-- Namespace and SavedVariables binding.
--
-- The namespace is also published as TavernCards_NS so Engine/ files (which must run headless,
-- without the `...` addon varargs) share it.

local ADDON, TC = ...
TC = TC or {}
TavernCards_NS = TC
_G.TavernCards = TC

TC.ADDON = ADDON or "TavernCards"
TC.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(TC.ADDON, "Version")) or "dev"

local DB_DEFAULTS = {
    schema = 1,
    generation = 1,    -- bumped by /tc reset; characters from an older generation start over
    collection = {},   -- cardId -> copies (account-wide)
    dust = 0,
    ledger = {},       -- { t, card, source }
    unseen = {},       -- cardId -> true until hovered in the book ("New")
    settings = { minimap = {}, mute = false, scale = 1 },
}

local CHAR_DEFAULTS = {
    schema = 1,
    granted = {},      -- sourceKey -> true (quests, milestones) so a source pays once
    decks = {},
    retroDone = false,
}

local function fill(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                fill(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            fill(target[k], v)
        end
    end
end

-- Forever can inject SavedVariables into _G while addon code holds a different table if defaults
-- are assigned too early (see GearQuestForever Core.lua). Only touch them from ADDON_LOADED on,
-- and always go through _G.
function TC:BindSavedVariables()
    if type(_G.TavernCardsDB) ~= "table" then
        _G.TavernCardsDB = {}
    end
    if type(_G.TavernCardsCharDB) ~= "table" then
        _G.TavernCardsCharDB = {}
    end
    fill(_G.TavernCardsDB, DB_DEFAULTS)
    fill(_G.TavernCardsCharDB, CHAR_DEFAULTS)
    self.db = _G.TavernCardsDB
    self.char = _G.TavernCardsCharDB
    if self.char.generation ~= self.db.generation then
        -- The account collection was reset: this character's quests pay again (journey re-runs).
        wipe(self.char.granted)
        self.char.retroDone = false
        self.char.generation = self.db.generation
    end
end

-- Wipes the account collection; every character re-earns its quests on its next login.
function TC:ResetCollection()
    local db = self.db
    wipe(db.collection)
    wipe(db.ledger)
    wipe(db.unseen)
    db.dust = 0
    db.generation = (db.generation or 1) + 1
    self:BindSavedVariables()
end

-- True once the rules engine can play at least one card (Data/Wave.lua not empty).
function TC:OnLoadedEngineCheck()
    TC.EngineReady = next(TC.PlayableNow or {}) ~= nil
end

function TC:Print(fmt, ...)
    local msg = select("#", ...) > 0 and fmt:format(...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cffd8a657Tavern Cards|r: " .. msg)
end

function TavernCards_OnAddonCompartmentClick()
    TC:ToggleWindow()
end
