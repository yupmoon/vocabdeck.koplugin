-- Actions, filters, and sorting menus for the VocabDeck card list.
local _ = require("gettext")

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local TextUtils = require("vocabdeck_text_utils")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local Blitbuffer = require("ffi/blitbuffer")

local DB = require("vocabdeck_db")

local Screen = Device.screen

local Filters = {}

Filters.DEFAULT_SORT_BY = "added"
Filters.DEFAULT_SORT_DIR = "desc"

local SORT_LABELS = {
    due = _("due time"),
    alphabet = _("alphabet"),
    edited = _("edited time"),
    added = _("added time"),
    lapses = _("lapses"),
}

local SORT_ORDER = { "added", "due", "alphabet", "edited", "lapses" }

local SORT_DIR_LABELS = {
    asc = _("ascending"),
    desc = _("descending"),
}

local SORT_DIR_ORDER = { "desc", "asc" }

local SORT_BY_MENU_LABELS = {
    added = _("Added time"),
    due = _("Due time"),
    alphabet = _("Alphabet"),
    edited = _("Edited time"),
    lapses = _("Lapses"),
}

local SORT_STATE_LABELS = {
    added = {
        asc = _("Oldest added"),
        desc = _("Newest added"),
    },
    due = {
        asc = _("Due soonest"),
        desc = _("Due latest"),
    },
    alphabet = {
        asc = _("A to Z"),
        desc = _("Z to A"),
    },
    edited = {
        asc = _("Oldest edited"),
        desc = _("Recently edited"),
    },
    lapses = {
        asc = _("Fewest lapses"),
        desc = _("Most lapses"),
    },
}

function Filters.normalizeSortBy(value)
    return SORT_LABELS[value] and value or Filters.DEFAULT_SORT_BY
end

function Filters.normalizeSortDir(value)
    return SORT_DIR_LABELS[value] and value or Filters.DEFAULT_SORT_DIR
end

function Filters.isDefaultSort(sort_by, sort_dir)
    return Filters.normalizeSortBy(sort_by) == Filters.DEFAULT_SORT_BY
        and Filters.normalizeSortDir(sort_dir) == Filters.DEFAULT_SORT_DIR
end

function Filters.getTitleSortLabel(sort_by, sort_dir)
    sort_by = Filters.normalizeSortBy(sort_by)
    sort_dir = Filters.normalizeSortDir(sort_dir)
    return SORT_LABELS[sort_by], SORT_DIR_LABELS[sort_dir]
end

local function currentSortLabel(sort_by, sort_dir)
    sort_by = Filters.normalizeSortBy(sort_by)
    sort_dir = Filters.normalizeSortDir(sort_dir)
    return SORT_STATE_LABELS[sort_by][sort_dir]
end

local function hasAnyFilter(self)
    return (self.filter_word_type or "") ~= ""
        or (self.filter_source_language or "") ~= ""
        or (self.filter_text or "") ~= ""
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

local function clearFilters(self)
    self.filter_word_type = ""
    self.filter_source_language = ""
    self.filter_text = ""
    self.filter_ai_status = false
    self.filter_flagged = false
    self.filter_not_started = false
    self.filter_learning = false
    self.filter_learned = false
    self.filter_weak = false
    self.filter_leech = false
    self.filter_suspended = false
    self.filter_book_id = nil
    self.sort_by = Filters.DEFAULT_SORT_BY
    self.sort_dir = Filters.DEFAULT_SORT_DIR
    self.show_page = 1
    self:reloadItems()
end

