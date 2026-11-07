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

local exists = {}
local function icon(name)
    local path = "Interface\\Icons\\" .. name
    if exists[path] == nil then
        exists[path] = not GetFileIDFromPath or GetFileIDFromPath(path) ~= nil
    end
    return exists[path] and path or nil
end

local cache = {}
function Art:Icon(id)
    if cache[id] then
        return cache[id]
    end
    local card = TC.Cards[id]
    local path
    if card then
        if card.type == "SPELL" then
            path = SCHOOL_ICONS[card.school] and icon(SCHOOL_ICONS[card.school])
        elseif card.type == "MINION" and card.races ~= 0 then
            for _, entry in ipairs(RACE_ICONS) do
                if bit.band(card.races, entry[1]) ~= 0 then
                    path = icon(entry[2])
                    break
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
function Art:RulesText(id)
    local card = TC.Cards[id]
    if not card then
        return ""
    end
    local text = card.shown or card.text or ""
    text = text:gsub("%[x%]", ""):gsub("%$(%d+)", "%1"):gsub("#(%d+)", "%1")
    text = text:gsub("<b>(.-)</b>", "|cffffd100%1|r"):gsub("<i>(.-)</i>", "%1"):gsub("</?%a+>", "")
    text = text:gsub("@", ""):gsub("\n", " ")
    return text
end

-- One shared sound helper: SOUNDKIT names vary by client, so look them up defensively.
function Art:Play(kit)
    local id = SOUNDKIT and SOUNDKIT[kit]
    if id and not TC.db.settings.mute then
        PlaySound(id)
    end
end
