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
local Dispatcher = require("dispatcher")
local InputContainer = require("ui/widget/container/inputcontainer")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local koutil = require("util")

local DB = require("vocabdeck_db")
local Bulk = require("vocabdeck_bulk")
local Dashboard = require("vocabdeck_dashboard")
local MenuBuilder = require("vocabdeck_menu")
local Querier = require("vocabdeck_ai")
local Stats = require("vocabdeck_stats")
local Config = require("vocabdeck_config")
local Context = require("vocabdeck_context")
local Add = require("vocabdeck_add")
local Define = require("vocabdeck_define")
local Grammar = require("vocabdeck_grammar")
local StudyEntry = require("vocabdeck_study_entry")

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/vocabdeck.lua"
local PLUGIN_VERSION = "1.2.4"
local DICT_BUTTON_ROW_GROUP = "vocabdeck_actions"

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
Grammar.install(VocabDeck)
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

-- Online, behave like "Define (VD)" (fetch an AI definition first); offline,
-- fall back to the plain "Add to VD" flow instead of attempting AI at all.
local function vocabDeckDefinitionFromDictionary(plugin, dict_popup)
    local NetworkMgr = require("ui/network/manager")
    if type(NetworkMgr.isWifiOn) == "function" and not NetworkMgr:isWifiOn() then
        plugin:addFromDictionary(dict_popup)
    else
        plugin:defineFromDictionary(dict_popup)
    end
end

local function buildDictionaryButtonSpecs(plugin)
    if plugin:readSetting("unified_dict_button", true) then
        return {
            {
                id = "vocabdeck_definition",
                text = _("VocabDeck Definition"),
                font_bold = true,
                conditional = true,
                row_group = DICT_BUTTON_ROW_GROUP,
                callback = function(dict_popup)
                    vocabDeckDefinitionFromDictionary(plugin, dict_popup)
                end,
            },
        }
    end
    return {
        {
            id = "vocabdeck_add",
            text = _("Add to VD"),
            font_bold = true,
            conditional = true,
            row_group = DICT_BUTTON_ROW_GROUP,
            callback = function(dict_popup)
                plugin:addFromDictionary(dict_popup)
            end,
        },
        {
            id = "vocabdeck_add_ai",
            text = _("VD +AI"),
            conditional = true,
            row_group = DICT_BUTTON_ROW_GROUP,
            callback = function(dict_popup)
                plugin:addWithAIFromDictionary(dict_popup)
            end,
        },
        {
            id = "vocabdeck_define",
            text = _("Define (VD)"),
            conditional = true,
            row_group = DICT_BUTTON_ROW_GROUP,
            callback = function(dict_popup)
                plugin:defineFromDictionary(dict_popup)
            end,
        },
    }
end

-- KOReader 2026.07+ uses a registry instead of broadcasting
-- DictButtonsReady while constructing each dictionary popup.
function VocabDeck:registerDictionaryButtons()
    local dictionary = self.ui and self.ui.dictionary
    if not dictionary or type(dictionary.addToDictButtons) ~= "function" then
        return false
    end
    if self._dict_buttons_registered_on == dictionary then
        return true
    end
    for _, spec in ipairs(buildDictionaryButtonSpecs(self)) do
        dictionary:addToDictButtons(spec)
    end
    self._dict_buttons_registered_on = dictionary
    return true
end

function VocabDeck:onDispatcherRegisterActions()
    Dispatcher:registerAction("vocabdeck_dashboard", {
        category = "none",
        event = "VocabDeckDashboard",
        title = _("VocabDeck: Dashboard"),
        general = true,
    })
end

function VocabDeck:onVocabDeckDashboard()
    Dashboard.show(self)
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
    self:registerDictionaryButtons()
    self:onDispatcherRegisterActions()

    if CONFIGURATION then
        self.querier = Querier:new{ plugin = self }
    end
end

function VocabDeck:onReaderReady()
    if not self.ui then return end

    -- Normally registered during init; retry here in case ReaderDictionary was
    -- not available yet. Re-registration on the same instance is a no-op.
    self:registerDictionaryButtons()

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
        self.ui.highlight:addToHighlightDialog("vocabdeck_grammar", function(reader_highlight)
            return {
                text = _("Grammar (VD)"),
                callback = function()
                    self:grammarFromHighlight(reader_highlight)
                end,
            }
        end)
    end
end

-- Legacy dictionary popup integration for KOReader versions predating the
-- addToDictButtons registry. `dict_buttons` is a 2-D array (rows of buttons),
-- so we inject a VocabDeck row just below the built-in row.
function VocabDeck:onDictButtonsReady(dict_popup, dict_buttons)
    local dictionary = self.ui and self.ui.dictionary
    if dictionary and self._dict_buttons_registered_on == dictionary then return end
    if not dict_popup or type(dict_buttons) ~= "table" then return end
    local row = {}
    for _, spec in ipairs(buildDictionaryButtonSpecs(self)) do
        row[#row + 1] = {
            id = spec.id,
            text = spec.text,
            font_bold = spec.font_bold,
            callback = function()
                spec.callback(dict_popup)
            end,
        }
    end
    local insert_index = #dict_buttons > 1 and 2 or 1
    table.insert(dict_buttons, insert_index, row)
end

return VocabDeck
