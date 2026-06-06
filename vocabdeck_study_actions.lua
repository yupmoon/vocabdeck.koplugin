-- VocabDeck Study card actions.
--
-- Owns less-frequent card actions shown from Study mode's Actions button.

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local AIRunner = require("vocabdeck_ai_runner")
local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")
local Memory = require("vocabdeck_memory")
local MemoryHelper = require("vocabdeck_memory_helper")

local Actions = {}

function Actions.deleteCard(study)
    if not study.current_card then return end
    if study.invalidateAutoRate then study:invalidateAutoRate() end
    UIManager:show(ConfirmBox:new{
        text = _("Delete this card?"),
        ok_text = _("Delete"),
        ok_callback = function()
            DB.deleteCard(study.current_card.id)
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    })
end

function Actions.suspendCard(study)
    if not study.current_card then return end
    DB.setCardSuspended(study.current_card.id, true)
    UIManager:show(InfoMessage:new{ text = _("Card suspended."), timeout = 2 })
    study.current_card = nil
    study.showing_back = false
    study:loadNextCard()
end

function Actions.markKnown(study)
    if not study.current_card then return end
    if study.invalidateAutoRate then study:invalidateAutoRate() end
    UIManager:show(ConfirmBox:new{
        text = _("Mark this card as known and hide it from study?"),
        ok_text = _("Mark as known"),
        ok_callback = function()
            DB.setCardKnown(study.current_card.id, true)
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    })
end

function Actions.toggleFlag(study)
    if not study.current_card then return end
    local flagged = (study.current_card.flag or 0) ~= 0
    local new_flag = not flagged
    DB.setCardFlag(study.current_card.id, new_flag)
    study.current_card.flag = new_flag and 1 or 0
    study:refreshCurrentCard()
    UIManager:show(InfoMessage:new{
        text = new_flag and _("Card flagged.") or _("Flag cleared."),
        timeout = 2,
    })
end

function Actions.resetCard(study)
    if not study.current_card then return end
    if study.invalidateAutoRate then study:invalidateAutoRate() end
    UIManager:show(ConfirmBox:new{
        text = _("Reset this card to new?"),
        ok_text = _("Reset"),
        ok_callback = function()
            DB.resetCardScheduling(study.current_card.id)
            UIManager:show(InfoMessage:new{ text = _("Card reset."), timeout = 2 })
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    })
end

function Actions.unleechCard(study)
    if not study.current_card then return end
    local card = study.current_card
    local was_leech = (card.leech or 0) ~= 0
    if not was_leech then
        UIManager:show(InfoMessage:new{ text = _("Card is not a leech."), timeout = 2 })
        return
    end
    DB.setCardLeech(card.id, false)
    card.leech = 0
    UIManager:show(InfoMessage:new{ text = _("Leech cleared."), timeout = 2 })
end

function Actions.refetchAIData(study)
    if not study.current_card then return end
    local card = study.current_card
    local plugin = study.plugin
    AIRunner.run(plugin, {
        message = _("Fetching AI data for:\n%s"),
        phrase = card.phrase or "",
        work = function(trap)
            return Enrich.enrichAndSave(plugin, card, trap)
        end,
        on_success = function()
            UIManager:show(InfoMessage:new{ text = _("AI data updated."), timeout = 2 })
            if study.current_card and study.current_card.id == card.id then
                study:refreshCurrentCard()
            end
        end,
    })
end

function Actions.showMemory(study)
    if not study.current_card then return end
    UIManager:show(TextViewer:new{
        title = _("Card memory"),
        text = Memory.buildText(study.current_card),
    })
end

function Actions.showAIMemoryHelp(study)
    if not study.current_card then return end
    MemoryHelper.show(study, function(saved_card)
        if study.current_card and study.current_card.id == saved_card.id then
            study:refreshCurrentCard()
        end
    end)
end

function Actions.showMenu(study)
    if not study.current_card then
        UIManager:show(InfoMessage:new{ text = _("No card selected."), timeout = 2 })
        return
    end
    local dialog
    local function closeDialog()
        if dialog then UIManager:close(dialog) end
    end
    local flagged = (study.current_card.flag or 0) ~= 0
    dialog = ButtonDialog:new{
        title = _("Card actions"),
        buttons = {
            { {
                text = flagged and _("Clear flag") or _("Flag card"),
                callback = function()
                    closeDialog()
                    Actions.toggleFlag(study)
                end,
            } },
            { {
                text = _("Suspend card"),
                callback = function()
                    closeDialog()
                    Actions.suspendCard(study)
                end,
            } },
            { {
                text = _("Mark as known"),
                callback = function()
                    closeDialog()
                    Actions.markKnown(study)
                end,
            } },
            { {
                text = _("Reset card"),
                callback = function()
                    closeDialog()
                    Actions.resetCard(study)
                end,
            } },
            { {
                text = _("Un-leech card"),
                callback = function()
                    closeDialog()
                    Actions.unleechCard(study)
                end,
                enabled = (study.current_card.leech or 0) ~= 0,
            } },
            { {
                text = _("Memory"),
                callback = function()
                    closeDialog()
                    Actions.showMemory(study)
                end,
            } },
            { {
                text = _("Refetch AI data"),
                callback = function()
                    closeDialog()
                    Actions.refetchAIData(study)
                end,
            } },
            { {
                text = _("AI memory helper"),
                callback = function()
                    closeDialog()
                    Actions.showAIMemoryHelp(study)
                end,
            } },
            { {
                text = _("Delete card"),
                callback = function()
                    closeDialog()
                    Actions.deleteCard(study)
                end,
            } },
            { {
                text = _("Close"),
                callback = closeDialog,
            } },
        },
    }
    UIManager:show(dialog)
end

return Actions
