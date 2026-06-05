-- VocabDeck stats presentation.
--
-- Keeps the e-ink friendly summary layout out of main.lua. Stats data
-- selection lives in vocabdeck_stats_data.lua.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local StatsData = require("vocabdeck_stats_data")
local DB = require("vocabdeck_db")

local Stats = {}

local divider = "────────────────────────"

local function pair(left_label, left_value, right_label, right_value)
    return string.format("%-12s %5s   │   %-12s %5s",
        left_label, tostring(left_value), right_label, tostring(right_value))
end

local function single(label, value)
    return string.format("%-12s %5s", label, tostring(value))
end

local function progressBar(value, total, width)
    value = tonumber(value) or 0
    total = tonumber(total) or 0
    width = width or 18
    if total <= 0 then
        return string.rep("─", width)
    end
    local filled = math.floor((value / total) * width + 0.5)
    if filled < 0 then filled = 0 end
    if filled > width then filled = width end
    return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function streakText(days)
    days = tonumber(days) or 0
    if days <= 0 then return _("No daily streak") end
    if days == 1 then return _("1 day") end
    return string.format(_("%d days"), days)
end

local function decimal(value, places)
    value = tonumber(value) or 0
    places = places or 1
    local fmt = "%." .. tostring(places) .. "f"
    return string.format(fmt, value)
end

local function ratingLine(summary)
    return string.format("%s %d   %s %d   %s %d   %s %d",
        _("Again"), tonumber(summary.again_today) or 0,
        _("Hard"), tonumber(summary.hard_today) or 0,
        _("Good"), tonumber(summary.good_today) or 0,
        _("Easy"), tonumber(summary.easy_today) or 0)
end

local function shortText(text, max_len)
    text = tostring(text or "")
    max_len = max_len or 14
    if #text <= max_len then return text end
    return text:sub(1, max_len - 1) .. "…"
end

local function addSourceLanguages(lines, languages)
    if not languages or #languages == 0 then return end
    lines[#lines + 1] = divider
    lines[#lines + 1] = ""
    lines[#lines + 1] = _("SOURCE LANGUAGES")
    local max_rows = math.min(#languages, 8)
    for i = 1, max_rows do
        local row = languages[i]
        lines[#lines + 1] = string.format("%-12s %4d  %s %d  %s %d",
            shortText(row.language or _("Unknown"), 12),
            tonumber(row.total) or 0,
            _("due"), tonumber(row.due) or 0,
            _("new"), tonumber(row.new) or 0)
    end
    if #languages > max_rows then
        lines[#lines + 1] = string.format(_("%d more languages"), #languages - max_rows)
    end
end

local function addSummary(lines, title, summary)
    lines[#lines + 1] = string.upper(title)
    lines[#lines + 1] = ""

    lines[#lines + 1] = _("TODAY")
    lines[#lines + 1] = pair(_("reviews"), summary.studied_today, _("added"), summary.added_today)
    lines[#lines + 1] = ratingLine(summary)
    lines[#lines + 1] = divider

    lines[#lines + 1] = _("STREAK")
    lines[#lines + 1] = string.format("%-12s %s", _("current"), streakText(summary.current_streak))
    lines[#lines + 1] = string.format("%-12s %s", _("best"), streakText(summary.best_streak))
    lines[#lines + 1] = divider

    lines[#lines + 1] = _("DUE")
    lines[#lines + 1] = pair(_("now"), summary.due, _("due today"), summary.due_later_today)
    lines[#lines + 1] = pair(_("overdue"), summary.overdue, _("tomorrow"), summary.due_tomorrow)
    lines[#lines + 1] = single(_("next 7 days"), summary.due_next_7_days)
    lines[#lines + 1] = divider

    lines[#lines + 1] = _("DECK")
    lines[#lines + 1] = pair(_("total"), summary.total, _("new"), summary.new)
    lines[#lines + 1] = pair(_("learning"), summary.learning, _("reviewed"), summary.reviewed)
    lines[#lines + 1] = pair(_("young"), summary.young, _("mature"), summary.mature)
    lines[#lines + 1] = pair(_("flagged"), summary.flagged, _("leeches"), summary.leeches)
    lines[#lines + 1] = pair(_("suspended"), summary.suspended, _("known"), summary.known)
    lines[#lines + 1] = string.format("%s  %s", progressBar(summary.reviewed, summary.total, 18), _("reviewed"))
    lines[#lines + 1] = divider

    lines[#lines + 1] = _("MEMORY")
    lines[#lines + 1] = pair(_("study days"), summary.study_days, _("events"), summary.review_events)
    lines[#lines + 1] = pair(_("stability"), decimal(summary.avg_stability, 1) .. "d", _("difficulty"), decimal(summary.avg_difficulty, 1))
    lines[#lines + 1] = pair(_("lapsed"), summary.lapsed_cards, _("lapses"), summary.lapses)
end

function Stats.show(plugin)
    local ok, summaries = pcall(StatsData.collect, plugin)
    if not ok or not summaries or not summaries.all then
        UIManager:show(InfoMessage:new{
            text = _("VocabDeck stats could not be loaded."),
            timeout = 3,
        })
        return
    end
    local all = summaries.all
    local current = summaries.current
    local languages = summaries.languages
    local lines = {}

    addSummary(lines, _("All cards"), all)
    addSourceLanguages(lines, languages)
    if current then
        lines[#lines + 1] = ""
        lines[#lines + 1] = divider
        lines[#lines + 1] = ""
        addSummary(lines, _("This book"), current)
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = divider
        lines[#lines + 1] = string.format(_("Books: %d"), all.books)
    end

    local viewer
    viewer = TextViewer:new{
        title = _("VocabDeck stats"),
        text = table.concat(lines, "\n"),
        buttons_table = {
            {
                {
                    text = _("Study history"),
                    callback = function()
                        Stats.showHistory()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

function Stats.showHistory()
    local ok, days = pcall(DB.getStudyHistory, 14)
    if not ok or not days or #days == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No study history yet."),
            timeout = 3,
        })
        return
    end

    local lines = { _("STUDY HISTORY"), "" }
    for _, row in ipairs(days) do
        local bar = string.rep("█", math.floor(row.good / math.max(row.total, 1) * 10 + 0.5))
            .. string.rep("░", 10 - math.floor(row.good / math.max(row.total, 1) * 10 + 0.5))
        lines[#lines + 1] = string.format("%s  %3d reviews  %2d cards  %s",
            row.day, row.total, row.cards, bar)
        lines[#lines + 1] = string.format("         again %d  hard %d  good %d  easy %d",
            row.again, row.hard, row.good, row.easy)
        lines[#lines + 1] = ""
    end

    UIManager:show(TextViewer:new{
        title = _("Study history"),
        text = table.concat(lines, "\n"),
    })
end

return Stats
