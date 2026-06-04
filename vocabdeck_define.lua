-- AI Define flow for selected text and dictionary popup entries.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")

local AIRunner = require("vocabdeck_ai_runner")
local DB = require("vocabdeck_db")
local Capture = require("vocabdeck_capture")
local Enrich = require("vocabdeck_enrich")

local Define = {}

function Define.install(VocabDeck)
    function VocabDeck:_showDefineFailure(params, message)
        local viewer
        local buttons = { {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(viewer)
                end,
            },
            {
                text = _("Save without meaning"),
                callback = function()
                    UIManager:close(viewer)
                    params.meaning = ""
                    params.ai_status = DB.STATUS_PENDING
                    self:_showAddDialog(params)
                end,
            },
        } }
        viewer = TextViewer:new{
            title = _("Define (VocabDeck)"),
            text = message or _("Could not fetch a definition."),
            buttons_table = buttons,
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end

    function VocabDeck:_applyDefineResult(params, result)
        local headword = Capture.cleanText(result.headword or "")
        if headword ~= "" then
            params.phrase = headword
        end
        params.meaning = Capture.cleanMeaning(result.meaning or "")
        params.synonym = Capture.cleanMeaning(result.synonym or "")
        params.pronunciation = Capture.cleanMeaning(result.pronunciation or "")
        params.word_type = Capture.cleanMeaning(result.word_type or "")
        local ai_lang = Capture.cleanMeaning(result.source_language or "")
        if (params.source_language or "") == "" or ai_lang ~= "" then
            params.source_language = self:resolveSourceLanguage{
                source_language = Capture.cleanMeaning(result.source_language or ""),
                dictionary_source_language = params.dictionary_source_language,
            }
        end
        if Capture.isPhrase(params.phrase) then
            params.pronunciation = ""
            if params.word_type == "" then
                params.word_type = "Phrase"
            end
        end
        params.ai_status = DB.STATUS_ENRICHED
        params.allow_update_existing = true
    end

    function VocabDeck:_showDefineResult(params, result)
        self:_applyDefineResult(params, result)

        local header = params.phrase or ""
        local meta = {}
        if params.word_type ~= "" then meta[#meta + 1] = params.word_type end
        if params.pronunciation ~= "" then meta[#meta + 1] = params.pronunciation end
        if #meta > 0 then header = header .. "\n" .. table.concat(meta, " · ") end

        local details = { header }
        if params.meaning ~= "" then details[#details + 1] = params.meaning end
        if params.synonym ~= "" then
            details[#details + 1] = string.format(_("Synonyms: %s"), params.synonym)
        end

        local viewer
        local buttons = { {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(viewer)
                end,
            },
            {
                text = _("Add Card"),
                callback = function()
                    UIManager:close(viewer)
                    self:_showAddDialog(params)
                end,
            },
        } }
        viewer = TextViewer:new{
            title = _("Define (VocabDeck)"),
            text = table.concat(details, "\n\n"),
            buttons_table = buttons,
            add_default_buttons = false,
        }
        UIManager:show(viewer)
    end

    function VocabDeck:defineWithVocabDeck(params)
        if not params or not params.phrase or params.phrase == "" then
            UIManager:show(InfoMessage:new{ text = _("No word or phrase selected."), timeout = 3 })
            return
        end
        local book_id, err = self:_getBookId()
        if not book_id then
            UIManager:show(InfoMessage:new{ text = err, timeout = 3 })
            return
        end
        AIRunner.run(self, {
            message = _("Defining... Tap outside to cancel."),
            phrase = params.phrase,
            work = function(trap)
                local anchored = Capture.anchorInfoMessageBottomLeft(trap)
                return Enrich.enrichCard(self, {
                    phrase = params.phrase,
                    ai_context = Capture.firstText(params.ai_context, params.sentence, params.display_context),
                    is_phrase = Capture.isPhrase(params.phrase),
                    source_language = "",  -- let AI detect independently
                }, anchored)
            end,
            on_error = function(define_err)
                self:_showDefineFailure(params, AIRunner.formatError(define_err or _("Unknown error")))
            end,
            on_success = function(result)
                result.meaning = Capture.cleanMeaning(result.meaning or "")
                result.synonym = Capture.cleanMeaning(result.synonym or "")
                if result.meaning == "" then
                    self:_showDefineFailure(params, _("VocabDeck did not receive a usable definition."))
                    return
                end
                self:_showDefineResult(params, result)
            end,
        })
    end

    function VocabDeck:defineFromHighlight(reader_highlight)
        local params = self:_buildHighlightCardParams(reader_highlight)
        if not params then
            return
        end
        self:_closeHighlightDialog(reader_highlight)
        self:defineWithVocabDeck(params)
    end

    function VocabDeck:defineFromDictionary(dict_popup)
        local params = self:_buildDictionaryCardParams(dict_popup)
        if params then
            self:defineWithVocabDeck(params)
        end
    end
end

return Define
