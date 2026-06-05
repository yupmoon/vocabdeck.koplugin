-- VocabDeck capture helpers.
--
-- Normalizes selected text, dictionary definitions, and document context.
local koutil = require("util")
local Device = require("device")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Enrich = require("vocabdeck_enrich")
local Languages = require("vocabdeck_languages")
local TextUtils = require("vocabdeck_text_utils")

local Capture = {}
local Screen = Device.screen

local NO_DEFINITION_PATTERNS = {
    "^no%s+definition",
    "^no%s+definitions",
    "^no%s+result",
    "^no%s+results",
    "^not%s+found",
    "^nothing%s+found",
    "^definition%s+not%s+found",
    "^dictionary%s+lookup%s+failed",
}

local SOURCE_LANGUAGE_KEYS = {
    "dict",
    "dictionary",
    "dict_name",
    "dictionary_name",
    "dict_title",
    "dict_path",
    "filename",
    "path",
    "name",
    "title",
    "from",
    "from_lang",
    "from_language",
    "source",
    "source_lang",
    "source_language",
    "language",
    "lang",
}

local function isNoDefinitionText(text)
    local cleaned = Capture.cleanText(text):lower()
    cleaned = cleaned:gsub("%p+$", "")
    if cleaned == "" then return true end
    for _, pattern in ipairs(NO_DEFINITION_PATTERNS) do
        if cleaned:match(pattern) then
            return true
        end
    end
    return false
end

function Capture.cleanText(text)
    if type(text) ~= "string" then return "" end
    -- KOReader dictionary definitions often arrive as small adjacent HTML
    -- spans. If tags are stripped directly, "to </span><span>stop" can become
    -- "tostop", so preserve a plain-text separator before conversion.
    if text:find("<", 1, true) and text:find(">", 1, true) then
        text = text:gsub("<%s*[Bb][Rr]%s*/?%s*>", "\n")
        text = text:gsub(">%s*<", "> <")
    end
    text = koutil.htmlToPlainTextIfHtml(text)
    text = text:gsub("\n?_*\n?%(query%s*:%s*.-%)%s*$", "")
    text = text:gsub("\n?_+%s*$", "")
    text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
    text = text:gsub("[ \t]+", " ")
    text = text:gsub("\n%s*\n+", "\n")
    return TextUtils.trim(text)
end

function Capture.cleanMeaning(text)
    text = Capture.cleanText(text)
    text = text:gsub("^#+%s*", "")
    text = text:gsub("^%*+%s*", "")
    text = text:gsub("^[-•]%s*", "")
    text = text:gsub("^[Mm]eaning%s*:%s*", "")
    text = text:gsub("^[Dd]efinition%s*:%s*", "")
    text = text:gsub("^[Aa]nswer%s*:%s*", "")
    text = text:gsub("%*%*(.-)%*%*", "%1")
    text = text:gsub("`(.-)`", "%1")
    return TextUtils.trim(text)
end

function Capture.splitDictionaryDefinition(definition)
    definition = Capture.cleanText(definition)
    if definition == "" or isNoDefinitionText(definition) then
        return "", ""
    end
    local first_line, rest = definition:match("^([^\n]+)\n(.+)$")
    if not first_line or not rest then
        return "", definition
    end
    if isNoDefinitionText(rest) then
        return "", ""
    end
    local label = TextUtils.trim(first_line):lower()
    label = label:gsub("%s*[,;:].*$", "")
    if Languages.GRAMMAR_LABELS[label] then
        return TextUtils.trim(first_line), Capture.cleanMeaning(rest)
    end
    return "", definition
end

function Capture.firstText(...)
    for i = 1, select("#", ...) do
        local value = select(i, ...)
        if type(value) == "string" and value ~= "" then
            return value
        end
    end
    return ""
end

function Capture.isPhrase(text)
    return type(text) == "string" and text:find("%s") ~= nil
end

function Capture.getDictionaryDefinition(dict_popup)
    if not dict_popup then return "" end
    local definition = dict_popup.definition
    if (not definition or definition == "") and dict_popup.results and dict_popup.dict_index then
        local result = dict_popup.results[dict_popup.dict_index]
        definition = result and result.definition
    end
    definition = Capture.cleanText(definition)
    return isNoDefinitionText(definition) and "" or definition
end

function Capture.getDictionaryPhrase(dict_popup)
    if not dict_popup then return "" end
    local selected = dict_popup.highlight and dict_popup.highlight.selected_text
    if type(selected) == "table" and selected.text then
        local text = Capture.cleanText(selected.text)
        if text ~= "" then return text end
    elseif type(selected) == "string" then
        local text = Capture.cleanText(selected)
        if text ~= "" then return text end
    end

    local headword = Capture.cleanText(dict_popup.word or "")
    if headword ~= "" then return headword end

    local lookupword = Capture.cleanText(dict_popup.lookupword or "")
    if lookupword ~= "" then return lookupword end
    return ""
end

