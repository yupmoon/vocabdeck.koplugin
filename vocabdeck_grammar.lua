-- Ephemeral AI grammar helper for highlighted text.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local AIRunner = require("vocabdeck_ai_runner")
local Capture = require("vocabdeck_capture")
local Querier = require("vocabdeck_ai")
local TextUtils = require("vocabdeck_text_utils")

local Grammar = {}

local SETTING_KEY = "grammar_helper_enabled"
local CACHE_TTL_SECONDS = 300
local CACHE_MAX_ENTRIES = 50
local CACHE_VERSION = "grammar-v2"
local cache = {}

local function grammarEnabled(plugin)
    return plugin and plugin.settings and plugin.settings:readSetting(SETTING_KEY) == true
end

-- System prompts. Both modes include a translation in the target language
-- before the grammar breakdown. Word limits account for both sections.
local CONCISE_SYSTEM = [[
You are a compact grammar tutor for an e-reader flashcard app.
Return plain text only. No markdown, no tables, no code blocks.
Keep the whole answer under 180 words.

First, provide a natural translation of the selected text in the explanation language.
Label it "Translation:".

Then pick the single most notable or interesting grammar point. Explain:
- What the grammar point is (e.g. subjunctive mood, relative clause, particle usage)
- Why it is used here in this specific sentence
- 1-2 short similar examples in the source language
Label this section "Grammar:".
Use a numbered list for grammar points. Put one blank line between numbered items, like:
1. First point

2. Second point

If the selected text has no notable grammar (e.g. a single common noun like "gato"),
briefly state that and move on -- do not invent grammar where there is none.

Write explanations in the explanation language. Write examples in the source language.
Keep the tone helpful and direct -- like a friend explaining grammar, not a textbook.
]]

local DETAILED_SYSTEM = [[
You are a grammar tutor for an e-reader flashcard app.
Return plain text only. No markdown, no tables, no code blocks.
Keep the whole answer under 450 words.

First, provide a natural translation of the selected text in the explanation language.
Label it "Translation:".

Then explain ALL grammar points present in the selected text. For each point, cover:
- What the grammar structure is
- Why it is used in this specific sentence
- 1-2 similar examples in the source language
Label this section "Grammar:".
Use a numbered list for grammar points. Put one blank line between numbered items, like:
1. First point

2. Second point

Organize by importance. Consider these categories where relevant:
- Sentence structure and word order
- Verb forms: tense, mood, aspect, conjugation patterns
- Particles, prepositions, and postpositions
- Case marking and agreement (gender, number, person)
- Clause types: relative, conditional, subordinate
- Any unusual or advanced constructions

If the selected text has no notable grammar (e.g. a single common noun),
briefly state that and move on -- do not invent grammar where there is none.

Write explanations in the explanation language. Write examples in the source language.
Keep the tone helpful and direct -- like a friend explaining grammar, not a textbook.
]]

local function buildSystemPrompt(detailed)
    return detailed and DETAILED_SYSTEM or CONCISE_SYSTEM
end

