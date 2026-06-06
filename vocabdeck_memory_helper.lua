-- AI memory helper for difficult cards.
--
-- This is intentionally display-only: it does not mutate card data or
-- scheduling state. It asks the configured provider for a compact explanation
-- that helps memory without turning Study mode into a long article.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local AIRunner = require("vocabdeck_ai_runner")
local Capture = require("vocabdeck_capture")
local DB = require("vocabdeck_db")
local Querier = require("vocabdeck_ai")
local TextUtils = require("vocabdeck_text_utils")

local MemoryHelper = {}

-- In-memory cache for AI responses keyed by card.id.
-- TTL avoids stale data across a study session while still allowing
-- the user to re-fetch after a reasonable interval.
local _memory_cache = {}
local MEMORY_CACHE_TTL = 300 -- 5 minutes

local function cleanText(text)
    text = tostring(text or "")
    text = TextUtils.trim(text)
    text = TextUtils.normalizeNewlines(text)
    -- Ensure a blank line between section labels in case the AI omits them.
    text = text:gsub("(Collocations:)", "\n\n%1")
    text = text:gsub("(Memory hook:)", "\n\n%1")
    text = text:gsub("(Example:)", "\n\n%1")
    -- Collapse any excess blank lines that may have been introduced above.
    text = text:gsub("\n\n\n+", "\n\n")
    -- Strip any section label that has no content after it (e.g. "Morphology:\n\n").
    -- A section label followed by nothing but whitespace/newlines until the next
    -- label or end-of-string is considered empty and removed entirely.
    text = text:gsub("(Morphology:|Collocations:|Memory hook:|Example:)%s*\n%s*\n", "")
    -- Clean up any leading/trailing whitespace left after stripping.
    text = TextUtils.trim(text)
    return text
end

local function buildMessages(plugin, card)
    local target_language = "English"
    if plugin and plugin.settings then
        target_language = plugin.settings:readSetting("target_language", "English") or "English"
    end
    local source_language = card.source_language or ""
    local context = card.sentence or ""
    if context == "" then context = card.display_context or "" end
    if context == "" then context = card.ai_context or "" end

    local system_prompt = table.concat({
        "You are a compact vocabulary memory helper for an e-reader flashcard app.",
        "Return plain text only.",
        "Keep the whole answer under 120 words.",
        "Do not use Markdown tables.",
        "Omit any section that has no useful content.",
    }, "\n")

    local user_prompt = string.format([[
Word or phrase: %s
Source language: %s
Meaning already saved: %s
Context: %s
Answer language: %s
Existing notes: %s

Create a short memory aid with these rules:
- Include "Morphology:" only if the word has a clear, helpful prefix, suffix, root, or compound structure. If not useful, omit this line completely — do not output "Morphology:" with nothing after it.
- Include "Collocations:" with 2-4 common word pairings in the source language that show how the word is naturally used.
- Include "Memory hook:" with one short, vivid association — a sound-alike word, a mental image, or a personal connection. Keep it to one sentence.
- Include "Example:" with one vivid, unusual, or even weird sentence in the source language that creates a strong mental image. Contrast and absurdity are good — reality is optional. Use simple vocabulary when possible.
- Do not repeat information already covered in the existing notes.
- Keep section labels exactly as written below, but write the collocations, memory hook, and example content in the source language.
- Separate each section with a blank line.
- Keep the tone helpful and direct — like a friend explaining a word, not a dictionary.

Use this exact section order when a section appears (with a blank line between each):

Morphology:

Collocations:

Memory hook:

Example:
]], card.phrase or "", source_language ~= "" and source_language or "unknown",
        card.meaning or "", context, target_language, card.user_note or "")

    return Querier.buildMessages(system_prompt, user_prompt)
end

function MemoryHelper.showForCard(plugin, card, on_saved, on_close)
    local flow_closed = false
    local function finishFlow()
        if flow_closed then return end
        flow_closed = true
        if on_close then on_close() end
    end

    if not card then
        finishFlow()
        return
    end
    if not plugin or not plugin.querier then
        UIManager:show(InfoMessage:new{
            text = _("AI fetch failed:\nVocabDeck AI provider is not configured."),
            timeout = 4,
        })
        finishFlow()
        return
    end

    -- Check in-memory cache first (fastest)
    local cache_entry = _memory_cache[card.id]
    if cache_entry and cache_entry.expires_at > os.time() then
        MemoryHelper._showViewer(plugin, card, cache_entry.response, on_saved, "memory", finishFlow)
        return
    end

    -- Check DB cache (still fast, no API call)
    if card.ai_memory_helper and card.ai_memory_helper ~= "" then
        MemoryHelper._showViewer(plugin, card, card.ai_memory_helper, on_saved, "db", finishFlow)
        return
    end

    local viewer_opened = false
    AIRunner.run(plugin, {
        message = _("Building AI memory helper for:\n%s"),
        phrase = card.phrase or "",
        work = function(trap)
            local anchored = Capture.anchorInfoMessageBottomLeft(trap)
            return plugin.querier:query(buildMessages(plugin, card), anchored)
        end,
        on_error = function(err)
            UIManager:show(InfoMessage:new{
                text = string.format(_("AI memory helper failed:\n%s"), err),
                timeout = 4,
            })
            finishFlow()
        end,
        on_success = function(response)
            local helper_text = cleanText(response)

            -- Handle empty AI response with a fallback message
            if helper_text == "" then
                UIManager:show(InfoMessage:new{
                    text = _("AI returned an empty response. Try again later."),
                    timeout = 3,
                })
                finishFlow()
                return
            end

            -- Store in in-memory cache
            _memory_cache[card.id] = {
                response = helper_text,
                expires_at = os.time() + MEMORY_CACHE_TTL,
            }

            -- Persist to DB so it survives restarts
            DB.updateCardMemoryHelper(card.id, helper_text)
            card.ai_memory_helper = helper_text

            viewer_opened = true
            MemoryHelper._showViewer(plugin, card, helper_text, on_saved, "fresh", finishFlow)
        end,
        on_finally = function()
            if not viewer_opened then
                finishFlow()
            end
        end,
    })
