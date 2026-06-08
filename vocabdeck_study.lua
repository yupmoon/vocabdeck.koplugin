-- VocabDeck study screen.
--
-- Compact study screen. The front and back of each card are assembled from
-- shared field-visibility toggles; the UI uses a bordered panel inspired by
-- KOReader's dictionary popup.
local Blitbuffer = require("ffi/blitbuffer")
local Button = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconButton = require("ui/widget/iconbutton")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local _ = require("gettext")

local DB = require("vocabdeck_db")
local CardFields = require("vocabdeck_card_fields")
local Edit = require("vocabdeck_edit")
local StudyActions = require("vocabdeck_study_actions")

local VERTICAL_SPAN_SMALL = rawget(Size.span, "vertical_small")
    or rawget(Size.span, "vertical_default")
    or rawget(Size.span, "vertical_large")
    or 0

local StudyScreen = InputContainer:extend{}
local LEECH_THRESHOLD = 8
local UNLEECH_THRESHOLD = 2
local LEARN_AHEAD_SECONDS = 20 * 60  -- 20 minutes
local DEFAULT_AUTO_EASY_CUTOFF = 5
local DEFAULT_AUTO_GOOD_CUTOFF = 10
local DEFAULT_AUTO_HARD_CUTOFF = 25
local DEFAULT_AUTO_ANSWER_DELAY = 4
local DEFAULT_MANUAL_AGAIN_DELAY = 5
local DEFAULT_MANUAL_HARD_DELAY = 4
local DEFAULT_MANUAL_GOOD_DELAY = 3
local DEFAULT_MANUAL_EASY_DELAY = 2

-- ── Text assembly helpers ────────────────────────────────────────────────

