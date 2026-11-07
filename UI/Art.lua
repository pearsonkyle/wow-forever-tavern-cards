-- Card art without card art: rarity colors from WoW's own item qualities, and an icon picked from the
-- game's icon set by the card's class, tribe, spell school or type. Every path is checked once with
-- GetFileIDFromPath so a missing icon falls back instead of showing a green box.

local TC = TavernCards_NS

local Art = {}
TC.Art = Art

-- WoW item qualities, so a rarity reads the way loot does: FREE white, COMMON green, RARE blue,
-- EPIC purple, LEGENDARY orange.
Art.QUALITY = { FREE = 1, COMMON = 2, RARE = 3, EPIC = 4, LEGENDARY = 5 }

local FALLBACK = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01"

local CLASS_ICONS = {
    WARRIOR = "ClassIcon_Warrior", PALADIN = "ClassIcon_Paladin", HUNTER = "ClassIcon_Hunter",
    ROGUE = "ClassIcon_Rogue", PRIEST = "ClassIcon_Priest", SHAMAN = "ClassIcon_Shaman", MAGE = "ClassIcon_Mage",
    WARLOCK = "ClassIcon_Warlock", DRUID = "ClassIcon_Druid", DEATHKNIGHT = "Spell_Deathknight_ClassIcon",
    DEMONHUNTER = "ClassIcon_DemonHunter",
}

-- Engine race bits (tc/card.h) -> icon.
local RACE_ICONS = {
    { 0x80, "INV_Misc_Head_Murloc_01" },           -- murloc
    { 0x10, "INV_Misc_Head_Dragon_01" },           -- dragon
    { 0x20, "Spell_Shadow_SummonImp" },            -- demon
    { 0x02, "Spell_Shadow_RaiseDead" },            -- undead
    { 0x04, "Spell_Fire_Elemental_Totem" },        -- elemental
    { 0x08, "INV_Gizmo_02" },                      -- mechanical
    { 0x40, "INV_Misc_Bandana_03" },               -- pirate
    { 0x200, "INV_Misc_MonsterScales_08" },        -- naga
    { 0x400, "Spell_Nature_StoneSkinTotem" },      -- totem
    { 0x800, "INV_Misc_Head_Quilboar_01" },        -- quilboar
    { 0x01, "Ability_Hunter_Pet_Wolf" },           -- beast
}

local SCHOOL_ICONS = {
    fire = "Spell_Fire_FlameBolt", frost = "Spell_Frost_FrostBolt02", arcane = "Spell_Nature_StarFall",
    nature = "Spell_Nature_HealingTouch", shadow = "Spell_Shadow_ShadowBolt", holy = "Spell_Holy_HolyBolt",
    fel = "Spell_Fire_FelFlameRing",
}

local TYPE_ICONS = {
    WEAPON = "INV_Sword_04", SPELL = "INV_Misc_Book_09", MINION = "INV_Misc_Head_Human_01",
    LOCATION = "INV_Misc_Map_01",
}

