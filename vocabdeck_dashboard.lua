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
local IconWidget = require("ui/widget/iconwidget")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
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
local TextUtils = require("vocabdeck_text_utils")

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
local ICON_SUSPENDED = "\226\143\184" -- pause
local CHEVRON = "\226\128\186"
local MODULE_DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*/)")
    or "plugins/vocabdeck.koplugin/"
local DASHBOARD_ICON_DIR = MODULE_DIR .. "icons/dashboard/"

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
        self.ges_events.Swipe = {
            GestureRange:new{ ges = "swipe", range = self.dimen },
        }
    end
    self.data = getCachedData() or getLastCachedData() or emptyData(self.plugin, true)
    self.page_padding = Screen:scaleBySize(34)
    self.page_padding_top = Screen:scaleBySize(24)
    self.page_padding_bottom = Screen:scaleBySize(8)
    self.tile_gap = Screen:scaleBySize(10)
    self.section_gap = Screen:scaleBySize(12)
    self.title_panel_gap = Screen:scaleBySize(4)
    self.card_radius = Screen:scaleBySize(12)
    self.panel_border = math.max(Size.border.thin, Screen:scaleBySize(2))
    self.progress_radius = Size.radius.default
    self.width = self.dimen.w - self.page_padding * 2
    self.left_margin = 0
    self.topbar_h = Screen:scaleBySize(38)
    self.section_h = Screen:scaleBySize(34)
    self.stat_h = Screen:scaleBySize(96)
    self.button_h = Screen:scaleBySize(88)
    self.bottom_icon_size = Screen:scaleBySize(48)
    self.meta_font_size = 13
    self:rebuildContent()
    self:scheduleRefresh()
end

