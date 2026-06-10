-- VocabDeck: import words from the KOReader Vocabulary Builder database.
--
-- The VocabBuilder plugin stores its entries in a SQLite database located at
-- `<settings_dir>/vocabulary_builder.sqlite3`. We only read from it; we never
-- write. Words are imported into the current book's deck; if the book has no
-- title registered in vocabulary_builder, all words are imported.
local _ = require("gettext")
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local Device = require("device")
local logger = require("logger")

local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")
local TextUtils = require("vocabdeck_text_utils")
local CardFields = require("vocabdeck_card_fields")

local Importer = {}
local ANKI_IMPORT_TITLE = "Anki import"
local ANKI_IMPORT_FILEPATH = "vocabdeck://import/anki"
local COMMON_IMPORT_LANGUAGES = {
    "Spanish", "French", "German", "Italian", "Portuguese",
    "Japanese", "Chinese", "Korean", "Russian", "Arabic",
}
local UNMAPPED_FIELD = ""
local SINGLE_ANKI_FIELDS = {
    phrase = true,
    pronunciation = true,
    word_type = true,
    meaning = true,
    synonym = true,
    sentence = true,
    display_context = true,
}

local function getVocabDbPath()
    return ffiUtil.joinPath(DataStorage:getSettingsDir(), "vocabulary_builder.sqlite3")
end

local function vocabDbExists()
    return util.pathExists(getVocabDbPath())
end

local function parentPath(path)
    path = TextUtils.trim(path or "")
    if path == "" then return DataStorage:getDataDir() end
    path = path:gsub("/+$", "")
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then return parent end
    return DataStorage:getDataDir()
end

local function closeInputDialog(dialog)
    if dialog and dialog.onCloseKeyboard then
        dialog:onCloseKeyboard()
    end
    UIManager:close(dialog)
end

local function cleanAnkiText(text, html)
    text = tostring(text or "")
    text = text:gsub("\239\187\191", "")
    if html then
        text = text:gsub("[\r\n]+", " ")
        text = text:gsub("<%s*br%s*/?%s*>", "\n")
        text = text:gsub("</%s*p%s*>", "\n")
        text = text:gsub("</%s*div%s*>", "\n")
        text = text:gsub("</%s*li%s*>", "\n")
        text = text:gsub("<[^>]->", "")
    end
    text = text
        :gsub("&nbsp;", " ")
        :gsub("&#160;", " ")
        :gsub("&amp;", "&")
        :gsub("&lt;", "<")
        :gsub("&gt;", ">")
        :gsub("&quot;", "\"")
        :gsub("&#39;", "'")
        :gsub("&apos;", "'")
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n%s+", "\n"):gsub("%s+\n", "\n")
    text = text:gsub("\n\n\n+", "\n\n")
    return TextUtils.trim(text)
end

