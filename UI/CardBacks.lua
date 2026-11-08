-- Card backs: what your opponent sees of your cards. Each deck can wear one (TC.CardBacks:Choose); the
-- house picks one at random each match. A back is a crop of one of the game's dungeon and raid paintings
-- (the loading screens) under a vignette and a gold frame, with an emblem seal in the middle; the class
-- and faction backs are plain colours with their emblem (always present in the client).
--
--   local b = TC.CardBacks:Create(parent, w, h)    b:SetBack(id)

local TC = TavernCards_NS
local Art = TC.Art

local CardBacks = {}
TC.CardBacks = CardBacks

local SCREENS = "Interface\\Glues\\LoadingScreens\\"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

-- { id, name, painting (loading screen) or colour {r,g,b}, emblem icon }
local LIST = {
    { "tavern", "Tavern", { 0.28, 0.16, 0.08 }, "INV_Misc_Ticket_Tarot_Stack_01" },
    { "deadmines", "The Deadmines", "LoadScreenDeadmines", "INV_Misc_Bandana_03" },
    { "wailing", "Wailing Caverns", "LoadScreenWailingCaverns", "Spell_Nature_Sleep" },
    { "shadowfang", "Shadowfang Keep", "LoadScreenShadowfangKeep", "Ability_Hunter_Pet_Wolf" },
    { "stockade", "The Stockade", "LoadScreenStormwindStockade", "INV_Misc_Key_03" },
    { "blackfathom", "Blackfathom Deeps", "LoadScreenBlackfathomDeeps", "INV_Misc_MonsterScales_08" },
    { "gnomeregan", "Gnomeregan", "LoadScreenGnomeregan", "INV_Gizmo_02" },
    { "kraul", "Razorfen Kraul", "LoadScreenRazorfenKraul", "INV_Misc_Head_Quilboar_01" },
    { "monastery", "Scarlet Monastery", "LoadScreenMonastery", "Spell_Holy_SealOfMight" },
    { "uldaman", "Uldaman", "LoadScreenUldaman", "INV_Stone_15" },
    { "zulfarrak", "Zul'Farrak", "LoadScreenZulFarrak", "INV_Misc_Head_Troll_01" },
    { "maraudon", "Maraudon", "LoadScreenMaraudon", "Spell_Nature_ResistNature" },
    { "sunken", "Sunken Temple", "LoadScreenSunkenTemple", "INV_Misc_Head_Dragon_Green" },
    { "brd", "Blackrock Depths", "LoadScreenBlackrockDepths", "Spell_Fire_Volcano" },
    { "brs", "Blackrock Spire", "LoadScreenBlackrockSpire", "INV_Misc_Head_Dragon_Black" },
    { "diremaul", "Dire Maul", "LoadScreenDireMaul", "Achievement_Character_Ogre" },
    { "scholomance", "Scholomance", "LoadScreenScholomance", "Spell_Shadow_RaiseDead" },
    { "stratholme", "Stratholme", "LoadScreenStrathome", "Spell_Shadow_AnimateDead" },
    { "moltencore", "Molten Core", "LoadScreenMoltenCore", "Achievement_Boss_Ragnaros" },
    { "blackwing", "Blackwing Lair", "LoadScreenBlackwingLair", "Achievement_Boss_Nefarion" },
    { "zulgurub", "Zul'Gurub", "LoadScreenZulGurub", "Achievement_Boss_Hakkar" },
    { "aq", "Ahn'Qiraj", "LoadScreenAhnQiraj40man", "Achievement_Boss_CThun" },
    { "naxxramas", "Naxxramas", "LoadScreenNaxxramas", "Achievement_Boss_Kelthuzad_01" },
    { "warsong", "Warsong Gulch", "LoadScreenWarsongGulch", "INV_Misc_Rune_07" },
    { "arathi", "Arathi Basin", "LoadScreenArathiBasin", "INV_Jewelry_Amulet_07" },
    { "kalimdor", "Kalimdor", "LoadScreenKalimdor", "Spell_Nature_StarFall" },
    { "easternkingdoms", "Eastern Kingdoms", "LoadScreenEasternKingdom", "INV_Misc_Map_01" },
    { "alliance", "Alliance", { 0.1, 0.2, 0.5 }, "INV_BannerPVP_02" },
    { "horde", "Horde", { 0.5, 0.08, 0.06 }, "INV_BannerPVP_01" },
    { "warrior", "Warrior", { 0.55, 0.42, 0.28 }, "Ability_Warrior_BattleShout" },
    { "paladin", "Paladin", { 0.62, 0.36, 0.5 }, "Spell_Holy_HolyBolt" },
    { "hunter", "Hunter", { 0.36, 0.5, 0.25 }, "INV_Weapon_Bow_07" },
    { "rogue", "Rogue", { 0.55, 0.52, 0.22 }, "Ability_Stealth" },
    { "priest", "Priest", { 0.6, 0.6, 0.62 }, "Spell_Holy_PowerWordShield" },
    { "shaman", "Shaman", { 0.1, 0.3, 0.6 }, "Spell_Nature_BloodLust" },
    { "mage", "Mage", { 0.25, 0.5, 0.65 }, "Spell_Frost_FrostBolt02" },
    { "warlock", "Warlock", { 0.35, 0.3, 0.55 }, "Spell_Shadow_DeathCoil" },
    { "druid", "Druid", { 0.6, 0.35, 0.1 }, "Ability_Druid_CatForm" },
}
CardBacks.DEFAULT = "tavern"

