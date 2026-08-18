-- VocabDeck SQLite database module.
--
-- Holds books and AI-enriched cards (pronunciation, meaning, type, synonyms)
-- plus FSRS scheduling state and review history.
local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local Scheduler = require("vocabdeck_scheduler")
local Queue = require("vocabdeck_queue")
local Languages = require("vocabdeck_languages")
local TextUtils = require("vocabdeck_text_utils")

local DB = {}

local DB_SCHEMA_VERSION = 15
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "vocabdeck")
local LEGACY_DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "vocabdeck.sqlite3")
local LEGACY_BACKUP_PATH = ffiUtil.joinPath(DB_DIRECTORY, "vocabdeck-backup.sqlite3")

-- Per-language DB paths: VocabDeck/<LanguageName>.sqlite3
DB.active_language = nil
local function dbPathForLanguage(language)
    if not language or language == "" then return LEGACY_DB_PATH end
    return ffiUtil.joinPath(DB_DIRECTORY, language .. ".sqlite3")
end
local function backupPathForLanguage(language)
    if not language or language == "" then return LEGACY_BACKUP_PATH end
    return ffiUtil.joinPath(DB_DIRECTORY, language .. "-backup.sqlite3")
end
local function currentDbPath()
    return dbPathForLanguage(DB.active_language)
end
local function currentBackupPath()
    return backupPathForLanguage(DB.active_language)
end

local SCHEMA_STATEMENTS = {
    [[CREATE TABLE IF NOT EXISTS books (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        filepath TEXT NOT NULL UNIQUE,
        source_language TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE TABLE IF NOT EXISTS cards (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        book_id INTEGER NOT NULL REFERENCES books(id) ON DELETE CASCADE,
        phrase TEXT NOT NULL,
        normalized_phrase TEXT NOT NULL DEFAULT '',
        sentence TEXT NOT NULL DEFAULT '',
        ai_context TEXT NOT NULL DEFAULT '',
        display_context TEXT NOT NULL DEFAULT '',
        pronunciation TEXT NOT NULL DEFAULT '',
        meaning TEXT NOT NULL DEFAULT '',
        synonym TEXT NOT NULL DEFAULT '',
        word_type TEXT NOT NULL DEFAULT '',
        source_language TEXT NOT NULL DEFAULT '',
        user_note TEXT NOT NULL DEFAULT '',
        ai_memory_helper TEXT NOT NULL DEFAULT '',
        ai_status INTEGER NOT NULL DEFAULT 0,
        ai_error TEXT NOT NULL DEFAULT '',
        due INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        fsrs_state INTEGER NOT NULL DEFAULT 1,
        fsrs_step INTEGER NOT NULL DEFAULT 0,
        fsrs_stability REAL NOT NULL DEFAULT 0,
        fsrs_difficulty REAL NOT NULL DEFAULT 0,
        last_review INTEGER,
        review_count INTEGER NOT NULL DEFAULT 0,
        lapse_count INTEGER NOT NULL DEFAULT 0,
        suspended INTEGER NOT NULL DEFAULT 0,
        leech INTEGER NOT NULL DEFAULT 0,
        leech_notified_at INTEGER,
        known INTEGER NOT NULL DEFAULT 0,
        flag INTEGER NOT NULL DEFAULT 0,
        study_more_day TEXT NOT NULL DEFAULT '',
        moved INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book ON cards(book_id)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_book_due ON cards(book_id, due)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_due ON cards(due)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_ai_status ON cards(ai_status)]],
    [[CREATE INDEX IF NOT EXISTS idx_cards_updated_at ON cards(updated_at)]],
    [[CREATE TABLE IF NOT EXISTS review_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
        reviewed_at INTEGER NOT NULL,
        rating TEXT NOT NULL,
        state_before INTEGER NOT NULL DEFAULT 1,
        state_after INTEGER NOT NULL DEFAULT 1,
        due_before INTEGER,
        due_after INTEGER,
        elapsed_days REAL,
        scheduled_days REAL,
        actual_days REAL,
        difficulty_before REAL,
        stability_before REAL,
        retrievability_before REAL,
        difficulty_after REAL,
        stability_after REAL
    )]],
    [[CREATE INDEX IF NOT EXISTS idx_review_history_card_time ON review_history(card_id, reviewed_at)]],
    [[CREATE INDEX IF NOT EXISTS idx_review_history_time ON review_history(reviewed_at)]],
    [[CREATE TABLE IF NOT EXISTS daily_overrides (
        day TEXT NOT NULL,
        source_language TEXT NOT NULL,
        extra_new INTEGER NOT NULL DEFAULT 0,
        extra_review INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        PRIMARY KEY(day, source_language)
    )]],
}

-- ai_status values:
-- 0 = pending enrichment, needs AI fetch
-- 1 = enriched successfully
-- 2 = AI fetch failed last time (retry allowed)
DB.STATUS_PENDING = 0
DB.STATUS_ENRICHED = 1
DB.STATUS_ERROR = 2

local initialized = false
local initialized_languages = {}  -- per-language init cache

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("vocabdeck sqlite schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

local function ensureReviewHistoryTable(conn)
    pcall(conn.exec, conn, [[CREATE TABLE IF NOT EXISTS review_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id INTEGER NOT NULL REFERENCES cards(id) ON DELETE CASCADE,
        reviewed_at INTEGER NOT NULL,
        rating TEXT NOT NULL,
        state_before INTEGER NOT NULL DEFAULT 1,
        state_after INTEGER NOT NULL DEFAULT 1,
        due_before INTEGER,
        due_after INTEGER,
        elapsed_days REAL,
        scheduled_days REAL,
        actual_days REAL,
        difficulty_before REAL,
        stability_before REAL,
        retrievability_before REAL,
        difficulty_after REAL,
        stability_after REAL
    );]])
    pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_review_history_card_time ON review_history(card_id, reviewed_at);")
end

local function normalizePhrase(phrase)
    phrase = tostring(phrase or "")
    -- Lua 5.1 %s does not match NBSP (U+00A0), so handle it explicitly
    -- before the general whitespace collapse below.
    phrase = phrase:gsub("\194\160", " ")
    phrase = phrase:gsub("%s+", " ")
    phrase = TextUtils.trim(phrase)
    return phrase:lower()
end

local WORD_TYPE_NAMES = {
    adj = "adjective",
    adjective = "adjective",
    adjectives = "adjective",
    adv = "adverb",
    adverb = "adverb",
    adverbs = "adverb",
    n = "noun",
    noun = "noun",
    nouns = "noun",
    v = "verb",
    verb = "verb",
    verbs = "verb",
    ["adverbial phrase"] = "phrase",
    ["adverbial phrases"] = "phrase",
    ["noun phrase"] = "phrase",
    ["noun phrases"] = "phrase",
    ["verb phrase"] = "phrase",
    ["verb phrases"] = "phrase",
    ["adjective phrase"] = "phrase",
    ["adjective phrases"] = "phrase",
    ["adjectival phrase"] = "phrase",
    ["adjectival phrases"] = "phrase",
    ["prepositional phrase"] = "phrase",
    ["prepositional phrases"] = "phrase",
    phrase = "phrase",
    phrases = "phrase",
    idiom = "phrase",
    idioms = "phrase",
    ["set phrase"] = "phrase",
    ["set phrases"] = "phrase",
    ["fixed expression"] = "phrase",
    ["fixed expressions"] = "phrase",
    prep = "preposition",
    preposition = "preposition",
    prepositions = "preposition",
}

local WORD_TYPE_ALIASES = {
    adjective = { "adjective", "adjectives", "adj" },
    adverb = { "adverb", "adverbs", "adv" },
    noun = { "noun", "nouns", "n" },
    verb = { "verb", "verbs", "v" },
    phrase = { "phrase", "phrases", "idiom", "idioms", "adverbial phrase", "adverbial phrases", "noun phrase", "noun phrases", "verb phrase", "verb phrases", "adjective phrase", "adjective phrases", "adjectival phrase", "adjectival phrases", "prepositional phrase", "prepositional phrases", "set phrase", "set phrases", "fixed expression", "fixed expressions" },
    preposition = { "preposition", "prepositions", "prep" },
}

local function normalizeWordType(word_type)
    word_type = TextUtils.trim(tostring(word_type or ""))
    if word_type == "" then return "" end
    local key = TextUtils.trim(word_type:lower())
    key = key:gsub("%s*[,;:].*$", "")
    return WORD_TYPE_NAMES[key] or key
end

local function wordTypeFilterSql(word_type)
    local normalized = normalizeWordType(word_type)
    if normalized == "" then return "" end
    local aliases = WORD_TYPE_ALIASES[normalized] or { normalized }
    local seen, quoted = {}, {}
    for _, alias in ipairs(aliases) do
        local value = tostring(alias or "")
        if value ~= "" and not seen[value:lower()] then
            seen[value:lower()] = true
            quoted[#quoted + 1] = "'" .. value:gsub("'", "''") .. "'"
        end
    end
    if #quoted == 0 then return "" end
    return "word_type COLLATE NOCASE IN (" .. table.concat(quoted, ", ") .. ")"
end

local function normalizeSourceLanguage(language)
    return Languages.normalize(language)
end

local function getSourceLanguageAliases(language)
    local normalized = normalizeSourceLanguage(language)
    local aliases = Languages.getAliases(normalized)
    local seen, quoted = {}, {}
    for _, alias in ipairs(aliases) do
        local value = tostring(alias or "")
        if value ~= "" and not seen[value:lower()] then
            seen[value:lower()] = true
            quoted[#quoted + 1] = "'" .. value:gsub("'", "''") .. "'"
        end
    end
    return quoted
end

local function sourceLanguageFilterSql(language)
    if not language or language == "" then return "" end
    local aliases = getSourceLanguageAliases(language)
    if #aliases == 0 then return "" end
    local language_list = table.concat(aliases, ", ")
    return string.format([[ AND source_language COLLATE NOCASE IN (%s) ]], language_list)
end

local ENRICHED_CARD_SQL = "ai_status = 1 AND meaning <> ''"

local function normalizeStoredSourceLanguages(conn)
    local updates = {}
    local function collect(table_name)
        local stmt = conn:prepare("SELECT DISTINCT source_language FROM " .. table_name .. " WHERE source_language <> '';")
        local rows = stmt:resultset("hik")
        stmt:close()
        if rows and rows[1] then
            for i = 1, #rows[1] do
                local current = rows[1][i] or ""
                local normalized = normalizeSourceLanguage(current)
                if normalized ~= "" and normalized ~= current then
                    updates[#updates + 1] = { table_name, current, normalized }
                end
            end
        end
    end

    collect("cards")
    collect("books")
    for _, update in ipairs(updates) do
        local stmt = conn:prepare("UPDATE " .. update[1] .. " SET source_language = ? WHERE source_language = ?;")
        stmt:bind(update[3], update[2])
        stmt:step()
        stmt:close()
    end
end

local function backfillNormalizedPhrases(conn)
    local stmt = conn:prepare("SELECT id, phrase FROM cards WHERE normalized_phrase = '' OR normalized_phrase IS NULL;")
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] then return end
    local update = conn:prepare("UPDATE cards SET normalized_phrase = ? WHERE id = ?;")
    for i = 1, #rows[1] do
        update:clearbind():reset()
        update:bind(normalizePhrase(rows[2][i] or ""), tonumber(rows[1][i]) or 0)
        update:step()
    end
    update:close()
end

local function hasNormalizedPhraseColumn(conn)
    local ok, stmt = pcall(conn.prepare, conn, "SELECT normalized_phrase FROM cards LIMIT 0;")
    if ok and stmt then
        stmt:close()
        return true
    end
    return false
end

local function ensureDirectory()
    local ok, err = util.makePath(DB_DIRECTORY)
    if not ok then
        logger.warn("vocabdeck: unable to create database directory", err)
    end
end

local function openConnection()
    ensureDirectory()
    local path = currentDbPath()
    local conn = SQ3.open(path)
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

local function withConnection(fn)
    local conn = openConnection()
    local results = { pcall(fn, conn) }
    conn:close()
    if not results[1] then
        error(results[2])
    end
    return table.unpack(results, 2)
end

local function escapeLike(value)
    return tostring(value or "")
        :gsub("\\", "\\\\")
        :gsub("%%", "\\%%")
        :gsub("_", "\\_")
        :gsub("'", "''")
end

function DB.init()
    if initialized then
        return
    end
    ensureDirectory()
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    execStatements(conn, SCHEMA_STATEMENTS)
    ensureReviewHistoryTable(conn)
    if current_version < 2 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN synonym TEXT NOT NULL DEFAULT '';")
    end
    if current_version < 3 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN source_language TEXT NOT NULL DEFAULT '';")
    end
    if current_version < 4 then
        pcall(conn.exec, conn, "ALTER TABLE books ADD COLUMN source_language TEXT NOT NULL DEFAULT '';")
    end
    if current_version < 6 then
        pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_source_due ON cards(source_language, due);")
        pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_source_book_due ON cards(source_language, book_id, due);")
    end
    if current_version < 7 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN suspended INTEGER NOT NULL DEFAULT 0;")
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN flag INTEGER NOT NULL DEFAULT 0;")
    end
    if current_version < 8 then
        ensureReviewHistoryTable(conn)
    end
    if current_version < 9 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN normalized_phrase TEXT NOT NULL DEFAULT '';")
        pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_norm_phrase ON cards(normalized_phrase);")
        pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_source_norm_phrase ON cards(source_language, normalized_phrase);")
    end
    if current_version < 10 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN study_more_day TEXT NOT NULL DEFAULT '';")
    end
    if current_version < 11 then
        -- Migration 11: ensure daily_overrides has source_language column.
        -- The table may have been created without it (e.g. by a previous
        -- multi-language removal deployment). Since ALTER TABLE cannot add
        -- a PRIMARY KEY column or change an existing PRIMARY KEY, we must
        -- recreate the table.
        pcall(conn.exec, conn, [[
            CREATE TABLE IF NOT EXISTS daily_overrides_v11 (
                day TEXT NOT NULL,
                source_language TEXT NOT NULL DEFAULT '',
                extra_new INTEGER NOT NULL DEFAULT 0,
                extra_review INTEGER NOT NULL DEFAULT 0,
                updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
                PRIMARY KEY(day, source_language)
            );
        ]])
        -- Check if the old table lacks source_language by attempting to
        -- query it. If the column is missing, SQLite raises an error.
        local has_source_language = pcall(function()
            conn:rowexec("SELECT source_language FROM daily_overrides LIMIT 1;")
        end)
        if not has_source_language then
            -- Old table is missing source_language. Copy data with empty
            -- source_language, drop old table, rename new one.
            pcall(conn.exec, conn, [[
                INSERT INTO daily_overrides_v11 (day, extra_new, extra_review, updated_at)
                SELECT day, extra_new, extra_review, updated_at FROM daily_overrides;
            ]])
            pcall(conn.exec, conn, "DROP TABLE IF EXISTS daily_overrides;")
            pcall(conn.exec, conn, "ALTER TABLE daily_overrides_v11 RENAME TO daily_overrides;")
        else
            -- Table already has source_language; drop the temp table.
            pcall(conn.exec, conn, "DROP TABLE IF EXISTS daily_overrides_v11;")
        end
    end
    if current_version < 12 then
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN ai_memory_helper TEXT NOT NULL DEFAULT '';")
    end
    -- Keep these idempotent guards outside the version gate. A device may have
    -- recorded the schema version after an interrupted migration; pcall makes
    -- the duplicate-column case harmless.
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN suspended INTEGER NOT NULL DEFAULT 0;")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN leech INTEGER NOT NULL DEFAULT 0;")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN leech_notified_at INTEGER;")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN normalized_phrase TEXT NOT NULL DEFAULT '';")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN known INTEGER NOT NULL DEFAULT 0;")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN flag INTEGER NOT NULL DEFAULT 0;")
    pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN study_more_day TEXT NOT NULL DEFAULT '';")
    pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_known_due ON cards(known, due);")
    pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_updated_at ON cards(updated_at);")
    pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_review_history_time ON review_history(reviewed_at);")
    pcall(conn.exec, conn, [[CREATE TABLE IF NOT EXISTS daily_overrides (
        day TEXT NOT NULL,
        source_language TEXT NOT NULL,
        extra_new INTEGER NOT NULL DEFAULT 0,
        extra_review INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')),
        PRIMARY KEY(day, source_language)
    );]])
    local normalize_ok, normalize_err = pcall(normalizeStoredSourceLanguages, conn)
    if not normalize_ok then
        logger.warn("vocabdeck: normalizeStoredSourceLanguages failed:", normalize_err)
    end
    if hasNormalizedPhraseColumn(conn) then
        pcall(conn.exec, conn, "CREATE INDEX IF NOT EXISTS idx_cards_norm_phrase ON cards(normalized_phrase);")
        local backfill_ok, backfill_err = pcall(backfillNormalizedPhrases, conn)
        if not backfill_ok then
            logger.warn("vocabdeck: backfillNormalizedPhrases failed:", backfill_err)
        end
    else
        logger.warn("vocabdeck: normalized_phrase migration did not complete; skipping normalized phrase indexes")
    end
    if current_version < 15 then
        -- Reserved for future card-move-between-decks tracking.
        -- Column exists in schema but is not yet wired to any UI or logic.
        pcall(conn.exec, conn, "ALTER TABLE cards ADD COLUMN moved INTEGER NOT NULL DEFAULT 0;")
    end
    if current_version ~= DB_SCHEMA_VERSION then
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    end
    conn:close()
    initialized = true
