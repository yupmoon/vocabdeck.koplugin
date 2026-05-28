-- VocabDeck card list / edit / delete UI.
--
-- Lists cards for the current book (or all books) in a full-screen KOReader
-- widget modeled on the built-in Vocabulary Builder. Tapping a card opens an
-- action dialog (view / edit / delete). Editing the phrase also offers the
-- user a choice between keeping the enrichment, clearing it for a later fetch,
-- or refetching right now.
local _ = require("gettext")
local BD = require("ui/bidi")
local BottomContainer = require("ui/widget/container/bottomcontainer")
local UIManager = require("ui/uimanager")
local Menu = require("ui/widget/menu")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local ButtonDialog = require("ui/widget/buttondialog")
local TextViewer = require("ui/widget/textviewer")
local Device = require("device")
local Button = require("ui/widget/button")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local T = require("ffi/util").template

local Screen = Device.screen

local AIRunner = require("vocabdeck_ai_runner")
local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")
local Languages = require("vocabdeck_languages")
local Memory = require("vocabdeck_memory")
local MemoryHelper = require("vocabdeck_memory_helper")

local Edit = {}

local function cleanMeaningPreview(meaning)
    if not meaning or meaning == "" then
        return ""
    end
    local first_line, rest = meaning:match("^([^\n]+)\n(.+)$")
    if not first_line or not rest then
        return meaning
    end
    local label = first_line:gsub("^%s+", ""):gsub("%s+$", ""):lower()
    label = label:gsub("%s*[,;:].*$", "")
    if Languages.GRAMMAR_LABELS[label] then
        return rest:gsub("^%s+", ""):gsub("%s+$", "")
    end
    return meaning
end

local function buildCardSubtitle(card)
    if card.meaning and card.meaning ~= "" then
        return cleanMeaningPreview(card.meaning)
    end
    if card.sentence and card.sentence ~= "" then
        return card.sentence
    end
    if card.display_context and card.display_context ~= "" then
        return card.display_context
    end
    if card.ai_status == DB.STATUS_ERROR then
        return _("AI fetch failed")
    end
    if card.ai_status == DB.STATUS_PENDING then
        return _("AI pending")
    end
    return _("No meaning yet")
end