function Filters.showActionsDialog(self)
    local menu
    local item_table = {}

    if not self.book_id then
        item_table[#item_table + 1] = {
            text = _("Add new card"),
            callback = function()
                UIManager:close(menu)
                if self.plugin and self.plugin.addManualCard then
                    self.plugin:addManualCard(nil, {
                        source_language = self.active_language,
                        after_save = function()
                            self:reloadItems()
                        end,
                    })
                end
            end,
        }
    end
    item_table[#item_table + 1] = {
        text = self.book_id and _("Fetch AI data for this book") or _("Fetch AI data for all cards"),
        callback = function()
            if self.plugin and self.plugin.bulkFetchMissing then
                self.plugin:bulkFetchMissing(self.book_id, function()
                    self:reloadItems()
                end)
            end
        end,
    }
    item_table[#item_table + 1] = {
        text = _("Search"),
        callback = function()
            self:showTextFilterDialog()
        end,
    }
    item_table[#item_table + 1] = {
        text = _("Sort"),
        callback = function()
            self:showSortDialog()
        end,
    }
    item_table[#item_table + 1] = {
        text_func = function()
            return self.quick_delete and _("Quick deletion: ON") or _("Quick deletion: OFF")
        end,
        keep_menu_open = true,
        callback = function()
            self.quick_delete = not self.quick_delete
            self:reloadItems()
        end,
    }
    item_table[#item_table].separator = true
    item_table[#item_table + 1] = {
        text = _("Word type"),
        callback = function()
            self:showWordTypeFilterDialog()
        end,
    }
    item_table[#item_table + 1] = {
        text_func = function()
            return self.filter_ai_status and "✓ " .. _("Not AI enriched") or _("Not AI enriched")
        end,
        keep_menu_open = true,
        callback = function()
            self.filter_ai_status = not self.filter_ai_status
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table + 1] = {
        text = _("Clear filters"),
        enabled = hasAnyFilter(self),
        callback = function()
            clearFilters(self)
        end,
    }
    item_table[#item_table + 1] = {
        text = _("Close"),
        callback = function()
            UIManager:close(menu)
        end,
    }

    menu = Menu:new{
        title = _("Actions"),
        item_table = item_table,
        covers_fullscreen = false,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(menu)
end

function Filters.showWordTypeFilterDialog(self)
    local menu
    local items = {}
    local book_id = self.filter_book_id or self.book_id
    local word_types = DB.listWordTypes(book_id)

    local function setWordType(word_type)
        self.filter_word_type = word_type or ""
        if menu then UIManager:close(menu) end
        self.show_page = 1
        self:reloadItems()
    end

    for _, word_type in ipairs(word_types) do
        items[#items + 1] = {
            text = word_type,
            enabled = self.filter_word_type ~= word_type,
            callback = function()
                setWordType(word_type)
            end,
        }
    end
    if #items == 0 then
        items[#items + 1] = {
            text = _("No word types yet"),
            enabled = false,
        }
    end
    items[#items + 1] = {
        text = _("Clear word type"),
        enabled = (self.filter_word_type or "") ~= "",
        callback = function()
            setWordType("")
        end,
    }
    items[#items + 1] = {
        text = _("Back"),
        callback = function()
            UIManager:close(menu)
            self:showActionsDialog()
        end,
    }

    menu = Menu:new{
        title = _("Word type"),
        item_table = items,
        covers_fullscreen = false,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(menu)
end

function Filters.showSourceLanguageFilterDialog(self)
    local dialog
    local buttons = {}
    local book_id = self.filter_book_id or self.book_id
    local now = os.time()
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
            self:showActionsDialog()
        end,
    } }

    dialog = ButtonDialog:new{
        title = _("Source language"),
        buttons = buttons,
    }
    UIManager:show(dialog)
end

function Filters.showTextFilterDialog(self)
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
                    raw = TextUtils.trim(raw)
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

function Filters.showBookFilter(self)
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

function Filters.showSortDialog(self)
    local menu
    local function applySort(sort_by, sort_dir)
        self.sort_by = Filters.normalizeSortBy(sort_by or self.sort_by)
        self.sort_dir = Filters.normalizeSortDir(sort_dir or self.sort_dir)
        if self.plugin and self.plugin.saveSetting then
            self.plugin:saveSetting("card_list_sort", self.sort_by)
            self.plugin:saveSetting("card_list_sort_dir", self.sort_dir)
        end
        if menu then
            UIManager:close(menu)
        end
        self.show_page = 1
        self:reloadItems()
        self:showSortDialog()
    end
    local function clearSort()
        applySort(Filters.DEFAULT_SORT_BY, Filters.DEFAULT_SORT_DIR)
    end

    local items = {}
    items[#items + 1] = {
        text = string.format(_("Current: %s"), currentSortLabel(self.sort_by, self.sort_dir)),
        enabled = false,
    }
    items[#items + 1] = {
        text = _("Sort"),
        enabled = false,
    }
    for __, sort_by in ipairs(SORT_ORDER) do
        local selected = self.sort_by == sort_by
        items[#items + 1] = {
            text = string.format("%s %s", selected and "✓" or " ", SORT_BY_MENU_LABELS[sort_by]),
            enabled = not selected,
            callback = function()
                applySort(sort_by, self.sort_dir)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Order"),
        enabled = false,
    }
    for __, sort_dir in ipairs(SORT_DIR_ORDER) do
        local selected = self.sort_dir == sort_dir
        items[#items + 1] = {
            text = string.format("%s %s", selected and "✓" or " ", currentSortLabel(self.sort_by, sort_dir)),
            enabled = not selected,
            callback = function()
                applySort(self.sort_by, sort_dir)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Clear sort order"),
        enabled = not Filters.isDefaultSort(self.sort_by, self.sort_dir),
        callback = clearSort,
    }
    items[#items + 1] = {
        text = _("Close"),
        callback = function()
            UIManager:close(menu)
        end,
    }

    menu = Menu:new{
        title = _("Sort"),
        item_table = items,
        covers_fullscreen = false,
        width = math.floor(Screen:getWidth() * 0.7),
    }
    UIManager:show(menu)
end

function Filters.onShowMenu(self)
    local item_table = {}

    local all_active = not self.filter_flagged and not self.filter_not_started
        and not self.filter_learning and not self.filter_learned
        and not self.filter_weak and not self.filter_leech and not self.filter_suspended
    item_table[#item_table + 1] = {
        text = all_active and _("✓ All words") or _("All words"),
        keep_menu_open = true,
        callback = function()
            self.filter_flagged = false
            self.filter_not_started = false
            self.filter_learning = false
            self.filter_learned = false
            self.filter_weak = false
            self.filter_leech = false
            self.filter_suspended = false
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table + 1] = {
        text = self.filter_flagged and _("✓ Flagged") or _("Flagged"),
        keep_menu_open = true,
        callback = function()
            self.filter_flagged = not self.filter_flagged
            if self.filter_flagged then
                self.filter_not_started = false
                self.filter_learning = false
                self.filter_learned = false
                self.filter_weak = false
                self.filter_leech = false
                self.filter_suspended = false
            end
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table + 1] = {
        text = self.filter_not_started and _("✓ Not started") or _("Not started"),
        keep_menu_open = true,
        callback = function()
            self.filter_not_started = not self.filter_not_started
            if self.filter_not_started then
                self.filter_flagged = false
                self.filter_learning = false
                self.filter_learned = false
                self.filter_weak = false
                self.filter_leech = false
                self.filter_suspended = false
            end
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table + 1] = {
        text = self.filter_learning and _("✓ Learning") or _("Learning"),
        keep_menu_open = true,
        callback = function()
            self.filter_learning = not self.filter_learning
            if self.filter_learning then
                self.filter_flagged = false
                self.filter_not_started = false
                self.filter_learned = false
                self.filter_weak = false
                self.filter_leech = false
                self.filter_suspended = false
            end
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table + 1] = {
        text = self.filter_learned and _("✓ Learned") or _("Learned"),
        keep_menu_open = true,
        callback = function()
            self.filter_learned = not self.filter_learned
            if self.filter_learned then
                self.filter_flagged = false
                self.filter_not_started = false
                self.filter_learning = false
                self.filter_weak = false
                self.filter_leech = false
                self.filter_suspended = false
            end
            self.show_page = 1
            self:reloadItems()
        end,
    }
    item_table[#item_table].separator = true
    item_table[#item_table + 1] = {
        text = _("Hardest"),
        callback = function()
            UIManager:close(menu)
            self.sort_by = "lapses"
            self.sort_dir = "desc"
            self.show_page = 1
            self:reloadItems()
        end,
    }

    if not self.book_id then
        local books = DB.listBooks()
        item_table[#item_table + 1] = {
            text = self.filter_book_id == nil and _("✓ All books") or _("All books"),
            callback = function()
                self.filter_book_id = nil
                self.show_page = 1
                self:reloadItems()
            end,
        }
        for _, book in ipairs(books) do
            local book_id = book.id
            local title = book.title or _("Untitled")
            item_table[#item_table + 1] = {
                text = self.filter_book_id == book_id and "✓ " .. title or title,
                mandatory = tostring(book.card_count or 0),
                callback = function()
                    self.filter_book_id = book_id
                    self.show_page = 1
                    self:reloadItems()
                end,
            }
        end
    end

    UIManager:show(Menu:new{
        title = _("Cards"),
        item_table = item_table,
        covers_fullscreen = false,
        width = math.floor(Screen:getWidth() * 0.7),
    })
end

return Filters
