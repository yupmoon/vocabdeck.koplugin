-- Temporary daily study-limit overrides.
--
-- "Study more" is deliberately small: choose a language once the normal
-- daily queue is exhausted, then add the configured extra allowance for today
-- and open the study screen.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")

local StudyMore = {}

local STUDY_MORE_ENABLED = false  -- freeze: set to true to re-enable

local EXTRA_NEW_KEY = "study_more_extra_new_cards"
local EXTRA_REVIEW_KEY = "study_more_extra_review_cards"
local EXTRA_DAY_KEY = "study_more_extra_day"

local function readNumber(plugin, key, default)
    if not plugin or not plugin.readSetting then return default end
    return tonumber(plugin:readSetting(key, default)) or default
end

local function todayKey()
    return os.date("%Y-%m-%d", os.time())
end

local function readDailyExtra(plugin, key)
    if not plugin or not plugin.readSetting then return 0 end
    if plugin:readSetting(EXTRA_DAY_KEY, "") ~= todayKey() then
        return 0
    end
    return readNumber(plugin, key, 0)
end

local function readBaseLimit(plugin, field)
    if field == "review" then
        return readNumber(plugin, "daily_review_cards_limit", 200)
    end
    return readNumber(plugin, "daily_new_cards_limit", 20)
end

local function readExtraNew(plugin)
    return readDailyExtra(plugin, EXTRA_NEW_KEY)
end

local function readExtraReview(plugin)
    return readDailyExtra(plugin, EXTRA_REVIEW_KEY)
end

local function requireEnrichedForStudy(plugin)
    if not plugin or not plugin.readSetting then return true end
    local value = plugin:readSetting("require_enriched_for_study")
    if value == nil then return true end
    return value and true or false
end

local function normalStudyCount(plugin, language)
    local ok, counts = pcall(DB.getStudyQueueCounts,
        nil, language, requireEnrichedForStudy(plugin), nil,
        readBaseLimit(plugin, "review"), 20 * 60,
        readBaseLimit(plugin, "new"), true)
    if not ok or not counts then return nil end
    return (tonumber(counts.new) or 0)
        + (tonumber(counts.learning) or 0)
        + (tonumber(counts.review) or 0)
end

local function listSourceLanguages()
    local ok, languages = pcall(DB.listSourceLanguages, nil)
    if not ok or type(languages) ~= "table" then
        return {}
    end
    return languages
end

function StudyMore.hasAvailableStudyMore(plugin)
    if not STUDY_MORE_ENABLED then return false end
    if readExtraNew(plugin) <= 0 and readExtraReview(plugin) <= 0 then
        return false
    end
    for _, language in ipairs(listSourceLanguages()) do
        local count = normalStudyCount(plugin, language)
        if count == 0 then
            return true
        end
    end
    return false
end

local function openStudyMore(plugin, language)
    local extra_new = readExtraNew(plugin)
    local extra_review = readExtraReview(plugin)
    if extra_new > 0 then
        DB.addDailyOverride(language, "new", extra_new, readBaseLimit(plugin, "new"), true)
    end
    if extra_review > 0 then
        DB.addDailyOverride(language, "review", extra_review, readBaseLimit(plugin, "review"), true)
    end
    if plugin and plugin.saveSetting then
        plugin:saveSetting("last_study_source_language", language)
    end
    local StudyScreen = require("vocabdeck_study")
    UIManager:show(StudyScreen:new{
        plugin = plugin,
        source_language = language,
        book_title = language,
        use_daily_override = true,
    })
end

local function makeLanguageItems(plugin)
    local items = {}
    for _, language in ipairs(listSourceLanguages()) do
        items[#items + 1] = {
            text = language,
            enabled_func = function()
                return normalStudyCount(plugin, language) == 0
            end,
            callback = function()
                openStudyMore(plugin, language)
            end,
        }
    end
    if #items == 0 then
        items[#items + 1] = {
            text = _("No source languages found"),
            enabled = false,
        }
    else
        items[#items].separator = true
    end
    return items
end

local function saveChoice(plugin, key, value)
    if not plugin or not plugin.settings then return end
    plugin.settings:saveSetting(EXTRA_DAY_KEY, todayKey())
    plugin.settings:saveSetting(key, value)
    plugin.settings:flush()
end

local function makeChoiceItems(plugin, key, values)
    local items = {}
    for _, value in ipairs(values) do
        items[#items + 1] = {
            text = tostring(value),
            checked_func = function()
                return readDailyExtra(plugin, key) == value
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                saveChoice(plugin, key, value)
                if touchmenu_instance and touchmenu_instance.updateItems then
                    touchmenu_instance:updateItems()
                end
            end,
        }
    end
    return items
end

function StudyMore.buildMenuItems(plugin)
    return makeLanguageItems(plugin)
end

function StudyMore.buildSettingsItems(plugin)
    if not STUDY_MORE_ENABLED then return {} end
    return {
        {
            text = _("Extra new cards for today"),
            text_func = function()
                return string.format("%s: %d", _("Extra new cards for today"), readExtraNew(plugin))
            end,
            sub_item_table_func = function()
                return makeChoiceItems(plugin, EXTRA_NEW_KEY, { 0, 10, 20 })
            end,
        },
        {
            text = _("Extra reviews for today"),
            text_func = function()
                return string.format("%s: %d", _("Extra reviews for today"), readExtraReview(plugin))
            end,
            sub_item_table_func = function()
                return makeChoiceItems(plugin, EXTRA_REVIEW_KEY, { 0, 50, 100 })
            end,
        },
    }
end

return StudyMore
