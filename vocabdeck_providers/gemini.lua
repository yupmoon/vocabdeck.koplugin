-- Google Gemini API handler for VocabDeck.
-- Ported from assistant.koplugin/api_handlers/gemini.lua. The streaming
-- branch has been removed because VocabDeck always fetches a single JSON
-- response through Trapper-backed makeRequest.
local BaseHandler = require("vocabdeck_providers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local GeminiHandler = BaseHandler:new()

-- Default safety settings disable Gemini's content filters so VocabDeck can
-- fetch definitions for any phrase the user selects.
local DEFAULT_SAFETY_SETTINGS = {
    { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
    { category = "HARM_CATEGORY_HATE_SPEECH",       threshold = "BLOCK_NONE" },
    { category = "HARM_CATEGORY_HARASSMENT",        threshold = "BLOCK_NONE" },
    { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
}

function GeminiHandler:query(message_history, gemini_settings)
    if not gemini_settings or not gemini_settings.api_key then
        return nil, "Error: Missing API key in configuration"
    end

    -- Gemini separates the system prompt from the conversation and expects
    -- each turn as a `{ role, parts = {{ text }} }` object.
    local contents = {}
    local system_content = ""
    local generation_config

    for _, msg in ipairs(message_history) do
        if msg.role == "system" then
            system_content = system_content .. msg.content .. "\n"
        elseif msg.role == "user" then
            table.insert(contents, { role = "user",  parts = {{ text = msg.content }} })
        elseif msg.role == "assistant" then
            table.insert(contents, { role = "model", parts = {{ text = msg.content }} })
        else
            table.insert(contents, { role = "user",  parts = {{ text = msg.content }} })
        end
    end

    local system_instruction
    if system_content ~= "" then
        system_instruction = { parts = {{ text = system_content:gsub("\n$", "") }} }
    end

    local additional = gemini_settings.additional_parameters or {}

    local thinking_budget = additional.thinking_budget
    if thinking_budget ~= nil then
        generation_config = generation_config or {}
        generation_config.thinking_config = { thinking_budget = thinking_budget }
    end

    for _, option in ipairs({ "maxOutputTokens", "temperature", "topP", "topK" }) do
        if additional[option] ~= nil then
            generation_config = generation_config or {}
            generation_config[option] = additional[option]
        end
    end

    local body_table = {
        contents = contents,
        system_instruction = system_instruction,
        safetySettings = DEFAULT_SAFETY_SETTINGS,
        generationConfig = generation_config,
    }

    local request_body = json.encode(body_table)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-goog-api-key"] = gemini_settings.api_key,
    }

    local model = gemini_settings.model or "gemini-2.0-flash"
    local base_url = gemini_settings.base_url or "https://generativelanguage.googleapis.com/v1beta/models/"
    local url = string.format("%s%s:generateContent", base_url, model)

    local success, code, response = self:makeRequest(url, headers, request_body)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        logger.warn("vocabdeck Gemini request failed", code, response)
        return nil, "Error: Failed to connect to Gemini API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or type(parsed) ~= "table" then
        logger.warn("vocabdeck Gemini JSON decode error", parsed)
        return nil, "Error: Failed to parse Gemini API response"
    end

    local content = koutil.tableGetValue(parsed, "candidates", 1, "content", "parts", 1, "text")
    if content then return content end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    end
    logger.warn("vocabdeck Gemini unexpected response", code, response)
    return nil, "Error: Unexpected response format from Gemini API"
end

return GeminiHandler
