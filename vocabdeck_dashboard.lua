-- VocabDeck library dashboard.
--
-- Read-only overview screen for deck health and quick navigation. It reuses
-- existing Study, All cards, Import, and Settings flows instead of introducing
-- new mutation paths.
local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local GestureRange = require("ui/gesturerange")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")

local DB = require("vocabdeck_db")
local Edit = require("vocabdeck_edit")
local Importer = require("vocabdeck_import")
local SettingsModule = require("vocabdeck_settings")
local StudyEntry = require("vocabdeck_study_entry")

local Dashboard = {}

local DASHBOARD_CACHE_TTL = 60  -- seconds
local _dashboard_cache = nil    -- { data, expires_at, version }

local DashboardScreen = InputContainer:extend{
    plugin = nil,
}

local LEARN_AHEAD_SECONDS = 20 * 60
local MAX_LANGUAGE_ROWS = 2
local MAX_BOOK_ROWS = 3
local ICON_WEAK = "\226\154\160"      -- warning sign
local ICON_MISSING = "\226\150\163"   -- document-like outline
local ICON_LEECH = "\226\134\187" -- refresh/loop
local ICON_STUDY = "\226\151\135"
local ICON_CARDS = "\226\150\164"
local ICON_IMPORT = "\226\135\167"
local ICON_SETTINGS = "\226\154\153"
local CHEVRON = "\226\128\186"
local MENU_ICON = "\226\152\176"
local CLOSE_ICON = "\195\151"

local function n(value)
    return tonumber(value) or 0
end

local function shortText(text, max_len)
    text = tostring(text or "")
    max_len = max_len or 28
    if #text <= max_len then return text end
    return text:sub(1, max_len - 1) .. "..."
end

local function getRequireEnriched(plugin)
    if not plugin then return true end
    local value = plugin:readSetting("require_enriched_for_study")
    if value == nil then return true end
    return value and true or false
end

local function emptyData(plugin, loading)
    local active_language = DB.getActiveLanguage()
    return {
        summary = {},
        languages = {},
        books = {},
        first_due_language = nil,
        first_language = active_language,
        missing_ai_language = nil,
        weak_language = nil,
        leech_language = nil,
        suspended_language = nil,
        loading = loading and true or false,
    }
end

local function collectData(plugin)
    local languages = DB.listLanguages()
    local deck_new_limits = {}
    local deck_review_limits = {}
    if plugin then
        for _, language in ipairs(languages) do
            deck_new_limits[language] = tonumber(plugin:readSetting("deck_new_limit_" .. language))
            deck_review_limits[language] = tonumber(plugin:readSetting("deck_review_limit_" .. language))
        end
    end
    local require_enriched = getRequireEnriched(plugin)
    return DB.getDashboardSummary{
        languages = languages,
        require_enriched = require_enriched,
        daily_new_limit = plugin and plugin:readSetting("daily_new_cards_limit", 20) or 20,
        daily_review_limit = plugin and plugin:readSetting("daily_review_cards_limit", 200) or 200,
        deck_new_limits = deck_new_limits,
        deck_review_limits = deck_review_limits,
        learn_ahead_seconds = LEARN_AHEAD_SECONDS,
        max_book_rows = MAX_BOOK_ROWS,
    }
end

local function getCacheVersion()
    if DB.getSummaryCacheVersion then
        return DB.getSummaryCacheVersion()
    end
    return 0
end

local function isCacheFresh()
    return _dashboard_cache
        and _dashboard_cache.expires_at > os.time()
        and _dashboard_cache.version == getCacheVersion()
end

local function getCachedData()
    if isCacheFresh() then
        return _dashboard_cache.data
    end
    return nil
end

local function getLastCachedData()
    return _dashboard_cache and _dashboard_cache.data or nil
end

local function setCachedData(data)
    _dashboard_cache = {
        data = data,
        expires_at = os.time() + DASHBOARD_CACHE_TTL,
        version = getCacheVersion(),
    }
end

function DashboardScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    self.closed = false
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.Tap = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        }
    end

    self.data = getCachedData() or getLastCachedData() or emptyData(self.plugin, true)
    self.page_padding = Screen:scaleBySize(30)
    self.tile_gap = Screen:scaleBySize(10)
    self.section_gap = Screen:scaleBySize(12)
    self.width = self.dimen.w - self.page_padding * 2
    self.left_margin = 0
    self.topbar_h = Screen:scaleBySize(52)
    self.section_h = Screen:scaleBySize(34)
    self.stat_h = Screen:scaleBySize(96)
    self.button_h = Screen:scaleBySize(58)
    self.meta_font_size = 13
    self.top_icon_font_size = 28
    self:rebuildContent()
    self:scheduleRefresh()
end

function DashboardScreen:updateRowHeight()
    local Screen = Device.screen
    local language_rows = self.data.loading and 1 or math.min(#(self.data.languages or {}), MAX_LANGUAGE_ROWS)
    local book_rows = self.data.loading and 1 or math.min(#(self.data.books or {}), MAX_BOOK_ROWS)
    local visible_rows = language_rows + book_rows + 3
    visible_rows = math.max(visible_rows, 1)
    local fixed_h = self.topbar_h + self.tile_gap + self.stat_h
        + self.section_gap * 4 + self.section_h * 3 + self.button_h
    local available_h = self.dimen.h - self.page_padding * 2
    self.row_h = math.floor((available_h - fixed_h) / visible_rows)
    self.row_h = math.max(Screen:scaleBySize(34), math.min(Screen:scaleBySize(44), self.row_h))
end

function DashboardScreen:rebuildContent()
    self:updateRowHeight()
    local content = VerticalGroup:new{}
    table.insert(content, self:buildTopBar())
    table.insert(content, VerticalSpan:new{ width = self.tile_gap })
    table.insert(content, self:buildStatsRow())
    -- Tappable section headers — tap to view all languages/books.
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:makeTappableHeader(_("Languages"), function()
        self:openAllCards(self.data.first_language)
    end))
    for _, row in ipairs(self:buildLanguageRows()) do
        table.insert(content, row)
    end
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:makeTappableHeader(_("Books"), function()
        self:openAllBooks()
    end))
    for _, row in ipairs(self:buildBookRows()) do
        table.insert(content, row)
    end
    self:addSection(content, _("Attention"), self:buildAttentionRows())
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:buildBottomButtons())

    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = self.page_padding,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

function DashboardScreen:onShow()
    local cached = getCachedData() or getLastCachedData()
    if cached then
        self.data = cached
        self:rebuildContent()
    end
    -- Returning from Study or All cards can change due/weak/AI counts while the
    -- dashboard cache is still inside its TTL. Paint cached data first, then
    -- force one async refresh so the visible numbers catch up.
    self:scheduleRefresh(true)
    UIManager:setDirty(self, "partial")
end

function DashboardScreen:scheduleRefresh(force)
    if self.refresh_scheduled or (not force and isCacheFresh()) then return end
    self.refresh_scheduled = true
    UIManager:nextTick(function()
        self.refresh_scheduled = false
        if self.closed or not self[1] then return end
        local ok, data = pcall(collectData, self.plugin)
        if not ok or not data then
            UIManager:show(InfoMessage:new{
                text = _("Dashboard could not be loaded."),
                timeout = 3,
            })
            return
        end
        setCachedData(data)
        self.data = data
        self:rebuildContent()
        UIManager:setDirty(self, "ui")
    end)
end

function DashboardScreen:onTap(_, ges)
    local pos = ges and ges.pos
    if not pos then return false end
    local top_y = 0
    local bottom_y = self.page_padding + self.topbar_h
    if pos.y >= top_y and pos.y <= bottom_y then
        if pos.x >= self.dimen.w - self.page_padding - self.topbar_h - self.tile_gap then
            return self:onClose()
        elseif pos.x <= self.page_padding + self.topbar_h + self.tile_gap then
            self:openSettings()
            return true
        end
    end
    return false
end

function DashboardScreen:makeTextBox(text, width, height, face, alignment, size)
    return TextBoxWidget:new{
        face = Font:getFace(face or "smallinfofont", size),
        text = text or "",
        width = width,
        height = height,
        alignment = alignment or "left",
        height_overflow_show_ellipsis = true,
    }
end

