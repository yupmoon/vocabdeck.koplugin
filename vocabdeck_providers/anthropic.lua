-- Anthropic Messages API handler for VocabDeck.
-- Ported from assistant.koplugin/api_handlers/anthropic.lua. The streaming
-- branch has been removed because VocabDeck always fetches a single JSON
-- response through Trapper-backed makeRequest.
local BaseHandler = require("vocabdeck_providers.base")
local json = require("json")
local koutil = require("util")
local logger = require("logger")

local AnthropicHandler = BaseHandler:new()

-- Split the VocabDeck conversation into the shape Anthropic expects:
-- a top-level `system` string plus a list of user/assistant messages.
local function prepare_anthropic_messages(message_history)
    local anthropic_messages = {}
    local system_content = ""

    for _, msg in ipairs(message_history) do
        if msg.role == "system" then
            system_content = system_content .. msg.content .. "\n\n"
        end
    end
    system_content = system_content:gsub("\n\n$", "")

    for _, msg in ipairs(message_history) do
        if msg.role ~= "system" then
            table.insert(anthropic_messages, {
                role = msg.role,
                content = msg.content,
            })
        end
    end

    return {
        messages = anthropic_messages,
        system = system_content,
    }
end

-- Anthropic returns an array of typed content blocks; only "text" blocks are
-- relevant for VocabDeck.
local function extract_text_from_content(content_blocks)
    if type(content_blocks) ~= "table" then
        return nil
    end
    local text_chunks = {}
    for _, block in ipairs(content_blocks) do
        if type(block) == "table" and block.type == "text" and type(block.text) == "string" then
            table.insert(text_chunks, block.text)
        end
    end
    if #text_chunks > 0 then
        return table.concat(text_chunks, "\n\n")
    end
end

function AnthropicHandler:query(message_history, anthropic_settings)
    local body_table = prepare_anthropic_messages(message_history)
    body_table.model = anthropic_settings.model
    body_table.max_tokens = koutil.tableGetValue(anthropic_settings, "additional_parameters", "max_tokens") or 1024
    body_table.stream = false

    local temperature = koutil.tableGetValue(anthropic_settings, "additional_parameters", "temperature")
    if temperature ~= nil then
        body_table.temperature = temperature
    end

    local tools = koutil.tableGetValue(anthropic_settings, "additional_parameters", "tools")
    if type(tools) == "table" and next(tools) ~= nil then
        body_table.tools = tools
    end

    local request_body = json.encode(body_table)
    local headers = {
        ["Content-Type"] = "application/json",
        ["x-api-key"] = anthropic_settings.api_key,
        ["anthropic-version"] = koutil.tableGetValue(anthropic_settings, "additional_parameters", "anthropic_version")
            or "2023-06-01",
    }

    local success, code, response = self:makeRequest(anthropic_settings.base_url, headers, request_body)
    if not success then
        if code == BaseHandler.CODE_CANCELLED then
            return nil, response
        end
        return nil, "Error: Failed to connect to Anthropic API - " .. tostring(response)
    end

    local ok, parsed = pcall(json.decode, response)
    if not ok or type(parsed) ~= "table" then
        logger.warn("vocabdeck Anthropic JSON decode error", parsed)
        return nil, "Error: Failed to parse Anthropic API response"
    end

    local content = extract_text_from_content(parsed.content)
    if type(content) ~= "string" or #content == 0 then
        content = koutil.tableGetValue(parsed, "content", 1, "text")
    end
    if type(content) == "string" and #content > 0 then
        return content
    end

    local err_msg = koutil.tableGetValue(parsed, "error", "message")
    if err_msg then
        return nil, err_msg
    end
    logger.warn("vocabdeck Anthropic unexpected response", code, response)
    return nil, "Error: Unexpected response format from Anthropic API"
end

return AnthropicHandler