function Capture.getDictionarySourceLanguage(dict_popup)
    if not dict_popup then return "" end
    local candidates = {}
    local visited = {}

    local function addCandidate(value)
        if type(value) == "string" and value ~= "" then
            candidates[#candidates + 1] = value
        end
    end

    local function scanTable(tbl, depth)
        if type(tbl) ~= "table" or depth > 3 or visited[tbl] then return end
        visited[tbl] = true

        for _, key in ipairs(SOURCE_LANGUAGE_KEYS) do
            addCandidate(tbl[key])
        end

        for key, value in pairs(tbl) do
            local key_text = type(key) == "string" and key:lower() or ""
            local sourceish = key_text:find("dict", 1, true)
                or key_text:find("lang", 1, true)
                or key_text:find("source", 1, true)
                or key_text == "name"
                or key_text == "title"
                or key_text == "path"
                or key_text == "filename"
            if sourceish then
                addCandidate(value)
                if type(value) == "table" then
                    scanTable(value, depth + 1)
                end
            elseif type(value) == "table" and (key == "results" or key == "dicts") then
                scanTable(value, depth + 1)
            end
        end
    end

    scanTable(dict_popup, 0)
    if dict_popup.results and dict_popup.dict_index then
        scanTable(dict_popup.results[dict_popup.dict_index], 0)
    end

    for _, value in ipairs(candidates) do
        local language = Languages.detectFromText(value)
        if language ~= "" then
            return language
        end
    end
    return ""
end

function Capture.dictionaryContext(plugin, dict_popup, phrase)
    if not dict_popup then return "", "", "" end

    -- Path A: Highlight path (user selected text then looked it up)
    if dict_popup.highlight and dict_popup.highlight.selected_text then
        return Enrich.captureContexts(plugin, plugin.ui, dict_popup.highlight.selected_text)
    end

    local settings = plugin.settings
    local ai_words = tonumber(settings:readSetting("ai_context_words", 15)) or 15
    local display_words = tonumber(settings:readSetting("display_context_words", 15)) or 15
    local max_words = math.max(ai_words, display_words, 10)
    local ui = plugin.ui
    local prev_ctx, next_ctx

    -- Strategy 1: Primary — getSelectedWordContext with word_boxes (most accurate)
    if ui and ui.document and ui.document.info and ui.document.info.has_pages
        and ui.document.getSelectedWordContext
        and dict_popup.word_boxes and dict_popup.word_boxes[1] then
        local ok, prev, next_ = pcall(
            ui.document.getSelectedWordContext,
            ui.document,
            phrase,
            max_words,
            dict_popup.word_boxes[1]
        )
        if ok then
            prev_ctx = prev
            next_ctx = next_
        end
    end

    -- Strategy 2: Fallback — try getSelectedWordContext without word_boxes
    -- Some document implementations can find the word by text search alone.
    if not prev_ctx and not next_ctx
        and ui and ui.document and ui.document.getSelectedWordContext then
        local ok, prev, next_ = pcall(
            ui.document.getSelectedWordContext,
            ui.document,
            phrase,
            max_words,
            nil  -- no word_boxes
        )
        if ok then
            prev_ctx = prev
            next_ctx = next_
        end
    end

    -- Strategy 3: Last resort — extract from current page text
    -- Less precise but guarantees context when other methods fail.
    -- Document:getPageText() requires a page number.
    if not prev_ctx and not next_ctx
        and ui and ui.document and ui.document.getPageText then
        local pageno = ui:getCurrentPage()
        if pageno then
            local ok, page_text = pcall(ui.document.getPageText, ui.document, pageno)
            if ok and page_text and page_text ~= "" then
                local phrase_pos = page_text:find(phrase, 1, true)
                -- Case-insensitive fallback: the dictionary headword may
                -- differ from the page text in casing or accents.
                if not phrase_pos then
                    phrase_pos = page_text:lower():find(phrase:lower(), 1, true)
                end
                -- For multi-word phrases, try matching just the first word
                -- when the full phrase can't be found (e.g. spans a line break).
                if not phrase_pos and phrase:find(" ") then
                    local first_word = phrase:match("^(%S+)")
                    phrase_pos = page_text:lower():find(first_word:lower(), 1, true)
                end
                if phrase_pos then
                    local before = page_text:sub(1, phrase_pos - 1)
                    local after = page_text:sub(phrase_pos + #phrase)
                    prev_ctx = Enrich.trimToWords(before, max_words, true)
                    next_ctx = Enrich.trimToWords(after, max_words, false)
                end
            end
        end
    end

    local ai_context, display_context =
        Enrich.buildContextWindows(phrase, prev_ctx, next_ctx, ai_words, display_words)
    local sentence = Enrich.extractSentence(phrase, prev_ctx, next_ctx)
    return ai_context, display_context, sentence
end

-- Anchors an InfoMessage (or any MovableContainer) to the bottom-left corner
-- of the screen, so it doesn't obscure the top of the screen during AI fetches.
function Capture.anchorInfoMessageBottomLeft(widget)
    if not widget or not widget.movable then
        return widget
    end
    widget.movable.anchor = function()
        return Geom:new{
            x = Size.margin.default,
            y = Screen:getHeight() - Size.margin.default,
            w = 1,
            h = 1,
        }
    end
    widget.movable._anchor_ensured = nil
    return widget
end

return Capture
