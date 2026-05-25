-- Ollama native /api/chat handler for VocabDeck.
-- Ported from assistant.koplugin/api_handlers/ollama.lua. The streaming
-- branch has been removed because VocabDeck always fetches a single JSON
-- response through Trapper-backed makeRequest.
--
-- Note: this targets Ollama's *native* chat endpoint which returns the
-- assistant reply under `message.content`. If you want to hit the
-- OpenAI-compatible `/v1/chat/completions` endpoint on an Ollama server,
-- use the `openai` handler with base_url pointing at that path instead.
local BaseHandler = require("vocabdeck_providers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OllamaHandler = BaseHandler:new()

function OllamaHandler:query(message_history, ollama_settings)
    local required = { "base_url", "model" }
    for _, setting in ipairs(required) do
        if not ollama_settings[setting] then
            return nil, "Error: Missing " .. setting .. " in configuration"
        end
    end

    local body_table = {
        model = ollama_settings.model,
        messages = message_history,
        stream = false,
    }

    -- Optional Ollama-style generation options (temperature, num_predict, …).
    local options = koutil.tableGetValue(ollama_settings, "additional_parameters", "options")
    if type(options) == "table" and next(options) ~= nil then
        body_table.options = options
    end

    local request_body = json.encode(body_table)
    local headers = {
        ["Content-Type"] = "application/json",
    }
    if ollama_settings.api_key and ollama_settings.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. ollama_settings.api_key
    end

    local success, code, response = self:makeRequest(ollama_settings.base_url, headers, request_body)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Ollama API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or type(parsed) ~= "table" then
        logger.warn("vocabdeck Ollama JSON decode error", parsed)
        return nil, "Error: Failed to parse Ollama API response"
    end

    local content = koutil.tableGetValue(parsed, "message", "content")
    if content and content ~= "" then
        return content
    end

    local err_msg = koutil.tableGetValue(parsed, "error")
    if type(err_msg) == "string" and err_msg ~= "" then
        return nil, err_msg
    end
    logger.warn("vocabdeck Ollama unexpected response", code, response)
    return nil, "Error: Unexpected response format from Ollama API"
end

return OllamaHandler
