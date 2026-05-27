-- Main-menu Study entry flow.
-- Provides flat menu items for each source language.
local _ = require("gettext")
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

    -- Build flat menu items for each source language with due count.
    -- Languages with zero due cards are included but grayed out (enabled = false).
    function StudyEntry.buildStudyMenuItems(plugin)
        local total = DB.getCardCountForBook(nil)
        if total == 0 then
            return { {
                text = _("No cards yet. Add words or phrases from the highlight menu or dictionary popup."),
                enabled = false,
            } }
        end

        -- Use the same filtered query as the "All cards → filter by language" dialog,
        -- so only languages with active (non-known, non-suspended) cards are shown.
        local languages = DB.listSourceLanguagesWithCards(nil, false, false, "", os.time(), "", false, false)
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
        end

        -- Build items for all languages; zero-due languages are grayed out.
        local items = {}
        for _, language in ipairs(languages) do
            local due_count = due_counts[language] or 0
            local item = {
                text = string.format("%s [%d]", language, due_count),
            }
            if due_count > 0 then
                item.callback = function()
                    startStudy(plugin, language)
                end
            else
                item.enabled = false
            end
            items[#items + 1] = item
        end
        if #items == 0 then
            return { {
                text = _("No cards due for study."),
                enabled = false,
            } }
        end

        return items
    end
end

return StudyEntry
