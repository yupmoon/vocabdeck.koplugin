-- VocabDeck bulk enrichment workflow.
--
-- Handles "fetch missing info" actions without making main.lua own the
-- refetch prompt, network handoff, and batch call plumbing.
local _ = require("gettext")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local Trapper = require("ui/trapper")

local AIRunner = require("vocabdeck_ai_runner")
local DB = require("vocabdeck_db")
local Enrich = require("vocabdeck_enrich")

local Bulk = {}

function Bulk.fetchMissing(plugin, book_id, on_finished)
    local provider_ok, provider_err = plugin:ensureAIProviderLoaded()
    if not provider_ok then
        UIManager:show(InfoMessage:new{
            text = AIRunner.formatError(provider_err),
            timeout = 4,
        })
        if on_finished then on_finished(0, 0) end
        return
    end

    local cards = DB.listPendingCards(book_id)
    if #cards == 0 then
        UIManager:show(ConfirmBox:new{
            text = _("All cards already have AI info. Refetch AI data anyway?"),
            ok_text = _("Refetch"),
            ok_callback = function()
                local refetch_cards = DB.listCardsForRefetch(book_id)
                if #refetch_cards == 0 then
                    UIManager:show(InfoMessage:new{
                        text = _("No cards found."),
                        timeout = 3,
                    })
                    if on_finished then on_finished(0, 0) end
                    return
                end
                local NetworkMgr = require("ui/network/manager")
                NetworkMgr:runWhenOnline(function()
                    Trapper:wrap(function()
                        Enrich.bulkEnrich(plugin, refetch_cards, on_finished)
                    end)
                end)
            end,
        })
        return
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Enrich.bulkEnrich(plugin, cards, on_finished)
        end)
    end)
end

return Bulk
