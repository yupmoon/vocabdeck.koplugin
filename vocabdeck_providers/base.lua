-- VocabDeck base HTTP handler.
--
-- Minimal HTTP POST helper reused by all provider-specific handlers. Modeled
-- after the assistant.koplugin `api_handlers/base.lua`, but stripped of
-- streaming because VocabDeck only needs small synchronous JSON requests.
-- When a trap widget is supplied, the request runs in KOReader's cancellable
-- subprocess wrapper so the UI can remain responsive.
local logger = require("logger")
local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local Trapper = require("ui/trapper")

local BaseHandler = {
    trap_widget = nil,
}

BaseHandler.CODE_CANCELLED = "USER_CANCELED"
BaseHandler.CODE_NETWORK_ERROR = "NETWORK_ERROR"

function BaseHandler:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function BaseHandler:setTrapWidget(trap_widget)
    self.trap_widget = trap_widget
end

function BaseHandler:resetTrapWidget()
    self.trap_widget = nil
end

-- Must be implemented by concrete handlers.
-- @param message_history table list of {role, content}
-- @param provider_setting table provider-specific config
-- @return string|nil response, string|nil error
function BaseHandler:query(message_history, provider_setting)
    error("query method must be implemented")
end

local function postURLContent(url, headers, body, timeout, maxtime)
    local sink = {}
    socketutil:set_timeout(timeout, maxtime)
    local request = {
        url = url,
        method = "POST",
        headers = headers or {},
        source = ltn12.source.string(body or ""),
        sink = maxtime and socketutil.table_sink(sink) or ltn12.sink.table(sink),
    }
    local code, response_headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local content = table.concat(sink)

    if code == socketutil.TIMEOUT_CODE
        or code == socketutil.SSL_HANDSHAKE_CODE
        or code == socketutil.SINK_TIMEOUT_CODE then
        logger.warn("vocabdeck: request timed out", code)
        return false, code, "Request interrupted/timed out"
    end

    if response_headers == nil then
        logger.warn("vocabdeck: no HTTP headers", status or code or "network unreachable")
        return false, BaseHandler.CODE_NETWORK_ERROR, "Network Error: " .. tostring(status or code)
    end

    if response_headers["content-length"] then
        local content_length = tonumber(response_headers["content-length"])
        if content_length and #content ~= content_length then
            return false, code, "Incomplete content received"
        end
    end
    return true, code, content
end

function BaseHandler:makeRequest(url, headers, body, timeout, maxtime)
    local completed, success, code, content
    -- Unified defaults: 60s per-byte idle timeout, 120s total wall-clock.
    -- AI API calls on an e-ink Kindle are slow (WiFi wake-up, CPU-bound JSON
    -- parsing, large model responses).  30/90 was too tight for the non-Trapper
    -- fallback path, creating an inconsistency that could confuse debugging.
    local request_timeout = timeout or 60
    local request_maxtime = maxtime or 120
    if self.trap_widget then
        completed, success, code, content = Trapper:dismissableRunInSubprocess(function()
            return postURLContent(url, headers, body, request_timeout, request_maxtime)
        end, self.trap_widget)
        if not completed then
            return false, self.CODE_CANCELLED, self.CODE_CANCELLED
        end
    else
        success, code, content = postURLContent(url, headers, body, request_timeout, request_maxtime)
    end
    return success, code, content
end

return BaseHandler
