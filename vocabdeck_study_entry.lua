-- Main-menu Study entry flow.
-- Provides flat menu items for each source language (one file per language).
local _ = require("gettext")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")

local DB = require("vocabdeck_db")

local StudyEntry = {}

function StudyEntry.startStudy(plugin, language, options)
    options = options or {}
    plugin:saveSetting("last_study_source_language", language)
    DB.setLanguage(language)
    local StudyScreen = require("vocabdeck_study")
    local study = StudyScreen:new{
        plugin = plugin,
        source_language = language,
        book_title = language,
        after_close = options.after_close,
    }
    UIManager:show(study)
end

function StudyEntry.install(VocabDeck)
    -- Long-press: show deck settings for a language.
    local function showDeckSettings(plugin, language)
        local deck_retention_key = "deck_retention_" .. language
        local deck_new_key = "deck_new_limit_" .. language
        local deck_review_key = "deck_review_limit_" .. language

        local function readDeckSetting(key, default)
            local val = plugin:readSetting(key)
            if val == nil then return default end
            return tonumber(val) or default
        end

        local retention = readDeckSetting(deck_retention_key, 90)
        local new_limit = readDeckSetting(deck_new_key, 20)
        local review_limit = readDeckSetting(deck_review_key, 200)

        local ButtonDialog = require("ui/widget/buttondialog")
        local deck_menu
        deck_menu = ButtonDialog:new{
            title = string.format(_("%s deck settings"), language),
            buttons = {
                {
                    {
                        text = string.format(_("Retention: %d%%"), retention),
                        callback = function()
                            UIManager:close(deck_menu)
                            local input_dialog
                            input_dialog = InputDialog:new{
                                title = string.format(_("%s — Desired retention"), language),
                                input = tostring(retention),
                                input_type = "number",
                                buttons = { {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = tonumber(input_dialog:getInputText()) or 90
                                            val = math.max(70, math.min(97, val))
                                            plugin:saveSetting(deck_retention_key, val)
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                } },
                            }
                            UIManager:show(input_dialog)
                            input_dialog:onShowKeyboard()
                        end,
                    },
                },
                {
                    {
                        text = string.format(_("New cards/day: %d"), new_limit),
                        callback = function()
                            UIManager:close(deck_menu)
                            local input_dialog
                            input_dialog = InputDialog:new{
                                title = string.format(_("%s — New cards per day"), language),
                                input = tostring(new_limit),
                                input_type = "number",
                                buttons = { {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = tonumber(input_dialog:getInputText()) or 20
                                            val = math.max(0, val)
                                            plugin:saveSetting(deck_new_key, val)
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                } },
                            }
                            UIManager:show(input_dialog)
                            input_dialog:onShowKeyboard()
                        end,
                    },
                },
                {
                    {
                        text = string.format(_("Review cards/day: %d"), review_limit),
                        callback = function()
                            UIManager:close(deck_menu)
                            local input_dialog
                            input_dialog = InputDialog:new{
                                title = string.format(_("%s — Review cards per day"), language),
                                input = tostring(review_limit),
                                input_type = "number",
                                buttons = { {
                                    {
                                        text = _("Cancel"),
                                        callback = function()
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                    {
                                        text = _("Save"),
                                        is_enter_default = true,
                                        callback = function()
                                            local val = tonumber(input_dialog:getInputText()) or 200
                                            val = math.max(0, val)
                                            plugin:saveSetting(deck_review_key, val)
                                            UIManager:close(input_dialog)
                                            showDeckSettings(plugin, language)
                                        end,
                                    },
                                } },
                            }
                            UIManager:show(input_dialog)
                            input_dialog:onShowKeyboard()
                        end,
                    },
                },
                {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(deck_menu)
                        end,
                    },
                    {
                        text = _("Delete deck"),
                        callback = function()
                            UIManager:close(deck_menu)
                            UIManager:show(ConfirmBox:new{
                                text = string.format(_("Delete the %s deck and all its cards? This cannot be undone."), language),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    local path = DB.getPath()
                                    DB.setLanguage(nil)
                                    os.remove(path)
                                    os.remove(path .. "-wal")
                                    os.remove(path .. "-shm")
                                    UIManager:show(InfoMessage:new{
                                        text = string.format(_("%s deck deleted."), language),
                                        timeout = 2,
                                    })
                                end,
                            })
                        end,
                    },
                },
            },
        }
        UIManager:show(deck_menu)
    end

    -- Build flat menu items for each language file with due count.
    -- Languages with zero due cards are grayed out. Long-press opens deck settings.
    function StudyEntry.buildStudyMenuItems(plugin)
        local languages = DB.listLanguages()
        local legacy_exists = DB.needsMigration()

        if #languages == 0 and not legacy_exists then
            return { {
                text = _("No cards yet. Add words or phrases from the highlight menu or dictionary popup."),
                enabled = false,
            } }
        end

        -- If legacy DB exists but no per-language files yet, run migration transparently
        if legacy_exists then
            DB.setLanguage(nil)  -- ensure legacy DB is loaded
            local ok, migrated_or_err = DB.runMigration()
            if ok then
                languages = DB.listLanguages()
            end
        end

        if #languages == 0 then
            return { {
                text = _("No source languages found. Add or enrich cards first."),
                enabled = false,
            } }
        end

        local require_enriched = plugin:readSetting("require_enriched_for_study")
        if require_enriched == nil then require_enriched = true end
        local daily_new_limit = tonumber(plugin:readSetting("daily_new_cards_limit", 20)) or 20
        local daily_review_limit = tonumber(plugin:readSetting("daily_review_cards_limit", 200)) or 200

        local due_counts = {}
        for _, language in ipairs(languages) do
            DB.setLanguage(language)
            local deck_new = tonumber(plugin:readSetting("deck_new_limit_" .. language)) or daily_new_limit
            local deck_review = tonumber(plugin:readSetting("deck_review_limit_" .. language)) or daily_review_limit
            local ok, counts = pcall(DB.getStudyQueueCounts,
                nil, language, require_enriched, nil, deck_review, 20 * 60, deck_new, true)
            local due_count = 0
            if ok and counts then
                due_count = (tonumber(counts.new) or 0)
                    + (tonumber(counts.learning) or 0)
                    + (tonumber(counts.review) or 0)
            end
            due_counts[language] = due_count
        end

        local items = {}
        for _, language in ipairs(languages) do
            local due_count = due_counts[language] or 0
            local item = {
                text = string.format("%s [%d]", language, due_count),
                -- Long-press opens deck settings
                hold_callback = function(touchmenu_instance)
                    showDeckSettings(plugin, language)
                end,
            }
            if due_count > 0 then
                item.callback = function()
                    StudyEntry.startStudy(plugin, language)
                end
            else
                item.enabled = false
            end
            items[#items + 1] = item
        end
        if #items == 0 then
            return { {
                text = _("No cards due for study."),
                enabled = false,
            } }
        end

        return items
    end
end

return StudyEntry
