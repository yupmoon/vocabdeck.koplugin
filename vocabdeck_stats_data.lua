-- VocabDeck stats data selection.
--
-- Collects the all-cards and current-book summaries for the stats view.
local DB = require("vocabdeck_db")

local StatsData = {}

local function emptySummary()
    return {
        total = 0, enriched = 0, pending = 0, failed = 0,
        due = 0, overdue = 0, due_later_today = 0, due_tomorrow = 0, due_next_7_days = 0,
        new = 0, learning = 0, young = 0, mature = 0, reviewed = 0,
        studied_today = 0, added_today = 0,
        again_today = 0, hard_today = 0, good_today = 0, easy_today = 0,
        review_events = 0, study_days = 0, current_streak = 0, best_streak = 0,
        lapses = 0, lapsed_cards = 0,
        avg_stability = 0, avg_difficulty = 0,
        suspended = 0, leeches = 0, known = 0, flagged = 0, books = 0,
    }
end

local function safeSummary(book_id, require_enriched)
    local ok, summary = pcall(DB.getSummary, book_id, require_enriched)
    if ok and summary then return summary end
    return emptySummary()
end

function StatsData.collect(plugin)
    local book_id
    local filepath = plugin:getDocumentFilePath()
    if filepath then
        local ok_book_id, found_book_id = pcall(DB.getBookIdByFilepath, filepath)
        if ok_book_id then
            book_id = found_book_id
        end
    end
    local require_enriched = true
    if plugin then
        local v = plugin:readSetting("require_enriched_for_study")
        require_enriched = v == nil and true or not not v
    end

    local ok_languages, languages = pcall(DB.getSourceLanguageSummaries, require_enriched)
    if not ok_languages then
        languages = {}
    end

    return {
        all = safeSummary(nil, require_enriched),
        current = book_id and safeSummary(book_id, require_enriched) or nil,
        languages = languages,
    }
end

return StatsData
