-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- A card, in the binder, the hand and the zoom: a classic card frame (Textures/, drawn by
-- tools/textures/build.py) around the card's icon or 3D portrait. The frame's stone body takes the class
-- colour; gems carry cost, attack and health; the rarity gem sits on the name banner. Missing cards are
-- shown faded and desaturated.
--
--   local w = TC.CardWidget:Create(parent)
--   w:SetCard(id)

local TC = TavernCards_NS
local Art = TC.Art

local CardWidget = {}
TC.CardWidget = CardWidget

CardWidget.WIDTH, CardWidget.HEIGHT = 100, 148

local LAYOUT = TC.TexLayout

-- Card text sizes are set on the font string itself (no global font objects): the client's standard font.
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function setFont(fs, size, flags)
    if fs.SetFont then fs:SetFont(FONT, size, flags or "") end
end
CardWidget.SetFont = setFont

-- A gem with a number on it: kind is a cell of Textures/gems ("mana", "attack", "health", "durability",
-- "armor"). The number is bold white with an outline, sized to the gem, so it reads on any colour.
local function gem(parent, size, kind)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetPoint("CENTER")
    f.tex:SetSize(size * 1.12, size * 1.12)   -- the cell has a little margin around the gem
    Art:Cell(f.tex, "gems", kind)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("CENTER", 0, kind == "health" and -2 or 0)   -- the drop's body is below its middle
    setFont(f.text, math.floor(size * 0.56 + 0.5), "OUTLINE")
    f.text:SetShadowOffset(1, -1)
    f.text:SetShadowColor(0, 0, 0, 1)
    function f:SetKind(k) Art:Cell(self.tex, "gems", k) end
    return f
end

CardWidget.Gem = gem

-- Crafting and disenchanting, one copy at a time: Alt + Right-click crafts, Ctrl + Right-click
-- disenchants (Epic and Legendary ask first); a plain Right-click opens the menu with both.
local CRAFT_WHY = { dust = "Not enough dust.", cap = "You already have the most copies a deck can use." }

local function craftOne(id)
    local ok, why = TC.Collection:Craft(id)
    if ok then
        TC.Art:Play("IG_ABILITY_ICON_DROP")
    else
        UIErrorsFrame:AddMessage(CRAFT_WHY[why] or "That card can't be crafted.", 1, 0.1, 0.1)
    end
    return ok
end

local function disenchantOne(id, confirmed)
    local C = TC.Collection
    local card = TC.Cards[id]
    if C:IsBasic(id) then
        UIErrorsFrame:AddMessage("Basic cards can't be disenchanted.", 1, 0.1, 0.1)
        return
    end
    if C:Count(id) == 0 then
        UIErrorsFrame:AddMessage("You don't have a copy to disenchant.", 1, 0.1, 0.1)
        return
    end
    if not confirmed and (card.rarity == "EPIC" or card.rarity == "LEGENDARY") then
        TC:Confirm(("Disenchant %s for %d dust?"):format(TC.Art:ColoredName(id), C.DISENCHANT[card.rarity] or 0),
            function() disenchantOne(id, true) end)
        return
    end
    if C:Disenchant(id) then TC.Art:Play("IG_BACKPACK_COIN_SELECT") end
end

local function onEnter(self)
    if not self.id then
        return
    end
    if TC.db.unseen and TC.db.unseen[self.id] then
        TC.db.unseen[self.id] = nil
        self.newGlow:Hide()
        self.newText:Hide()
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    TC:CardTooltip(self.id)
    local C = TC.Collection
    local card = TC.Cards[self.id]
    local have, cap = C:Count(self.id), C:Cap(self.id)
    local blue, grey = { 0.5, 0.75, 1 }, { 0.5, 0.5, 0.5 }
    if not C:IsBasic(self.id) then
        local craftCost = C.CRAFT[card.rarity] or 0
        if have >= cap then
            GameTooltip:AddLine("Alt + Right-click: craft (you have the most a deck can use)", unpack(grey))
        elseif TC.db.dust < craftCost then
            GameTooltip:AddLine(("Alt + Right-click: craft (%d dust; you have %d)"):format(craftCost, TC.db.dust), unpack(grey))
        else
            GameTooltip:AddLine(("Alt + Right-click: craft a copy for %d dust"):format(craftCost), unpack(blue))
        end
        if have > 0 then
            GameTooltip:AddLine(("Ctrl + Right-click: disenchant a copy for %d dust"):format(C.DISENCHANT[card.rarity] or 0), unpack(blue))
        end
    end
    GameTooltip:AddLine("Right-click: more options   Shift-click: link in chat", unpack(blue))
    GameTooltip:Show()
