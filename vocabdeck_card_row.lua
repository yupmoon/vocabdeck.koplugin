-- Lightweight card row renderer for the VocabDeck card list.
local _ = require("gettext")

local Button = require("ui/widget/button")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local LeftContainer = require("ui/widget/container/leftcontainer")
local RightContainer = require("ui/widget/container/rightcontainer")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local Blitbuffer = require("ffi/blitbuffer")

local DB = require("vocabdeck_db")
local Format = require("vocabdeck_card_format")

local Screen = Device.screen

local Row = {}

local word_face = Font:getFace("smallinfofont")
local subtitle_face = Font:getFace("smallinfofont")
local subtitle_color = Blitbuffer.COLOR_BLACK
local dim_color = Blitbuffer.COLOR_GRAY_3
local word_height = TextWidget:new{ text = " ", face = word_face }:getSize().h
local schedule_face = Font:getFace("cfont", 14)
local schedule_height = TextWidget:new{ text = " ", face = schedule_face }:getSize().h
local separator_width = TextWidget:new{ text = " — ", face = subtitle_face }:getSize().w

function Row.buildRowWidget(width, height, card, empty_text, quick_delete, show_parent)
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
    local subtitle = card and Format.buildCardSubtitle(card) or ""
    local review_status = Format.formatReviewStatus(card)

    local left_padding = Size.padding.large
    local delete_width = quick_delete and Screen:scaleBySize(48) or 0
    local text_width = width - left_padding - delete_width
    local top_space = math.max(0, math.floor((height - word_height - schedule_height) / 4))
    local phrase_widget = TextWidget:new{ text = phrase, face = word_face }
    local phrase_width = math.min(phrase_widget:getSize().w, math.floor(text_width * 0.72))
    local meaning_width = math.max(0, text_width - phrase_width - separator_width)

    return FrameContainer:new{
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
end

return Row
