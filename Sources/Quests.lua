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
        if bit.band(card.flags, 8) ~= 0 and (card.family == family or card.family == "NEUTRAL") then
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

function Quests:CardFor(questID)
    local id = classMap and classMap[questID]
    if id then
        return id
    end
    if not pools then
        return nil
    end
    local level = UnitLevel("player") or 1
    local rarity = level < 20 and "COMMON" or level < 45 and "RARE" or "EPIC"
    local pool = pools[rarity]
    return pool[hash(questID) % #pool + 1]
end

local function questTitle(questID)
    local title = C_QuestLog and C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
    if title and not (issecretvalue and issecretvalue(title)) then
        return title
    end
    return "Quest #" .. questID
end

function Quests:OnTurnedIn(questID)
    local id = self:CardFor(questID)
    if id then
        TC.Collection:Grant("q:" .. questID, id, "Quest: " .. questTitle(questID))
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
    local cards, dust = {}, 0
    for _, questID in ipairs(done) do
        local id = classMap and classMap[questID]
        if id then
            local result, gained = TC.Collection:Grant("q:" .. questID, id, "Quest: " .. questTitle(questID), true)
            if result then
                cards[#cards + 1] = id
                dust = dust + (gained or 0)
            end
        end
    end
    TC.char.retroDone = true
    if #cards > 0 then
        TC.Collection:NotifyBatch(cards, dust, "Your journey so far")
        TC:Print("Your past adventures earned you |cffffffff%d|r cards%s. Open |cffffffff/tc|r to see them.",
            #cards, dust > 0 and (" and |cffffffff" .. dust .. "|r dust") or "")
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
