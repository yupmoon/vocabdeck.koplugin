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
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Button = require("ui/widget/button")
local FocusManager = require("ui/widget/focusmanager")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TitleBar = require("ui/widget/titlebar")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")
local T = require("ffi/util").template

local Screen = Device.screen

local Dialogs = require("vocabdeck_card_dialogs")
local DB = require("vocabdeck_db")
local Filters = require("vocabdeck_card_filters")
local Row = require("vocabdeck_card_row")

local Edit = {}

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
    filter_not_started = false,
    filter_learning = false,
    filter_learned = false,
    filter_weak = false,
    filter_leech = false,
    filter_suspended = false,
    reviewable_only = false,
    show_known = false,
    quick_delete = false,
    sort_by = "added",
    sort_dir = "desc",
    show_page = 1,
    item_table = nil,
    total_items = 0,
    active_language = nil,  -- current language for all-cards tab view
    language_tabs = nil,    -- HorizontalGroup of language tab buttons
    -- Tracks (y_start, y_end, card_index) for hit-testing Tap/Hold on lightweight rows.
    _row_positions = {},
}

local function hasActiveFilters(self)
    return (self.filter_text or "") ~= ""
        or (self.filter_word_type or "") ~= ""
        or (self.filter_source_language or "") ~= ""
        or self.filter_ai_status
        or self.filter_flagged
        or self.filter_not_started
        or self.filter_learning
        or self.filter_learned
        or self.filter_weak
        or self.filter_leech
        or self.filter_suspended
        or self.filter_book_id ~= nil
end

function VocabDeckCardList:getScopeLabel()
    if self.book_id then
        local language = DB.getActiveLanguage()
        if language and language ~= "" then
            return string.format(_("Book · %s"), language)
        end
        return _("Book")
    end
    local language = self.active_language or DB.getActiveLanguage()
    if language and language ~= "" then
        return string.format(_("All books · %s"), language)
    end
    return _("All books")
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
    if self.filter_not_started then
        title = string.format("%s  [%s]", title, _("not started"))
    elseif self.filter_learning then
        title = string.format("%s  [%s]", title, _("learning"))
    elseif self.filter_learned then
        title = string.format("%s  [%s]", title, _("learned"))
    elseif self.filter_weak then
        title = string.format("%s  [%s]", title, _("weak"))
    elseif self.filter_leech then
        title = string.format("%s  [%s]", title, _("leeches"))
    elseif self.filter_suspended then
        title = string.format("%s  [%s]", title, _("suspended"))
    end
    if not Filters.isDefaultSort(self.sort_by, self.sort_dir) then
        local sort_label, dir_label = Filters.getTitleSortLabel(self.sort_by, self.sort_dir)
        title = string.format("%s  [%s, %s]", title,
            sort_label, dir_label)
    end
    return title
end

function VocabDeckCardList:getCardStateFilter()
    if self.filter_not_started then
        return "not_started"
    elseif self.filter_learning then
        return "learning"
    elseif self.filter_learned then
        return "learned"
    elseif self.filter_weak then
        return "weak"
    elseif self.filter_leech then
        return "leech"
    elseif self.filter_suspended then
        return "suspended"
    end
    return nil
end

function VocabDeckCardList:shouldIncludeKnown()
    return self.show_known or self.filter_learned or self.filter_suspended
end

-- Re-count total items and recalculate pagination.
-- Only needed when filters change or cards are added/deleted.
function VocabDeckCardList:_recount()
    local now = os.time()
    local book_id = self.filter_book_id or self.book_id
    self.total_items = DB.countCards(book_id, false, self.reviewable_only,
        self.filter_text, now, self.filter_word_type, self.filter_source_language,
        self:shouldIncludeKnown(), self.filter_flagged, self.filter_ai_status, self:getCardStateFilter())
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
        self.filter_word_type, self.filter_source_language, self:shouldIncludeKnown(),
        self.filter_flagged, self.filter_ai_status, self:getCardStateFilter())
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
        self.filter_word_type, self.filter_source_language, self:shouldIncludeKnown(),
        self.filter_flagged, self.filter_ai_status, self:getCardStateFilter())
    return cards and cards[1] or nil
end