-- Words in a card's name -> icon, matched at the start of a word. First match wins.
local NAME_ICONS = {
    { "spider", "Ability_Hunter_Pet_Spider" }, { "wolf", "Ability_Hunter_Pet_Wolf" }, { "worg", "Ability_Hunter_Pet_Wolf" },
    { "hound", "Ability_Hunter_Pet_Wolf" }, { "boar", "Ability_Hunter_Pet_Boar" }, { "bear", "Ability_Hunter_Pet_Bear" },
    { "raptor", "Ability_Hunter_Pet_Raptor" }, { "panther", "Ability_Hunter_Pet_Cat" }, { "tiger", "Ability_Hunter_Pet_Cat" },
    { "lion", "Ability_Hunter_Pet_Cat" }, { "cat", "Ability_Hunter_Pet_Cat" }, { "saber", "Ability_Hunter_Pet_Cat" },
    { "bat", "Ability_Hunter_Pet_Bat" }, { "owl", "Ability_Hunter_Pet_Owl" }, { "crab", "Ability_Hunter_Pet_Crab" },
    { "turtle", "Ability_Hunter_Pet_Turtle" }, { "tortoise", "Ability_Hunter_Pet_Turtle" },
    { "gorilla", "Ability_Hunter_Pet_Gorilla" }, { "ape", "Ability_Hunter_Pet_Gorilla" }, { "hyena", "Ability_Hunter_Pet_Hyena" },
    { "scorpi", "Ability_Hunter_Pet_Scorpid" }, { "vulture", "Ability_Hunter_Pet_Vulture" }, { "buzzard", "Ability_Hunter_Pet_Vulture" },
    { "croc", "Ability_Hunter_Pet_Crocolisk" }, { "serpent", "Ability_Hunter_Pet_WindSerpent" }, { "snake", "Ability_Hunter_Pet_WindSerpent" },
    { "strider", "Ability_Hunter_Pet_TallStrider" }, { "hawk", "Ability_Hunter_Pet_DragonHawk" }, { "rat", "INV_Misc_Food_57" },
    { "rodent", "INV_Misc_Food_57" }, { "sheep", "Spell_Nature_Polymorph" }, { "chicken", "Spell_Magic_PolymorphChicken" },
    { "frog", "Ability_Hunter_Pet_Turtle" }, { "toad", "Ability_Hunter_Pet_Turtle" }, { "fish", "INV_Misc_Fish_02" },
    { "shark", "INV_Misc_Fish_35" }, { "ogre", "Achievement_Character_Ogre" }, { "gnoll", "INV_Misc_Head_Gnoll_01" },
    { "kobold", "INV_Misc_Head_Kobold_01" }, { "troll", "Achievement_Character_Troll_Male" },
    { "orc", "Achievement_Character_Orc_Male" }, { "tauren", "Achievement_Character_Tauren_Male" },
    { "dwar", "Achievement_Character_Dwarf_Male" }, { "gnome", "Achievement_Character_Gnome_Male" },
    { "goblin", "Achievement_Character_Goblin_Male" }, { "elf", "Achievement_Character_Nightelf_Female" },
    { "draenei", "Achievement_Character_Draenei_Female" }, { "ghost", "Spell_Shadow_Haunting" },
    { "spirit", "Spell_Shadow_Haunting" }, { "wisp", "Spell_Nature_WispSplode" }, { "treant", "Ability_Druid_ForceofNature" },
    { "ancient", "Ability_Druid_ForceofNature" }, { "dryad", "Ability_Druid_ForceofNature" },
    { "faerie", "Spell_Nature_FaerieFire" }, { "sprite", "Spell_Nature_FaerieFire" }, { "ooze", "INV_Misc_Slime_01" },
    { "slime", "INV_Misc_Slime_01" }, { "golem", "INV_Misc_Gear_08" }, { "giant", "INV_Stone_15" },
    { "bomb", "INV_Misc_Bomb_05" }, { "explosive", "INV_Misc_Bomb_05" }, { "engineer", "Trade_Engineering" },
    { "tinker", "Trade_Engineering" }, { "mech", "Trade_Engineering" }, { "mage", "Spell_Holy_MagicalSentry" },
    { "magus", "Spell_Holy_MagicalSentry" }, { "sorcer", "Spell_Holy_MagicalSentry" }, { "priest", "Spell_Holy_PowerWordShield" },
    { "cleric", "Spell_Holy_PowerWordShield" }, { "acolyte", "Spell_Holy_PowerWordShield" },
    { "necromancer", "Spell_Shadow_DeathCoil" }, { "cultist", "Spell_Shadow_DeathCoil" }, { "warlock", "Spell_Shadow_DeathCoil" },
    { "knight", "Ability_Warrior_DefensiveStance" }, { "champion", "Ability_Warrior_DefensiveStance" },
    { "guard", "INV_Shield_06" }, { "soldier", "INV_Shield_06" }, { "footman", "INV_Shield_06" }, { "militia", "INV_Shield_06" },
    { "assassin", "Ability_Rogue_Ambush" }, { "thief", "Ability_Rogue_Ambush" }, { "bandit", "Ability_Rogue_Ambush" },
    { "ranger", "INV_Weapon_Bow_07" }, { "archer", "INV_Weapon_Bow_07" }, { "hunter", "INV_Weapon_Bow_07" },
    { "trapper", "INV_Weapon_Bow_07" }, { "cook", "INV_Misc_Food_15" }, { "chef", "INV_Misc_Food_15" },
    { "brew", "INV_Drink_05" }, { "barkeep", "INV_Drink_05" }, { "innkeeper", "INV_Drink_05" }, { "book", "INV_Misc_Book_09" },
    { "scroll", "INV_Scroll_03" }, { "dummy", "INV_Misc_Bag_08" }, { "mime", "Spell_Shadow_Charm" },
    { "imp", "Spell_Shadow_SummonImp" }, { "whelp", "INV_Misc_Head_Dragon_01" }, { "drake", "INV_Misc_Head_Dragon_01" },
}