function DashboardScreen:buildTopBar()
    local icon_w = self.topbar_h
    local title_w = self.width - icon_w * 2
    local menu_button = self:makeTopButton(MENU_ICON, icon_w, function() self:openSettings() end)
    local title = CenterContainer:new{
        dimen = Geom:new{ w = title_w, h = self.topbar_h },
            TextWidget:new{
                text = _("VocabDeck"),
                face = Font:getFace("cfont"),
                bold = true,
            },
    }
    local close_button = self:makeTopButton(CLOSE_ICON, icon_w, function() self:onClose() end)
    return HorizontalGroup:new{
        dimen = Geom:new{ w = self.width, h = self.topbar_h },
        menu_button,
        title,
        close_button,
    }
end

function DashboardScreen:makeTopButton(text, width, callback)
    local button = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.topbar_h },
        CenterContainer:new{
            dimen = Geom:new{ w = width, h = self.topbar_h },
            TextWidget:new{
                text = text,
                face = Font:getFace("cfont", self.top_icon_font_size),
            },
        },
    }
    if Device:isTouchDevice() then
        button.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = button.dimen,
                },
            },
        }
        button.onTap = function()
            if callback then callback() end
            return true
        end
    end
    return button
end

function DashboardScreen:makeStatCell(label, value, width, callback)
    local padding = Size.padding.small
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.stat_h },
        FrameContainer:new{
            dimen = Geom:new{ w = width, h = self.stat_h },
            padding = padding,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - padding * 2, h = self.stat_h - padding * 2 },
                VerticalGroup:new{
                    CenterContainer:new{
                        dimen = Geom:new{ w = width - padding * 2, h = math.floor(self.stat_h * 0.38) },
                        TextWidget:new{
                            text = label,
                            face = Font:getFace("smallinfofontbold"),
                        },
                    },
                    CenterContainer:new{
                        dimen = Geom:new{ w = width - padding * 2, h = math.floor(self.stat_h * 0.45) },
                        TextWidget:new{
                            text = tostring(value),
                            face = Font:getFace("smallinfofontbold"),
                        },
                    },
                },
            },
        },
    }
    if callback and Device:isTouchDevice() then
        cell.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = cell.dimen,
                },
            },
        }
        cell.onTap = function()
            callback()
            return true
        end
    end
    return cell
end

function DashboardScreen:progressText(value, total)
    value = n(value)
    total = n(total)
    local percent = total > 0 and math.floor(value * 100 / total + 0.5) or 0
    return percent, tostring(percent) .. "%"
end

function DashboardScreen:languageProgress(row)
    local total = n(row and row.total)
    if total <= 0 then return 0, "0%" end
    local percent = math.floor(n(row.mature) * 100 / total + 0.5)
    percent = math.max(0, math.min(100, percent))
    return percent, tostring(percent) .. "%"
end

function DashboardScreen:makeProgressBox(value, total, width)
    local percent = self:progressText(value, total)
    local height = math.max(Device.screen:scaleBySize(16), math.floor(self.row_h * 0.42))
    local inset = math.max(1, Size.border.thin * 2)
    local inner_w = math.max(1, width - Size.border.thin * 2)
    local inner_h = math.max(1, height - Size.border.thin * 2)
    local fill_w_max = math.max(1, inner_w - inset * 2)
    local fill_h = math.max(1, inner_h - inset * 2)
    local filled_w = math.floor(fill_w_max * percent / 100 + 0.5)
    filled_w = math.max(0, math.min(fill_w_max, filled_w))
    return FrameContainer:new{
        dimen = Geom:new{ w = width, h = height },
        padding = 0,
        bordersize = Size.border.thin,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            HorizontalGroup:new{
                dimen = Geom:new{ w = fill_w_max, h = fill_h },
                LineWidget:new{
                    dimen = Geom:new{ w = filled_w, h = fill_h },
                    background = Blitbuffer.COLOR_BLACK,
                },
                HorizontalSpan:new{ width = fill_w_max - filled_w },
            },
        },
    }
end

function DashboardScreen:makeRow(content, callback)
    local padding = Size.padding.small
    local row = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.row_h },
        FrameContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.row_h },
            padding = padding,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            content,
        },
    }
    if Device:isTouchDevice() then
        row.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = row.dimen,
                },
            },
        }
        row.onTap = function()
            if callback then callback() end
            return true
        end
    end
    return row
