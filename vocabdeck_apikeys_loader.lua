-- VocabDeck API key loader.
--
-- Keeps credentials separate from provider defaults. Reads optional
-- `vocabdeck_apikeys.lua` from this plugin folder.
local DataStorage = require("datastorage")
local logger = require("logger")

local ApiKeys = {}

local PLUGIN_DIR = DataStorage:getDataDir() .. "/plugins/vocabdeck.koplugin/"
local API_KEYS_FILE = PLUGIN_DIR .. "vocabdeck_apikeys.lua"

local loaded = false
local keys = {}

local function load()
    if loaded then return end
    loaded = true
    local file = io.open(API_KEYS_FILE, "r")
    if not file then
        keys = {}
        return
    end
    file:close()

    local ok, result = pcall(function() return dofile(API_KEYS_FILE) end)
    if not ok then
        logger.warn("vocabdeck: vocabdeck_apikeys.lua load failed:", result)
        keys = {}
        return
    end
    keys = type(result) == "table" and result or {}
end

function ApiKeys.get(provider)
    load()
    local key = keys[provider]
    if type(key) == "string" and key ~= "" then
        return key
    end
    local alias = type(provider) == "string" and provider:match("^%w+_(.+)$")
    key = alias and keys[alias]
    if type(key) == "string" and key ~= "" then
        return key
    end
    return nil
end

function ApiKeys.has(provider)
    return ApiKeys.get(provider) ~= nil
end

function ApiKeys.path()
    return API_KEYS_FILE
end

return ApiKeys
