-- VocabDeck configuration loading helpers.
local _ = require("gettext")
local DataStorage = require("datastorage")
local koutil = require("util")
local logger = require("logger")

local Config = {}

local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/vocabdeck.koplugin/"
local CONFIG_FILE_PATH = PLUGIN_DIR .. "vocabdeck_configuration.lua"

local FALLBACK_CONFIGURATION = {
    provider = "gemini",
    provider_settings = {
        gemini = {
            visible = true,
            model = "gemini-2.5-flash",
            base_url = "https://generativelanguage.googleapis.com/v1beta/models/",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                maxOutputTokens = 1024,
            },
        },
        openai = {
            visible = true,
            model = "gpt-4o-mini",
            base_url = "https://api.openai.com/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },
        anthropic = {
            visible = true,
            model = "claude-3-5-haiku-latest",
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "",
            additional_parameters = {
                max_tokens = 1024,
                temperature = 0.3,
                anthropic_version = "2023-06-01",
            },
        },
        ollama = {
            visible = true,
            model = "llama3.1",
            base_url = "http://127.0.0.1:11434/api/chat",
            api_key = "",
            additional_parameters = {
                options = {
                    temperature = 0.3,
                    num_predict = 1024,
                },
            },
        },
    },
}

local function loadBundledDefaultConfiguration()
    local sample_path = PLUGIN_DIR .. "vocabdeck_configuration.sample.lua"
    if not koutil.pathExists(sample_path) then
        return nil
    end
    local ok, result = pcall(function() return dofile(sample_path) end)
    if not ok or type(result) ~= "table" or type(result.provider_settings) ~= "table" then
        logger.warn("vocabdeck: bundled default configuration load failed:", result)
        return nil
    end
    result.provider = "gemini"
    for _, settings_table in pairs(result.provider_settings) do
        if type(settings_table) == "table" then
            settings_table.visible = true
        end
    end
    return result
end

local function loadConfigurationFile()
    if not koutil.pathExists(CONFIG_FILE_PATH) then
        return nil, nil
    end
    local ok, result = pcall(function() return dofile(CONFIG_FILE_PATH) end)
    if not ok then
        logger.warn("vocabdeck: configuration load failed:", result)
        return nil, tostring(result)
    end
    if type(result) ~= "table" then
        return nil, _("vocabdeck_configuration.lua did not return a table.")
    end
    return result, nil
end

local function mergeDefaultProviders(config, default_config)
    if type(config) ~= "table" or type(default_config.provider_settings) ~= "table" then
        return
    end
    if type(config.provider_settings) ~= "table" then
        config.provider_settings = {}
    end
    for name, settings_table in pairs(default_config.provider_settings) do
        if config.provider_settings[name] == nil then
            config.provider_settings[name] = settings_table
        end
    end
end

function Config.load()
    local default_config = loadBundledDefaultConfiguration() or FALLBACK_CONFIGURATION
    local configuration, config_error = loadConfigurationFile()
    if not configuration then
        configuration = default_config
    else
        mergeDefaultProviders(configuration, default_config)
    end
    return configuration, config_error
end

return Config
