local _ = require("gettext")

return {
    name = "vocabdeck",
    fullname = _("VocabDeck"),
    description = _([[Vocabulary deck and flashcard review for words and phrases collected while reading. Save dictionary lookups or highlights with source context, enrich missing details with AI, browse and edit cards, and review them with spaced repetition.]]),
    update_url = "https://api.github.com/repos/yupmoon/vocabdeck.koplugin/releases/latest",
    version = "1.2.0",
}
