-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Earning card backs (Data/CardBacks.lua says how each is earned). Unlocks are account-wide and kept in
-- TavernCardsDB.backs (back id -> time earned). They come from:
--   bosses       Rewards credits every boss kill (live, this lockout, kill statistics, quest evidence) and
--                tells us: a dungeon's back is earned by its last boss.
--   classes      logging in a character of the class; factions likewise.
--   zones        being in the zone (on login and on every zone change), or its exploration achievement.
--   achievements earned on any character.
-- Nothing is ever taken away. The backs your decks already wore before backs had to be earned stay yours.

local TC = TavernCards_NS

local Backs = {}
TC.Backs = Backs

local byBoss, byZone, byAchievement, byId = {}, {}, {}, {}

-- Forever hides some event values in combat (secret values): never compare or convert those.
local function secret(v)
    return issecretvalue and issecretvalue(v)
end

local function index()
    if next(byId) then return end
    for _, b in ipairs(TC.CardBackList or {}) do
        local id, rule = b[1], b[5]
        byId[id] = b
        if rule[1] == "boss" then
            for _, enc in ipairs(rule[2]) do byBoss[enc] = byBoss[enc] or {} table.insert(byBoss[enc], id) end
        elseif rule[1] == "zone" then
            byZone[rule[2]] = id
            byZone[rule[3]] = id
            if rule.explore then byAchievement[rule.explore] = id end
        elseif rule[1] == "achievement" then
            byAchievement[rule[2]] = id
        end
    end
end

local function store()
    TC.db.backs = TC.db.backs or {}
    return TC.db.backs
end

function Backs:IsUnlocked(id)
    index()
    local b = byId[id]
    if not b then return false end
    return b[5][1] == "default" or store()[id] ~= nil
end

local pending = {}   -- backs earned quietly (login scans), announced together by Backs:Announce

-- Earn a back. quiet: no message now; the login catch-up announces them together.
function Backs:Unlock(id, quiet)
    index()
    if not byId[id] or self:IsUnlocked(id) then return false end
    store()[id] = time()
    if quiet then
        pending[#pending + 1] = byId[id][2]
    else
        TC:Print("New card back: |cffffd100%s|r. Choose it for a deck on the Decks tab.", byId[id][2])
        TC.Art:Play("UI_EPICLOOT_TOAST")
    end
    return true
end

-- One line for every back earned quietly since the last announcement.
function Backs:Announce()
    if #pending == 0 then return end
    TC:Print("New card back%s: |cffffd100%s|r. See them all on the Collection tab (Card Backs).",
        #pending == 1 and "" or "s", table.concat(pending, ", "))
    wipe(pending)
end

-- How to earn a back, for the gallery.
function Backs:Hint(id)
    index()
    local b = byId[id]
    if not b then return "" end
    local rule = b[5]
    local kind = rule[1]
    if kind == "default" then return "Every tavern has this one." end
    if kind == "boss" or kind == "achievement" then return rule[3] end
    if kind == "class" then
        return ("Play a %s."):format((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[rule[2]]) or b[2])
    end
    if kind == "faction" then return ("Play a character of the %s."):format(rule[2]) end
    if kind == "zone" then return ("Travel to %s."):format(rule[3]) end
    return ""
end

function Backs:OnBoss(encounterID, quiet)
    if secret(encounterID) then return end
    index()
    for _, id in ipairs(byBoss[tonumber(encounterID) or 0] or {}) do self:Unlock(id, quiet) end
end

function Backs:OnAchievement(achievementID, quiet)
    if secret(achievementID) then return end
    index()
    local id = byAchievement[tonumber(achievementID) or 0]
    if id then self:Unlock(id, quiet) end
end

-- Where you stand: the zone's map id (and its parents, for a subzone map) and the zone's name.
function Backs:CheckZone(quiet)
    index()
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
        local hops = 0
        while ok and map and not secret(map) and hops < 4 do
            if byZone[map] then self:Unlock(byZone[map], quiet) end
            local got, info = pcall(C_Map.GetMapInfo, map)
            map = got and info and info.parentMapID
            hops = hops + 1
        end
    end
    local name = GetRealZoneText and GetRealZoneText()
    if type(name) == "string" and not secret(name) and byZone[name] then self:Unlock(byZone[name], quiet) end
end

local function completed(id)
    if not GetAchievementInfo then return false end
    local ok, _, _, _, done = pcall(GetAchievementInfo, id)
    return ok and done and true or false
end

-- At login: this character's class and faction, where it stands, achievements, and the backs decks already
-- wore. Bosses come from Rewards' own catch-up (Rewards:CatchUp -> pay -> Backs:OnBoss), which announces.
function Backs:CatchUp()
    index()
    for _, deck in ipairs(TC.db.decks or {}) do
        if deck.back and byId[deck.back] and not self:IsUnlocked(deck.back) then store()[deck.back] = time() end
    end
    local _, class = UnitClass("player")
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    for _, b in ipairs(TC.CardBackList or {}) do
        local rule = b[5]
        if (rule[1] == "class" and rule[2] == class) or (rule[1] == "faction" and rule[2] == faction) then
            self:Unlock(b[1], true)
        end
    end
    for achievementID in pairs(byAchievement) do
        if completed(achievementID) then self:OnAchievement(achievementID, true) end
    end
    self:CheckZone(true)
end

-- Counts for the gallery title: earned, and how many there are.
function Backs:Progress()
    index()
    local have, total = 0, 0
    for _, b in ipairs(TC.CardBackList or {}) do
        total = total + 1
        if self:IsUnlocked(b[1]) then have = have + 1 end
    end
    return have, total
end

TC:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if not TC.db then return end
    Backs:CatchUp()
    -- At login Rewards' catch-up announces a few seconds later (with the bosses); entering an instance or a
    -- battleground announces now.
    if not (isLogin or isReload) then Backs:Announce() end
end)
TC:On("ZONE_CHANGED_NEW_AREA", function() if TC.db then Backs:CheckZone() end end)
TC:On("ACHIEVEMENT_EARNED", function(id) if TC.db then Backs:OnAchievement(id) end end)
