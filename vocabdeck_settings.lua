-- VocabDeck settings menu helpers.
--
-- Most settings are stored on `plugin.settings` (a LuaSettings instance on the
-- plugin itself). The main KOReader menu uses native submenus.
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local koutil = require("util")
local ApiKeys = require("vocabdeck_apikeys_loader")
local ProviderCatalog = require("vocabdeck_provider_catalog")
local CardFields = require("vocabdeck_card_fields")
local DB = require("vocabdeck_db")
local StudyMore = require("vocabdeck_study_more")
local TextUtils = require("vocabdeck_text_utils")

local Settings = {}

-- ── Sub-dialog helpers ───────────────────────────────────────────────────

local function listProviders(plugin)
    local config = plugin.CONFIGURATION
    if not config or type(config.provider_settings) ~= "table" then
        return {}
    end
    local names = {}
    for name, settings_table in pairs(config.provider_settings) do
        if type(settings_table) == "table" and settings_table.visible ~= false then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

local function getProviderConfig(plugin, provider)
    return koutil.tableGetValue(plugin.CONFIGURATION or {}, "provider_settings", provider) or {}
end

local function providerLabel(provider)
    return ProviderCatalog.getLabel(provider)
end

local function getCurrentProvider(plugin)
    return plugin.settings:readSetting("provider") or plugin:getDefaultProvider()
end

local function getDefaultModel(provider)
    if not provider then return nil end
    return ProviderCatalog.getDefaultModel(provider)
end

local function getProviderModel(plugin, provider)
    if not provider then return "-" end
    local saved = plugin.settings:readSetting("model_" .. provider)
    if saved and saved ~= "" then return saved end
    local configured = getProviderConfig(plugin, provider).model
    if configured and configured ~= "" then return configured end
    local default_model = getDefaultModel(provider)
    if default_model and default_model ~= "" then return default_model end
    return "-"
end

local function getModelOptions(plugin, provider)
    local options = ProviderCatalog.getModelOptions(provider)
    local list = {}
    if options then
        for _, model in ipairs(options) do
            list[#list + 1] = model
        end
    end
    local current = getProviderModel(plugin, provider)
    local found_current = false
    for _, model in ipairs(list) do
        if model == current then
            found_current = true
            break
        end
    end
    if current and current ~= "-" and not found_current then
        table.insert(list, 1, current)
    end
    return list
end

local function apiKeyStatus(plugin, provider)
    if not provider then return "-" end
    if ApiKeys.has(provider) then return _("File") end
    local saved = plugin.settings:readSetting("api_key_" .. provider)
    if saved and saved ~= "" then return _("Set") end
    local configured = getProviderConfig(plugin, provider).api_key
    if configured and configured ~= "" then return _("File") end
    if provider == "ollama" then return _("Optional") end
    return _("Missing")
end

local function invalidateLoadedProvider(plugin)
    if plugin.querier then
        plugin.querier.handler = nil
        plugin.querier.handler_name = nil
        plugin.querier.provider_settings = nil
        plugin.querier.provider_name = nil
    end
end

local function closeInputDialog(input_dialog)
    if input_dialog then
        if input_dialog.onCloseKeyboard then
            input_dialog:onCloseKeyboard()
        end
        UIManager:close(input_dialog)
        UIManager:setDirty(nil, "ui")
    end
end

local function showApiKeyInput(plugin, provider)
    local input_dialog
    local from_file = ApiKeys.has(provider)
    local configured = getProviderConfig(plugin, provider).api_key
    local description
    if from_file then
        description = _("A key is loaded from vocabdeck_apikeys.lua. Saving here will store a KOReader setting fallback.")
    elseif configured and configured ~= "" then
        description = _("A key is present in vocabdeck_configuration.lua. Saving here will store a KOReader setting fallback.")
    else
        description = string.format(_("Enter API key for %s."), providerLabel(provider))
    end
    input_dialog = InputDialog:new{
        title = string.format(_("API key: %s"), providerLabel(provider)),
        description = description,
        input = plugin.settings:readSetting("api_key_" .. provider) or "",
        input_hint = _("API key"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() closeInputDialog(input_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local key = TextUtils.trim(input_dialog:getInputText() or "")
                    closeInputDialog(input_dialog)
                    plugin.settings:saveSetting("api_key_" .. provider, key)
                    plugin.settings:flush()
                    if plugin.querier and plugin.querier.provider_name == provider
                        and plugin.querier.provider_settings then
                        plugin.querier.provider_settings.api_key = key
                    end
                    UIManager:show(InfoMessage:new{
                        text = key ~= "" and _("API key saved.") or _("API key cleared."),
                        timeout = 2,
                    })
                end,
            },
        } },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function showNumberInput(title, description, current, min_value, on_save)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        description = description,
        input = tostring(current),
        input_type = "number",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() closeInputDialog(input_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = tonumber(input_dialog:getInputText()) or current
                    if min_value and value < min_value then value = min_value end
                    closeInputDialog(input_dialog)
                    on_save(value)
                end,
            },
        } },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

