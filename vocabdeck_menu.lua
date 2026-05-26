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
local StudyMore = require("vocabdeck_study_more")
local StudyEntry = require("vocabdeck_study_entry")
local Updater = require("vocabdeck_updater")

local Menu = {}

function Menu.build(plugin, config_error, plugin_version)
    local has_book = plugin:getDocumentFilePath() ~= nil

    -- Build study items eagerly so we can decide between direct callback and sub-menu.
    local study_items = StudyEntry.buildStudyMenuItems(plugin)
    local study_menu_item
    if #study_items == 1 and study_items[1].callback then
        -- Single language with due cards: start study directly, no sub-menu.
        study_menu_item = {
            text = study_items[1].text,
            callback = study_items[1].callback,
        }
    else
        -- Multiple languages or no due cards: show sub-menu.
        study_menu_item = {
            text = _("Study"),
            sub_item_table_func = function()
                return StudyEntry.buildStudyMenuItems(plugin)
            end,
        }
    end

    local items = {
        study_menu_item,
        {
            text = _("Study more"),
            enabled_func = function()
                return StudyMore.hasAvailableStudyMore(plugin)
            end,
            sub_item_table_func = function()
                return StudyMore.buildMenuItems(plugin)
            end,
        },
    }
    items[#items + 1] = {
        text = _("All cards"),
        callback = function()
            local filepath = plugin:getDocumentFilePath()
            if filepath then
                DB.getOrCreateBook(plugin:getDocumentTitle(), filepath, plugin:getDocumentSourceLanguage())
            end
            EditModule.showList(plugin, nil, _("All cards"))
        end,
    }
    items[#items + 1] = {
        text = _("Cards for this book"),
        enabled_func = function() return has_book end,
        callback = function()
            local filepath = plugin:getDocumentFilePath()
            if not filepath then return end
            local book_id = DB.getOrCreateBook(plugin:getDocumentTitle(), filepath, plugin:getDocumentSourceLanguage())
            EditModule.showList(plugin, book_id, plugin:getDocumentTitle())
        end,
    }
    items[#items + 1] = {
        text = _("Add new card"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            plugin:addManualCard(touchmenu_instance)
        end,
    }
    items[#items + 1] = {
        text = _("Stats"),
        callback = function() plugin:showSummary() end,
    }
    items[#items].separator = true
    items[#items + 1] = {
        text = _("Fetch missing info (this book)"),
        enabled_func = function() return has_book end,
        callback = function()
            local filepath = plugin:getDocumentFilePath()
            if not filepath then return end
            local book_id = DB.getOrCreateBook(plugin:getDocumentTitle(), filepath, plugin:getDocumentSourceLanguage())
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
                text = _("Import from Vocabulary Builder"),
                enabled_func = function() return has_book end,
                callback = function()
                    Importer.showImportDialog(plugin)
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
        keep_menu_open = true,
        callback = function()
            Updater.check(plugin, plugin_version)
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
