-- VocabDeck provider catalog.
--
-- Keeps provider display names and model lists out of the settings UI.
local Catalog = {}

Catalog.MODEL_OPTIONS = {
    gemini = {
        "gemini-2.5-flash",
        "gemini-2.5-pro",
        "gemini-2.5-flash-lite",
        "gemini-3-flash-preview",
        "gemini-3.1-pro-preview",
        "gemini-3.1-flash-lite-preview",
    },
    openai = {
        "gpt-4.1-mini",
        "gpt-4.1",
        "gpt-4.1-nano",
        "gpt-4o-mini",
        "gpt-4o",
        "gpt-5-mini",
        "gpt-5",
    },
    deepseek = {
        "deepseek-v4-flash",
        "deepseek-v4-pro",
        "deepseek-chat",
        "deepseek-reasoner",
    },
    groq = {
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
        "qwen/qwen3-32b",
    },
    openai_groq = {
        "llama-3.3-70b-versatile",
        "llama-3.1-8b-instant",
        "openai/gpt-oss-120b",
        "openai/gpt-oss-20b",
        "qwen/qwen3-32b",
    },
    mistral = {
        "mistral-large-latest",
        "mistral-medium-latest",
        "mistral-small-latest",
        "ministral-8b-latest",
        "ministral-3b-latest",
        "open-mistral-nemo",
    },
    xai = {
        "grok-3",
        "grok-3-fast",
        "grok-3-mini",
        "grok-3-mini-fast",
    },
    openai_grok = {
        "grok-3",
        "grok-3-fast",
        "grok-3-mini",
        "grok-3-mini-fast",
    },
    openrouter = {
        "anthropic/claude-sonnet-4.5",
        "openai/gpt-4.1",
        "openai/gpt-4o-mini",
        "google/gemini-2.5-flash",
        "google/gemini-2.5-pro",
        "deepseek/deepseek-chat",
        "deepseek/deepseek-r1",
        "meta-llama/llama-3.3-70b-instruct",
        "qwen/qwen3-235b-a22b",
        "perplexity/sonar",
    },
    qwen = {
        "qwen-plus",
        "qwen-turbo",
        "qwen-max",
        "qwen3-max",
    },
    kimi = {
        "kimi-k2-0905-preview",
        "kimi-k2-turbo-preview",
        "kimi-k2-thinking",
        "moonshot-v1-8k",
        "moonshot-v1-32k",
        "moonshot-v1-128k",
    },
    together = {
        "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        "Qwen/Qwen3-32B",
        "Qwen/Qwen3-235B-A22B-fp8",
        "deepseek-ai/DeepSeek-R1",
    },
    fireworks = {
        "accounts/fireworks/models/llama-v3p3-70b-instruct",
        "accounts/fireworks/models/qwen3-235b-a22b",
        "accounts/fireworks/models/deepseek-r1",
    },
    sambanova = {
        "Meta-Llama-3.3-70B-Instruct",
        "Meta-Llama-3.1-8B-Instruct",
        "DeepSeek-R1",
        "Qwen3-32B",
    },
    perplexity = {
        "sonar",
        "sonar-pro",
        "sonar-reasoning-pro",
        "sonar-deep-research",
    },
    zai = {
        "glm-4.7-flash",
        "glm-4.7",
        "glm-4.7-flashx",
        "glm-4.6",
        "glm-4.5-flash",
    },
    cohere = {
        "command-a-03-2025",
        "command-r-plus-08-2024",
        "command-r-08-2024",
        "command-r7b-12-2024",
    },
    anthropic = {
        "claude-sonnet-4-5-20250929",
        "claude-haiku-4-5-20251001",
        "claude-opus-4-5-20251101",
        "claude-3-5-haiku-latest",
    },
    ollama = {
        "llama3.3",
        "llama3.3:70b",
        "llama3.2:3b",
        "qwen3",
        "qwen3:8b",
        "qwen2.5:7b",
        "deepseek-r1",
        "gemma3",
        "mistral",
    },
}

Catalog.PROVIDER_LABELS = {
    openai = "OpenAI",
    anthropic = "Anthropic",
    gemini = "Gemini",
    ollama = "Ollama",
    deepseek = "DeepSeek",
    groq = "Groq",
    openai_groq = "Groq",
    mistral = "Mistral",
    xai = "xAI",
    openai_grok = "xAI",
    openrouter = "OpenRouter",
    qwen = "Qwen",
    kimi = "Kimi",
    together = "Together AI",
    fireworks = "Fireworks",
    sambanova = "SambaNova",
    perplexity = "Perplexity",
    zai = "Z.AI",
    cohere = "Cohere",
}

function Catalog.getLabel(provider)
    return Catalog.PROVIDER_LABELS[provider] or provider or "-"
end

function Catalog.getModelOptions(provider)
    local options = Catalog.MODEL_OPTIONS[provider]
    if not options then
        local handler = provider and (provider:match("^([^_]+)") or provider)
        options = handler and Catalog.MODEL_OPTIONS[handler]
    end
    return options
end

function Catalog.getDefaultModel(provider)
    local options = Catalog.getModelOptions(provider)
    return options and options[1] or nil
end

return Catalog