local function showTextInput(title, description, current, on_save)
    local input_dialog
    input_dialog = InputDialog:new{
        title = title,
        description = description,
        input = current or "",
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() closeInputDialog(input_dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local text = TextUtils.trim(input_dialog:getInputText() or "")
                    closeInputDialog(input_dialog)
                    on_save(text)
                end,
            },
        } },
    }
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

-- ── Main entry point ─────────────────────────────────────────────────────

-- Trim a long mandatory string so it never eats into the item's text column,
-- which would trigger a "width must be strictly positive" paint error on
-- narrow screens. We cap to 28 visible characters.
local function shortMandatory(str)
    str = tostring(str or "")
    if #str <= 28 then return str end
    return str:sub(1, 26) .. "…"
end

local function rowValue(label, value)
    return string.format("%s → %s", label, tostring(value or ""))
end

local function readBool(plugin, key, default)
    local v = plugin.settings:readSetting(key)
    if v == nil then return default end
    return v and true or false
end

local function boolRowValue(plugin, key, default, label)
    return rowValue(label, readBool(plugin, key, default) and _("On") or _("Off"))
end

local LEECH_ACTION_LABELS = {
    tag = _("Tag only"),
    suspend = _("Suspend card"),
}

local function getLeechAction(plugin)
    local value = plugin.settings:readSetting("leech_action", "tag")
    if value ~= "suspend" then
        value = "tag"
    end
    return value
end

local goBackFromSubmenu
local appendBackItem

local function makeLeechActionItems(plugin, parent_menu_instance)
    local actions = {
        { key = "tag", label = LEECH_ACTION_LABELS.tag },
        { key = "suspend", label = LEECH_ACTION_LABELS.suspend },
    }
    local items = {}
    for _, action in ipairs(actions) do
        items[#items + 1] = {
            text = action.label,
            checked_func = function()
                return getLeechAction(plugin) == action.key
            end,
            callback = function()
                plugin.settings:saveSetting("leech_action", action.key)
                plugin.settings:flush()
            end,
        }
    end
    return appendBackItem(items, parent_menu_instance)
end

local function makeRefreshable(items, plugin)
    items.needs_refresh = true
    items.refresh_func = function()
        return Settings.buildMenuItems(plugin)
    end
    return items
end

local function makeProviderItems(plugin, parent_menu_instance)
    local items = {}
    local providers = listProviders(plugin)
    if #providers == 0 then
        items[#items + 1] = {
            text = _("No providers are configured."),
            enabled = false,
        }
        return parent_menu_instance and appendBackItem(items, parent_menu_instance) or items
    end
    for _, name in ipairs(providers) do
        items[#items + 1] = {
            text = providerLabel(name),
            checked_func = function()
                return name == getCurrentProvider(plugin)
            end,
            callback = function(touchmenu_instance)
                plugin.settings:saveSetting("provider", name)
                local saved_model = plugin.settings:readSetting("model_" .. name)
                if not saved_model or saved_model == "" then
                    local configured = getProviderConfig(plugin, name).model
                    local default_model = (configured and configured ~= "") and configured or getDefaultModel(name)
                    if default_model and default_model ~= "" then
                        plugin.settings:saveSetting("model_" .. name, default_model)
                    end
                end
                UIManager:nextTick(function()
                    plugin.settings:flush()
                    invalidateLoadedProvider(plugin)
                end)
            end,
        }
    end
    return parent_menu_instance and appendBackItem(items, parent_menu_instance) or items