-- Build the content for one side of the card.
--
-- `show_labels` controls whether section markers like 【Context】 are
-- printed before each field. When false, fields are concatenated as bare
-- paragraphs which lets the content fit on smaller screens. The full-text
-- viewer called by tapping the card always passes true so the user can see
-- the structured view regardless of the compact setting.
local function buildSide(card, field_state, show_labels)
    local parts = {}
    local function add(label, text)
        if not text or text == "" then return end
        if show_labels and label and label ~= "" then
            parts[#parts + 1] = "【" .. label .. "】 " .. text
        else
            parts[#parts + 1] = text
        end
    end
    if field_state.phrase then
        local phrase = card.phrase or ""
        if (card.leech or 0) ~= 0 then
            phrase = "! " .. phrase
        end
        if (card.flag or 0) ~= 0 then
            phrase = "* " .. phrase
        end
        add(nil, phrase)
    end
    if field_state.pronunciation then
        add(nil, card.pronunciation)
    end
    if field_state.word_type and field_state.meaning
        and card.word_type and card.word_type ~= ""
        and card.meaning and card.meaning ~= "" then
        add(nil, card.word_type .. "\n" .. card.meaning)
    else
        if field_state.word_type then
            add(nil, card.word_type)
        end
        if field_state.meaning then
            add(nil, card.meaning)
        end
    end
    if field_state.synonym then
        add(_("Synonyms"), card.synonym)
    end
    if field_state.sentence then
        add(nil, card.sentence)
    end
    if field_state.display_context then
        add(_("Context"), card.display_context)
    end
    if field_state.user_note then
        add(_("Note"), card.user_note)
    end
    if #parts == 0 then
        parts[#parts + 1] = card.phrase or ""
    end
    return table.concat(parts, "\n\n")
end

-- ── StudyScreen ──────────────────────────────────────────────────────────

function StudyScreen:init()
    local Screen = Device.screen
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.covers_fullscreen = true
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end

    self.book_id = nil
    self.source_language = self.source_language or ""
    self.book_title = self.source_language ~= "" and self.source_language or _("Study")

    self.current_card = nil
    self.showing_back = false

    local panel_width = math.floor(Screen:getWidth() * 0.92)
    local panel_height = math.floor(Screen:getHeight() * 0.82)
    local title_h = Screen:scaleBySize(48)
    local topbar_h = title_h * 2
    local edit_icon_h = Screen:scaleBySize(32)
    local action_h = Screen:scaleBySize(48)
    local interval_h = Screen:scaleBySize(28)
    local card_width = panel_width - Size.padding.large * 2
    local front_card_height = panel_height - topbar_h - action_h - Size.padding.large * 2
    local back_card_height = panel_height - topbar_h - action_h - interval_h - Size.padding.large * 2
    local card_height = front_card_height
    local card_inner_width = card_width - Size.padding.large * 2
    local front_card_inner_height = front_card_height - Size.padding.large * 2
    local back_card_inner_height = back_card_height - Size.padding.large * 2
    self.card_widget = TextBoxWidget:new{
        face = Font:getFace("cfont"),
        text = "",
        width = card_inner_width,
        height = front_card_inner_height,
        alignment = "left",
        height_overflow_show_ellipsis = true,
    }
    self.card_full_text = ""

    self.front_card_container = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = card_width, h = front_card_height },
        FrameContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = card_width, h = front_card_height },
            padding = Size.padding.large,
            bordersize = 0,
            self.card_widget,
        },
    }
    self.card_container = self.front_card_container
    if Device:isTouchDevice() then
        self.front_card_container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = self.front_card_container.dimen,
                },
            },
        }
        self.front_card_container.onTap = function()
            self:showFullText()
            return true
        end
    end

    local function makeFlatButton(text, callback, width)
        return Button:new{
            text = text,
            background = Blitbuffer.COLOR_WHITE,
            callback = callback,
            show_parent = self,
            text_font_face = "cfont",
            text_font_bold = false,
            width = width,
            height = action_h,
            bordersize = Size.border.thin,
            margin = 0,
            radius = 0,
        }
    end

    local title_width = panel_width - title_h * 2
    local function makeTitleWidget()
        return TextBoxWidget:new{
            face = Font:getFace("smallinfofontbold"),
            text = self.book_title or "",
            width = title_width,
            height = topbar_h,
            height_adjust = true,
            height_overflow_show_ellipsis = true,
            alignment = "center",
        }
    end
    self.front_title_widget = makeTitleWidget()
    self.back_title_widget = makeTitleWidget()
    -- Keep the older name as an alias for any local callers, but update both
    -- title widgets via setStudyTitle().
    self.title_widget = self.front_title_widget

    local function makeTopBar(title_widget)
        local menu_button = IconButton:new{
            icon = "appbar.menu",
            width = title_h,
            height = title_h,
            padding = Size.padding.button,
            show_parent = self,
            callback = function() self:showBookSelection() end,
        }
        local close_button = IconButton:new{
            icon = "close",
            width = title_h,
            height = title_h,
            padding = Size.padding.button,
            show_parent = self,
            callback = function() self:onClose() end,
        }
        local edit_button = IconButton:new{
            icon = "edit",
            width = edit_icon_h,
            height = edit_icon_h,
            padding = 0,
            show_parent = self,
            callback = function() self:onEditCurrentCard() end,
        }
        local right_actions = VerticalGroup:new{
            close_button,
            CenterContainer:new{
                dimen = Geom:new{ w = title_h, h = title_h },
                edit_button,
            },
        }
        return HorizontalGroup:new{
            dimen = Geom:new{ w = panel_width, h = topbar_h },
            menu_button,
            title_widget,
            right_actions,
        }
    end
    local front_top_bar = makeTopBar(self.front_title_widget)
    local back_top_bar = makeTopBar(self.back_title_widget)

    self.show_button = makeFlatButton(_("Show answer"), function() self:onShowOrNext() end, panel_width)
    local show_row = HorizontalGroup:new{
        dimen = Geom:new{ w = panel_width, h = action_h },
        self.show_button,
    }
    local btn_width = math.floor(panel_width / 5)
    self.again_button  = makeFlatButton(_("Again"),  function() self:onRate("again") end, btn_width)
    self.hard_button   = makeFlatButton(_("Hard"),   function() self:onRate("hard")  end, btn_width)
    self.good_button   = makeFlatButton(_("Good"),   function() self:onRate("good")  end, btn_width)
    self.easy_button   = makeFlatButton(_("Easy"),   function() self:onRate("easy")  end, btn_width)
    self.action_button = makeFlatButton(_("Actions"), function() self:showActionMenu() end, panel_width - btn_width * 4)
    local interval_face = Font:getFace("smallinfofont")
    self.interval_again = TextWidget:new{ face = interval_face, text = "" }
    self.interval_hard  = TextWidget:new{ face = interval_face, text = "" }
    self.interval_good  = TextWidget:new{ face = interval_face, text = "" }
    self.interval_easy  = TextWidget:new{ face = interval_face, text = "" }
    self.timer_widget = TextWidget:new{ face = interval_face, text = "" }
    local function intervalCell(widget, width)
        return CenterContainer:new{
            dimen = Geom:new{ w = width, h = interval_h },
            widget,
        }
    end
    local interval_row = HorizontalGroup:new{
        dimen = Geom:new{ w = panel_width, h = interval_h },
        intervalCell(self.interval_again, btn_width),
        intervalCell(self.interval_hard, btn_width),
        intervalCell(self.interval_good, btn_width),
        intervalCell(self.interval_easy, btn_width),
        intervalCell(self.timer_widget, panel_width - btn_width * 4),
    }
    local rating_row = HorizontalGroup:new{
        dimen = Geom:new{ w = panel_width, h = action_h },
        self.again_button,
        self.hard_button,
        self.good_button,
        self.easy_button,
        self.action_button,
    }

    local front_panel_content = VerticalGroup:new{
        front_top_bar,
        self.front_card_container,
        show_row,
    }
    self.front_study_panel = FrameContainer:new{
        padding = 0,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        background = Blitbuffer.COLOR_WHITE,
        front_panel_content,
    }

    self.back_card_widget = TextBoxWidget:new{
        face = Font:getFace("cfont"),
        text = "",
        width = card_inner_width,
        height = back_card_inner_height,
        alignment = "left",
        height_overflow_show_ellipsis = true,
    }
    self.back_card_container = InputContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = card_width, h = back_card_height },
        FrameContainer:new{
            dimen = Geom:new{ x = 0, y = 0, w = card_width, h = back_card_height },
            padding = Size.padding.large,
            bordersize = 0,
            self.back_card_widget,
        },
    }
    if Device:isTouchDevice() then
        self.back_card_container.ges_events = {
            Tap = {
                GestureRange:new{
                    ges = "tap",
                    range = self.back_card_container.dimen,
                },
            },
        }
        self.back_card_container.onTap = function()
            self:showFullText()
            return true
        end
    end
    local back_panel_content = VerticalGroup:new{
        back_top_bar,
        self.back_card_container,
        interval_row,
        rating_row,
    }
    self.back_study_panel = FrameContainer:new{
        padding = 0,
        bordersize = Size.border.window,
        radius = Size.radius.window,
        background = Blitbuffer.COLOR_WHITE,
        back_panel_content,
    }

    self.front_layout = CenterContainer:new{
        dimen = self.dimen,
        self.front_study_panel,
    }
    self.back_layout = CenterContainer:new{
        dimen = self.dimen,
        self.back_study_panel,
    }

    self[1] = self.front_layout
    self:loadNextCard()

    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function StudyScreen:refresh()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