function VocabDeckCardList:_buildLanguageTabs()
    local languages = DB.listLanguages()
    if #languages <= 1 then
        self.language_tabs = nil
        self.tab_bar_height = 0
        return
    end
    if not self.active_language then
        local current = DB.getActiveLanguage()
        self.active_language = current or languages[1]
        DB.setLanguage(self.active_language)
    end
    local tab_group = HorizontalGroup:new{}
    local tab_height = Screen:scaleBySize(28)
    local available_w = self.dimen.w - 2 * Size.padding.small
    local tab_width = math.floor(available_w / #languages)
    for _, lang in ipairs(languages) do
        local is_active = (lang == self.active_language)
        local tab = Button:new{
            text = lang,
            width = tab_width,
            max_width = tab_width,
            text_font_face = "smallinfofont",
            text_font_bold = is_active,
            bordersize = 0,
            radius = 0,
            padding_h = Size.padding.small,
            background = is_active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
            callback = function()
                self:switchLanguage(lang)
            end,
            show_parent = self,
        }
        table.insert(tab_group, tab)
    end
    self.language_tabs = tab_group
    self.tab_bar_height = tab_height
end

function VocabDeckCardList:switchLanguage(language)
    if self.active_language == language then return end
    self.active_language = language
    DB.setLanguage(language)
    -- Rebuild tabs in-place (tabs are in the footer now)
    if self.language_tabs then
        while #self.language_tabs > 0 do
            self.language_tabs[#self.language_tabs] = nil
        end
        local languages = DB.listLanguages()
        local available_w = self.dimen.w - 2 * Size.padding.small
        local tab_width = math.floor(available_w / #languages)
        for _, lang in ipairs(languages) do
            local is_active = (lang == language)
            local tab = Button:new{
                text = lang,
                width = tab_width,
                max_width = tab_width,
                text_font_face = "smallinfofont",
                text_font_bold = is_active,
                bordersize = 0,
                radius = 0,
                padding_h = Size.padding.small,
                background = is_active and Blitbuffer.COLOR_LIGHT_GRAY or Blitbuffer.COLOR_WHITE,
                callback = function()
                    self:switchLanguage(lang)
                end,
                show_parent = self,
            }
            table.insert(self.language_tabs, tab)
        end
    end
    self:setupItemHeight()
    self:_recount()
    self.item_table = self:_fetchPage()
    self.show_page = 1
    self:_populateItems()
    self:updateTitleBar()
    self:refreshFooter()
end

function VocabDeckCardList:updateTitleBar()
    if self.title_bar then
        self.title_bar:setTitle(self:getTitle())
    end
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

    -- Build language tabs for all-cards view (not book-specific)
    if not self.book_id then
        self:_buildLanguageTabs()
    else
        self.tab_bar_height = 0
    end

    self.page_info = HorizontalGroup:new{}
    self:refreshFooter()

    local bottom_line = LineWidget:new{
        dimen = Geom:new{ w = self.item_width, h = Size.line.thick },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    local footer_children = VerticalGroup:new{}
    if self.language_tabs then
        table.insert(footer_children, self.language_tabs)
    end
    table.insert(footer_children, bottom_line)
    table.insert(footer_children, self.page_info)
    self.footer_height = footer_children:getSize().h
    self.footer_widget = BottomContainer:new{
        dimen = self.dimen:copy(),
        footer_children,
    }

    self:setupItemHeight()
    self.item_table = self:loadItems()
    self.main_content = VerticalGroup:new{}
    self:_populateItems()

    local frame_children = VerticalGroup:new{}
    table.insert(frame_children, self.title_bar)
    table.insert(frame_children, self.main_content)
    self.frame_children = frame_children  -- store for tab switching

    self:_buildFrame()
end

function VocabDeckCardList:_buildFrame()
    local frame_content = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        self.frame_children,
    }
    local content = OverlapGroup:new{
        dimen = self.dimen:copy(),
        frame_content,
        self.footer_widget,
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
    self.footer_actions = Button:new{
        text = _("Actions"),
        width = self.footer_side_width,
        bordersize = 0,
        radius = 0,
        show_parent = self,
        callback = function() self:showActionsDialog() end,
    }

    table.insert(self.page_info, HorizontalSpan:new{ width = self.footer_side_width })
    table.insert(self.page_info, self.footer_first)
    table.insert(self.page_info, self.footer_prev)
    table.insert(self.page_info, self.footer_page)
    table.insert(self.page_info, self.footer_next)
    table.insert(self.page_info, self.footer_last)
    table.insert(self.page_info, self.footer_actions)
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
    -- main_content starts below the title bar.
    local content_y_offset = self.title_bar:getHeight()
    local y_offset = Size.padding.small
    for idx, card in ipairs(self.item_table) do
        local margin = self.item_margin / (idx == 1 and 2 or 1)
        table.insert(self.main_content, VerticalSpan:new{ width = margin })
        y_offset = y_offset + margin
        local row = Row.buildRowWidget(self.item_width, self.item_height, card, nil,
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
        local text
        if hasActiveFilters(self) then
            text = string.format(_("No cards match filters in %s"), self:getScopeLabel())
        elseif self.book_id then
            text = _("No cards for this book")
        elseif self.active_language then
            text = string.format(_("No cards in %s"), self.active_language)
        else
            text = _("No cards yet")
        end
        table.insert(self.main_content, VerticalSpan:new{ width = self.item_margin })
        table.insert(self.main_content, Row.buildRowWidget(self.item_width, self.item_height, nil, text,
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
        return "fast", self.dimen
    end)
end

-- Hit-test Tap on lightweight rows (no per-row InputContainer overhead).
function VocabDeckCardList:onTap(arg, ges)
    local y = ges.pos.y
    for __, entry in ipairs(self._row_positions) do
        if y >= entry.y_start and y < entry.y_end then
            if entry.card then
                local global_idx = (self.show_page - 1) * self.items_per_page + entry.idx
                Dialogs.showCardDetails(self.plugin, entry.card, {
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

VocabDeckCardList.showActionsDialog = Filters.showActionsDialog
VocabDeckCardList.showWordTypeFilterDialog = Filters.showWordTypeFilterDialog
VocabDeckCardList.showSourceLanguageFilterDialog = Filters.showSourceLanguageFilterDialog
VocabDeckCardList.showTextFilterDialog = Filters.showTextFilterDialog
VocabDeckCardList.showBookFilter = Filters.showBookFilter
VocabDeckCardList.showSortDialog = Filters.showSortDialog
VocabDeckCardList.onShowMenu = Filters.onShowMenu

function VocabDeckCardList:onShow()
    UIManager:setDirty(self, "partial")
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
        self:showActionsDialog()
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
-- @param options  optional initial filters for callers such as the dashboard
function Edit.showList(plugin, book_id, title, options)
    options = options or {}
    local sort_by = Filters.DEFAULT_SORT_BY
    local sort_dir = Filters.DEFAULT_SORT_DIR
    if book_id and plugin and plugin.readSetting then
        sort_by = plugin:readSetting("card_list_sort", Filters.DEFAULT_SORT_BY)
        sort_dir = plugin:readSetting("card_list_sort_dir", Filters.DEFAULT_SORT_DIR)
    end
    if options.active_language and options.active_language ~= "" then
        DB.setLanguage(options.active_language)
    end
    UIManager:show(VocabDeckCardList:new{
        title = title or _("VocabDeck cards"),
        plugin = plugin,
        book_id = book_id,
        active_language = options.active_language,
        filter_text = options.filter_text or "",
        filter_ai_status = options.filter_ai_status or false,
        filter_flagged = options.filter_flagged or false,
        filter_not_started = options.filter_not_started or false,
        filter_learning = options.filter_learning or false,
        filter_learned = options.filter_learned or false,
        filter_weak = options.filter_weak or false,
        filter_leech = options.filter_leech or false,
        filter_suspended = options.filter_suspended or false,
        show_known = options.show_known or false,
        sort_by = Filters.normalizeSortBy(sort_by),
        sort_dir = Filters.normalizeSortDir(sort_dir),
    })
end

-- Public: open the single-card editor used by card details and study mode.
function Edit.showCardEditor(plugin, card, on_saved)
    if not card then return end
    UIManager:nextTick(function()
        Dialogs.showEditDialog(plugin, card, on_saved)
    end)
end

return Edit
