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

function Actions.deleteCard(study, on_cancel)
    if not study.current_card then return end
    local confirmed = false
    local confirm
    confirm = ConfirmBox:new{
        text = _("Delete this card?"),
        ok_text = _("Delete"),
        ok_callback = function()
            confirmed = true
            if study.invalidateAutoRate then study:invalidateAutoRate() end
            DB.deleteCard(study.current_card.id)
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    }
    local old_on_close = confirm.onCloseWidget
    function confirm:onCloseWidget()
        if old_on_close then old_on_close(self) end
        if not confirmed and on_cancel then on_cancel() end
    end
    UIManager:show(confirm)
end

function Actions.suspendCard(study)
    if not study.current_card then return end
    if study.invalidateAutoRate then study:invalidateAutoRate() end
    DB.setCardSuspended(study.current_card.id, true)
    UIManager:show(InfoMessage:new{ text = _("Card suspended."), timeout = 2 })
    study.current_card = nil
    study.showing_back = false
    study:loadNextCard()
end

function Actions.markKnown(study, on_cancel)
    if not study.current_card then return end
    local confirmed = false
    local confirm
    confirm = ConfirmBox:new{
        text = _("Mark this card as known and hide it from study?"),
        ok_text = _("Mark as known"),
        ok_callback = function()
            confirmed = true
            if study.invalidateAutoRate then study:invalidateAutoRate() end
            DB.setCardKnown(study.current_card.id, true)
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    }
    local old_on_close = confirm.onCloseWidget
    function confirm:onCloseWidget()
        if old_on_close then old_on_close(self) end
        if not confirmed and on_cancel then on_cancel() end
    end
    UIManager:show(confirm)
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

function Actions.resetCard(study, on_cancel)
    if not study.current_card then return end
    local confirmed = false
    local confirm
    confirm = ConfirmBox:new{
        text = _("Reset this card to new?"),
        ok_text = _("Reset"),
        ok_callback = function()
            confirmed = true
            if study.invalidateAutoRate then study:invalidateAutoRate() end
            DB.resetCardScheduling(study.current_card.id)
            UIManager:show(InfoMessage:new{ text = _("Card reset."), timeout = 2 })
            study.current_card = nil
            study.showing_back = false
            study:loadNextCard()
        end,
    }
    local old_on_close = confirm.onCloseWidget
    function confirm:onCloseWidget()
        if old_on_close then old_on_close(self) end
        if not confirmed and on_cancel then on_cancel() end
    end
    UIManager:show(confirm)
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

function Actions.refetchAIData(study, on_done)
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
        on_finally = function()
            if on_done then on_done() end
        end,
    })
end

function Actions.showMemory(study, on_close)
    if not study.current_card then
        if on_close then on_close() end
        return
    end
    local viewer
    local closed = false
    local function notifyClosed()
        if closed then return end
        closed = true
        if on_close then on_close() end
    end
    viewer = TextViewer:new{
        title = _("Card memory"),
        text = Memory.buildText(study.current_card),
    }
    local old_on_close = viewer.onCloseWidget
    function viewer:onCloseWidget()
        if old_on_close then old_on_close(self) end
        notifyClosed()
    end
    UIManager:show(viewer)
end

function Actions.showAIMemoryHelp(study, on_close)
    if not study.current_card then
        if on_close then on_close() end
        return
    end
    MemoryHelper.show(study, function(saved_card)
        if study.current_card and study.current_card.id == saved_card.id then
            study:refreshCurrentCard()
        end
    end, on_close)
end

function Actions.showMenu(study)
    if not study.current_card then
        UIManager:show(InfoMessage:new{ text = _("No card selected."), timeout = 2 })
        return
    end
    local dialog
    local dialog_resume_allowed = true
    local dialog_closed = false
    local function resumeStudy()
        if study.resumeAutoRate then study:resumeAutoRate() end
    end
    local function closeDialog(resume)
        dialog_resume_allowed = resume ~= false
        if dialog then UIManager:close(dialog) end
        if dialog_resume_allowed and not dialog_closed then
            dialog_closed = true
            resumeStudy()
        end
    end
    local flagged = (study.current_card.flag or 0) ~= 0
    dialog = ButtonDialog:new{
        title = _("Card actions"),
        buttons = {
            { {
                text = flagged and _("Clear flag") or _("Flag card"),
                callback = function()
                    closeDialog(false)
                    Actions.toggleFlag(study)
                    resumeStudy()
                end,
            } },
            { {
                text = _("Suspend card"),
                callback = function()
                    closeDialog(false)
                    Actions.suspendCard(study)
                end,
            } },
            { {
                text = _("Mark as known"),
                callback = function()
                    closeDialog(false)
                    Actions.markKnown(study, resumeStudy)
                end,
            } },
            { {
                text = _("Reset card"),
                callback = function()
                    closeDialog(false)
                    Actions.resetCard(study, resumeStudy)
                end,
            } },
            { {
                text = _("Un-leech card"),
                callback = function()
                    closeDialog(false)
                    Actions.unleechCard(study)
                    resumeStudy()
                end,
                enabled = (study.current_card.leech or 0) ~= 0,
            } },
            { {
                text = _("Memory"),
                callback = function()
                    closeDialog(false)
                    Actions.showMemory(study, resumeStudy)
                end,
            } },
            { {
                text = _("Refetch AI data"),
                callback = function()
                    closeDialog(false)
                    Actions.refetchAIData(study, resumeStudy)
                end,
            } },
            { {
                text = _("AI memory helper"),
                callback = function()
                    closeDialog(false)
                    Actions.showAIMemoryHelp(study, resumeStudy)
                end,
            } },
            { {
                text = _("Delete card"),
                callback = function()
                    closeDialog(false)
                    Actions.deleteCard(study, resumeStudy)
                end,
            } },
            { {
                text = _("Close"),
                callback = closeDialog,
            } },
        },
    }
    local old_on_close = dialog.onCloseWidget
    function dialog:onCloseWidget()
        if old_on_close then old_on_close(self) end
        if dialog_closed then return end
        dialog_closed = true
        if dialog_resume_allowed then
            resumeStudy()
        end
    end
    UIManager:show(dialog)
end

return Actions