function StudyScreen:invalidateAutoRate()
    self.auto_rate_token = (self.auto_rate_token or 0) + 1
    self.pending_auto_rate = nil
end

function StudyScreen:invalidateAdvance()
    self.advance_token = (self.advance_token or 0) + 1
end

function StudyScreen:_fireAutoRate(run_id)
    local pending = self.pending_auto_rate
    if not pending or pending.paused or pending.run_id ~= run_id then return end
    if self.showing_back
        and self.current_card
        and self.current_card.id == pending.card_id
        and self.auto_rate_token == pending.token then
        local rating = pending.rating
        self.pending_auto_rate = nil
        self:onRate(rating, 0)
    end
end

function StudyScreen:_schedulePendingAutoRate(delay)
    local pending = self.pending_auto_rate
    if not pending then return end
    delay = math.max(0, math.floor((tonumber(delay) or 0) + 0.5))
    pending.run_id = (pending.run_id or 0) + 1
    pending.due_at = os.time() + delay
    local run_id = pending.run_id
    UIManager:scheduleIn(delay, function()
        self:_fireAutoRate(run_id)
    end)
end

function StudyScreen:scheduleAutoRate(rating, delay, card_id)
    if not rating or rating == "" or not card_id then return end
    self.pending_auto_rate = {
        rating = rating,
        card_id = card_id,
        token = self.auto_rate_token,
        paused = false,
        remaining = nil,
        run_id = 0,
    }
    self:_schedulePendingAutoRate(delay)
