-- Main-menu Study entry flow.
-- Provides sub-menu items for the TouchMenu (no ButtonDialog overlay).
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")

local StudyEntry = {}

function StudyEntry.install(VocabDeck)
    -- Shared helper: start study for a given language.
    local function startStudy(plugin, language)
        plugin:saveSetting("last_study_source_language", language)
        local StudyScreen = require("vocabdeck_study")
        local study = StudyScreen:new{
            plugin = plugin,
            source_language = language,
            book_title = language,
        }
        UIManager:show(study)
    end

    -- Build sub-menu items for the "Study" TouchMenu entry.
    -- Returns a table of menu items, one per source language with due count.
    -- If only one language has due cards, returns a single item that starts
    -- study immediately (no sub-menu expansion needed).
    function StudyEntry.buildStudyMenuItems(plugin)
        local total = DB.getCardCountForBook(nil)
        if total == 0 then
            return { {
                text = _("No cards yet. Add words or phrases from the highlight menu or dictionary popup."),
                enabled = false,
            } }
        end

        local languages = DB.listSourceLanguages(nil)
        if #languages == 0 then
            return { {
                text = _("No source languages found. Add or enrich cards first."),
                enabled = false,
            } }
        end

        local require_enriched = plugin:readSetting("require_enriched_for_study")
        if require_enriched == nil then require_enriched = true end
        local daily_new_limit = tonumber(plugin:readSetting("daily_new_cards_limit", 20)) or 20
        local daily_review_limit = tonumber(plugin:readSetting("daily_review_cards_limit", 200)) or 200

        local due_counts = {}
        local first_due_language
        for _, language in ipairs(languages) do
            local ok, counts = pcall(DB.getStudyQueueCounts,
                nil, language, require_enriched, nil, daily_review_limit, 20 * 60, daily_new_limit, true)
            local due_count = 0
            if ok and counts then
                due_count = (tonumber(counts.new) or 0)
                    + (tonumber(counts.learning) or 0)
                    + (tonumber(counts.review) or 0)
            end
            due_counts[language] = due_count
            if due_count > 0 and not first_due_language then
                first_due_language = language
            end
        end

        -- Build items for languages that have due cards.
        local items = {}
        for _, language in ipairs(languages) do
            local due_count = due_counts[language] or 0
            if due_count > 0 then
                items[#items + 1] = {
                    text = string.format("%s [%d]", language, due_count),
                    callback = function()
                        startStudy(plugin, language)
                    end,
                }
            end
        end
        if #items == 0 then
            return { {
                text = _("No cards due for study."),
                enabled = false,
            } }
        end

        -- Single language with due cards: return a direct callback so
        -- clicking "Study" goes straight to study mode (no sub-menu).
        if #items == 1 then
            return { {
                text = items[1].text,
                callback = items[1].callback,
            } }
        end

        return items
    end
end

return StudyEntry
