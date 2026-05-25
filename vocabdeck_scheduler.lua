-- VocabDeck scheduling module.
--
-- Pure FSRS-style scheduling math used by the database layer and Study UI.
-- It does not open the database or touch widgets.

local Scheduler = {}

Scheduler.STATE_LEARNING = 1
Scheduler.STATE_REVIEW = 2
Scheduler.STATE_RELEARNING = 3

local REVIEW_DAY_START_HOUR = 4
local FSRS_MIN_DIFFICULTY = 1
local FSRS_MAX_DIFFICULTY = 10
local FSRS_STABILITY_MIN = 0.001
local FSRS_DEFAULT_DESIRED_RETENTION = 0.9
local FSRS_MAXIMUM_INTERVAL = 36500
local FSRS_LEARNING_STEPS = { 60, 10 * 60 }
local FSRS_RELEARNING_STEPS = { 10 * 60 }
local FSRS_PARAMETERS = {
    0.212, 1.2931, 2.3065, 8.2956, 6.4133, 0.8334, 3.0194,
    0.001, 1.8722, 0.1666, 0.796, 1.4835, 0.0614, 0.2629,
    1.6483, 0.6014, 1.8729, 0.5425, 0.0912, 0.0658, 0.1542,
}

local FSRS_DECAY = -FSRS_PARAMETERS[21]
local FSRS_FACTOR = (0.9 ^ (1 / FSRS_DECAY)) - 1

local function clamp(value, min_value, max_value)
    if value < min_value then return min_value end
    if value > max_value then return max_value end
    return value
end

local function round(value)
    return math.floor(value + 0.5)
end

local function normalizeRetention(desired_retention)
    desired_retention = tonumber(desired_retention) or FSRS_DEFAULT_DESIRED_RETENTION
    return clamp(desired_retention, 0.7, 0.97)
end

function Scheduler.nextReviewDayStart(now)
    now = now or os.time()
    local today = os.date("*t", now)
    today.hour = REVIEW_DAY_START_HOUR
    today.min = 0
    today.sec = 0
    local today_start = os.time(today)
    return now < today_start and today_start or today_start + 86400
end

function Scheduler.reviewDayBoundary(now, interval_days)
    interval_days = math.max(tonumber(interval_days) or 1, 1)
    return Scheduler.nextReviewDayStart(now) + (interval_days - 1) * 86400
end

local function initialStability(rating_value)
    return math.max(FSRS_STABILITY_MIN, FSRS_PARAMETERS[rating_value] or FSRS_PARAMETERS[3])
end

local function initialDifficulty(rating_value, should_clamp)
    local difficulty = FSRS_PARAMETERS[5] - (math.exp(FSRS_PARAMETERS[6] * (rating_value - 1))) + 1
    if should_clamp then
        difficulty = clamp(difficulty, FSRS_MIN_DIFFICULTY, FSRS_MAX_DIFFICULTY)
    end
    return difficulty
end

local function nextDifficulty(difficulty, rating_value)
    local easy_initial = initialDifficulty(4, false)
    local delta = -(FSRS_PARAMETERS[7] * (rating_value - 3))
    local damped = (FSRS_MAX_DIFFICULTY - difficulty) * delta / 9
    local mean_reverted = FSRS_PARAMETERS[8] * easy_initial + (1 - FSRS_PARAMETERS[8]) * (difficulty + damped)
    return clamp(mean_reverted, FSRS_MIN_DIFFICULTY, FSRS_MAX_DIFFICULTY)
end

local function nextInterval(stability, desired_retention)
    desired_retention = normalizeRetention(desired_retention)
    local interval = (stability / FSRS_FACTOR) * ((desired_retention ^ (1 / FSRS_DECAY)) - 1)
    interval = round(interval)
    interval = math.max(interval, 1)
    return math.min(interval, FSRS_MAXIMUM_INTERVAL)
end

local function retrievability(card, now)
    local stability = tonumber(card.fsrs_stability) or 0
    local last_review = tonumber(card.last_review)
    if not last_review or stability <= 0 then
        return 0
    end
    local elapsed_days = math.max(0, math.floor((now - last_review) / 86400))
    return (1 + FSRS_FACTOR * elapsed_days / stability) ^ FSRS_DECAY
end

local function shortTermStability(stability, rating_value)
    local increase = math.exp(FSRS_PARAMETERS[18] * (rating_value - 3 + FSRS_PARAMETERS[19]))
        * (stability ^ -FSRS_PARAMETERS[20])
    if rating_value >= 3 then
        increase = math.max(increase, 1)
    end
    return math.max(FSRS_STABILITY_MIN, stability * increase)
end

local function nextForgetStability(difficulty, stability, r)
    local long_term = FSRS_PARAMETERS[12]
        * (difficulty ^ -FSRS_PARAMETERS[13])
        * (((stability + 1) ^ FSRS_PARAMETERS[14]) - 1)
        * math.exp((1 - r) * FSRS_PARAMETERS[15])
    local short_term = stability / math.exp(FSRS_PARAMETERS[18] * FSRS_PARAMETERS[19])
    return math.min(long_term, short_term)
