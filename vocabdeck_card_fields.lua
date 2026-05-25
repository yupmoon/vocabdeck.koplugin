-- Shared VocabDeck card-field visibility helpers.
--
-- Settings uses this to edit front/back visibility; Study uses it to decide
-- which fields to render on each side.
local _ = require("gettext")

local CardFields = {}

CardFields.DEFAULT_FRONT_FIELDS = {
    phrase = true,
    display_context = false,
    sentence = false,
    pronunciation = false,
    word_type = false,
    meaning = false,
    synonym = false,
    user_note = false,
}

CardFields.DEFAULT_BACK_FIELDS = {
    phrase = true,
    display_context = false,
    sentence = true,
    pronunciation = true,
    word_type = true,
    meaning = true,
    synonym = true,
    user_note = true,
}

CardFields.FIELD_LABELS = {
    { key = "phrase",          label = _("Word/Phrase") },
    { key = "pronunciation",   label = _("Pronunciation") },
    { key = "word_type",       label = _("Word type") },
    { key = "meaning",         label = _("Meaning") },
    { key = "synonym",         label = _("Synonyms") },
    { key = "sentence",        label = _("Source sentence") },
    { key = "display_context", label = _("Surrounding context") },
    { key = "user_note",       label = _("User note") },
}

function CardFields.getFieldState(plugin, side)
    local setting_key = side == "front" and "front_fields" or "back_fields"
    local defaults = side == "front" and CardFields.DEFAULT_FRONT_FIELDS or CardFields.DEFAULT_BACK_FIELDS
    local state = plugin.settings:readSetting(setting_key)
    if type(state) ~= "table" then
        state = {}
    end
    local merged = {}
    for key, default_value in pairs(defaults) do
        if state[key] == nil then
            merged[key] = default_value
        else
            merged[key] = state[key] and true or false
        end
    end
    return merged
end

function CardFields.setFieldState(plugin, side, state)
    local setting_key = side == "front" and "front_fields" or "back_fields"
    plugin.settings:saveSetting(setting_key, state)
    plugin.settings:flush()
end

function CardFields.describeFields(state)
    local parts = {}
    for _, f in ipairs(CardFields.FIELD_LABELS) do
        if state[f.key] then parts[#parts + 1] = f.label end
    end
    if #parts == 0 then return _("(none)") end
    return table.concat(parts, ", ")
end

return CardFields
