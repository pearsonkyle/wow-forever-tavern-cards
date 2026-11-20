-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Card backs and how each is earned (hand-written, not generated). Keyed by stable string ids: a back's id
-- is what TavernCardsDB.backs and every deck remember, so ids never change or get reused. Unlocks key on the
-- game's own ids (encounters, zones, achievements, classes), never on the card map, so redistributing cards
-- can't move them.
--
--   { id, name, art, emblem icon, rule }
--   art:  a loading-screen painting name ("LoadScreenDeadmines"), a colour {r, g, b} (emblem backs), or
--         { map = uiMapID, folder = "Elwynn" } (a zone back: the zone's own world map)
--   rule: { "default" }                       everyone has it
--         { "boss", ids, hint }               defeat any of these encounters (a dungeon's last boss, per wing)
--         { "class", "WARRIOR" }              have a character of the class
--         { "faction", "Alliance" }           have a character of the faction
--         { "zone", uiMapID, "Zone Name", explore = achievementID }   be there (or have explored it)
--         { "achievement", id, hint }         earn the achievement (on any character)

local TC = TavernCards_NS

TC.CardBackList = {
    { "tavern", "Tavern", { 0.28, 0.16, 0.08 }, "INV_Misc_Ticket_Tarot_Stack_01", { "default" } },

    -- Dungeons and raids: their loading-screen painting, earned by finishing the place.
    { "deadmines", "The Deadmines", "LoadScreenDeadmines", "INV_Misc_Bandana_03", { "boss", { 2747 }, "Defeat Edwin VanCleef in the Deadmines" } },
    { "wailing", "Wailing Caverns", "LoadScreenWailingCaverns", "Spell_Nature_Sleep", { "boss", { 592 }, "Defeat Mutanus the Devourer in Wailing Caverns" } },
    { "shadowfang", "Shadowfang Keep", "LoadScreenShadowfangKeep", "Ability_Hunter_Pet_Wolf", { "boss", { 2755 }, "Defeat Archmage Arugal in Shadowfang Keep" } },
    { "stockade", "The Stockade", "LoadScreenStormwindStockade", "INV_Misc_Key_03", { "boss", { 2760 }, "Defeat Bazil Thredd in the Stockade" } },
    { "blackfathom", "Blackfathom Deeps", "LoadScreenBlackfathomDeeps", "INV_Misc_MonsterScales_08", { "boss", { 2767 }, "Defeat Aku'mai in Blackfathom Deeps" } },
    { "gnomeregan", "Gnomeregan", "LoadScreenGnomeregan", "INV_Gizmo_02", { "boss", { 2772 }, "Defeat Mekgineer Thermaplugg in Gnomeregan" } },
    { "kraul", "Razorfen Kraul", "LoadScreenRazorfenKraul", "INV_Misc_Head_Quilboar_01", { "boss", { 2778 }, "Defeat Charlga Razorflank in Razorfen Kraul" } },
    { "monastery", "Scarlet Monastery", "LoadScreenMonastery", "Spell_Holy_SealOfMight", { "boss", { 450, 448, 447, 2779 }, "Finish a wing of the Scarlet Monastery" } },
    { "uldaman", "Uldaman", "LoadScreenUldaman", "INV_Stone_15", { "boss", { 554 }, "Defeat Archaedas in Uldaman" } },
    { "zulfarrak", "Zul'Farrak", "LoadScreenZulFarrak", "INV_Misc_Head_Troll_01", { "boss", { 600 }, "Defeat Chief Ukorz Sandscalp in Zul'Farrak" } },
    { "maraudon", "Maraudon", "LoadScreenMaraudon", "Spell_Nature_ResistNature", { "boss", { 429 }, "Defeat Princess Theradras in Maraudon" } },
    { "sunken", "Sunken Temple", "LoadScreenSunkenTemple", "INV_Misc_Head_Dragon_Green", { "boss", { 493, 492 }, "Defeat the Shade of Eranikus in the Sunken Temple" } },
    { "brd", "Blackrock Depths", "LoadScreenBlackrockDepths", "Spell_Fire_Volcano", { "boss", { 2790 }, "Defeat Emperor Dagran Thaurissan in Blackrock Depths" } },
    { "brs", "Blackrock Spire", "LoadScreenBlackrockSpire", "INV_Misc_Head_Dragon_Black", { "boss", { 275, 3069 }, "Defeat Overlord Wyrmthalak or General Drakkisath in Blackrock Spire" } },
    { "diremaul", "Dire Maul", "LoadScreenDireMaul", "Achievement_Character_Ogre", { "boss", { 346, 361, 368 }, "Finish a wing of Dire Maul" } },
    { "scholomance", "Scholomance", "LoadScreenScholomance", "Spell_Shadow_RaiseDead", { "boss", { 2801 }, "Defeat Darkmaster Gandling in Scholomance" } },
    { "stratholme", "Stratholme", "LoadScreenStrathome", "Spell_Shadow_AnimateDead", { "boss", { 484, 478 }, "Defeat Baron Rivendare or Balnazzar in Stratholme" } },
    { "moltencore", "Molten Core", "LoadScreenMoltenCore", "Achievement_Boss_Ragnaros", { "boss", { 672 }, "Defeat Ragnaros in Molten Core" } },
    { "blackwing", "Blackwing Lair", "LoadScreenBlackwingLair", "Achievement_Boss_Nefarion", { "boss", { 617 }, "Defeat Nefarian in Blackwing Lair" } },
    { "zulgurub", "Zul'Gurub", "LoadScreenZulGurub", "Achievement_Boss_Hakkar", { "boss", { 793 }, "Defeat Hakkar in Zul'Gurub" } },
    { "aq", "Ahn'Qiraj", "LoadScreenAhnQiraj40man", "Achievement_Boss_CThun", { "boss", { 717 }, "Defeat C'Thun in the Temple of Ahn'Qiraj" } },
    { "naxxramas", "Naxxramas", "LoadScreenNaxxramas", "Achievement_Boss_Kelthuzad_01", { "boss", { 1114 }, "Defeat Kel'Thuzad in Naxxramas" } },

    -- Battlegrounds: go there.
    { "warsong", "Warsong Gulch", "LoadScreenWarsongGulch", "INV_Misc_Rune_07", { "zone", 1460, "Warsong Gulch" } },
    { "arathi", "Arathi Basin", "LoadScreenArathiBasin", "INV_Jewelry_Amulet_07", { "zone", 1461, "Arathi Basin" } },

    -- Continents: explore them.
    { "kalimdor", "Kalimdor", "LoadScreenKalimdor", "Spell_Nature_StarFall", { "achievement", 43, "Explore Kalimdor (the achievement)" } },
    { "easternkingdoms", "Eastern Kingdoms", "LoadScreenEasternKingdom", "INV_Misc_Map_01", { "achievement", 42, "Explore the Eastern Kingdoms (the achievement)" } },

    -- Zones: their world map, earned by going there (or, from before, by having explored them).
    { "elwynn", "Elwynn Forest", { map = 1429, folder = "Elwynn" }, "INV_Misc_Map_01", { "zone", 1429, "Elwynn Forest", explore = 776 } },
    { "dunmorogh", "Dun Morogh", { map = 1426, folder = "DunMorogh" }, "INV_Misc_Map_01", { "zone", 1426, "Dun Morogh", explore = 627 } },
    { "teldrassil", "Teldrassil", { map = 1438, folder = "Teldrassil" }, "INV_Misc_Map_01", { "zone", 1438, "Teldrassil", explore = 842 } },
    { "durotar", "Durotar", { map = 1411, folder = "Durotar" }, "INV_Misc_Map_01", { "zone", 1411, "Durotar", explore = 728 } },
    { "mulgore", "Mulgore", { map = 1412, folder = "Mulgore" }, "INV_Misc_Map_01", { "zone", 1412, "Mulgore", explore = 736 } },
    { "tirisfal", "Tirisfal Glades", { map = 1420, folder = "Tirisfal" }, "INV_Misc_Map_01", { "zone", 1420, "Tirisfal Glades", explore = 768 } },
    { "stranglethorn", "Stranglethorn Vale", { map = 1434, folder = "Stranglethorn" }, "INV_Misc_Map_01", { "zone", 1434, "Stranglethorn Vale", explore = 781 } },
    { "feralas", "Feralas", { map = 1444, folder = "Feralas" }, "INV_Misc_Map_01", { "zone", 1444, "Feralas", explore = 849 } },
    { "tanaris", "Tanaris", { map = 1446, folder = "Tanaris" }, "INV_Misc_Map_01", { "zone", 1446, "Tanaris", explore = 851 } },
    { "easternplaguelands", "Eastern Plaguelands", { map = 1423, folder = "EasternPlaguelands" }, "INV_Misc_Map_01", { "zone", 1423, "Eastern Plaguelands", explore = 771 } },
    { "silithus", "Silithus", { map = 1451, folder = "Silithus" }, "INV_Misc_Map_01", { "zone", 1451, "Silithus", explore = 856 } },
    { "winterspring", "Winterspring", { map = 1452, folder = "Winterspring" }, "INV_Misc_Map_01", { "zone", 1452, "Winterspring", explore = 857 } },

    -- Factions and classes: have a character of it.
    { "alliance", "Alliance", { 0.1, 0.2, 0.5 }, "INV_BannerPVP_02", { "faction", "Alliance" } },
    { "horde", "Horde", { 0.5, 0.08, 0.06 }, "INV_BannerPVP_01", { "faction", "Horde" } },
    { "warrior", "Warrior", { 0.55, 0.42, 0.28 }, "Ability_Warrior_BattleShout", { "class", "WARRIOR" } },
    { "paladin", "Paladin", { 0.62, 0.36, 0.5 }, "Spell_Holy_HolyBolt", { "class", "PALADIN" } },
    { "hunter", "Hunter", { 0.36, 0.5, 0.25 }, "INV_Weapon_Bow_07", { "class", "HUNTER" } },
    { "rogue", "Rogue", { 0.55, 0.52, 0.22 }, "Ability_Stealth", { "class", "ROGUE" } },
    { "priest", "Priest", { 0.6, 0.6, 0.62 }, "Spell_Holy_PowerWordShield", { "class", "PRIEST" } },
    { "shaman", "Shaman", { 0.1, 0.3, 0.6 }, "Spell_Nature_BloodLust", { "class", "SHAMAN" } },
    { "mage", "Mage", { 0.25, 0.5, 0.65 }, "Spell_Frost_FrostBolt02", { "class", "MAGE" } },
    { "warlock", "Warlock", { 0.35, 0.3, 0.55 }, "Spell_Shadow_DeathCoil", { "class", "WARLOCK" } },
    { "druid", "Druid", { 0.6, 0.35, 0.1 }, "Ability_Druid_CatForm", { "class", "DRUID" } },
    { "deathknight", "Death Knight", { 0.5, 0.1, 0.12 }, "Spell_Deathknight_ClassIcon", { "class", "DEATHKNIGHT" } },
    { "demonhunter", "Demon Hunter", { 0.3, 0.45, 0.1 }, "Ability_DemonHunter_SpecDPS", { "class", "DEMONHUNTER" } },
}