-- Untagged minions with no name match get a varied, stable pick instead of one shared face.
local MINION_POOL = {
    "Achievement_Character_Human_Male", "Achievement_Character_Human_Female", "Achievement_Character_Dwarf_Male",
    "Achievement_Character_Gnome_Female", "Achievement_Character_Nightelf_Male", "Achievement_Character_Orc_Female",
    "Achievement_Character_Troll_Female", "Achievement_Character_Tauren_Female", "Achievement_Character_Undead_Female",
    "Achievement_Character_Bloodelf_Female", "Achievement_Character_Goblin_Female", "INV_Misc_Head_Human_01",
    "INV_Misc_Head_Orc_01", "INV_Misc_Head_Troll_01", "INV_Misc_Head_Dwarf_01", "INV_Misc_Head_Gnome_01",
    "INV_Misc_Head_Elf_01", "INV_Misc_Head_Tauren_01", "INV_Misc_Head_Undead_01",
}

local WEAPON_WORDS = {
    { "axe", "INV_Axe_09" }, { "hammer", "INV_Hammer_04" }, { "mace", "INV_Mace_01" }, { "dagger", "INV_Weapon_ShortBlade_05" },
    { "knife", "INV_Weapon_ShortBlade_05" }, { "blade", "INV_Sword_27" }, { "bow", "INV_Weapon_Bow_07" },
    { "rifle", "INV_Weapon_Rifle_01" }, { "gun", "INV_Weapon_Rifle_01" }, { "staff", "INV_Staff_08" },
    { "spear", "INV_Spear_04" }, { "glaive", "INV_Weapon_Glaive_01" }, { "fist", "INV_Gauntlets_04" },
}

local function stableIndex(id, n)
    local h = 7
    for i = 1, #id do
        h = (h * 31 + id:byte(i)) % 1000003
    end
    return h % n + 1
end

local exists = {}
local function icon(name)
    local path = "Interface\\Icons\\" .. name
    if exists[path] == nil then
        exists[path] = not GetFileIDFromPath or GetFileIDFromPath(path) ~= nil
    end
    return exists[path] and path or nil
end

-- A class's own icon (Death Knight / Demon Hunter have no slot in the old class-crest sheet).
function Art:ClassIcon(family)
    return icon(CLASS_ICONS[family] or "") or FALLBACK
end

