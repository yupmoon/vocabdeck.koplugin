-- Shared text-normalization utilities.
--
-- Used wherever Lua strings need whitespace trimming, newline normalization,
-- or blank-line collapsing. Centralised to avoid the ubiquitous
-- :gsub("^%s+", ""):gsub("%s+$", "") pattern duplicated across the codebase.
local TextUtils = {}

--- Trim leading and trailing whitespace from a string.
function TextUtils.trim(s)
    if type(s) ~= "string" then return "" end
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Normalize line endings to LF and collapse 3+ blank lines to 2.
function TextUtils.normalizeNewlines(s)
    if type(s) ~= "string" then return "" end
    s = s:gsub("\r\n", "\n"):gsub("\r", "\n")
    return s:gsub("\n\n\n+", "\n\n")
end

--- Collapse multiple consecutive spaces/tabs to a single space.
function TextUtils.collapseSpaces(s)
    if type(s) ~= "string" then return "" end
    return s:gsub("[ \t]+", " ")
end

return TextUtils