end

local function nextRecallStability(difficulty, stability, r, rating_value)
    local hard_penalty = rating_value == 2 and FSRS_PARAMETERS[16] or 1
    local easy_bonus = rating_value == 4 and FSRS_PARAMETERS[17] or 1
    return stability * (
        1
        + math.exp(FSRS_PARAMETERS[9])
        * (11 - difficulty)
        * (stability ^ -FSRS_PARAMETERS[10])
        * (math.exp((1 - r) * FSRS_PARAMETERS[11]) - 1)
        * hard_penalty
        * easy_bonus
    )
end

local function nextStability(difficulty, stability, r, rating_value)
    local stability_next
    if rating_value == 1 then
        stability_next = nextForgetStability(difficulty, stability, r)
    else
        stability_next = nextRecallStability(difficulty, stability, r, rating_value)
    end
    return math.max(FSRS_STABILITY_MIN, stability_next)
end

local function ratingValue(rating)
    if rating == "again" then return 1 end
    if rating == "hard" then return 2 end
    if rating == "easy" then return 4 end
    return 3
end

local function stepSeconds(steps, step)
    return steps[(step or 0) + 1]
end

local function normalizeFsrsState(card)
    local state = tonumber(card.fsrs_state) or Scheduler.STATE_LEARNING
    local step = tonumber(card.fsrs_step) or 0
    local stability = tonumber(card.fsrs_stability) or 0
    local difficulty = tonumber(card.fsrs_difficulty) or 0

    if difficulty <= 0 then
        difficulty = initialDifficulty(3, true)
    end
    if state ~= Scheduler.STATE_LEARNING
        and state ~= Scheduler.STATE_REVIEW
        and state ~= Scheduler.STATE_RELEARNING then
        state = Scheduler.STATE_LEARNING
    end
    if state == Scheduler.STATE_REVIEW then
        step = 0
    end
    return state, step, stability, difficulty
end

