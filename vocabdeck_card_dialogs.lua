-- Card detail, edit, and enrichment dialogs for VocabDeck.
local _ = require("gettext")

local AIRunner = require("vocabdeck_ai_runner")
local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")
local TextUtils = require("vocabdeck_text_utils")
local Format = require("vocabdeck_card_format")
local Memory = require("vocabdeck_memory")
local MemoryHelper = require("vocabdeck_memory_helper")

local Screen = Device.screen

local Dialogs = {}

local function askPostEditAction(plugin, card, on_done)
    local dialog
    dialog = ButtonDialog:new{
        title = _("What should happen to the existing AI data?"),
        buttons = {
            { {
                text = _("Keep existing data"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("keep")
                end,
            } },
            { {
                text = _("Clear, fetch later"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("clear")
                end,
            } },
            { {
                text = _("Clear and refetch now"),
                callback = function()
                    UIManager:close(dialog)
                    on_done("refetch")
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

local function runSingleFetch(plugin, card, after)
    local handled_in_dialog = false
    AIRunner.run(plugin, {
        message = _("Fetching AI data for:\n%s"),
        phrase = card.phrase or "",
        work = function(trap)
            return Enrich.enrichCard(plugin, card, trap)
        end,
        on_success = function(result)
            local headword = result.headword or ""
            local book_id = DB.getCardBookId(card.id)
            if book_id and headword ~= "" and headword ~= card.phrase then
                local dup_id = DB.findDuplicateByHeadword(book_id, headword, result.source_language, card.id)
                if dup_id then
                    handled_in_dialog = true
                    local dialog
                    local function closeDialog()
                        if dialog then UIManager:close(dialog) end
                    end
                    dialog = ButtonDialog:new{
                        title = string.format(_("\"%s\" already exists in this book."), headword),
                        buttons = { {
                            {
                                text = _("Delete"),
                                callback = function()
                                    closeDialog()
                                    DB.deleteCard(card.id)
                                    UIManager:show(InfoMessage:new{ text = _("Card deleted."), timeout = 2 })
                                    if after then after() end
                                end,
                            },
                            {
                                text = _("Merge into existing"),
                                callback = function()
                                    closeDialog()
                                    DB.mergeCards(card.id, dup_id, result)
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("Merged with %s."), headword),
                                        timeout = 2,
                                    })
                                    if after then after() end
                                end,
                            },
                        } },
                    }
                    UIManager:show(dialog)
                    return
                end
            end
            DB.applyEnrichment(card.id, result)
            if result.headword and result.headword ~= "" then
                card.phrase = result.headword
            end
            card.pronunciation = result.pronunciation or ""
            card.meaning = result.meaning or ""
            card.synonym = result.synonym or ""
            card.word_type = result.word_type or ""
            card.source_language = result.source_language ~= "" and result.source_language or card.source_language
            card.ai_status = DB.STATUS_ENRICHED
            card.ai_error = ""
            UIManager:show(InfoMessage:new{ text = _("Card enriched."), timeout = 2 })
        end,
        on_finally = function()
            if not handled_in_dialog and after then after() end
        end,
    })
end

function Dialogs.showEditDialog(plugin, card, on_saved)
    local original_phrase = card.phrase or ""
    local edit_menu
    local draft = {}
    local saved_during_edit = false
    local field_specs = {
        { key = "phrase", label = _("Word/Phrase"), rows = 1 },
        { key = "pronunciation", label = _("Pronunciation"), rows = 1 },
        { key = "word_type", label = _("Word type"), rows = 1 },
        { key = "source_language", label = _("Source language"), rows = 1 },
        { key = "meaning", label = _("Meaning"), rows = 4 },
        { key = "synonym", label = _("Synonyms"), rows = 2 },
        { key = "sentence", label = _("Source sentence"), rows = 4 },
        { key = "display_context", label = _("Surrounding context"), rows = 4 },
        { key = "user_note", label = _("User note"), rows = 4 },
    }
    for _, spec in ipairs(field_specs) do
        draft[spec.key] = card[spec.key] or ""
    end

    local function shortValue(value)
        value = value or ""
        value = value:gsub("\n", " ")
        if #value > 32 then value = value:sub(1, 30) .. "…" end
        return value ~= "" and value or _("empty")
    end

    local function closeMenu(refresh_parent)
        if edit_menu then
            UIManager:close(edit_menu)
            edit_menu = nil
            UIManager:setDirty(nil, "ui")
        end
        if refresh_parent and on_saved then
            on_saved(card)
        end
    end

    local function hideMenuPagination(menu)
        if menu.page_info_text then menu.page_info_text:hide() end
        if menu.page_info_left_chev then menu.page_info_left_chev:hide() end
        if menu.page_info_right_chev then menu.page_info_right_chev:hide() end
        if menu.page_info_first_chev then menu.page_info_first_chev:hide() end
        if menu.page_info_last_chev then menu.page_info_last_chev:hide() end
        if menu.page_return_arrow then menu.page_return_arrow:hide() end
    end

    local function persistFields(clear_ai)
        local fields = {
            phrase = draft.phrase or "",
            sentence = draft.sentence or "",
            ai_context = card.ai_context or "",
            display_context = draft.display_context or "",
            pronunciation = clear_ai and "" or (draft.pronunciation or ""),
            meaning = clear_ai and "" or (draft.meaning or ""),
            synonym = clear_ai and "" or (draft.synonym or ""),
            word_type = clear_ai and "" or (draft.word_type or ""),
            source_language = draft.source_language or "",
            user_note = draft.user_note or "",
            ai_status = clear_ai and DB.STATUS_PENDING or (card.ai_status or DB.STATUS_PENDING),
            ai_error = "",
        }
        if fields.phrase == "" then
            UIManager:show(InfoMessage:new{ text = _("Phrase cannot be empty."), timeout = 3 })
            return false
        end
        if DB.cardPhraseExists(card.book_id, fields.phrase, card.id, fields.source_language) then
            UIManager:show(InfoMessage:new{
                text = string.format(_("Already in VocabDeck:\n%s"), fields.phrase),
                timeout = 3,
            })
            return false
        end
        DB.updateCardFields(card.id, fields)
        local fresh = DB.getCard(card.id)
        if fresh then
            for k, v in pairs(fresh) do card[k] = v end
        else
            UIManager:show(InfoMessage:new{ text = _("Card could not be saved."), timeout = 3 })
            return false
        end
        for _, spec in ipairs(field_specs) do
            draft[spec.key] = card[spec.key] or ""
        end
        saved_during_edit = true
        return true
    end

    local function finishSave(clear_ai, refetch_now)
        if not persistFields(clear_ai) then return false end
        if refetch_now then
            closeMenu()
            runSingleFetch(plugin, card, on_saved)
        else
            closeMenu(true)
            UIManager:show(InfoMessage:new{ text = _("Card saved."), timeout = 2 })
        end
        return true
    end

    local function saveFromForm()
        local phrase_changed = (draft.phrase or "") ~= original_phrase
        if phrase_changed and card.ai_status == DB.STATUS_ENRICHED then
            askPostEditAction(plugin, card, function(choice)
                if choice == "keep" then
                    finishSave(false, false)
                elseif choice == "clear" then
                    finishSave(true, false)
                else
                    finishSave(true, true)
                end
            end)
        else
            finishSave(false, false)
        end
    end

    local function editField(spec)
        local dialog
        local function closeDialog()
            if dialog then
                if dialog.onCloseKeyboard then
                    dialog:onCloseKeyboard()
                end
                UIManager:close(dialog)
                dialog = nil
                UIManager:setDirty(nil, "ui")
            end
        end
        dialog = InputDialog:new{
            title = spec.label,
            input = draft[spec.key] or "",
            allow_newline = (spec.rows or 1) > 1,
            rows = spec.rows or 1,
            buttons = { {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = closeDialog,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local value = dialog:getInputText() or ""
                        if spec.key == "phrase" then
                            value = TextUtils.trim(value)
                            if value == "" then
                                UIManager:show(InfoMessage:new{ text = _("Phrase cannot be empty."), timeout = 3 })
                                return
                            end
                        end
                        draft[spec.key] = TextUtils.trim(value)
                        closeDialog()
                        if persistFields(false) and edit_menu and edit_menu.updateItems then
                            edit_menu:updateItems()
                            hideMenuPagination(edit_menu)
                        end
                    end,
                },
            } },
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end

    local items = {}
    for _, spec in ipairs(field_specs) do
        items[#items + 1] = {
            text = spec.label,
            mandatory_func = function()
                return shortValue(draft[spec.key])
            end,
            keep_menu_open = true,
            callback = function()
                editField(spec)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Save card"),
        separator = true,
        callback = saveFromForm,
    }
    items[#items + 1] = {
        text = _("Cancel"),
        callback = function()
            closeMenu(saved_during_edit)
        end,
    }

    edit_menu = Menu:new{
        title = _("Edit card"),
        item_table = items,
        covers_fullscreen = true,
        items_per_page = #items,
    }
    hideMenuPagination(edit_menu)
    UIManager:show(edit_menu)
end

function Dialogs.showCardDetails(plugin, card, nav_context, on_refresh)
    if type(nav_context) == "function" then
        on_refresh = nav_context
        nav_context = nil
    end
    local page_cards, global_idx, total_items, fetch_at_card
    if type(nav_context) == "table" and nav_context.fetch_at then
        page_cards = nav_context.cards
        global_idx = nav_context.global_idx
        total_items = nav_context.total
        fetch_at_card = nav_context.fetch_at
    end

    local viewer
    local needs_parent_refresh = false
    local function refreshViewer(saved_card)
        if saved_card then
            for k, v in pairs(saved_card) do card[k] = v end
        else
            local fresh = DB.getCard(card.id)
            if fresh then
                for k, v in pairs(fresh) do card[k] = v end
            end
        end
        if viewer then
            viewer.text = Format.buildPreviewText(card)
            if viewer.reinit then
                viewer:reinit()
            else
                UIManager:setDirty(nil, "ui")
            end
        end
        needs_parent_refresh = true
    end
    local function closeViewer()
        if viewer then
            UIManager:close(viewer)
            UIManager:setDirty(nil, "ui")
        end
        if needs_parent_refresh and on_refresh then
            needs_parent_refresh = false
            on_refresh()
        end
    end

    local buttons = {}
    if nav_context and fetch_at_card and total_items and total_items > 0 then
        local has_prev = global_idx > 1
        local has_next = global_idx < total_items
        local function navigateTo(target_idx)
            if target_idx < 1 or target_idx > total_items then return end
            local needs_refresh = needs_parent_refresh
            closeViewer()
            local next_card = fetch_at_card(target_idx)
            if next_card then
                Dialogs.showCardDetails(plugin, next_card, {
                    cards = page_cards,
                    global_idx = target_idx,
                    total = total_items,
                    fetch_at = fetch_at_card,
                }, on_refresh)
            end
            if needs_refresh then needs_parent_refresh = true end
        end
        table.insert(buttons, {
            {
                text = "← " .. _("Previous"),
                enabled = has_prev,
                callback = function() navigateTo(global_idx - 1) end,
            },
            {
                text = string.format("%d / %d", global_idx, total_items),
                callback = function() end,
            },
            {
                text = _("Next") .. " →",
                enabled = has_next,
                callback = function() navigateTo(global_idx + 1) end,
            },
        })
    end
    table.insert(buttons, {
        {
            text = _("Edit"),
            callback = function()
                UIManager:nextTick(function()
                    Dialogs.showEditDialog(plugin, card, function(saved_card)
                        refreshViewer(saved_card)
                    end)
                end)
            end,
        },
        {
            text = card.ai_status == DB.STATUS_ENRICHED and _("Refetch AI data") or _("Fetch AI data"),
            callback = function()
                runSingleFetch(plugin, card, refreshViewer)
            end,
        },
    })
    table.insert(buttons, {
        {
            text = (card.known or 0) ~= 0 and _("Restore to study") or _("Mark as known"),
            callback = function()
                local new_known = (card.known or 0) == 0
                DB.setCardKnown(card.id, new_known)
                card.known = new_known and 1 or 0
                if not new_known then
                    UIManager:show(InfoMessage:new{
                        text = _("Restored to study."),
                        timeout = 2,
                    })
                end
                needs_parent_refresh = true
                closeViewer()
            end,
        },
        {
            text = _("Delete"),
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Delete this card?"),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        closeViewer()
                        DB.deleteCard(card.id)
                        UIManager:show(InfoMessage:new{ text = _("Card deleted."), timeout = 2 })
                        if on_refresh then on_refresh() end
                    end,
                })
            end,
        },
        {
            text = _("Move to deck"),
            callback = function()
                local langs = DB.listLanguages()
                local current = DB.getActiveLanguage() or ""
                local items = {}
                for __, lang in ipairs(langs) do
                    if lang ~= current then
                        items[#items + 1] = {
                            text = lang,
                            callback = function()
                                DB.moveCardToLanguage(card.id, lang)
                                closeViewer()
                                UIManager:show(InfoMessage:new{
                                    text = string.format(_("Moved to %s."), lang),
                                    timeout = 2,
                                })
                                if on_refresh then on_refresh() end
                            end,
                        }
                    end
                end
                if #items == 0 then
                    UIManager:show(InfoMessage:new{ text = _("No other decks."), timeout = 2 })
                    return
                end
                UIManager:show(Menu:new{
                    title = _("Move to deck"),
                    item_table = items,
                    covers_fullscreen = false,
                    width = math.floor(Screen:getWidth() * 0.6),
                })
            end,
        },
    })
    table.insert(buttons, {
        {
            text = _("Memory"),
            callback = function()
                UIManager:show(TextViewer:new{
                    title = _("Card memory"),
                    text = Memory.buildText(card),
                })
            end,
        },
        {
            text = _("AI memory helper"),
            callback = function()
                MemoryHelper.showForCard(plugin, card, function(saved_card)
                    refreshViewer(saved_card)
                end)
            end,
        },
        {
            text = _("Close"),
            callback = function()
                closeViewer()
            end,
        },
    })
    if (card.leech or 0) ~= 0 then
        table.insert(buttons, { {
            text = _("Un-leech"),
            callback = function()
                DB.setCardLeech(card.id, false)
                card.leech = 0
                UIManager:show(InfoMessage:new{ text = _("Leech cleared."), timeout = 2 })
                refreshViewer()
            end,
        } } )
    end
    viewer = TextViewer:new{
        title = _("Card details"),
        text = Format.buildPreviewText(card),
        buttons_table = buttons,
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

return Dialogs
