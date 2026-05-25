-- OpenAI-compatible chat completions handler for VocabDeck.
local BaseHandler = require("vocabdeck_providers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local OpenAIHandler = BaseHandler:new()

function OpenAIHandler:query(message_history, openai_settings)
    local body_table = {
        model = openai_settings.model,
        messages = message_history,
        max_tokens = koutil.tableGetValue(openai_settings, "additional_parameters", "max_tokens") or 1024,
        temperature = koutil.tableGetValue(openai_settings, "additional_parameters", "temperature") or 0.3,
        stream = false,
    }
    -- Copy any additional fields the user supplied.
    local additional = openai_settings.additional_parameters or {}
    for key, value in pairs(additional) do
        if body_table[key] == nil and key ~= "stream" then
            body_table[key] = value
        end
    end

    local request_body = json.encode(body_table)
    local headers = {
        ["Content-Type"] = "application/json",
        ["Authorization"] = "Bearer " .. (openai_settings.api_key or ""),
    }

    local success, code, response = self:makeRequest(openai_settings.base_url, headers, request_body)
    if success then
        local ok, parsed = pcall(json.decode, response)
        if ok then
            local content = koutil.tableGetValue(parsed, "choices", 1, "message", "content")
            if content then return content end
            local err_msg = koutil.tableGetValue(parsed, "error", "message")
            if err_msg then return nil, err_msg end
        end
        logger.warn("vocabdeck OpenAI error", code, response)
    end

    if code == BaseHandler.CODE_CANCELLED then
        return nil, response
    end
    return nil, "Error: " .. tostring(code or "unknown") .. " - " .. tostring(response or "")
end

return OpenAIHandler
