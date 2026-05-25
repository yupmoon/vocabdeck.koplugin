-- VocabDeck manual card entry workflow.
--
-- Owns the UI for adding a card outside the current book context. Manual cards
-- are saved through the main plugin's normal persistence path so duplicate
-- checks, source-language normalization, optional notes, and later scheduling
-- stay consistent with dictionary/highlight cards.
local _ = require("gettext")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local UIManager = require("ui/uimanager")

local AIRunner = require("vocabdeck_ai_runner")
local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")
local Languages = require("vocabdeck_languages")

local ManualAdd = {}

local function closeInputDialog(dialog)
    if dialog then
        if dialog.onCloseKeyboard then dialog:onCloseKeyboard() end
        UIManager:close(dialog)
        UIManager:setDirty(nil, "ui")
    end
end

local function fetchAIForCard(plugin, card_id)
    local card = DB.getCard(card_id)
    if not card then
        UIManager:show(InfoMessage:new{ text = _("Card not found."), timeout = 3 })
        return
    end
    AIRunner.run(plugin, {
        message = _("Fetching AI data for:\n%s"),
        phrase = card.phrase or "",
        work = function(trap)
            return Enrich.enrichAndSave(plugin, card, trap)
        end,
        on_success = function()
            UIManager:show(InfoMessage:new{ text = _("Card enriched."), timeout = 2 })
        end,
    })
end

local function showFetchChoice(plugin, card_id)
    local dialog
    dialog = ButtonDialog:new{
        title = _("Card added"),
        buttons = {
            { {
                text = _("Fetch AI data now"),
                callback = function()
                    UIManager:close(dialog)
                    fetchAIForCard(plugin, card_id)
                end,
            } },
            { {
                text = _("Close"),
                callback = function()
                    UIManager:close(dialog)
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

local function saveManualCard(plugin, phrase, source_language, touchmenu_instance)
    local params = {
        phrase = phrase,
        source_language = source_language,
        manual_entry = true,
        ai_status = DB.STATUS_PENDING,
        after_save = function(card_id)
            showFetchChoice(plugin, card_id)
        end,
    }
    local ask_note = plugin.settings:readSetting("ask_note_on_add")
    if ask_note == nil then ask_note = true end
    if ask_note then
        plugin:_showNoteDialog(phrase, params, touchmenu_instance)
    else
        plugin:_persistCard(phrase, "", params, touchmenu_instance)
    end
end

local function showSourcePicker(plugin, phrase, touchmenu_instance)
    local dialog
    local function choose(source_language)
        UIManager:close(dialog)
        saveManualCard(plugin, phrase, source_language, touchmenu_instance)
    end
    local buttons = {}
    for __, language in ipairs(Languages.listManualChoices()) do
        buttons[#buttons + 1] = { {
            text = _(language),
            callback = function() choose(language) end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Cancel"),
        callback = function() UIManager:close(dialog) end,
    } }
    dialog = ButtonDialog:new{
        title = _("Source language"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function ManualAdd.start(plugin, touchmenu_instance)
    local dialog
    dialog = InputDialog:new{
        title = _("Add new card"),
        description = _("Enter the word or phrase first."),
        input = "",
        input_hint = _("Word or phrase"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                callback = function() closeInputDialog(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local phrase = dialog:getInputText() or ""
                    phrase = phrase:gsub("^%s+", ""):gsub("%s+$", "")
                    if phrase == "" then
                        UIManager:show(InfoMessage:new{ text = _("Word or phrase cannot be empty."), timeout = 3 })
                        return
                    end
                    closeInputDialog(dialog)
                    showSourcePicker(plugin, phrase, touchmenu_instance)
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

return ManualAdd
