-- Everything but quests that pays a card, once per character: the first kill of each dungeon and raid boss,
-- achievements, and level milestones (Data/Rewards.lua, per class: harder content pays rarer cards).
-- Also the hero classes: no Forever character plays a Demon Hunter or a Death Knight, so their decks unlock for
-- the whole account when any character reaches the level (TC.HeroUnlock).

local TC = TavernCards_NS

local Rewards = {}
TC.Rewards = Rewards

local map          -- this class's { b = boss, a = achievement, l = level } -> card id
local aliases      -- canonical achievement id -> every id the client lists it under
local bossByName   -- lower-case boss name -> canonical encounter id

local function secret(v)
    return issecretvalue and issecretvalue(v)
end

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

-- ---- hero classes ---------------------------------------------------------------------------------

function Rewards:UnlockLevel(class)
    return TC.HeroUnlock and TC.HeroUnlock[class]
end

function Rewards:IsUnlocked(class)
    if not self:UnlockLevel(class) then
        return true
    end
    return TC.db.unlocks[class] ~= nil
end

-- Unlocks every hero class this level reaches. Announced unless quiet (the login check of an old character).
function Rewards:CheckUnlocks(level, quiet)
    for class, need in pairs(TC.HeroUnlock or {}) do
        if level >= need and not TC.db.unlocks[class] then
            TC.db.unlocks[class] = time()
            TC:Print("|cffffd100%s decks unlocked!|r Every character of yours can now build one, and %s cards start turning up as rewards.",
                className(class), className(class))
            if not quiet and TC.Toast and TC.Toast.Notice then
                TC.Toast:Notice(className(class) .. " Unlocked", "New deck class", TC.Art and TC.Art:ClassIcon(class))
            end
        end
    end
end

-- ---- paying ---------------------------------------------------------------------------------------

