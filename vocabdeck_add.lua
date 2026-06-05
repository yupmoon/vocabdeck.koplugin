-- Card creation workflow for dictionary, highlight, and manual entries.
local _ = require("gettext")
local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local logger = require("logger")

local DB = require("vocabdeck_db")
local Capture = require("vocabdeck_capture")
local Enrich = require("vocabdeck_enrich")
local ManualAdd = require("vocabdeck_manual_add")
local AIRunner = require("vocabdeck_ai_runner")
local TextUtils = require("vocabdeck_text_utils")

local Add = {}

function Add.install(VocabDeck)
    function VocabDeck:_showAddDialog(params)
        params = params or {}
        local phrase = params.phrase or ""
        if phrase == "" then
            UIManager:show(InfoMessage:new{ text = _("No text selected."), timeout = 3 })
            return
        end
        local book_id, err = self:_getBookId(params)
        if not book_id then
            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
            return
        end
        local source_language = self:resolveSourceLanguage(params)
        if source_language ~= "" then
            params.source_language = source_language
        end
        if not params.allow_update_existing and self:_hasDuplicate(book_id, phrase, source_language) then
            return
        end

        local ask_phrase = self.settings:readSetting("ask_phrase_edit_on_add")
        if ask_phrase == nil then ask_phrase = true end
        ask_phrase = ask_phrase and true or false
        local ask_note = self.settings:readSetting("ask_note_on_add")
        if ask_note == nil then ask_note = true end
        ask_note = ask_note and true or false

        if not ask_phrase and not ask_note then
            self:_persistCard(phrase, "", params)
            return
        end

        if not ask_phrase then
            self:_showNoteDialog(phrase, params)
            return
        end

        local phrase_dialog
        local function closePhraseDialog()
            if phrase_dialog then
                if phrase_dialog.onCloseKeyboard then
                    phrase_dialog:onCloseKeyboard()
                end
                UIManager:close(phrase_dialog)
                UIManager:setDirty(nil, "ui")
            end
        end
        phrase_dialog = InputDialog:new{
            title = _("Add to VocabDeck"),
            description = _("Edit word or phrase if needed."),
            input = phrase,
            input_hint = _("Selected word or phrase"),
            buttons = { {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = closePhraseDialog,
                },
                {
                    text = ask_note and _("Next") or _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local final_phrase = phrase_dialog:getInputText() or ""
                        final_phrase = TextUtils.trim(final_phrase)
                        if final_phrase == "" then final_phrase = phrase end
                        if final_phrase ~= phrase and not params.allow_update_existing
                            and self:_hasDuplicate(book_id, final_phrase, source_language) then
                            return
                        end
                        closePhraseDialog()
                        if ask_note then
                            self:_showNoteDialog(final_phrase, params)
                        else
                            self:_persistCard(final_phrase, "", params)
                        end
                    end,
                },
            } },
        }
        UIManager:show(phrase_dialog)
        phrase_dialog:onShowKeyboard()
    end

    function VocabDeck:_showNoteDialog(final_phrase, params, touchmenu_instance)
        local description
        if params.sentence and params.sentence ~= "" then
            description = _("Sentence: ") .. params.sentence
        end
        local note_dialog
        local function closeNoteDialog()
            if note_dialog then
                if note_dialog.onCloseKeyboard then
                    note_dialog:onCloseKeyboard()
                end
                UIManager:close(note_dialog)
                UIManager:setDirty(nil, "ui")
            end
        end
        note_dialog = InputDialog:new{
            title = _("Add note"),
            description = description,
            input = "",
            input_hint = _("Optional personal note…"),
            buttons = { {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = closeNoteDialog,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local note = note_dialog:getInputText() or ""
                        closeNoteDialog()
                        self:_persistCard(final_phrase, note, params, touchmenu_instance)
                    end,
                },
            } },
        }
        UIManager:show(note_dialog)
        note_dialog:onShowKeyboard()
    end

    function VocabDeck:_persistCard(phrase, note, params, touchmenu_instance)
        params = params or {}
        local book_id, err = self:_getBookId(params)
        if not book_id then
            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
            return
        end
        local word_type = params.word_type or ""
        local pronunciation = params.pronunciation or ""
        local source_language = self:resolveSourceLanguage(params)
        if source_language ~= "" then
            params.source_language = source_language
        end
        local existing = DB.findDuplicateCard(book_id, phrase, source_language)
        if Capture.isPhrase(phrase) then
            pronunciation = ""
            word_type = "Phrase"
        end
        if existing and params.allow_update_existing then
            local dialog
            local function updateExisting()
                if dialog then UIManager:close(dialog) end
                DB.applyEnrichment(existing.id, {
                    pronunciation = pronunciation,
                    meaning = params.meaning or "",
                    synonym = params.synonym or "",
                    word_type = word_type,
                    source_language = source_language,
                    status = params.ai_status or DB.STATUS_ENRICHED,
                    error = "",
                })
                UIManager:show(Notification:new{ text = _("VocabDeck card updated.") })
                if params.after_save then params.after_save(existing.id, phrase, params) end
            end
            dialog = ButtonDialog:new{
                title = _("Card already exists"),
                buttons = { {
                    {
                        text = _("Cancel"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                    {
                        text = _("Update existing card"),
                        callback = updateExisting,
                    },
                } },
            }
            UIManager:show(dialog)
            return
        end
        if existing then
            if (existing.source_language or "") == "" and source_language ~= "" then
                DB.updateCardSourceLanguage(existing.id, source_language)
            end
            UIManager:show(InfoMessage:new{
                text = string.format(_("Already in VocabDeck:\n%s"), phrase),
                timeout = 3,
            })
            return
        end
        local card_id = DB.addCard(book_id, {
            phrase = phrase,
            sentence = params.sentence or "",
            ai_context = params.ai_context or "",
            display_context = params.display_context or "",
            pronunciation = pronunciation,
            meaning = params.meaning or "",
            synonym = params.synonym or "",
            word_type = word_type,
            source_language = source_language,
            user_note = note or "",
            ai_status = params.ai_status or DB.STATUS_PENDING,
        })
        if not card_id then
            UIManager:show(InfoMessage:new{ text = _("Failed to save card."), timeout = 3 })
            return
        end

        UIManager:show(Notification:new{ text = _("Word or phrase added to VocabDeck.") })
        if params.after_save then params.after_save(card_id, phrase, params) end
        return card_id
    end

    function VocabDeck:addManualCard(touchmenu_instance, options)
        ManualAdd.start(self, touchmenu_instance, options)
    end

    -- Enrich first, then auto-save — same pattern as Define (VD) but silent.
    function VocabDeck:_defineAndAutoSave(params)
        if not params or not params.phrase or params.phrase == "" then return end
        AIRunner.run(self, {
            message = _("Enriching... Tap outside to cancel."),
            phrase = params.phrase,
            work = function(trap)
                local anchored = Capture.anchorInfoMessageBottomLeft(trap)
                return Enrich.enrichCard(self, {
                    phrase = params.phrase,
                    ai_context = params.ai_context or "",
                    source_language = "",
                }, anchored)
            end,
            on_error = function(err)
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Enrichment failed:\n%s"), err or _("Unknown error")),
                    timeout = 3,
                })
            end,
            on_success = function(result)
                logger.info("VD+AI source_language from AI: '" .. (result.source_language or "") .. "'")
                logger.info("VD+AI dict fallback: '" .. (params.dictionary_source_language or "") .. "'")
                params.source_language = nil  -- let AI detection override metadata
                self:_applyDefineResult(params, result)
                logger.info("VD+AI final source_language: '" .. (params.source_language or "") .. "'")
                self:_persistCard(params.phrase, "", params)
            end,
        })
    end

    function VocabDeck:addWithAIFromHighlight(reader_highlight)
        local params = self:_buildHighlightCardParams(reader_highlight)
        if not params then return end
        self:_closeHighlightDialog(reader_highlight)
        self:_defineAndAutoSave(params)
    end

    function VocabDeck:addWithAIFromDictionary(dict_popup)
        local params = self:_buildDictionaryCardParams(dict_popup)
        if not params then return end
        if dict_popup and dict_popup.onClose then
            UIManager:close(dict_popup)
        end
        if dict_popup and dict_popup.highlight and dict_popup.highlight.clear then
            dict_popup.highlight:clear()
        end
        self:_defineAndAutoSave(params)
    end

    function VocabDeck:_buildDictionaryCardParams(dict_popup)
        local phrase = Capture.getDictionaryPhrase(dict_popup)
        if phrase == "" then
            UIManager:show(InfoMessage:new{ text = _("No word to add."), timeout = 3 })
            return nil
        end

        local word_type, meaning =
            Capture.splitDictionaryDefinition(Capture.getDictionaryDefinition(dict_popup))
        local ai_context, display_context, sentence =
            Capture.dictionaryContext(self, dict_popup, phrase)
        local source_language = Capture.getDictionarySourceLanguage(dict_popup)
        return {
            phrase = phrase,
            sentence = sentence,
            ai_context = ai_context,
            display_context = display_context,
            meaning = meaning,
            word_type = word_type,
            source_language = self:resolveSourceLanguage{ source_language = source_language },
            dictionary_source_language = source_language,
            ai_status = DB.STATUS_PENDING,
        }
    end

    function VocabDeck:_buildHighlightCardParams(reader_highlight)
        if not reader_highlight or not reader_highlight.selected_text then
            return nil
        end
        local selected = reader_highlight.selected_text
        local phrase = selected.text or ""
        if phrase == "" then
            return nil
        end
        local ai_context, display_context, sentence = Enrich.captureContexts(self, self.ui, selected)
        return {
            phrase = phrase,
            ai_context = ai_context,
            display_context = display_context,
            sentence = sentence,
            source_language = self:resolveSourceLanguage(),
            ai_status = DB.STATUS_PENDING,
        }
    end

    function VocabDeck:_closeHighlightDialog(reader_highlight)
        if reader_highlight and reader_highlight.highlight_dialog then
            UIManager:close(reader_highlight.highlight_dialog)
            reader_highlight.highlight_dialog = nil
        end
        if reader_highlight and reader_highlight.clear then
            reader_highlight:clear()
        end
    end

    function VocabDeck:addFromHighlight(reader_highlight)
        local params = self:_buildHighlightCardParams(reader_highlight)
        if not params then
            return
        end
        self:_closeHighlightDialog(reader_highlight)
        self:_showAddDialog(params)
    end

    function VocabDeck:addFromDictionary(dict_popup)
        local params = self:_buildDictionaryCardParams(dict_popup)
        if params then
            self:_showAddDialog(params)
        end
    end
end

return Add
