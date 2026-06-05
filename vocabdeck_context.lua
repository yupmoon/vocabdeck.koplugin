-- Document, book, source-language, and duplicate helpers.
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")

local DB = require("vocabdeck_db")
local Capture = require("vocabdeck_capture")
local TextUtils = require("vocabdeck_text_utils")

local Context = {}

function Context.install(VocabDeck)
    function VocabDeck:getDocumentFilePath()
        if self.ui and self.ui.document and self.ui.document.file then
            return self.ui.document.file
        end
        return nil
    end

    function VocabDeck:getDocumentTitle()
        if self.ui and self.ui.doc_props then
            local title = self.ui.doc_props.title
            if title and title ~= "" then return title end
        end
        local filepath = self:getDocumentFilePath()
        if filepath then
            local filename = filepath:match("([^/\\]+)$") or filepath
            return filename:match("(.+)%.[^%.]+$") or filename
        end
        return _("Unknown")
    end

    function VocabDeck:getDocumentSourceLanguage()
        local props = self.ui and self.ui.doc_props
        if (type(props) ~= "table" or next(props) == nil) and self.ui and self.ui.doc_settings
            and self.ui.doc_settings.data then
            props = self.ui.doc_settings.data.doc_props
        end
        if type(props) ~= "table" then return "" end

        local language = props.language or props.lang or props.book_lang
        if type(language) == "table" then
            language = language[1]
        end
        if (not language or language == "") and type(props.languages) == "table" then
            language = props.languages[1]
        end
        if type(language) ~= "string" then return "" end
        return TextUtils.trim(language)
    end

    function VocabDeck:getKnownBookSourceLanguage()
        local book_id = self:_getBookId()
        if not book_id then return "" end
        local languages = DB.listSourceLanguages(book_id)
        if type(languages) == "table" and #languages == 1 then
            return languages[1] or ""
        end
        return ""
    end

    function VocabDeck:resolveSourceLanguage(params)
        params = params or {}
        return Capture.firstText(
            params.source_language,
            params.dictionary_source_language
        )
    end

    function VocabDeck:_getBookId(params)
        params = params or {}
        if params.manual_entry then
            local source_language = self:resolveSourceLanguage(params)
            if source_language == "" then
                return nil, _("Choose a source language first.")
            end
            DB.setLanguage(source_language)
            if params.manual_book_id then
                return params.manual_book_id
            end
            local title = string.format(_("Manual entries (%s)"), source_language)
            local filepath = "vocabdeck://manual/" .. source_language
            local book_id = DB.getOrCreateBook(title, filepath, source_language)
            if not book_id then
                return nil, _("Failed to create manual card record.")
            end
            return book_id
        end
        local filepath = self:getDocumentFilePath()
        if not filepath then
            return nil, _("Open a book to save cards.")
        end
        local source_language = self:resolveSourceLanguage(params)
        if source_language == "" then
            source_language = self:getDocumentSourceLanguage()
        end
        DB.setLanguage(source_language)
        local book_id = DB.getOrCreateBook(self:getDocumentTitle(), filepath, source_language)
        if not book_id then
            return nil, _("Failed to create book record.")
        end
        return book_id
    end

    function VocabDeck:_hasDuplicate(book_id, phrase, source_language)
        local existing = DB.findDuplicateCard(book_id, phrase, source_language)
        if not existing then return false end
        if (existing.source_language or "") == "" and source_language and source_language ~= "" then
            DB.updateCardSourceLanguage(existing.id, source_language)
        end
        UIManager:show(InfoMessage:new{
            text = string.format(_("Already in VocabDeck:\n%s"), phrase),
            timeout = 3,
        })
        return true
    end
end

return Context
