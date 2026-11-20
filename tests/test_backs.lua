-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Card backs are earned: a dungeon's last boss, a character of the class or faction, being in a zone (or
-- having explored it), an achievement. Earned backs are kept account-wide in TavernCardsDB.backs, and the
-- backs decks already wore stay theirs.
local T = {}

-- A world to log into: who you are, where you stand, which achievements are done.
local function setup(TC, world)
    world = world or {}
    time = function() return 1000 end
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    issecretvalue = world.secret
    UnitClass = function() return "Warrior", world.class or "WARRIOR" end
    UnitFactionGroup = function() return world.faction or "Horde" end
    GetRealZoneText = function() return world.zone or "Orgrimmar" end
    C_Map = {
        GetBestMapForUnit = function() return world.map end,
        GetMapInfo = function(id) return { parentMapID = world.parents and world.parents[id] } end,
    }
    GetAchievementInfo = function(id)
        return id, "x", 10, (world.achievements or {})[id] and true or false
    end
    LOCALIZED_CLASS_NAMES_MALE = { WARRIOR = "Warrior", MAGE = "Mage" }
    local printed = {}
    TC.On = function() end
    TC.Print = function(_, fmt, ...) printed[#printed + 1] = fmt:format(...) end
    TC.Art = { Play = function() end }
    TC.db = { decks = world.decks or {}, backs = world.backs or {} }
    dofile("Sources/Backs.lua")
    return TC.Backs, printed
end

T.every_back_has_a_rule_and_unique_id = function(TC)
    local seen = {}
    for _, b in ipairs(TC.CardBackList) do
        assert(not seen[b[1]], "duplicate back id " .. b[1])
        seen[b[1]] = true
        local kind = b[5] and b[5][1]
        assert(({ default = 1, boss = 1, class = 1, faction = 1, zone = 1, achievement = 1 })[kind], b[1])
    end
    -- Every boss rule names an encounter the reward tables know, so the back can actually be earned.
    for _, b in ipairs(TC.CardBackList) do
        if b[5][1] == "boss" then
            for _, enc in ipairs(b[5][2]) do assert(TC.BossInfo[enc], b[1] .. ": unknown encounter " .. enc) end
        end
    end
end

T.only_the_tavern_back_is_free = function(TC)
    local Backs = setup(TC)
    assert(Backs:IsUnlocked("tavern"))
    assert(not Backs:IsUnlocked("deadmines"))
    assert(not Backs:IsUnlocked("mage"))
    assert(not Backs:IsUnlocked("no such back"))
end

T.a_dungeons_last_boss_earns_its_back = function(TC)
    local Backs, printed = setup(TC)
    Backs:OnBoss(2746)                      -- Cookie: not the last boss
    assert(not Backs:IsUnlocked("deadmines"))
    Backs:OnBoss("2747")                    -- Edwin VanCleef (ids arrive as strings from the reward keys)
    assert(Backs:IsUnlocked("deadmines"))
    assert(TC.db.backs.deadmines == 1000)
    assert(#printed == 1 and printed[1]:find("The Deadmines"))
    Backs:OnBoss(2747)                      -- earned once
    assert(#printed == 1)
    Backs:OnBoss(448)                       -- any wing's end earns the Scarlet Monastery
    assert(Backs:IsUnlocked("monastery"))
end

T.class_faction_zone_and_achievements_at_login = function(TC)
    local Backs, printed = setup(TC, { class = "MAGE", faction = "Alliance", map = 1429, achievements = { [43] = true, [728] = true } })
    Backs:CatchUp()
    for _, id in ipairs({ "mage", "alliance", "elwynn", "kalimdor", "durotar" }) do
        assert(Backs:IsUnlocked(id), id)
    end
    for _, id in ipairs({ "warrior", "horde", "easternkingdoms", "mulgore" }) do
        assert(not Backs:IsUnlocked(id), id)
    end
    -- Quiet at login: one line later, from Announce.
    assert(#printed == 0)
    Backs:Announce()
    assert(#printed == 1 and printed[1]:find("Mage") and printed[1]:find("Elwynn Forest"))
    Backs:Announce()
    assert(#printed == 1)
end

T.zones_by_name_and_by_parent_map = function(TC)
    local Backs = setup(TC, { zone = "Warsong Gulch" })
    Backs:CheckZone()
    assert(Backs:IsUnlocked("warsong"))
    local Backs2 = setup(TC, { map = 99999, parents = { [99999] = 1446 } })   -- a subzone map inside Tanaris
    Backs2:CheckZone()
    assert(Backs2:IsUnlocked("tanaris"))
end

T.backs_decks_already_wore_stay_theirs = function(TC)
    local Backs = setup(TC, { decks = { { name = "Old", back = "naxxramas" }, { name = "New" } } })
    Backs:CatchUp()
    assert(Backs:IsUnlocked("naxxramas"))
    -- Saved unlocks survive, untouched.
    local Backs2 = setup(TC, { backs = { moltencore = 5 } })
    Backs2:CatchUp()
    assert(Backs2:IsUnlocked("moltencore") and TC.db.backs.moltencore == 5)
end

T.secret_values_are_ignored = function(TC)
    local Backs = setup(TC, { secret = function(v) return v == "hidden" end, zone = "hidden" })
    Backs:OnBoss("hidden")
    Backs:OnAchievement("hidden")
    Backs:CheckZone()
    local have = Backs:Progress()
    assert(have == 1)   -- only the tavern
end

T.hints_say_how_to_earn = function(TC)
    local Backs = setup(TC)
    assert(Backs:Hint("deadmines"):find("Edwin VanCleef"))
    assert(Backs:Hint("mage") == "Play a Mage.")
    assert(Backs:Hint("tanaris") == "Travel to Tanaris.")
    assert(Backs:Hint("alliance"):find("Alliance"))
end

return T
