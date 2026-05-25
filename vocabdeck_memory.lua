-- VocabDeck card memory/debug text.
--
-- Small, read-only helper used by card details and Study mode.

local _ = require("gettext")
local Scheduler = require("vocabdeck_scheduler")

local Memory = {}

local function formatTimestamp(ts)
    ts = tonumber(ts)
    if not ts or ts <= 0 then return _("Never") end
    return os.date("%Y-%m-%d %H:%M", ts)
end

local function fsrsStateName(state)
    state = tonumber(state) or Scheduler.STATE_LEARNING
    if state == Scheduler.STATE_REVIEW then return _("Review") end
    if state == Scheduler.STATE_RELEARNING then return _("Relearning") end
    return _("Learning")
end

function Memory.buildText(card)
    local retrievability = Scheduler.getRetrievability(card, os.time())
    local parts = {
        string.format(_("Card: %s"), card.phrase or ""),
        "",
        string.format(_("State: %s"), fsrsStateName(card.fsrs_state)),
        string.format(_("Difficulty: %.2f"), tonumber(card.fsrs_difficulty) or 0),
        string.format(_("Stability: %.2f days"), tonumber(card.fsrs_stability) or 0),
        string.format(_("Retrievability now: %.0f%%"), math.max(0, math.min(1, retrievability or 0)) * 100),
        "",
        string.format(_("Due: %s"), formatTimestamp(card.due)),
        string.format(_("Last reviewed: %s"), formatTimestamp(card.last_review)),
        string.format(_("Reviews: %d"), tonumber(card.review_count) or 0),
        string.format(_("Lapses: %d"), tonumber(card.lapse_count) or 0),
    }
    if (card.suspended or 0) ~= 0 then
        parts[#parts + 1] = _("Suspended: yes")
    end
    if (card.leech or 0) ~= 0 then
        parts[#parts + 1] = _("Leech: yes")
    end
    if (card.known or 0) ~= 0 then
        parts[#parts + 1] = _("Known: yes")
    end
    if (card.flag or 0) ~= 0 then
        parts[#parts + 1] = _("Flagged: yes")
    end
    return table.concat(parts, "\n")
end

return Memory