end

function DB.getPath()
    return currentDbPath()
end

function DB.getBackupPath()
    return currentBackupPath()
end

function DB.getSchemaVersion()
    DB.init()
    return withConnection(function(conn)
        return tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    end)
end

-- Switch the active language. Closes the old connection and re-inits
-- against the per-language database file. Pass nil or "" to use the
-- legacy single-file database (for migration).
function DB.setLanguage(language)
    if language and language ~= "" then
        language = Languages.normalize(language)
        if language == "" then language = nil end
    end
    if DB.active_language == language then return end
    DB.active_language = language
    local key = language or "__legacy__"
    if not initialized_languages[key] then
        initialized_languages[key] = true
        initialized = false
        DB.init()
    end
end

-- Return the current active language, or nil if using the legacy DB.
function DB.getActiveLanguage()
    return DB.active_language
end

local function languageDbHasCards(language)
    local path = dbPathForLanguage(language)
    if not lfs.attributes(path, "mode") then
        return false
    end
    local ok, count = pcall(function()
        local conn = SQ3.open(path)
        local has_cards_table = conn:rowexec("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'cards' LIMIT 1;")
        if not has_cards_table then
            conn:close()
            return 0
        end
        local total = tonumber(conn:rowexec("SELECT COUNT(*) FROM cards;")) or 0
        conn:close()
        return total
    end)
    return ok and tonumber(count) and tonumber(count) > 0
end

