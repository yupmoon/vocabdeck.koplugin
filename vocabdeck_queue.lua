-- VocabDeck study queue policy.
--
-- The scheduler decides when a card is ideally due. This module decides which
-- card should be shown next in a study session.
--
-- SQL construction is localised inside this module. Callers pass semantic
-- values (source_language, require_enriched) rather than pre-built SQL
-- fragments, so all SQL string concatenation is visible in one place.

local Scheduler = require("vocabdeck_scheduler")
local Languages = require("vocabdeck_languages")

local Queue = {}

-- Hardcoded SQL fragment for filtering to enriched cards only.
local ENRICHED_CARD_SQL = "ai_status = 1 AND meaning <> ''"

--------------------------------------------------------------------
-- Helpers: SQL fragment generation (localised, not exported)
--------------------------------------------------------------------

local function dueOrder(randomize)
    if randomize then
        return "ORDER BY due ASC, random()"
    end
    return "ORDER BY due ASC, id ASC"
end

--- Build a source-language filter SQL fragment from a language name.
--- The language name is normalised via Languages, and all known aliases
--- are single-quote escaped before concatenation.  Returns "" when the
--- language is empty or unknown.
local function sourceFilterSql(source_language)
    if not source_language or source_language == "" then return "" end
    local normalized = Languages.normalize(source_language)
    if normalized == "" then return "" end
    local aliases = Languages.getAliases(normalized)
    if not aliases or #aliases == 0 then return "" end
    local seen, quoted = {}, {}
    for _, alias in ipairs(aliases) do
        local value = tostring(alias or "")
        if value ~= "" and not seen[value:lower()] then
            seen[value:lower()] = true
            quoted[#quoted + 1] = "'" .. value:gsub("'", "''") .. "'"
        end
    end
    if #quoted == 0 then return "" end
    local language_list = table.concat(quoted, ", ")
    return string.format([[ (source_language COLLATE NOCASE IN (%s)
        OR (source_language = '' AND book_id IN (
            SELECT id FROM books WHERE source_language COLLATE NOCASE IN (%s)
        ))) ]], language_list, language_list)
end

--- Build the enriched-card filter SQL fragment.
local function enrichedFilterSql(require_enriched)
    if not require_enriched then return "" end
    return ENRICHED_CARD_SQL
end

--------------------------------------------------------------------
-- Core filter builder (used by every query in this module)
--------------------------------------------------------------------

local function baseFilters(opts)
    opts = opts or {}
    local filters = { "suspended = 0", "known = 0" }

    if not opts.include_study_more and opts.today_key and opts.today_key ~= "" then
        -- today_key is always os.date("%Y-%m-%d") from internal callers,
        -- so gsub escaping is sufficient.
        filters[#filters + 1] = string.format(
            "(study_more_day = '' OR study_more_day <> '%s' OR fsrs_state = %d)",
            tostring(opts.today_key):gsub("'", "''"),
            Scheduler.STATE_REVIEW
        )
    end

    if opts.book_id then
        -- tonumber ensures only numeric values pass through.
        filters[#filters + 1] = string.format("book_id = %d", tonumber(opts.book_id) or 0)
    end

    -- source_language filter — built from a semantic value, not a raw SQL string.
    local source_sql = sourceFilterSql(opts.source_language)
    if source_sql ~= "" then
        filters[#filters + 1] = source_sql
    end

    -- enriched filter — built from a boolean, not a raw SQL string.
    local enriched_sql = enrichedFilterSql(opts.require_enriched)
    if enriched_sql ~= "" then
        filters[#filters + 1] = enriched_sql
    end

    return table.concat(filters, " AND ")
end

--------------------------------------------------------------------
-- Daily-introduced count (used by dailyNewLimitReached)
--------------------------------------------------------------------

local function dailyNewIntroducedCount(conn, opts)
    if not opts.today_start then
        return 0
    end
    local filters = {}
    if opts.book_id then
        filters[#filters + 1] = string.format("c.book_id = %d", tonumber(opts.book_id) or 0)
    end
    local source_sql = sourceFilterSql(opts.source_language)
    if source_sql ~= "" then
        filters[#filters + 1] = source_sql
    end
    local filter_sql = #filters > 0 and (" AND " .. table.concat(filters, " AND ")) or ""
    local sql = string.format([[SELECT COUNT(*) FROM (
            SELECT h.card_id, MIN(h.reviewed_at) AS first_reviewed_at
            FROM review_history h
            JOIN cards c ON c.id = h.card_id
            WHERE 1 = 1%s
            GROUP BY h.card_id
        ) first_reviews
        WHERE first_reviewed_at >= %d;]],
        filter_sql, tonumber(opts.today_start) or 0)
    local count = tonumber(conn:rowexec(sql)) or 0
    return count
end

local function dailyNewLimitReached(conn, opts)
    local limit = tonumber(opts.daily_new_limit) or 0
    if limit <= 0 then
        return false
    end
    limit = limit + math.max(0, tonumber(opts.extra_new_limit) or 0)
    local count = dailyNewIntroducedCount(conn, opts)
    return count >= limit
end

--------------------------------------------------------------------
-- Daily-review-done count (used by dailyReviewLimitReached)
--------------------------------------------------------------------

local function dailyReviewDoneCount(conn, opts)
    if not opts.today_start then
        return 0
    end
    local filters = {}
    if opts.book_id then
        filters[#filters + 1] = string.format("c.book_id = %d", tonumber(opts.book_id) or 0)
    end
    local source_sql = sourceFilterSql(opts.source_language)
    if source_sql ~= "" then
        filters[#filters + 1] = source_sql
    end
    local filter_sql = #filters > 0 and (" AND " .. table.concat(filters, " AND ")) or ""
    local sql = string.format([[SELECT COUNT(*) FROM review_history h
        JOIN cards c ON c.id = h.card_id
        WHERE h.reviewed_at >= %d AND h.state_before = %d%s;]],
        tonumber(opts.today_start) or 0, Scheduler.STATE_REVIEW, filter_sql)
    local count = tonumber(conn:rowexec(sql)) or 0
    return count
end

local function dailyReviewLimitReached(conn, opts)
    local limit = tonumber(opts.daily_review_limit) or 0
    if limit <= 0 then
        return false
    end
    limit = limit + math.max(0, tonumber(opts.extra_review_limit) or 0)
    local count = dailyReviewDoneCount(conn, opts)
    return count >= limit
end

--------------------------------------------------------------------
-- Single-card selector (used by getNextCard / getLearningAheadCard)
--------------------------------------------------------------------

local function selectOne(conn, opts, extra_filter)
    local sql = string.format([[SELECT %s FROM cards
        WHERE %s AND due <= %d AND %s
        %s LIMIT 1;]],
        opts.columns,
        baseFilters(opts),
        tonumber(opts.now) or os.time(),
        extra_filter,
        dueOrder(opts.randomize))
    return opts.fetch_single(conn, sql)
end

--------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------

function Queue.getNextCard(conn, opts)
    opts = opts or {}
    opts.now = tonumber(opts.now) or os.time()

    local learning_filter = string.format(
        "review_count > 0 AND fsrs_state IN (%d, %d)",
        Scheduler.STATE_LEARNING, Scheduler.STATE_RELEARNING)
    local card = selectOne(conn, opts, learning_filter)
    if card then return card end

    if not dailyReviewLimitReached(conn, opts) then
        card = selectOne(conn, opts, "review_count > 0 AND fsrs_state = " .. Scheduler.STATE_REVIEW)
        if card then return card end
    end

    if not dailyNewLimitReached(conn, opts) then
        return selectOne(conn, opts, "review_count = 0")
    end
    return nil
end

function Queue.getLearningAheadCard(conn, opts)
    opts = opts or {}
    local now = tonumber(opts.now) or os.time()
    local horizon = now + (tonumber(opts.learn_ahead_seconds) or 0)
    local sql = string.format([[SELECT %s FROM cards
        WHERE %s AND due > %d AND due <= %d
            AND review_count > 0
            AND fsrs_state IN (%d, %d)
        %s LIMIT 1;]],
        opts.columns,
        baseFilters(opts),
        now, horizon,
        Scheduler.STATE_LEARNING, Scheduler.STATE_RELEARNING,
        dueOrder(false))
    return opts.fetch_single(conn, sql)
end

function Queue.getCounts(conn, opts)
    opts = opts or {}
    local now = tonumber(opts.now) or os.time()
    local learn_ahead_seconds = tonumber(opts.learn_ahead_seconds) or 0
    local learning_horizon = now + learn_ahead_seconds
    local sql = string.format([[SELECT
        COALESCE(SUM(CASE WHEN due <= %d AND review_count = 0 THEN 1 ELSE 0 END), 0) AS new_count,
        COALESCE(SUM(CASE WHEN due <= %d AND review_count > 0 AND fsrs_state IN (%d, %d)
            THEN 1 ELSE 0 END), 0) AS learning_count,
        COALESCE(SUM(CASE WHEN due <= %d AND review_count > 0 AND fsrs_state = %d THEN 1 ELSE 0 END), 0) AS review_count
        FROM cards
        WHERE %s AND due <= %d;]],
        now, learning_horizon,
        Scheduler.STATE_LEARNING, Scheduler.STATE_RELEARNING,
        now, Scheduler.STATE_REVIEW,
        baseFilters(opts), learning_horizon)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] or not rows[1][1] then
        return { new = 0, learning = 0, review = 0 }
    end
    local review_count = tonumber(rows[3][1]) or 0
    local daily_new_limit = tonumber(opts.daily_new_limit) or 0
    local new_count = tonumber(rows[1][1]) or 0
    if daily_new_limit > 0 then
        daily_new_limit = daily_new_limit + math.max(0, tonumber(opts.extra_new_limit) or 0)
        local remaining = daily_new_limit - dailyNewIntroducedCount(conn, opts)
        if remaining < 0 then remaining = 0 end
        if new_count > remaining then new_count = remaining end
    end
    local daily_review_limit = tonumber(opts.daily_review_limit) or 0
    if daily_review_limit > 0 then
        daily_review_limit = daily_review_limit + math.max(0, tonumber(opts.extra_review_limit) or 0)
        local remaining = daily_review_limit - dailyReviewDoneCount(conn, opts)
        if remaining < 0 then remaining = 0 end
        if review_count > remaining then review_count = remaining end
    end
    return {
        new = new_count,
        learning = tonumber(rows[2][1]) or 0,
        review = review_count,
    }
end

return Queue