end

function StudyScreen:pauseAutoRate()
    local pending = self.pending_auto_rate
    if not pending or pending.paused then return end
    if not self.showing_back
        or not self.current_card
        or self.current_card.id ~= pending.card_id
        or self.auto_rate_token ~= pending.token then
        self:invalidateAutoRate()
        return
    end
    pending.remaining = math.max(0, (pending.due_at or os.time()) - os.time())
    pending.paused = true
    pending.run_id = (pending.run_id or 0) + 1
end

function StudyScreen:resumeAutoRate()
    local pending = self.pending_auto_rate
    if not pending or not pending.paused then return end
    if not self.showing_back
        or not self.current_card
        or self.current_card.id ~= pending.card_id
        or self.auto_rate_token ~= pending.token then
        self:invalidateAutoRate()
        return
    end
    pending.paused = false
    self:_schedulePendingAutoRate(pending.remaining or 0)
end

function StudyScreen:isAutoRateEnabled()
    local plugin = self.plugin
    return plugin
        and plugin:readSetting("study_timer_enabled", true) ~= false
        and plugin:readSetting("auto_rate_enabled", false) == true
end

function StudyScreen:getManualAdvanceDelay(rating)
    local plugin = self.plugin
    local defaults = {
        again = DEFAULT_MANUAL_AGAIN_DELAY,
        hard = DEFAULT_MANUAL_HARD_DELAY,
        good = DEFAULT_MANUAL_GOOD_DELAY,
        easy = DEFAULT_MANUAL_EASY_DELAY,
    }
    local key = "manual_" .. tostring(rating or "") .. "_advance_delay"
    local fallback = defaults[rating] or 0
    local value = plugin and tonumber(plugin:readSetting(key, fallback)) or fallback
    return math.max(0, math.floor((value or fallback) + 0.5))
end

function StudyScreen:getAutoRateConfig()
    local plugin = self.plugin
    local easy = plugin and tonumber(plugin:readSetting("auto_rate_easy_cutoff", DEFAULT_AUTO_EASY_CUTOFF))
        or DEFAULT_AUTO_EASY_CUTOFF
    local good = plugin and tonumber(plugin:readSetting("auto_rate_good_cutoff", DEFAULT_AUTO_GOOD_CUTOFF))
        or DEFAULT_AUTO_GOOD_CUTOFF
    local hard = plugin and tonumber(plugin:readSetting("auto_rate_hard_cutoff", DEFAULT_AUTO_HARD_CUTOFF))
        or DEFAULT_AUTO_HARD_CUTOFF
    local delay = plugin and tonumber(plugin:readSetting("auto_rate_answer_delay", DEFAULT_AUTO_ANSWER_DELAY))
        or DEFAULT_AUTO_ANSWER_DELAY

    easy = math.max(1, math.floor((easy or DEFAULT_AUTO_EASY_CUTOFF) + 0.5))
    good = math.max(easy, math.floor((good or DEFAULT_AUTO_GOOD_CUTOFF) + 0.5))
    hard = math.max(good, math.floor((hard or DEFAULT_AUTO_HARD_CUTOFF) + 0.5))
    delay = math.max(0, math.floor((delay or DEFAULT_AUTO_ANSWER_DELAY) + 0.5))

    return {
        easy = easy,
        good = good,
        hard = hard,
        delay = delay,
    }
end

function StudyScreen:setStudyTitle(title)
    self.book_title = title or _("Study")
    if self.front_title_widget then
        self.front_title_widget:setText(self.book_title)
    end
    if self.back_title_widget then
        self.back_title_widget:setText(self.book_title)
    end
end

function StudyScreen:updateTitle()
    if self.front_title_widget then
        self.front_title_widget:setText(self.book_title or _("Study"))
    end
    if self.back_title_widget then
        self.back_title_widget:setText(self.book_title or _("Study"))
    end
end

function StudyScreen:setRatingButtonsEnabled(enabled)
    local flag = not not enabled
    if self.again_button  then self.again_button:enableDisable(flag)  end
    if self.hard_button   then self.hard_button:enableDisable(flag)   end
    if self.good_button   then self.good_button:enableDisable(flag)   end
    if self.easy_button   then self.easy_button:enableDisable(flag)   end
    if self.action_button then self.action_button:enableDisable(flag) end
end