local function buildPreviewText(card)
    local parts = { card.phrase or "" }
    local meta = {}
    if (card.leech or 0) ~= 0 then
        meta[#meta + 1] = _("Leech")
    end
    if card.word_type and card.word_type ~= "" then
        meta[#meta + 1] = card.word_type
    end
    if card.pronunciation and card.pronunciation ~= "" then
        meta[#meta + 1] = card.pronunciation
    end
    if #meta > 0 then
        parts[#parts + 1] = table.concat(meta, " · ")
    end
    if card.meaning ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = card.meaning
    end
    if card.synonym and card.synonym ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Synonyms: %s"), card.synonym)
    end
    local context = card.sentence ~= "" and card.sentence or card.display_context
    if context and context ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = context
    end
    if card.user_note and card.user_note ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Note: %s"), card.user_note)
    end
    local book_title = card.book_id and DB.getBookTitle(card.book_id)
    if book_title and book_title ~= "" or card.created_at then
        parts[#parts + 1] = ""
    end
    if book_title and book_title ~= "" then
        parts[#parts + 1] = string.format(_("Book: %s"), book_title)
    end
    if card.created_at then
        parts[#parts + 1] = string.format(_("Added on: %s"), os.date("%Y-%m-%d %H:%M", card.created_at))
    end
    if card.ai_status == DB.STATUS_ENRICHED then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("✨ Enriched by AI")
    elseif card.ai_status == DB.STATUS_ERROR and card.ai_error ~= "" then
        parts[#parts + 1] = ""
        parts[#parts + 1] = string.format(_("Last AI error: %s"), card.ai_error)
    elseif card.ai_status == DB.STATUS_PENDING then
        parts[#parts + 1] = ""
        parts[#parts + 1] = _("This card has not been enriched yet.")
    end
    return table.concat(parts, "\n")
end

-- Ask the user what should happen to the AI fields after an edit.
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
    AIRunner.run(plugin, {
        message = _("Fetching AI data for:\n%s"),
        phrase = card.phrase or "",
        work = function(trap)
            return Enrich.enrichAndSave(plugin, card, trap)
        end,
        on_success = function()
            UIManager:show(InfoMessage:new{ text = _("Card enriched."), timeout = 2 })
        end,
        on_finally = function()
            if after then after() end
        end,
    })
end

local function showEditDialog(plugin, card, on_saved)
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
        -- KOReader's stock Menu always creates a page footer, even when this
        -- editor fits on one page. The edit form has explicit Save/Cancel
        -- actions, so the footer is only noise here.
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
                            value = value:gsub("^%s+", ""):gsub("%s+$", "")
                            if value == "" then
                                UIManager:show(InfoMessage:new{ text = _("Phrase cannot be empty."), timeout = 3 })
                                return
                            end
                        end
                        draft[spec.key] = value:gsub("^%s+", ""):gsub("%s+$", "")
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

local function showCardDetails(plugin, card, nav_context, on_refresh)
    -- Backward compat: old callers pass (plugin, card, on_refresh) with
    -- only three arguments.  When nav_context is a function it is actually
    -- the on_refresh callback.  When nav_context is a flat table (the old
    -- card_list), treat current_index as the 4th arg.
    if type(nav_context) == "function" then
        on_refresh = nav_context
        nav_context = nil
    end
    -- Unpack nav_context when provided: { cards, global_idx, total, fetch_at }
    local page_cards, global_idx, total_items, fetch_at_card
    if type(nav_context) == "table" and nav_context.fetch_at then
        page_cards = nav_context.cards
        global_idx = nav_context.global_idx
        total_items = nav_context.total
        fetch_at_card = nav_context.fetch_at
    end
    -- card_list and current_index are optional: when provided, prev/next
    -- navigation buttons appear so the user can browse cards in-place.
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
            viewer.text = buildPreviewText(card)
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
    -- Navigation row: shown when nav_context is provided (cross-page-aware)
    -- or when backward-compat card_list is passed (within-page only).
    if nav_context and fetch_at_card and total_items and total_items > 0 then
        local has_prev = global_idx > 1
        local has_next = global_idx < total_items
        local function navigateTo(target_idx)
            if target_idx < 1 or target_idx > total_items then return end
            local needs_refresh = needs_parent_refresh
            closeViewer()
            -- Try to find the card in the current page first.
            local local_idx = target_idx - (global_idx - (page_cards and page_cards[1] and 1 or 0))
            -- Actually, find by computing offset within the current page.
            -- Simpler: always fetch from DB. It's a single LIMIT 1 query.
            local next_card = fetch_at_card(target_idx)
            if next_card then
                -- Build nav_context for the next card using the same total page cards
                local next_ctx = {
                    cards = page_cards,
                    global_idx = target_idx,
                    total = total_items,
                    fetch_at = fetch_at_card,
                }
                showCardDetails(plugin, next_card, next_ctx, on_refresh)
            end
            if needs_refresh then needs_parent_refresh = true end
        end
        local nav_row = {}
        nav_row[1] = {
            text = "← " .. _("Previous"),
            enabled = has_prev,
            callback = function() navigateTo(global_idx - 1) end,
        }
        nav_row[2] = {
            text = string.format("%d / %d", global_idx, total_items),
            enabled = false,
            callback = function() end,
        }
        nav_row[3] = {
            text = _("Next") .. " →",
            enabled = has_next,
            callback = function() navigateTo(global_idx + 1) end,
        }
        table.insert(buttons, nav_row)
    end
    table.insert(buttons, {
        {
            text = _("Edit"),
            callback = function()
                UIManager:nextTick(function()
                    showEditDialog(plugin, card, function(saved_card)
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
    -- Un-leech button: only shown when the card is actually a leech.
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
        text = buildPreviewText(card),
        buttons_table = buttons,
        add_default_buttons = false,
    }
    UIManager:show(viewer)
end

local word_face = Font:getFace("smallinfofont")
local subtitle_face = Font:getFace("smallinfofont")
local subtitle_color = Blitbuffer.COLOR_BLACK
local dim_color = Blitbuffer.COLOR_GRAY_3
local word_height = TextWidget:new{ text = " ", face = word_face }:getSize().h
local schedule_face = Font:getFace("cfont", 14)
local schedule_height = TextWidget:new{ text = " ", face = schedule_face }:getSize().h
local separator_width = TextWidget:new{ text = " — ", face = subtitle_face }:getSize().w

local function formatReviewStatus(card)
    if not card then return "" end
    if (card.review_count or 0) == 0 then
        return _("New card")
    end
    local now = os.time()
    local due = tonumber(card.due) or now
    if due <= now then
        return _("Review now")
    end
    local next_day_start = DB.getNextReviewDayStart
        and DB.getNextReviewDayStart(now) or (now + 86400)
    if due < next_day_start then
        return _("Due today")
    end
    local days = math.max(1, math.ceil((due - next_day_start) / 86400))
    if days == 1 then
        return _("Review tomorrow")
    end
    return string.format(_("Review in %d days"), days)
end

-- Lightweight row builder: returns a FrameContainer with TextWidget children.
-- No InputContainer overhead — gesture handling is done by VocabDeckCardList.
local function buildRowWidget(width, height, card, empty_text, quick_delete, show_parent)
    local phrase = card and (card.phrase or "") or (empty_text or "")
    if card and (card.leech or 0) ~= 0 then
        phrase = "! " .. phrase
    end
    if card and (card.flag or 0) ~= 0 then
        phrase = "* " .. phrase
    end
    if card and card.ai_status ~= DB.STATUS_ENRICHED then
        phrase = "[!] " .. phrase
    end
    local subtitle = card and buildCardSubtitle(card) or ""
    local review_status = formatReviewStatus(card)

    local left_padding = Size.padding.large
    local delete_width = quick_delete and Screen:scaleBySize(48) or 0
    local text_width = width - left_padding - delete_width
    local top_space = math.max(0, math.floor((height - word_height - schedule_height) / 4))
    local phrase_widget = TextWidget:new{ text = phrase, face = word_face }
    local phrase_width = math.min(phrase_widget:getSize().w, math.floor(text_width * 0.72))
    local meaning_width = math.max(0, text_width - phrase_width - separator_width)

    local row = FrameContainer:new{
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            dimen = Geom:new{ w = width, h = height },
            HorizontalSpan:new{ width = left_padding },
            VerticalGroup:new{
                dimen = Geom:new{ w = text_width, h = height },
                VerticalSpan:new{ width = top_space },
                LeftContainer:new{
                    dimen = Geom:new{ w = text_width, h = word_height },
                    HorizontalGroup:new{
                        dimen = Geom:new{ w = text_width, h = word_height },
                        TextWidget:new{
                            text = phrase,
                            face = word_face,
                            max_width = phrase_width,
                            fgcolor = card and Blitbuffer.COLOR_BLACK or dim_color,
                        },
                        TextWidget:new{
                            text = " — ",
                            face = subtitle_face,
                            fgcolor = subtitle_color,
                        },
                        TextWidget:new{
                            text = subtitle,
                            face = subtitle_face,
                            max_width = meaning_width,
                            fgcolor = card and subtitle_color or dim_color,
                        },
                    },
                },
                VerticalSpan:new{ width = math.max(0, math.floor(top_space / 2)) },
                RightContainer:new{
                    dimen = Geom:new{ w = text_width, h = schedule_height },
                    TextWidget:new{
                        text = review_status,
                        face = schedule_face,
                        max_width = text_width,
                        fgcolor = dim_color,
                    },
                },
            },
            delete_width > 0 and Button:new{
                icon = "exit",
                width = delete_width,
                height = delete_width,
                padding = Size.padding.button,
                bordersize = 0,
                radius = 0,
                show_parent = show_parent,
                callback = function()
                    if card then
                        UIManager:show(ConfirmBox:new{
                            text = string.format(_("Delete card \"%s\"?"), card.phrase or ""),
                            ok_text = _("Delete"),
                            ok_callback = function()
                                DB.deleteCard(card.id)
                                if show_parent then show_parent:reloadItems() end
                            end,
                        })
                    end
                end,
            } or HorizontalSpan:new{ width = 0 },
        },
    }
    return row
end

local VocabDeckCardList = FocusManager:extend{
    title = "",
    plugin = nil,
    book_id = nil,
    filter_book_id = nil,
    filter_text = "",
    filter_word_type = "",
    filter_source_language = "",
    filter_flagged = false,
    filter_ai_status = false,  -- false = all, true = not enriched only
    reviewable_only = false,
    show_known = false,
    quick_delete = false,
    sort_by = "added",
    sort_dir = "desc",
    show_page = 1,
    item_table = nil,
    total_items = 0,
    -- Tracks (y_start, y_end, card_index) for hit-testing Tap/Hold on lightweight rows.
    _row_positions = {},
}

local SORT_LABELS = {
    due = _("due time"),
    alphabet = _("alphabet"),
    edited = _("edited time"),
    added = _("added time"),
}

local SORT_ORDER = { "due", "alphabet", "edited", "added" }

local SORT_DIR_LABELS = {
    asc = _("ascending"),
    desc = _("descending"),
}

local SORT_DIR_ORDER = { "asc", "desc" }

local function normalizeSortBy(value)
    return SORT_LABELS[value] and value or "added"
end

local function normalizeSortDir(value)
    return SORT_DIR_LABELS[value] and value or "desc"
end

local function isDefaultSort(sort_by, sort_dir)
    return normalizeSortBy(sort_by) == "added" and normalizeSortDir(sort_dir) == "desc"
end

function VocabDeckCardList:getTitle()
    local title = self.title
    if self.filter_text and self.filter_text ~= "" then
        title = string.format("%s  [%s]", title, self.filter_text)
    end
    if self.filter_word_type and self.filter_word_type ~= "" then
        title = string.format("%s  [%s]", title, self.filter_word_type)
    end
    if self.filter_source_language and self.filter_source_language ~= "" then
        title = string.format("%s  [%s]", title, self.filter_source_language)
    end
    if self.filter_flagged then
        title = string.format("%s  [%s]", title, _("flagged"))
    end
    if self.filter_ai_status then
        title = string.format("%s  [%s]", title, _("not enriched"))
    end
    if not isDefaultSort(self.sort_by, self.sort_dir) then
        title = string.format("%s  [%s, %s]", title,
            SORT_LABELS[self.sort_by] or SORT_LABELS.added,
            SORT_DIR_LABELS[self.sort_dir] or SORT_DIR_LABELS.desc)
    end
    return title
end

-- Re-count total items and recalculate pagination.
-- Only needed when filters change or cards are added/deleted.
function VocabDeckCardList:_recount()
    local now = os.time()
    local book_id = self.filter_book_id or self.book_id
    self.total_items = DB.countCards(book_id, false, self.reviewable_only,
        self.filter_text, now, self.filter_word_type, self.filter_source_language,
        self.show_known, self.filter_flagged, self.filter_ai_status)
    self.pages = math.ceil(self.total_items / self.items_per_page)
    self.show_page = math.max(1, math.min(math.max(1, self.pages), self.show_page))
end

-- Fetch the current page of cards (SELECT with LIMIT/OFFSET).
-- Does NOT re-count — call _recount() separately when filters change.
function VocabDeckCardList:_fetchPage()
    local now = os.time()
    local book_id = self.filter_book_id or self.book_id
    local offset = (self.show_page - 1) * self.items_per_page
    return DB.listCardsPage(book_id, false, self.reviewable_only, self.filter_text,
        self.items_per_page, offset, now, self.sort_by, self.sort_dir,
        self.filter_word_type, self.filter_source_language, self.show_known,
        self.filter_flagged, self.filter_ai_status)
end

-- Full reload: re-count + fetch page. Used on initial load and filter changes.
function VocabDeckCardList:loadItems()
    self:_recount()
    return self:_fetchPage()
end

-- Fetch a single card at the given global 1-based index using the same
-- filters, sort order, and book scope as the current card list view.
function VocabDeckCardList:fetchCardAtGlobalIndex(global_idx)
    local now = os.time()
    local book_id = self.filter_book_id or self.book_id
    local cards = DB.listCardsPage(book_id, false, self.reviewable_only, self.filter_text,
        1, global_idx - 1, now, self.sort_by, self.sort_dir,
        self.filter_word_type, self.filter_source_language, self.show_known,
        self.filter_flagged, self.filter_ai_status)
    return cards and cards[1] or nil
end

function VocabDeckCardList:init()
    self.item_table = {}
    self.total_items = 0
    self.layout = {}
    self.dimen = Geom:new{
        w = Screen:getWidth(),
        h = Screen:getHeight(),
    }

    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
        self.ges_events.Hold = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        }
    end

    self.page_info = HorizontalGroup:new{}
    self:refreshFooter()

    local bottom_line = LineWidget:new{
        dimen = Geom:new{ w = self.item_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    local vertical_footer = VerticalGroup:new{
        bottom_line,
        self.page_info,
    }
    self.footer_height = vertical_footer:getSize().h
    local footer = BottomContainer:new{
        dimen = self.dimen:copy(),
        vertical_footer,
    }

    self.title_bar = TitleBar:new{
        width = self.dimen.w,
        align = "center",
        title_face = Font:getFace("smallinfofontbold"),
        bottom_line_color = Blitbuffer.COLOR_LIGHT_GRAY,
        with_bottom_line = true,
        bottom_line_h_padding = Size.padding.large,
        left_icon = "appbar.menu",
        left_icon_tap_callback = function() self:onShowMenu() end,
        title = self:getTitle(),
        close_callback = function() self:onClose() end,
        show_parent = self,
    }

    self:setupItemHeight()
    self.item_table = self:loadItems()
    self.main_content = VerticalGroup:new{}
    self:_populateItems()

    local frame_content = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            self.title_bar,
            self.main_content,
        },
    }
    local content = OverlapGroup:new{
        dimen = self.dimen:copy(),
        frame_content,
        footer,
    }
    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

function VocabDeckCardList:refreshFooter()
    self.page_info:clear()
    local padding = Size.padding.large
    self.width_widget = self.dimen.w - 2 * padding
    self.item_width = self.width_widget
    self.footer_center_width = math.floor(self.width_widget * 32 / 100)
    self.footer_button_width = math.floor(self.width_widget * 12 / 100)
    self.footer_side_width = math.floor(self.width_widget * 10 / 100)

    local chevron_left = "chevron.left"
    local chevron_right = "chevron.right"
    local chevron_first = "chevron.first"
    local chevron_last = "chevron.last"
    if BD.mirroredUILayout() then
        chevron_left, chevron_right = chevron_right, chevron_left
        chevron_first, chevron_last = chevron_last, chevron_first
    end

    self.footer_first = Button:new{
        icon = chevron_first,
        width = self.footer_button_width,
        callback = function() self:goToPage(1) end,
        bordersize = 0,
        radius = 0,
        show_parent = self,
    }
    self.footer_prev = Button:new{
        icon = chevron_left,
        width = self.footer_button_width,
        callback = function() self:prevPage() end,
        bordersize = 0,
        radius = 0,
        show_parent = self,
    }
    self.footer_page = Button:new{
        text = "",
        hold_input = {
            title = _("Enter page number"),
            input_type = "number",
            hint_func = function()
                return string.format("(1 - %s)", self.pages or 1)
            end,
            callback = function(input)
                local page = tonumber(input)
                if page and page >= 1 and page <= self.pages then
                    self:goToPage(page)
                end
            end,
            ok_text = _("Go to page"),
        },
        call_hold_input_on_tap = true,
        bordersize = 0,
        margin = 0,
        text_font_face = "pgfont",
        text_font_bold = false,
        width = self.footer_center_width,
        show_parent = self,
    }
    self.footer_next = Button:new{
        icon = chevron_right,
        width = self.footer_button_width,
        callback = function() self:nextPage() end,
        bordersize = 0,
        radius = 0,
        show_parent = self,
    }
    self.footer_last = Button:new{
        icon = chevron_last,
        width = self.footer_button_width,
        callback = function() self:goToPage(self.pages) end,
        bordersize = 0,
        radius = 0,
        show_parent = self,
    }
    self.footer_filter = Button:new{
        text = _("Filter"),
        width = self.footer_side_width,
        bordersize = 0,
        radius = 0,
        show_parent = self,
        callback = function() self:showFilterDialog() end,
    }

    table.insert(self.page_info, HorizontalSpan:new{ width = self.footer_side_width })
    table.insert(self.page_info, self.footer_first)
    table.insert(self.page_info, self.footer_prev)
    table.insert(self.page_info, self.footer_page)
    table.insert(self.page_info, self.footer_next)
    table.insert(self.page_info, self.footer_last)
    table.insert(self.page_info, self.footer_filter)
end

function VocabDeckCardList:setupItemHeight()
    self.item_height = Screen:scaleBySize(62)
    self.item_margin = Screen:scaleBySize(2)
    local line_height = self.item_height + self.item_margin
    local content_height = self.dimen.h - self.title_bar:getHeight() - self.footer_height - Size.padding.large
    self.items_per_page = math.max(1, math.floor(content_height / line_height))
    self.pages = math.ceil((self.total_items or #self.item_table) / self.items_per_page)
    self.show_page = math.max(1, math.min(math.max(1, self.pages), self.show_page))
end

function VocabDeckCardList:_populateItems()
    self.main_content:clear()
    self.layout = {{self.title_bar.left_button, self.title_bar.right_button}}
    self._row_positions = {}
    self:setupItemHeight()

    -- Gesture coordinates are relative to self (full screen).
    -- main_content starts below the title bar, so we offset row positions.
    local content_y_offset = self.title_bar:getHeight()
    local y_offset = 0
    for idx, card in ipairs(self.item_table) do
        local margin = self.item_margin / (idx == 1 and 2 or 1)
        table.insert(self.main_content, VerticalSpan:new{ width = margin })
        y_offset = y_offset + margin
        local row = buildRowWidget(self.item_width, self.item_height, card, nil,
            self.quick_delete, self)
        table.insert(self.main_content, row)
        -- Record row position for hit-testing (screen coordinates)
        table.insert(self._row_positions, {
            y_start = content_y_offset + y_offset,
            y_end = content_y_offset + y_offset + self.item_height,
            card = card,
            idx = idx,
        })
        y_offset = y_offset + self.item_height
    end
    if (self.total_items or 0) == 0 then
        local has_filter = (self.filter_text ~= "")
            or ((self.filter_word_type or "") ~= "")
            or ((self.filter_source_language or "") ~= "")
        local text = has_filter and _("No cards match filter") or _("No cards")
        table.insert(self.main_content, VerticalSpan:new{ width = self.item_margin })
        table.insert(self.main_content, buildRowWidget(self.item_width, self.item_height, nil, text,
            false, self))
        self.footer_page:setText(text, self.footer_center_width)
    else
        self.footer_page:setText(T(_("Page %1 of %2"), self.show_page, self.pages), self.footer_center_width)
    end

    local can_prev = self.pages > 1 and self.show_page > 1
    local can_next = self.pages > 1 and self.show_page < self.pages
    self.footer_prev:enableDisable(can_prev)
    self.footer_first:enableDisable(can_prev)
    self.footer_next:enableDisable(can_next)
    self.footer_last:enableDisable(can_next)
    if self.title_bar and self.title_bar.setTitle then
        self.title_bar:setTitle(self:getTitle())
    end
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

-- Hit-test Tap on lightweight rows (no per-row InputContainer overhead).
function VocabDeckCardList:onTap(arg, ges)
    local y = ges.pos.y
    for __, entry in ipairs(self._row_positions) do
        if y >= entry.y_start and y < entry.y_end then
            if entry.card then
                local global_idx = (self.show_page - 1) * self.items_per_page + entry.idx
                showCardDetails(self.plugin, entry.card, {
                    cards = self.item_table,
                    global_idx = global_idx,
                    total = self.total_items,
                    fetch_at = function(idx) return self:fetchCardAtGlobalIndex(idx) end,
                }, function()
                    self:reloadItems()
                end)
            end
            return true
        end
    end
    return false
end

-- Hit-test Hold on lightweight rows.
function VocabDeckCardList:onHold(arg, ges)
    local y = ges.pos.y
    for __, entry in ipairs(self._row_positions) do
        if y >= entry.y_start and y < entry.y_end then
            if entry.card then
                UIManager:show(ConfirmBox:new{
                    text = string.format(_("Delete card \"%s\"?"), entry.card.phrase or ""),
                    ok_text = _("Delete"),
                    ok_callback = function()
                        DB.deleteCard(entry.card.id)
                        self:reloadItems()
                    end,
                })
            end
            return true
        end
    end
    return false
end

function VocabDeckCardList:reloadItems()
    self:setupItemHeight()
    self.item_table = self:loadItems()
    self:_populateItems()
end

function VocabDeckCardList:nextPage()
    if self.show_page < self.pages then
        self.show_page = self.show_page + 1
        self.item_table = self:_fetchPage()
        self:_populateItems()
    end
end

function VocabDeckCardList:prevPage()
    if self.show_page > 1 then
        self.show_page = self.show_page - 1
        self.item_table = self:_fetchPage()
        self:_populateItems()
    end
end

function VocabDeckCardList:goToPage(page)
    if not page or self.pages == 0 then return end
    self.show_page = math.max(1, math.min(self.pages, page))
    self.item_table = self:_fetchPage()
    self:_populateItems()
end

function VocabDeckCardList:showFilterDialog()
    local dialog
    local buttons = {}

    local function closeDialog()
        if dialog then
            UIManager:close(dialog)
        end
    end

    buttons[#buttons + 1] = { {
        text = _("Word type"),
        callback = function()
            closeDialog()
            self:showWordTypeFilterDialog()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Source language"),
        callback = function()
            closeDialog()
            self:showSourceLanguageFilterDialog()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Flagged cards"),
        checked_func = function()
            return self.filter_flagged and true or false
        end,
        keep_menu_open = true,
        callback = function()
            self.filter_flagged = not self.filter_flagged
            self.show_page = 1
            self:reloadItems()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("not ai enriched"),
        checked_func = function()
            return self.filter_ai_status and true or false
        end,
        keep_menu_open = true,
        callback = function()
            self.filter_ai_status = not self.filter_ai_status
            self.show_page = 1
            self:reloadItems()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Clear filters"),
        enabled = (self.filter_word_type or "") ~= ""
            or (self.filter_source_language or "") ~= ""
            or (self.filter_text or "") ~= ""
            or self.filter_flagged
            or self.filter_ai_status,
        callback = function()
            self.filter_word_type = ""
            self.filter_source_language = ""
            self.filter_text = ""
            self.filter_flagged = false
            self.filter_ai_status = false
            closeDialog()
            self.show_page = 1
            self:reloadItems()
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = closeDialog,
    } }

    dialog = ButtonDialog:new{
        title = _("Filter cards"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function VocabDeckCardList:showWordTypeFilterDialog()
    local dialog
    local buttons = {}
    local book_id = self.filter_book_id or self.book_id
    local word_types = DB.listWordTypes(book_id)

    local function setWordType(word_type)
        self.filter_word_type = word_type or ""
        if dialog then UIManager:close(dialog) end
        self.show_page = 1
        self:reloadItems()
    end

    for _, word_type in ipairs(word_types) do
        buttons[#buttons + 1] = { {
            text = word_type,
            enabled = self.filter_word_type ~= word_type,
            callback = function()
                setWordType(word_type)
            end,
        } }
    end
    if #buttons == 0 then
        buttons[#buttons + 1] = { {
            text = _("No word types yet"),
            enabled = false,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Clear word type"),
        enabled = (self.filter_word_type or "") ~= "",
        callback = function()
            setWordType("")
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            self:showFilterDialog()
        end,
    } }

    dialog = ButtonDialog:new{
        title = _("Word type"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function VocabDeckCardList:showSourceLanguageFilterDialog()
    local dialog
    local buttons = {}
    local book_id = self.filter_book_id or self.book_id
    local now = os.time()
    -- Only show languages that have cards matching the current filter criteria.
    local source_languages = DB.listSourceLanguagesWithCards(
        book_id, false, self.reviewable_only,
        self.filter_text, now, self.filter_word_type,
        self.show_known, self.filter_flagged)

    local function setSourceLanguage(language)
        self.filter_source_language = language or ""
        if dialog then UIManager:close(dialog) end
        self.show_page = 1
        self:reloadItems()
    end

    for _, language in ipairs(source_languages) do
        buttons[#buttons + 1] = { {
            text = language,
            enabled = self.filter_source_language ~= language,
            callback = function()
                setSourceLanguage(language)
            end,
        } }
    end
    if #buttons == 0 then
        buttons[#buttons + 1] = { {
            text = _("No source languages yet"),
            enabled = false,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("No language"),
        enabled = self.filter_source_language ~= "NONE",
        callback = function()
            setSourceLanguage("NONE")
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Clear source language"),
        enabled = (self.filter_source_language or "") ~= "" and self.filter_source_language ~= "NONE",
        callback = function()
            setSourceLanguage("")
        end,
    } }
    buttons[#buttons + 1] = { {
        text = _("Back"),
        callback = function()
            UIManager:close(dialog)
            self:showFilterDialog()
        end,
    } }

    dialog = ButtonDialog:new{
        title = _("Source language"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function VocabDeckCardList:showTextFilterDialog()
    local dialog
    local function closeDialog()
        if dialog then
            if dialog.onCloseKeyboard then
                dialog:onCloseKeyboard()
            end
            UIManager:close(dialog)
            UIManager:setDirty(nil, "ui")
        end
    end
    dialog = InputDialog:new{
        title = _("Text search"),
        description = _("Match phrase, meaning, note, word type, pronunciation or sentence."),
        input = self.filter_text or "",
        input_hint = _("Filter text"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                background = Blitbuffer.COLOR_WHITE,
                callback = closeDialog,
            },
            {
                text = _("Clear"),
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    closeDialog()
                    self.filter_text = ""
                    self.show_page = 1
                    self:reloadItems()
                end,
            },
            {
                text = _("OK"),
                is_enter_default = true,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local raw = dialog:getInputText() or ""
                    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    closeDialog()
                    self.filter_text = raw
                    self.show_page = 1
                    self:reloadItems()
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function VocabDeckCardList:showBookFilter()
    if self.book_id then
        UIManager:show(InfoMessage:new{ text = _("Already showing one book."), timeout = 2 })
        return
    end
    local books = DB.listBooks()
    local menu
    local items = {
        {
            text_func = function()
                return self.filter_book_id == nil and "✓ " .. _("All books") or _("All books")
            end,
            callback = function()
                self.filter_book_id = nil
                self.show_page = 1
                self:reloadItems()
                if menu then UIManager:close(menu) end
            end,
        },
    }
    for _, book in ipairs(books) do
        local book_id = book.id
        local title = book.title or _("Untitled")
        items[#items + 1] = {
            text_func = function()
                return self.filter_book_id == book_id and "✓ " .. title or title
            end,
            mandatory = tostring(book.card_count or 0),
            callback = function()
                self.filter_book_id = book_id
                self.show_page = 1
                self:reloadItems()
                if menu then UIManager:close(menu) end
            end,
        }
    end
    menu = Menu:new{
        title = _("Filter books"),
        item_table = items,
        covers_fullscreen = true,
    }
    UIManager:show(menu)
end

local DEFAULT_SORT_BY = "added"
local DEFAULT_SORT_DIR = "desc"
local SORT_DIR_SYMBOLS = { asc = "↑", desc = "↓" }

function VocabDeckCardList:showSortDialog()
    local dialog
    local function applySort(sort_by, sort_dir)
        self.sort_by = sort_by or self.sort_by
        self.sort_dir = sort_dir or self.sort_dir
        if dialog then
            UIManager:close(dialog)
        end
        self.show_page = 1
        self:reloadItems()
        self:showSortDialog()
    end

    local buttons = {}
    for __, sort_dir in ipairs(SORT_DIR_ORDER) do
        local selected = self.sort_dir == sort_dir
        buttons[#buttons + 1] = { {
            text = string.format("%s %s", selected and "[x]" or "[ ]", SORT_DIR_LABELS[sort_dir]),
            enabled = not selected,
            callback = function()
                applySort(self.sort_by, sort_dir)
            end,
        } }
    end
    for __, sort_by in ipairs(SORT_ORDER) do
        local selected = self.sort_by == sort_by
        buttons[#buttons + 1] = { {
            text = string.format("%s %s", selected and "[x]" or "[ ]", SORT_LABELS[sort_by]),
            enabled = not selected,
            callback = function()
                applySort(sort_by, self.sort_dir)
            end,
        } }
    end
    buttons[#buttons + 1] = { {
        text = _("Close"),
        callback = function()
            UIManager:close(dialog)
        end,
    } }

    dialog = ButtonDialog:new{
        title = _("Sort"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function VocabDeckCardList:onShowMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = _("VocabDeck cards"),
        buttons = {
            { {
                text = self.book_id and _("Fetch AI data for this book") or _("Fetch AI data for all cards"),
                callback = function()
                    UIManager:close(dialog)
                    if self.plugin and self.plugin.bulkFetchMissing then
                        self.plugin:bulkFetchMissing(self.book_id, function()
                            self:reloadItems()
                        end)
                    end
                end,
            } },
            { {
                text = _("Search"),
                callback = function()
                    UIManager:close(dialog)
                    self:showTextFilterDialog()
                end,
            } },
            { {
                text = _("Filter books"),
                enabled = self.book_id == nil,
                callback = function()
                    UIManager:close(dialog)
                    self:showBookFilter()
                end,
            } },
            { {
                text = string.format(_("Sort by: %s, %s"),
                    SORT_LABELS[self.sort_by] or SORT_LABELS.added,
                    SORT_DIR_LABELS[self.sort_dir] or SORT_DIR_LABELS.desc),
                callback = function()
                    UIManager:close(dialog)
                    self:showSortDialog()
                end,
            } },
            { {
                text = _("Quick deletion"),
                callback = function()
                    self.quick_delete = not self.quick_delete
                    UIManager:close(dialog)
                    self:reloadItems()
                end,
            } },
            { {
                text = _("Close"),
                callback = function() UIManager:close(dialog) end,
            } },
        },
    }
    UIManager:show(dialog)
end

function VocabDeckCardList:onShow()
    UIManager:setDirty(self, "flashui")
end

function VocabDeckCardList:onNextPage()
    self:nextPage()
    return true
end

function VocabDeckCardList:onPrevPage()
    self:prevPage()
    return true
end

function VocabDeckCardList:onSwipe(_, ges_ev)
    local direction = BD.flipDirectionIfMirroredUILayout(ges_ev.direction)
    if direction == "west" then
        self:onNextPage()
    elseif direction == "east" then
        self:onPrevPage()
    elseif direction == "south" then
        self:onClose()
    elseif direction == "north" then
        self:showFilterDialog()
    else
        return false
    end
    return true
end

function VocabDeckCardList:onClose()
    UIManager:close(self)
end

function VocabDeckCardList:onReturn()
    return self:onClose()
end

-- Public: open the card list screen.
-- @param plugin   VocabDeck plugin instance
-- @param book_id  nil = all books
-- @param title    string shown in the title bar
function Edit.showList(plugin, book_id, title)
    UIManager:show(VocabDeckCardList:new{
        title = title or _("VocabDeck cards"),
        plugin = plugin,
        book_id = book_id,
        sort_by = DEFAULT_SORT_BY,
        sort_dir = DEFAULT_SORT_DIR,
    })
end

-- Public: open the single-card editor used by card details and study mode.
function Edit.showCardEditor(plugin, card, on_saved)
    if not card then return end
    UIManager:nextTick(function()
        showEditDialog(plugin, card, on_saved)
    end)
end

return Edit