local function pay(key, id, source, batch)
    if not id or TC.Collection:HasGranted(key) then
        return
    end
    local result, dust = TC.Collection:Grant(key, id, source, batch ~= nil)
    if result and batch then
        batch.cards[#batch.cards + 1] = id
        batch.dust = batch.dust + (dust or 0)
    end
end

function Rewards:PayLevels(level, batch)
    if not map then return end
    for lvl, id in pairs(map.l) do
        if level >= lvl then
            pay("lvl:" .. lvl, id, "Reached level " .. lvl, batch)
        end
    end
end

local function bossLabel(id, fallbackName)
    local info = TC.BossInfo and TC.BossInfo[id]
    if info then
        local name, where = strsplit("\t", info)
        return ("Boss: %s (%s)"):format(name, where)
    end
    return "Boss: " .. (fallbackName or ("#" .. id))
end

-- A boss the tables don't know (new Forever content) still pays, from a stable pick of its kind.
local function unknownBoss(id, raid)
    return TC.Quests and TC.Quests:Fallback(id, raid and "EPIC" or "RARE")
end

function Rewards:OnBossKill(encounterID, name, raid, batch)
    if secret(encounterID) or not map then
        return
    end
    encounterID = tonumber(encounterID)
    if not encounterID then return end
    local id = TC.BossCanon and TC.BossCanon[encounterID] or encounterID
    local card = map.b[id]
    if not card and not (TC.BossInfo and TC.BossInfo[id]) then
        card = unknownBoss(id, raid)
    end
    pay("b:" .. id, card, bossLabel(id, not secret(name) and name or nil), batch)
end

-- Bosses killed this lockout: pays the ones missed while the addon was off.
function Rewards:PayLockouts(batch)
    if not (GetNumSavedInstances and GetSavedInstanceEncounterInfo and TC.BossInfo) then
        return
    end
    if not bossByName then
        bossByName = {}
        for id, info in pairs(TC.BossInfo) do
            local name = strsplit("\t", info)
            bossByName[name:lower()] = bossByName[name:lower()] or id
        end
    end
    local ok, n = pcall(GetNumSavedInstances)
    for i = 1, ok and n or 0 do
        local info = { pcall(GetSavedInstanceInfo, i) }
        local encounters = info[1] and info[12] or 0
        for j = 1, encounters do
            local got, boss, _, killed = pcall(GetSavedInstanceEncounterInfo, i, j)
            if got and killed and boss and not secret(boss) then
                local id = bossByName[boss:lower()]
                if id then
                    pay("b:" .. id, map.b[id], bossLabel(id), batch)
                end
            end
        end
    end
end

-- Kills from before the addon: the game's boss kill statistics ("Edwin VanCleef kills"), per character.
function Rewards:PayStatistics(batch)
    if not (map and GetStatistic and TC.BossStatistics) then return end
    for stat, id in pairs(TC.BossStatistics) do
        local ok, value = pcall(GetStatistic, stat)
        if ok and not secret(value) and (tonumber(value) or 0) > 0 then
            pay("b:" .. id, map.b[id], bossLabel(id), batch)
        end
    end
end

-- ...and quests that can't be done without the boss dead (its head, or killing it), done by this character.
local function questDone(questID)
    return C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted and C_QuestLog.IsQuestFlaggedCompleted(questID)
end

function Rewards:PayQuestBosses(questID, batch)
    local bosses = map and TC.BossQuests and TC.BossQuests[questID]
    for _, id in ipairs(bosses or {}) do
        pay("b:" .. id, map.b[id], bossLabel(id), batch)
    end
end

function Rewards:PayQuestEvidence(batch)
    if not (map and TC.BossQuests) then return end
    for questID in pairs(TC.BossQuests) do
        if questDone(questID) then
            self:PayQuestBosses(questID, batch)
        end
    end
end

local function earnedByMe(id)
    if not GetAchievementInfo then
        return false
    end
    local ok, _, _, _, completed, _, _, _, _, _, _, _, _, wasEarnedByMe = pcall(GetAchievementInfo, id)
    -- Account-wide achievements earned on another character don't pay this one.
    return ok and completed and wasEarnedByMe ~= false
end

local function achievementLabel(id)
    return "Achievement: " .. (TC.AchievementInfo and TC.AchievementInfo[id] or ("#" .. id))
end

function Rewards:OnAchievement(achievementID, batch)
    if secret(achievementID) or not map then return end
    achievementID = tonumber(achievementID)
    local id = TC.AchievementCanon and TC.AchievementCanon[achievementID] or achievementID
    if map.a[id] then
        pay("a:" .. id, map.a[id], achievementLabel(id), batch)
    end
end

function Rewards:ScanAchievements(batch)
    if not map or not GetAchievementInfo then return end
    if not aliases then
        aliases = {}
        for id in pairs(map.a) do aliases[id] = { id } end
        for alias, id in pairs(TC.AchievementCanon or {}) do
            if aliases[id] then table.insert(aliases[id], alias) end
        end
    end
    for id, ids in pairs(aliases) do
        if not TC.Collection:HasGranted("a:" .. id) then
            for _, aid in ipairs(ids) do
                if earnedByMe(aid) then
                    pay("a:" .. id, map.a[id], achievementLabel(id), batch)
                    break
                end
            end
        end
    end
end

-- Every login: whatever this character has done since (or before) the addon last looked pays now, as one batch.
function Rewards:CatchUp()
    local level = UnitLevel("player") or 1
    self:CheckUnlocks(level, true)
    local batch = { cards = {}, dust = 0 }
    self:PayLevels(level, batch)
    self:ScanAchievements(batch)
    self:PayLockouts(batch)
    self:PayStatistics(batch)
    self:PayQuestEvidence(batch)
    if #batch.cards > 0 then
        TC.Collection:NotifyBatch(batch.cards, batch.dust, "Rewards for your adventures")
        TC:Print("Your levels, achievements and boss kills earned |cffffffff%d|r cards. Your collection: %s.",
            #batch.cards, TC.Collection:ProgressText())
    end
end

function Rewards:Init()
    local _, family = UnitClass("player")
    map = TC.RewardMap and TC.RewardMap[family]
    TC.RewardMap = nil   -- only this character's class is needed
end

-- What the ledger and toasts know about a source key ("b:663"): a tooltip line.
function Rewards:Describe(key)
    local kind, id = (key or ""):match("^(%a+):(%d+)$")
    id = tonumber(id)
    if kind == "b" then return bossLabel(id) end
    if kind == "a" then return achievementLabel(id) end
    if kind == "lvl" then return "Reached level " .. id end
end

TC:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if isLogin or isReload then
        if not map then
            Rewards:Init()
        end
        C_Timer.After(5, function()
            TC:Safe("rewards catch-up", Rewards.CatchUp, Rewards)
        end)
    end
end)

TC:On("PLAYER_LEVEL_UP", function(level)
    if secret(level) then return end
    Rewards:CheckUnlocks(level)
    Rewards:PayLevels(level)
end)

-- ENCOUNTER_END(encounterID, name, difficultyID, groupSize, success); BOSS_KILL(encounterID, name) as a backup.
TC:On("ENCOUNTER_END", function(encounterID, name, _, groupSize, success)
    if success == 1 or success == true then
        Rewards:OnBossKill(encounterID, name, (tonumber(groupSize) or 5) > 5)
    end
end)

TC:On("BOSS_KILL", function(encounterID, name)
    Rewards:OnBossKill(encounterID, name, IsInRaid and IsInRaid())
end)

-- A turned-in quest that needed a boss dead pays that boss too (if its kill went unseen).
TC:On("QUEST_TURNED_IN", function(questID)
    if secret(questID) then return end
    Rewards:PayQuestBosses(TC.Quests and TC.Quests:Canon(questID) or questID)
end)

TC:On("ACHIEVEMENT_EARNED", function(achievementID)
    Rewards:OnAchievement(achievementID)
end)