local function splitLine(line, separator)
    local fields = {}
    separator = separator or "\t"
    if separator == "\t" then
        line = line .. "\t"
        for field in line:gmatch("(.-)\t") do
            fields[#fields + 1] = field
        end
    else
        fields[1] = line
    end
    return fields
end

local function readAnkiTextFile(path)
    local f = io.open(path, "rb")
    if not f then
        return nil, _("Anki export file could not be opened.")
    end
    local content = f:read("*all") or ""
    f:close()
    return content:gsub("^\239\187\191", "")
end

local function readAnkiMetadataAndRows(content)
    local separator = "\t"
    local html = false
    local tags_column = nil
    local rows = {}

    for raw_line in (content .. "\n"):gmatch("(.-)\n") do
        local line = raw_line:gsub("\r$", "")
        local trimmed = TextUtils.trim(line)
        if trimmed == "" then
            -- skip blank rows
        elseif trimmed:sub(1, 1) == "#" then
            local key, value = trimmed:match("^#([^:]+):%s*(.*)$")
            key = key and key:lower() or nil
            value = value or ""
            if key == "separator" and value:lower() == "tab" then
                separator = "\t"
            elseif key == "html" then
                html = value:lower() == "true"
            elseif key == "tags column" then
                tags_column = tonumber(value)
            end
        else
            rows[#rows + 1] = splitLine(line, separator)
        end
    end

    return {
        separator = separator,
        html = html,
        tags_column = tags_column,
        rows = rows,
    }
end

local function inspectAnkiTextFile(path)
    local content, err = readAnkiTextFile(path)
    if not content then return nil, err end
    local data = readAnkiMetadataAndRows(content)
    local sample = data.rows[1] or {}
    data.column_count = #sample
    data.sample_fields = sample
    return data
end

local function fieldLabel(field_key)
    if field_key == UNMAPPED_FIELD or not field_key then return _("Unmapped") end
    for _, spec in ipairs(CardFields.FIELD_LABELS) do
        if spec.key == field_key then return spec.label end
    end
    return field_key
end

local function defaultAnkiMapping(info)
    local mapping = {}
    local column_count = tonumber(info and info.column_count) or 0
    local tags_column = tonumber(info and info.tags_column)
    if column_count >= 1 and tags_column ~= 1 then mapping[1] = "phrase" end
    if column_count >= 2 and tags_column ~= 2 then mapping[2] = "meaning" end
    return mapping
end

local function normalizeAnkiMapping(raw_mapping, info)
    local column_count = tonumber(info and info.column_count) or 0
    local tags_column = tonumber(info and info.tags_column)
    local mapping = {}
    if type(raw_mapping) == "table" then
        for i = 1, column_count do
            if i ~= tags_column then
                local value = raw_mapping[i] or raw_mapping[tostring(i)]
                if value and value ~= UNMAPPED_FIELD then
                    mapping[i] = value
                end
            end
        end
    end
    if next(mapping) == nil then
        mapping = defaultAnkiMapping(info)
    end
    return mapping
end

local function saveAnkiMapping(plugin, mapping)
    local stored = {}
    for column, field_key in pairs(mapping or {}) do
        local column_number = tonumber(column)
        if column_number and field_key and field_key ~= UNMAPPED_FIELD then
            stored[column_number] = field_key
        end
    end
    plugin:saveSetting("anki_import_column_mapping", stored)
    if plugin.settings then plugin.settings:flush() end
end

local function parseAnkiTextFile(path, opts)
    opts = opts or {}
    local content, err = readAnkiTextFile(path)
    if not content then return nil, err end
    local data = readAnkiMetadataAndRows(content)
    local mapping = opts.column_mapping or {}
    local cards = {}
    local skipped_rows = 0
    local tags_column = tonumber(data.tags_column)

    local has_phrase = false
    for _column, field_key in pairs(mapping) do
        if field_key == "phrase" then
            has_phrase = true
            break
        end
    end
    if not has_phrase then
        return nil, _("Map one column to Word/Phrase before importing.")
    end

    for _, fields in ipairs(data.rows) do
        local card = {
            phrase = "",
            pronunciation = "",
            word_type = "",
            meaning = "",
            synonym = "",
            sentence = "",
            display_context = "",
            ai_context = "",
            user_note = "",
            source_language = opts.source_language or "",
        }
        local notes = {}
        for i, value in ipairs(fields) do
            local field_key = i ~= tags_column and mapping[i] or nil
            if field_key and field_key ~= UNMAPPED_FIELD then
                local cleaned = cleanAnkiText(value, data.html)
                if field_key == "user_note" then
                    if cleaned ~= "" then notes[#notes + 1] = cleaned end
                elseif card[field_key] ~= nil then
                    card[field_key] = cleaned
                end
            end
        end
        if card.phrase == "" then
            skipped_rows = skipped_rows + 1
        else
            if card.sentence ~= "" and card.display_context == "" then
                card.display_context = card.sentence
            end
            if card.ai_context == "" then
                card.ai_context = card.display_context ~= "" and card.display_context or card.sentence
            end
            card.user_note = table.concat(notes, "\n\n")
            card.ai_status = card.meaning ~= "" and DB.STATUS_ENRICHED or DB.STATUS_PENDING
            cards[#cards + 1] = card
        end
    end

    return cards, nil, skipped_rows
end

local function showAnkiResult(imported, skipped, skipped_rows)
    local msg = string.format(
        _("Imported %d new cards. Skipped %d duplicates."),
        imported or 0,
        skipped or 0
    )
    if (tonumber(skipped_rows) or 0) > 0 then
        msg = msg .. "\n" .. string.format(_("Skipped %d rows without a word."), skipped_rows)
    end
    UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
end

function Importer.importAnkiText(plugin, path, source_language, column_mapping)
    path = TextUtils.trim(path or "")
    source_language = TextUtils.trim(source_language or "")
    if path == "" then
        UIManager:show(InfoMessage:new{ text = _("Choose an Anki export file first."), timeout = 3 })
        return
    end
    if not util.pathExists(path) then
        UIManager:show(InfoMessage:new{ text = _("Anki export file not found."), timeout = 3 })
        return
    end
    if source_language == "" then
        UIManager:show(InfoMessage:new{ text = _("Choose a source language first."), timeout = 3 })
        return
    end

    DB.setLanguage(source_language)
    local book_id = DB.getOrCreateBook(ANKI_IMPORT_TITLE, ANKI_IMPORT_FILEPATH, source_language)
    if not book_id then
        UIManager:show(InfoMessage:new{ text = _("Could not prepare Anki import deck."), timeout = 3 })
        return
    end

    local info, inspect_err = inspectAnkiTextFile(path)
    if not info then
        UIManager:show(InfoMessage:new{ text = inspect_err or _("Anki import failed."), timeout = 3 })
        return
    end
    column_mapping = normalizeAnkiMapping(column_mapping or plugin:readSetting("anki_import_column_mapping"), info)
    local cards, err, skipped_rows = parseAnkiTextFile(path, {
        source_language = source_language,
        column_mapping = column_mapping,
    })
    if not cards then
        UIManager:show(InfoMessage:new{ text = err or _("Anki import failed."), timeout = 3 })
        return
    end
    if #cards == 0 then
        UIManager:show(InfoMessage:new{ text = _("No importable Anki rows found."), timeout = 3 })
        return
    end

    plugin:saveSetting("anki_import_last_path", path)
    saveAnkiMapping(plugin, column_mapping)

    local imported, skipped = DB.addCardsIfMissing(book_id, cards)
    showAnkiResult(imported, skipped, skipped_rows)
    logger.info("vocabdeck: anki text import", imported, skipped, skipped_rows)
end

local function rememberAnkiPath(plugin, path)
    path = TextUtils.trim(path or "")
    if path ~= "" then
        plugin:saveSetting("anki_import_last_path", path)
        if plugin.settings then plugin.settings:flush() end
    end
    return path
end

local function buildAnkiLanguageItems(plugin, path)
    local seen = {}
    local items = {}
    local function addLanguage(language)
        language = TextUtils.trim(language or "")
        if language == "" or seen[language:lower()] or #items >= 10 then return end
        seen[language:lower()] = true
        items[#items + 1] = {
            text = language,
            callback = function()
                DB.setLanguage(language)
                Importer.showAnkiMappingDialog(plugin, language, path)
            end,
        }
    end

    local ok, languages = pcall(DB.listLanguages)
    if ok and type(languages) == "table" then
        for _, language in ipairs(languages) do
            addLanguage(language)
        end
    end
    for _, language in ipairs(COMMON_IMPORT_LANGUAGES) do
        addLanguage(language)
    end
    return items
end

function Importer.showAnkiImportDialog(plugin)
    local ok_pc, PathChooser = pcall(require, "ui/widget/pathchooser")
    if not ok_pc or not PathChooser then
        Importer.showAnkiPathDialog(plugin)
        return
    end

    local last_path = plugin:readSetting("anki_import_last_path", "") or ""
    local pc = PathChooser:new{
        title = _("Select Anki text export"),
        select_file = true,
        select_directory = false,
        show_files = true,
        path = parentPath(last_path),
        onConfirm = function(chosen_path)
            chosen_path = rememberAnkiPath(plugin, chosen_path)
            if chosen_path == "" then
                UIManager:show(InfoMessage:new{ text = _("Choose an Anki export file first."), timeout = 3 })
                return
            end
            Importer.showAnkiLanguageMenu(plugin, chosen_path)
        end,
    }
    UIManager:show(pc)
end

function Importer.showAnkiLanguageMenu(plugin, path)
    path = TextUtils.trim(path or "")
    if path == "" then
        UIManager:show(InfoMessage:new{ text = _("Choose an Anki export file first."), timeout = 3 })
        return
    end
    local screen = Device.screen
    UIManager:show(Menu:new{
        title = _("Anki source language"),
        item_table = buildAnkiLanguageItems(plugin, path),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.8),
    })
end

function Importer.showAnkiPathDialog(plugin)
    local path_dialog
    path_dialog = InputDialog:new{
        title = _("Anki text export path"),
        input = plugin:readSetting("anki_import_last_path", "") or "",
        buttons = { {
            {
                text = _("Cancel"),
                callback = function() closeInputDialog(path_dialog) end,
            },
            {
                text = _("Next"),
                is_enter_default = true,
                callback = function()
                    local path = TextUtils.trim(path_dialog:getInputText() or "")
                    if path == "" then
                        UIManager:show(InfoMessage:new{ text = _("Choose an Anki export file first."), timeout = 3 })
                        return
                    end
                    closeInputDialog(path_dialog)
                    path = rememberAnkiPath(plugin, path)
                    Importer.showAnkiLanguageMenu(plugin, path)
                end,
            },
        } },
    }
    UIManager:show(path_dialog)
    path_dialog:onShowKeyboard()
end

function Importer.showAnkiMappingDialog(plugin, source_language, path, current_mapping)
    local info, err = inspectAnkiTextFile(path)
    if not info then
        UIManager:show(InfoMessage:new{ text = err or _("Anki export file could not be opened."), timeout = 3 })
        return
    end
    if (tonumber(info.column_count) or 0) <= 0 then
        UIManager:show(InfoMessage:new{ text = _("No importable Anki rows found."), timeout = 3 })
        return
    end
    local mapping = normalizeAnkiMapping(current_mapping or plugin:readSetting("anki_import_column_mapping"), info)
    local screen = Device.screen
    local mapping_menu
    local function fieldUsedByOtherColumn(field_key, column)
        if not SINGLE_ANKI_FIELDS[field_key] then return false end
        for other_column, other_field in pairs(mapping) do
            if tonumber(other_column) ~= tonumber(column) and other_field == field_key then
                return true
            end
        end
        return false
    end
    local function openFieldMenu(column)
        local field_menu
        local field_items = {
            {
                text = fieldLabel(UNMAPPED_FIELD),
                callback = function()
                    UIManager:close(field_menu)
                    mapping[column] = nil
                    saveAnkiMapping(plugin, mapping)
                    Importer.showAnkiMappingDialog(plugin, source_language, path, mapping)
                end,
            },
        }
        for _, spec in ipairs(CardFields.FIELD_LABELS) do
            local disabled = fieldUsedByOtherColumn(spec.key, column)
            field_items[#field_items + 1] = {
                text = disabled and (spec.label .. " *") or spec.label,
                enabled = not disabled,
                callback = function()
                    if disabled then return end
                    UIManager:close(field_menu)
                    mapping[column] = spec.key
                    saveAnkiMapping(plugin, mapping)
                    Importer.showAnkiMappingDialog(plugin, source_language, path, mapping)
                end,
            }
        end
        field_items[#field_items + 1] = {
            text = _("Back"),
            callback = function()
                UIManager:close(field_menu)
                Importer.showAnkiMappingDialog(plugin, source_language, path, mapping)
            end,
        }
        field_menu = Menu:new{
            title = string.format(_("Column %d"), column),
            item_table = field_items,
            covers_fullscreen = true,
            width = math.floor(screen:getWidth() * 0.9),
            height = math.floor(screen:getHeight() * 0.8),
        }
        UIManager:show(field_menu)
    end
    local items = {}
    for column = 1, info.column_count do
        local is_tags_column = tonumber(info.tags_column) == column
        local label = fieldLabel(is_tags_column and UNMAPPED_FIELD or mapping[column])
        if is_tags_column then
            label = label .. " (" .. _("tags") .. ")"
        end
        items[#items + 1] = {
            text = string.format(_("Column %d: %s"), column, label),
            enabled = not is_tags_column,
            callback = function()
                if is_tags_column then return end
                UIManager:close(mapping_menu)
                openFieldMenu(column)
            end,
        }
    end
    items[#items + 1] = {
        text = _("Import"),
        callback = function()
            local has_phrase = false
            for _column, field_key in pairs(mapping) do
                if field_key == "phrase" then
                    has_phrase = true
                    break
                end
            end
            if not has_phrase then
                UIManager:show(InfoMessage:new{ text = _("Map one column to Word/Phrase before importing."), timeout = 3 })
                return
            end
            UIManager:close(mapping_menu)
            Importer.importAnkiText(plugin, path, source_language, mapping)
        end,
    }
    mapping_menu = Menu:new{
        title = _("Anki column mapping"),
        item_table = items,
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.8),
    }
    UIManager:show(mapping_menu)
end

function Importer.showImportMenu(plugin)
    local screen = Device.screen
    UIManager:show(Menu:new{
        title = _("Import"),
        item_table = Importer.buildImportMenuItems(plugin),
        covers_fullscreen = true,
        width = math.floor(screen:getWidth() * 0.9),
        height = math.floor(screen:getHeight() * 0.7),
    })
end

function Importer.buildImportMenuItems(plugin)
    return {
        {
            text = _("Import from Vocabulary Builder"),
            enabled_func = function()
                return plugin
                    and plugin.getDocumentFilePath
                    and plugin:getDocumentFilePath() ~= nil
            end,
            callback = function()
                Importer.showImportDialog(plugin)
            end,
        },
        {
            text = _("Import from Anki text"),
            callback = function()
                Importer.showAnkiImportDialog(plugin)
            end,
        },
    }
end

-- Load words from vocabbuilder restricted to a specific title_id (book).
-- If book_title is nil or no matching title, return all words.
local function loadVocabWords(book_title)
    local path = getVocabDbPath()
    if not util.pathExists(path) then
        return nil, _("Vocabulary Builder database not found.")
    end
    local conn = SQ3.open(path)
    local title_id
    if book_title and book_title ~= "" then
        local stmt = conn:prepare("SELECT id FROM title WHERE name = ? LIMIT 1;")
        stmt:bind(book_title)
        local row = stmt:step()
        stmt:close()
        if row and row[1] then
            title_id = tonumber(row[1])
        end
    end

    local sql
    if title_id then
        sql = string.format(
            "SELECT word, prev_context, next_context FROM vocabulary WHERE title_id = %d ORDER BY create_time ASC;",
            title_id
        )
    else
        sql = "SELECT word, prev_context, next_context FROM vocabulary ORDER BY create_time ASC;"
    end

    local stmt = conn:prepare(sql)
    local words = {}
    while true do
        local row = stmt:step()
        if not row then break end
        words[#words + 1] = {
            word = row[1] or "",
            prev_context = row[2] or "",
            next_context = row[3] or "",
        }
    end
    stmt:close()
    conn:close()
    return words
end

-- Import entries belonging to the active book into `book_id`.
function Importer.importForBook(plugin, book_id, book_title, source_language)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Cannot import — no book record is available."),
            timeout = 3,
        })
        return
    end
    if not vocabDbExists() then
        UIManager:show(InfoMessage:new{
            text = _("Vocabulary Builder database not found. Open a book and look up at least one word first."),
            timeout = 4,
        })
        return
    end

    local words, err = loadVocabWords(book_title)
    if not words then
        UIManager:show(InfoMessage:new{ text = err or _("Import failed."), timeout = 3 })
        return
    end
    if #words == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No words found for this book in Vocabulary Builder."),
            timeout = 3,
        })
        return
    end

    local ai_words = tonumber(plugin.settings:readSetting("ai_context_words", 15)) or 15
    local display_words = tonumber(plugin.settings:readSetting("display_context_words", 15)) or 15
    source_language = plugin:resolveSourceLanguage{
        source_language = source_language or plugin:getDocumentSourceLanguage(),
    }

    local imported = 0
    local skipped = 0
    local cards = {}
    for _, entry in ipairs(words) do
        local phrase = entry.word or ""
        if phrase ~= "" then
            local ai_context, display_context = Enrich.buildContextWindows(
                phrase, entry.prev_context, entry.next_context, ai_words, display_words
            )
            local sentence = Enrich.extractSentence(phrase, entry.prev_context, entry.next_context)
            cards[#cards + 1] = {
                phrase = phrase,
                sentence = sentence,
                ai_context = ai_context,
                display_context = display_context,
                source_language = source_language,
            }
        end
    end
    imported, skipped = DB.addCardsIfMissing(book_id, cards)

    local msg = string.format(
        _("Imported %d new cards. Skipped %d duplicates."),
        imported, skipped
    )
    UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
    logger.info("vocabdeck: vocabbuilder import", imported, skipped)
end

-- Ask the user how to scope the import (current book only vs. all entries)
-- and then run it.
function Importer.showImportDialog(plugin)
    local book_title = plugin:getDocumentTitle()
    local filepath = plugin:getDocumentFilePath()
    if not filepath then
        UIManager:show(InfoMessage:new{
            text = _("Open a book before importing from Vocabulary Builder."),
            timeout = 3,
        })
        return
    end
    local source_language = plugin:getDocumentSourceLanguage()
    DB.setLanguage(source_language)
    local book_id = DB.getOrCreateBook(book_title, filepath, source_language)
    if not book_id then
        UIManager:show(InfoMessage:new{
            text = _("Could not prepare book record."),
            timeout = 3,
        })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = string.format(
            _("Import all Vocabulary Builder entries recorded for \"%s\" into this book's VocabDeck?"),
            book_title or _("this book")
        ),
        ok_text = _("Import"),
        ok_callback = function()
            Importer.importForBook(plugin, book_id, book_title, source_language)
        end,
    })
end

return Importer