end

-- Shows the AI memory helper text in a TextViewer with Save/Close buttons.
-- Extracted so both the cache-hit path and the fresh-fetch path share the same UI.
-- @param plugin  The VocabDeck plugin instance (needed for Regenerate).
-- @param card    The card object.
-- @param helper_text  The AI-generated memory aid text.
-- @param on_saved     Optional callback invoked after saving as note.
-- @param source       One of "memory", "db", or "fresh" — controls the title indicator.
-- @param on_close     Optional callback invoked when the helper flow is done.
function MemoryHelper._showViewer(plugin, card, helper_text, on_saved, source, on_close)
    local viewer
    local closed = false
    local suppress_close = false

    local function notifyClosed()
        if closed or suppress_close then return end
        closed = true
        if on_close then on_close() end
    end

    -- Build the title with a source indicator
    local title = _("AI memory helper")
    if source == "memory" then
        title = title .. " (" .. _("cached") .. ")"
    elseif source == "db" then
        title = title .. " (" .. _("saved") .. ")"
    end

    local buttons = { {
        {
            text = _("Save as note"),
            callback = function()
                local input_dialog
                input_dialog = InputDialog:new{
                    title = _("Save as note"),
                    input = helper_text,
                    allow_newline = true,
                    rows = 8,
                    buttons = { {
                        {
                            text = _("Cancel"),
                            callback = function()
                                UIManager:close(input_dialog)
                            end,
                        },
                        {
                            text = _("Save"),
                            callback = function()
                                local edited_text = input_dialog:getInputText()
                                UIManager:close(input_dialog)
                                local existing_note = card.user_note or ""

                                -- Avoid accumulating duplicate entries.
                                -- Check if the exact same edited_text is already the
                                -- last segment of user_note (separated by blank line).
                                local last_segment = existing_note:match("%s*\n\n%s*([^\n].*)$")
                                    or existing_note
                                if last_segment == edited_text then
                                    UIManager:show(InfoMessage:new{
                                        text = _("Already saved."),
                                        timeout = 2,
                                    })
                                    return
                                end

                                local note = existing_note ~= ""
                                    and (existing_note .. "\n\n" .. edited_text)
                                    or edited_text
                                -- Use lightweight update that only touches user_note
                                DB.updateCardNote(card.id, note)
                                card.user_note = note
                                -- Invalidate cache so next fetch gets fresh data
                                _memory_cache[card.id] = nil
                                if on_saved then on_saved(card) end
                                UIManager:show(InfoMessage:new{
                                    text = _("Saved as note."),
                                    timeout = 2,
                                })
                            end,
                        },
                    } },
                }
                UIManager:show(input_dialog)
            end,
        },
        {
            text = _("Regenerate"),
            callback = function()
                suppress_close = true
                if viewer then UIManager:close(viewer) end
                -- Clear both caches
                _memory_cache[card.id] = nil
                card.ai_memory_helper = ""
                -- Re-fetch from AI
                MemoryHelper.showForCard(plugin, card, on_saved, on_close)
            end,
        },
        {
            text = _("Close"),
            callback = function()
                if viewer then UIManager:close(viewer) end
                notifyClosed()
            end,
        },
    } }
    viewer = TextViewer:new{
        title = title,
        text = helper_text,
        buttons_table = buttons,
        add_default_buttons = false,
    }
    local old_on_close = viewer.onCloseWidget
    function viewer:onCloseWidget()
        if old_on_close then old_on_close(self) end
        notifyClosed()
    end
    UIManager:show(viewer)
end

function MemoryHelper.show(study, on_saved, on_close)
    if not study or not study.current_card then
        if on_close then on_close() end
        return
    end
    MemoryHelper.showForCard(study.plugin, study.current_card, on_saved, on_close)
end

return MemoryHelper
