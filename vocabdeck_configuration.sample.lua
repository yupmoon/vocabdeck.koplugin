-- VocabDeck configuration
--
-- Copy this file to `vocabdeck_configuration.lua` only if you want to change
-- provider defaults, endpoints, visibility, or request parameters. API keys
-- can be entered from the VocabDeck menu, or kept in `vocabdeck_apikeys.lua` if you
-- prefer file-based credentials.
--
-- The plugin picks `provider` as the default provider. You can switch
-- providers at runtime from the VocabDeck settings menu.
--
-- Providers that speak OpenAI-compatible chat completions can use
-- `handler = "openai"` even when their visible provider name is different.

local CONFIGURATION = {
    provider = "openai",

    provider_settings = {
        openai = {
            visible = true,
            model = "gpt-4.1-mini",
            base_url = "https://api.openai.com/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        deepseek = {
            visible = true,
            handler = "openai",
            model = "deepseek-v4-flash",
            base_url = "https://api.deepseek.com/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        groq = {
            visible = true,
            handler = "openai",
            model = "llama-3.3-70b-versatile",
            base_url = "https://api.groq.com/openai/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            }
        },

        mistral = {
            visible = true,
            handler = "openai",
            model = "mistral-small-latest",
            base_url = "https://api.mistral.ai/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        xai = {
            visible = true,
            handler = "openai",
            model = "grok-3-mini-fast",
            base_url = "https://api.x.ai/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        openrouter = {
            visible = true,
            handler = "openai",
            model = "google/gemini-2.5-flash",
            base_url = "https://openrouter.ai/api/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        qwen = {
            visible = true,
            handler = "openai",
            model = "qwen-plus",
            base_url = "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        kimi = {
            visible = true,
            handler = "openai",
            model = "kimi-k2-turbo-preview",
            base_url = "https://api.moonshot.ai/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        perplexity = {
            visible = true,
            handler = "openai",
            model = "sonar",
            base_url = "https://api.perplexity.ai/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        together = {
            visible = false,
            handler = "openai",
            model = "meta-llama/Llama-3.3-70B-Instruct-Turbo",
            base_url = "https://api.together.xyz/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        fireworks = {
            visible = false,
            handler = "openai",
            model = "accounts/fireworks/models/llama-v3p3-70b-instruct",
            base_url = "https://api.fireworks.ai/inference/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        sambanova = {
            visible = false,
            handler = "openai",
            model = "Meta-Llama-3.3-70B-Instruct",
            base_url = "https://api.sambanova.ai/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        zai = {
            visible = false,
            handler = "openai",
            model = "glm-4.7-flash",
            base_url = "https://open.bigmodel.cn/api/paas/v4/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        cohere = {
            visible = false,
            handler = "openai",
            model = "command-r-08-2024",
            base_url = "https://api.cohere.com/compatibility/v1/chat/completions",
            api_key = "",
            additional_parameters = {
                temperature = 0.3,
                max_tokens = 1024,
            },
        },

        -- Anthropic Claude. Uses the Messages API (vocabdeck_providers/anthropic.lua).
        anthropic = {
            visible = true,
            model = "claude-haiku-4-5-20251001",
            base_url = "https://api.anthropic.com/v1/messages",
            api_key = "",
            additional_parameters = {
                max_tokens = 1024,
                temperature = 0.3,
                anthropic_version = "2023-06-01",
            },
        },

        -- Google Gemini. Uses the native generateContent endpoint
        -- (vocabdeck_providers/gemini.lua). `base_url` must end with a slash.
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

        -- Ollama using its native /api/chat endpoint
        -- (vocabdeck_providers/ollama.lua).
        ollama = {
            visible = true,
            model = "llama3.3",
            base_url = "http://127.0.0.1:11434/api/chat",
            api_key = "", -- leave empty unless your server needs one
            additional_parameters = {
                options = {
                    temperature = 0.3,
                    num_predict = 1024,
                },
            },
        },
    },
}

return CONFIGURATION