function StudyScreen:setShowButtonVisible(visible)
    if not self.show_button then return end
    self.show_button:enableDisable(not not visible)
end

function StudyScreen:updateQueueCounts(require_enriched)
    if not self.show_button then return end
    local daily_new_limit = self.plugin
        and (tonumber(self.plugin:readSetting("daily_new_cards_limit", 20)) or 20) or 20
    local daily_review_limit = self.plugin
        and (tonumber(self.plugin:readSetting("daily_review_cards_limit", 200)) or 200) or 200
    local ok, counts = pcall(DB.getStudyQueueCounts,
        self.book_id, self.source_language, require_enriched or self:getRequireEnriched(),
        nil, daily_review_limit, LEARN_AHEAD_SECONDS, daily_new_limit, not self.use_daily_override)
    counts = ok and counts or { new = 0, learning = 0, review = 0 }
    self.show_button:setText(string.format("%d + %d + %d",
        tonumber(counts.new) or 0,
        tonumber(counts.learning) or 0,
        tonumber(counts.review) or 0))
end

function StudyScreen:updateRatingLabels(previews)
    if not previews then return end
    local function setLabel(widget, key)
        local info = previews[key]
        if info and widget then widget:setText(info.label or "") end
    end
    setLabel(self.interval_again, "again")
    setLabel(self.interval_hard,  "hard")
    setLabel(self.interval_good,  "good")
    setLabel(self.interval_easy,  "easy")
end

function StudyScreen:getRequireEnriched()
    local plugin = self.plugin
    if not plugin then return true end
    local v = plugin:readSetting("require_enriched_for_study")
    if v == nil then return true end
    return v and true or false
end

function StudyScreen:getDesiredRetention()
    local plugin = self.plugin
    local percent = plugin and tonumber(plugin:readSetting("desired_retention_percent", 90)) or 90
    percent = math.max(70, math.min(97, percent or 90))
    return percent / 100
end

local function todayKey()
    return os.date("%Y-%m-%d", os.time())
end