end

local function makeModelItems(plugin, provider, parent_menu_instance)
    local items = {}
    if not provider then
        items[#items + 1] = { text = _("No provider selected."), enabled = false }
        return parent_menu_instance and appendBackItem(items, parent_menu_instance) or items
    end
    local models = getModelOptions(plugin, provider)
    if #models == 0 then
        items[#items + 1] = { text = _("No model list is available for this provider."), enabled = false }
        return parent_menu_instance and appendBackItem(items, parent_menu_instance) or items
    end
    for _, model in ipairs(models) do
        items[#items + 1] = {
            text = model,
            checked_func = function()
                return model == getProviderModel(plugin, provider)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                plugin.settings:saveSetting("model_" .. provider, model)
                plugin.settings:flush()
                if provider == getCurrentProvider(plugin) then
                    invalidateLoadedProvider(plugin)
                end
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return parent_menu_instance and appendBackItem(items, parent_menu_instance) or items
end

function goBackFromSubmenu(menu_instance)
    if menu_instance and menu_instance.backToUpperMenu then
        menu_instance:backToUpperMenu()
    elseif menu_instance and menu_instance.onClose then
        menu_instance:onClose()
    end
end

function appendBackItem(items, parent_menu_instance)
    items[#items + 1] = {
        text = _("Back"),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            goBackFromSubmenu(touchmenu_instance or parent_menu_instance)
        end,
    }
    return items
end

local function makeFieldItems(plugin, side, parent_menu_instance)
    local items = {}
    for _idx, f in ipairs(CardFields.FIELD_LABELS) do
        local key = f.key
        items[#items + 1] = {
            text = f.label,
            checked_func = function()
                return CardFields.getFieldState(plugin, side)[key] == true
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local state = CardFields.getFieldState(plugin, side)
                state[key] = not state[key]
                CardFields.setFieldState(plugin, side, state)
                if touchmenu_instance then touchmenu_instance:updateItems() end
            end,
        }
    end
    return appendBackItem(items, parent_menu_instance)
end

local function makeProviderMenuItem(plugin, add_back_row)
    return {
        text = _("Provider"),
        text_func = function()
            return string.format(_("Provider: %s"), providerLabel(getCurrentProvider(plugin)))
        end,
        sub_item_table_func = function(parent_menu_instance)
            return makeProviderItems(plugin, add_back_row and parent_menu_instance or nil)
        end,
    }
end

local function makeModelMenuItem(plugin, add_back_row)
    return {
        text = _("Model"),
        text_func = function()
            local provider = getCurrentProvider(plugin)
            return string.format(_("Model: %s"), getProviderModel(plugin, provider))
        end,
        sub_item_table_func = function(parent_menu_instance)
            return makeModelItems(plugin, getCurrentProvider(plugin), add_back_row and parent_menu_instance or nil)
        end,
    }
end

local function makeApiKeyMenuItem(plugin)
    return {
        text = _("API Key"),
        text_func = function()
            local provider = getCurrentProvider(plugin)
            return string.format(_("API Key: %s"), providerLabel(provider))
        end,
        mandatory = shortMandatory(apiKeyStatus(plugin, getCurrentProvider(plugin))),
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local provider = getCurrentProvider(plugin)
            if not provider then
                UIManager:show(InfoMessage:new{
                    text = _("Select an AI provider first."),
                    timeout = 2,
                })
                return
            end
            showApiKeyInput(plugin, provider)
        end,
    }
end

local function makeAiContextWordsMenuItem(plugin)
    return {
        text = _("AI context words"),
        text_func = function()
            return rowValue(_("AI context words"), tonumber(plugin.settings:readSetting("ai_context_words", 15)) or 15)
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            local current = tonumber(plugin.settings:readSetting("ai_context_words", 15)) or 15
            showNumberInput(
                _("AI context words"),
                _("Number of words around the selection that will be sent to the AI as context. 0 = only the selected word or phrase."),
                current, 0,
                function(value)
                    plugin.settings:saveSetting("ai_context_words", value)
                    plugin.settings:flush()
                    if touchmenu_instance and touchmenu_instance.updateItems then
                        touchmenu_instance:updateItems()
                    end
                end
            )
        end,
    }
end

local function makeBackupItems(parent_menu_instance)
    local items = {
        {
            text = _("Backup cards now"),
            keep_menu_open = true,
            callback = function()
                local ok, message = DB.backupCards()
                UIManager:show(InfoMessage:new{
                    text = ok
                        and string.format(_("VocabDeck backup saved:\n%s"), message)
                        or message,
                    timeout = ok and 3 or 5,
                })
            end,
        },
        {
            text = _("Recover cards from backup"),
            keep_menu_open = true,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Replace the current VocabDeck cards with the saved backup?"),
                    ok_text = _("Recover"),
                    ok_callback = function()
                        local ok, message = DB.restoreCardsBackup()
                        UIManager:show(InfoMessage:new{
                            text = ok
                                and string.format(_("VocabDeck cards recovered from:\n%s"), message)
                                or message,
                            timeout = ok and 3 or 5,
                        })
                    end,
                })
            end,
        },
    }
    return appendBackItem(items, parent_menu_instance)
end

local function makeAutoRateItems(plugin, refreshMenu, touchmenu_instance)
    local items = {
        {
            text = _("Enable auto-rate"),
            text_func = function()
                return boolRowValue(plugin, "auto_rate_enabled", false, _("Enable auto-rate"))
            end,
            checked_func = function()
                return readBool(plugin, "auto_rate_enabled", false)
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = readBool(plugin, "auto_rate_enabled", false)
                plugin.settings:saveSetting("auto_rate_enabled", not current)
                plugin.settings:flush()
                refreshMenu(submenu_instance or touchmenu_instance)
            end,
        },
        {
            text = _("Easy cutoff"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("auto_rate_easy_cutoff", 5)) or 5
                return rowValue(_("Easy cutoff"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("auto_rate_easy_cutoff", 5)) or 5
                showNumberInput(
                    _("Auto-rate Easy cutoff"),
                    _("Recall time in seconds for automatic Easy."),
                    current, 1,
                    function(value)
                        value = math.floor((tonumber(value) or 5) + 0.5)
                        plugin.settings:saveSetting("auto_rate_easy_cutoff", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Good cutoff"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("auto_rate_good_cutoff", 10)) or 10
                return rowValue(_("Good cutoff"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("auto_rate_good_cutoff", 10)) or 10
                showNumberInput(
                    _("Auto-rate Good cutoff"),
                    _("Recall time in seconds for automatic Good. Values below Easy are treated as Easy."),
                    current, 1,
                    function(value)
                        value = math.floor((tonumber(value) or 10) + 0.5)
                        plugin.settings:saveSetting("auto_rate_good_cutoff", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Hard cutoff"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("auto_rate_hard_cutoff", 25)) or 25
                return rowValue(_("Hard cutoff"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("auto_rate_hard_cutoff", 25)) or 25
                showNumberInput(
                    _("Auto-rate Hard cutoff"),
                    _("Recall time in seconds for automatic Hard. Longer recalls stay manual."),
                    current, 1,
                    function(value)
                        value = math.floor((tonumber(value) or 25) + 0.5)
                        plugin.settings:saveSetting("auto_rate_hard_cutoff", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Answer delay"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("auto_rate_answer_delay", 4)) or 4
                return rowValue(_("Answer delay"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("auto_rate_answer_delay", 4)) or 4
                showNumberInput(
                    _("Auto-rate answer delay"),
                    _("Seconds to stay on the answer side before automatic rating. 0 = immediately."),
                    current, 0,
                    function(value)
                        value = math.floor((tonumber(value) or 4) + 0.5)
                        plugin.settings:saveSetting("auto_rate_answer_delay", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
    }
    return appendBackItem(items, touchmenu_instance)
end

local function makeManualAdvanceItems(plugin, refreshMenu, touchmenu_instance)
    local items = {
        {
            text = _("Again advance delay"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("manual_again_advance_delay", 5)) or 5
                return rowValue(_("Again advance delay"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("manual_again_advance_delay", 5)) or 5
                showNumberInput(
                    _("Again advance delay"),
                    _("Seconds to stay on the answer side after manually rating Again."),
                    current, 0,
                    function(value)
                        value = math.floor((tonumber(value) or 5) + 0.5)
                        plugin.settings:saveSetting("manual_again_advance_delay", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Hard advance delay"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("manual_hard_advance_delay", 4)) or 4
                return rowValue(_("Hard advance delay"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("manual_hard_advance_delay", 4)) or 4
                showNumberInput(
                    _("Hard advance delay"),
                    _("Seconds to stay on the answer side after manually rating Hard."),
                    current, 0,
                    function(value)
                        value = math.floor((tonumber(value) or 4) + 0.5)
                        plugin.settings:saveSetting("manual_hard_advance_delay", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Good advance delay"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("manual_good_advance_delay", 3)) or 3
                return rowValue(_("Good advance delay"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("manual_good_advance_delay", 3)) or 3
                showNumberInput(
                    _("Good advance delay"),
                    _("Seconds to stay on the answer side after manually rating Good."),
                    current, 0,
                    function(value)
                        value = math.floor((tonumber(value) or 3) + 0.5)
                        plugin.settings:saveSetting("manual_good_advance_delay", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Easy advance delay"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("manual_easy_advance_delay", 2)) or 2
                return rowValue(_("Easy advance delay"), string.format(_("%ds"), value))
            end,
            keep_menu_open = true,
            callback = function(submenu_instance)
                local current = tonumber(plugin.settings:readSetting("manual_easy_advance_delay", 2)) or 2
                showNumberInput(
                    _("Easy advance delay"),
                    _("Seconds to stay on the answer side after manually rating Easy."),
                    current, 0,
                    function(value)
                        value = math.floor((tonumber(value) or 2) + 0.5)
                        plugin.settings:saveSetting("manual_easy_advance_delay", value)
                        plugin.settings:flush()
                        refreshMenu(submenu_instance or touchmenu_instance)
                    end
                )
            end,
        },
    }
    return appendBackItem(items, touchmenu_instance)
end

function Settings.buildAiMenuItems(plugin, add_back_rows)
    return {
        makeProviderMenuItem(plugin, add_back_rows),
        makeModelMenuItem(plugin, add_back_rows),
        makeApiKeyMenuItem(plugin),
        makeAiContextWordsMenuItem(plugin),
    }
end

function Settings.buildFullMenuItems(plugin, default_touchmenu_instance, trailing_items)
    local items = {}
    for _, item in ipairs(Settings.buildMenuItems(plugin, default_touchmenu_instance)) do
        items[#items + 1] = item
    end
    if trailing_items then
        for _, item in ipairs(trailing_items) do
            items[#items + 1] = item
        end
    end
    for _, item in ipairs(Settings.buildAiMenuItems(plugin, true)) do
        items[#items + 1] = item
    end
    return items
end

function Settings.buildMenuItems(plugin, default_touchmenu_instance)
    local daily_limit = tonumber(plugin.settings:readSetting("daily_new_cards_limit", 20)) or 20
    local daily_review_limit = tonumber(plugin.settings:readSetting("daily_review_cards_limit", 200)) or 200
    local retention_percent = tonumber(plugin.settings:readSetting("desired_retention_percent", 90)) or 90
    local study_more_settings = StudyMore.buildSettingsItems(plugin)

    local function refreshMenu(touchmenu_instance)
        touchmenu_instance = touchmenu_instance or default_touchmenu_instance
        if touchmenu_instance and touchmenu_instance.updateItems then
            touchmenu_instance:updateItems()
        end
    end

    return makeRefreshable({
        {
            text = _("Target language"),
            text_func = function()
                return rowValue(_("Target language"), shortMandatory(plugin.settings:readSetting("target_language", "English") or "English"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = plugin.settings:readSetting("target_language", "English") or "English"
                showTextInput(
                    _("Target language"),
                    _("Language used for meanings generated by the AI (e.g. Turkish, English, German)."),
                    current,
                    function(value)
                        if value == "" then value = "English" end
                        plugin.settings:saveSetting("target_language", value)
                        plugin.settings:flush()
                        refreshMenu(touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Display context words"),
            text_func = function()
                return rowValue(_("Display context words"), tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15
                showNumberInput(
                    _("Display context words"),
                    _("Words around the word or phrase stored for display on cards. 0 = hide."),
                    current, 0,
                    function(value)
                        plugin.settings:saveSetting("display_context_words", value)
                        plugin.settings:flush()
                        refreshMenu(touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Prompt to edit word/phrase before saving"),
            text_func = function()
                return boolRowValue(plugin, "ask_phrase_edit_on_add", true, _("Prompt to edit word/phrase before saving"))
            end,
            checked_func = function()
                return readBool(plugin, "ask_phrase_edit_on_add", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "ask_phrase_edit_on_add", true)
                plugin.settings:saveSetting("ask_phrase_edit_on_add", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Prompt for note before saving"),
            text_func = function()
                return boolRowValue(plugin, "ask_note_on_add", true, _("Prompt for note before saving"))
            end,
            checked_func = function()
                return readBool(plugin, "ask_note_on_add", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "ask_note_on_add", true)
                plugin.settings:saveSetting("ask_note_on_add", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Grammar helper"),
            text_func = function()
                return boolRowValue(plugin, "grammar_helper_enabled", false, _("Grammar helper"))
            end,
            checked_func = function()
                return readBool(plugin, "grammar_helper_enabled", false)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "grammar_helper_enabled", false)
                plugin.settings:saveSetting("grammar_helper_enabled", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Backup and recover"),
            sub_item_table_func = function(touchmenu_instance)
                return makeBackupItems(touchmenu_instance)
            end,
        },
        {
            text = _("Show answer timer in study"),
            text_func = function()
                return boolRowValue(plugin, "study_timer_enabled", true, _("Show answer timer in study"))
            end,
            checked_func = function()
                return readBool(plugin, "study_timer_enabled", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "study_timer_enabled", true)
                plugin.settings:saveSetting("study_timer_enabled", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Study reverse (meaning → phrase)"),
            text_func = function()
                return boolRowValue(plugin, "study_reverse", false, _("Study reverse (meaning → phrase)"))
            end,
            checked_func = function()
                return readBool(plugin, "study_reverse", false)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "study_reverse", false)
                plugin.settings:saveSetting("study_reverse", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Auto-rate by recall time"),
            text_func = function()
                local enabled = readBool(plugin, "auto_rate_enabled", false)
                return rowValue(_("Auto-rate by recall time"), enabled and _("On") or _("Off"))
            end,
            sub_item_table_func = function(touchmenu_instance)
                return makeAutoRateItems(plugin, refreshMenu, touchmenu_instance)
            end,
        },
        {
            text = _("Manual advance delays"),
            text_func = function()
                local again = tonumber(plugin.settings:readSetting("manual_again_advance_delay", 5)) or 5
                local hard = tonumber(plugin.settings:readSetting("manual_hard_advance_delay", 4)) or 4
                local good = tonumber(plugin.settings:readSetting("manual_good_advance_delay", 3)) or 3
                local easy = tonumber(plugin.settings:readSetting("manual_easy_advance_delay", 2)) or 2
                return rowValue(_("Manual advance delays"), string.format(_("%d/%d/%d/%ds"), again, hard, good, easy))
            end,
            sub_item_table_func = function(touchmenu_instance)
                return makeManualAdvanceItems(plugin, refreshMenu, touchmenu_instance)
            end,
        },
        {
            text = _("Front side fields"),
            mandatory = shortMandatory(CardFields.describeFields(CardFields.getFieldState(plugin, "front"))),
            sub_item_table_func = function(touchmenu_instance)
                return makeFieldItems(plugin, "front", touchmenu_instance)
            end,
        },
        {
            text = _("Back side fields"),
            mandatory = shortMandatory(CardFields.describeFields(CardFields.getFieldState(plugin, "back"))),
            sub_item_table_func = function(touchmenu_instance)
                return makeFieldItems(plugin, "back", touchmenu_instance)
            end,
        },
        {
            text = _("Randomize cards with same due date"),
            text_func = function()
                return boolRowValue(plugin, "randomize_cards", false, _("Randomize cards with same due date"))
            end,
            checked_func = function()
                return readBool(plugin, "randomize_cards", false)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "randomize_cards", false)
                plugin.settings:saveSetting("randomize_cards", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Daily new cards limit"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("daily_new_cards_limit", 20)) or 20
                local label = value == 0 and _("Unlimited") or tostring(value)
                return rowValue(_("Daily new cards limit"), label)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showNumberInput(
                    _("Daily new cards limit"),
                    _("Maximum new cards per day for the selected study deck. 0 = unlimited."),
                    daily_limit, 0,
                    function(value)
                        plugin.settings:saveSetting("daily_new_cards_limit", value)
                        plugin.settings:flush()
                        refreshMenu(touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Daily review limit"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("daily_review_cards_limit", 200)) or 200
                local label = value == 0 and _("Unlimited") or tostring(value)
                return rowValue(_("Daily review limit"), label)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showNumberInput(
                    _("Daily review limit"),
                    _("Maximum review cards per day. Learning cards may still appear. 0 = unlimited."),
                    daily_review_limit, 0,
                    function(value)
                        plugin.settings:saveSetting("daily_review_cards_limit", value)
                        plugin.settings:flush()
                        refreshMenu(touchmenu_instance)
                    end
                )
            end,
        },
        -- Study more frozen — re-enable by uncommenting below and setting
        -- STUDY_MORE_ENABLED = true in vocabdeck_study_more.lua.
        -- study_more_settings[1],
        -- study_more_settings[2],
        {
            text = _("Leech action"),
            text_func = function()
                return string.format("%s: %s", _("Leech action"), LEECH_ACTION_LABELS[getLeechAction(plugin)] or LEECH_ACTION_LABELS.tag)
            end,
            sub_item_table_func = function(touchmenu_instance)
                return makeLeechActionItems(plugin, touchmenu_instance)
            end,
        },
        {
            text = _("Desired retention"),
            text_func = function()
                local value = tonumber(plugin.settings:readSetting("desired_retention_percent", 90)) or 90
                return rowValue(_("Desired retention"), string.format("%d%%", value))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                showNumberInput(
                    _("Desired retention"),
                    _("Target recall rate for long-term reviews. Higher means more reviews. Recommended: 90."),
                    retention_percent, 70,
                    function(value)
                        value = math.floor((tonumber(value) or 90) + 0.5)
                        if value > 97 then value = 97 end
                        plugin.settings:saveSetting("desired_retention_percent", value)
                        plugin.settings:flush()
                        refreshMenu(touchmenu_instance)
                    end
                )
            end,
        },
        {
            text = _("Study only enriched cards"),
            text_func = function()
                return boolRowValue(plugin, "require_enriched_for_study", true, _("Study only enriched cards"))
            end,
            checked_func = function()
                return readBool(plugin, "require_enriched_for_study", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "require_enriched_for_study", true)
                plugin.settings:saveSetting("require_enriched_for_study", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
        {
            text = _("Show field names in study cards"),
            text_func = function()
                return boolRowValue(plugin, "show_section_labels", true, _("Show field names in study cards"))
            end,
            checked_func = function()
                return readBool(plugin, "show_section_labels", true)
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                local current = readBool(plugin, "show_section_labels", true)
                plugin.settings:saveSetting("show_section_labels", not current)
                plugin.settings:flush()
                refreshMenu(touchmenu_instance)
            end,
        },
    }, plugin)
end

return Settings
