-- The tavern table: the match board. The opponent sits at the top, you at the bottom.
--
-- The board never changes the game itself. It reads the engine's state, and every click is matched
-- against engine:legal_moves(): picking a card narrows the legal moves to that card's, further clicks
-- (an option, a board slot, a target) narrow them again until one is left, and that move index goes
-- to TC.Match. Right-click cancels a half-made move.

local TC = TavernCards_NS
local D = TC.EngineDefs
local Art, Match, CardWidget = TC.Art, TC.Match, TC.CardWidget
local ZONE, PHASE, KW = D.ZONE, D.PHASE, D.KW
local band = bit.band

local Board = {}
TC.Board = Board

local W, H = 1000, 670
local SLOT_W, SLOT_H, SLOT_GAP = 84, 104, 6
local HAND_SCALE = 0.85
local GLOW = "Interface\\Buttons\\UI-ActionButton-Border"
local MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"
local gem = CardWidget.Gem
local HUGE_FONT = _G.GameFont_Gigantic and "GameFont_Gigantic" or "GameFontNormalHuge"

local POWER_ICONS = { [1] = "Ability_Warrior_ShieldWall", [2] = "Spell_Holy_SealOfMight", [3] = "Ability_Marksmanship",
    [4] = "INV_Weapon_ShortBlade_05", [5] = "Spell_Holy_LesserHeal", [6] = "Spell_Shadow_RaiseDead",
    [7] = "Spell_Fire_SearingTotem", [8] = "Spell_Fire_FireBolt02", [9] = "Spell_Shadow_BurningSpirit",
    [11] = "Ability_Druid_CatForm" }

local KEYWORD_LABELS = { { KW.TAUNT, "Taunt" }, { KW.CHARGE, "Charge" }, { KW.RUSH, "Rush" },
    { KW.DIVINE_SHIELD, "Divine Shield" }, { KW.WINDFURY, "Windfury" }, { KW.LIFESTEAL, "Lifesteal" },
    { KW.STEALTH, "Stealth" }, { KW.POISONOUS, "Poisonous" }, { KW.REBORN, "Reborn" }, { KW.ELUSIVE, "Elusive" },
    { KW.IMMUNE, "Immune" }, { KW.DEATHRATTLE, "Deathrattle" } }

local frame          -- the board
local widgets = {}   -- entity id -> widget, rebuilt every refresh
local moves = {}     -- legal moves for the player's current decision (empty otherwise)
local sel            -- the half-made move: { list = {{index, move}...}, step, source }

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

local function setClassIcon(tex, class)
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        tex:SetTexCoord(unpack(coords))
    else
        tex:SetTexture(Art:SafeIcon("INV_Misc_Ticket_Tarot_Stack_01"))
        tex:SetTexCoord(0, 1, 0, 1)
    end
end

local function addGlow(f, scale)
    local g = f:CreateTexture(nil, "OVERLAY", nil, 7)
    g:SetTexture(GLOW)
    g:SetBlendMode("ADD")
    g:SetPoint("CENTER")
    g:SetSize(f:GetWidth() * (scale or 1.75), f:GetHeight() * (scale or 1.75))
    g:Hide()
    f.glow = g
    return g
end

-- "green" = can act, "gold" = selected, "red" = a target of the move being made.
local GLOW_COLORS = { green = { 0.2, 1, 0.2 }, gold = { 1, 0.85, 0.1 }, red = { 1, 0.25, 0.15 } }
local function setGlow(f, color)
    if not f.glow then return end
    local c = color and GLOW_COLORS[color]
    if c then
        f.glow:SetVertexColor(c[1], c[2], c[3])
        f.glow:Show()
    else
        f.glow:Hide()
    end
end