function DashboardScreen:updateRowHeight()
    local Screen = Device.screen
    local language_rows = self.data.loading and 1 or math.min(#(self.data.languages or {}), MAX_LANGUAGE_ROWS)
    local book_rows = self.data.loading and 1 or math.min(#(self.data.books or {}), MAX_BOOK_ROWS)
    local attention_rows = self:getVisibleAttentionRowCount()
    local visible_rows = language_rows + book_rows + attention_rows
    visible_rows = math.max(visible_rows, 1)
    local grouped_panel_count = 2 + (attention_rows > 0 and 1 or 0)
    local divider_count = math.max(0, language_rows - 1)
        + math.max(0, book_rows - 1)
        + math.max(0, attention_rows - 1)
    local panel_extra = grouped_panel_count * (Size.padding.small * 2 + self.panel_border * 2)
        + divider_count * Size.line.thin
    local fixed_h = self.topbar_h + self.tile_gap + self.stat_h
        + self.section_gap * 4 + self.section_h * 3 + self.title_panel_gap * 3
        + self.button_h
        + panel_extra
    local available_h = self.dimen.h - self.page_padding_top - self.page_padding_bottom
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
    table.insert(content, VerticalSpan:new{ width = self.title_panel_gap })
    for _, row in ipairs(self:buildLanguageRows()) do
        table.insert(content, row)
    end
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:makeTappableHeader(_("Books"), function()
        self:openAllBooks()
    end))
    table.insert(content, VerticalSpan:new{ width = self.title_panel_gap })
    for _, row in ipairs(self:buildBookRows()) do
        table.insert(content, row)
    end
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:makeTappableHeader(_("Attention"), function()
        self:openAttention()
    end))
    table.insert(content, VerticalSpan:new{ width = self.title_panel_gap })
    for _, row in ipairs(self:buildAttentionRows()) do
        table.insert(content, row)
    end
    local attention_spacer_h = self:getAttentionReserveSpacerHeight()
    if attention_spacer_h > 0 then
        table.insert(content, VerticalSpan:new{ width = attention_spacer_h })
    end
    table.insert(content, VerticalSpan:new{ width = self.section_gap })
    table.insert(content, self:buildBottomButtons())

    self[1] = FrameContainer:new{
        height = self.dimen.h,
        padding = 0,
        padding_left = self.page_padding,
        padding_right = self.page_padding,
        padding_top = self.page_padding_top,
        padding_bottom = self.page_padding_bottom,
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

function DashboardScreen:onSwipe(_, ges)
    if not ges or ges.direction ~= "south" then
        return false
    end
    local menu = self.plugin and self.plugin.ui and self.plugin.ui.menu
    if menu and menu.onSwipeShowMenu then
        return menu:onSwipeShowMenu(ges) and true or false
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
    return CenterContainer:new{
        dimen = Geom:new{ w = self.width, h = self.topbar_h },
        TextWidget:new{
            text = _("VocabDeck"),
            face = Font:getFace("cfont"),
            bold = true,
        },
    }
end

function DashboardScreen:makeStatCell(label, value, width, callback)
    local padding = Size.padding.small
    local cell = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.stat_h },
        FrameContainer:new{
            dimen = Geom:new{ w = width, h = self.stat_h },
            padding = padding,
            bordersize = self.panel_border,
            radius = self.card_radius,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{ w = width - padding * 2, h = self.stat_h - padding * 2 },
                VerticalGroup:new{
                    CenterContainer:new{
                        dimen = Geom:new{ w = width - padding * 2, h = math.floor(self.stat_h * 0.38) },
                        TextWidget:new{
                            text = label,
                            face = Font:getFace("smallinfofont"),
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
        radius = self.progress_radius,
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
            bordersize = self.panel_border,
            radius = self.card_radius,
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

function DashboardScreen:makePanelRow(content, callback, width)
    width = width or self.panel_inner_w or self.width
    local row = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.row_h },
        content,
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

function DashboardScreen:makePanelDivider(width)
    width = width or self.panel_inner_w or self.width
    local inset = Size.padding.large
    return CenterContainer:new{
        dimen = Geom:new{ w = width, h = Size.line.thin },
        LineWidget:new{
            dimen = Geom:new{ w = math.max(1, width - inset * 2), h = Size.line.thin },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
end

function DashboardScreen:makeGroupedPanel(rows)
    local panel_h = self.row_h * #rows + Size.line.thin * math.max(0, #rows - 1)
    local content = VerticalGroup:new{}
    for i, row in ipairs(rows) do
        table.insert(content, row)
        if i < #rows then
            table.insert(content, self:makePanelDivider(self.panel_inner_w))
        end
    end
    return FrameContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.width, h = panel_h },
        padding = Size.padding.small,
        bordersize = self.panel_border,
        radius = self.card_radius,
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
end

function DashboardScreen:makeLanguagePanelRow(row)
    local inner_w = self.panel_inner_w
    local chevron_pad = Size.padding.small
    local name_w = math.floor(inner_w * 0.31)
    local due_w = math.floor(inner_w * 0.14)
    local new_w = math.floor(inner_w * 0.14)
    local leading_spacer_w = math.floor(inner_w * 0.03)
    local bar_w = math.floor(inner_w * 0.20)
    local pct_gap_w = math.floor(inner_w * 0.02)
    local pct_w = math.floor(inner_w * 0.08)
    local chevron_w = inner_w - name_w - due_w - new_w - leading_spacer_w
        - bar_w - pct_gap_w - pct_w - chevron_pad
    local percent, pct = self:languageProgress(row)
    local meta_size = self.meta_font_size
    return self:makePanelRow(HorizontalGroup:new{
        self:makeColumnText(shortText(row.language, 16), name_w, "smallinfofont", "left"),
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
        HorizontalSpan:new{ width = chevron_pad },
    }, function()
        self:openStudy(row.language)
    end, inner_w)
end

function DashboardScreen:makeBookPanelRow(row)
    local inner_w = self.panel_inner_w
    local chevron_pad = Size.padding.small
    local title_w = math.floor(inner_w * 0.58)
    local due_w = math.floor(inner_w * 0.15)
    local total_w = math.floor(inner_w * 0.21)
    local chevron_w = inner_w - title_w - due_w - total_w - chevron_pad
    local meta_size = self.meta_font_size
    return self:makePanelRow(HorizontalGroup:new{
        self:makeColumnText(shortText(row.title, 24), title_w, "smallinfofont", "left"),
        self:makeColumnText(string.format(_("Due %d"), row.due), due_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(string.format(_("Total %d"), row.total), total_w, "smallinfofont", "left", meta_size),
        self:makeColumnText(CHEVRON, chevron_w, "smallinfofontbold", "right"),
        HorizontalSpan:new{ width = chevron_pad },
    }, function()
        self:openBook(row)
    end, inner_w)
end

function DashboardScreen:makeAttentionPanelRow(icon, text, callback, width)
    local inner_w = width or self.width
    local chevron_pad = Size.padding.small
    local icon_w = math.floor(inner_w * 0.08)
    local text_w = math.floor(inner_w * 0.82)
    local chevron_w = inner_w - icon_w - text_w - chevron_pad
    local row = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = inner_w, h = self.row_h },
        HorizontalGroup:new{
            self:makeColumnText(icon, icon_w, "smallinfofont", "center"),
            self:makeColumnText(text, text_w, "smallinfofont", "left"),
            self:makeColumnText(callback and CHEVRON or "", chevron_w, "smallinfofontbold", "right"),
            HorizontalSpan:new{ width = chevron_pad },
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

function DashboardScreen:makeAttentionPanel(rows)
    return self:makeGroupedPanel(rows)
end

function DashboardScreen:makeButton(text, width, callback)
    local button = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.button_h },
        FrameContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = width, h = self.button_h },
            padding = Size.padding.small,
            bordersize = Size.border.thin,
            radius = self.card_radius,
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

function DashboardScreen:makeBottomButton(icon_file, label, width, callback)
    local padding = 0
    local inner_w = width - padding * 2
    local inner_h = self.button_h - padding * 2
    local icon_h = math.floor(inner_h * 0.68)
    local label_h = inner_h - icon_h
    local icon_size = math.min(self.bottom_icon_size, icon_h, inner_w)
    local button = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = width, h = self.button_h },
        CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h },
            VerticalGroup:new{
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = icon_h },
                    IconWidget:new{
                        file = icon_file,
                        width = icon_size,
                        height = icon_size,
                        alpha = true,
                    },
                },
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = label_h },
                    TextBoxWidget:new{
                        text = label,
                        face = Font:getFace("smallinfofont", 14),
                        width = inner_w,
                        alignment = "center",
                        height_overflow_show_ellipsis = true,
                    },
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