local function buildUserPrompt(params, source_language, target_language)
    local parts = {}

    if source_language and source_language ~= "" then
        parts[#parts + 1] = "Source language: " .. source_language
    end
    if target_language and target_language ~= "" then
        parts[#parts + 1] = "Explanation language: " .. target_language
    end

    parts[#parts + 1] = "Selected text:\n" .. (params.phrase or "")

    local context = Capture.firstText(params.ai_context, params.sentence, params.display_context)
    if context ~= "" then
        parts[#parts + 1] = "Context:\n" .. context
    end

    parts[#parts + 1] = "Explain the grammar used in the selected text above."

    return table.concat(parts, "\n\n")
end

local function cleanResult(text)
    text = tostring(text or ""):gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("\n%s*\n+", "\nVD_GRAMMAR_PARAGRAPH_BREAK\n")
    text = Capture.cleanText(text)
    text = text:gsub("\n?VD_GRAMMAR_PARAGRAPH_BREAK\n?", "\n\n")
    text = text:gsub("^#+%s*", "")
    return TextUtils.trim(text)
end

local function cacheKey(params)
    return table.concat({
        CACHE_VERSION,
        Capture.cleanText(params and params.phrase or ""),
        Capture.cleanText(params and params.ai_context or ""),
        Capture.cleanText(params and params.sentence or ""),
        Capture.cleanText(params and params.display_context or ""),
    }, "\31")
end

local function getCached(params, detailed)
    local entry = cache[cacheKey(params)]
    if not entry or os.time() - entry.created_at > CACHE_TTL_SECONDS then
        return nil
    end
    if detailed then
        return entry.detailed
    else
        return entry.concise
    end
end

local function setCached(params, detailed, text)
    local key = cacheKey(params)
    local entry = cache[key]
    if not entry or os.time() - entry.created_at > CACHE_TTL_SECONDS then
        -- Evict oldest entry if at capacity before inserting a new one.
        if not entry then
            local keys = {}
            for k in pairs(cache) do keys[#keys + 1] = k end
            if #keys >= CACHE_MAX_ENTRIES then
                table.sort(keys, function(a, b)
                    return (cache[a].created_at or 0) < (cache[b].created_at or 0)
                end)
                cache[keys[1]] = nil
            end
        end
        entry = {}
        cache[key] = entry
    end
    entry.created_at = os.time()
    if detailed then
        entry.detailed = text
    else
        entry.concise = text
    end
end

local function clearCached(params, detailed)
    local key = cacheKey(params)
    local entry = cache[key]
    if not entry then return end
    if detailed then
        entry.detailed = nil
    else
        entry.concise = nil
    end
    if not entry.concise and not entry.detailed then
        cache[key] = nil
    end
end

local function showNativeNoteUnavailable()
    UIManager:show(InfoMessage:new{
        text = _("Could not open KOReader's note editor for this highlight."),
        timeout = 4,
    })
end

function Grammar.explainGrammar(plugin, params, detailed, on_success)
    local cached = getCached(params, detailed)
    if cached then
        if on_success then
            on_success(cached, detailed)
        end
        return
    end

    local target_language = "English"
    if plugin and plugin.settings then
        target_language = plugin.settings:readSetting("target_language", "English") or "English"
    end
    local source_language = params and params.source_language or ""

    -- Track whether on_success fired so on_finally knows whether to clear
    -- the highlight selection. On success the viewer needs it alive for
    -- "Save as note" and "Close"; on any failure/cancel path we clean up.
    local completed = false

    AIRunner.run(plugin, {
        message = _("Grammar... tap outside to cancel"),
        phrase = params and params.phrase,
        work = function(trap)
            local anchored = Capture.anchorInfoMessageBottomLeft(trap)
            if not plugin.querier or not plugin.querier.query then
                return nil, _("VocabDeck AI provider is not configured.")
            end
            local messages = Querier.buildMessages(
                buildSystemPrompt(detailed),
                buildUserPrompt(params, source_language, target_language)
            )
            return plugin.querier:query(messages, anchored)
        end,
        on_success = function(result)
            completed = true
            result = cleanResult(result)
            if result == "" then
                result = _("No notable grammar point found.")
            end
            setCached(params, detailed, result)
            if on_success then
                on_success(result, detailed)
            end
        end,
        on_error = function(err)
            UIManager:show(InfoMessage:new{
                text = AIRunner.formatError(err or _("Unknown error")),
                timeout = 4,
            })
        end,
        on_finally = function()
            if not completed and params.reader_highlight and type(params.reader_highlight.clear) == "function" then
                params.reader_highlight:clear()
            end
        end,
    })
end

function Grammar._showGrammarResult(plugin, params, text, detailed)
    local viewer
    local function clearHighlight()
        if params.reader_highlight and type(params.reader_highlight.clear) == "function" then
            params.reader_highlight:clear()
        end
    end
    local function closeViewer(should_clear_highlight)
        if viewer then
            UIManager:close(viewer)
        end
        if should_clear_highlight then
            clearHighlight()
        end
    end
    local function rerun(next_detailed)
        closeViewer(false)
        Grammar.explainGrammar(plugin, params, next_detailed, function(result, result_detailed)
            Grammar._showGrammarResult(plugin, params, result, result_detailed)
        end)
    end
    local function regenerate()
        clearCached(params, detailed)
        rerun(detailed)
    end
    local function saveAsNote()
        closeViewer(false)
        if params.reader_highlight and type(params.reader_highlight.addNote) == "function" then
            params.reader_highlight:addNote(text)
            return
        end
        if plugin and plugin.ui and plugin.ui.highlight and type(plugin.ui.highlight.addNote) == "function" then
            plugin.ui.highlight:addNote(text)
            return
        end
        showNativeNoteUnavailable()
    end

    viewer = TextViewer:new{
        title = _("Grammar (VD)"),
        text = text,
        buttons_table = {
            {
                {
                    text = detailed and _("Concise") or _("Detailed"),
                    callback = function()
                        rerun(not detailed)
                    end,
                },
                {
                    text = _("Regenerate"),
                    callback = regenerate,
                },
            },
            {
                {
                    text = _("Save as note"),
                    callback = saveAsNote,
                },
                {
                    text = _("Close"),
                    callback = function()
                        closeViewer(true)
                    end,
                },
            },
        },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function Grammar.install(VocabDeck)
    function VocabDeck:isGrammarHelperEnabled()
        return grammarEnabled(self)
    end

    function VocabDeck:grammarFromHighlight(reader_highlight)
        if not self:isGrammarHelperEnabled() then
            UIManager:show(InfoMessage:new{
                text = _("Grammar helper is disabled. Enable it in VocabDeck settings."),
                timeout = 4,
            })
            return
        end

        local params = self:_buildHighlightCardParams(reader_highlight)
        if not params or not params.phrase or params.phrase == "" then
            UIManager:show(InfoMessage:new{ text = _("No text selected."), timeout = 3 })
            return
        end

        if reader_highlight and type(reader_highlight.onClose) == "function" then
            reader_highlight:onClose(true)
        elseif reader_highlight and reader_highlight.highlight_dialog then
            UIManager:close(reader_highlight.highlight_dialog)
            reader_highlight.highlight_dialog = nil
        end
        params.reader_highlight = reader_highlight
        Grammar.explainGrammar(self, params, false, function(result, detailed)
            Grammar._showGrammarResult(self, params, result, detailed)
        end)
    end
end

return Grammar