end

local function contextMenu(self)
    local id = self.id
    if not id or not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    local card = TC.Cards[id]
    local C = TC.Collection
    MenuUtil.CreateContextMenu(self, function(_, root)
        root:CreateTitle(card.name)
        local craftCost = C.CRAFT[card.rarity] or 0
        local craft = root:CreateButton(("Craft a copy (%d dust)"):format(craftCost), function() craftOne(id) end)
        craft:SetEnabled(not C:IsBasic(id) and C:Count(id) < C:Cap(id) and TC.db.dust >= craftCost)
        local dis = root:CreateButton(("Disenchant a copy (+%d dust)"):format(C.DISENCHANT[card.rarity] or 0),
            function() disenchantOne(id) end)
        dis:SetEnabled(not C:IsBasic(id) and C:Count(id) > 0)
        root:CreateDivider()
        root:CreateButton("Link in chat", function() TC.Chat:InsertCard(id) end)
        local show = root:CreateButton("Show off in the tavern channel", function() TC.Channel:Say(TC.Chat:CardText(id)) end)
        show:SetEnabled(TC.Channel:Number() ~= nil)
    end)
end

local W, H = CardWidget.WIDTH, CardWidget.HEIGHT

-- Anchor a region to a rectangle given in card fractions ({x0, y0, x1, y1}, 0..1 down the card).
local function place(r, w, rect, grow)
    grow = grow or 0
    r:ClearAllPoints()
    r:SetPoint("TOPLEFT", w, "TOPLEFT", rect[1] * W - grow, -rect[2] * H + grow)
    r:SetPoint("BOTTOMRIGHT", w, "TOPLEFT", rect[3] * W + grow, -rect[4] * H - grow)
end

local function placeAt(r, w, pt)
    r:ClearAllPoints()
    r:SetPoint("CENTER", w, "TOPLEFT", pt[1] * W, -pt[2] * H)
end

-- Hovering lights the card's own shape. The button's highlight layer would sit under the frame.
local function addHover(w)
    w:HookScript("OnEnter", function(self) self.hover:Show() end)
    w:HookScript("OnLeave", function(self) self.hover:Hide() end)
end

