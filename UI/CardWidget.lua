-- The mini card shown in the binder: parchment face, rarity border, art window, cost gem, name, type
-- line, and attack / health (or durability) badges. Missing cards are shown faded and desaturated.
--
--   local w = TC.CardWidget:Create(parent)
--   w:SetCard(id)

local TC = TavernCards_NS
local Art = TC.Art

local CardWidget = {}
TC.CardWidget = CardWidget

CardWidget.WIDTH, CardWidget.HEIGHT = 100, 140

local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local PARCHMENT = "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal-Desaturated"

-- A round gem: a tinted disc clipped by the round portrait mask, a dark rim, and a number.
local function gem(parent, size, r, g, b, font)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    f.rim = f:CreateTexture(nil, "ARTWORK", nil, 1)
    f.rim:SetAllPoints()
    f.rim:SetColorTexture(0.08, 0.06, 0.04, 1)
    local rimMask = f:CreateMaskTexture()
    rimMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    rimMask:SetAllPoints(f.rim)
    f.rim:AddMaskTexture(rimMask)

    f.disc = f:CreateTexture(nil, "ARTWORK", nil, 2)
    f.disc:SetPoint("TOPLEFT", 2, -2)
    f.disc:SetPoint("BOTTOMRIGHT", -2, 2)
    f.disc:SetColorTexture(r, g, b, 1)
    f.disc:SetGradient("VERTICAL", CreateColor(r * 0.55, g * 0.55, b * 0.55, 1), CreateColor(r, g, b, 1))
    local mask = f:CreateMaskTexture()
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(f.disc)
    f.disc:AddMaskTexture(mask)

    f.text = f:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    f.text:SetPoint("CENTER", 0, 0)
    f.text:SetShadowOffset(1, -1)
    return f
end

CardWidget.Gem = gem

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
    local card = TC.Cards[self.id]
    local have = TC.Collection:Count(self.id)
    if have > 0 then
        GameTooltip:AddLine(("Right-click: disenchant for %d dust"):format(TC.Collection.DISENCHANT[card.rarity] or 0), 0.5, 0.75, 1)
    end
    if have < TC.Collection:Cap(self.id) then
        GameTooltip:AddLine(("Right-click: craft for %d dust"):format(TC.Collection.CRAFT[card.rarity] or 0), 0.5, 0.75, 1)
    end
    GameTooltip:AddLine("Shift-click: link in chat", 0.5, 0.75, 1)
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
        local craft = root:CreateButton(("Craft (%d dust)"):format(craftCost), function()
            local ok, why = C:Craft(id)
            if not ok then
                TC:Print(why == "dust" and "Not enough dust." or "You already have the most copies a deck can use.")
            end
        end)
        craft:SetEnabled(C:Count(id) < C:Cap(id) and TC.db.dust >= craftCost)
        local dis = root:CreateButton(("Disenchant (+%d dust)"):format(C.DISENCHANT[card.rarity] or 0), function()
            C:Disenchant(id)
        end)
        dis:SetEnabled(C:Count(id) > 0)
        root:CreateDivider()
        root:CreateButton("Link in chat", function() TC.Chat:InsertCard(id) end)
        local show = root:CreateButton("Show off in the tavern channel", function() TC.Channel:Say(TC.Chat:CardText(id)) end)
        show:SetEnabled(TC.Channel:Number() ~= nil)
    end)
end