-- /tc icons: which vocabulary icons this client lacks (saved for tools/match_icons.py to prune).
function Art:CheckIcons()
    local missing = {}
    for _, name in ipairs(TC.IconVocab or {}) do
        if not icon(name) then missing[#missing + 1] = name end
    end
    TC.db.missingIcons = missing
    return missing, #(TC.IconVocab or {})
end

-- An icon path by name if this client has it, else `fallback`.
function Art:SafeIcon(name, fallback)
    return icon(name) or fallback or FALLBACK
end

local cache = {}
function Art:Icon(id)
    if cache[id] then
        return cache[id]
    end
    local card = TC.Cards[id]
    -- A matched icon (Data/Icons.lua, tools/match_icons.py) when the client has it.
    local path = TC.CardIcons and TC.CardIcons[id] and icon(TC.CardIcons[id])
    if card and not path then
        if card.type == "SPELL" then
            path = SCHOOL_ICONS[card.school] and icon(SCHOOL_ICONS[card.school])
        elseif card.type == "WEAPON" then
            local lower = card.name:lower()
            for _, entry in ipairs(WEAPON_WORDS) do
                if lower:find("%f[%a]" .. entry[1]) then
                    path = icon(entry[2])
                    if path then break end
                end
            end
        elseif card.type == "MINION" then
            local lower = card.name:lower()
            for _, entry in ipairs(NAME_ICONS) do
                if lower:find("%f[%a]" .. entry[1]) then  -- word start: "rat" is not "pirate"
                    path = icon(entry[2])
                    if path then break end
                end
            end
            if not path and card.races ~= 0 then
                for _, entry in ipairs(RACE_ICONS) do
                    if bit.band(card.races, entry[1]) ~= 0 then
                        path = icon(entry[2])
                        break
                    end
                end
            end
            if not path then
                local start = stableIndex(id, #MINION_POOL)
                for k = 0, #MINION_POOL - 1 do
                    path = icon(MINION_POOL[(start + k - 1) % #MINION_POOL + 1])
                    if path then break end
                end
            end
        end
        path = path or (card.family ~= "NEUTRAL" and CLASS_ICONS[card.family] and icon(CLASS_ICONS[card.family]))
            or (TYPE_ICONS[card.type] and icon(TYPE_ICONS[card.type]))
    end
    cache[id] = path or FALLBACK
    return cache[id]
end

function Art:RarityColor(rarity)
    local q = self.QUALITY[rarity] or 1
    if C_Item and C_Item.GetItemQualityColor then
        local r, g, b = C_Item.GetItemQualityColor(q)
        if r then
            return r, g, b
        end
    end
    local c = ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[q]
    if c then
        return c.r, c.g, c.b
    end
    return 1, 1, 1
end

function Art:ColoredName(id)
    local card = TC.Cards[id]
    if not card then
        return id
    end
    local r, g, b = self:RarityColor(card.rarity)
    return ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, card.name)
end

-- Rules text for display: the engine's shown text, with its markup turned into WoW color codes.
local LINE_KEYWORDS = { "Battlecry", "Deathrattle", "Overload", "Combo", "Secret", "Spellburst", "Honorable Kill",
    "Corrupt", "Inspire", "Outcast", "Overkill", "Kindred", "Frenzy", "Overheal", "Finale", "Quickdraw", "Forge",
    "Infuse", "Manathirst", "Choose One", "Excavate" }

-- keepLines: keep the card's own line breaks (tooltips); otherwise one line.
function Art:RulesText(id, keepLines)
    local card = TC.Cards[id]
    if not card then
        return ""
    end
    local text = card.shown or card.text or ""
    text = text:gsub("%[x%]", ""):gsub("%$(%d+)", "%1"):gsub("#(%d+)", "%1")
    text = text:gsub("<b>(.-)</b>", "|cffffffff%1|r"):gsub("<i>(.-)</i>", "%1"):gsub("</?%a+>", "")
    text = text:gsub("@", "")
    if keepLines then
        -- Keyword lists like "Spell Damage +1 Overload: (1)" each get their own line.
        -- Card-frame line breaks mid-sentence are joined; breaks after a sentence stay.
        text = text:gsub("%s*\n%s*", "\n"):gsub("([^%.%!%)%:])\n", "%1 ")
        for _, kw in ipairs(LINE_KEYWORDS) do
            text = text:gsub("([^\n]) (" .. kw .. ":)", "%1\n%2")
        end
    else
        text = text:gsub("\n", " ")
    end
    return text
end

-- One shared sound helper: SOUNDKIT names vary by client, so look them up defensively.
function Art:Play(kit)
    local id = SOUNDKIT and SOUNDKIT[kit]
    if id and not TC.db.settings.mute then
        PlaySound(id)
    end
end