function CardWidget:Create(parent)
    local w = CreateFrame("Button", nil, parent)
    w:SetSize(W, H)
    local base = w:GetFrameLevel()

    -- The portrait: the card's icon, and over it the creature in 3D when there is one (UI/Models.lua).
    w.art = w:CreateTexture(nil, "ARTWORK")
    w.art:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    if TC.Models then
        w.model = TC.Models:Create(w)
        w.model:SetFrameLevel(base + 1)
    end

    -- The frame, above the portrait: the body is opaque around the window, so it clips a square model to
    -- the window's shape.
    w.dress = CreateFrame("Frame", nil, w)
    w.dress:SetAllPoints()
    w.dress:SetFrameLevel(base + 2)
    w.body = w.dress:CreateTexture(nil, "BORDER")
    w.body:SetAllPoints()
    w.trim = w.dress:CreateTexture(nil, "ARTWORK")
    w.trim:SetAllPoints()
    w.wings = w.dress:CreateTexture(nil, "ARTWORK", nil, 2)
    w.wings:SetTexture(Art:Tex("frame_legendary"))
    local leg = LAYOUT.card.legendary
    w.wings:SetPoint("TOPLEFT", w, "TOPLEFT", 0, -leg[1] * H)
    w.wings:SetPoint("BOTTOMRIGHT", w, "TOPLEFT", W, -leg[2] * H)
    w.hover = w.dress:CreateTexture(nil, "OVERLAY", nil, 7)
    w.hover:SetAllPoints()
    w.hover:SetBlendMode("ADD")
    w.hover:SetAlpha(0.18)
    w.hover:Hide()

    w.name = w.dress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    setFont(w.name, 11, "OUTLINE")
    w.name:SetJustifyH("CENTER")
    w.name:SetJustifyV("MIDDLE")
    w.name:SetWordWrap(false)
    w.name:SetShadowColor(0, 0, 0, 1)
    w.name:SetShadowOffset(1, -1)
    w.rarity = w.dress:CreateTexture(nil, "OVERLAY", nil, 1)
    w.rarity:SetSize(13, 13)
    w.text = w.dress:CreateFontString(nil, "OVERLAY", "GameFontBlackTiny")
    setFont(w.text, 9)
    w.text:SetJustifyH("CENTER")
    w.text:SetJustifyV("MIDDLE")
    w.text:SetTextColor(0.16, 0.1, 0.05)
    w.kind = w.dress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.kind:SetTextColor(0.98, 0.92, 0.78)
    w.kind:SetShadowColor(0, 0, 0, 1)
    w.kind:SetShadowOffset(1, -1)
    setFont(w.kind, 8)

    w.cost = gem(w, 28, "mana")
    w.attack = gem(w, 27, "attack")
    w.health = gem(w, 27, "health")
    for _, g in ipairs({ w.cost, w.attack, w.health }) do g:SetFrameLevel(base + 3) end

    w.count = w:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.count:SetPoint("TOP", w, "BOTTOM", 0, 1)

    -- Whose card it is, besides the frame colour: the class icon in the top-right corner, as big as the
    -- cost gem opposite (none for Neutral).
    w.crest = CreateFrame("Frame", nil, w)
    w.crest:SetSize(26, 26)
    w.crest:SetPoint("CENTER", w, "TOPRIGHT", -LAYOUT.minion.cost[1] * W, -LAYOUT.minion.cost[2] * H)
    w.crest:SetFrameLevel(base + 3)
    w.crest.icon = w.crest:CreateTexture(nil, "ARTWORK")
    w.crest.icon:SetAllPoints()
    w.crest.round = w.crest:CreateMaskTexture()
    w.crest.round:SetTexture(Art:Tex("mask_round"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    w.crest.round:SetAllPoints(w.crest.icon)
    w.crest.icon:AddMaskTexture(w.crest.round)
    w.crest.masked = true

    -- Above everything: the New and later markers.
    w.top = CreateFrame("Frame", nil, w)
    w.top:SetAllPoints()
    w.top:SetFrameLevel(base + 4)
    w.newGlow = w.top:CreateTexture(nil, "OVERLAY")
    if TC.Compat:HasAtlas("collections-newglow") then
        w.newGlow:SetAtlas("collections-newglow")
    end
    w.newGlow:SetPoint("CENTER", w, "TOPRIGHT", -14, -30)
    w.newGlow:SetSize(50, 40)
    w.newText = w.top:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.newText:SetPoint("CENTER", w.newGlow)
    w.newText:SetText(NEW or "New")
    w.newText:SetTextColor(0.1, 1, 0.1)
    w.later = w.top:CreateTexture(nil, "OVERLAY")
    w.later:SetSize(14, 14)
    w.later:SetPoint("TOPRIGHT", -6, -24)
    w.later:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")

    w:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    w:SetScript("OnEnter", onEnter)
    w:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w:SetScript("OnClick", function(self, button)
        if button == "RightButton" and self.id and IsAltKeyDown and IsAltKeyDown() then
            craftOne(self.id)
            if self:IsMouseOver() then onEnter(self) end
        elseif button == "RightButton" and self.id and IsControlKeyDown and IsControlKeyDown() then
            disenchantOne(self.id)
            if self:IsMouseOver() then onEnter(self) end
        elseif button == "RightButton" then
            contextMenu(self)
        elseif self.id and IsModifiedClick and IsModifiedClick("CHATLINK") then
            TC.Chat:InsertCard(self.id)
        elseif self.onLeftClick and self.id then
            self.onLeftClick(self.id)
        end
    end)
    addHover(w)
    w.SetCard = CardWidget.SetCard
    return w
end

-- A card in a match hand: same face, game tooltip, and clicks go to w.onClick(w, button).
function CardWidget:CreateGame(parent)
    local w = self:Create(parent)
    w.game = true
    w:SetScript("OnEnter", function(self)
        if not self.id then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        TC:CardTooltip(self.id, true)
        GameTooltip:Show()
        if self.onEnter then self.onEnter(self) end
    end)
    w:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self.onLeave then self.onLeave(self) end
    end)
    w:SetScript("OnClick", function(self, button)
        if self.onClick then self.onClick(self, button) end
    end)
    addHover(w)   -- SetScript dropped the hooks
    return w
end

-- Card type -> frame (Textures/frame_<kind>[_body], TC.TexLayout[kind]).
local FRAME_OF = { MINION = "minion", SPELL = "spell", WEAPON = "weapon", HERO = "hero", LOCATION = "spell" }
local SCHOOLS = { arcane = "Arcane", fire = "Fire", frost = "Frost", nature = "Nature", holy = "Holy",
    shadow = "Shadow", fel = "Fel" }

-- Dress the frame for a card type: textures and where the window, banner, text and gems sit.
local function setFrame(w, kind)
    if w.frameKind == kind then return end
    w.frameKind = kind
    local L = LAYOUT[kind]
    local bottom = LAYOUT.card.texBottom
    w.body:SetTexture(Art:Tex("frame_" .. kind .. "_body"))
    w.body:SetTexCoord(0, 1, 0, bottom)
    w.trim:SetTexture(Art:Tex("frame_" .. kind))
    w.trim:SetTexCoord(0, 1, 0, bottom)
    w.hover:SetTexture(Art:Tex("frame_" .. kind .. "_body"))
    w.hover:SetTexCoord(0, 1, 0, bottom)
    place(w.art, w, L.window, 2)
    if w.model then place(w.model, w, L.window, 1) end
    place(w.name, w, L.name, -1)
    place(w.text, w, L.text, -3)
    placeAt(w.kind, w, L.plate)
    placeAt(w.rarity, w, L.rarity)
    placeAt(w.cost, w, L.cost)
    if L.attack then placeAt(w.attack, w, L.attack) end
    if L.health then placeAt(w.health, w, L.health) end
end

-- Rules text for the card face: dark ink on parchment, so the tooltip's white emphasis goes dark too.
local function faceText(id)
    return (Art:RulesText(id):gsub("|cffffffff", "|cff000000"))
end

function CardWidget.SetCard(w, id)
    w.id = id
    local card = id and TC.Cards[id]
    if not card then
        w:Hide()
        return
    end
    w:Show()
    local have = TC.Collection:Count(id)
    setFrame(w, FRAME_OF[card.type] or "spell")
    w.body:SetVertexColor(Art:ClassTint(card.family))

    w.art:SetTexture(Art:Icon(id))
    -- A picked head shot (TC.CardPortraits, tools/picker), else the creature a card is named after. Portrait
    -- zoom 1 is the head-and-shoulders shot the target frame shows; the pick turns it and pulls back.
    -- A creature from outside Forever's world is shown by its model (display id).
    -- A prop (item or object) shows whole rather than as a head shot.
    local portrait = w.model and TC.CardPortraits and TC.CardPortraits[id]
    local kind, npc, file, zoom = "npc", nil, nil, 1
    if portrait then
        local prop = portrait[5]
        if type(prop) == "table" then
            kind, npc, file, zoom = prop[1], prop[2], prop[3], 0
        elseif (portrait[4] or 0) > 0 then kind, npc = "display", portrait[4] else npc = portrait[1] end
    elseif w.model and TC.CardNamedNPC and TC.CardNamedNPC[id] then
        local prop = TC.CardProps and TC.CardProps[id]
        local disp = (TC.CardDisplays and TC.CardDisplays[id]) or (TC.CardModelDisplays and TC.CardModelDisplays[id])
        if prop then kind, npc, file, zoom = prop[1], prop[2], prop[3], 0
        elseif disp then kind, npc = "display", disp else npc = TC.CardModels and TC.CardModels[id] end
    end
    local facing, dist = portrait and portrait[2], portrait and portrait[3] or 1
    if npc and TC.Models:Show(w.model, kind, npc, zoom, dist, facing, function() w.art:SetAlpha(1) end, file) then
        w.art:SetAlpha(TC.Models:ArtAlpha(0.25))
        w.model:SetAlpha((w.game or TC.Collection:Count(id) > 0) and 1 or 0.55)
    else
        if w.model then TC.Models:Hide(w.model) end
        w.art:SetAlpha(1)
    end

    w.name:SetText(card.name)
    if w.name.SetTextScale then
        -- Long names shrink to fit the banner rather than run off it.
        w.name:SetTextScale(1)
        local room, need = w.name:GetWidth() or 0, w.name.GetUnboundedStringWidth and w.name:GetUnboundedStringWidth() or 0
        if room > 0 and need > room then w.name:SetTextScale(math.max(0.82, room / need)) end
    end
    w.text:SetText(faceText(id))
    w.cost.text:SetText(card.cost)

    local rarity = card.rarity ~= "FREE" and card.rarity:lower()
    if rarity and LAYOUT.gems[rarity] then
        Art:Cell(w.rarity, "gems", rarity)
        w.rarity:Show()
    else
        w.rarity:Hide()
    end
    w.wings:SetShown(card.rarity == "LEGENDARY")

    if card.type == "MINION" then
        w.attack.text:SetText(card.attack)
        w.health.text:SetText(card.health)
        w.health:SetKind("health")
        w.attack:Show()
        w.health:Show()
    elseif card.type == "WEAPON" then
        w.attack.text:SetText(card.attack)
        w.health.text:SetText(card.durability)
        w.health:SetKind("durability")
        w.attack:Show()
        w.health:Show()
    else
        w.attack:Hide()
        w.health:Hide()
    end
    -- The plate under the text: the minion's tribe, or the spell's school.
    local plate = TC.TribeText and TC:TribeText(card.races)
    if plate and plate:find(",") then plate = "Multiple" end
    if not plate or plate == "" then plate = SCHOOLS[card.school or ""] or (card.type == "LOCATION" and "Location" or "") end
    w.kind:SetText(plate)
    if w.kind.SetTextScale then
        -- Long tribes ("Elemental", "Mechanical") shrink to fit the plate.
        w.kind:SetTextScale(1)
        local room = (LAYOUT.plateWidth or 0.44) * W
        local need = w.kind.GetUnboundedStringWidth and w.kind:GetUnboundedStringWidth() or 0
        if need > room then w.kind:SetTextScale(math.max(0.6, room / need)) end
    end

    -- The old class sheet has no Death Knight / Demon Hunter cell even where the coordinate table lists them.
    local oldSheet = card.family ~= "DEATHKNIGHT" and card.family ~= "DEMONHUNTER"
    local coords = oldSheet and card.family ~= "NEUTRAL" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[card.family]
    -- The round class emblem (transparent round it, so no box) first; the square icon only for classes the
    -- emblem sheet lacks, and then clipped round.
    local square = not coords and card.family ~= "NEUTRAL" and Art:SquareClassIcon(card.family)
    local wantRound = not coords
    if wantRound ~= w.crest.masked then   -- a mask can't be hidden, only removed
        if wantRound then w.crest.icon:AddMaskTexture(w.crest.round) else w.crest.icon:RemoveMaskTexture(w.crest.round) end
        w.crest.masked = wantRound
    end
    if coords then
        w.crest.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        w.crest.icon:SetTexCoord(unpack(coords))
        w.crest:Show()
    elseif square then
        w.crest.icon:SetTexture(square)
        w.crest.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        w.crest:Show()
    elseif card.family ~= "NEUTRAL" then
        w.crest.icon:SetTexture(Art:ClassIcon(card.family))
        w.crest.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        w.crest:Show()
    else
        w.crest:Hide()
    end

    local owned = w.game or have > 0
    for _, t in ipairs({ w.art, w.body, w.trim, w.wings, w.rarity, w.cost.tex, w.attack.tex, w.health.tex }) do
        t:SetDesaturated(not owned)
    end
    if w.game then
        -- A card in a match: always "owned"; the cost shown is what it costs now.
        w.count:SetText("")
        w.cost.text:SetText(w.costNow or card.cost)
        if w.costNow and w.costNow < card.cost then
            w.cost.text:SetTextColor(0.3, 1, 0.3)
        elseif w.costNow and w.costNow > card.cost then
            w.cost.text:SetTextColor(1, 0.3, 0.3)
        else
            w.cost.text:SetTextColor(1, 1, 1)
        end
        w:SetAlpha(1)
        w.newGlow:Hide()
        w.newText:Hide()
        w.later:Hide()
        return
    end
    w.count:SetText(have > 1 and ("x" .. have) or "")
    w:SetAlpha(owned and 1 or 0.8)

    local unseen = owned and TC.db.unseen and TC.db.unseen[id]
    w.newGlow:SetShown(unseen and true or false)
    w.newText:SetShown(unseen and true or false)
    -- Only meaningful once the engine plays some cards; until then every card would carry it.
    w.later:SetShown(TC.EngineReady and not TC.PlayableNow[id] or false)
end
