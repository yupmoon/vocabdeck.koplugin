-- VocabDeck main menu builder.
--
-- Keeps KOReader menu table assembly out of the plugin lifecycle file.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")
local SettingsModule = require("vocabdeck_settings")
local Importer = require("vocabdeck_import")
local EditModule = require("vocabdeck_edit")
local Dashboard = require("vocabdeck_dashboard")
local Diagnostics = require("vocabdeck_diagnostics")
local StudyMore = require("vocabdeck_study_more")
local StudyEntry = require("vocabdeck_study_entry")
local Updater = require("vocabdeck_updater")

local Menu = {}

local function hasCurrentBook(plugin)
    return plugin:getDocumentFilePath() ~= nil
end

local function currentBookHasCards(plugin)
    local filepath = plugin:getDocumentFilePath()
    if not filepath then
        return false
    end
    local book_id = DB.findBookWithCardsByFilepath(filepath, plugin:getDocumentSourceLanguage(), true)
    return book_id ~= nil
end

local function getCurrentBookId(plugin)
    local filepath = plugin:getDocumentFilePath()
    if not filepath then
        return nil, _("Open a book first.")
    end

    local source_language = plugin:getDocumentSourceLanguage()
    local book_id = DB.findBookWithCardsByFilepath(filepath, source_language)
    if book_id then
        return book_id
    end

    if source_language and source_language ~= "" then
        DB.setLanguage(source_language)
    end
    book_id = DB.getOrCreateBook(plugin:getDocumentTitle(), filepath, source_language)
    if not book_id then
        return nil, _("Could not prepare book record.")
    end
    return book_id
end

function Menu.build(plugin, config_error, plugin_version)
    -- Build flat language items directly in the top-level menu.
    local study_items = StudyEntry.buildStudyMenuItems(plugin)
    local items = {}
    items[#items + 1] = {
        text = _("Dashboard"),
        callback = function()
            Dashboard.show(plugin)
        end,
        separator = true,
    }
    for _, item in ipairs(study_items) do
        items[#items + 1] = item
    end
    if StudyMore.hasAvailableStudyMore(plugin) then
        items[#items + 1] = {
            text = _("Study more"),
            sub_item_table_func = function()
                return StudyMore.buildMenuItems(plugin)
            end,
        }
    end
    items[#items + 1] = {
        text = _("All cards"),
        callback = function()
            EditModule.showList(plugin, nil, _("All cards"))
        end,
    }
    items[#items + 1] = {
        text = _("Cards for this book"),
        enabled_func = function() return currentBookHasCards(plugin) end,
        callback = function()
            local book_id, err = getCurrentBookId(plugin)
            if not book_id then
                UIManager:show(InfoMessage:new{ text = err or _("Could not open cards for this book."), timeout = 3 })
                return
            end
            EditModule.showList(plugin, book_id, plugin:getDocumentTitle())
        end,
    }
    items[#items + 1] = {
        text = _("Stats"),
        callback = function() plugin:showSummary() end,
    }
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Fetch missing info (this book)"),
        enabled_func = function() return currentBookHasCards(plugin) end,
        callback = function()
            local book_id, err = getCurrentBookId(plugin)
            if not book_id then
                UIManager:show(InfoMessage:new{ text = err or _("Could not prepare book record."), timeout = 3 })
                return
            end
            plugin:bulkFetchMissing(book_id)
        end,
    }
    items[#items + 1] = {
        text = _("Fetch missing info (all books)"),
        callback = function() plugin:bulkFetchMissing(nil) end,
    }
    items[#items + 1] = {
        text = _("Settings"),
        sub_item_table_func = function(touchmenu_instance)
            local sub_items = SettingsModule.buildMenuItems(plugin, touchmenu_instance)
            table.insert(sub_items, 1, {
                text = _("Import"),
                sub_item_table_func = function()
                    return Importer.buildImportMenuItems(plugin)
                end,
            })
            return sub_items
        end,
        separator = true,
    }
    for _, item in ipairs(SettingsModule.buildAiMenuItems(plugin)) do
        items[#items + 1] = item
    end
    if #items > 0 then
        items[#items].separator = true
    end
    items[#items + 1] = {
        text = _("Check for updates"),
        callback = function()
            Updater.check(plugin, plugin_version)
        end,
    }
    items[#items + 1] = {
        text = _("Diagnostics"),
        callback = function()
            Diagnostics.show(plugin, plugin_version, config_error)
        end,
    }
    items[#items + 1] = {
        text = _("About VocabDeck"),
        keep_menu_open = true,
        callback = function()
            local provider = plugin:getActiveProvider() or _("Not configured")
            local model = plugin.settings:readSetting("model_" .. provider)
            if not model or model == "" then
                model = plugin.querier and plugin.querier:isInited() and plugin.querier:getModel() or "-"
            end
            local cfg_status
            if plugin.CONFIGURATION then
                cfg_status = _("Loaded")
            elseif config_error then
                cfg_status = config_error
            else
                cfg_status = _("Not found")
            end
            local cards = DB.getCardCountForBook(nil)
            UIManager:show(InfoMessage:new{
                text = string.format(
                    _("VocabDeck %s\n\nSave words and phrases while reading, keep their book context, enrich missing definitions with AI, and review them with spaced repetition.\n\nCards: %s\nProvider: %s\nModel: %s\nConfig: %s"),
                    plugin_version, tostring(cards), provider, model, cfg_status
                ),
                timeout = 7,
            })
        end,
    }
    return items
end

return Menu
