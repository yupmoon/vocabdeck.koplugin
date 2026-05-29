-- VocabDeck plugin entry point.
--
-- Responsibilities:
--   * Plugin lifecycle (init / onReaderReady / onFlushSettings).
--   * Injecting the "VocabDeck" action into the highlight menu and the
--     dictionary popup.
--   * Registering the main menu under the `tools` sorting hint.
--   * Instantiating the AI querier from vocabdeck_configuration.lua.
local _ = require("gettext")
local DataStorage = require("datastorage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local koutil = require("util")

local DB = require("vocabdeck_db")
local Bulk = require("vocabdeck_bulk")
local MenuBuilder = require("vocabdeck_menu")
local Querier = require("vocabdeck_ai")
local Stats = require("vocabdeck_stats")
local Config = require("vocabdeck_config")
local Context = require("vocabdeck_context")
local Add = require("vocabdeck_add")
local Define = require("vocabdeck_define")
local StudyEntry = require("vocabdeck_study_entry")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/vocabdeck.lua"
local PLUGIN_VERSION = "1.0.0"

local CONFIGURATION, CONFIG_ERROR = Config.load()

-- ── Plugin definition ────────────────────────────────────────────────────

local VocabDeck = InputContainer:extend{
    name = "vocabdeck",
    is_doc_only = false,
    CONFIGURATION = nil,
    settings = nil,
    querier = nil,
}

Context.install(VocabDeck)
Add.install(VocabDeck)
Define.install(VocabDeck)
StudyEntry.install(VocabDeck)

function VocabDeck:readSetting(key, default)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    local val = self.settings:readSetting(key)
    if val == nil then return default end
    return val
end

function VocabDeck:saveSetting(key, value)
    if not self.settings then
        self.settings = LuaSettings:open(SETTINGS_FILE)
    end
    self.settings:saveSetting(key, value)
    -- Flush is deferred to onFlushSettings (called periodically by KOReader)
    -- to avoid unnecessary flash write cycles on e-ink devices.
end

function VocabDeck:onFlushSettings()
    if self.settings then
        self.settings:flush()
    end
end

function VocabDeck:getDefaultProvider()
    local config = self.CONFIGURATION
    if not config then return nil end
    if config.provider and koutil.tableGetValue(config, "provider_settings", config.provider) then
        return config.provider
    end
    if type(config.provider_settings) == "table" then
        for name, _settings in pairs(config.provider_settings) do
            return name
        end
    end
    return nil
end

function VocabDeck:getActiveProvider()
    return self.settings:readSetting("provider") or self:getDefaultProvider()
end

function VocabDeck:ensureAIProviderLoaded()
    if not self.querier then
        return false, _("Configure vocabdeck_configuration.lua with a valid AI provider first.")
    end
    local provider = self:getActiveProvider()
    if not provider or provider == "" then
        return false, _("Configure vocabdeck_configuration.lua with a valid AI provider first.")
    end
    if self.querier.provider_name == provider and self.querier:isInited() then
        return true
    end
    local ok, err = self.querier:loadProvider(provider)
    if not ok then
        return false, err or _("Configure vocabdeck_configuration.lua with a valid AI provider first.")
    end
    return true
end

-- ── Bulk operations ──────────────────────────────────────────────────────

function VocabDeck:bulkFetchMissing(book_id, on_finished)
    return Bulk.fetchMissing(self, book_id, on_finished)
end

function VocabDeck:showSummary()
    Stats.show(self)
end

-- ── Menu ─────────────────────────────────────────────────────────────────

function VocabDeck:addToMainMenu(menu_items)
    menu_items.vocabdeck = {
        sorting_hint = "tools",
        text = _("VocabDeck"),
        sub_item_table_func = function() return self:_buildMenu() end,
    }
end

function VocabDeck:_buildMenu()
    return MenuBuilder.build(self, CONFIG_ERROR, PLUGIN_VERSION)
end

-- ── Lifecycle ────────────────────────────────────────────────────────────

function VocabDeck:init()
    DB.init()
    self.settings = LuaSettings:open(SETTINGS_FILE)
    if self.settings:readSetting("card_list_sort") == nil then
        self.settings:saveSetting("card_list_sort", "added")
    end
    if self.settings:readSetting("card_list_sort_dir") == nil then
        self.settings:saveSetting("card_list_sort_dir", "desc")
    end
    self.settings:flush()
    self.CONFIGURATION = CONFIGURATION

    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Load AI provider lazily so the plugin still works if the configuration
    -- is missing (adding cards without AI).
    if CONFIGURATION then
        self.querier = Querier:new{ plugin = self }
    end
end

function VocabDeck:onReaderReady()
    if not self.ui then return end

    -- Highlight menu entry.
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        self.ui.highlight:addToHighlightDialog("vocabdeck_add", function(reader_highlight)
            return {
                text = _("Add to VD"),
                callback = function()
                    self:addFromHighlight(reader_highlight)
                end,
            }
        end)
        self.ui.highlight:addToHighlightDialog("vocabdeck_add_ai", function(reader_highlight)
            return {
                text = _("Add to VD (Enriched)"),
                callback = function()
                    self:addWithAIFromHighlight(reader_highlight)
                end,
            }
        end)
        self.ui.highlight:addToHighlightDialog("vocabdeck_define", function(reader_highlight)
            return {
                text = _("Define (VD)"),
                callback = function()
                    self:defineFromHighlight(reader_highlight)
                end,
            }
        end)
    end
end

-- Dictionary popup integration. The DictButtonsReady event is fired by
-- dictquicklookup.lua as it assembles its action rows. `dict_buttons` is a
-- 2-D array (rows of buttons), so we inject a new row holding the VocabDeck
-- button just below the built-in row.
function VocabDeck:onDictButtonsReady(dict_popup, dict_buttons)
    if not dict_popup or type(dict_buttons) ~= "table" then return end
    local row = {
        {
            id = "vocabdeck_add",
            text = _("Add to VD"),
            font_bold = true,
            callback = function()
                self:addFromDictionary(dict_popup)
            end,
        },
        {
            id = "vocabdeck_add_ai",
            text = _("VD +AI"),
            callback = function()
                self:addWithAIFromDictionary(dict_popup)
            end,
        },
        {
            id = "vocabdeck_define",
            text = _("Define (VD)"),
            callback = function()
                self:defineFromDictionary(dict_popup)
            end,
        },
    }
    local insert_index = #dict_buttons > 1 and 2 or 1
    table.insert(dict_buttons, insert_index, row)
end

return VocabDeck
