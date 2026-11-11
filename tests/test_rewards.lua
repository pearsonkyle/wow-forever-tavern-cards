-- Bosses, achievements, levels and the hero class unlocks (Sources/Rewards.lua over Data/Rewards.lua).
local T = {}
-- Init drops every class map but the player's: keep the generated tables for each test.
local REWARDS, QUESTS = TavernCards_NS.RewardMap, TavernCards_NS.QuestMap

local function setup(TC, opts)
    opts = opts or {}
    time = time or os.time
    geterrorhandler = geterrorhandler or function() return error end
    strsplit = strsplit or function(sep, s)
        local out = {}
        for part in (s .. sep):gmatch("(.-)" .. sep) do out[#out + 1] = part end
        return unpack(out)
    end
    TC.RewardMap, TC.QuestMap = REWARDS, QUESTS
    TC.db = { collection = {}, dust = 0, ledger = {}, unlocks = {}, decks = {} }
    TC.char = { granted = {} }
    TC.handlers = {}
    function TC:On(event, fn) self.handlers[event] = fn end
    function TC:Print() end
    function TC:Safe(_, fn, ...) return fn(...) end
    TC.Collection:Subscribe(function() end)
    UnitClass = function() return "Warrior", "WARRIOR" end
    UnitLevel = function() return opts.level or 1 end
    C_Timer = { After = function() end }
    GetAchievementInfo = opts.achievements
    GetNumSavedInstances = nil
    LOCALIZED_CLASS_NAMES_MALE = nil
    dofile("Sources/Quests.lua")
    dofile("Sources/Rewards.lua")
    TC.Quests:Init()
    TC.Rewards:Init()
    return TC.Rewards
end

local function load(TC)
    TC.RewardMap, TC.QuestMap = REWARDS, QUESTS
    dofile("Collection/Collection.lua")
    dofile("Collection/Decks.lua")
end

local function firstBoss(TC)
    -- Ragnaros: a raid boss every class map pays.
    for id, info in pairs(TC.BossInfo) do
        if info:match("^Ragnaros\t") then return id end
    end
end

T.boss_kill_pays_once_and_aliases_share_it = function(TC)
    load(TC)
    local warriorMap = TC.RewardMap.WARRIOR
    local R = setup(TC)
    local id = firstBoss(TC)
    assert(id and warriorMap.b[id], "Ragnaros pays a Warrior card")
    R:OnBossKill(id, "Ragnaros", true)
    local card = warriorMap.b[id]
    assert(TC.Collection:Count(card) == 1, "the boss's card arrives")
    assert(TC.Cards[card].rarity == "LEGENDARY", "the last boss of a raid pays a legendary")
    R:OnBossKill(id, "Ragnaros", true)
    assert(TC.Collection:Count(card) == 1, "a second kill pays nothing")
    -- Another difficulty's encounter id of a boss is the same source.
    for alias, canon in pairs(TC.BossCanon) do
        local before = #TC.db.ledger
        R:OnBossKill(canon, "x", false)
        R:OnBossKill(alias, "x", false)
        assert(#TC.db.ledger <= before + 1, "an alias pays as its boss")
        break
    end
end

T.dungeon_bosses_are_never_common = function(TC)
    load(TC)
    for _, family in ipairs({ "WARRIOR", "MAGE", "DRUID" }) do
        local commons = 0
        for id, card in pairs(TC.RewardMap[family].b) do
            if TC.Cards[card].rarity == "COMMON" then commons = commons + 1 end
        end
        assert(commons <= 4, family .. ": only namesakes (Arcane Anomaly) may be common")
    end
end

T.past_kills_pay_from_statistics_and_quests = function(TC)
    load(TC)
    local stat, statBoss = next(TC.BossStatistics)
    local quest, questBosses = next(TC.BossQuests)
    local R = setup(TC)
    GetStatistic = function(id) return id == stat and "3" or "--" end
    C_QuestLog = { IsQuestFlaggedCompleted = function(q) return q == quest end }
    R:CatchUp()
    assert(TC.Collection:HasGranted("b:" .. statBoss), "a boss with kills on record pays")
    for _, b in ipairs(questBosses) do
        assert(TC.Collection:HasGranted("b:" .. b), "a quest that needed the boss dead pays the boss")
    end
    GetStatistic, C_QuestLog = nil, nil
end

T.levels_pay_up_to_the_level_and_unlock_hero_classes = function(TC)
    load(TC)
    local R = setup(TC, { level = 25 })
    assert(not TC.Decks:IsUnlocked("DEMONHUNTER") and TC.Decks:IsUnlocked("WARRIOR"))
    R:CatchUp()
    assert(TC.Collection:HasGranted("lvl:10") and TC.Collection:HasGranted("lvl:20"))
    assert(not TC.Collection:HasGranted("lvl:30"))
    assert(TC.Decks:IsUnlocked("DEMONHUNTER"), "level 20 unlocks Demon Hunter decks")
    assert(not TC.Decks:IsUnlocked("DEATHKNIGHT"), "Death Knight waits for level 40")
    R:CheckUnlocks(40)
    assert(TC.Decks:IsUnlocked("DEATHKNIGHT"))
end

T.level_twenty_pays_a_demon_hunter_card = function(TC)
    load(TC)
    local card = TC.RewardMap.WARRIOR.l[20]
    assert(card and TC.Cards[card].family == "DEMONHUNTER")
    assert(TC.Cards[TC.RewardMap.WARRIOR.l[40]].family == "DEATHKNIGHT")
    assert(TC.Cards[TC.RewardMap.WARRIOR.l[60]].rarity == "LEGENDARY")
end

T.achievements_pay_only_when_earned_by_this_character = function(TC)
    load(TC)
    local ids = {}
    for id in pairs(TC.RewardMap.WARRIOR.a) do ids[#ids + 1] = id end
    table.sort(ids)
    local mine, other = ids[1], ids[2]
    local R = setup(TC, { achievements = function(id)
        local canon = TC.AchievementCanon[id] or id
        if canon == mine then return id, "x", 0, true, 1, 1, 1, "", 0, 0, "", false, true end
        if canon == other then return id, "x", 0, true, 1, 1, 1, "", 0, 0, "", false, false end
        return id, "x", 0, false
    end })
    R:ScanAchievements()
    assert(TC.Collection:HasGranted("a:" .. mine), "earned here: pays")
    assert(not TC.Collection:HasGranted("a:" .. other), "earned on another character: doesn't")
end

T.locked_hero_decks_cannot_be_imported = function(TC)
    load(TC)
    setup(TC, { level = 5 })
    local deck = TC.Decks:Create("DEMONHUNTER")
    for id, card in pairs(TC.Cards) do
        if card.family == "DEMONHUNTER" and bit.band(card.flags, 8) ~= 0 then
            deck.cards[id] = 1
            break
        end
    end
    local code = TC.Decks:Encode(deck)
    TC.db.decks = {}
    local got, why = TC.Decks:Import(code)
    assert(not got and why == "locked")
    TC.Rewards:CheckUnlocks(20, true)
    assert(TC.Decks:Import(code), "unlocked: imports")
end

return T
