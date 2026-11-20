-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Card backs: what your opponent sees of your cards. Each deck can wear one it has earned
-- (TC.CardBacks:Choose; Sources/Backs.lua earns them); the house picks any at random each match. A back is a
-- crop of a dungeon or raid painting (the loading screens) or of a zone's world map, under a light vignette
-- and a gold frame; the class and faction backs show their emblem art (always present in the client).
--
--   local b = TC.CardBacks:Create(parent, w, h)    b:SetBack(id)

local TC = TavernCards_NS
local Art = TC.Art

local CardBacks = {}
TC.CardBacks = CardBacks

local SCREENS = "Interface\\Glues\\LoadingScreens\\"

-- { id, name, art, emblem icon, rule }: Data/CardBacks.lua.
local LIST = TC.CardBackList
CardBacks.DEFAULT = "tavern"

local byId, available = {}, nil
for _, b in ipairs(LIST) do byId[b[1]] = b end

local function paintingPath(b)
    return type(b[3]) == "string" and (SCREENS .. b[3]) or nil
end

-- A zone back's art: the middle tile of the zone's world map (the client's map art, else the old
-- Interface\WorldMap tiles). Returns a texture (file id or path), or nil when the client has neither.
local function zoneArt(b)
    local art = type(b[3]) == "table" and b[3].map and b[3]
    if not art then return nil end
    local mapArt = TC.Board and TC.Board.MapArt
    local layer, tiles
    if mapArt then layer, tiles = mapArt(art.map) end   -- not "mapArt and mapArt(...)": that keeps one value
    if layer then
        local cols = math.max(1, math.ceil(layer.layerWidth / layer.tileWidth))
        local rows = math.max(1, math.ceil(#tiles / cols))
        local mid = math.floor(rows / 2) * cols + math.floor((cols + 1) / 2)
        return tiles[math.min(#tiles, math.max(1, mid))]
    end
    local path = ("Interface\\WorldMap\\%s\\%s6"):format(art.folder, art.folder)
    if not GetFileIDFromPath or GetFileIDFromPath(path) then return path end
end

-- The backs this client can draw (paintings it has, plus every colour back).
function CardBacks:List()
    if not available then
        available = {}
        for _, b in ipairs(LIST) do
            local path = paintingPath(b)
            local drawable = (type(b[3]) == "table" and b[3].map) and zoneArt(b) ~= nil
                or not path or not GetFileIDFromPath or GetFileIDFromPath(path)
            if drawable then
                available[#available + 1] = { id = b[1], name = b[2] }
            end
        end
    end
    return available
end

-- The paintings this client has, as { name, file } (the Play tab's Table choice uses them too).
function CardBacks:Paintings()
    local out = {}
    for _, b in ipairs(LIST) do
        local path = paintingPath(b)
        if path and (not GetFileIDFromPath or GetFileIDFromPath(path)) then
            out[#out + 1] = { name = b[2], file = b[3] }
        end
    end
    return out
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

-- Earned: the default, or unlocked in TavernCardsDB.backs (Sources/Backs.lua).
function CardBacks:Unlocked(id)
    return not TC.Backs or TC.Backs:IsUnlocked(id)
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
    local w, h = self.bw, self.bh
    local zone = zoneArt(b)
    if zone then
        -- The middle of the zone's map, in the card's proportions.
        local frac = math.min(1, w / h)
        self.paint:SetTexture(zone)
        self.paint:SetTexCoord(0.5 - frac / 2, 0.5 + frac / 2, 0, 1)
    elseif path and (not GetFileIDFromPath or GetFileIDFromPath(path)) then
        -- A centred slice of the whole 4:3 painting (with the World of Warcraft logo across its top) in the
        -- card's proportions.
        local frac = math.min(1, (w / h) * 0.75)
        self.paint:SetTexture(path)
        self.paint:SetTexCoord(0.5 - frac / 2, 0.5 + frac / 2, 0, 1)
    else
        -- The faction and class backs: their emblem art fills the card (a centred slice of the icon).
        local frac = math.min(0.86, (w / h) * 0.86)
        self.paint:SetTexture(Art:SafeIcon(b[4]))
        self.paint:SetTexCoord(0.5 - frac / 2, 0.5 + frac / 2, 0.07, 0.93)
    end
    self.paint:SetVertexColor(1, 1, 1)
    self.backId = b[1]
end

-- A card back of the given size: the art, a light vignette, and our carved wood-and-gold back frame
-- (Textures/card_back_frame, whose opening starts 20/256 of the width in).
function CardBacks:Create(parent, w, h)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, h)
    f.bw, f.bh = w, h
    local inset = math.max(2, math.floor(w * 20 / 256 + 0.5))
    f.paint = f:CreateTexture(nil, "BACKGROUND")
    f.paint:SetPoint("TOPLEFT", inset, -inset)
    f.paint:SetPoint("BOTTOMRIGHT", -inset, inset)
    f.vignette = f:CreateTexture(nil, "BORDER")
    f.vignette:SetAllPoints(f.paint)
    f.vignette:SetColorTexture(1, 1, 1, 1)
    f.vignette:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.35), CreateColor(0, 0, 0, 0.05))
    f.frame = f:CreateTexture(nil, "ARTWORK")
    f.frame:SetAllPoints()
    f.frame:SetTexture(Art:Tex("card_back_frame"))
    f.frame:SetTexCoord(0, 1, 0, TC.TexLayout.card.texBottom)
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

local COLS, BW, BH, GAP = 11, 52, 76, 10

local function showHint(item)
    GameTooltip:SetOwner(item, "ANCHOR_RIGHT")
    GameTooltip:SetText(item.entry.name, 1, 0.82, 0)
    if item.locked then
        GameTooltip:AddLine("Not earned yet", 1, 0.3, 0.3)
        GameTooltip:AddLine(TC.Backs and TC.Backs:Hint(item.entry.id) or "", 1, 1, 1, true)
    elseif item.deck then
        GameTooltip:AddLine("Click to use it for this deck.", 0.5, 0.75, 1)
    else
        GameTooltip:AddLine("Earned. Choose it for a deck on the Decks tab.", 0.5, 1, 0.5, true)
    end
    GameTooltip:Show()
end

-- The card back window. With a deck: pick that deck's back (earned backs only). Without one: the gallery,
-- every back with the ones still to earn greyed out and how to earn them in the tooltip.
function CardBacks:Choose(deck, onChosen)
    chooser = chooser or buildChooser()
    local list = self:List()
    local rows = math.ceil(#list / COLS)
    chooser:SetSize(COLS * (BW + GAP) + 30, rows * (BH + GAP + 14) + 70)
    local have, total = 0, #list
    for _, entry in ipairs(list) do if self:Unlocked(entry.id) then have = have + 1 end end
    chooser.title:SetText(deck and ("Card back for \"%s\"  (%d of %d earned)"):format(deck.name, have, total)
        or ("Card backs: %d of %d earned"):format(have, total))
    for i, entry in ipairs(list) do
        local item = chooser.items[i]
        if not item then
            item = CreateFrame("Button", nil, chooser)
            item:SetSize(BW, BH + 14)
            item.back = self:Create(item, BW, BH)
            item.back:SetPoint("TOP")
            item.shade = item.back:CreateTexture(nil, "OVERLAY")
            item.shade:SetAllPoints()
            item.shade:SetColorTexture(0, 0, 0, 0.55)
            item.lock = item.back:CreateTexture(nil, "OVERLAY", nil, 1)
            item.lock:SetSize(22, 22)
            item.lock:SetPoint("CENTER")
            item.lock:SetTexture(Art:SafeIcon("INV_Misc_Key_03"))
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
            item:SetScript("OnEnter", showHint)
            item:SetScript("OnLeave", function() GameTooltip:Hide() end)
            chooser.items[i] = item
        end
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        item:ClearAllPoints()
        item:SetPoint("TOPLEFT", 15 + col * (BW + GAP), -48 - row * (BH + GAP + 14))
        item.entry, item.deck = entry, deck
        item.locked = not self:Unlocked(entry.id)
        item.back:SetBack(entry.id)
        item.back.paint:SetDesaturated(item.locked)
        item.shade:SetShown(item.locked)
        item.lock:SetShown(item.locked)
        item.label:SetText(entry.name)
        item.label:SetTextColor(item.locked and 0.55 or 1, item.locked and 0.55 or 1, item.locked and 0.55 or 1)
        item.glow:SetShown(deck ~= nil and (deck.back or CardBacks.DEFAULT) == entry.id)
        item:SetScript("OnClick", function()
            if item.locked then
                UIErrorsFrame:AddMessage(TC.Backs and TC.Backs:Hint(entry.id) or "Not earned yet.", 1, 0.82, 0)
                return
            end
            if not deck then return end
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

-- The gallery: every back, earned or not.
function CardBacks:Gallery()
    self:Choose(nil)
end
