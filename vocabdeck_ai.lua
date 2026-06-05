-- VocabDeck querier: thin wrapper over vocabdeck_providers/* handlers.
--
-- Dispatch logic mirrors the AI Assistant plugin:
--   provider name "openai_grok" -> loads vocabdeck_providers/openai
--   provider name "openai"      -> loads vocabdeck_providers/openai
-- The bit before the first underscore selects the handler file.
local _ = require("gettext")
local koutil = require("util")
local logger = require("logger")
local ApiKeys = require("vocabdeck_apikeys_loader")

local Querier = {
    plugin = nil,
    handler = nil,
    handler_name = nil,
    provider_settings = nil,
    provider_name = nil,
    _loading = false,  -- re-entrancy guard for coroutine interleaving
}

local function copyTable(tbl)
    local out = {}
    if type(tbl) ~= "table" then return out end
    for key, value in pairs(tbl) do
        if type(value) == "table" then
            out[key] = copyTable(value)
        else
            out[key] = value
        end
    end
    return out
end

function Querier:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    return o
end

function Querier:isInited()
    return self.handler ~= nil
end

function Querier:loadProvider(provider_name)
    if provider_name == self.provider_name and self:isInited() then
        return true
    end
    -- Guard against re-entrant calls from coroutine yields (e.g., Trapper:wrap).
    -- KOReader is single-threaded but coroutines can interleave during I/O,
    -- so a second caller could enter loadProvider before the first finishes,
    -- corrupting the shared handler/provider_name state.
    if self._loading then
        return false, _("AI provider is already being loaded. Please wait.")
    end
    self._loading = true
    -- Wrap body in pcall so _loading is always reset, even if an unexpected
    -- error (e.g. metatable traps in copyTable) throws mid-function.
    local ok, result, err_msg = pcall(function()
        local config = self.plugin and self.plugin.CONFIGURATION
        if not config then
            return false, _("VocabDeck configuration file is not loaded.")
        end
        local raw_provider_settings = koutil.tableGetValue(config, "provider_settings", provider_name)
        if not raw_provider_settings then
            return false, string.format(
                _("Provider settings not found for: %s. Check vocabdeck_configuration.lua."),
                tostring(provider_name)
            )
        end
        local provider_settings = copyTable(raw_provider_settings)

        local settings = self.plugin and self.plugin.settings
        if settings then
            local saved_model = settings:readSetting("model_" .. provider_name)
            if saved_model and saved_model ~= "" then
                provider_settings.model = saved_model
            end
            local saved_api_key = settings:readSetting("api_key_" .. provider_name)
            if saved_api_key and saved_api_key ~= "" then
                provider_settings.api_key = saved_api_key
            end
        end
        local file_api_key = ApiKeys.get(provider_name)
        if file_api_key then
            provider_settings.api_key = file_api_key
        end

        local handler_name = provider_settings.handler
        if not handler_name or handler_name == "" then
            local underscore_pos = provider_name:find("_")
            if underscore_pos and underscore_pos > 0 then
                handler_name = provider_name:sub(1, underscore_pos - 1)
            else
                handler_name = provider_name
            end
        end

        local ok2, handler = pcall(function()
            return require("vocabdeck_providers." .. handler_name)
        end)
        if not ok2 then
            local err = string.format(
                _("The handler for %s was not found in vocabdeck_providers/."),
                handler_name
            )
            logger.warn("vocabdeck: " .. err)
            return false, err
        end

        self.handler = handler
        self.handler_name = handler_name
        self.provider_settings = provider_settings
        self.provider_name = provider_name
        return true
    end)
    self._loading = false
    if not ok then
        logger.warn("vocabdeck: loadProvider panicked: " .. tostring(result))
        return false, tostring(result)
    end
    return result, err_msg
end

function Querier:getModel()
    return koutil.tableGetValue(self.provider_settings or {}, "model")
end

-- Perform a single chat completion request.
-- @param messages  list of {role=..., content=...}
-- @param trap_widget optional widget used for cancellation (Trapper).
-- @return string|nil response, string|nil error
function Querier:query(messages, trap_widget)
    if not self:isInited() then
        return nil, _("VocabDeck AI provider is not configured.")
    end
    if trap_widget then
        self.handler:setTrapWidget(trap_widget)
    end
    local response, err = self.handler:query(messages, self.provider_settings)
    if trap_widget then
        self.handler:resetTrapWidget()
    end
    return response, err
end

-- Shared message-pair builder used by all AI callers (enrich, memory_helper,
-- grammar). Keeps the {role="system",...},{role="user",...} shape in one place.
function Querier.buildMessages(system_content, user_content)
    return {
        { role = "system", content = system_content },
        { role = "user",   content = user_content   },
    }
end

return Querier