function DashboardScreen:getAttentionItems()
    local summary = self.data.summary or {}
    return {
        {
            icon = ICON_WEAK,
            count = n(summary.weak_cards),
            text = string.format(_("%d weak cards"), n(summary.weak_cards)),
            callback = function() self:openWeakCards() end,
        },
        {
            icon = ICON_MISSING,
            count = n(summary.missing_ai),
            text = string.format(_("%d missing AI data"), n(summary.missing_ai)),
            callback = function() self:openMissingAI() end,
        },
        {
            icon = ICON_LEECH,
            count = n(summary.leeches),
            text = string.format(_("%d leeches"), n(summary.leeches)),
            callback = function() self:openLeeches() end,
        },
        {
            icon = ICON_SUSPENDED,
            count = n(summary.suspended),
            text = string.format(_("%d suspended cards"), n(summary.suspended)),
            callback = function() self:openSuspendedCards() end,
        },
    }
end

function DashboardScreen:getVisibleAttentionRowCount()
    return 3
end

function DashboardScreen:getRenderedAttentionRowCount()
    if self.data.loading then
        return 1
    end
    local count = 0
    for _, item in ipairs(self:getAttentionItems()) do
        if item.count > 0 then
            count = count + 1
        end
    end
    return math.max(1, math.min(3, count))
