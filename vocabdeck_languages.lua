-- Shared source-language normalization and detection helpers.
--
-- Keep canonical language handling in one place so DB queries, dictionary
-- capture, filters, study decks, and manual cards all agree on names.
local Languages = {}

local TextUtils = require("vocabdeck_text_utils")

local NAMES = {
    es = "Spanish",
    spa = "Spanish",
    spanish = "Spanish",
    ["español"] = "Spanish",
    castellano = "Spanish",
    fr = "French",
    fra = "French",
    fre = "French",
    french = "French",
    ["français"] = "French",
    de = "German",
    deu = "German",
    ger = "German",
    german = "German",
    deutsch = "German",
    it = "Italian",
    ita = "Italian",
    italian = "Italian",
    italiano = "Italian",
    pt = "Portuguese",
    por = "Portuguese",
    portuguese = "Portuguese",
    ["português"] = "Portuguese",
    ja = "Japanese",
    jpn = "Japanese",
    japanese = "Japanese",
    zh = "Chinese",
    zho = "Chinese",
    chi = "Chinese",
    chinese = "Chinese",
    ko = "Korean",
    kor = "Korean",
    korean = "Korean",
    ru = "Russian",
    rus = "Russian",
    russian = "Russian",
    ar = "Arabic",
    ara = "Arabic",
    arabic = "Arabic",
    la = "Latin",
    lat = "Latin",
    latin = "Latin",
    el = "Greek",
    ell = "Greek",
    gre = "Greek",
    greek = "Greek",
    en = "English",
    eng = "English",
    english = "English",
    nl = "Dutch",
    nld = "Dutch",
    dut = "Dutch",
    dutch = "Dutch",
    sv = "Swedish",
    swe = "Swedish",
    swedish = "Swedish",
    no = "Norwegian",
    nor = "Norwegian",
    norwegian = "Norwegian",
    nb = "Norwegian",
    nn = "Norwegian",
    da = "Danish",
    dan = "Danish",
    danish = "Danish",
    fi = "Finnish",
    fin = "Finnish",
    finnish = "Finnish",
    pl = "Polish",
    pol = "Polish",
    polish = "Polish",
    cs = "Czech",
    ces = "Czech",
    cze = "Czech",
    czech = "Czech",
    tr = "Turkish",
    tur = "Turkish",
    turkish = "Turkish",
    uk = "Ukrainian",
    ukr = "Ukrainian",
    ukrainian = "Ukrainian",
    he = "Hebrew",
    heb = "Hebrew",
    hebrew = "Hebrew",
    hi = "Hindi",
    hin = "Hindi",
    hindi = "Hindi",
    vi = "Vietnamese",
    vie = "Vietnamese",
    vietnamese = "Vietnamese",
    th = "Thai",
    tha = "Thai",
    thai = "Thai",
    id = "Indonesian",
    ind = "Indonesian",
    indonesian = "Indonesian",
}

local ALIASES = {
    Spanish = { "Spanish", "spanish", "es", "spa", "es_es", "es-es", "español", "castellano" },
    French = { "French", "french", "fr", "fra", "fre", "fr_fr", "fr-fr", "français" },
    German = { "German", "german", "de", "deu", "ger", "de_de", "de-de", "deutsch" },
    Italian = { "Italian", "italian", "it", "ita", "it_it", "it-it", "italiano" },
    Portuguese = { "Portuguese", "portuguese", "pt", "por", "pt_pt", "pt-pt", "pt_br", "pt-br", "português" },
    Japanese = { "Japanese", "japanese", "ja", "jpn", "ja_jp", "ja-jp" },
    Chinese = { "Chinese", "chinese", "zh", "zho", "chi", "zh_cn", "zh-cn", "zh_tw", "zh-tw" },
    Korean = { "Korean", "korean", "ko", "kor", "ko_kr", "ko-kr" },
    Russian = { "Russian", "russian", "ru", "rus", "ru_ru", "ru-ru" },
    Arabic = { "Arabic", "arabic", "ar", "ara", "ar_ar", "ar-ar" },
    Latin = { "Latin", "latin", "la", "lat" },
    Greek = { "Greek", "greek", "el", "ell", "gre", "el_gr", "el-gr" },
    English = { "English", "english", "en", "eng", "en_us", "en-us", "en_gb", "en-gb" },
    Dutch = { "Dutch", "dutch", "nl", "nld", "dut", "nl_nl", "nl-nl" },
    Swedish = { "Swedish", "swedish", "sv", "swe", "sv_se", "sv-se" },
    Norwegian = { "Norwegian", "norwegian", "no", "nor", "nb", "nn", "no_no", "no-no", "nb_no", "nb-no", "nn_no", "nn-no" },
    Danish = { "Danish", "danish", "da", "dan", "da_dk", "da-dk" },
    Finnish = { "Finnish", "finnish", "fi", "fin", "fi_fi", "fi-fi" },
    Polish = { "Polish", "polish", "pl", "pol", "pl_pl", "pl-pl" },
    Czech = { "Czech", "czech", "cs", "ces", "cze", "cs_cz", "cs-cz" },
    Turkish = { "Turkish", "turkish", "tr", "tur", "tr_tr", "tr-tr" },
    Ukrainian = { "Ukrainian", "ukrainian", "uk", "ukr", "uk_ua", "uk-ua" },
    Hebrew = { "Hebrew", "hebrew", "he", "heb", "he_il", "he-il" },
    Hindi = { "Hindi", "hindi", "hi", "hin", "hi_in", "hi-in" },
    Vietnamese = { "Vietnamese", "vietnamese", "vi", "vie", "vi_vn", "vi-vn" },
    Thai = { "Thai", "thai", "th", "tha", "th_th", "th-th" },
    Indonesian = { "Indonesian", "indonesian", "id", "ind", "id_id", "id-id" },
}