local function computeRaw(card, rating, now_ts, desired_retention)
    local review_count = card.review_count or 0
    local lapse_count = card.lapse_count or 0
    local now = now_ts or os.time()
    local rating_value = ratingValue(rating)
    local state, step, stability, difficulty = normalizeFsrsState(card)
    local last_review = tonumber(card.last_review)
    local days_since_last_review = last_review and math.floor((now - last_review) / 86400) or nil

    if stability <= 0 then
        stability = initialStability(rating_value)
        difficulty = initialDifficulty(rating_value, true)
    elseif days_since_last_review and days_since_last_review < 1 then
        stability = shortTermStability(stability, rating_value)
        difficulty = nextDifficulty(difficulty, rating_value)
    else
        stability = nextStability(difficulty, stability, retrievability(card, now), rating_value)
        difficulty = nextDifficulty(difficulty, rating_value)
    end

    review_count = review_count + 1
    if rating_value == 1 then
        lapse_count = lapse_count + 1
    end

    local due
    local interval = 0

    if state == Scheduler.STATE_LEARNING then
        if rating_value == 1 then
            step = 0
            due = now + stepSeconds(FSRS_LEARNING_STEPS, step)
        elseif rating_value == 2 then
            if step == 0 and #FSRS_LEARNING_STEPS == 1 then
                due = now + FSRS_LEARNING_STEPS[1] * 1.5
            elseif step == 0 and #FSRS_LEARNING_STEPS >= 2 then
                due = now + math.floor((FSRS_LEARNING_STEPS[1] + FSRS_LEARNING_STEPS[2]) / 2)
            else
                due = now + (stepSeconds(FSRS_LEARNING_STEPS, step) or FSRS_LEARNING_STEPS[#FSRS_LEARNING_STEPS])
            end
        elseif rating_value == 3 then
            if step + 1 >= #FSRS_LEARNING_STEPS then
                state = Scheduler.STATE_REVIEW
                step = 0
                interval = nextInterval(stability, desired_retention)
                due = Scheduler.reviewDayBoundary(now, interval)
            else
                step = step + 1
                due = now + stepSeconds(FSRS_LEARNING_STEPS, step)
            end
        else
            state = Scheduler.STATE_REVIEW
            step = 0
            interval = math.max(nextInterval(stability, desired_retention), 3)
            due = Scheduler.reviewDayBoundary(now, interval)
        end
    elseif state == Scheduler.STATE_REVIEW then
        if rating_value == 1 and #FSRS_RELEARNING_STEPS > 0 then
            state = Scheduler.STATE_RELEARNING
            step = 0
            due = now + stepSeconds(FSRS_RELEARNING_STEPS, step)
        else
            interval = nextInterval(stability, desired_retention)
            due = Scheduler.reviewDayBoundary(now, interval)
        end
    else
        if rating_value == 1 then
            step = 0
            due = now + stepSeconds(FSRS_RELEARNING_STEPS, step)
        elseif rating_value == 2 then
            if step == 0 and #FSRS_RELEARNING_STEPS == 1 then
                due = now + FSRS_RELEARNING_STEPS[1] * 1.5
            elseif step == 0 and #FSRS_RELEARNING_STEPS >= 2 then
                due = now + math.floor((FSRS_RELEARNING_STEPS[1] + FSRS_RELEARNING_STEPS[2]) / 2)
            else
                due = now + (stepSeconds(FSRS_RELEARNING_STEPS, step) or FSRS_RELEARNING_STEPS[#FSRS_RELEARNING_STEPS])
            end
        elseif rating_value == 3 then
            if step + 1 >= #FSRS_RELEARNING_STEPS then
                state = Scheduler.STATE_REVIEW
                step = 0
                interval = nextInterval(stability, desired_retention)
                due = Scheduler.reviewDayBoundary(now, interval)
            else
                step = step + 1
                due = now + stepSeconds(FSRS_RELEARNING_STEPS, step)
            end
        else
            state = Scheduler.STATE_REVIEW
            step = 0
            interval = math.max(nextInterval(stability, desired_retention), 3)
            due = Scheduler.reviewDayBoundary(now, interval)
        end
    end

    return interval, due, state, step, stability, difficulty, now, review_count, lapse_count
end

local function optionFromCompute(card, rating, now, desired_retention)
    local interval, due, state, step, stability, difficulty, last_review, review_count, lapse_count =
        computeRaw(card, rating, now, desired_retention)
    return {
        rating = rating,
        interval = interval,
        due = due,
        fsrs_state = state,
        fsrs_step = step,
        fsrs_stability = stability,
        fsrs_difficulty = difficulty,
        last_review = last_review,
        review_count = review_count,
        lapse_count = lapse_count,
    }
end

local function applyReviewIntervalOrdering(options, original_state, now)
    if original_state ~= Scheduler.STATE_REVIEW then return end
    local hard, good, easy = options.hard, options.good, options.easy
    if not hard or not good or not easy then return end
    if hard.fsrs_state ~= Scheduler.STATE_REVIEW
        or good.fsrs_state ~= Scheduler.STATE_REVIEW
        or easy.fsrs_state ~= Scheduler.STATE_REVIEW then
        return
    end

    hard.interval = math.max(1, tonumber(hard.interval) or 1)
    good.interval = math.max(1, tonumber(good.interval) or 1)
    easy.interval = math.max(1, tonumber(easy.interval) or 1)

    hard.interval = math.min(hard.interval, good.interval)
    if good.interval <= hard.interval then
        good.interval = hard.interval + 1
    end
    if easy.interval <= good.interval then
        easy.interval = good.interval + 1
    end

    hard.due = Scheduler.reviewDayBoundary(now, hard.interval)
    good.due = Scheduler.reviewDayBoundary(now, good.interval)
    easy.due = Scheduler.reviewDayBoundary(now, easy.interval)
end

function Scheduler.computeOptions(card, now_ts, desired_retention)
    if not card or not card.id then return nil end
    local now = now_ts or os.time()
    local original_state = normalizeFsrsState(card)
    local options = {
        again = optionFromCompute(card, "again", now, desired_retention),
        hard = optionFromCompute(card, "hard", now, desired_retention),
        good = optionFromCompute(card, "good", now, desired_retention),
        easy = optionFromCompute(card, "easy", now, desired_retention),
    }
    applyReviewIntervalOrdering(options, original_state, now)
    return options
end

function Scheduler.compute(card, rating, now_ts, desired_retention)
    local options = Scheduler.computeOptions(card, now_ts, desired_retention)
    local option = options and options[rating] or nil
    if not option then
        option = optionFromCompute(card, rating, now_ts or os.time(), desired_retention)
    end
    return option.interval, option.due, option.fsrs_state, option.fsrs_step,
        option.fsrs_stability, option.fsrs_difficulty, option.last_review,
        option.review_count, option.lapse_count
end

function Scheduler.getRetrievability(card, now_ts)
    return retrievability(card, now_ts or os.time())
end

function Scheduler.formatDelta(delta)
    if delta <= 0 then return "0m" end
    if delta < 3600 then return tostring(math.floor(delta / 60 + 0.5)) .. "m" end
    if delta < 86400 then return tostring(math.floor(delta / 3600 + 0.5)) .. "h" end
    return tostring(math.floor(delta / 86400 + 0.5)) .. "d"
end

function Scheduler.previewIntervals(card, now_ts, desired_retention)
    if not card or not card.id then return nil end
    local now = now_ts or os.time()
    local result = Scheduler.computeOptions(card, now, desired_retention) or {}
    for _, info in pairs(result) do
        info.label = Scheduler.formatDelta((info.due or now) - now)
    end
    return result
end

return Scheduler