-- Scan the data directory for per-language .sqlite3 files and return
-- a sorted list of language names that actually contain cards. Excludes the
-- legacy file, backups, and empty DBs created by read-only lookups.
function DB.listLanguages()
    ensureDirectory()
    local languages = {}
    local lfs = require("libs/libkoreader-lfs")
    for file in lfs.dir(DB_DIRECTORY) do
        if file:match("%.sqlite3$") and not file:match("%-backup") and file ~= "vocabdeck.sqlite3" then
            local lang = file:gsub("%.sqlite3$", "")
            if lang ~= "" and languageDbHasCards(lang) then
                languages[#languages + 1] = lang
            end
        end
    end
    table.sort(languages)
    return languages
end

-- Check whether the legacy single-file database still exists and needs
-- to be split into per-language files.
function DB.needsMigration()
    local legacy = io.open(LEGACY_DB_PATH, "rb")
    if not legacy then return false end
    legacy:close()
    -- Already have per-language files?
    local langs = DB.listLanguages()
    return #langs == 0
end

-- Split the legacy single-file database into one file per source_language.
-- Returns true on success, false + error on failure.
function DB.runMigration()
    local legacy = io.open(LEGACY_DB_PATH, "rb")
    if not legacy then
        return false, "No legacy database found."
    end
    legacy:close()

    local legacy_conn = SQ3.open(LEGACY_DB_PATH)
    legacy_conn:exec("PRAGMA foreign_keys = ON;")

    -- Get distinct languages
    local lang_stmt = legacy_conn:prepare("SELECT DISTINCT source_language FROM cards WHERE source_language <> '';")
    local lang_rows = lang_stmt:resultset("hik")
    lang_stmt:close()

    local languages = {}
    if lang_rows and lang_rows[1] then
        for i = 1, #lang_rows[1] do
            languages[#languages + 1] = lang_rows[1][i]
        end
    end

    if #languages == 0 then
        legacy_conn:close()
        return false, "No cards with source_language found."
    end

    local migrated = {}
    for _, lang in ipairs(languages) do
        local target_path = dbPathForLanguage(lang)
        local target_conn = SQ3.open(target_path)
        target_conn:exec("PRAGMA foreign_keys = ON;")

        -- Create schema in target
        execStatements(target_conn, SCHEMA_STATEMENTS)
        ensureReviewHistoryTable(target_conn)

        -- Copy books for this language
        local book_stmt = legacy_conn:prepare("SELECT id, title, filepath, source_language, created_at FROM books WHERE source_language = ?;")
        book_stmt:bind(lang)
        local book_rows = book_stmt:resultset("hik")
        book_stmt:close()
        if book_rows and book_rows[1] then
            local insert_book = target_conn:prepare("INSERT INTO books (id, title, filepath, source_language, created_at) VALUES (?, ?, ?, ?, ?);")
            for i = 1, #book_rows[1] do
                insert_book:clearbind():reset()
                insert_book:bind(book_rows[1][i], book_rows[2][i], book_rows[3][i], book_rows[4][i], book_rows[5][i])
                insert_book:step()
            end
            insert_book:close()
        end

        -- Copy cards for this language
        local card_stmt = legacy_conn:prepare([[
            SELECT id, book_id, phrase, normalized_phrase, sentence, ai_context, display_context,
                   pronunciation, meaning, synonym, word_type, source_language, user_note,
                   ai_memory_helper, ai_status, ai_error, due, fsrs_state, fsrs_step,
                   fsrs_stability, fsrs_difficulty, last_review, review_count, lapse_count,
                   suspended, leech, leech_notified_at, known, flag, study_more_day,
                   created_at, updated_at
            FROM cards WHERE source_language = ?;]])
        card_stmt:bind(lang)
        local card_rows = card_stmt:resultset("hik")
        card_stmt:close()
        if card_rows and card_rows[1] then
            local insert_card = target_conn:prepare([[
                INSERT INTO cards (id, book_id, phrase, normalized_phrase, sentence, ai_context, display_context,
                    pronunciation, meaning, synonym, word_type, source_language, user_note,
                    ai_memory_helper, ai_status, ai_error, due, fsrs_state, fsrs_step,
                    fsrs_stability, fsrs_difficulty, last_review, review_count, lapse_count,
                    suspended, leech, leech_notified_at, known, flag, study_more_day,
                    created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
            for i = 1, #card_rows[1] do
                insert_card:clearbind():reset()
                for j = 1, 32 do
                    insert_card:bind(card_rows[j][i])
                end
                insert_card:step()
            end
            insert_card:close()
        end

        -- Copy review_history for this language's cards
        local rh_stmt = legacy_conn:prepare([[
            SELECT r.id, r.card_id, r.reviewed_at, r.rating, r.state_before, r.state_after,
                   r.due_before, r.due_after, r.elapsed_days, r.scheduled_days, r.actual_days,
                   r.difficulty_before, r.stability_before, r.retrievability_before,
                   r.difficulty_after, r.stability_after
            FROM review_history r
            JOIN cards c ON c.id = r.card_id
            WHERE c.source_language = ?;]])
        rh_stmt:bind(lang)
        local rh_rows = rh_stmt:resultset("hik")
        rh_stmt:close()
        if rh_rows and rh_rows[1] then
            local insert_rh = target_conn:prepare([[
                INSERT INTO review_history (id, card_id, reviewed_at, rating, state_before, state_after,
                    due_before, due_after, elapsed_days, scheduled_days, actual_days,
                    difficulty_before, stability_before, retrievability_before,
                    difficulty_after, stability_after)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
            for i = 1, #rh_rows[1] do
                insert_rh:clearbind():reset()
                for j = 1, 16 do
                    insert_rh:bind(rh_rows[j][i])
                end
                insert_rh:step()
            end
            insert_rh:close()
        end

        -- Copy daily_overrides for this language
        local do_stmt = legacy_conn:prepare("SELECT day, source_language, extra_new, extra_review, updated_at FROM daily_overrides WHERE source_language = ?;")
        do_stmt:bind(lang)
        local do_rows = do_stmt:resultset("hik")
        do_stmt:close()
        if do_rows and do_rows[1] then
            local insert_do = target_conn:prepare("INSERT INTO daily_overrides (day, source_language, extra_new, extra_review, updated_at) VALUES (?, ?, ?, ?, ?);")
            for i = 1, #do_rows[1] do
                insert_do:clearbind():reset()
                insert_do:bind(do_rows[1][i], do_rows[2][i], do_rows[3][i], do_rows[4][i], do_rows[5][i])
                insert_do:step()
            end
            insert_do:close()
        end

        -- Set schema version
        target_conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
        target_conn:close()
        migrated[#migrated + 1] = lang
    end

    legacy_conn:close()

    -- Rename legacy file to backup so it's not picked up again
    local backup_name = LEGACY_DB_PATH .. ".migrated"
    os.rename(LEGACY_DB_PATH, backup_name)

    return true, migrated
end

function DB.backupCards()
    DB.init()
    ensureDirectory()
    local src = currentDbPath()
    local dst = currentBackupPath()
    local conn = openConnection()
    pcall(conn.exec, conn, "PRAGMA wal_checkpoint(FULL);")
    conn:close()
    local err = ffiUtil.copyFile(src, dst)
    if err then
        return false, "Could not write backup."
    end
    return true, dst
end

function DB.restoreCardsBackup()
    local dst = currentBackupPath()
    local backup = io.open(dst, "rb")
    if not backup then
        return false, "No VocabDeck backup found."
    end
    backup:close()
    ensureDirectory()
    local src = currentDbPath()
    local bkp = currentBackupPath()
    os.remove(src .. "-wal")
    os.remove(src .. "-shm")
    local err = ffiUtil.copyFile(bkp, src)
    if err then
        return false, "Could not restore backup."
    end
    initialized = false
    DB.init()
    return true, bkp
end

local function coerceNumber(value, default)
    if value == nil then
        return default
    end
    local n = tonumber(value)
    if not n then
        return default
    end
    return n
end

local function nextReviewDayStart(now)
    return Scheduler.nextReviewDayStart(now)
end

local function getTodayStart()
    local today = os.date("*t", os.time())
    today.hour, today.min, today.sec = 0, 0, 0
    return os.time(today)
end

local function getTodayKey()
    return os.date("%Y-%m-%d", os.time())
end

local function dailyNewIntroducedCountForConn(conn, source_language)
    local source_filter = sourceLanguageFilterSql(source_language):gsub("^%s*AND%s+", "")
    if source_filter == "" then return 0 end
    local sql = string.format([[SELECT COUNT(*) FROM (
            SELECT h.card_id, MIN(h.reviewed_at) AS first_reviewed_at
            FROM review_history h
            JOIN cards c ON c.id = h.card_id
            WHERE %s
            GROUP BY h.card_id
        ) first_reviews
        WHERE first_reviewed_at >= %d;]],
        source_filter, getTodayStart())
    return tonumber(conn:rowexec(sql)) or 0
end

local function dailyReviewDoneCountForConn(conn, source_language)
    local source_filter = sourceLanguageFilterSql(source_language):gsub("^%s*AND%s+", "")
    if source_filter == "" then return 0 end
    local sql = string.format([[SELECT COUNT(*) FROM review_history h
        JOIN cards c ON c.id = h.card_id
        WHERE h.reviewed_at >= %d
            AND h.state_before = %d
            AND %s;]],
        getTodayStart(), Scheduler.STATE_REVIEW, source_filter)
    return tonumber(conn:rowexec(sql)) or 0
end

local function getDailyOverrideForConn(conn, source_language)
    source_language = normalizeSourceLanguage(source_language)
    if source_language == "" then
        return { extra_new = 0, extra_review = 0 }
    end
    local stmt = conn:prepare("SELECT extra_new, extra_review FROM daily_overrides WHERE day = ? AND source_language = ? LIMIT 1;")
    stmt:bind(getTodayKey(), source_language)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] or not rows[1][1] then
        return { extra_new = 0, extra_review = 0 }
    end
    return {
        extra_new = coerceNumber(rows[1][1], 0),
        extra_review = coerceNumber(rows[2] and rows[2][1], 0),
    }
end

function DB.getNextReviewDayStart(now)
    return nextReviewDayStart(now)
end

function DB.getDailyOverride(source_language)
    DB.init()
    return withConnection(function(conn)
        return getDailyOverrideForConn(conn, source_language)
    end)
end

function DB.addDailyOverride(source_language, field, amount, base_limit, from_current)
    source_language = normalizeSourceLanguage(source_language)
    amount = math.max(0, math.floor((tonumber(amount) or 0) + 0.5))
    if source_language == "" or amount <= 0 then return false end
    local column = field == "review" and "extra_review" or "extra_new"
    DB.init()
    return withConnection(function(conn)
        local day = getTodayKey()
        local now = os.time()
        local insert = conn:prepare([[INSERT OR IGNORE INTO daily_overrides
            (day, source_language, extra_new, extra_review, updated_at)
            VALUES (?, ?, 0, 0, ?);]])
        insert:bind(day, source_language, now)
        insert:step()
        insert:close()

        -- Start with the requested amount. Do NOT add to the existing value,
        -- otherwise every call to openStudyMore accumulates the extra amount
        -- (10 → 20 → 30 → …).
        local next_extra = amount
        if from_current then
            -- If the user has already exceeded their base limit today (e.g.
            -- studied 25 new cards with a base limit of 20), the catch-up
            -- ensures the override covers the overage plus the requested extra.
            local already_done = field == "review"
                and dailyReviewDoneCountForConn(conn, source_language)
                or dailyNewIntroducedCountForConn(conn, source_language)
            local base = tonumber(base_limit) or 0
            local catch_up_extra = base > 0 and math.max(0, already_done - base) or 0
            next_extra = math.max(next_extra, catch_up_extra + amount)
        end

        local stmt = conn:prepare(string.format(
            "UPDATE daily_overrides SET %s = ?, updated_at = ? WHERE day = ? AND source_language = ?;",
            column))
        stmt:bind(next_extra, now, day, source_language)
        stmt:step()
        stmt:close()
        return true
    end)
end

-- ── Book CRUD ──────────────────────────────────────────────────────────────

function DB.getOrCreateBook(title, filepath, source_language)
    if not filepath or filepath == "" then
        return nil
    end
    -- When using per-language decks the language is implied by the active DB;
    -- the source_language parameter is kept for backward compat but may be
    -- overridden by the active language.
    local effective_language = normalizeSourceLanguage(DB.active_language or source_language)
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT id FROM books WHERE filepath = ?;")
        stmt:bind(filepath)
        local rows = stmt:resultset("hik")
        stmt:close()
        local existing_id = rows and rows[1] and tonumber(rows[1][1]) or nil
        if existing_id then
            if effective_language ~= "" then
                local update = conn:prepare("UPDATE books SET source_language = ? WHERE id = ? AND source_language = '';")
                update:bind(effective_language, existing_id)
                update:step()
                update:close()
            end
            return existing_id
        end
        local insert = conn:prepare("INSERT INTO books (title, filepath, source_language) VALUES (?, ?, ?);")
        insert:bind(title or "", filepath, effective_language)
        insert:step()
        insert:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.getBookIdByFilepath(filepath)
    if not filepath or filepath == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT id FROM books WHERE filepath = ? LIMIT 1;")
        stmt:bind(filepath)
        local row = stmt:step()
        stmt:close()
        return row and tonumber(row[1]) or nil
    end)
end

function DB.findBookWithCardsByFilepath(filepath, preferred_language, restore_previous)
    if not filepath or filepath == "" then
        return nil
    end

    local previous_language = DB.active_language
    local available_list = DB.listLanguages()
    local available_languages = {}
    for _, language in ipairs(available_list) do
        available_languages[normalizeSourceLanguage(language)] = true
    end
    local languages = {}
    local seen = {}
    local function addLanguage(language, allow_missing)
        language = normalizeSourceLanguage(language)
        if language ~= "" and not allow_missing and not available_languages[language] then
            return
        end
        local key = language ~= "" and language or "__legacy__"
        if not seen[key] then
            seen[key] = true
            languages[#languages + 1] = { language = language ~= "" and language or nil }
        end
    end

    addLanguage(preferred_language)
    addLanguage(previous_language)
    for _, language in ipairs(available_list) do
        addLanguage(language, true)
    end
    addLanguage(nil, true)

    for _, entry in ipairs(languages) do
        DB.setLanguage(entry.language)
        local book_id = DB.getBookIdByFilepath(filepath)
        if book_id and (DB.getCardCountForBook(book_id) or 0) > 0 then
            local found_language = DB.active_language
            if restore_previous then
                DB.setLanguage(previous_language)
            end
            return book_id, found_language
        end
    end

    DB.setLanguage(previous_language)
    return nil
end

function DB.listBooks()
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[SELECT b.id, b.title, b.filepath, COUNT(c.id) AS card_count
            FROM books b
            JOIN cards c ON c.book_id = b.id
            GROUP BY b.id, b.title, b.filepath
            HAVING COUNT(c.id) > 0
            ORDER BY
                CASE WHEN b.filepath LIKE 'vocabdeck://manual/%' THEN 1 ELSE 0 END ASC,
                b.title COLLATE NOCASE ASC;]])
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[0] or #rows[0] == 0 then
            return {}
        end
        local headers = rows[0]
        local list = {}
        if not rows[1] then return list end
        for i = 1, #rows[1] do
            local row = {}
            for col_index, col_name in ipairs(headers) do
                local column_values = rows[col_index]
                row[col_name] = column_values[i]
            end
            list[#list + 1] = {
                id = coerceNumber(row.id, nil),
                title = tostring(row.title or ""),
                filepath = tostring(row.filepath or ""),
                card_count = coerceNumber(row.card_count, 0),
            }
        end
        return list
    end)
end

function DB.getBookTitle(book_id)
    if not book_id then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        return conn:rowexec(string.format("SELECT title FROM books WHERE id = %d;", book_id))
    end)
end

-- ── Card CRUD ──────────────────────────────────────────────────────────────

-- card_data: {phrase, sentence, ai_context, display_context, user_note,
-- pronunciation?, meaning?, synonym?, word_type?, source_language?, ai_status?}
function DB.addCard(book_id, card_data)
    if not book_id or not card_data or not card_data.phrase or card_data.phrase == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local source_language = normalizeSourceLanguage(card_data.source_language)
        local stmt = conn:prepare([[INSERT INTO cards
            (book_id, phrase, normalized_phrase, sentence, ai_context, display_context, pronunciation, meaning, synonym, word_type, source_language, user_note, ai_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
        stmt:bind(
            book_id,
            card_data.phrase,
            normalizePhrase(card_data.phrase),
            card_data.sentence or "",
            card_data.ai_context or "",
            card_data.display_context or "",
            card_data.pronunciation or "",
            card_data.meaning or "",
            card_data.synonym or "",
            card_data.word_type or "",
            source_language,
            card_data.user_note or "",
            card_data.ai_status or DB.STATUS_PENDING
        )
        stmt:step()
        stmt:close()
        local new_id = conn:rowexec("SELECT last_insert_rowid();")
        if source_language ~= "" then
            local book_stmt = conn:prepare("UPDATE books SET source_language = ? WHERE id = ? AND source_language = '';")
            book_stmt:bind(source_language, book_id)
            book_stmt:step()
            book_stmt:close()
        end
        DB.invalidateSummaryCache()
        return new_id and tonumber(new_id) or nil
    end)
end

function DB.addCardsIfMissing(book_id, cards)
    if not book_id or type(cards) ~= "table" or #cards == 0 then
        return 0, 0
    end
    DB.init()
    return withConnection(function(conn)
        local imported = 0
        local skipped = 0
        conn:exec("BEGIN;")
        local insert_stmt = conn:prepare([[INSERT INTO cards
            (book_id, phrase, normalized_phrase, sentence, ai_context, display_context, pronunciation, meaning, synonym, word_type, source_language, user_note, ai_status)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
        local existing_phrases = {}
        local existing_stmt = conn:prepare("SELECT normalized_phrase FROM cards WHERE book_id = ?;")
        existing_stmt:bind(book_id)
        local existing_rows = existing_stmt:resultset("hik")
        existing_stmt:close()
        if existing_rows and existing_rows[1] then
            for i = 1, #existing_rows[1] do
                existing_phrases[existing_rows[1][i] or ""] = true
            end
        end
        for _, card_data in ipairs(cards) do
            local phrase = card_data and card_data.phrase or ""
            if phrase ~= "" then
                local normalized = normalizePhrase(phrase)
                if existing_phrases[normalized] then
                    skipped = skipped + 1
                else
                    local source_language = normalizeSourceLanguage(card_data.source_language)
                    existing_phrases[normalized] = true
                    insert_stmt:clearbind():reset()
                    insert_stmt:bind(
                        book_id,
                        phrase,
                        normalized,
                        card_data.sentence or "",
                        card_data.ai_context or "",
                        card_data.display_context or "",
                        card_data.pronunciation or "",
                        card_data.meaning or "",
                        card_data.synonym or "",
                        card_data.word_type or "",
                        source_language,
                        card_data.user_note or "",
                        card_data.ai_status or DB.STATUS_PENDING
                    )
                    insert_stmt:step()
                    imported = imported + 1
                end
            end
        end
        insert_stmt:close()
        for _, card_data in ipairs(cards) do
            local source_language = card_data and normalizeSourceLanguage(card_data.source_language) or ""
            if source_language ~= "" then
                local book_stmt = conn:prepare("UPDATE books SET source_language = ? WHERE id = ? AND source_language = '';")
                book_stmt:bind(source_language, book_id)
                book_stmt:step()
                book_stmt:close()
                break
            end
        end
        conn:exec("COMMIT;")
        DB.invalidateSummaryCache()
        return imported, skipped
    end)
end

function DB.deleteCard(card_id)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("DELETE FROM cards WHERE id = ?;")
        stmt:bind(card_id); stmt:step(); stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

-- Delete every card that belongs to `book_id` together with the book row
-- itself. Returns the number of cards that were removed.
function DB.deleteBookAndCards(book_id)
    if not book_id then return 0 end
    DB.init()
    return withConnection(function(conn)
        local count_stmt = conn:prepare("SELECT COUNT(*) AS n FROM cards WHERE book_id = ?;")
        count_stmt:bind(book_id)
        local row = count_stmt:step()
        local deleted = row and coerceNumber(row[1], 0) or 0
        count_stmt:close()

        local del_cards = conn:prepare("DELETE FROM cards WHERE book_id = ?;")
        del_cards:bind(book_id); del_cards:step(); del_cards:close()

        local del_book = conn:prepare("DELETE FROM books WHERE id = ?;")
        del_book:bind(book_id); del_book:step(); del_book:close()
        DB.invalidateSummaryCache()
        return deleted
    end)
end

local function mapCardRow(row)
    if not row then return nil end
    return {
        id = coerceNumber(row.id, nil),
        book_id = coerceNumber(row.book_id, nil),
        phrase = row.phrase or "",
        sentence = row.sentence or "",
        ai_context = row.ai_context or "",
        display_context = row.display_context or "",
        pronunciation = row.pronunciation or "",
        meaning = row.meaning or "",
        synonym = row.synonym or "",
        word_type = row.word_type or "",
        source_language = normalizeSourceLanguage(row.source_language),
        user_note = row.user_note or "",
        ai_memory_helper = row.ai_memory_helper or "",
        ai_status = coerceNumber(row.ai_status, DB.STATUS_PENDING),
        ai_error = row.ai_error or "",
        due = coerceNumber(row.due, os.time()),
        fsrs_state = coerceNumber(row.fsrs_state, 1),
        fsrs_step = coerceNumber(row.fsrs_step, 0),
        fsrs_stability = coerceNumber(row.fsrs_stability, 0),
        fsrs_difficulty = coerceNumber(row.fsrs_difficulty, 0),
        last_review = coerceNumber(row.last_review, nil),
        review_count = coerceNumber(row.review_count, 0),
        lapse_count = coerceNumber(row.lapse_count, 0),
        suspended = coerceNumber(row.suspended, 0),
        leech = coerceNumber(row.leech, 0),
        leech_notified_at = coerceNumber(row.leech_notified_at, nil),
        known = coerceNumber(row.known, 0),
        flag = coerceNumber(row.flag, 0),
        study_more_day = row.study_more_day or "",
        created_at = coerceNumber(row.created_at, nil),
        updated_at = coerceNumber(row.updated_at, nil),
    }
end

local CARD_SELECT_COLUMNS = table.concat({
    "id", "book_id", "phrase", "sentence", "ai_context", "display_context",
    "pronunciation", "meaning", "synonym", "word_type", "source_language", "user_note",
    "ai_memory_helper",
    "ai_status", "ai_error", "due",
    "fsrs_state", "fsrs_step", "fsrs_stability", "fsrs_difficulty",
    "last_review", "review_count", "lapse_count", "suspended",
    "leech", "leech_notified_at", "known", "flag",
    "study_more_day",
    "created_at", "updated_at",
}, ", ")

local function fetchSingle(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] or #rows[1] == 0 then
        return nil
    end
    local headers = rows[0]
    local row = {}
    for header_index, header in ipairs(headers) do
        row[header] = rows[header_index][1]
    end
    return mapCardRow(row)
end

local function fetchList(conn, sql)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] then return {} end
    local headers = rows[0]
    local list = {}
    for i = 1, #rows[1] do
        local row = {}
        for header_index, header in ipairs(headers) do
            row[header] = rows[header_index][i]
        end
        list[#list + 1] = mapCardRow(row)
    end
    return list
end

function DB.getCard(card_id)
    if not card_id then return nil end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare(string.format(
            "SELECT %s FROM cards WHERE id = ?;", CARD_SELECT_COLUMNS))
        stmt:bind(tonumber(card_id) or 0)
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then return nil end
        local row = {}
        for header_index, header in ipairs(rows[0]) do
            row[header] = rows[header_index][1]
        end
        return mapCardRow(row)
    end)
end

local function buildCardWhere(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, filter_source_language, include_known, flagged_only, filter_ai_status, filter_card_state)
    local clauses = {}
    if not include_known then
        clauses[#clauses + 1] = "known = 0"
    end
    if book_id then
        clauses[#clauses + 1] = string.format("book_id = %d", tonumber(book_id) or 0)
    end
    if include_enriched_only then
        clauses[#clauses + 1] = ENRICHED_CARD_SQL
    end
    if reviewable_only then
        clauses[#clauses + 1] = string.format("due <= %d", tonumber(now) or os.time())
    end
    if filter_text and filter_text ~= "" then
        local pattern = "'%" .. escapeLike(filter_text) .. "%'"
        clauses[#clauses + 1] = string.format([[
            (phrase LIKE %s ESCAPE '\' COLLATE NOCASE
            OR meaning LIKE %s ESCAPE '\' COLLATE NOCASE
            OR synonym LIKE %s ESCAPE '\' COLLATE NOCASE
            OR user_note LIKE %s ESCAPE '\' COLLATE NOCASE
            OR word_type LIKE %s ESCAPE '\' COLLATE NOCASE
            OR pronunciation LIKE %s ESCAPE '\' COLLATE NOCASE
            OR sentence LIKE %s ESCAPE '\' COLLATE NOCASE)]],
            pattern, pattern, pattern, pattern, pattern, pattern, pattern)
    end
    if filter_word_type and filter_word_type ~= "" then
        local word_type_filter = wordTypeFilterSql(filter_word_type)
        if word_type_filter ~= "" then
            clauses[#clauses + 1] = word_type_filter
        end
    end
    if filter_source_language and filter_source_language ~= "" then
        if filter_source_language == "NONE" then
            clauses[#clauses + 1] = "(source_language = '' OR source_language IS NULL)"
        else
            local source_filter = sourceLanguageFilterSql(filter_source_language)
            if source_filter ~= "" then
                clauses[#clauses + 1] = source_filter:gsub("^%s*AND%s+", "")
            end
        end
    end
    if flagged_only then
        clauses[#clauses + 1] = "(flag <> 0 OR leech <> 0)"
    end
    if filter_ai_status then
        clauses[#clauses + 1] = "ai_status <> " .. DB.STATUS_ENRICHED
    end
    if filter_card_state == "not_started" then
        clauses[#clauses + 1] = "review_count = 0"
    elseif filter_card_state == "learning" then
        clauses[#clauses + 1] = "fsrs_state = 1"
    elseif filter_card_state == "learned" then
        clauses[#clauses + 1] = "known <> 0"
    elseif filter_card_state == "weak" then
        clauses[#clauses + 1] = "(lapse_count > 0 OR flag <> 0)"
    elseif filter_card_state == "leech" then
        clauses[#clauses + 1] = "leech <> 0"
    elseif filter_card_state == "suspended" then
        clauses[#clauses + 1] = "suspended <> 0"
    end
    if #clauses == 0 then
        return ""
    end
    return " WHERE " .. table.concat(clauses, " AND ")
end

local CARD_SORT_ORDERS = {
    due = {
        asc = "due ASC, phrase COLLATE NOCASE ASC, created_at DESC",
        desc = "due DESC, phrase COLLATE NOCASE ASC, created_at DESC",
    },
    alphabet = {
        asc = "phrase COLLATE NOCASE ASC, created_at DESC",
        desc = "phrase COLLATE NOCASE DESC, created_at DESC",
    },
    edited = {
        asc = "updated_at ASC, created_at ASC",
        desc = "updated_at DESC, created_at DESC",
    },
    added = {
        asc = "created_at ASC",
        desc = "created_at DESC",
    },
    lapses = {
        asc = "lapse_count ASC, due ASC",
        desc = "lapse_count DESC, due ASC",
    },
}

local function cardSortOrder(sort_by, sort_dir)
    local orders = CARD_SORT_ORDERS[sort_by or ""] or CARD_SORT_ORDERS.added
    return orders[sort_dir == "asc" and "asc" or "desc"]
end

function DB.countCards(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, filter_source_language, include_known, flagged_only, filter_ai_status, filter_card_state)
    DB.init()
    return withConnection(function(conn)
        local where = buildCardWhere(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, filter_source_language, include_known, flagged_only, filter_ai_status, filter_card_state)
        return tonumber(conn:rowexec("SELECT COUNT(*) FROM cards" .. where .. ";")) or 0
    end)
end

function DB.listCardsPage(book_id, include_enriched_only, reviewable_only, filter_text, limit, offset, now, sort_by, sort_dir, filter_word_type, filter_source_language, include_known, flagged_only, filter_ai_status, filter_card_state)
    DB.init()
    return withConnection(function(conn)
        local where = buildCardWhere(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, filter_source_language, include_known, flagged_only, filter_ai_status, filter_card_state)
        local sql = string.format("SELECT %s FROM cards%s ORDER BY %s LIMIT %d OFFSET %d;",
            CARD_SELECT_COLUMNS, where, cardSortOrder(sort_by, sort_dir), tonumber(limit) or 20, tonumber(offset) or 0)
        return fetchList(conn, sql)
    end)
end

function DB.listSourceLanguages(book_id)
    DB.init()
    return withConnection(function(conn)
        local where = "WHERE source_language <> ''"
        if book_id then
            local safe_book_id = tonumber(book_id) or 0
            where = where .. string.format(" AND book_id = %d", safe_book_id)
        end
        local stmt = conn:prepare([[
            SELECT DISTINCT source_language FROM cards ]] .. where .. [[
            ORDER BY source_language COLLATE NOCASE ASC;
        ]])
        local rows = stmt:resultset("hik")
        stmt:close()
        local languages = {}
        if rows and rows[1] then
            for i = 1, #rows[1] do
                local language = normalizeSourceLanguage(rows[1][i] or "")
                if language ~= "" then
                    languages[language] = true
                end
            end
        end
        local list = {}
        for language in pairs(languages) do
            list[#list + 1] = language
        end
        table.sort(list, function(a, b) return a:lower() < b:lower() end)
        return list
    end)
end

-- Return source languages that have at least one card matching the given
-- filter criteria.  Reuses buildCardWhere() so the result is consistent
-- with what countCards() / listCardsPage() would show.
-- Parameters mirror countCards() except filter_source_language is omitted
-- (we want all languages, not filtered by one).
function DB.listSourceLanguagesWithCards(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, include_known, flagged_only)
    DB.init()
    return withConnection(function(conn)
        local where = buildCardWhere(book_id, include_enriched_only, reviewable_only, filter_text, now, filter_word_type, nil, include_known, flagged_only)
        if where == "" then
            where = " WHERE source_language <> ''"
        else
            where = where .. " AND source_language <> ''"
        end
        local stmt = conn:prepare([[
            SELECT DISTINCT source_language FROM cards ]] .. where .. [[
            ORDER BY source_language COLLATE NOCASE ASC;
        ]])
        local rows = stmt:resultset("hik")
        stmt:close()
        local languages = {}
        if rows and rows[1] then
            for i = 1, #rows[1] do
                local language = normalizeSourceLanguage(rows[1][i] or "")
                if language ~= "" then
                    languages[language] = true
                end
            end
        end
        local list = {}
        for language in pairs(languages) do
            list[#list + 1] = language
        end
        table.sort(list, function(a, b) return a:lower() < b:lower() end)
        return list
    end)
end

function DB.listWordTypes(book_id)
    DB.init()
    return withConnection(function(conn)
        local where = "WHERE word_type <> ''"
        if book_id then
            where = where .. string.format(" AND book_id = %d", tonumber(book_id) or 0)
        end
        local stmt = conn:prepare("SELECT DISTINCT word_type FROM cards " .. where .. " ORDER BY word_type COLLATE NOCASE ASC;")
        local rows = stmt:resultset("hik")
        stmt:close()
        local types = {}
        if rows and rows[1] then
            for i = 1, #rows[1] do
                if rows[1][i] and rows[1][i] ~= "" then
                    local word_type = normalizeWordType(rows[1][i])
                    if word_type ~= "" then
                        types[word_type] = true
                    end
                end
            end
        end
        local list = {}
        for word_type in pairs(types) do
            list[#list + 1] = word_type
        end
        table.sort(list, function(a, b) return a:lower() < b:lower() end)
        return list
    end)
end

function DB.listPendingCards(book_id)
    DB.init()
    return withConnection(function(conn)
        local where = " WHERE NOT (" .. ENRICHED_CARD_SQL .. ")"
        if book_id then
            where = where .. string.format(" AND book_id = %d", book_id)
        end
        local sql = string.format("SELECT %s FROM cards%s ORDER BY created_at ASC;",
            CARD_SELECT_COLUMNS, where)
        return fetchList(conn, sql)
    end)
end

function DB.listCardsForRefetch(book_id)
    DB.init()
    return withConnection(function(conn)
        local where = ""
        if book_id then
            where = string.format(" WHERE book_id = %d", book_id)
        end
        local sql = string.format("SELECT %s FROM cards%s ORDER BY created_at ASC;",
            CARD_SELECT_COLUMNS, where)
        return fetchList(conn, sql)
    end)
end

function DB.getCardCountForBook(book_id)
    DB.init()
    return withConnection(function(conn)
        local query
        if book_id then
            query = string.format("SELECT COUNT(*) FROM cards WHERE book_id = %d;", book_id)
        else
            query = "SELECT COUNT(*) FROM cards;"
        end
        return tonumber(conn:rowexec(query)) or 0
    end)
end

function DB.getCardCountForSourceLanguage(source_language)
    source_language = normalizeSourceLanguage(source_language)
    if source_language == "" then return 0 end
    DB.init()
    return withConnection(function(conn)
        local source_filter = sourceLanguageFilterSql(source_language)
        local query = "SELECT COUNT(*) FROM cards WHERE 1 = 1" .. source_filter .. ";"
        return tonumber(conn:rowexec(query)) or 0
    end)
end

function DB.getLatestAIError()
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[
            SELECT phrase, ai_error, updated_at FROM cards
            WHERE ai_error <> ''
            ORDER BY updated_at DESC
            LIMIT 1;
        ]])
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then return nil end
        return {
            phrase = rows[1][1] or "",
            error = rows[2] and rows[2][1] or "",
            updated_at = rows[3] and tonumber(rows[3][1]) or nil,
        }
    end)
end

function DB.getSourceLanguageSummaries(require_enriched, now_ts)
    DB.init()
    return withConnection(function(conn)
        local now = tonumber(now_ts) or os.time()
        local due_extra = require_enriched and " AND ai_status = 1 AND meaning <> ''" or ""
        local sql = string.format([[SELECT
            c.source_language AS language,
            COUNT(*) AS total,
            COALESCE(SUM(CASE WHEN c.suspended = 0 AND c.due <= %d%s THEN 1 ELSE 0 END), 0) AS due,
            COALESCE(SUM(CASE WHEN c.review_count = 0 THEN 1 ELSE 0 END), 0) AS new,
            COALESCE(SUM(CASE WHEN c.review_count > 0 THEN 1 ELSE 0 END), 0) AS reviewed
            FROM cards c
            WHERE c.source_language <> ''
            GROUP BY c.source_language
            ORDER BY c.source_language COLLATE NOCASE ASC;]], now, due_extra)
        local stmt = conn:prepare(sql)
        local result = stmt:resultset("hik")
        stmt:close()
        local merged = {}
        if result and result[1] then
            for i = 1, #result[1] do
                local language = normalizeSourceLanguage(result[1][i] or "")
                if language ~= "" then
                    if not Languages.isKnown(language) then
                        language = "Other"
                    end
                    local row = merged[language] or {
                        language = language,
                        total = 0,
                        due = 0,
                        new = 0,
                        reviewed = 0,
                    }
                    row.total = row.total + (tonumber(result[2][i]) or 0)
                    row.due = row.due + (tonumber(result[3][i]) or 0)
                    row.new = row.new + (tonumber(result[4][i]) or 0)
                    row.reviewed = row.reviewed + (tonumber(result[5][i]) or 0)
                    merged[language] = row
                end
            end
        end
        local rows = {}
        for _, row in pairs(merged) do
            rows[#rows + 1] = row
        end
        table.sort(rows, function(a, b) return a.language:lower() < b.language:lower() end)
        return rows
    end)
end

function DB.getStudyQueueCounts(book_id, source_language, require_enriched, now_ts, daily_review_limit, learn_ahead_seconds, daily_new_limit, ignore_daily_override)
    DB.init()
    return withConnection(function(conn)
        ensureReviewHistoryTable(conn)
        local override = ignore_daily_override
            and { extra_new = 0, extra_review = 0 }
            or getDailyOverrideForConn(conn, source_language)
        return Queue.getCounts(conn, {
            book_id = book_id,
            source_language = source_language,
            require_enriched = require_enriched,
            now = now_ts,
            daily_new_limit = daily_new_limit,
            daily_review_limit = daily_review_limit,
            extra_new_limit = override.extra_new,
            extra_review_limit = override.extra_review,
            learn_ahead_seconds = learn_ahead_seconds,
            today_start = getTodayStart(),
            today_key = getTodayKey(),
            include_study_more = not ignore_daily_override,
        })
    end)
end

-- ── Summary cache ─────────────────────────────────────────────────────────
-- getSummary is expensive (3 SQL queries + streak iteration over all study
-- days). Cache results with a 30-second TTL so that rapid navigation (e.g.
-- opening/closing the stats view) doesn't recompute from scratch each time.
-- The cache is invalidated by any write operation (addCard, deleteCard,
-- updateCardScheduling, etc.) via DB.invalidateSummaryCache().

local SUMMARY_CACHE_TTL = 60 -- seconds
local _summary_cache = {}    -- key -> { expires_at, value }
local _summary_cache_version = 0

function DB.invalidateSummaryCache()
    _summary_cache = {}
    _summary_cache_version = _summary_cache_version + 1
end

function DB.getSummaryCacheVersion()
    return _summary_cache_version
end

function DB.getSummary(book_id, require_enriched_due)
    local cache_key = tostring(DB.active_language or "")
        .. "|" .. tostring(book_id or "")
        .. "|" .. tostring(require_enriched_due)
    local cached = _summary_cache[cache_key]
    if cached and cached.expires_at > os.time() then
        return cached.value
    end

    DB.init()
    local result = withConnection(function(conn)
        ensureReviewHistoryTable(conn)
        local history_book_filter = book_id and string.format(" AND c.book_id = %d", book_id) or ""
        local where_book = book_id and string.format(" WHERE book_id = %d", book_id) or ""
        local now = os.time()
        local today_start = os.time{
            year = tonumber(os.date("%Y")),
            month = tonumber(os.date("%m")),
            day = tonumber(os.date("%d")),
            hour = 0, min = 0, sec = 0,
        }
        local later_today_cutoff = nextReviewDayStart(now)
        local next_week = now + 7 * 86400
        local mature_seconds = 21 * 86400
        local due_extra = require_enriched_due and " AND " .. ENRICHED_CARD_SQL or ""
        local summary = {}
        local stats_sql = string.format([[SELECT
            COUNT(*) AS total,
            COALESCE(SUM(CASE WHEN ai_status = 1 THEN 1 ELSE 0 END), 0) AS enriched,
            COALESCE(SUM(CASE WHEN ai_status = 0 THEN 1 ELSE 0 END), 0) AS pending,
            COALESCE(SUM(CASE WHEN ai_status = 2 THEN 1 ELSE 0 END), 0) AS failed,
            COALESCE(SUM(CASE WHEN suspended = 0 AND known = 0 AND due <= %d%s THEN 1 ELSE 0 END), 0) AS due,
            COALESCE(SUM(CASE WHEN suspended = 0 AND known = 0 AND due < %d%s THEN 1 ELSE 0 END), 0) AS overdue,
            COALESCE(SUM(CASE WHEN suspended = 0 AND known = 0 AND due > %d AND due < %d%s THEN 1 ELSE 0 END), 0) AS due_later_today,
            COALESCE(SUM(CASE WHEN suspended = 0 AND known = 0 AND due >= %d AND due < %d%s THEN 1 ELSE 0 END), 0) AS due_tomorrow,
            COALESCE(SUM(CASE WHEN suspended = 0 AND known = 0 AND due > %d AND due <= %d%s THEN 1 ELSE 0 END), 0) AS due_next_7_days,
            COALESCE(SUM(CASE WHEN review_count = 0 THEN 1 ELSE 0 END), 0) AS new,
            COALESCE(SUM(CASE WHEN review_count > 0 AND fsrs_state IN (1, 3) THEN 1 ELSE 0 END), 0) AS learning,
            COALESCE(SUM(CASE WHEN review_count > 0 AND fsrs_state = 2 AND (due - COALESCE(last_review, created_at)) < %d THEN 1 ELSE 0 END), 0) AS young,
            COALESCE(SUM(CASE WHEN review_count > 0 AND fsrs_state = 2 AND (due - COALESCE(last_review, created_at)) >= %d THEN 1 ELSE 0 END), 0) AS mature,
            COALESCE(SUM(CASE WHEN review_count > 0 THEN 1 ELSE 0 END), 0) AS reviewed,
            COALESCE(SUM(lapse_count), 0) AS lapses,
            COALESCE(SUM(CASE WHEN lapse_count > 0 THEN 1 ELSE 0 END), 0) AS lapsed_cards,
            COALESCE(AVG(CASE WHEN fsrs_stability > 0 THEN fsrs_stability ELSE NULL END), 0) AS avg_stability,
            COALESCE(AVG(CASE WHEN fsrs_difficulty > 0 THEN fsrs_difficulty ELSE NULL END), 0) AS avg_difficulty,
            COALESCE(SUM(CASE WHEN suspended <> 0 THEN 1 ELSE 0 END), 0) AS suspended,
            COALESCE(SUM(CASE WHEN leech <> 0 THEN 1 ELSE 0 END), 0) AS leeches,
            COALESCE(SUM(CASE WHEN known <> 0 THEN 1 ELSE 0 END), 0) AS known,
            COALESCE(SUM(CASE WHEN flag <> 0 THEN 1 ELSE 0 END), 0) AS flagged,
            COALESCE(SUM(CASE WHEN created_at >= %d THEN 1 ELSE 0 END), 0) AS added_today
            FROM cards%s;]],
            now, due_extra, today_start, due_extra, now, later_today_cutoff, due_extra,
            later_today_cutoff, later_today_cutoff + 86400, due_extra,
            now, next_week, due_extra, mature_seconds, mature_seconds,
            today_start, where_book)
        local stats_stmt = conn:prepare(stats_sql)
        local stats_rows = stats_stmt:resultset("hik")
        stats_stmt:close()
        if stats_rows and stats_rows[0] and stats_rows[1] then
            for col_index, col_name in ipairs(stats_rows[0]) do
                summary[col_name] = tonumber(stats_rows[col_index][1]) or 0
            end
        end
        summary.books = tonumber(conn:rowexec(
            "SELECT COUNT(*) FROM books WHERE id IN (SELECT DISTINCT book_id FROM cards);"
        )) or 0
        summary.studied_today = 0
        summary.again_today = 0
        summary.hard_today = 0
        summary.good_today = 0
        summary.easy_today = 0
        summary.review_events = 0
        summary.study_days = 0
        summary.current_streak = 0
        summary.best_streak = 0

        local history_sql = string.format([[SELECT
            COUNT(*) AS review_events,
            COALESCE(SUM(CASE WHEN h.reviewed_at >= %d THEN 1 ELSE 0 END), 0) AS studied_today,
            COALESCE(SUM(CASE WHEN h.reviewed_at >= %d AND h.rating = 'again' THEN 1 ELSE 0 END), 0) AS again_today,
            COALESCE(SUM(CASE WHEN h.reviewed_at >= %d AND h.rating = 'hard' THEN 1 ELSE 0 END), 0) AS hard_today,
            COALESCE(SUM(CASE WHEN h.reviewed_at >= %d AND h.rating = 'good' THEN 1 ELSE 0 END), 0) AS good_today,
            COALESCE(SUM(CASE WHEN h.reviewed_at >= %d AND h.rating = 'easy' THEN 1 ELSE 0 END), 0) AS easy_today
            FROM review_history h
            JOIN cards c ON c.id = h.card_id
            WHERE 1 = 1%s;]],
            today_start, today_start, today_start, today_start, today_start, history_book_filter)
        local history_stmt = conn:prepare(history_sql)
        local history_rows = history_stmt:resultset("hik")
        history_stmt:close()
        if history_rows and history_rows[0] and history_rows[1] then
            for col_index, col_name in ipairs(history_rows[0]) do
                summary[col_name] = tonumber(history_rows[col_index][1]) or 0
            end
        end

        local streak_sql = "SELECT strftime('%Y-%m-%d', h.reviewed_at, 'unixepoch', 'localtime') AS day " ..
            "FROM review_history h JOIN cards c ON c.id = h.card_id " ..
            "WHERE 1 = 1" .. history_book_filter .. " GROUP BY day ORDER BY day ASC;"
        local stmt = conn:prepare(streak_sql)
        local rows = stmt:resultset("hik")
        stmt:close()
        local days = {}
        if rows and rows[1] then
            for i = 1, #rows[1] do
                local day = rows[1][i]
                if day and day ~= "" then
                    days[#days + 1] = day
                end
            end
        end
        summary.study_days = #days
        if #days > 0 then
            local day_set = {}
            for _, day in ipairs(days) do
                day_set[day] = true
            end

            local function dateKey(ts)
                return os.date("%Y-%m-%d", ts)
            end

            local cursor = today_start
            if not day_set[dateKey(cursor)] then
                cursor = cursor - 86400
            end
            while day_set[dateKey(cursor)] do
                summary.current_streak = summary.current_streak + 1
                cursor = cursor - 86400
            end

            local last_ts
            local current = 0
            for _, day in ipairs(days) do
                local year, month, date = day:match("^(%d+)%-(%d+)%-(%d+)$")
                local ts = os.time{
                    year = tonumber(year), month = tonumber(month), day = tonumber(date),
                    hour = 0, min = 0, sec = 0,
                }
                if last_ts and math.floor((ts - last_ts) / 86400) == 1 then
                    current = current + 1
                else
                    current = 1
                end
                if current > summary.best_streak then
                    summary.best_streak = current
                end
                last_ts = ts
            end
        end
        return summary
    end)

    -- Cache the result with TTL
    _summary_cache[cache_key] = {
        expires_at = os.time() + SUMMARY_CACHE_TTL,
        value = result,
    }
    return result
end

function DB.getDashboardSummary(options)
    options = options or {}
    local max_book_rows = math.max(1, tonumber(options.max_book_rows) or 3)
    local learn_ahead_seconds = tonumber(options.learn_ahead_seconds) or (20 * 60)
    local daily_new_limit = tonumber(options.daily_new_limit) or 20
    local daily_review_limit = tonumber(options.daily_review_limit) or 200
    local deck_new_limits = options.deck_new_limits or {}
    local deck_review_limits = options.deck_review_limits or {}
    local require_enriched = options.require_enriched
    if require_enriched == nil then require_enriched = false end

    local function summaryNumber(value)
        return tonumber(value) or 0
    end

    local function addSummaryTotals(total, summary)
        for _, key in ipairs{
            "total", "pending", "failed", "new", "reviewed", "learning",
            "mature", "flagged", "known", "lapsed_cards",
        } do
            total[key] = summaryNumber(total[key]) + summaryNumber(summary and summary[key])
        end
    end

    local function getQueueCounts(book_id, language)
        local deck_new = tonumber(deck_new_limits[language])
        local deck_review = tonumber(deck_review_limits[language])
        return DB.getStudyQueueCounts(
            book_id, language, require_enriched, nil,
            deck_review or daily_review_limit, learn_ahead_seconds,
            deck_new or daily_new_limit, true
        ) or { new = 0, learning = 0, review = 0 }
    end

    local function dueFromCounts(counts)
        return summaryNumber(counts and counts.new)
            + summaryNumber(counts and counts.learning)
            + summaryNumber(counts and counts.review)
    end

    local function countCardsByState(state, include_known)
        return summaryNumber(DB.countCards(
            nil, false, false, "", os.time(), nil, nil,
            include_known and true or false, false, false, state
        ))
    end

    local previous_language = DB.getActiveLanguage()
    local ok, result = pcall(function()
        local languages = options.languages or DB.listLanguages()
        local has_language = {}
        for _, language in ipairs(languages) do
            has_language[language] = true
        end
        local first_language = has_language[previous_language or ""] and previous_language or languages[1]
        local data = {
            summary = {},
            languages = {},
            books = {},
            first_due_language = nil,
            first_language = first_language,
            missing_ai_language = nil,
            weak_language = nil,
            leech_language = nil,
            suspended_language = nil,
        }

        for _, language in ipairs(languages) do
            DB.setLanguage(language)
            local summary = DB.getSummary(nil, require_enriched) or {}
            local counts = getQueueCounts(nil, language)
            local due = dueFromCounts(counts)
            local weak_count = countCardsByState("weak", false)
            local leech_count = countCardsByState("leech", false)
            local suspended_count = countCardsByState("suspended", true)
            addSummaryTotals(data.summary, summary)
            data.summary.due = summaryNumber(data.summary.due) + due
            data.summary.available_new = summaryNumber(data.summary.available_new) + summaryNumber(counts.new)
            data.summary.weak_cards = summaryNumber(data.summary.weak_cards) + weak_count
            data.summary.missing_ai = summaryNumber(data.summary.missing_ai)
                + summaryNumber(summary.pending) + summaryNumber(summary.failed)
            data.summary.leeches = summaryNumber(data.summary.leeches) + leech_count
            data.summary.suspended = summaryNumber(data.summary.suspended) + suspended_count

            data.languages[#data.languages + 1] = {
                language = language,
                total = summaryNumber(summary.total),
                due = due,
                new = summaryNumber(counts.new),
                mature = summaryNumber(summary.mature),
            }
            if (summaryNumber(summary.pending) + summaryNumber(summary.failed)) > 0 and not data.missing_ai_language then
                data.missing_ai_language = language
            end
            if weak_count > 0 and not data.weak_language then
                data.weak_language = language
            end
            if leech_count > 0 and not data.leech_language then
                data.leech_language = language
            end
            if suspended_count > 0 and not data.suspended_language then
                data.suspended_language = language
            end

            for _, book in ipairs(DB.listBooks() or {}) do
                data.books[#data.books + 1] = {
                    id = book.id,
                    language = language,
                    title = book.title ~= "" and book.title or book.filepath,
                    total = summaryNumber(book.card_count),
                    due = 0,
                }
            end
        end

        table.sort(data.languages, function(a, b)
            if a.due ~= b.due then return a.due > b.due end
            return tostring(a.language):lower() < tostring(b.language):lower()
        end)
        for _, row in ipairs(data.languages) do
            if summaryNumber(row.due) > 0 then
                data.first_due_language = row.language
                break
            end
        end
        table.sort(data.books, function(a, b)
            if a.total ~= b.total then return a.total > b.total end
            return tostring(a.title):lower() < tostring(b.title):lower()
        end)
        for i = 1, math.min(#data.books, max_book_rows) do
            local book = data.books[i]
            DB.setLanguage(book.language)
            book.due = dueFromCounts(getQueueCounts(book.id, book.language))
        end
        table.sort(data.books, function(a, b)
            if a.due ~= b.due then return a.due > b.due end
            if a.total ~= b.total then return a.total > b.total end
            return tostring(a.title):lower() < tostring(b.title):lower()
        end)

        return data
    end)

    DB.setLanguage(previous_language)
    if not ok then error(result) end
    return result
end

-- Return daily review summaries for the last `days` days from review_history.
-- Each row: { day = "YYYY-MM-DD", total, again, hard, good, easy, cards }
function DB.getStudyHistory(days)
    days = math.max(1, tonumber(days) or 7)
    DB.init()
    return withConnection(function(conn)
        local cutoff = os.time() - (days * 86400)
        local stmt = conn:prepare([[
            SELECT
                date(reviewed_at, 'unixepoch') AS day,
                COUNT(*) AS total,
                SUM(CASE WHEN rating = 'again' THEN 1 ELSE 0 END) AS again,
                SUM(CASE WHEN rating = 'hard' THEN 1 ELSE 0 END) AS hard,
                SUM(CASE WHEN rating = 'good' THEN 1 ELSE 0 END) AS good,
                SUM(CASE WHEN rating = 'easy' THEN 1 ELSE 0 END) AS easy,
                COUNT(DISTINCT card_id) AS cards
            FROM review_history
            WHERE reviewed_at >= ?
            GROUP BY day
            ORDER BY day DESC;
        ]])
        stmt:bind(cutoff)
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] then return {} end
        local list = {}
        for i = 1, #rows[1] do
            list[#list + 1] = {
                day = rows[1][i] or "",
                total = tonumber(rows[2][i]) or 0,
                again = tonumber(rows[3][i]) or 0,
                hard = tonumber(rows[4][i]) or 0,
                good = tonumber(rows[5][i]) or 0,
                easy = tonumber(rows[6][i]) or 0,
                cards = tonumber(rows[7][i]) or 0,
            }
        end
        return list
    end)
end

function DB.findCardByPhrase(book_id, phrase, exclude_card_id)
    if not book_id or not phrase or phrase == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local exclude_sql = exclude_card_id and string.format(" AND id <> %d", tonumber(exclude_card_id) or 0) or ""
        local stmt = conn:prepare(string.format(
            "SELECT %s FROM cards WHERE book_id = ? AND normalized_phrase = ?%s LIMIT 1;",
            CARD_SELECT_COLUMNS, exclude_sql
        ))
        stmt:bind(book_id, normalizePhrase(phrase))
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then return nil end
        local row = {}
        for header_index, header in ipairs(rows[0]) do
            row[header] = rows[header_index][1]
        end
        return mapCardRow(row)
    end)
end

function DB.findCardByPhraseInSourceLanguage(phrase, source_language, exclude_card_id)
    source_language = normalizeSourceLanguage(source_language)
    if not phrase or phrase == "" or source_language == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local source_filter = sourceLanguageFilterSql(source_language)
        if source_filter == "" then return nil end
        local exclude_sql = exclude_card_id and string.format(" AND id <> %d", tonumber(exclude_card_id) or 0) or ""
        local stmt = conn:prepare(string.format(
            "SELECT %s FROM cards WHERE normalized_phrase = ?%s%s LIMIT 1;",
            CARD_SELECT_COLUMNS,
            source_filter,
            exclude_sql
        ))
        stmt:bind(normalizePhrase(phrase))
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then return nil end
        local row = {}
        for header_index, header in ipairs(rows[0]) do
            row[header] = rows[header_index][1]
        end
        return mapCardRow(row)
    end)
end

function DB.findCardByPhraseDeckWide(phrase, exclude_card_id)
    if not phrase or phrase == "" then
        return nil
    end
    DB.init()
    return withConnection(function(conn)
        local exclude_sql = exclude_card_id and string.format(" AND id <> %d", tonumber(exclude_card_id) or 0) or ""
        local stmt = conn:prepare(string.format(
            "SELECT %s FROM cards WHERE normalized_phrase = ?%s LIMIT 1;",
            CARD_SELECT_COLUMNS,
            exclude_sql
        ))
        stmt:bind(normalizePhrase(phrase))
        local rows = stmt:resultset("hik")
        stmt:close()
        if not rows or not rows[1] or #rows[1] == 0 then return nil end
        local row = {}
        for header_index, header in ipairs(rows[0]) do
            row[header] = rows[header_index][1]
        end
        return mapCardRow(row)
    end)
end

function DB.findDuplicateCard(book_id, phrase, source_language, exclude_card_id)
    local existing
    source_language = normalizeSourceLanguage(source_language)
    if source_language ~= "" then
        existing = DB.findCardByPhraseInSourceLanguage(phrase, source_language, exclude_card_id)
        return existing
    end
    return DB.findCardByPhraseDeckWide(phrase, exclude_card_id)
end

function DB.cardPhraseExists(book_id, phrase, exclude_card_id, source_language)
    return DB.findDuplicateCard(book_id, phrase, source_language, exclude_card_id) ~= nil
end

function DB.updateCardSourceLanguage(card_id, source_language)
    if not card_id or not source_language or source_language == "" then return false end
    source_language = normalizeSourceLanguage(source_language)
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            source_language = ?, updated_at = ?
            WHERE id = ? AND source_language = '';]])
        stmt:bind(source_language, os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

-- Move a card to another language deck. Preserves the original book,
-- review history, and all card data. Only the source_language changes.
-- Sets moved=1 on the new card for future identification.
function DB.moveCardToLanguage(card_id, target_language)
    if not card_id or not target_language or target_language == "" then return false end
    target_language = normalizeSourceLanguage(target_language)
    if target_language == "" then return false end
    DB.init()
    local card = DB.getCard(card_id)
    if not card then return false end
    -- Fetch review history from current DB
    local history = {}
    withConnection(function(conn)
        local stmt = conn:prepare([[SELECT reviewed_at, rating, state_before, state_after,
            due_before, due_after, elapsed_days, scheduled_days, actual_days,
            difficulty_before, stability_before, retrievability_before,
            difficulty_after, stability_after
            FROM review_history WHERE card_id = ? ORDER BY reviewed_at;]])
        stmt:bind(card_id)
        local rows = stmt:resultset("hik")
        stmt:close()
        if rows and rows[1] then
            for i = 1, #rows[1] do
                history[#history + 1] = {
                    reviewed_at = rows[1][i], rating = rows[2][i],
                    state_before = rows[3][i], state_after = rows[4][i],
                    due_before = rows[5][i], due_after = rows[6][i],
                    elapsed_days = rows[7][i], scheduled_days = rows[8][i],
                    actual_days = rows[9][i], difficulty_before = rows[10][i],
                    stability_before = rows[11][i], retrievability_before = rows[12][i],
                    difficulty_after = rows[13][i], stability_after = rows[14][i],
                }
            end
        end
    end)
    -- Get original book info before switching
    local book_title, book_filepath
    withConnection(function(conn)
        local stmt = conn:prepare("SELECT b.title, b.filepath FROM books b JOIN cards c ON c.book_id = b.id WHERE c.id = ?;")
        stmt:bind(card_id)
        local rows = stmt:resultset("hik")
        stmt:close()
        if rows and rows[1] then
            book_title = rows[1][1]
            book_filepath = rows[2][1]
        end
    end)
    book_title = book_title or "Moved cards"
    book_filepath = book_filepath or "vocabdeck://moved/" .. card_id
    -- Switch to target language, ensure same book exists
    local prev_lang = DB.active_language
    DB.setLanguage(target_language)
    local target_book_id = DB.getBookIdByFilepath(book_filepath)
        or DB.getOrCreateBook(book_title, book_filepath, target_language)
    if not target_book_id then
        if prev_lang and prev_lang ~= target_language then
            DB.setLanguage(prev_lang)
        end
        return false
    end
    local new_id = withConnection(function(conn)
        local stmt = conn:prepare([[
            INSERT INTO cards (book_id, phrase, normalized_phrase, sentence, ai_context,
                display_context, pronunciation, meaning, synonym, word_type, source_language,
                user_note, ai_memory_helper, ai_status, ai_error, due, fsrs_state, fsrs_step,
                fsrs_stability, fsrs_difficulty, last_review, review_count, lapse_count,
                suspended, leech, leech_notified_at, known, flag, study_more_day,
                moved, created_at, updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);]])
        stmt:bind(target_book_id, card.phrase, card.normalized_phrase or "",
            card.sentence or "", card.ai_context or "", card.display_context or "",
            card.pronunciation or "", card.meaning or "", card.synonym or "",
            card.word_type or "", target_language, card.user_note or "",
            card.ai_memory_helper or "", card.ai_status or 0, card.ai_error or "",
            card.due or os.time(), card.fsrs_state or 1, card.fsrs_step or 0,
            card.fsrs_stability or 0, card.fsrs_difficulty or 0,
            card.last_review, card.review_count or 0, card.lapse_count or 0,
            card.suspended or 0, card.leech or 0, card.leech_notified_at,
            card.known or 0, card.flag or 0, card.study_more_day or "",
            1,  -- moved
            card.created_at or os.time(), os.time())
        stmt:step()
        stmt:close()
        return conn:rowexec("SELECT last_insert_rowid();")
    end)
    new_id = tonumber(new_id)
    if new_id and #history > 0 then
        withConnection(function(conn)
            local stmt = conn:prepare([[
                INSERT INTO review_history (card_id, reviewed_at, rating, state_before,
                    state_after, due_before, due_after, elapsed_days, scheduled_days,
                    actual_days, difficulty_before, stability_before, retrievability_before,
                    difficulty_after, stability_after)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);]])
            for _, h in ipairs(history) do
                stmt:clearbind():reset()
                stmt:bind(new_id, h.reviewed_at, h.rating, h.state_before, h.state_after,
                    h.due_before, h.due_after, h.elapsed_days, h.scheduled_days, h.actual_days,
                    h.difficulty_before, h.stability_before, h.retrievability_before,
                    h.difficulty_after, h.stability_after)
                stmt:step()
            end
            stmt:close()
        end)
    end
    if prev_lang and prev_lang ~= target_language then
        DB.setLanguage(prev_lang)
    end
    DB.deleteCard(card_id)
    return true
end

-- Return the book_id for a card, or nil.
function DB.getCardBookId(card_id)
    if not card_id then return nil end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("SELECT book_id FROM cards WHERE id = ?;")
        stmt:bind(card_id)
        local rows = stmt:resultset("hik")
        stmt:close()
        return rows and rows[1] and rows[1][1]
    end)
end

-- Check whether a card with the given headword already exists in the same
-- book (and optionally the same source language), excluding `exclude_id`.
-- Returns the duplicate card id, or nil.
function DB.findDuplicateByHeadword(book_id, headword, source_language, exclude_id)
    if not book_id or not headword or headword == "" then return nil end
    DB.init()
    return withConnection(function(conn)
        local normalized = normalizePhrase(headword)
        local lang_filter = sourceLanguageFilterSql(source_language)
        local sql
        if lang_filter ~= "" then
            sql = "SELECT id FROM cards WHERE normalized_phrase = ? AND book_id = ?" .. lang_filter .. " AND id <> ? LIMIT 1;"
        else
            sql = "SELECT id FROM cards WHERE normalized_phrase = ? AND book_id = ? AND id <> ? LIMIT 1;"
        end
        local stmt = conn:prepare(sql)
        stmt:bind(normalized, book_id, exclude_id or 0)
        local rows = stmt:resultset("hik")
        stmt:close()
        return rows and rows[1] and rows[1][1]
    end)
end

-- Apply AI enrichment result to a card.
-- result: {headword?, pronunciation, meaning, synonym, word_type, source_language?, status, error}
function DB.applyEnrichment(card_id, result)
    if not card_id or not result then return false end
    DB.init()
    return withConnection(function(conn)
        local headword_value = TextUtils.trim(tostring(result.headword or ""))
        local headword = normalizePhrase(headword_value)
        local source_language = normalizeSourceLanguage(result.source_language)
        if headword ~= "" then
            local current_stmt = conn:prepare([[SELECT c.book_id, c.phrase, c.source_language
                FROM cards c WHERE c.id = ?;]])
            current_stmt:bind(card_id)
            local current_rows = current_stmt:resultset("hik")
            current_stmt:close()
            local book_id = current_rows and current_rows[1] and current_rows[1][1]
            local current_phrase = current_rows and current_rows[2] and current_rows[2][1]
            local effective_language = source_language ~= "" and source_language
                or (current_rows and current_rows[3] and normalizeSourceLanguage(current_rows[3][1]) or "")
            if book_id and current_phrase and normalizePhrase(current_phrase) ~= headword then
                local source_filter = sourceLanguageFilterSql(effective_language)
                local duplicate_sql = source_filter ~= ""
                    and ("SELECT id FROM cards WHERE normalized_phrase = ? AND id <> ?" .. source_filter .. " LIMIT 1;")
                    or "SELECT id FROM cards WHERE normalized_phrase = ? AND book_id = ? AND id <> ? LIMIT 1;"
                local duplicate_stmt = conn:prepare(duplicate_sql)
                if source_filter ~= "" then
                    duplicate_stmt:bind(headword, card_id)
                else
                    duplicate_stmt:bind(headword, book_id, card_id)
                end
                local duplicate_rows = duplicate_stmt:resultset("hik")
                duplicate_stmt:close()
                if not duplicate_rows or not duplicate_rows[1] then
                    local phrase_stmt = conn:prepare("UPDATE cards SET phrase = ?, normalized_phrase = ? WHERE id = ?;")
                    phrase_stmt:bind(headword_value, normalizePhrase(headword_value), card_id)
                    phrase_stmt:step()
                    phrase_stmt:close()
                end
            end
        end
        local stmt = conn:prepare([[UPDATE cards SET
            pronunciation = ?, meaning = ?, synonym = ?, word_type = ?,
            source_language = CASE WHEN ? <> '' THEN ? ELSE source_language END,
            ai_status = ?, ai_error = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(
            result.pronunciation or "",
            result.meaning or "",
            result.synonym or "",
            result.word_type or "",
            source_language,
            source_language,
            result.status or DB.STATUS_PENDING,
            result.error or "",
            os.time(),
            card_id
        )
        stmt:step()
        stmt:close()
        if source_language ~= "" then
            local book_stmt = conn:prepare([[UPDATE books SET source_language = ?
                WHERE id = (SELECT book_id FROM cards WHERE id = ?) AND source_language = '';]])
            book_stmt:bind(source_language, card_id)
            book_stmt:step()
            book_stmt:close()
        end
        DB.invalidateSummaryCache()
        return true
    end)
end

-- Merge source card into target card, then delete source.
-- If target has no AI data and ai_result is provided, apply AI data to target.
-- Otherwise copy only non-AI fields that target is missing.
-- ai_result: {headword, pronunciation, meaning, synonym, word_type, source_language, status, error} or nil
function DB.mergeCards(source_id, target_id, ai_result)
    if not source_id or not target_id then return false end
    DB.init()
    return withConnection(function(conn)
        -- Fetch both cards
        local function fetchCard(id)
            local stmt = conn:prepare([[SELECT phrase, user_note, display_context, sentence, ai_context,
                meaning, synonym, pronunciation, word_type, source_language, ai_status
                FROM cards WHERE id = ?;]])
            stmt:bind(id)
            local rows = stmt:resultset("hik")
            stmt:close()
            return rows and rows[1]
        end
        local source = fetchCard(source_id)
        local target = fetchCard(target_id)
        if not source or not target then return false end

        local target_has_ai = target[6] and target[6] ~= ""  -- meaning non-empty
        local updates = {}
        local params = {}

        -- Apply AI data only if target doesn't have it yet
        if ai_result and not target_has_ai then
            updates[#updates + 1] = "phrase = ?"
            params[#params + 1] = ai_result.headword or source[1]
            updates[#updates + 1] = "normalized_phrase = ?"
            params[#params + 1] = normalizePhrase(ai_result.headword or source[1])
            updates[#updates + 1] = "pronunciation = ?"
            params[#params + 1] = ai_result.pronunciation or ""
            updates[#updates + 1] = "meaning = ?"
            params[#params + 1] = ai_result.meaning or ""
            updates[#updates + 1] = "synonym = ?"
            params[#params + 1] = ai_result.synonym or ""
            updates[#updates + 1] = "word_type = ?"
            params[#params + 1] = ai_result.word_type or ""
            if (ai_result.source_language or "") ~= "" then
                updates[#updates + 1] = "source_language = ?"
                params[#params + 1] = ai_result.source_language
            end
            updates[#updates + 1] = "ai_status = ?"
            params[#params + 1] = DB.STATUS_ENRICHED
        end

        -- Copy non-AI fields from source if target is missing them
        local field_map = {
            { idx = 2, col = "user_note" },
            { idx = 3, col = "display_context" },
            { idx = 4, col = "sentence" },
            { idx = 5, col = "ai_context" },
        }
        for _, f in ipairs(field_map) do
            local src_val = source[f.idx] or ""
            local tgt_val = target[f.idx] or ""
            if src_val ~= "" and tgt_val == "" then
                updates[#updates + 1] = f.col .. " = ?"
                params[#params + 1] = src_val
            end
        end

        if #updates > 0 then
            updates[#updates + 1] = "updated_at = ?"
            params[#params + 1] = os.time()
            local sql = "UPDATE cards SET " .. table.concat(updates, ", ") .. " WHERE id = ?;"
            params[#params + 1] = target_id
            local stmt = conn:prepare(sql)
            stmt:bind(table.unpack(params))
            stmt:step()
            stmt:close()
        end

        -- Delete source
        local del_stmt = conn:prepare("DELETE FROM cards WHERE id = ?;")
        del_stmt:bind(source_id)
        del_stmt:step()
        del_stmt:close()

        DB.invalidateSummaryCache()
        return true
    end)
end

-- Record provider/parsing errors without touching existing card content.
function DB.recordAIError(card_id, status, err)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            ai_status = ?, ai_error = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(
            status or DB.STATUS_ERROR,
            err or "",
            os.time(),
            card_id
        )
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.updateCardFields(card_id, fields)
    if not card_id or not fields then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            phrase = ?, normalized_phrase = ?, sentence = ?, ai_context = ?, display_context = ?,
            pronunciation = ?, meaning = ?, synonym = ?, word_type = ?, source_language = ?,
            user_note = ?, ai_memory_helper = ?,
            ai_status = ?, ai_error = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(
            fields.phrase or "",
            normalizePhrase(fields.phrase),
            fields.sentence or "",
            fields.ai_context or "",
            fields.display_context or "",
            fields.pronunciation or "",
            fields.meaning or "",
            fields.synonym or "",
            fields.word_type or "",
            normalizeSourceLanguage(fields.source_language),
            fields.user_note or "",
            fields.ai_memory_helper or "",
            fields.ai_status or DB.STATUS_PENDING,
            fields.ai_error or "",
            os.time(),
            card_id
        )
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.setCardSuspended(card_id, suspended)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("UPDATE cards SET suspended = ?, updated_at = ? WHERE id = ?;")
        stmt:bind(suspended and 1 or 0, os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.setCardLeech(card_id, leech)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local now = os.time()
        local stmt
        if leech then
            stmt = conn:prepare("UPDATE cards SET leech = 1, leech_notified_at = ?, updated_at = ? WHERE id = ?;")
            stmt:bind(now, now, card_id)
        else
            stmt = conn:prepare("UPDATE cards SET leech = 0, leech_notified_at = NULL, updated_at = ? WHERE id = ?;")
            stmt:bind(now, card_id)
        end
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

-- Store the count of consecutive successful reviews for a leech card.
--
-- leech_notified_at serves double duty:
--   Positive value = Unix timestamp of when the card was marked as a leech
--                    (set by setCardLeech).
--   Negative value = count of consecutive successful reviews since leeching
--                     (set by setCardLeechSuccessCount: -1 = 1 review, -2 = 2, etc.)
--   NULL or 0      = not a leech, or no successful reviews since leeching.
-- This avoids adding a separate column for a rarely-used counter.
function DB.setCardLeechSuccessCount(card_id, count)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt
        if count and count > 0 then
            stmt = conn:prepare("UPDATE cards SET leech_notified_at = ?, updated_at = ? WHERE id = ?;")
            stmt:bind(-count, os.time(), card_id)
        else
            stmt = conn:prepare("UPDATE cards SET leech_notified_at = NULL, updated_at = ? WHERE id = ?;")
            stmt:bind(os.time(), card_id)
        end
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.setCardKnown(card_id, known)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("UPDATE cards SET known = ?, updated_at = ? WHERE id = ?;")
        stmt:bind(known and 1 or 0, os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.setCardFlag(card_id, flag)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare("UPDATE cards SET flag = ?, updated_at = ? WHERE id = ?;")
        stmt:bind(flag and 1 or 0, os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.resetCardScheduling(card_id)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            due = ?, fsrs_state = ?, fsrs_step = 0, fsrs_stability = 0,
            fsrs_difficulty = 0, last_review = NULL, review_count = 0,
            lapse_count = 0, suspended = 0, leech = 0, leech_notified_at = NULL,
            known = 0, updated_at = ?
            WHERE id = ?;]])
        local now = os.time()
        stmt:bind(now, Scheduler.STATE_LEARNING, now, card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

function DB.fetchNextDueCard(book_id, now_ts, randomize, daily_new_limit, require_enriched, source_language, daily_review_limit, use_daily_override)
    DB.init()
    local now = now_ts or os.time()
    return withConnection(function(conn)
        ensureReviewHistoryTable(conn)
        local override = use_daily_override
            and getDailyOverrideForConn(conn, source_language)
            or { extra_new = 0, extra_review = 0 }
        return Queue.getNextCard(conn, {
            book_id = book_id,
            source_language = source_language,
            require_enriched = require_enriched,
            now = now,
            randomize = not not randomize,
            daily_new_limit = daily_new_limit,
            daily_review_limit = daily_review_limit,
            extra_new_limit = override.extra_new,
            extra_review_limit = override.extra_review,
            today_start = getTodayStart(),
            today_key = getTodayKey(),
            include_study_more = not not use_daily_override,
            columns = CARD_SELECT_COLUMNS,
            fetch_single = fetchSingle,
        })
    end)
end

function DB.fetchNextLearningAheadCard(book_id, now_ts, learn_ahead_seconds, require_enriched, source_language, use_daily_override)
    DB.init()
    local now = now_ts or os.time()
    return withConnection(function(conn)
        return Queue.getLearningAheadCard(conn, {
            book_id = book_id,
            source_language = source_language,
            require_enriched = require_enriched,
            now = now,
            learn_ahead_seconds = learn_ahead_seconds,
            today_key = getTodayKey(),
            include_study_more = not not use_daily_override,
            columns = CARD_SELECT_COLUMNS,
            fetch_single = fetchSingle,
        })
    end)
end

function DB.previewIntervals(card, now_ts, desired_retention)
    return Scheduler.previewIntervals(card, now_ts, desired_retention)
end

function DB.updateCardScheduling(card, rating, now_ts, desired_retention, study_more_day)
    if not card or not card.id then return nil end
    DB.init()
    local now = now_ts or os.time()
    local old_due = tonumber(card.due)
    local old_state = tonumber(card.fsrs_state) or Scheduler.STATE_LEARNING
    local old_stability = tonumber(card.fsrs_stability) or 0
    local old_difficulty = tonumber(card.fsrs_difficulty) or 0
    local old_last_review = tonumber(card.last_review)
    local old_retrievability = Scheduler.getRetrievability(card, now)
    local actual_days = old_last_review and math.max(0, (now - old_last_review) / 86400) or 0
    local elapsed_days = actual_days
    local new_interval, new_due, new_state, new_step, new_stability,
        new_difficulty, new_last_review, new_review_count, new_lapse_count =
        Scheduler.compute(card, rating, now, desired_retention)
    local scheduled_days = math.max(0, (new_due - now) / 86400)
    withConnection(function(conn)
        ensureReviewHistoryTable(conn)
        study_more_day = tostring(study_more_day or "")
        local stmt = conn:prepare([[UPDATE cards
            SET due = ?, fsrs_state = ?, fsrs_step = ?, fsrs_stability = ?,
                fsrs_difficulty = ?, last_review = ?,
                review_count = ?, lapse_count = ?,
                study_more_day = CASE WHEN ? <> '' AND study_more_day = '' THEN ? ELSE study_more_day END,
                updated_at = ?
            WHERE id = ?;]])
        stmt:bind(
            new_due, new_state, new_step, new_stability, new_difficulty,
            new_last_review, new_review_count, new_lapse_count,
            study_more_day, study_more_day,
            now, card.id
        )
        stmt:step()
        stmt:close()

        local history_stmt = conn:prepare([[INSERT INTO review_history (
            card_id, reviewed_at, rating, state_before, state_after,
            due_before, due_after, elapsed_days, scheduled_days, actual_days,
            difficulty_before, stability_before, retrievability_before,
            difficulty_after, stability_after
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);]])
        history_stmt:bind(
            card.id, now, rating or "",
            old_state, new_state,
            old_due, new_due,
            elapsed_days, scheduled_days, actual_days,
            old_difficulty, old_stability, old_retrievability,
            new_difficulty, new_stability
        )
        history_stmt:step()
        history_stmt:close()
        DB.invalidateSummaryCache()
    end)
    card.due = new_due
    card.fsrs_state = new_state
    card.fsrs_step = new_step
    card.fsrs_stability = new_stability
    card.fsrs_difficulty = new_difficulty
    card.last_review = new_last_review
    card.review_count = new_review_count
    card.lapse_count = new_lapse_count
    if study_more_day ~= "" and (card.study_more_day or "") == "" then
        card.study_more_day = study_more_day
    end
    return card
end

-- Lightweight update for just the user_note field.
-- Avoids the heavy updateCardFields() call which writes every column.
function DB.updateCardNote(card_id, note)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            user_note = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(note or "", os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

-- Lightweight update for just the ai_memory_helper field.
function DB.updateCardMemoryHelper(card_id, helper_text)
    if not card_id then return false end
    DB.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE cards SET
            ai_memory_helper = ?, updated_at = ?
            WHERE id = ?;]])
        stmt:bind(helper_text or "", os.time(), card_id)
        stmt:step()
        stmt:close()
        DB.invalidateSummaryCache()
        return true
    end)
end

return DB