end

function DashboardScreen:makePlainRow(text, callback)
    local padding = Size.padding.small
    return self:makeRow(
        self:makeTextBox(text, self.width - padding * 2, self.row_h - padding * 2,
            "smallinfofont", "left"),
        callback
    )
end

function DashboardScreen:makeColumnText(text, width, face, alignment, size)
    local cell_h = self.row_h - Size.padding.small * 2
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = cell_h },
        TextBoxWidget:new{
            face = Font:getFace(face or "smallinfofont", size),
            text = text or "",
            width = width,
            alignment = alignment or "left",
            height_overflow_show_ellipsis = true,
        },
    }
end

function DashboardScreen:makeLanguageRow(row)
    local padding = Size.padding.small
    local inner_w = self.width - padding * 2
    local name_w = math.floor(inner_w * 0.31)
    local due_w = math.floor(inner_w * 0.14)
    local new_w = math.floor(inner_w * 0.14)
    local leading_spacer_w = math.floor(inner_w * 0.03)
    local bar_w = math.floor(inner_w * 0.20)
    local pct_gap_w = math.floor(inner_w * 0.02)
    local pct_w = math.floor(inner_w * 0.08)
    local chevron_w = inner_w - name_w - due_w - new_w - leading_spacer_w - bar_w - pct_gap_w - pct_w
    local percent, pct = self:languageProgress(row)
    local meta_size = self.meta_font_size
    return self:makeRow(HorizontalGroup:new{
        self:makeColumnText(shortText(row.language, 16), name_w, "smallinfofontbold", "left"),
        self:makeColumnText(string.format(_("Due %d"), row.due), due_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(string.format(_("New %d"), row.new), new_w, "smallinfofont", "left", meta_size),
        HorizontalSpan:new{ width = leading_spacer_w },
        CenterContainer:new{
            dimen = Geom:new{ w = bar_w, h = self.row_h - Size.padding.small * 2 },
            self:makeProgressBox(percent, 100, bar_w - Size.padding.small),
        },
        HorizontalSpan:new{ width = pct_gap_w },
        self:makeColumnText(pct, pct_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(CHEVRON, chevron_w, "smallinfofontbold", "right"),
    }, function()
        self:openStudy(row.language)
    end)
end

function DashboardScreen:makeBookRow(row)
    local padding = Size.padding.small
    local inner_w = self.width - padding * 2
    local title_w = math.floor(inner_w * 0.58)
    local due_w = math.floor(inner_w * 0.15)
    local total_w = math.floor(inner_w * 0.21)
    local chevron_w = inner_w - title_w - due_w - total_w
    local meta_size = self.meta_font_size
    return self:makeRow(HorizontalGroup:new{
        self:makeColumnText(shortText(row.title, 24), title_w, "smallinfofont", "left"),
        self:makeColumnText(string.format(_("Due %d"), row.due), due_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(string.format(_("Total %d"), row.total), total_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(CHEVRON, chevron_w, "smallinfofontbold", "right"),
    }, function()
        self:openBook(row)
    end)
end

function DashboardScreen:makeAttentionRow(icon, text, callback)
    local padding = Size.padding.small
    local inner_w = self.width - padding * 2
    local icon_w = math.floor(inner_w * 0.08)
    local text_w = math.floor(inner_w * 0.82)
    local chevron_w = inner_w - icon_w - text_w
    return self:makeRow(HorizontalGroup:new{
        self:makeColumnText(icon, icon_w, "smallinfofont", "center"),
        self:makeColumnText(text, text_w, "smallinfofont", "left"),
        self:makeColumnText(CHEVRON, chevron_w, "smallinfofontbold", "right"),
    }, callback)
end

function DashboardScreen:makeButton(text, width, callback)
    local button = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.button_h },
        FrameContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = width, h = self.button_h },
            padding = Size.padding.small,
            bordersize = Size.border.thin,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - Size.padding.small * 2, h = self.button_h - Size.padding.small * 2 },
                TextWidget:new{
                    text = text,
                    face = Font:getFace("smallinfofont"),
                },
            },
        },
    }
    if Device:isTouchDevice() then
        button.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = button.dimen,
                },
            },
        }
        button.onTap = function()
            if callback then callback() end
            return true
        end
    end
    return button
