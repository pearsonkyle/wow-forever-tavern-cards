-- Quests pay cards: one per quest, per character, from the class's own map (Data/QuestMap.lua).
-- A quest the map does not know (new Forever content) still pays, from a stable pick in the class pool.

local TC = TavernCards_NS

local Quests = {}
TC.Quests = Quests

local classMap
local pools -- [rarity] = ids for the player's class + neutral, in card order

local function buildPools(family)
    pools = { COMMON = {}, RARE = {}, EPIC = {}, LEGENDARY = {} }
    for _, id in ipairs(TC.CardOrder) do
        local card = TC.Cards[id]
        if bit.band(card.flags, 8) ~= 0 and (card.family == family or card.family == "NEUTRAL"
                or (TC.HeroUnlock and TC.HeroUnlock[card.family])) then
            local rarity = card.rarity == "FREE" and "COMMON" or card.rarity
            table.insert(pools[rarity], id)
        end
    end
end

-- Stable hash of a number over its decimal digits. The multiplier stays small so every step is
-- exact in a double (FNV's 16777619 would overflow 2^53).
local function hash(n)
    local s, h = tostring(n), 7
    for i = 1, #s do
        h = (h * 31 + s:byte(i)) % 4294967296
    end
    return h
end

-- Forever's per-starting-zone copies of a quest all pay as their canonical quest, once.
function Quests:Canon(questID)
    return TC.QuestCanon and TC.QuestCanon[questID] or questID
end

-- A stable card of that rarity for a source the maps don't know (seeded by its id). Hero class cards only once
-- their decks are unlocked.
function Quests:Fallback(seed, rarity)
    local pool = pools and pools[rarity]
    if not pool or #pool == 0 then
        return nil
    end
    local h = hash(seed)
    for i = 0, 15 do
        local id = pool[(h + i * 7919) % #pool + 1]
        local family = TC.Cards[id].family
        if not (TC.Rewards and TC.HeroUnlock and TC.HeroUnlock[family]) or TC.Rewards:IsUnlocked(family) then
            return id
        end
    end
end

function Quests:CardFor(questID)
    questID = self:Canon(questID)
    local id = classMap and classMap[questID]
    if id then
        return id
    end
    local level = UnitLevel("player") or 1
    return self:Fallback(questID, level < 20 and "COMMON" or level < 45 and "RARE" or "EPIC")
end

local function areaName(id)
    id = tonumber(id) or 0
    if id < 0 then
        return TC.QuestSorts and TC.QuestSorts[id]
    end
    if id > 0 and C_Map and C_Map.GetAreaInfo then
        local name = C_Map.GetAreaInfo(id)
        if name and name ~= "" then
            return name
        end
    end
end

-- What we know about a quest: { name, level, zone, giver, giverZone } (fields may be nil).
function Quests:Info(questID)
    questID = tonumber(questID)
    if not questID then
        return nil
    end
    local info = {}
    local raw = TC.QuestInfo and TC.QuestInfo[questID]
    if raw then
        local name, level, zone, giver, giverZone = strsplit("\t", raw)
        info.name = name ~= "" and name or nil
        info.level = tonumber(level)
        info.zone = areaName(zone)
        info.giver = giver ~= "" and giver or nil
        info.giverZone = areaName(giverZone)
    end
    if not info.name then
        local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
        if title and not (issecretvalue and issecretvalue(title)) then
            info.name = title
        end
    end
    info.name = info.name or ("Quest #" .. questID)
    return info
end

local function questTitle(questID)
    return Quests:Info(questID).name
end

-- Tooltip lines for a quest source: where it is and who gives it.
function Quests:AddTooltipLines(tip, questID)
    local info = self:Info(questID)
    if not info then
        return
    end
    tip:AddLine(" ")
    tip:AddLine(info.name, 1, 0.82, 0)
    local where = info.zone
    if info.giverZone and info.giverZone ~= where then
        where = where and (where .. " (" .. info.giverZone .. ")") or info.giverZone
    end
    if info.level and info.level > 0 then
        tip:AddLine(("Level %d quest%s"):format(info.level, where and (" in " .. where) or ""), 1, 1, 1)
    elseif where then
        tip:AddLine(where, 1, 1, 1)
    end
    if info.giver then
        tip:AddLine(info.giver, 0.75, 0.75, 0.75)
    end
end

function Quests:OnTurnedIn(questID)
    local id = self:CardFor(questID)
    questID = self:Canon(questID)
    if id then
        TC.Collection:Grant("q:" .. questID, id, "Quest: " .. questTitle(questID), false, questID)
    end
end

-- First login with the addon: every quest already completed pays once, as one batch.
function Quests:Retro()
    if TC.char.retroDone then
        return
    end
    local done = C_QuestLog and C_QuestLog.GetAllCompletedQuestIDs and C_QuestLog.GetAllCompletedQuestIDs()
    if not done then
        return
    end
    local cards, dust, extra = {}, 0, 0
    for _, completed in ipairs(done) do
        local questID = self:Canon(completed)
        local id = classMap and classMap[questID]
        if id then
            local result, gained = TC.Collection:Grant("q:" .. questID, id, "Quest: " .. questTitle(questID), true, questID)
            if result then
                cards[#cards + 1] = id
                dust = dust + (gained or 0)
                if result == "dust" then extra = extra + 1 end
            end
        end
    end
    TC.char.retroDone = true
    if #cards > 0 then
        TC.Collection:NotifyBatch(cards, dust, "Your journey so far")
        TC:Print("This character's past quests earned |cffffffff%d|r cards%s. Your collection: %s (shared by all your characters). Open |cffffffff/tc|r to see them.",
            #cards, extra > 0 and (" (|cffffffff%d|r extra copies became |cffffffff%d|r dust)"):format(extra, dust) or "",
            TC.Collection:ProgressText())
    end
end

function Quests:Init()
    local _, family = UnitClass("player")
    classMap = TC.QuestMap and TC.QuestMap[family]
    -- Only this character's class map is needed; drop the others' memory.
    TC.QuestMap = nil
    buildPools(family)
end

TC:On("QUEST_TURNED_IN", function(questID)
    Quests:OnTurnedIn(questID)
end)

TC:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if isLogin or isReload then
        if not pools then
            Quests:Init()
        end
        -- The completed-quest list can lag the login by a moment.
        C_Timer.After(3, function()
            Quests:Retro()
        end)
    end
end)