local HINTS = {
    { pattern = "spanish", language = "Spanish" },
    { pattern = "español", language = "Spanish" },
    { pattern = "castellano", language = "Spanish" },
    { pattern = "french", language = "French" },
    { pattern = "français", language = "French" },
    { pattern = "german", language = "German" },
    { pattern = "deutsch", language = "German" },
    { pattern = "italian", language = "Italian" },
    { pattern = "italiano", language = "Italian" },
    { pattern = "portuguese", language = "Portuguese" },
    { pattern = "português", language = "Portuguese" },
    { pattern = "japanese", language = "Japanese" },
    { pattern = "日本", language = "Japanese" },
    { pattern = "chinese", language = "Chinese" },
    { pattern = "中文", language = "Chinese" },
    { pattern = "korean", language = "Korean" },
    { pattern = "한국", language = "Korean" },
    { pattern = "russian", language = "Russian" },
    { pattern = "рус", language = "Russian" },
    { pattern = "arabic", language = "Arabic" },
    { pattern = "عرب", language = "Arabic" },
    { pattern = "latin", language = "Latin" },
    { pattern = "greek", language = "Greek" },
    { pattern = "english", language = "English" },
    { pattern = "dutch", language = "Dutch" },
    { pattern = "nederlands", language = "Dutch" },
    { pattern = "swedish", language = "Swedish" },
    { pattern = "svenska", language = "Swedish" },
    { pattern = "norwegian", language = "Norwegian" },
    { pattern = "norsk", language = "Norwegian" },
    { pattern = "danish", language = "Danish" },
    { pattern = "dansk", language = "Danish" },
    { pattern = "finnish", language = "Finnish" },
    { pattern = "suomi", language = "Finnish" },
    { pattern = "polish", language = "Polish" },
    { pattern = "polski", language = "Polish" },
    { pattern = "czech", language = "Czech" },
    { pattern = "čeština", language = "Czech" },
    { pattern = "turkish", language = "Turkish" },
    { pattern = "türk", language = "Turkish" },
    { pattern = "ukrainian", language = "Ukrainian" },
    { pattern = "україн", language = "Ukrainian" },
    { pattern = "hebrew", language = "Hebrew" },
    { pattern = "עבר", language = "Hebrew" },
    { pattern = "hindi", language = "Hindi" },
    { pattern = "हिन्द", language = "Hindi" },
    { pattern = "vietnamese", language = "Vietnamese" },
    { pattern = "tiếng việt", language = "Vietnamese" },
    { pattern = "thai", language = "Thai" },
    { pattern = "ไทย", language = "Thai" },
    { pattern = "indonesian", language = "Indonesian" },
    { pattern = "indonesia", language = "Indonesian" },
}

function Languages.normalize(language)
    language = TextUtils.trim(tostring(language or ""))
    if language == "" then return "" end
    local lowered = language:lower()
    lowered = lowered:gsub("%b()", "")
    lowered = lowered:gsub("%b[]", "")
    lowered = TextUtils.trim(lowered)
    local key = lowered:gsub("^([a-z][a-z])[_%-].*$", "%1")
    key = key:gsub("^([a-z][a-z])%s+.*$", "%1")
    return NAMES[key] or NAMES[language:lower()] or language
end

function Languages.getAliases(language)
    local normalized = Languages.normalize(language)
    return ALIASES[normalized] or { normalized }
end

function Languages.isKnown(language)
    local normalized = Languages.normalize(language)
    return ALIASES[normalized] ~= nil
end

function Languages.detectFromText(text)
    if type(text) ~= "string" or text == "" then return "" end
    local lower = text:lower()
    for _, hint in ipairs(HINTS) do
        if lower:find(hint.pattern, 1, true) then
            return hint.language
        end
    end
    local code = lower:match("(^%a%a)[_%-]")
        or lower:match("[/%._%-](%a%a)[_%-]")
        or lower:match("[_%-](%a%a)%.")
        or lower:match("[/%._%-](%a%a)%.")
    return code and Languages.normalize(code) or ""
end

-- Grammar labels used to detect whether the first line of a dictionary
-- definition is a part-of-speech label that should be stripped from the
-- meaning text (e.g. "adj." or "noun").
Languages.GRAMMAR_LABELS = {
    noun = true,
    verb = true,
    adjective = true,
    adj = true,
    adverb = true,
    adv = true,
    pronoun = true,
    preposition = true,
    conjunction = true,
    interjection = true,
    article = true,
    determiner = true,
    phrase = true,
    idiom = true,
}

function Languages.listManualChoices()
    local seen = {}
    local choices = {}
    for _, name in pairs(NAMES) do
        if not seen[name] then
            seen[name] = true
            choices[#choices + 1] = name
        end
    end
    table.sort(choices)
    return choices
end

return Languages
