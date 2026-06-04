-- Read-only diagnostics for troubleshooting common VocabDeck setup issues.
local _ = require("gettext")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")

local Diagnostics = {}

local function valueOrDash(value)
    if value == nil or value == "" then return "-" end
    return tostring(value)
end

local function yesNo(value)
    return value and _("Yes") or _("No")
end

local function formatTime(ts)
    if not ts then return "-" end
    return os.date("%Y-%m-%d %H:%M", ts)
end

function Diagnostics.show(plugin, plugin_version, config_error)
    local provider = plugin:getActiveProvider()
    local model = provider and plugin.settings:readSetting("model_" .. provider) or nil
    if (not model or model == "") and plugin.querier and plugin.querier:isInited() then
        model = plugin.querier:getModel()
    end

    local active_language = DB.getActiveLanguage()
    local languages = DB.listLanguages()
    local latest_error = DB.getLatestAIError()
    local cfg_status = plugin.CONFIGURATION and _("Loaded")
        or (config_error and config_error ~= "" and config_error)
        or _("Not found")

    local lines = {
        string.format(_("Plugin version: %s"), valueOrDash(plugin_version)),
        string.format(_("Configuration: %s"), cfg_status),
        string.format(_("Provider: %s"), valueOrDash(provider)),
        string.format(_("Model: %s"), valueOrDash(model)),
        string.format(_("AI provider loaded: %s"), yesNo(plugin.querier and plugin.querier:isInited())),
        "",
        string.format(_("Active language: %s"), valueOrDash(active_language)),
        string.format(_("Available languages: %s"), #languages > 0 and table.concat(languages, ", ") or "-"),
        string.format(_("Active database: %s"), valueOrDash(DB.getPath())),
        string.format(_("Schema version: %s"), valueOrDash(DB.getSchemaVersion())),
        string.format(_("Cards in active language: %s"), tostring(DB.getCardCountForBook(nil))),
        "",
        string.format(_("Current book: %s"), valueOrDash(plugin:getDocumentTitle())),
        string.format(_("Current book language: %s"), valueOrDash(plugin:getDocumentSourceLanguage())),
    }

    if latest_error then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Last AI error")
        lines[#lines + 1] = string.format(_("Card: %s"), valueOrDash(latest_error.phrase))
        lines[#lines + 1] = string.format(_("Time: %s"), formatTime(latest_error.updated_at))
        lines[#lines + 1] = latest_error.error
    else
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("Last AI error: none")
    end

    UIManager:show(TextViewer:new{
        title = _("VocabDeck diagnostics"),
        text = table.concat(lines, "\n"),
    })
end

return Diagnostics
