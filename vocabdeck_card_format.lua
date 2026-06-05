-- Formatting helpers for VocabDeck card previews and list rows.
local _ = require("gettext")

local DB = require("vocabdeck_db")
local Languages = require("vocabdeck_languages")
local TextUtils = require("vocabdeck_text_utils")

local Format = {}

function Format.cleanMeaningPreview(meaning)
    if not meaning or meaning == "" then
        return ""
    end
    local first_line, rest = meaning:match("^([^\n]+)\n(.+)$")
    if not first_line or not rest then
        return meaning
    end
    local label = TextUtils.trim(first_line):lower()
    label = label:gsub("%s*[,;:].*$", "")
    if Languages.GRAMMAR_LABELS[label] then
        return TextUtils.trim(rest)
    end
    return meaning
end

function Format.buildCardSubtitle(card)
    if card.meaning and card.meaning ~= "" then
        return Format.cleanMeaningPreview(card.meaning)
    end
    if card.sentence and card.sentence ~= "" then
        return card.sentence
    end
    if card.display_context and card.display_context ~= "" then
        return card.display_context
    end
    if card.ai_status == DB.STATUS_ERROR then
        return _("AI fetch failed")
    end
    if card.ai_status == DB.STATUS_PENDING then
        return _("AI pending")
    end
    return _("No meaning yet")
end

function Format.buildPreviewText(card)
    local parts = { card.phrase or "" }
    local meta = {}
    if (card.leech or 0) ~= 0 then
        meta[#meta + 1] = _("Leech")
    end
    if card.word_type and card.word_type ~= "" then
        meta[#meta + 1] = card.word_type
    end
    if card.pronunciation and card.pronunciation ~= "" then
        meta[#meta + 1] = card.pronunciation
    end
    if #meta > 0 then
        parts[#parts + 1] = table.concat(meta, " · ")
    end
    if card.meaning ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = card.meaning
    end
    if card.synonym and card.synonym ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Synonyms: %s"), card.synonym)
    end
    local context = card.sentence ~= "" and card.sentence or card.display_context
    if context and context ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = context
    end
    if card.user_note and card.user_note ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Note: %s"), card.user_note)
    end
    local book_title = card.book_id and DB.getBookTitle(card.book_id)
    if book_title and book_title ~= "" or card.created_at then
        parts[#parts + 1] = ""
    end
    if book_title and book_title ~= "" then
        parts[#parts + 1] = string.format(_("Book: %s"), book_title)
    end
    if card.created_at then
        parts[#parts + 1] = string.format(_("Added on: %s"), os.date("%Y-%m-%d %H:%M", card.created_at))
    end
    if card.ai_status == DB.STATUS_ENRICHED then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("✨ Enriched by AI")
    elseif card.ai_status == DB.STATUS_ERROR and card.ai_error ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Last AI error: %s"), card.ai_error)
    elseif card.ai_status == DB.STATUS_PENDING then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("This card has not been enriched yet.")
    end
    return table.concat(parts, "\n")
end

function Format.formatReviewStatus(card)
    if not card then return "" end
    if (card.review_count or 0) == 0 then
        return _("New card")
    end
    local now = os.time()
    local due = tonumber(card.due) or now
    if due <= now then
        return _("Review now")
    end
    local next_day_start = DB.getNextReviewDayStart
        and DB.getNextReviewDayStart(now) or (now + 86400)
    if due < next_day_start then
        return _("Due today")
    end
    local days = math.max(1, math.ceil((due - next_day_start) / 86400))
    if days == 1 then
        return _("Review tomorrow")
    end
    return string.format(_("Review in %d days"), days)
end

return Format