end

function DashboardScreen:makeTappableHeader(text, callback)
    local header = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.section_h },
        self:makeTextBox(text, self.width, self.section_h, "smallinfofontbold", "left"),
    }
    if callback and Device:isTouchDevice() then
        header.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = header.dimen } },
        }
        header.onTap = function()
            callback()
            return true
        end
    end
    return header
end

function DashboardScreen:addSection(content, title, rows)
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:makeTextBox(title, self.width, self.section_h, "smallinfofontbold", "left"))
    for _, row in ipairs(rows) do
        table.insert(content, row)
    end
end

function DashboardScreen:buildStatsRow()
    local summary = self.data.summary or {}
    local due = n(summary.due)
    local new = n(summary.available_new)
    local weak = n(summary.weak_cards)
    local suspended = n(summary.suspended)
    local gap = self.tile_gap
    local cell_w = math.floor((self.width - gap * 3) / 4)
    return HorizontalGroup:new{
        self:makeStatCell(_("Due"), due, cell_w, function()
            if due <= 0 then
                UIManager:show(InfoMessage:new{ text = _("No cards due."), timeout = 2 })
                return
            end
            self:openStudy(self.data.first_due_language or self.data.first_language)
        end),
        HorizontalSpan:new{ width = gap },
        self:makeStatCell(_("New"), new, cell_w, function()
            if new <= 0 then
                UIManager:show(InfoMessage:new{ text = _("No new cards."), timeout = 2 })
                return
            end
            self:openAllCards(self.data.first_due_language or self.data.first_language, {
                filter_not_started = true,
            })
        end),
        HorizontalSpan:new{ width = gap },
        self:makeStatCell(_("Weak"), weak, cell_w, function()
            self:openWeakCards()
        end),
        HorizontalSpan:new{ width = gap },
        self:makeStatCell(_("Suspended"), suspended, self.width - cell_w * 3 - gap * 3, function()
            self:openSuspendedCards()
        end),
    }
end