end

function DashboardScreen:getAttentionReserveSpacerHeight()
    local missing_rows = 3 - self:getRenderedAttentionRowCount()
    if missing_rows <= 0 then
        return 0
    end
    return missing_rows * (self.row_h + Size.line.thin)
end

function DashboardScreen:buildStatsRow()
    local summary = self.data.summary or {}
    local due = n(summary.due)
    local new = n(summary.available_new)
    local learned = n(summary.reviewed)
    local mature = n(summary.mature)
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
        self:makeStatCell(_("Learned"), learned, cell_w),
        HorizontalSpan:new{ width = gap },
        self:makeStatCell(_("Mature"), mature, self.width - cell_w * 3 - gap * 3),
    }
end

function DashboardScreen:buildLanguageRows()
    self.panel_inner_w = self.width - Size.padding.small * 2 - self.panel_border * 2
    local rows = {}
    if self.data.loading then
        return { self:makeGroupedPanel({
            self:makePanelRow(
                self:makeTextBox(_("Loading..."), self.panel_inner_w, self.row_h - Size.padding.small * 2,
                    "smallinfofont", "left"),
                nil,
                self.panel_inner_w
            ),
        }) }
    end
    if #self.data.languages == 0 then
        return { self:makeGroupedPanel({
            self:makePanelRow(
                self:makeTextBox(_("No cards yet"), self.panel_inner_w, self.row_h - Size.padding.small * 2,
                    "smallinfofont", "left"),
                nil,
                self.panel_inner_w
            ),
        }) }
    end
    for i = 1, math.min(#self.data.languages, MAX_LANGUAGE_ROWS) do
        local row = self.data.languages[i]
        rows[#rows + 1] = self:makeLanguagePanelRow(row)
    end
    return { self:makeGroupedPanel(rows) }
end

function DashboardScreen:buildBookRows()
    self.panel_inner_w = self.width - Size.padding.small * 2 - self.panel_border * 2
    local rows = {}
    if self.data.loading then
        return { self:makeGroupedPanel({
            self:makePanelRow(
                self:makeTextBox(_("Loading..."), self.panel_inner_w, self.row_h - Size.padding.small * 2,
                    "smallinfofont", "left"),
                nil,
                self.panel_inner_w
            ),
        }) }
    end
    if #self.data.books == 0 then
        return { self:makeGroupedPanel({
            self:makePanelRow(
                self:makeTextBox(_("No books with cards"), self.panel_inner_w, self.row_h - Size.padding.small * 2,
                    "smallinfofont", "left"),
                nil,
                self.panel_inner_w
            ),
        }) }
    end
    for i = 1, math.min(#self.data.books, MAX_BOOK_ROWS) do
        local row = self.data.books[i]
        rows[#rows + 1] = self:makeBookPanelRow(row)
    end
    return { self:makeGroupedPanel(rows) }
end

function DashboardScreen:buildAttentionRows()
    self.panel_inner_w = self.width - Size.padding.small * 2 - self.panel_border * 2
    if self.data.loading then
        return { self:makeAttentionPanel({
            self:makeAttentionPanelRow("", _("Loading..."), nil, self.panel_inner_w),
        }) }
    end
    local rows = {}
    for _, item in ipairs(self:getAttentionItems()) do
        if item.count > 0 then
            rows[#rows + 1] = self:makeAttentionPanelRow(item.icon, item.text, item.callback, self.panel_inner_w)
            if #rows >= 3 then
                break
            end
        end
    end
    if #rows == 0 then
        rows[#rows + 1] = self:makeAttentionPanelRow("", _("No attention items"), nil, self.panel_inner_w)
    end
    return { self:makeAttentionPanel(rows) }
end

function DashboardScreen:buildBottomButtons()
    local gap = self.tile_gap
    local button_w = math.floor((self.width - gap * 4) / 5)
    return HorizontalGroup:new{
        self:makeBottomButton(DASHBOARD_ICON_DIR .. "cards.svg", _("All cards"), button_w, function() self:openAllCards(self.data.first_language) end),
        HorizontalSpan:new{ width = gap },
        self:makeBottomButton(DASHBOARD_ICON_DIR .. "import.svg", _("Import"), button_w, function() self:openImport() end),
        HorizontalSpan:new{ width = gap },
        self:makeBottomButton(DASHBOARD_ICON_DIR .. "search.svg", _("Search"), button_w, function() self:openSearch() end),
        HorizontalSpan:new{ width = gap },
        self:makeBottomButton(DASHBOARD_ICON_DIR .. "settings.svg", _("Settings"), button_w, function() self:openSettings() end),
        HorizontalSpan:new{ width = gap },
        self:makeBottomButton(DASHBOARD_ICON_DIR .. "close.svg", _("Close"), self.width - button_w * 4 - gap * 4, function() self:onClose() end),
    }
end

function DashboardScreen:openStudy(language)
    if not language or language == "" then
        UIManager:show(InfoMessage:new{ text = _("No study deck available."), timeout = 3 })
        return
    end
    StudyEntry.startStudy(self.plugin, language, {
        after_close = function()
            Dashboard.invalidateCache()
            self:scheduleRefresh(true)
        end,
    })
end

function DashboardScreen:openAllCards(language, options)
    options = options or {}
    if language and language ~= "" then
        options.active_language = language
    end
    Edit.showList(self.plugin, nil, _("All cards"), options)
end

function DashboardScreen:openSearch()
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
        title = _("Search cards"),
        description = _("Match phrase, meaning, note, word type, pronunciation or sentence."),
        input = "",
        input_hint = _("Search text"),
        buttons = { {
            {
                text = _("Cancel"),
                id = "close",
                background = Blitbuffer.COLOR_WHITE,
                callback = closeDialog,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                background = Blitbuffer.COLOR_WHITE,
                callback = function()
                    local text = TextUtils.trim(dialog:getInputText() or "")
                    closeDialog()
                    if text == "" then return end
                    self:openAllCards(self.data.first_language, { filter_text = text })
                end,
            },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
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
    Importer.showImportMenu(self.plugin)
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

function DashboardScreen:openAttention()
    if self.data.loading then
        UIManager:show(InfoMessage:new{ text = _("Dashboard is still loading."), timeout = 2 })
        return
    end
    local items = {}
    for _, item in ipairs(self:getAttentionItems()) do
        items[#items + 1] = {
            text = item.text,
            callback = item.callback,
        }
    end
    local screen = Device.screen
    UIManager:show(Menu:new{
        title = _("Attention"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    })
end

function DashboardScreen:openSettings()
    local screen = Device.screen
    local settings_menu
    local refresh_proxy = {
        updateItems = function()
            if settings_menu and settings_menu.updateItems then
                settings_menu:updateItems()
            end
        end,
        onClose = function()
            if settings_menu and settings_menu.onClose then
                settings_menu:onClose()
            end
        end,
    }
    local function materializeSubmenus(items)
        if not items then return items end
        for _, item in ipairs(items) do
            if item.sub_item_table_func and not item.sub_item_table then
                item.sub_item_table = item.sub_item_table_func(refresh_proxy)
            end
            materializeSubmenus(item.sub_item_table)
        end
        return items
    end
    local trailing_items = {
        {
            text = _("Import"),
            sub_item_table_func = function()
                return Importer.buildImportMenuItems(self.plugin)
            end,
        },
    }
    local settings_items = materializeSubmenus(
        SettingsModule.buildFullMenuItems(self.plugin, refresh_proxy, trailing_items)
    )
    settings_menu = Menu:new{
        title = _("Settings"),
        item_table = settings_items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }
    UIManager:show(settings_menu)
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
