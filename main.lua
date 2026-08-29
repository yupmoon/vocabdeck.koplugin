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
local DICT_BUTTON_IDS = {
    "vocabdeck_add",
    "vocabdeck_add_ai",
    "vocabdeck_define",
}
local DICT_BUTTON_ID_SET = {}
for _, id in ipairs(DICT_BUTTON_IDS) do
    DICT_BUTTON_ID_SET[id] = true
end

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

local function buildDictionaryButtonSpecs(plugin)
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

-- Normalize the final button table as a compatibility guard. KOReader 2026.07
-- normally honors row_group while building its transient rows, but some builds
-- still return each registered action as a separate row. Working on the final
-- button objects makes the intended three-column row explicit in either case.
local function groupDictionaryButtons(button_rows)
    if type(button_rows) ~= "table" then return end

    local rebuilt_rows = {}
    local grouped_buttons = {}
    local insert_index

    for _, row in ipairs(button_rows) do
        if type(row) == "table" then
            local remaining_buttons = {}
            local found_vocabdeck_button = false
            for _, button in ipairs(row) do
                local id = type(button) == "table" and button.id or button
                if DICT_BUTTON_ID_SET[id] then
                    grouped_buttons[id] = grouped_buttons[id] or button
                    found_vocabdeck_button = true
                else
                    remaining_buttons[#remaining_buttons + 1] = button
                end
            end
            if found_vocabdeck_button and not insert_index then
                insert_index = #rebuilt_rows + 1
            end
            if #remaining_buttons > 0 then
                rebuilt_rows[#rebuilt_rows + 1] = remaining_buttons
            end
        else
            rebuilt_rows[#rebuilt_rows + 1] = row
        end
    end

    local grouped_row = {}
    for _, id in ipairs(DICT_BUTTON_IDS) do
        if grouped_buttons[id] then
            grouped_row[#grouped_row + 1] = grouped_buttons[id]
        end
    end
    if #grouped_row < 2 then return end

    table.insert(rebuilt_rows, math.min(insert_index, #rebuilt_rows + 1), grouped_row)
    for i = #button_rows, 1, -1 do
        button_rows[i] = nil
    end
    for i, row in ipairs(rebuilt_rows) do
        button_rows[i] = row
    end
end

local function installDictionaryButtonRowGuard()
    local loaded, DictQuickLookup = pcall(require, "ui/widget/dictquicklookup")
    if not loaded or type(DictQuickLookup.buildButtonLayout) ~= "function" then
        return false
    end
    if DictQuickLookup._vocabdeck_button_row_guard then
        return true
    end

    local original_build_button_layout = DictQuickLookup.buildButtonLayout
    DictQuickLookup.buildButtonLayout = function(dict_popup, ...)
        local button_rows = original_build_button_layout(dict_popup, ...)
        groupDictionaryButtons(button_rows)
        return button_rows
    end
    DictQuickLookup._vocabdeck_button_row_guard = true
    return true
end

-- KOReader 2026.07+ uses a registry instead of broadcasting
-- DictButtonsReady while constructing each dictionary popup.
function VocabDeck:registerDictionaryButtons()
    local dictionary = self.ui and self.ui.dictionary
    if not dictionary or type(dictionary.addToDictButtons) ~= "function" then
        return false
    end
    installDictionaryButtonRowGuard()
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
