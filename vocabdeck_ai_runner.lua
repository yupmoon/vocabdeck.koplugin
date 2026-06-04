-- Shared AI-fetch workflow for VocabDeck.
--
-- Extracts the common "ensure AI provider → check network → Trapper wrap →
-- show InfoMessage → do work → handle result" pattern that was duplicated
-- across 5+ callers.
--
-- Usage:
--   local AIRunner = require("vocabdeck_ai_runner")
--   AIRunner.run(plugin, {
--       message = _("Fetching AI data for:\n%s"),   -- format string with %s for phrase
--       phrase  = card.phrase,
--       work    = function(trap) ... end,            -- the AI work, called inside Trapper
--       on_success = function(result) ... end,       -- optional, called on success
--       on_error   = function(err) ... end,          -- optional, called on error
--       on_finally = function() ... end,             -- optional, always called
--   })

local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")
local _ = require("gettext")

local AIRunner = {}

local function classifyError(err)
    local raw = tostring(err or "")
    local lower = raw:lower()
    local title
    local hint

    if raw == "NETWORK_ERROR" or lower:find("network error", 1, true)
        or lower:find("failed to connect", 1, true)
        or lower:find("host not found", 1, true) then
        title = _("Network connection failed.")
        hint = _("Check Wi-Fi and the provider base URL.")
    elseif lower:find("timed out", 1, true) or lower:find("timeout", 1, true)
        or lower:find("interrupted", 1, true) then
        title = _("AI request timed out.")
        hint = _("Try again, or choose a smaller/faster model.")
    elseif lower:find("missing api key", 1, true) or lower:find("missing key", 1, true) then
        title = _("AI API key is missing.")
        hint = _("Add an API key in VocabDeck settings or configuration.")
    elseif raw:find("401", 1, true) or raw:find("403", 1, true)
        or lower:find("unauthorized", 1, true)
        or lower:find("forbidden", 1, true)
        or lower:find("invalid api key", 1, true) then
        title = _("AI authentication failed.")
        hint = _("Check the selected provider and API key.")
    elseif raw:find("429", 1, true) or lower:find("rate limit", 1, true)
        or lower:find("quota", 1, true) then
        title = _("AI provider rate limit reached.")
        hint = _("Wait a moment, then try again.")
    elseif lower:find("parse", 1, true) or lower:find("invalid json", 1, true)
        or lower:find("unexpected response", 1, true) then
        title = _("AI response could not be read.")
        hint = _("Try again, or use another model/provider.")
    else
        title = _("AI fetch failed.")
    end

    if hint then
        return string.format("%s\n%s\n\n%s", title, hint, raw)
    end
    return string.format("%s\n%s", title, raw)
end

function AIRunner.formatError(err)
    return classifyError(err)
end

-- Ensure the AI provider is loaded. Returns true on success, or shows an
-- error message and returns false + the error string.
local function ensureProvider(plugin)
    if not plugin or not plugin.ensureAIProviderLoaded then
        UIManager:show(InfoMessage:new{
            text = _("AI fetch failed:\nVocabDeck AI provider is not configured."),
            timeout = 4,
        })
        return false, _("VocabDeck AI provider is not configured.")
    end
    local ok, err = plugin:ensureAIProviderLoaded()
    if not ok then
        UIManager:show(InfoMessage:new{
            text = classifyError(err or _("VocabDeck AI provider is not configured.")),
            timeout = 4,
        })
        return false, err
    end
    return true
end

-- Run an AI-fetch workflow with the common boilerplate.
-- @param plugin  VocabDeck plugin instance
-- @param opts    table with:
--   message   - string with one %s placeholder for the phrase (or plain string)
--   phrase    - string to fill into message
--   work      - function(trap_widget) called inside Trapper:wrap; return (result, err)
--               where err == "USER_CANCELED" means the user tapped outside.
--   on_success - optional function(result) called when work returns a truthy result
--   on_error  - optional function(err) called when work returns nil + error
--   on_finally - optional function() called after everything (success, error, or cancel)
function AIRunner.run(plugin, opts)
    if not opts or not opts.work then return end

    local ok = ensureProvider(plugin)
    if not ok then
        if opts.on_finally then opts.on_finally() end
        return
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            local cancelled = false
            local trap_text = opts.message
            if opts.phrase then
                trap_text = string.format(opts.message or "", opts.phrase)
            end
            local trap = InfoMessage:new{
                text = trap_text,
                timeout = nil,
                show_icon = false,
            }
            trap.dismiss_callback = function()
                cancelled = true
            end
            UIManager:show(trap)
            -- Use targeted refresh instead of full-screen flash on e-ink.
            UIManager:setDirty(trap, "ui")

            if cancelled then
                UIManager:close(trap)
                if opts.on_finally then opts.on_finally() end
                return
            end

            local result, err = opts.work(trap)

            trap.dismiss_callback = nil
            UIManager:close(trap)

            if err == "USER_CANCELED" then
                -- Quiet cancel: the tap outside was intentional.
                if opts.on_finally then opts.on_finally() end
                return
            end

            if result then
                if opts.on_success then opts.on_success(result) end
            else
                if opts.on_error then
                    opts.on_error(err or _("Unknown error"))
                else
                    UIManager:show(InfoMessage:new{
                        text = classifyError(err or _("Unknown error")),
                        timeout = 4,
                    })
                end
            end

            if opts.on_finally then opts.on_finally() end
        end)
    end)
end

return AIRunner