function StudyScreen:loadNextCard()
    self:invalidateAutoRate()
    self:invalidateAdvance()
    local plugin = self.plugin
    local randomize = plugin and plugin:readSetting("randomize_cards", false) or false
    local daily_new_limit = plugin and (tonumber(plugin:readSetting("daily_new_cards_limit", 20)) or 20) or 20
    local daily_review_limit = plugin and (tonumber(plugin:readSetting("daily_review_cards_limit", 200)) or 200) or 200
    local require_enriched = self:getRequireEnriched()

    local card = DB.fetchNextDueCard(self.book_id, nil, randomize, daily_new_limit,
        require_enriched, self.source_language, daily_review_limit, self.use_daily_override)
    if not card then
        -- Anki-like learn ahead: when there are no normal due cards, keep
        -- short-interval learning cards in the active session instead of
        -- ending the study screen.
        card = DB.fetchNextLearningAheadCard(self.book_id, nil, LEARN_AHEAD_SECONDS, require_enriched,
            self.source_language, self.use_daily_override)
    end
    if not card then
        self.current_card = nil
        self.showing_back = false
        self:updateTitle()
        self:updateQueueCounts(require_enriched)
        -- Rotating congratulatory messages when all cards are done.
        local CONGRATS = {
            _("All caught up! 🎉"),
            _("No cards due — great work!"),
            _("Session complete! Well done."),
            _("All done for now. Come back later!"),
            _("You're on a roll! Nothing due."),
            _("Finished! You're building momentum."),
            _("No more cards due. Keep it up!"),
            _("All reviewed. Excellent consistency!"),
        }
        local idx = tonumber(self.plugin:readSetting("congrats_index", 1)) or 1
        if idx < 1 or idx > #CONGRATS then idx = 1 end
        self.plugin:saveSetting("congrats_index", idx % #CONGRATS + 1)
        self.plugin.settings:flush()
        local msg = CONGRATS[idx]
        self.card_widget:setText(msg)
        self.back_card_widget:setText(msg)
        if self.timer_widget then self.timer_widget:setText("") end
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(false)
        self[1] = self.front_layout
        self:refresh()
        return
    end
    self.current_card = card
    self.showing_back = false
    self.timer_start = os.time()
    if self.timer_widget then self.timer_widget:setText("") end
    self:updateTitle()
    self:updateQueueCounts(require_enriched)
    local front_state = CardFields.getFieldState(plugin, "front")
    local back_state = CardFields.getFieldState(plugin, "back")
    local reverse = plugin and plugin:readSetting("study_reverse", false) or false
    if reverse then
        front_state, back_state = back_state, front_state
    end
    local show_labels = plugin and plugin:readSetting("show_section_labels", true) and true or false
    local front_text = buildSide(card, front_state, show_labels)
    -- Tapping the card always presents the labelled version.
    self.card_full_text = buildSide(card, front_state, true)
    self.card_widget:setText(front_text)
    self.back_card_widget:setText(front_text)
    self:setShowButtonVisible(true)
    self:setRatingButtonsEnabled(false)
    self[1] = self.front_layout
    self:refresh()
end

function StudyScreen:onShowOrNext()
    if not self.current_card then
        self:loadNextCard()
        return
    end
    if not self.showing_back then
        self.showing_back = true
        self.elapsed = os.time() - (self.timer_start or os.time())

        -- Determine auto-rate label for the timer display.
        local auto_rate_label = ""
        local auto_enabled = self:isAutoRateEnabled()
        local auto_config = self:getAutoRateConfig()
        if auto_enabled and self.elapsed <= auto_config.hard then
            if self.elapsed <= auto_config.easy then
                auto_rate_label = "Easy"
            elseif self.elapsed <= auto_config.good then
                auto_rate_label = "Good"
            else
                auto_rate_label = "Hard"
            end
        end

        if self.timer_widget then
            if self.plugin and self.plugin:readSetting("study_timer_enabled", true) ~= false then
                local label = string.format("\226\143\177 %ds", self.elapsed)
                if auto_rate_label ~= "" then
                    label = label .. " \194\183 " .. _(auto_rate_label)
                end
                self.timer_widget:setText(label)
            else
                self.timer_widget:setText("")
            end
        end
        local plugin = self.plugin
        local back_state = CardFields.getFieldState(plugin, "back")
        local reverse = plugin and plugin:readSetting("study_reverse", false) or false
        if reverse then
            back_state = CardFields.getFieldState(plugin, "front")
        end
        local show_labels = plugin and plugin:readSetting("show_section_labels", true) and true or false
        local back_text = buildSide(self.current_card, back_state, show_labels)
        -- Full-text viewer always shows labelled, double-newline version.
        self.card_full_text = buildSide(self.current_card, back_state, true):gsub("\n", "\n\n")
        self.back_card_widget:setText(back_text)
        local previews = DB.previewIntervals(self.current_card, nil, self:getDesiredRetention())
        self:updateRatingLabels(previews)
        self:setShowButtonVisible(false)
        self:setRatingButtonsEnabled(true)
        self[1] = self.back_layout
        self:refresh()

        -- Auto-rate based on recall time. Rating buttons remain as override.
        if auto_rate_label ~= "" then
            local auto_card_id = self.current_card and self.current_card.id
            local rating = auto_rate_label:lower()
            self:scheduleAutoRate(rating, auto_config.delay, auto_card_id)
        end
    end
end

function StudyScreen:showFullText()
    if not self.card_full_text or self.card_full_text == "" then return end
    self:pauseAutoRate()
    local viewer
    local resumed = false
    local function resumeOnce()
        if resumed then return end
        resumed = true
        self:resumeAutoRate()
    end
    viewer = TextViewer:new{
        title = _("Full text"),
        text = self.card_full_text,
    }
    local old_on_close = viewer.onCloseWidget
    function viewer:onCloseWidget()
        if old_on_close then old_on_close(self) end
        resumeOnce()
    end
    UIManager:show(viewer)
end

function StudyScreen:refreshCurrentCard()
    if not self.current_card or not self.current_card.id then return end
    local fresh = DB.getCard(self.current_card.id)
    if fresh then
        self.current_card = fresh
        local plugin = self.plugin
        local field_state = CardFields.getFieldState(plugin, self.showing_back and "back" or "front")
        local show_labels = plugin and plugin:readSetting("show_section_labels", true) and true or false
        local text = buildSide(fresh, field_state, show_labels)
        self.card_full_text = buildSide(fresh, field_state, true)
        if self.showing_back then
            self.back_card_widget:setText(text)
        else
            self.card_widget:setText(text)
            self.back_card_widget:setText(text)
        end
        self:refresh()
    end
end

function StudyScreen:onEditCurrentCard()
    if not self.current_card then
        UIManager:show(InfoMessage:new{ text = _("No card to edit."), timeout = 2 })
        return
    end
    Edit.showCardEditor(self.plugin, self.current_card, function(saved_card)
        if saved_card and saved_card.id == self.current_card.id then
            self.current_card = saved_card
        end
        self:refreshCurrentCard()
    end)
end

function StudyScreen:onDeleteCard()
    StudyActions.deleteCard(self)
end

function StudyScreen:onSuspendCard()
    StudyActions.suspendCard(self)
end

function StudyScreen:onToggleFlag()
    StudyActions.toggleFlag(self)
end

function StudyScreen:onResetCard()
    StudyActions.resetCard(self)
end

function StudyScreen:onRefetchAIData()
    StudyActions.refetchAIData(self)
end

function StudyScreen:showActionMenu()
    self:pauseAutoRate()
    StudyActions.showMenu(self)
end

function StudyScreen:notifyAfterClose()
    if self.after_close_notified then return end
    self.after_close_notified = true
    if self.after_close then
        self.after_close()
    end
end

function StudyScreen:onRate(rating, advance_delay)
    if not self.current_card then return end
    self:invalidateAutoRate()
    self:invalidateAdvance()
    local card = self.current_card
    local was_leech = (card.leech or 0) ~= 0
    local updated = DB.updateCardScheduling(card, rating, nil, self:getDesiredRetention(),
        self.use_daily_override and todayKey() or "") or card
    local became_leech = rating == "again"
        and not was_leech
        and (tonumber(updated.lapse_count) or 0) >= LEECH_THRESHOLD
    if became_leech then
        DB.setCardLeech(updated.id, true)
        updated.leech = 1
        local action = self.plugin and self.plugin:readSetting("leech_action", "tag") or "tag"
        if action == "suspend" then
            DB.setCardSuspended(updated.id, true)
            updated.suspended = 1
            UIManager:show(InfoMessage:new{ text = _("Leech suspended."), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{ text = _("Marked as leech."), timeout = 2 })
        end
    elseif was_leech then
        -- Auto-unleech: track consecutive successful reviews.
        -- leech_notified_at stores the count as a negative value:
        --   -1 = 1 successful review, -2 = 2 successful reviews (threshold reached).
        -- On "Again" (failed), reset the counter.
        -- On Hard/Good/Easy (successful), increment toward UNLEECH_THRESHOLD.
        local success_count = tonumber(card.leech_notified_at) or 0
        if success_count > 0 then
            -- Was a timestamp from old data; treat as 0.
            success_count = 0
        else
            success_count = math.abs(success_count)
        end
        if rating == "again" then
            -- Failed review: reset successful-review counter.
            DB.setCardLeechSuccessCount(updated.id, 0)
        else
            -- Successful review: increment counter.
            success_count = success_count + 1
            if success_count >= UNLEECH_THRESHOLD then
                DB.setCardLeech(updated.id, false)
                updated.leech = 0
                UIManager:show(InfoMessage:new{ text = _("Leech cleared."), timeout = 2 })
            else
                DB.setCardLeechSuccessCount(updated.id, success_count)
            end
        end
    end
    self.current_card = nil
    self:setRatingButtonsEnabled(false)

    local delay = advance_delay
    if delay == nil then
        delay = self:getManualAdvanceDelay(rating)
    end
    delay = math.max(0, math.floor((tonumber(delay) or 0) + 0.5))
    if delay == 0 then
        self.showing_back = false
        self:loadNextCard()
        return
    end

    local advance_token = self.advance_token
    UIManager:scheduleIn(delay, function()
        if self.advance_token == advance_token and not self.current_card then
            self.showing_back = false
            self:loadNextCard()
        end
    end)
end

function StudyScreen:showBookSelection()
    self:invalidateAutoRate()
    local study = self
    local menu
    local screen = Device.screen
    local title = _("Select study deck")

    local function buildItems()
        local languages = DB.listSourceLanguages(nil)
        local items = {}
        local require_enriched = study:getRequireEnriched()
        local daily_new_limit = study.plugin
            and (tonumber(study.plugin:readSetting("daily_new_cards_limit", 20)) or 20) or 20
        local daily_review_limit = study.plugin
            and (tonumber(study.plugin:readSetting("daily_review_cards_limit", 200)) or 200) or 200
        for _, language in ipairs(languages) do
            local ok, counts = pcall(DB.getStudyQueueCounts,
                nil, language, require_enriched, nil, daily_review_limit, LEARN_AHEAD_SECONDS, daily_new_limit,
                not study.use_daily_override)
            local due_count = 0
            if ok and counts then
                due_count = (tonumber(counts.new) or 0)
                    + (tonumber(counts.learning) or 0)
                    + (tonumber(counts.review) or 0)
            end
            table.insert(items, {
                text = string.format("%s [%d]", language, due_count),
                enabled = due_count > 0,
                callback = function()
                    study.source_language = language
                    study.book_id = nil
                    study:setStudyTitle(language)
                    study:loadNextCard()
                end,
            })
        end
        if #items > 0 then
            items[#items].separator = true
        end

        local books = DB.listBooks()
        for _idx, b in ipairs(books) do
            local base = b.title or ""
            if base == "" then base = b.filepath or "Book" end
            local label = base
            if b.card_count and b.card_count > 0 then
                label = string.format("%s (%d)", base, b.card_count)
            end
            local book_id = b.id
            local book_title = b.title or ""
            table.insert(items, {
                text = label,
                book_id = book_id,
                callback = function()
                    study.book_id = book_id
                    study:setStudyTitle(book_title)
                    study:loadNextCard()
                end,
                -- Long-press on a book row prompts for confirmation and then
                -- wipes the book together with every card belonging to it.
                hold_callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = string.format(
                            _("Delete book \"%s\" and all its %d cards? This cannot be undone."),
                            base, tonumber(b.card_count) or 0
                        ),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            local deleted = DB.deleteBookAndCards(book_id) or 0
                            -- If the user was studying that book, fall back to the current language deck.
                            if study.book_id == book_id then
                                study.book_id = nil
                                study:setStudyTitle(study.source_language ~= "" and study.source_language or _("Study"))
                                study:loadNextCard()
                            end
                            UIManager:show(InfoMessage:new{
                                text = string.format(_("Deleted %d cards."), deleted),
                                timeout = 2,
                            })
                            if menu and menu.switchItemTable then
                                menu:switchItemTable(title, buildItems())
                            end
                        end,
                    })
                end,
            })
        end
        return items
    end

    local items = buildItems()
    if #items <= 1 then
        UIManager:show(InfoMessage:new{
            text = _("No books with cards yet. Add phrases from the highlight menu while reading."),
            timeout = 4,
        })
        return
    end

    menu = Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.9),
    }
    -- Default Menu:onMenuChoice closes the menu on tap; we keep the same
    -- behavior. Menu's default `onMenuHold` is a no-op, so we override it to
    -- forward hold gestures to the item's `hold_callback`.
    function menu:onMenuChoice(item)
        if item.callback then item.callback() end
        UIManager:close(self)
        return true
    end
    function menu:onMenuHold(item)
        if item and item.hold_callback then
            item.hold_callback()
        end
        return true
    end
    UIManager:show(menu)
end

function StudyScreen:onClose()
    self:invalidateAutoRate()
    self:invalidateAdvance()
    self:notifyAfterClose()
    UIManager:close(self)
    -- Request a full refresh so the reader screen behind us is redrawn
    -- cleanly (no leftover pixels from the deck screen).
    UIManager:setDirty(nil, "full")
    return true
end

function StudyScreen:onCloseWidget()
    self:invalidateAutoRate()
    self:invalidateAdvance()
    self:notifyAfterClose()
    -- Also fires on system dismissals (e.g. the user presses Back or switches
    -- documents). Same motivation as onClose.
    UIManager:setDirty(nil, "full")
end

-- Paint the whole fullscreen area with white before laying out the
-- internal widgets. This prevents leftover pixels from the previous screen
-- (reader, file manager, toolbars) bleeding through around the margins and
-- below the button row.
function StudyScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    if self[1] then
        local content_size = self[1]:getSize()
        local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
        local offset_y = y + math.floor((self.dimen.h - content_size.h) / 2)
        self[1]:paintTo(bb, offset_x, offset_y)
    end
end

return StudyScreen