local byId, available = {}, nil
for _, b in ipairs(LIST) do byId[b[1]] = b end

local function paintingPath(b)
    return type(b[3]) == "string" and (SCREENS .. b[3]) or nil
end

-- The backs this client can draw (paintings it has, plus every colour back).
function CardBacks:List()
    if not available then
        available = {}
        for _, b in ipairs(LIST) do
            local path = paintingPath(b)
            if not path or not GetFileIDFromPath or GetFileIDFromPath(path) then
                available[#available + 1] = { id = b[1], name = b[2] }
            end
        end
    end
    return available
end

function CardBacks:Valid(id)
    for _, b in ipairs(self:List()) do
        if b.id == id then return true end
    end
    return false
end

function CardBacks:Name(id)
    return byId[id] and byId[id][2] or byId[self.DEFAULT][2]
end

-- A random back the client has (the house's pick), steady for a given seed.
function CardBacks:Random(seed)
    local list = self:List()
    local i = seed and (math.floor(seed) % #list) + 1 or math.random(#list)
    return list[i].id
end

local function setBack(self, id)
    local b = byId[id] or byId[CardBacks.DEFAULT]
    local path = paintingPath(b)
    if path and (not GetFileIDFromPath or GetFileIDFromPath(path)) then
        -- A centred slice of the 4:3 painting with the card's proportions.
        local w, h = self.bw, self.bh
        local frac = math.min(1, (w / h) * 0.75)
        self.paint:SetTexture(path)
        self.paint:SetTexCoord(0.5 - frac / 2, 0.5 + frac / 2, 0, 1)
        self.paint:SetVertexColor(1, 1, 1)
    else
        local c = type(b[3]) == "table" and b[3] or { 0.28, 0.16, 0.08 }
        self.paint:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
        self.paint:SetTexCoord(0, 1, 0, 1)
        self.paint:SetVertexColor(c[1] * 1.6, c[2] * 1.6, c[3] * 1.6)
    end
    self.emblem:SetTexture(Art:SafeIcon(b[4]))
    self.backId = b[1]
end

-- A card back of the given size: painting, vignette, gold frame, emblem seal.
function CardBacks:Create(parent, w, h)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(w, h)
    f.bw, f.bh = w, h
    f:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = math.max(8, math.floor(w / 9)),
        insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    f:SetBackdropBorderColor(0.85, 0.68, 0.3, 1)
    local inset = math.max(2, math.floor(w / 25))
    f.paint = f:CreateTexture(nil, "BACKGROUND")
    f.paint:SetPoint("TOPLEFT", inset, -inset)
    f.paint:SetPoint("BOTTOMRIGHT", -inset, inset)
    f.vignette = f:CreateTexture(nil, "BORDER")
    f.vignette:SetAllPoints(f.paint)
    f.vignette:SetColorTexture(1, 1, 1, 1)
    f.vignette:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.55), CreateColor(0, 0, 0, 0.15))
    local seal = math.floor(math.min(w, h) * 0.46)
    f.ring = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.ring:SetSize(seal + 4, seal + 4)
    f.ring:SetPoint("CENTER")
    f.ring:SetColorTexture(0.85, 0.68, 0.3, 1)
    local ringMask = f:CreateMaskTexture()
    ringMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    ringMask:SetAllPoints(f.ring)
    f.ring:AddMaskTexture(ringMask)
    f.emblem = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.emblem:SetSize(seal, seal)
    f.emblem:SetPoint("CENTER")
    f.emblem:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local mask = f:CreateMaskTexture()
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(f.emblem)
    f.emblem:AddMaskTexture(mask)
    f.SetBack = setBack
    f:SetBack(CardBacks.DEFAULT)
    return f
end

-- ---- choosing a deck's back --------------------------------------------------------------------

local chooser

local function buildChooser()
    local d = CreateFrame("Frame", "TavernCardsBackChooser", UIParent, "BackdropTemplate")
    d:SetFrameStrata("FULLSCREEN_DIALOG")
    d:SetToplevel(true)
    d:EnableMouse(true)
    d:SetMovable(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:SetPoint("CENTER")
    d:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    d.title = d:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    d.title:SetPoint("TOP", 0, -18)
    local close = CreateFrame("Button", nil, d, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() d:Hide() end)
    d.items = {}
    tinsert(UISpecialFrames, "TavernCardsBackChooser")
    d:Hide()
    return d
end

local COLS, BW, BH, GAP = 7, 64, 94, 10

function CardBacks:Choose(deck, onChosen)
    chooser = chooser or buildChooser()
    local list = self:List()
    local rows = math.ceil(#list / COLS)
    chooser:SetSize(COLS * (BW + GAP) + 40, rows * (BH + GAP + 14) + 70)
    chooser.title:SetText(("Card back for \"%s\""):format(deck.name))
    for i, entry in ipairs(list) do
        local item = chooser.items[i]
        if not item then
            item = CreateFrame("Button", nil, chooser)
            item:SetSize(BW, BH + 14)
            item.back = self:Create(item, BW, BH)
            item.back:SetPoint("TOP")
            item.label = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            item.label:SetPoint("TOP", item.back, "BOTTOM", 0, -2)
            item.label:SetWidth(BW + GAP)
            item.label:SetWordWrap(false)
            item.glow = item:CreateTexture(nil, "OVERLAY")
            item.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
            item.glow:SetBlendMode("ADD")
            item.glow:SetVertexColor(1, 0.85, 0.2)
            item.glow:SetPoint("CENTER", item.back, "CENTER")
            item.glow:SetSize(BW * 1.9, BH * 1.75)
            item:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            item:GetHighlightTexture():SetAllPoints(item.back)
            chooser.items[i] = item
        end
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", 20 + col * (BW + GAP), -48 - row * (BH + GAP + 14))
        item.back:SetBack(entry.id)
        item.label:SetText(entry.name)
        item.glow:SetShown((deck.back or CardBacks.DEFAULT) == entry.id)
        item:SetScript("OnClick", function()
            deck.back = entry.id
            TC.Art:Play("IG_ABILITY_ICON_DROP")
            for _, other in ipairs(chooser.items) do other.glow:Hide() end
            item.glow:Show()
            if onChosen then onChosen(entry.id) end
        end)
        item:Show()
    end
    for i = #list + 1, #chooser.items do chooser.items[i]:Hide() end
    chooser:Show()
end
