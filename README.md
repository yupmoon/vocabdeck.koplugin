# VocabDeck

VocabDeck is a vocabulary deck and flashcard plugin for
[KOReader](https://github.com/koreader/koreader).

It lets you save words and phrases while reading, keep the sentence or context
where they appeared, enrich missing information with AI, and review the cards
later with spaced repetition. The interface is designed for e-ink: text-first,
quiet, fast, and close to KOReader's native menus.

VocabDeck is inspired by and derived from
[smartdeck.koplugin](https://github.com/yupmoon/smartdeck.koplugin).

## Features

- **Save words as you read** — tap **Add to VocabDeck** from the dictionary popup or highlight menu. Each card keeps the word, its sentence, surrounding context, book title, and when you added it.
- **Get AI definitions on the spot** — use **Define (VocabDeck)** when the built-in dictionary doesn't have what you need. It fetches a meaning, pronunciation, word type, and more before saving.
- **Add cards manually** — open the main menu and pick **Add new card** to type in a word or phrase yourself.
- **Browse and manage everything** — open **All cards** or **Cards for this book**. Tap any row to view details, edit fields, refetch AI data, mark as known, check memory stats, or delete.
- **Search and filter** — search by text, filter by word type or source language, or show only flagged cards. Sort by any field and switch to quick deletion mode when you need to clean up.
- **Study with spaced repetition** — review using **Again**, **Hard**, **Good**, and **Easy** with an FSRS-style scheduler. Pick a source language or a specific book to study from.
- **Extra study when you want it** — finished today's due cards? **Study more** lets you add extra new cards or extra reviews for the day.
- **Card actions during study** — flag, suspend, mark as known, reset, un-leech, check memory, or refetch AI data — all from the **Actions** button.
- **Import from Vocabulary Builder** — bring in words you've already collected with KOReader's built-in Vocabulary Builder.
- **Back up and restore** — your card database lives locally. Back it up or restore it from Settings whenever you need.
- **Customize study cards** — choose which fields appear on the front and back: word, pronunciation, word type, meaning, synonyms, sentence, context, or your own notes.
- **Configure AI** — pick your provider and model, enter an API key, set a target language, adjust context size, and control daily new-card and review limits — all from KOReader's native menu.


## Installation

1. Download or clone this repository.
2. Copy the folder named `vocabdeck.koplugin` into KOReader's `plugins`
   directory.
3. Restart KOReader.
4. Open KOReader's top menu, go to **Tools**, and open **VocabDeck**.


## Quick Start

1. Open a book in KOReader.
2. Select a word or phrase.
3. Tap **Add to VocabDeck** to save the current lookup or selection.
4. Tap **Define (VocabDeck)** if you want VocabDeck to fetch a definition first.
5. Open **Tools > VocabDeck > Study** when you want to review.

For ordinary dictionary lookups, **Add to VocabDeck** saves the word with the
available definition and reading context. For phrases, or words without a good
dictionary result, **Define (VocabDeck)** can create a card with AI-generated
meaning and metadata.

## Main Menu

VocabDeck appears in KOReader's **Tools** menu.

- **Study**: open the review screen.
- **Stats**: show study progress, streaks, due cards, and deck health.
- **All cards**: browse every saved card.
- **Cards for this book**: browse cards from the current book.
- **Provider**: choose the AI provider.
- **Model**: choose the model for the current provider.
- **API Key**: enter or clear the key for the current provider.
- **AI context words**: choose how much surrounding text is sent for AI lookup.
- **Fetch missing info (this book)**: enrich pending cards from the current book.
- **Fetch missing info (all books)**: enrich pending cards across the deck.
- **Settings**: study behavior, display fields, import, backup, and restore.
- **About VocabDeck**: show provider and configuration status.

## AI Providers

VocabDeck supports these provider handlers:

- **OpenAI-compatible**: OpenAI, Groq, xAI, DeepSeek, Mistral, OpenRouter,
  Azure OpenAI, local servers that expose `/v1/chat/completions`, and similar
  compatible APIs.
- **Anthropic**: Claude models through the Messages API.
- **Google Gemini**: Gemini models through the native `generateContent` API.
- **Ollama**: local Ollama models through `/api/chat`.

You can choose the provider and model from the VocabDeck menu. API keys can be
entered from the menu, or kept in a separate `vocabdeck_apikeys.lua` file so credentials
stay out of provider configuration.

## API Keys

VocabDeck includes a sample API key file:

```text
vocabdeck_apikeys.lua.sample
```

To add keys, copy it to:

```text
vocabdeck_apikeys.lua
```

Then fill only the providers you use:

```lua
return {
    openai = "sk-...",
    gemini = "...",
    anthropic = "...",
}
```

`vocabdeck_apikeys.lua` is ignored by git and should not be shared. If a key exists both
in `vocabdeck_apikeys.lua` and in KOReader settings, the file value is used when loading
the provider.

## Configuration File

VocabDeck includes a sample configuration file:

```text
vocabdeck_configuration.sample.lua
```

To configure providers manually, copy it to:

```text
vocabdeck_configuration.lua
```

Then edit the provider settings inside that file. This is useful when you want
multiple named providers, custom base URLs, local models, or OpenAI-compatible
services that are not listed in the menu. Keep real API keys in `vocabdeck_apikeys.lua`.

VocabDeck picks the right provider handler by looking at the part of the name
before the first underscore. For example, a provider named `openai_myserver`
uses the OpenAI-compatible handler. A provider named `anthropic_custom` uses
the Anthropic handler. If the name has no underscore, the whole name is used
as the handler name.

The provider name you use in `vocabdeck_configuration.lua` will appear directly
in VocabDeck's **Provider** menu. If it's not a built-in provider (like `openai`,
`anthropic`, `gemini`, `ollama`), it will show up as its raw name — for example,
`openai_myserver` appears as `openai_myserver` in the menu.

## Custom Providers

To add a custom OpenAI-compatible provider:

1. Open `vocabdeck_configuration.lua`.
2. Add a new entry under `provider_settings`.
3. Use a name beginning with `openai_`, such as `openai_myserver`.
4. Set `base_url`, `model`, and any extra request parameters.
5. Add its API key to `vocabdeck_apikeys.lua` using the same provider name.
6. Restart KOReader if needed, then choose the provider from VocabDeck's menu.

Example:

```lua
openai_myserver = {
    visible = true,
    model = "my-model",
    base_url = "http://127.0.0.1:8080/v1/chat/completions",
    api_key = "",
    additional_parameters = {
        temperature = 0.3,
        max_tokens = 1024,
    },
}
```

For Anthropic, Gemini, or Ollama, use provider names beginning with
`anthropic`, `gemini`, or `ollama` so VocabDeck can select the correct handler.

## Study Mode

Study mode shows the card front first. Tap **Show answer** to reveal the back,
then grade your recall:

- **Again**: review soon.
- **Hard**: remembered with difficulty.
- **Good**: remembered normally.
- **Easy**: remembered easily.
- **Delete**: remove the card.

The schedule is handled with FSRS-style review state. The goal is to keep the
review flow simple on e-ink while still giving better spacing than a fixed
interval system.

## Card Browser

The card browser is designed for quick maintenance:

- Tap a row to open card details.
- Use **Edit** in details to change word, pronunciation, type, meaning,
  sentence, context, or note.
- Use **Refetch AI data** to regenerate card metadata.
- Use **Delete** to remove a card.
- Use the top-left menu to search, filter, or enter quick deletion mode.

Card rows prioritize the word or phrase, then the meaning, with review status
shown underneath.

## Stats

The stats screen is deliberately text-first and light to render. It shows:

- Cards studied today.
- Current and best streaks.
- Cards due now and due today.
- Tomorrow and seven-day forecast.
- New, learning, young, mature, and lapsed cards.
- Total cards and active books.

## Backup and Restore

Open **Tools > VocabDeck > Settings > Backup and recover**.

From there you can:

- Back up the current VocabDeck database.
- Restore the latest VocabDeck backup.

VocabDeck stores its card database in KOReader's data directory under
`vocabdeck/vocabdeck.sqlite3`.

## Privacy

Cards are stored locally in KOReader's data directory.

AI requests are only made when you use AI features such as **Define
(VocabDeck)**, **Refetch AI data**, or **Fetch missing info**. Those requests
may send the selected word or phrase, configured surrounding context, and
relevant card fields to the selected AI provider.

If you only use **Add to VocabDeck** with KOReader dictionary data and do not
fetch AI data, VocabDeck does not need to contact an AI provider for that card.

## Troubleshooting

### AI fetch says the provider is not configured  

- Open **Tools > VocabDeck > Provider** and choose a provider.
- Copy `vocabdeck_apikeys.lua.sample` to `vocabdeck_apikeys.lua` and add the key for that provider.
- Or open **API Key** and enter the key for the selected provider.
- Confirm the selected model is valid for that provider.
- If using a local or custom provider, check `vocabdeck_configuration.lua`.


### Missing meanings

- Use **Define (VocabDeck)** when adding the card, or use **Refetch AI data**
  from card details.
- Use **Fetch missing info** for bulk enrichment.

## Credits

VocabDeck is inspired by and derived from
[smartdeck.koplugin](https://github.com/yupmoon/smartdeck.koplugin).

Thanks to the KOReader community for the plugin framework and examples that
make projects like this possible.

## License

See [LICENSE](LICENSE).