function CardWidget:Create(parent)
    local w = CreateFrame("Button", nil, parent, "BackdropTemplate")
    w:SetSize(self.WIDTH, self.HEIGHT)
    w:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 } })

    w.face = w:CreateTexture(nil, "BACKGROUND")
    w.face:SetPoint("TOPLEFT", 3, -3)
    w.face:SetPoint("BOTTOMRIGHT", -3, 3)
    w.face:SetTexture(PARCHMENT)
    w.face:SetTexCoord(0.05, 0.45, 0.05, 0.95)

    -- Art window with a dark frame line.
    w.artFrame = w:CreateTexture(nil, "BORDER")
    w.artFrame:SetPoint("TOPLEFT", 9, -14)
    w.artFrame:SetPoint("TOPRIGHT", -9, -14)
    w.artFrame:SetHeight(58)
    w.artFrame:SetColorTexture(0.12, 0.09, 0.06, 1)
    w.art = w:CreateTexture(nil, "ARTWORK")
    w.art:SetPoint("TOPLEFT", w.artFrame, 1, -1)
    w.art:SetPoint("BOTTOMRIGHT", w.artFrame, -1, 1)
    w.art:SetTexCoord(0.08, 0.92, 0.22, 0.78)

    -- Dark banner behind the name so rarity colors read on parchment.
    w.banner = w:CreateTexture(nil, "BORDER", nil, 1)
    w.banner:SetPoint("TOPLEFT", w.artFrame, "BOTTOMLEFT", -5, -2)
    w.banner:SetPoint("TOPRIGHT", w.artFrame, "BOTTOMRIGHT", 5, -2)
    w.banner:SetHeight(26)
    w.banner:SetColorTexture(0.06, 0.04, 0.03, 0.82)

    w.name = w:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.name:SetPoint("TOPLEFT", w.artFrame, "BOTTOMLEFT", -3, -3)
    w.name:SetPoint("TOPRIGHT", w.artFrame, "BOTTOMRIGHT", 3, -3)
    w.name:SetHeight(24)
    w.name:SetJustifyV("MIDDLE")
    w.name:SetShadowOffset(1, -1)
    if w.name.SetMaxLines then
        w.name:SetMaxLines(2)
    end

    w.kind = w:CreateFontString(nil, "OVERLAY", "GameFontBlackTiny")
    w.kind:SetPoint("TOP", w.name, "BOTTOM", 0, -1)
    w.kind:SetTextColor(0.12, 0.07, 0.02)
    w.kind:SetShadowColor(1, 0.95, 0.8, 0.35)
    w.kind:SetShadowOffset(1, -1)

    w.cost = gem(w, 24, 0.15, 0.4, 0.95, "GameFontHighlight")
    w.cost:SetPoint("TOPLEFT", -4, 4)
    w.attack = gem(w, 22, 0.85, 0.65, 0.15, "GameFontHighlightSmall")
    w.attack:SetPoint("BOTTOMLEFT", -3, -3)
    w.health = gem(w, 22, 0.75, 0.12, 0.1, "GameFontHighlightSmall")
    w.health:SetPoint("BOTTOMRIGHT", 3, -3)

    w.count = w:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    w.count:SetPoint("BOTTOM", 0, 7)

    w.newGlow = w:CreateTexture(nil, "OVERLAY")
    if TC.Compat:HasAtlas("collections-newglow") then
        w.newGlow:SetAtlas("collections-newglow")
    end
    w.newGlow:SetPoint("CENTER", w.art, "TOPRIGHT", -6, 0)
    w.newGlow:SetSize(50, 40)
    w.newText = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.newText:SetPoint("CENTER", w.newGlow)
    w.newText:SetText(NEW or "New")
    w.newText:SetTextColor(0.1, 1, 0.1)

    -- Whose card it is: the class crest in the top-right corner (none for Neutral).
    w.crest = CreateFrame("Frame", nil, w)
    w.crest:SetSize(22, 22)
    w.crest:SetPoint("TOPRIGHT", 4, 4)
    w.crest.rim = w.crest:CreateTexture(nil, "ARTWORK", nil, 1)
    w.crest.rim:SetAllPoints()
    w.crest.rim:SetColorTexture(0.08, 0.06, 0.04, 1)
    local crestRimMask = w.crest:CreateMaskTexture()
    crestRimMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    crestRimMask:SetAllPoints(w.crest.rim)
    w.crest.rim:AddMaskTexture(crestRimMask)
    w.crest.icon = w.crest:CreateTexture(nil, "ARTWORK", nil, 2)
    w.crest.icon:SetPoint("TOPLEFT", 2, -2)
    w.crest.icon:SetPoint("BOTTOMRIGHT", -2, 2)
    local crestMask = w.crest:CreateMaskTexture()
    crestMask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    crestMask:SetAllPoints(w.crest.icon)
    w.crest.icon:AddMaskTexture(crestMask)

    w.later = w:CreateTexture(nil, "OVERLAY")
    w.later:SetSize(14, 14)
    w.later:SetPoint("TOPRIGHT", -6, -22)
    w.later:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")

    w:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    w:GetHighlightTexture():SetPoint("TOPLEFT", 3, -3)
    w:GetHighlightTexture():SetPoint("BOTTOMRIGHT", -3, 3)
    w:GetHighlightTexture():SetAlpha(0.35)

    w:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    w:SetScript("OnEnter", onEnter)
    w:SetScript("OnLeave", function() GameTooltip:Hide() end)
    w:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            contextMenu(self)
        elseif self.id and IsModifiedClick and IsModifiedClick("CHATLINK") then
            TC.Chat:InsertCard(self.id)
        elseif self.onLeftClick and self.id then
            self.onLeftClick(self.id)
        end
    end)
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
    return w
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
    local r, g, b = Art:RarityColor(card.rarity)
    w:SetBackdropBorderColor(r, g, b, 1)

    w.art:SetTexture(Art:Icon(id))
    w.name:SetText(card.name)
    w.name:SetTextColor(r, g, b)
    w.cost.text:SetText(card.cost)

    local kind
    if card.type == "MINION" then
        kind = "Minion"
        w.attack.text:SetText(card.attack)
        w.health.text:SetText(card.health)
        w.attack:Show()
        w.health:Show()
    elseif card.type == "WEAPON" then
        kind = "Weapon"
        w.attack.text:SetText(card.attack)
        w.health.text:SetText(card.durability)
        w.attack:Show()
        w.health:Show()
    else
        kind = card.type == "SPELL" and "Spell" or "Location"
        w.attack:Hide()
        w.health:Hide()
    end
    local tribe = TC.TribeText and TC:TribeText(card.races)
    if tribe and not tribe:find(",") then kind = kind .. " - " .. tribe end
    w.kind:SetText(kind)
    -- The old class sheet has no Death Knight / Demon Hunter cell even where the coordinate table lists them.
    local oldSheet = card.family ~= "DEATHKNIGHT" and card.family ~= "DEMONHUNTER"
    local coords = oldSheet and card.family ~= "NEUTRAL" and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[card.family]
    if coords then
        w.crest.icon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        w.crest.icon:SetTexCoord(unpack(coords))
        w.crest:Show()
    elseif card.family ~= "NEUTRAL" then
        w.crest.icon:SetTexture(Art:ClassIcon(card.family))
        w.crest.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        w.crest:Show()
    else
        w.crest:Hide()
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
        w.art:SetDesaturated(false)
        w.art:SetVertexColor(1, 1, 1)
        w.face:SetVertexColor(1, 1, 1)
        w:SetAlpha(1)
        w.newGlow:Hide()
        w.newText:Hide()
        w.later:Hide()
        return
    end
    w.count:SetText(have > 1 and ("x" .. have) or "")
    local owned = have > 0
    w.art:SetDesaturated(not owned)
    w.art:SetVertexColor(owned and 1 or 0.7, owned and 1 or 0.7, owned and 1 or 0.7)
    w.face:SetVertexColor(owned and 1 or 0.72, owned and 1 or 0.72, owned and 1 or 0.72)
    w:SetAlpha(owned and 1 or 0.85)

    local unseen = owned and TC.db.unseen and TC.db.unseen[id]
    w.newGlow:SetShown(unseen and true or false)
    w.newText:SetShown(unseen and true or false)
    -- Only meaningful once the engine plays some cards; until then every card would carry it.
    w.later:SetShown(TC.EngineReady and not TC.PlayableNow[id] or false)
end
