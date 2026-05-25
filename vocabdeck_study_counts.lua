-- VocabDeck Study queue counts.
--
-- Builds small, deck-aware count queries for Study mode. The DB module owns
-- connections; this module owns the queue-count definition.

local Counts = {}

function Counts.getStudyQueueCounts(conn, opts)
    opts = opts or {}
    local book_filter = opts.book_id and string.format(" AND book_id = %d", tonumber(opts.book_id) or 0) or ""
    local source_filter = opts.source_filter or ""
    local enriched_filter = opts.enriched_filter or ""
    local now = tonumber(opts.now) or os.time()
    local sql = string.format([[SELECT
        COALESCE(SUM(CASE WHEN review_count = 0 THEN 1 ELSE 0 END), 0) AS new_count,
        COALESCE(SUM(CASE WHEN review_count > 0 AND fsrs_state IN (1, 3) THEN 1 ELSE 0 END), 0) AS learning_count,
        COALESCE(SUM(CASE WHEN review_count > 0 AND fsrs_state = 2 THEN 1 ELSE 0 END), 0) AS review_count
        FROM cards
        WHERE suspended = 0 AND due <= %d%s%s%s;]],
        now, book_filter, source_filter, enriched_filter)
    local stmt = conn:prepare(sql)
    local rows = stmt:resultset("hik")
    stmt:close()
    if not rows or not rows[1] or not rows[1][1] then
        return { new = 0, learning = 0, review = 0 }
    end
    return {
        new = tonumber(rows[1][1]) or 0,
        learning = tonumber(rows[2][1]) or 0,
        review = tonumber(rows[3][1]) or 0,
    }
end

return Counts