function DashboardScreen:buildLanguageRows()
    local rows = {}
    if self.data.loading then
        return { self:makePlainRow(_("Loading..."), nil) }
    end
    if #self.data.languages == 0 then
        return { self:makePlainRow(_("No cards yet"), nil) }
    end
    for i = 1, math.min(#self.data.languages, MAX_LANGUAGE_ROWS) do
        local row = self.data.languages[i]
        rows[#rows + 1] = self:makeLanguageRow(row)
    end
    return rows
end

function DashboardScreen:buildBookRows()
    local rows = {}
    if self.data.loading then
        return { self:makePlainRow(_("Loading..."), nil) }
    end
    if #self.data.books == 0 then
        return { self:makePlainRow(_("No books with cards"), nil) }
    end
    for i = 1, math.min(#self.data.books, MAX_BOOK_ROWS) do
        local row = self.data.books[i]
        rows[#rows + 1] = self:makeBookRow(row)
    end
    return rows
end

function DashboardScreen:buildAttentionRows()
    if self.data.loading then
        return {
            self:makePlainRow(_("Loading..."), nil),
            self:makePlainRow("", nil),
            self:makePlainRow("", nil),
        }
    end
    local summary = self.data.summary or {}
    local weak = n(summary.weak_cards)
    local missing = n(summary.missing_ai)
    local leeches = n(summary.leeches)
    return {
        self:makeAttentionRow(ICON_WEAK, string.format(_("%d weak cards"), weak), function()
            self:openWeakCards()
        end),
        self:makeAttentionRow(ICON_MISSING, string.format(_("%d missing AI data"), missing), function()
            self:openMissingAI()
        end),
        self:makeAttentionRow(ICON_LEECH, string.format(_("%d leeches"), leeches), function()
            self:openLeeches()
        end),
    }
end

function DashboardScreen:buildBottomButtons()
    local gap = self.tile_gap
    local button_w = math.floor((self.width - gap * 3) / 4)
    return HorizontalGroup:new{
        self:makeButton(ICON_STUDY .. " " .. _("Study"), button_w, function() self:openStudy(self.data.first_due_language or self.data.first_language) end),
        HorizontalSpan:new{ width = gap },
        self:makeButton(ICON_CARDS .. " " .. _("All cards"), button_w, function() self:openAllCards(self.data.first_language) end),
        HorizontalSpan:new{ width = gap },
        self:makeButton(ICON_IMPORT .. " " .. _("Import"), button_w, function() self:openImport() end),
        HorizontalSpan:new{ width = gap },
        self:makeButton(ICON_SETTINGS .. " " .. _("Settings"), self.width - button_w * 3 - gap * 3, function() self:openSettings() end),
    }
end

function DashboardScreen:openStudy(language)
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No study deck available."), timeout = 3 })
        return
    end
    StudyEntry.startStudy(self.plugin, language)
end

function DashboardScreen:openAllCards(language, options)
    options = options or {}
    if language and language ~= "" then
        options.active_language = language
    end
    Edit.showList(self.plugin, nil, _("All cards"), options)
end

function DashboardScreen:openBook(row)
    if not row then return end
    if row.language and row.language ~= "" then
        DB.setLanguage(row.language)
    end
    Edit.showList(self.plugin, row.id, row.title, { active_language = row.language })
end

function DashboardScreen:openMissingAI()
    if n(self.data.summary and self.data.summary.missing_ai) <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No missing AI data."), timeout = 2 })
        return
    end
    local language = self.data.missing_ai_language or self.data.first_language
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No missing AI data."), timeout = 2 })
        return
    end
    self:openAllCards(language, { filter_ai_status = true })
end

function DashboardScreen:openWeakCards()
    if n(self.data.summary and self.data.summary.weak_cards) <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No weak cards."), timeout = 2 })
        return
    end
    local language = self.data.weak_language or self.data.first_language
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No weak cards."), timeout = 2 })
        return
    end
    self:openAllCards(language, { filter_weak = true })
end

function DashboardScreen:openLeeches()
    if n(self.data.summary and self.data.summary.leeches) <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No leeches."), timeout = 2 })
        return
    end
    local language = self.data.leech_language or self.data.first_language
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No leeches."), timeout = 2 })
        return
    end
    self:openAllCards(language, { filter_leech = true })
end

function DashboardScreen:openSuspendedCards()
    if n(self.data.summary and self.data.summary.suspended) <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No suspended cards."), timeout = 2 })
        return
    end
    local language = self.data.suspended_language or self.data.first_language
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No suspended cards."), timeout = 2 })
        return
    end
    self:openAllCards(language, { filter_suspended = true, show_known = true })
end

function DashboardScreen:openImport()
    if not self.plugin or not self.plugin.getDocumentFilePath or not self.plugin:getDocumentFilePath() then
        UIManager:show(InfoMessage:new{
            text = _("Open a book to import its Vocabulary Builder words."),
            timeout = 3,
        })
        return
    end
    Importer.showImportDialog(self.plugin)
end

function DashboardScreen:openAllBooks()
    local books = self.data.books
    if not books or #books == 0 then
        UIManager:show(InfoMessage:new{ text = _("No books with cards."), timeout = 2 })
        return
    end
    local items = {}
    for _, b in ipairs(books) do
        local label = b.title or ""
        if label == "" then label = _("Unknown") end
        items[#items + 1] = {
            text = string.format("%s  (%d)", label, b.total),
            callback = function()
                self:openBook(b)
            end,
        }
    end
    local screen = Device.screen
    UIManager:show(Menu:new{
        title = _("Books"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    })
end

function DashboardScreen:openSettings()
    local screen = Device.screen
    UIManager:show(Menu:new{
        title = _("Settings"),
        item_table = SettingsModule.buildMenuItems(self.plugin),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    })
end

function DashboardScreen:onClose()
    self.closed = true
    UIManager:close(self)
    return true
end

function DashboardScreen:onReturn()
    return self:onClose()
end

function Dashboard.show(plugin)
    UIManager:show(DashboardScreen:new{ plugin = plugin })
end

function Dashboard.invalidateCache()
    _dashboard_cache = nil
end

return Dashboard
