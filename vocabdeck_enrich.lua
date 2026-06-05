-- VocabDeck AI enrichment.
--
-- Handles the prompt construction and response parsing used to populate the
-- pronunciation / word_type / meaning / synonym fields of a card. Exposes
-- three entry points:
--   * buildContextAroundSelection   – helper to split "prev + phrase + next"
--                                     context into AI + display windows.
--   * enrichCard                    – single synchronous enrichment.
--   * bulkEnrich                    – cancellable enrichment of many cards.
local _ = require("gettext")
local json = require("json")
local UIManager = require("ui/uimanager")
local Querier = require("vocabdeck_ai")
local InfoMessage = require("ui/widget/infomessage")
local logger = require("logger")
local TextUtils = require("vocabdeck_text_utils")

local DB = require("vocabdeck_db")

local Enrich = {}
local CODE_CANCELLED = "USER_CANCELED"

local function waitInCoroutine(seconds)
    local co = coroutine.running()
    if not co then return true end
    UIManager:scheduleIn(seconds or 0.05, function()
        coroutine.resume(co, true)
    end)
    return coroutine.yield()
end

-- ── Context helpers ───────────────────────────────────────────────────────

-- Cut a trailing/leading chunk of `text` containing at most `nb_words` words.
-- `from_end=true` keeps the tail (used for prev context), otherwise the head
-- (used for next context). Whitespace runs count as word boundaries.
local function trimToWords(text, nb_words, from_end)
    if not text or text == "" or nb_words <= 0 then
        return ""
    end
    local words = {}
    for w in text:gmatch("%S+") do
        words[#words + 1] = w
    end
    if #words <= nb_words then
        return text
    end
    local start_idx, end_idx
    if from_end then
        start_idx = #words - nb_words + 1
        end_idx = #words
    else
        start_idx = 1
        end_idx = nb_words
    end
    local result = {}
    for i = start_idx, end_idx do
        result[#result + 1] = words[i]
    end
    return table.concat(result, " ")
end
Enrich.trimToWords = trimToWords

-- prev_ctx / next_ctx come from document:getSelectedWordContext which already
-- returns requested word counts. We combine them into single strings.
function Enrich.buildContextWindows(phrase, prev_ctx, next_ctx, ai_words, display_words)
    phrase = phrase or ""
    prev_ctx = prev_ctx or ""
    next_ctx = next_ctx or ""
    if prev_ctx == "" and next_ctx == "" then
        return "", ""
    end

    local function compose(prev, next_)
        local left = prev or ""
        local right = next_ or ""
        local middle = phrase
        if left ~= "" and not left:match("%s$") then left = left .. " " end
        if right ~= "" and not right:match("^%s") then right = " " .. right end
        return TextUtils.trim(left .. middle .. right)
    end

    local ai_prev = trimToWords(prev_ctx, ai_words or 0, true)
    local ai_next = trimToWords(next_ctx, ai_words or 0, false)
    local disp_prev = trimToWords(prev_ctx, display_words or 0, true)
    local disp_next = trimToWords(next_ctx, display_words or 0, false)

    return compose(ai_prev, ai_next), compose(disp_prev, disp_next)
end

-- Extract the sentence containing the phrase from a prev/next context.
local SENTENCE_DELIMITERS = "[%.%?!;]"
function Enrich.extractSentence(phrase, prev_ctx, next_ctx)
    if not phrase or phrase == "" then return phrase or "" end
    if (not prev_ctx or prev_ctx == "") and (not next_ctx or next_ctx == "") then
        return ""
    end
    local full = (prev_ctx or "") .. phrase .. (next_ctx or "")
    if full == "" then return phrase end
    local phrase_start = #(prev_ctx or "") + 1
    local phrase_end = phrase_start + #phrase - 1

    local sent_start = 1
    for i = phrase_start - 1, 1, -1 do
        if full:sub(i, i):match(SENTENCE_DELIMITERS) then
            sent_start = i + 1
            break
        end
    end
    local sent_end = #full
    for i = phrase_end + 1, #full do
        if full:sub(i, i):match(SENTENCE_DELIMITERS) then
            sent_end = i
            break
        end
    end
    local sentence = full:sub(sent_start, sent_end)
    sentence = TextUtils.trim(sentence)
    if sentence == "" or sentence == phrase then return "" end
    return sentence
end

-- ── Prompt construction & JSON parsing ────────────────────────────────────

-- Strip Romance-language definite articles from the start of a phrase.
-- This is done in code so the AI never sees the article and can't be
-- inconsistent about dropping it.  Handles Spanish, French, Italian,
-- Portuguese, and Catalan.
local function stripLeadingArticles(phrase)
    if not phrase or phrase == "" then return "" end
    -- Case-insensitive patterns: el, la, los, las, le, la, les, l', il, lo,
    -- i, gli, o, a, os, as.  Only match when followed by a space.
    local stripped = phrase:gsub("^[Ee][Ll]%s+", "")
    stripped = stripped:gsub("^[Ll][Aa]%s+", "")
    stripped = stripped:gsub("^[Ll][Oo][Ss]%s+", "")
    stripped = stripped:gsub("^[Ll][Aa][Ss]%s+", "")
    stripped = stripped:gsub("^[Ll][Ee]%s+", "")
    stripped = stripped:gsub("^[Ll][Ee][Ss]%s+", "")
    stripped = stripped:gsub("^[Ll]'%s*", "")
    stripped = stripped:gsub("^[Ii][Ll]%s+", "")
    stripped = stripped:gsub("^[Ll][Oo]%s+", "")
    stripped = stripped:gsub("^[Ii]%s+", "")
    stripped = stripped:gsub("^[Gg][Ll][Ii]%s+", "")
    stripped = stripped:gsub("^[Oo]%s+", "")
    stripped = stripped:gsub("^[Aa]%s+", "")
    stripped = stripped:gsub("^[Oo][Ss]%s+", "")
    stripped = stripped:gsub("^[Aa][Ss]%s+", "")
    return stripped
end
Enrich.stripLeadingArticles = stripLeadingArticles

local function buildMessages(phrase, ai_context, target_language, source_language)
    target_language = target_language or "English"

    local system_prompt = string.format(
        "You are a multilingual language tutor. You MUST reply with a single valid JSON object and nothing else " ..
        "(no prose, no code fences). The JSON object must contain exactly these keys: headword, pronunciation, word_type, meaning, synonym, source_language.\n" ..
        "  source_language: FIRST, determine the source language from the context. " ..
        "Look at the surrounding words in the context to identify the language. " ..
        "If Known source language is given, use it. Otherwise read the context carefully — " ..
        "do NOT assume English. Return as an English name, e.g. Spanish, Japanese.\n" ..
        "  pronunciation : IPA phonetic transcription of the headword (the value of the headword key). " ..
        "If the headword is a fixed multi-word phrase (e.g. \"por supuesto\", \"a priori\"), return empty string. " ..
        "If the headword is a single word (e.g. \"ponerse\", \"llamarse\"), provide its IPA.\n" ..
        "  headword      : the core lexical entry — as it appears in a dictionary " ..
        "WITHOUT any article. Spanish/French/Italian/Portuguese/Catalan noun entries " ..
        "do NOT include definite articles (el, la, los, las, le, les, il, lo, i, gli, " ..
        "o, a, os, as, l'). ALWAYS strip these from the headword. " ..
        "e.g. \"el coche\" -> \"coche\", \"las casas\" -> \"casas\", " ..
        "\"el alumbrado de carretera\" -> \"alumbrado de carretera\", " ..
        "\"la maison\" -> \"maison\", \"les fleurs\" -> \"fleurs\".\n" ..
        "In Spanish, expand the contraction \"del\" (de + el) to \"de\" " ..
        "in the headword. e.g. \"a peticion del\" -> \"a petición de\".\n" ..
        "For single words, ALWAYS lemmatize to the dictionary (lemma) form, e.g. Spanish \"tierna\" -> \"tierno\", \"tenía\" -> \"tener\", " ..
        "\"haciendo\" -> \"hacer\", \"se pone\" -> \"ponerse\", \"me llamo\" -> \"llamarse\", " ..
        "\"se aprecie\" -> \"apreciarse\", \"te vas\" -> \"irse\", \"se siente\" -> \"sentirse\". " ..
        "For multi-word phrases, return the canonical form WITHOUT any article. " ..
        "For pronominal or possessive components in idioms, normalize to a generic " ..
        "placeholder, e.g. Spanish \"haciendo de las suyas\" -> \"hacer de algo\". " ..
        "For fixed phrases that are already in their canonical form, keep them as-is.\n" ..
        "  headword MUST be lowercase (e.g. \"estado anímico\", \"coche\", \"ponerse\"). " ..
        "Do NOT copy the input's capitalization. Only use capital letters for words that are " ..
        "ALWAYS capitalized in dictionary entries: proper nouns (España, iPhone, macOS), " ..
        "language names (English, Spanish), and acronyms (NASA, PDF). " ..
        "A sentence-start capital letter in the input does NOT make a word a proper noun.\n" ..
        "  word_type     : part of speech or a short grammatical label, e.g. noun, verb, adjective, phrase. Note: adverbial phrase, noun phrase, verb phrase, adjective phrase, idiom, and similar multi-word constructs should all be labeled simply as \"phrase\".\n" ..
        "  meaning       : one short, plain definition written in %s, ideally under 25 words.\n" ..
        "  synonym       : one to three useful synonyms or near-synonyms in the source language of the word or phrase, comma-separated; empty string if none are useful.\n" ..
        "  source_language: use the language determined above from the context.\n" ..
        "Use the provided context to determine the correct meaning and source_language. " ..
        "Pay attention to how the word is used in context to select the most accurate sense. " ..
        "Do not add labels, markdown, or commentary.",
        target_language
    )

    local context_text = (ai_context and ai_context ~= "" and ai_context ~= phrase)
        and ai_context or "(no context available)"
    local user_parts = {}
    if context_text ~= "(no context available)" then
        user_parts[#user_parts + 1] = "Context: " .. context_text
    end
    user_parts[#user_parts + 1] = "Word or phrase: \"" .. phrase .. "\""
    if source_language and source_language ~= "" then
        user_parts[#user_parts + 1] = "Known source language: " .. source_language
    else
        user_parts[#user_parts + 1] = "Important: detect the source language from the context above. Do not assume English."
    end
    user_parts[#user_parts + 1] = "Return JSON only."
    local user_prompt = table.concat(user_parts, "\n\n")

    return Querier.buildMessages(system_prompt, user_prompt)
end

local function isPhrase(text)
    return type(text) == "string" and text:find("%s") ~= nil
end

-- Strip common code fences before attempting JSON decode.
local function cleanupResponse(response)
    if type(response) ~= "string" then return "" end
    local cleaned = TextUtils.trim(response)
    cleaned = cleaned:gsub("^```%w*%s*", ""):gsub("```%s*$", "")
    -- extract first {...} block if surrounded by prose
    local brace_start = cleaned:find("{")
    local brace_end = cleaned:match(".*()}")
    if brace_start and brace_end and brace_end > brace_start then
        cleaned = cleaned:sub(brace_start, brace_end)
    end
    return cleaned
end

local function parseResponse(response)
    if not response or response == "" then
        return nil, "empty response"
    end
    local cleaned = cleanupResponse(response)
    local ok, parsed = pcall(json.decode, cleaned)
    if not ok or type(parsed) ~= "table" then
        return nil, "invalid JSON response"
    end

    local word_type = parsed.word_type
        or parsed.wordType
        or parsed.type
        or parsed.part_of_speech
        or parsed.partOfSpeech
        or parsed["word type"]
        or parsed["part of speech"]
    local synonym = parsed.synonym
        or parsed.synonyms
        or parsed.near_synonym
        or parsed.near_synonyms
        or parsed["near synonym"]
        or parsed["near synonyms"]
    if type(synonym) == "table" then
        synonym = table.concat(synonym, ", ")
    end
    local source_language = parsed.source_language
        or parsed.sourceLanguage
        or parsed.language
        or parsed.source_lang
        or parsed.sourceLang
    local headword = parsed.headword
        or parsed.lemma
        or parsed.canonical_form
        or parsed.canonicalForm
        or parsed.base_form
        or parsed.baseForm

    return {
        headword      = type(headword) == "string"              and headword             or "",
        pronunciation = type(parsed.pronunciation) == "string" and parsed.pronunciation or "",
        meaning       = type(parsed.meaning) == "string"       and parsed.meaning       or "",
        synonym       = type(synonym) == "string"              and synonym              or "",
        word_type     = type(word_type) == "string"            and word_type            or "",
        source_language = type(source_language) == "string" and source_language or "",
    }
end

-- ── Single card enrichment ────────────────────────────────────────────────

-- Perform the enrichment; returns the writable result table on success,
-- otherwise nil plus an error message. Uses the already-loaded querier.
function Enrich.enrichCard(plugin, card, trap_widget)
    if not card or not plugin or not plugin.querier then
        return nil, _("VocabDeck AI provider is not configured.")
    end
    local settings = plugin.settings
    local target_language = settings:readSetting("target_language", "English") or "English"

    -- Cap context to avoid accidentally sending entire chapters to the AI.
    local MAX_CONTEXT_SIZE = 10000
    local ai_context = card.ai_context or ""
    if #ai_context > MAX_CONTEXT_SIZE then
        ai_context = ai_context:sub(1, MAX_CONTEXT_SIZE)
    end

    local messages = buildMessages(card.phrase, ai_context, target_language, card.source_language)
    local response, err = plugin.querier:query(messages, trap_widget)
    if not response then
        return nil, err or _("No response from AI provider.")
    end

    local result, parse_err = parseResponse(response)
    if not result then
        return nil, parse_err or _("Could not parse AI response.")
    end
    if card.source_language and card.source_language ~= "" then
        -- Prefer the card's known language, but only when the AI agrees
        -- or could not determine one.  If the AI detected a different
        -- language from the surrounding context, trust the AI — the
        -- document metadata may be wrong (e.g. a Spanish text in a book
        -- tagged as English).
        if result.source_language == "" or result.source_language == card.source_language then
            result.source_language = card.source_language
        end
    end
    result.status = DB.STATUS_ENRICHED
    result.error = ""
    return result
end

-- Enrich the card in-place and persist the result to the database. Returns
-- `true` on success, otherwise `false` plus an error string.
function Enrich.enrichAndSave(plugin, card, trap_widget)
    local result, err = Enrich.enrichCard(plugin, card, trap_widget)
    if not result then
        local status = card.ai_status == DB.STATUS_ENRICHED
            and DB.STATUS_ENRICHED or DB.STATUS_ERROR
        DB.recordAIError(card.id, status, err or "")
        card.ai_status = status
        card.ai_error = err or ""
        return false, err
    end
    DB.applyEnrichment(card.id, result)
    -- reflect on the in-memory card too
    if result.headword and result.headword ~= "" then
        card.phrase = result.headword
    end
    card.pronunciation = result.pronunciation
    card.meaning = result.meaning
    card.synonym = result.synonym
    card.word_type = result.word_type
    card.source_language = result.source_language ~= "" and result.source_language or card.source_language
    card.ai_status = DB.STATUS_ENRICHED
    card.ai_error = ""
    return true
end

-- ── Cancellable bulk enrichment ───────────────────────────────────────────

-- Retry policy for transient provider errors (rate-limits, network blips,
-- timeouts). Most failures observed in practice succeed on the first or
-- second retry, so we keep the waits short to stay responsive.
-- Number of entries in BACKOFF_SECONDS == max retries after the initial try.
local BACKOFF_SECONDS = { 1.5, 3.0 }
local MAX_ATTEMPTS = #BACKOFF_SECONDS + 1

-- Persist a non-fatal in-flight error on the card without flipping the status
-- to STATUS_ERROR; this keeps the card eligible for an upcoming retry while
-- still logging what went wrong on the last attempt.
local function recordTransientError(card, err)
    if not card or not card.id then return end
    local status = card.ai_status == DB.STATUS_ENRICHED
        and DB.STATUS_ENRICHED or DB.STATUS_PENDING
    DB.recordAIError(card.id, status, err or "")
end

function Enrich.bulkEnrich(plugin, cards, on_finished)
    if not cards or #cards == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No cards require AI enrichment."),
            timeout = 3,
        })
        if on_finished then on_finished(0, 0) end
        return
    end

    local total = #cards
    local index = 0
    local succeeded = 0
    local failed = 0
    local cancelled = false
    local progress_widget

    -- `extra` is an optional suffix shown below the phrase (e.g. retry info).
    local function showProgress(idx, phrase, extra)
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
        local text = string.format(
            _("Fetching card %d of %d…\n\n\"%s\""),
            idx, total, phrase or ""
        )
        if extra and extra ~= "" then
            text = text .. "\n\n" .. extra
        end
        text = text .. "\n\n" .. _("Tap outside to cancel.")
        progress_widget = InfoMessage:new{
            text = text,
            timeout = nil,
        }
        progress_widget.dismiss_callback = function()
            if not cancelled then cancelled = true end
        end
        UIManager:show(progress_widget)
        -- Use targeted region refresh instead of full-screen forceRePaint().
        -- On e-ink devices a full flash per card makes bulk enrichment
        -- extremely slow and causes excessive ghosting.
        UIManager:setDirty(progress_widget, "ui")
    end

    local function closeProgress()
        if progress_widget then
            progress_widget.dismiss_callback = nil
            UIManager:close(progress_widget)
            progress_widget = nil
        end
    end

    local function finalize(msg)
        closeProgress()
        UIManager:show(InfoMessage:new{ text = msg, timeout = 4 })
        if on_finished then on_finished(succeeded, failed) end
    end

    local processNext -- forward declaration

    local function cancelledMessage()
        return string.format(
            _("Cancelled. %d succeeded, %d failed, %d skipped."),
            succeeded, failed, total - succeeded - failed
        )
    end

    -- Attempt enrichment of the current card; retry up to MAX_ATTEMPTS-1 times
    -- with a short backoff before giving up. Cancellation is honoured both
    -- during the network call and while waiting between retries.
    local function runAttempt(card, attempt)
        if cancelled then
            finalize(cancelledMessage())
            return
        end

        local attempt_note
        if attempt > 1 then
            attempt_note = string.format(
                _("Retrying (%d/%d)…"), attempt, MAX_ATTEMPTS
            )
        end
        showProgress(index, card.phrase or "", attempt_note)

        local ok, err = Enrich.enrichAndSave(plugin, card, progress_widget)
        if cancelled or err == CODE_CANCELLED then
            finalize(cancelledMessage())
            return
        end
        if ok then
            succeeded = succeeded + 1
            return processNext()
        end

        if attempt < MAX_ATTEMPTS then
            local wait = BACKOFF_SECONDS[attempt] or 2.0
            logger.info("vocabdeck: retry", attempt + 1, "of", MAX_ATTEMPTS,
                "for", card.phrase, "after", wait, "s; err=", err)
            -- Don't leave the card marked as STATUS_ERROR while we're
            -- still going to try again.
            recordTransientError(card, err)
            if card.ai_status ~= DB.STATUS_ENRICHED then
                card.ai_status = DB.STATUS_PENDING
            end
            card.ai_error = err or ""
            showProgress(index, card.phrase or "", string.format(
                _("Retry %d/%d in %.1fs…\n(%s)"),
                attempt + 1, MAX_ATTEMPTS, wait, err or _("unknown error")
            ))
            waitInCoroutine(wait)
            return runAttempt(card, attempt + 1)
        else
            failed = failed + 1
            logger.warn("vocabdeck: enrichment failed after",
                MAX_ATTEMPTS, "attempts for", card.phrase, err)
            return processNext()
        end
    end

    processNext = function()
        if cancelled then
            finalize(cancelledMessage())
            return
        end
        index = index + 1
        if index > total then
            finalize(string.format(
                _("Done. %d succeeded, %d failed."), succeeded, failed
            ))
            return
        end
        return runAttempt(cards[index], 1)
    end

    return processNext()
end

-- ── Sentence extraction helper when user selects text in the reader ──────

-- Returns: ai_context, display_context, sentence
function Enrich.captureContexts(plugin, ui, selected_text_obj)
    if not selected_text_obj or not selected_text_obj.text then
        return "", "", ""
    end
    local phrase = selected_text_obj.text
    local settings = plugin.settings
    local ai_words = tonumber(settings:readSetting("ai_context_words", 15)) or 15
    local display_words = tonumber(settings:readSetting("display_context_words", 15)) or 15
    local max_words = math.max(ai_words, display_words, 10)

    local prev_ctx, next_ctx
    if ui and ui.highlight and ui.highlight.getSelectedWordContext then
        local ok, prev, next_ = pcall(
            ui.highlight.getSelectedWordContext,
            ui.highlight,
            max_words
        )
        if ok then
            prev_ctx = prev
            next_ctx = next_
        end
    end

    if (not prev_ctx and not next_ctx)
        and ui and ui.document and not ui.document.info.has_pages
        and selected_text_obj.pos0 and selected_text_obj.pos1
        and ui.document.getSelectedWordContext then
        local ok, prev, next_ = pcall(
            ui.document.getSelectedWordContext,
            ui.document,
            phrase, max_words,
            selected_text_obj.pos0, selected_text_obj.pos1,
            true
        )
        if ok then
            prev_ctx = prev
            next_ctx = next_
        end
    end

    local ai_context, display_context =
        Enrich.buildContextWindows(phrase, prev_ctx, next_ctx, ai_words, display_words)
    local sentence = Enrich.extractSentence(phrase, prev_ctx, next_ctx)
    return ai_context, display_context, sentence
end

return Enrich