local function roundTexture(f, layer, inset)
    local t = f:CreateTexture(nil, layer)
    t:SetPoint("TOPLEFT", inset, -inset)
    t:SetPoint("BOTTOMRIGHT", -inset, inset)
    local mask = f:CreateMaskTexture()
    mask:SetTexture(MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(t)
    t:AddMaskTexture(mask)
    return t
end

local function engine()
    return Match:Engine()
end

-- ---- floating numbers --------------------------------------------------------------------------

local floats = {}
local function floatText(x, y, text, r, g, b)
    local fs
    for _, f in ipairs(floats) do
        if not f.active then fs = f break end
    end
    if not fs then
        fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        fs:SetShadowOffset(2, -2)
        floats[#floats + 1] = fs
    end
    fs.active, fs.x, fs.y, fs.t = true, x, y, 0
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:SetPoint("CENTER", frame, "BOTTOMLEFT", x, y)
    fs:SetAlpha(1)
    fs:Show()
end

local function updateFloats(elapsed)
    for _, fs in ipairs(floats) do
        if fs.active then
            fs.t = fs.t + elapsed
            if fs.t > 1.3 then
                fs.active = false
                fs:Hide()
            else
                fs:SetPoint("CENTER", frame, "BOTTOMLEFT", fs.x, fs.y + fs.t * 28)
                fs:SetAlpha(fs.t < 0.8 and 1 or (1.3 - fs.t) / 0.5)
            end
        end
    end
end

-- Where each entity's widget sits now (board coordinates), so numbers can float over the dead too.
local function positions()
    local out = {}
    local left, bottom = frame:GetLeft(), frame:GetBottom()
    if not left then return out end
    local scale = frame:GetEffectiveScale()
    for id, w in pairs(widgets) do
        if w:IsShown() then
            local x, y = w:GetCenter()
            if x then
                local ws = w:GetEffectiveScale() / scale
                out[id] = { x * ws - left, y * ws - bottom }
            end
        end
    end
    return out
end

-- ---- tooltips ----------------------------------------------------------------------------------

local function entityTooltip(owner, id)
    local eng = engine()
    local e = eng and eng:ent(id)
    if not e then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if e.zone == ZONE.HERO then
        local p = eng:player(e.owner)
        local record = Match:Record()
        local name = e.owner == 0 and (UnitName("player") or "You")
            or (record and record.opponent and record.opponent.name) or "Opponent"
        GameTooltip:SetText(name, 1, 0.82, 0)
        GameTooltip:AddLine(("Health %d / %d"):format(e.health, e.max_health), 1, 1, 1)
        if e.armor > 0 then GameTooltip:AddLine(("Armor %d"):format(e.armor), 0.8, 0.8, 0.8) end
        if e.attack > 0 then GameTooltip:AddLine(("Attack %d"):format(e.attack), 1, 1, 1) end
        GameTooltip:AddLine(("Deck %d  ·  Hand %d"):format(#eng:deck_ids(e.owner), #eng:hand_ids(e.owner)), 0.7, 0.7, 0.7)
        if #p.secrets > 0 then
            GameTooltip:AddLine(("%d secret(s) in play"):format(#p.secrets), 0.8, 0.4, 1)
        end
    else
        TC:CardTooltip(e.card_id, true)
        if e.zone == ZONE.BOARD then
            GameTooltip:AddLine(("Now %d / %d"):format(e.attack, e.health), 1, 1, 1)
        elseif e.zone == ZONE.WEAPON then
            GameTooltip:AddLine(("Now %d / %d"):format(e.attack, e.durability), 1, 1, 1)
        end
    end
    local words = {}
    for _, kw in ipairs(KEYWORD_LABELS) do
        if band(e.keywords, kw[1]) ~= 0 and not (kw[1] == KW.DIVINE_SHIELD or kw[1] == KW.STEALTH) then
            words[#words + 1] = kw[2]
        end
    end
    if e.flags.divine_shield then words[#words + 1] = "Divine Shield" end
    if e.flags.stealth then words[#words + 1] = "Stealth" end
    if e.flags.immune then words[#words + 1] = "Immune" end
    if e.flags.frozen then words[#words + 1] = "|cff66ccffFrozen|r" end
    if e.flags.silenced then words[#words + 1] = "|cff999999Silenced|r" end
    if e.flags.dormant_turns > 0 then words[#words + 1] = ("Dormant (%d)"):format(e.flags.dormant_turns) end
    if #words > 0 then
        GameTooltip:AddLine(table.concat(words, ", "), 0.5, 1, 0.5, true)
    end
    GameTooltip:Show()
end

-- ---- widgets -----------------------------------------------------------------------------------

local function onEntityClick(self, button)
    if button == "RightButton" then
        Board:Cancel()
    elseif self.entity then
        TC:Safe("board click", Board.ClickEntity, Board, self.entity)
    end
end

local function minionWidget(parent)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(SLOT_W, SLOT_H)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    b:SetBackdropColor(0.1, 0.08, 0.06, 1)
    b.art = b:CreateTexture(nil, "ARTWORK")
    b.art:SetPoint("TOPLEFT", 6, -6)
    b.art:SetPoint("TOPRIGHT", -6, -6)
    b.art:SetHeight(62)
    b.art:SetTexCoord(0.08, 0.92, 0.18, 0.82)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.name:SetPoint("TOPLEFT", b.art, "BOTTOMLEFT", -2, -1)
    b.name:SetPoint("TOPRIGHT", b.art, "BOTTOMRIGHT", 2, -1)
    b.name:SetHeight(14)
    b.name:SetWordWrap(false)
    b.attack = gem(b, 26, 0.85, 0.65, 0.15, "GameFontHighlight")
    b.attack:SetPoint("BOTTOMLEFT", -5, -5)
    b.health = gem(b, 26, 0.75, 0.12, 0.1, "GameFontHighlight")
    b.health:SetPoint("BOTTOMRIGHT", 5, -5)
    b.taunt = b:CreateTexture(nil, "OVERLAY")
    b.taunt:SetSize(22, 22)
    b.taunt:SetPoint("TOP", 0, 8)
    b.taunt:SetTexture(Art:SafeIcon("INV_Shield_06"))
    b.shield = b:CreateTexture(nil, "OVERLAY", nil, 2)
    b.shield:SetTexture("Interface\\Buttons\\CheckButtonGlow")
    b.shield:SetBlendMode("ADD")
    b.shield:SetVertexColor(1, 0.9, 0.3, 0.9)
    b.shield:SetPoint("TOPLEFT", -10, 10)
    b.shield:SetPoint("BOTTOMRIGHT", 10, -10)
    b.status = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.status:SetPoint("CENTER", b.art, "CENTER")
    b.status:SetShadowOffset(2, -2)
    addGlow(b, 1.7)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function setMinion(b, e)
    local eng = engine()
    local d = eng:def_of(e.id)
    local card = TC.Cards[e.card_id]
    b.entity = e.id
    b.art:SetTexture(Art:Icon(e.card_id))
    b.name:SetText(card and card.name or (d and d.name) or e.card_id)
    local r, g, bl = Art:RarityColor(card and card.rarity or "FREE")
    b:SetBackdropBorderColor(r, g, bl, 1)
    b.name:SetTextColor(r, g, bl)
    b.attack.text:SetText(e.attack)
    b.health.text:SetText(e.health)
    local baseAttack = card and card.attack or e.attack
    if e.attack > baseAttack then b.attack.text:SetTextColor(0.3, 1, 0.3) else b.attack.text:SetTextColor(1, 1, 1) end
    if e.health < e.max_health then
        b.health.text:SetTextColor(1, 0.3, 0.3)
    elseif card and e.max_health > card.health then
        b.health.text:SetTextColor(0.3, 1, 0.3)
    else
        b.health.text:SetTextColor(1, 1, 1)
    end
    b.taunt:SetShown(band(e.keywords, KW.TAUNT) ~= 0 and not e.flags.silenced)
    b.shield:SetShown(e.flags.divine_shield)
    b:SetAlpha(e.flags.stealth and 0.6 or 1)
    if e.flags.frozen then
        b.art:SetVertexColor(0.55, 0.8, 1)
        b.status:SetText("|cff99ddffFrozen|r")
    elseif e.flags.dormant_turns > 0 then
        b.art:SetVertexColor(0.6, 0.6, 0.6)
        b.status:SetText("Dormant")
    elseif e.owner == eng.state.active and e.flags.exhausted and e.flags.attacks_this_turn == 0
        and e.flags.just_played_turn == eng.state.turn then
        b.art:SetVertexColor(1, 1, 1)
        b.status:SetText("|cffccccccZzz|r")
    else
        b.art:SetVertexColor(1, 1, 1)
        b.status:SetText("")
    end
    b:Show()
end

local function heroWidget(parent, seat)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(84, 84)
    b.ring = roundTexture(b, "BACKGROUND", 0)
    b.ring:SetColorTexture(0.75, 0.6, 0.25, 1)
    b.portrait = roundTexture(b, "ARTWORK", 4)
    b.attack = gem(b, 30, 0.85, 0.65, 0.15, "GameFontHighlightLarge")
    b.attack:SetPoint("BOTTOMLEFT", -8, -4)
    b.health = gem(b, 30, 0.75, 0.12, 0.1, "GameFontHighlightLarge")
    b.health:SetPoint("BOTTOMRIGHT", 8, -4)
    b.armor = gem(b, 26, 0.55, 0.55, 0.6, "GameFontHighlight")
    b.armor:SetPoint("BOTTOM", b.health, "TOP", 0, -2)
    b.secrets = b:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.secrets:SetPoint("TOP", 0, 10)
    b.secrets:SetTextColor(0.8, 0.45, 1)
    b.frozen = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.frozen:SetPoint("CENTER")
    b.frozen:SetText("|cff99ddffFrozen|r")
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.name:SetPoint("RIGHT", b, "LEFT", -96, 0)
    b.deck = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.deck:SetPoint("TOPRIGHT", b.name, "BOTTOMRIGHT", 0, -4)
    addGlow(b, 1.6)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function powerButton(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(52, 52)
    b.ring = roundTexture(b, "BACKGROUND", 0)
    b.ring:SetColorTexture(0.55, 0.45, 0.2, 1)
    b.icon = roundTexture(b, "ARTWORK", 3)
    b.cost = gem(b, 22, 0.15, 0.4, 0.95, "GameFontHighlightSmall")
    b.cost:SetPoint("TOP", 0, 10)
    addGlow(b, 1.7)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
        if not self.power then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(TC.Engine.POWER_NAME[self.power] or "Hero Power", 1, 0.82, 0)
        GameTooltip:AddLine(("%d Mana Hero Power"):format(self.costNow or 2), 1, 1, 1)
        GameTooltip:AddLine(TC.Engine.POWER_TEXT[self.power] or "", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function weaponWidget(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(52, 52)
    b.ring = roundTexture(b, "BACKGROUND", 0)
    b.ring:SetColorTexture(0.35, 0.35, 0.38, 1)
    b.icon = roundTexture(b, "ARTWORK", 3)
    b.attack = gem(b, 22, 0.85, 0.65, 0.15, "GameFontHighlightSmall")
    b.attack:SetPoint("BOTTOMLEFT", -6, -4)
    b.durability = gem(b, 22, 0.45, 0.45, 0.5, "GameFontHighlightSmall")
    b.durability:SetPoint("BOTTOMRIGHT", 6, -4)
    b:SetScript("OnEnter", function(self) entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function manaBar(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(170, 34)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT")
    f.crystals = {}
    for i = 1, 10 do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(15, 15)
        t:SetPoint("BOTTOMLEFT", (i - 1) * 16, 0)
        t:SetTexture(Art:SafeIcon("INV_Misc_Gem_Sapphire_02"))
        f.crystals[i] = t
    end
    return f
end

local function setMana(f, p)
    local overload = p.overload_locked
    f.text:SetText(("Mana |cff66aaff%d|r / %d%s"):format(p.mana, p.max_mana,
        overload > 0 and ("  |cffff5533(%d locked)|r"):format(overload) or ""))
    for i = 1, 10 do
        local t = f.crystals[i]
        if i > math.max(p.max_mana, p.mana) then
            t:Hide()
        else
            t:Show()
            local spent = i > p.mana
            t:SetDesaturated(spent)
            t:SetAlpha(spent and 0.45 or 1)
            if i > p.max_mana - overload and i > p.mana then
                t:SetVertexColor(1, 0.35, 0.25)
            else
                t:SetVertexColor(1, 1, 1)
            end
        end
    end
end

local function cardBack(parent)
    local b = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    b:SetSize(34, 48)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 } })
    b:SetBackdropColor(0.22, 0.12, 0.06, 1)
    b:SetBackdropBorderColor(0.8, 0.65, 0.3, 1)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetSize(22, 22)
    t:SetPoint("CENTER")
    t:SetTexture(Art:SafeIcon("INV_Misc_Ticket_Tarot_Stack_01"))
    t:SetAlpha(0.8)
    return b
end

-- ---- the choice dialog (discover, adapt, dredge, choose one, mulligan) -------------------------

local function buildChoice()
    local c = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    c:SetFrameLevel(frame:GetFrameLevel() + 40)
    c:SetPoint("CENTER", 0, 10)
    c:SetSize(620, 260)
    c:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    c:EnableMouse(true)
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.title:SetPoint("TOP", 0, -16)
    c.cards = {}
    for i = 1, 5 do
        local w = CardWidget:CreateGame(c)
        w.mark = w:CreateTexture(nil, "OVERLAY", nil, 7)
        w.mark:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        w.mark:SetSize(40, 40)
        w.mark:SetPoint("CENTER", 0, 10)
        w.mark:Hide()
        c.cards[i] = w
    end
    c.buttons = {}
    for i = 1, 9 do
        local b = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
        b:SetSize(170, 28)
        c.buttons[i] = b
    end
    c.confirm = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.confirm:SetSize(140, 26)
    c.confirm:SetPoint("BOTTOM", 0, 16)
    c:Hide()
    return c
end

-- options: { {card = id} or {label = text}, ... }; pick(i) is called with the option index.
function Board:ShowChoice(title, options, pick, multi, confirmText, onConfirm)
    local c = frame.choice
    c.title:SetText(title)
    for _, w in ipairs(c.cards) do w:Hide() w.mark:Hide() end
    for _, b in ipairs(c.buttons) do b:Hide() end
    c.confirm:Hide()
    local cardsShown = options[1] and options[1].card
    local n = #options
    if cardsShown then
        local step = 112
        local x0 = -(n - 1) * step / 2
        for i, opt in ipairs(options) do
            local w = c.cards[i]
            if w then
                w:ClearAllPoints()
                w:SetPoint("CENTER", c, "CENTER", x0 + (i - 1) * step, 0)
                w.costNow = nil
                w:SetCard(opt.card)
                w.onClick = function(_, button)
                    if button == "LeftButton" then pick(i, w) end
                end
            end
        end
        c:SetSize(math.max(360, n * step + 40), 250)
    else
        for i, opt in ipairs(options) do
            local b = c.buttons[i]
            if b then
                b:ClearAllPoints()
                local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
                local cols = math.min(n, 3)
                b:SetPoint("TOP", c, "TOP", (col - (cols - 1) / 2) * 180, -56 - row * 36)
                b:SetText(opt.label)
                b:SetScript("OnClick", function() pick(i, b) end)
                b:Show()
            end
        end
        c:SetSize(math.max(360, math.min(n, 3) * 180 + 40), 90 + math.ceil(n / 3) * 36 + 20)
    end
    if onConfirm then
        c.confirm:SetText(confirmText or OKAY or "Okay")
        c.confirm:SetScript("OnClick", onConfirm)
        c.confirm:Show()
        c:SetHeight(c:GetHeight() + 30)
    end
    c:Show()
end

function Board:HideChoice()
    if frame and frame.choice then frame.choice:Hide() end
end

-- ---- building the frame ------------------------------------------------------------------------

local function build()
    local f = CreateFrame("Frame", "TavernCardsBoard", UIParent, "BackdropTemplate")
    frame = f
    f:SetSize(W, H)
    f:SetPoint("CENTER", 0, 10)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetBackdrop({ bgFile = "Interface\\FrameGeneral\\UI-Background-Rock",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 256, edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    f:Hide()
    tinsert(UISpecialFrames, "TavernCardsBoard")

    -- The table top: dark wood with a lighter felt where the minions stand.
    local top = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    top:SetPoint("TOPLEFT", 10, -10)
    top:SetPoint("BOTTOMRIGHT", -10, 10)
    top:SetColorTexture(1, 1, 1, 1)
    top:SetGradient("VERTICAL", CreateColor(0.16, 0.1, 0.06, 0.93), CreateColor(0.22, 0.14, 0.08, 0.93))
    local felt = f:CreateTexture(nil, "BACKGROUND", nil, 2)
    felt:SetPoint("TOPLEFT", 190, -178)
    felt:SetPoint("TOPRIGHT", -190, -178)
    felt:SetHeight(244)
    felt:SetColorTexture(1, 1, 1, 1)
    felt:SetGradient("VERTICAL", CreateColor(0.12, 0.22, 0.12, 0.85), CreateColor(0.1, 0.18, 0.1, 0.85))
    local line = f:CreateTexture(nil, "BORDER")
    line:SetPoint("LEFT", felt, "LEFT", 0, 0)
    line:SetPoint("RIGHT", felt, "RIGHT", 0, 0)
    line:SetHeight(2)
    line:SetColorTexture(0.8, 0.65, 0.3, 0.5)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 22, -18)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)
    f.concede = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.concede:SetSize(90, 22)
    f.concede:SetPoint("RIGHT", close, "LEFT", -4, 0)
    f.concede:SetText("Concede")
    f.concede:SetScript("OnClick", function()
        TC:Confirm("Concede this match?", function() Match:Concede() end)
    end)

    -- Opponent (top).
    f.oppHand = CreateFrame("Frame", nil, f)
    f.oppHand:SetSize(400, 48)
    f.oppHand:SetPoint("TOP", 0, -26)
    f.oppHand.backs = {}
    for i = 1, 10 do
        local back = cardBack(f.oppHand)
        f.oppHand.backs[i] = back
    end
    f.heroes = { [0] = heroWidget(f, 0), [1] = heroWidget(f, 1) }
    f.heroes[1]:SetPoint("TOP", 0, -84)
    f.heroes[0]:SetPoint("TOP", 0, -432)
    f.powers, f.weapons, f.mana = {}, {}, {}
    for seat = 0, 1 do
        local hero = f.heroes[seat]
        f.powers[seat] = powerButton(f)
        f.powers[seat]:SetPoint("LEFT", hero, "RIGHT", 22, -8)
        f.weapons[seat] = weaponWidget(f)
        f.weapons[seat]:SetPoint("RIGHT", hero, "LEFT", -22, -8)
        f.mana[seat] = manaBar(f)
        f.mana[seat]:SetPoint("LEFT", f.powers[seat], "RIGHT", 18, 0)
    end
    f.powers[0]:SetScript("OnClick", function(_, button)
        if button == "RightButton" then return Board:Cancel() end
        TC:Safe("hero power", Board.ClickPower, Board)
    end)

    f.rows = { [0] = {}, [1] = {} }
    for seat = 0, 1 do
        for i = 1, 7 do
            f.rows[seat][i] = minionWidget(f)
        end
    end
    -- Gaps between your minions, shown while placing one.
    f.gaps = {}
    for i = 1, 8 do
        local g = CreateFrame("Button", nil, f)
        g:SetSize(18, SLOT_H)
        local t = g:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints()
        t:SetColorTexture(1, 0.85, 0.2, 0.55)
        g:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
        g:GetHighlightTexture():SetVertexColor(1, 0.9, 0.4, 0.6)
        g:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        g:SetScript("OnClick", function(self, button)
            if button == "RightButton" then return Board:Cancel() end
            TC:Safe("place", Board.ClickGap, Board, self.position)
        end)
        g:Hide()
        f.gaps[i] = g
    end

    -- Your hand (bottom), slightly smaller cards.
    f.hand = CreateFrame("Frame", nil, f)
    f.hand:SetScale(HAND_SCALE)
    f.hand:SetSize(760 / HAND_SCALE, CardWidget.HEIGHT)
    f.hand:SetPoint("BOTTOM", 0, 14)
    f.hand.cards = {}
    for i = 1, 10 do
        local w = CardWidget:CreateGame(f.hand)
        addGlow(w, 1.45)
        w.onClick = function(self, button)
            if button == "RightButton" then return Board:Cancel() end
            TC:Safe("hand click", Board.ClickHand, Board, self.entity, self)
        end
        f.hand.cards[i] = w
    end

    -- Log (left) and turn controls (right).
    local log = CreateFrame("ScrollingMessageFrame", nil, f)
    log:SetPoint("TOPLEFT", 18, -180)
    log:SetSize(166, 240)
    log:SetFontObject(GameFontHighlightSmall)
    log:SetJustifyH("LEFT")
    log:SetFading(false)
    log:SetMaxLines(60)
    log:EnableMouseWheel(true)
    log:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then self:ScrollUp() else self:ScrollDown() end
    end)
    f.log = log
    local logTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    logTitle:SetPoint("BOTTOMLEFT", log, "TOPLEFT", 0, 4)
    logTitle:SetText("Match log")

    f.endTurn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.endTurn:SetSize(140, 34)
    f.endTurn:SetPoint("RIGHT", -28, 35)
    f.endTurn:SetScript("OnClick", function() TC:Safe("end turn", Board.ClickEndTurn, Board) end)
    f.endGlow = addGlow(f.endTurn, 1.3)
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.status:SetPoint("TOP", f.endTurn, "BOTTOM", 0, -10)
    f.status:SetWidth(170)
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hint:SetPoint("BOTTOM", f.heroes[0], "TOP", 0, 128)

    -- The card the opponent just played, shown for a moment.
    f.showcase = CardWidget:CreateGame(f)
    f.showcase:SetPoint("TOPRIGHT", -40, -60)
    f.showcase:Hide()
    f.showcaseLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.showcaseLabel:SetPoint("BOTTOM", f.showcase, "TOP", 0, 4)

    -- Turn banner and the end-of-match banner.
    f.banner = f:CreateFontString(nil, "OVERLAY", HUGE_FONT)
    f.banner:SetPoint("CENTER", 0, 40)
    f.banner:SetTextColor(1, 0.82, 0)
    f.banner:SetShadowOffset(3, -3)
    f.banner:Hide()

    f.over = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.over:SetFrameLevel(f:GetFrameLevel() + 50)
    f.over:SetPoint("CENTER", 0, 20)
    f.over:SetSize(420, 190)
    f.over:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    f.over:EnableMouse(true)
    f.over.text = f.over:CreateFontString(nil, "OVERLAY", HUGE_FONT)
    f.over.text:SetPoint("TOP", 0, -26)
    f.over.reason = f.over:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.over.reason:SetPoint("TOP", f.over.text, "BOTTOM", 0, -10)
    local leave = CreateFrame("Button", nil, f.over, "UIPanelButtonTemplate")
    leave:SetSize(130, 26)
    leave:SetPoint("BOTTOMRIGHT", f.over, "BOTTOM", -6, 20)
    leave:SetText("Leave Table")
    leave:SetScript("OnClick", function()
        f:Hide()
        TC:ShowWindow("play")
    end)
    local again = CreateFrame("Button", nil, f.over, "UIPanelButtonTemplate")
    again:SetSize(130, 26)
    again:SetPoint("BOTTOMLEFT", f.over, "BOTTOM", 6, 20)
    again:SetText("Rematch")
    again:SetScript("OnClick", function() TC:Safe("rematch", Board.Rematch, Board) end)
    f.over:Hide()

    f.choice = buildChoice()

    local bannerTime = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        updateFloats(elapsed)
        if f.banner:IsShown() then
            bannerTime = bannerTime + elapsed
            if bannerTime > 1.6 then
                f.banner:Hide()
            else
                f.banner:SetAlpha(bannerTime < 1 and 1 or (1.6 - bannerTime) / 0.6)
            end
        else
            bannerTime = 0
        end
        if f.showcaseUntil and GetTime() > f.showcaseUntil then
            f.showcaseUntil = nil
            f.showcase:Hide()
            f.showcaseLabel:SetText("")
        end
        if Match.thinking then
            f.status:SetText("Opponent is thinking" .. string.rep(".", math.floor(GetTime() * 2) % 4))
        end
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Board:Cancel() end
    end)
    f:SetScript("OnShow", function() Art:Play("IG_MAINMENU_OPEN") Board:Refresh() end)
    f:SetScript("OnHide", function()
        Board:Cancel(true)
        GameTooltip:Hide()
    end)
end

-- ---- reading the state -------------------------------------------------------------------------

local function myDecision()
    local eng = engine()
    return eng and not eng:is_terminal() and eng:current_player() == 0 and not Match.thinking
end

local function movesWhere(test)
    local out = {}
    for i, m in ipairs(moves) do
        if test(m) then out[#out + 1] = { index = i, move = m } end
    end
    return out
end

local function layoutRow(seat)
    local eng = engine()
    local ids = eng:board_ids(seat)
    local row = frame.rows[seat]
    local n = #ids
    local total = n * SLOT_W + math.max(0, n - 1) * SLOT_GAP
    local y = seat == 1 and -186 or -310
    for i = 1, 7 do
        local b = row[i]
        local id = ids[i]
        if id then
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOP", -total / 2 + (i - 1) * (SLOT_W + SLOT_GAP), y)
            setMinion(b, eng:ent(id))
            widgets[id] = b
        else
            b.entity = nil
            b:Hide()
        end
    end
    return ids, total, y
end

local function refreshHero(seat)
    local eng = engine()
    local s = eng.state
    local p = eng:player(seat)
    local hero = eng:hero_of(seat)
    local b = frame.heroes[seat]
    local record = Match:Record()
    local classes = record and record.classes or Match.lastClasses or {}
    setClassIcon(b.portrait, classes[seat + 1])
    if hero then
        b.entity = hero.id
        widgets[hero.id] = b
        b.health.text:SetText(hero.health)
        local hurt = hero.health < hero.max_health
        b.health.text:SetTextColor(1, hurt and 0.4 or 1, hurt and 0.4 or 1)
        b.armor:SetShown(hero.armor > 0)
        b.armor.text:SetText(hero.armor)
        b.attack:SetShown(hero.attack > 0)
        b.attack.text:SetText(hero.attack)
        b.frozen:SetShown(hero.flags.frozen)
    end
    b.secrets:SetText(#p.secrets > 0 and string.rep("?", #p.secrets) or "")
    local name = seat == 0 and (UnitName("player") or "You")
        or (record and record.opponent and record.opponent.name) or "Opponent"
    b.name:SetText(name .. "  |cffaaaaaa" .. className(classes[seat + 1] or "") .. "|r")
    b.deck:SetText(("Deck %d   Fatigue %d"):format(#eng:deck_ids(seat), p.fatigue))

    local power = frame.powers[seat]
    power.power = p.hero_power_id
    power.costNow = eng:hero_power_cost(seat)
    power.cost.text:SetText(power.costNow)
    power.icon:SetTexture(Art:SafeIcon(POWER_ICONS[p.hero_power_id] or "INV_Misc_QuestionMark"))
    local used = hero and (hero.flags.hero_power_used or p.hero_power_uses >= 1) and s.active == seat
    power.icon:SetDesaturated(used and true or false)
    power:SetShown(p.hero_power_id ~= 0)

    local wpn = frame.weapons[seat]
    local w = p.weapon_id ~= 0 and eng:ent(p.weapon_id)
    if w and w.zone == ZONE.WEAPON then
        wpn.entity = w.id
        widgets[w.id] = wpn
        wpn.icon:SetTexture(Art:Icon(w.card_id))
        wpn.attack.text:SetText(w.attack)
        wpn.durability.text:SetText(w.durability)
        wpn:Show()
    else
        wpn.entity = nil
        wpn:Hide()
    end
    setMana(frame.mana[seat], p)
end

local function refreshHand()
    local eng = engine()
    local ids = eng:hand_ids(0)
    local n = #ids
    local cw = CardWidget.WIDTH
    local avail = 760 / HAND_SCALE
    local step = n > 1 and math.min(cw + 6, (avail - cw) / (n - 1)) or 0
    local total = (n - 1) * step + cw
    for i = 1, 10 do
        local w = frame.hand.cards[i]
        local id = ids[i]
        if id then
            local e = eng:ent(id)
            w.entity = id
            w.costNow = eng:card_cost(0, id)
            w:ClearAllPoints()
            w:SetPoint("BOTTOMLEFT", frame.hand, "BOTTOM", -total / 2 + (i - 1) * step, 0)
            w:SetFrameLevel(frame.hand:GetFrameLevel() + i * 3)
            w:SetCard(e.card_id)
            widgets[id] = w
        else
            w.entity = nil
            w:Hide()
        end
    end
    local backs = frame.oppHand.backs
    local m = #eng:hand_ids(1)
    for i = 1, 10 do
        local back = backs[i]
        if i <= m then
            back:ClearAllPoints()
            back:SetPoint("TOPLEFT", frame.oppHand, "TOP", -(m * 30) / 2 + (i - 1) * 30, 0)
            back:Show()
        else
            back:Hide()
        end
    end
end

-- Glows: what you can do now, or (mid-move) what the move can still become.
local function refreshGlows()
    for _, w in pairs(widgets) do setGlow(w) end
    setGlow(frame.powers[0])
    for _, g in ipairs(frame.gaps) do g:Hide() end
    if not myDecision() then return end
    local eng = engine()
    if sel then
        if sel.source and widgets[sel.source] then setGlow(widgets[sel.source], "gold") end
        if sel.step == "target" or sel.step == "position" then
            for _, x in ipairs(sel.list) do
                local t = x.move.raw.target
                if t and t ~= 0 and widgets[t] and (sel.step == "target" or x.move.raw.position == -1) then
                    setGlow(widgets[t], "red")
                end
            end
        end
        if sel.step == "position" then
            local ids = eng:board_ids(0)
            local n = #ids
            local total = n * SLOT_W + math.max(0, n - 1) * SLOT_GAP
            local seen = {}
            for _, x in ipairs(sel.list) do
                local pos = x.move.raw.position
                if pos and pos >= 0 and not seen[pos] then
                    seen[pos] = true
                    local g = frame.gaps[pos + 1]
                    g.position = pos
                    g:ClearAllPoints()
                    g:SetPoint("TOP", frame, "TOP", -total / 2 + pos * (SLOT_W + SLOT_GAP) - SLOT_GAP / 2, -310)
                    g:Show()
                end
            end
        end
        return
    end
    local canAct = {}
    for _, m in ipairs(moves) do
        if m.raw.entity and m.raw.entity ~= 0 and m.action ~= "mulligan" then canAct[m.raw.entity] = true end
        if m.action == "hero_power" then setGlow(frame.powers[0], "green") end
    end
    for id in pairs(canAct) do
        if widgets[id] then setGlow(widgets[id], "green") end
    end
    local onlyEnd = true
    for _, m in ipairs(moves) do
        if m.action ~= "end_turn" and m.action ~= "concede" then onlyEnd = false break end
    end
    setGlow(frame.endTurn, onlyEnd and "gold" or nil)
end

function Board:Refresh()
    if not frame or not frame:IsShown() then return end
    local eng = engine()
    wipe(widgets)
    if not eng then
        frame:Hide()
        return
    end
    local s = eng.state
    local record = Match:Record()
    local opp = record and record.opponent
    frame.title:SetText(("Tavern Table — %s"):format(opp and opp.name or (Match.lastOpponent or "Practice")))
    layoutRow(1)
    layoutRow(0)
    refreshHero(0)
    refreshHero(1)
    refreshHand()

    moves = myDecision() and eng:legal_moves() or {}
    if sel and #moves == 0 then sel = nil end
    local mine = myDecision()
    if eng:is_terminal() then
        frame.endTurn:SetText("Game Over")
        frame.endTurn:Disable()
        frame.status:SetText("")
    elseif mine and s.phase == PHASE.PLAYER_ACTIONS and not s.pending.active then
        frame.endTurn:SetText("End Turn")
        frame.endTurn:Enable()
        frame.status:SetText(("Turn %d"):format(math.floor((s.turn + 1) / 2)))
    else
        frame.endTurn:SetText(eng:current_player() == 1 and "Enemy Turn" or "Your Turn")
        frame.endTurn:Disable()
        if not Match.thinking then frame.status:SetText("") end
    end
    frame.concede:SetEnabled(not eng:is_terminal())
    frame.hint:SetText(sel and sel.hint or "")
    refreshGlows()

    -- Decisions that need a dialog: the opening hand, then any pending choice.
    if mine and s.phase == PHASE.MULLIGAN then
        self:ShowMulligan()
    elseif mine and s.pending.active and s.pending.seat == 0 then
        self:ShowPending()
    elseif sel and sel.step == "choice" then
        -- stays open
    else
        self:HideChoice()
    end
    if eng:is_terminal() and Match.result then
        self:ShowGameOver()
    else
        frame.over:Hide()
    end
end

-- ---- decisions ---------------------------------------------------------------------------------

function Board:ShowMulligan()
    local eng = engine()
    local ids = eng:mulligan_ids(0)
    local replace = {}
    local options = {}
    for i, id in ipairs(ids) do options[i] = { card = eng:ent(id).card_id } end
    self:ShowChoice("Your opening hand — click cards to replace them", options, function(i, w)
        replace[i] = not replace[i]
        w.mark:SetShown(replace[i])
    end, true, "Keep", function()
        local want = {}
        for i = 1, #ids do
            if replace[i] then want[#want + 1] = i - 1 end
        end
        for index, m in ipairs(moves) do
            if m.action == "mulligan" then
                local got = m.raw.replace
                local same = #got == #want
                for k = 1, #want do
                    if got[k] ~= want[k] then same = false end
                end
                if same then
                    self:HideChoice()
                    Match:PlayerApply(index)
                    return
                end
            end
        end
    end)
end

function Board:ShowPending()
    local eng = engine()
    local pending = eng.state.pending
    local options = {}
    local title = "Choose one"
    if #pending.card_options > 0 then
        for i, id in ipairs(pending.card_options) do options[i] = { card = id } end
        title = pending.kind == "hand_action" and "Choose a card from your hand" or "Discover a card"
    elseif pending.kind == "adapt" then
        for i, which in ipairs(pending.options) do options[i] = { label = TC.Engine.ADAPT_LABELS[which] or tostring(which) } end
        title = "Adapt"
    elseif pending.kind == "dredge" then
        for i, id in ipairs(pending.options) do
            local e = eng:ent(id)
            options[i] = { card = e and e.card_id }
        end
        title = "Dredge: put one on top of your deck"
    else
        for i in ipairs(pending.options) do options[i] = { label = "Option " .. i } end
    end
    self:ShowChoice(title, options, function(i)
        for index, m in ipairs(moves) do
            if m.action == "resolve" and m.raw.choice == i - 1 then
                self:HideChoice()
                Match:PlayerApply(index)
                return
            end
        end
    end)
end

function Board:Cancel(silent)
    if not sel then return end
    sel = nil
    if frame then
        self:HideChoice()
        if not silent then self:Refresh() end
    end
end

local function apply(index)
    sel = nil
    Board:HideChoice()
    Match:PlayerApply(index)
end

-- Narrows the half-made move one step: option, then board slot, then target.
function Board:Advance()
    local list = sel.list
    if #list == 0 then
        return self:Cancel()
    end
    local choices, nChoices = {}, 0
    for _, x in ipairs(list) do
        local c = x.move.raw.choice or 0
        if (x.move.action == "play" or x.move.action == "activate") and not choices[c] then
            choices[c] = x.move.desc:match("%[(.-)%]") or x.move.desc:match(": (.-) on ") or x.move.desc:match(": (.+)$")
                or ("Option " .. (c + 1))
            nChoices = nChoices + 1
        end
    end
    if nChoices > 1 then
        sel.step = "choice"
        local options, keys = {}, {}
        for c, label in pairs(choices) do keys[#keys + 1] = c end
        table.sort(keys)
        for i, c in ipairs(keys) do options[i] = { label = choices[c] } end
        self:ShowChoice("Choose one", options, function(i)
            local keep = {}
            for _, x in ipairs(list) do
                if (x.move.raw.choice or 0) == keys[i] then keep[#keep + 1] = x end
            end
            self:HideChoice()
            sel.list = keep
            self:Advance()
        end)
        self:Refresh()
        return
    end
    local positions, nPos, hosts = {}, 0, false
    for _, x in ipairs(list) do
        local p = x.move.raw.position
        if x.move.action == "play" and p and p >= 0 and not positions[p] then
            positions[p] = true
            nPos = nPos + 1
        elseif x.move.action == "play" and p == -1 and (x.move.raw.target or 0) ~= 0 then
            hosts = true
        end
    end
    if (nPos > 1 or (nPos >= 1 and hosts)) and not sel.placed then
        sel.step = "position"
        sel.hint = hosts and "Choose where to place it, or a Mech to magnetize to" or "Choose where to place it"
        self:Refresh()
        return
    end
    local targets = {}
    local anyTarget = false
    for _, x in ipairs(list) do
        local t = x.move.raw.target or 0
        if t ~= 0 then
            targets[t] = true
            anyTarget = true
        end
    end
    if anyTarget and not sel.targeted then
        sel.step = "target"
        sel.hint = list[1].move.action == "attack" and "Choose a target to attack" or "Choose a target"
        self:Refresh()
        return
    end
    apply(list[1].index)
end

function Board:Begin(list, source)
    sel = { list = list, source = source }
    Art:Play("IG_ABILITY_ICON_DROP")
    self:Advance()
end

local HAND_ACTIONS = { play = true, trade = true, forge = true, prepare = true }
local ACTION_LABEL = { play = "Play", trade = "Trade (1 mana, draw a card)", forge = "Forge (2 mana)",
    prepare = "Prepare (1 mana)" }

function Board:ClickHand(id, widget)
    if not myDecision() then return end
    if sel then
        if sel.step == "target" then return self:ClickEntity(id) end
        self:Cancel(true)
    end
    local byAction, kinds = {}, {}
    for _, x in ipairs(movesWhere(function(m) return HAND_ACTIONS[m.action] and m.raw.entity == id end)) do
        if not byAction[x.move.action] then
            byAction[x.move.action] = {}
            kinds[#kinds + 1] = x.move.action
        end
        table.insert(byAction[x.move.action], x)
    end
    if #kinds == 0 then
        local eng = engine()
        local cost = eng:card_cost(0, id)
        UIErrorsFrame:AddMessage(cost > eng:player(0).mana and "Not enough mana." or "You can't play that now.", 1, 0.1, 0.1)
        return
    end
    if #kinds == 1 and kinds[1] == "play" then
        return self:Begin(byAction.play, id)
    end
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(widget, function(_, root)
            for _, kind in ipairs(kinds) do
                root:CreateButton(ACTION_LABEL[kind] or kind, function() self:Begin(byAction[kind], id) end)
            end
        end)
    else
        self:Begin(byAction[kinds[1]], id)
    end
end

function Board:ClickEntity(id)
    if not myDecision() then return end
    if sel and (sel.step == "target" or sel.step == "position") then
        local keep = {}
        for _, x in ipairs(sel.list) do
            if x.move.raw.target == id and (sel.step == "target" or x.move.raw.position == -1) then
                keep[#keep + 1] = x
            end
        end
        if #keep > 0 then
            sel.list = keep
            sel.placed, sel.targeted = true, true
            return self:Advance()
        end
        if sel.step == "target" then
            UIErrorsFrame:AddMessage("Invalid target.", 1, 0.1, 0.1)
            return
        end
    end
    if sel then self:Cancel(true) end
    local list = movesWhere(function(m)
        return (m.action == "attack" or m.action == "activate") and m.raw.entity == id
    end)
    if #list > 0 then
        return self:Begin(list, id)
    end
    local e = engine():ent(id)
    if e and e.owner == 0 and e.zone == ZONE.BOARD then
        local why = e.flags.frozen and "That minion is frozen." or e.flags.exhausted and "That minion can't attack yet."
            or "That minion can't attack."
        UIErrorsFrame:AddMessage(why, 1, 0.1, 0.1)
    end
    self:Refresh()
end

function Board:ClickGap(position)
    if not sel then return end
    local keep = {}
    for _, x in ipairs(sel.list) do
        if x.move.raw.position == position then keep[#keep + 1] = x end
    end
    sel.list = keep
    sel.placed = true
    self:Advance()
end

function Board:ClickPower()
    if not myDecision() then return end
    if sel then self:Cancel(true) end
    local list = movesWhere(function(m) return m.action == "hero_power" end)
    if #list == 0 then
        UIErrorsFrame:AddMessage("You can't use your hero power now.", 1, 0.1, 0.1)
        return
    end
    self:Begin(list, nil)
end

function Board:ClickEndTurn()
    if not myDecision() then return end
    sel = nil
    for index, m in ipairs(moves) do
        if m.action == "end_turn" then
            Art:Play("IG_QUEST_LIST_SELECT")
            Match:PlayerApply(index)
            return
        end
    end
end

-- ---- match feedback ----------------------------------------------------------------------------

function Board:ShowGameOver()
    local over = frame.over
    local result = Match.result
    if result == "win" then
        over.text:SetText("|cffffd100Victory!|r")
    elseif result == "loss" then
        over.text:SetText("|cffcc3333Defeat|r")
    else
        over.text:SetText("Draw")
    end
    local reasons = { life = "", fatigue = "Out of cards.", concede = "Conceded.", turn_limit = "Turn limit reached.",
        loop = "The rules got stuck in a loop.", errored = "The match ended in an error." }
    over.reason:SetText(reasons[Match.reason or ""] or "")
    over:Show()
end

function Board:Rematch()
    local last = Match.lastSetup
    if not last then return end
    frame.over:Hide()
    Match:StartPractice(last.deck, last.opponent)
end

local function showBanner(text)
    frame.banner:SetText(text)
    frame.banner:SetAlpha(1)
    frame.banner:Show()
end

local function onMatch(what, seat, move)
    if what == "log" then
        if frame then frame.log:AddMessage(seat) end
        return
    end
    if not frame then return end
    if what == "load" then
        sel = nil
        frame.log:Clear()
        local record = Match:Record()
        for _, line in ipairs(record and record.log or {}) do frame.log:AddMessage(line) end
        frame.over:Hide()
        Board:Refresh()
        return
    end
    if what == "move" and frame:IsShown() then
        local eng = engine()
        local before = positions()
        sel = nil
        Board:Refresh()
        local after = positions()
        local turnStarted
        for _, ev in ipairs(eng.events or {}) do
            local at = after[ev.subject] or before[ev.subject]
            if ev.kind == "DAMAGED" and at then
                floatText(at[1], at[2], "-" .. ev.amount, 1, 0.2, 0.15)
            elseif ev.kind == "DAMAGE_PREVENTED" and at then
                floatText(at[1], at[2], "Blocked", 1, 0.9, 0.4)
            elseif ev.kind == "DIED" and at then
                floatText(at[1], at[2] - 24, "Died", 0.7, 0.7, 0.7)
            elseif ev.kind == "TURN_STARTED" then
                turnStarted = ev.seat
            end
        end
        if seat == 1 and move and move.action == "play" and move.raw.entity then
            local e = eng:ent(move.raw.entity)
            if e then
                frame.showcase.costNow = nil
                frame.showcase:SetCard(e.card_id)
                frame.showcaseLabel:SetText("Opponent played")
                frame.showcaseUntil = GetTime() + 2.2
            end
        end
        if turnStarted == 0 and not eng:is_terminal() then
            showBanner("Your Turn")
            Art:Play("READY_CHECK")
        end
        return
    end
    if what == "end" then
        Art:Play(Match.result == "win" and "UI_EPICLOOT_TOAST" or "IG_QUEST_FAILED")
        Board:Refresh()
    end
end

Match:Subscribe(onMatch)

function Board:Open()
    if not frame then build() end
    if not Match:Engine() then
        TC:Print("No match in progress. Start one from the Play tab.")
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        TC:Print("The tavern table opens when you leave combat.")
        return
    end
    if not frame:IsShown() then
        frame.log:Clear()
        local record = Match:Record()
        for _, line in ipairs(record and record.log or {}) do frame.log:AddMessage(line) end
    end
    frame:Show()
    self:Refresh()
end

-- The step of the half-made move ("choice", "position", "target"), or nil.
function Board:Selecting()
    return sel and sel.step
end

function Board:IsShown()
    return frame and frame:IsShown()
end

-- Combat: the table folds away and comes back after.
TC:On("PLAYER_REGEN_DISABLED", function()
    if frame and frame:IsShown() then
        frame.reopen = true
        frame:Hide()
    end
end)
TC:On("PLAYER_REGEN_ENABLED", function()
    if frame and frame.reopen then
        frame.reopen = nil
        if Match:Engine() then Board:Open() end
    end
end)
