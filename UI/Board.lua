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

local W, H = 1000, 692
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

local allGlows = {}
local function addGlow(f, scale)
    local g = f:CreateTexture(nil, "OVERLAY", nil, 7)
    allGlows[#allGlows + 1] = g
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

-- Your seat in the engine (0, or 1 when a friend challenged you) and theirs. The board's own tables are
-- by side instead: [0] is the bottom (you), [1] the top (the opponent).
local function ME()
    return Match.mySeat or 0
end
local function OPP()
    return 1 - ME()
end
local function sideOf(seat)
    return seat == ME() and 0 or 1
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

-- An attack: the attacker's portrait lunges at its target and springs back.
local ghosts = {}
local LUNGE = 0.45
local function lunge(from, to, texture, mode)
    local g
    for _, x in ipairs(ghosts) do
        if not x.active then g = x break end
    end
    if not g then
        g = CreateFrame("Frame", nil, frame)
        g:SetSize(62, 62)
        g:SetFrameLevel(frame:GetFrameLevel() + 30)
        g.ring = roundTexture(g, "ARTWORK", 0)
        g.ring:SetColorTexture(0.9, 0.75, 0.3, 1)
        g.tex = roundTexture(g, "OVERLAY", 3)
        ghosts[#ghosts + 1] = g
    end
    g.from, g.to, g.t, g.active, g.mode = from, to, 0, true, mode or "lunge"
    g.tex:SetTexture(texture)
    g:SetScale(1)
    g:SetAlpha(1)
    g.ring:SetColorTexture(g.mode == "die" and 0.4 or 0.9, g.mode == "die" and 0.4 or 0.75, g.mode == "die" and 0.4 or 0.3, 1)
    g:ClearAllPoints()
    g:SetPoint("CENTER", frame, "BOTTOMLEFT", from[1], from[2])
    g:Show()
end

local function updateGhosts(elapsed)
    for _, g in ipairs(ghosts) do
        if g.active then
            g.t = g.t + elapsed
            local p = g.t / (g.mode == "die" and 0.6 or LUNGE)
            if p >= 1 then
                g.active = false
                g:Hide()
            elseif g.mode == "die" then
                -- A dying minion: greys, shrinks and fades where it stood.
                local scale = 1 - 0.5 * p
                g:SetScale(scale)
                g:SetAlpha(1 - p)
                g:SetPoint("CENTER", frame, "BOTTOMLEFT", g.from[1] / scale, (g.from[2] - 20 * p) / scale)
            else
                local k = p < 0.5 and p * 2 or (1 - p) * 2
                k = k * k * (3 - 2 * k) * 0.85
                g:SetPoint("CENTER", frame, "BOTTOMLEFT", g.from[1] + (g.to[1] - g.from[1]) * k,
                    g.from[2] + (g.to[2] - g.from[2]) * k)
            end
        end
    end
end

-- ---- effects: flashes, fades, flying cards, the targeting arrow ---------------------------------

local flashing, fading = {}, {}

local function addFlash(w)
    local t = w:CreateTexture(nil, "OVERLAY", nil, 6)
    t:SetPoint("TOPLEFT", 3, -3)
    t:SetPoint("BOTTOMRIGHT", -3, 3)
    t:SetColorTexture(1, 1, 1, 1)
    t:SetBlendMode("ADD")
    t:SetAlpha(0)
    w.flash = t
end

-- A quick colored flash over a widget (hit = red, power = gold).
local function flash(w, r, g, b, length)
    if not w or not w.flash then return end
    w.flash:SetVertexColor(r, g, b)
    w.flashLeft, w.flashLength = length or 0.45, length or 0.45
    flashing[w] = true
end

-- A widget fades in (new minion); `delay` keeps it hidden while a card flies to it.
local function fadeIn(w, delay)
    w.fadeT = -(delay or 0)
    w.fadeEntity = w.entity
    w:SetAlpha(0)
    fading[w] = true
end

local function updateEffects(elapsed)
    for w in pairs(flashing) do
        w.flashLeft = w.flashLeft - elapsed
        if w.flashLeft <= 0 then
            w.flash:SetAlpha(0)
            flashing[w] = nil
        else
            w.flash:SetAlpha(0.65 * w.flashLeft / w.flashLength)
        end
    end
    for w in pairs(fading) do
        w.fadeT = w.fadeT + elapsed
        local k = math.max(0, math.min(1, w.fadeT / 0.3))
        w:SetAlpha(k * (w.baseAlpha or 1))
        if k >= 1 then fading[w] = nil end
    end
end

-- Flying cards: a card face moving from the hand to where it lands, shrinking as it goes.
local flyers = {}
local FLY = 0.35
local function flyCard(cardId, from, to)
    local g
    for _, x in ipairs(flyers) do
        if not x.active then g = x break end
    end
    if not g then
        g = CardWidget:CreateGame(frame)
        g:EnableMouse(false)
        g:SetFrameLevel(frame:GetFrameLevel() + 40)
        flyers[#flyers + 1] = g
    end
    g.from, g.to, g.t, g.active = from, to, 0, true
    g.costNow = nil
    g:SetCard(cardId)
    g:Show()
end

local function updateFlyers(elapsed)
    for _, g in ipairs(flyers) do
        if g.active then
            g.t = g.t + elapsed
            local p = math.min(1, g.t / FLY)
            local k = 1 - (1 - p) * (1 - p)
            local scale = 0.95 - 0.35 * k
            g:SetScale(scale)
            g:ClearAllPoints()
            g:SetPoint("CENTER", frame, "BOTTOMLEFT", (g.from[1] + (g.to[1] - g.from[1]) * k) / scale,
                (g.from[2] + (g.to[2] - g.from[2]) * k) / scale)
            g:SetAlpha(p < 0.75 and 1 or (1 - p) * 4)
            if p >= 1 then
                g.active = false
                g:Hide()
            end
        end
    end
end

-- The targeting arrow: marching dots from the card or minion being used to the cursor, an arrowhead at
-- the cursor, red when the cursor is over a legal target.
local arrow
local function buildArrow(f)
    arrow = CreateFrame("Frame", nil, f)
    arrow:SetAllPoints()
    arrow:SetFrameLevel(f:GetFrameLevel() + 45)
    arrow.dots = {}
    for i = 1, 18 do
        local t = arrow:CreateTexture(nil, "OVERLAY")
        t:SetTexture(MASK)
        t:SetBlendMode("ADD")
        arrow.dots[i] = t
    end
    arrow.head = arrow:CreateTexture(nil, "OVERLAY", nil, 2)
    arrow.head:SetTexture("Interface\\Minimap\\MinimapArrow")
    arrow.head:SetSize(40, 40)
    arrow.head:SetBlendMode("ADD")
    arrow:Hide()
end

local function frameXY(w)
    local x, y = w:GetCenter()
    if not x then return nil end
    local ws = w:GetEffectiveScale() / frame:GetEffectiveScale()
    return x * ws - frame:GetLeft(), y * ws - frame:GetBottom()
end

local function updateArrow()
    if not arrow then return end
    local src = sel and sel.step == "target" and (sel.source and widgets[sel.source] or (sel.power and frame.powers[0]))
    if not src or not src:IsShown() then
        arrow:Hide()
        return
    end
    local sx, sy = frameXY(src)
    if not sx then arrow:Hide() return end
    local scale = frame:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale - frame:GetLeft(), cy / scale - frame:GetBottom()
    local dx, dy = cx - sx, cy - sy
    local valid = false
    if Board.hover then
        for _, x in ipairs(sel.list) do
            if x.move.raw.target == Board.hover then valid = true break end
        end
    end
    local r, g, b = 1, 0.8, 0.2
    if valid then r, g, b = 1, 0.25, 0.15 end
    local n = #arrow.dots
    local phase = (GetTime() * 1.6) % 1
    for i, t in ipairs(arrow.dots) do
        local k = (i - 1 + phase) / n
        local size = 5 + 9 * k
        t:SetSize(size, size)
        t:ClearAllPoints()
        t:SetPoint("CENTER", arrow, "BOTTOMLEFT", sx + dx * k, sy + dy * k)
        t:SetVertexColor(r, g, b, 0.35 + 0.6 * k)
    end
    arrow.head:ClearAllPoints()
    arrow.head:SetPoint("CENTER", arrow, "BOTTOMLEFT", cx, cy)
    arrow.head:SetVertexColor(r, g, b)
    arrow.head:SetRotation(math.atan2(dy, dx) - math.pi / 2)
    arrow:Show()
end

-- Gliding: widgets ease to their new places (the hand closing up after a play, the row closing up after
-- a death, a hovered card lifting) instead of jumping. Widgets are per slot, so each remembers where its
-- card/minion was drawn last and starts from there when the slot now shows that entity.
local gliders = {}
local lastHand, lastBoard = {}, {}

local function placeHand(w, x, y)
    w:SetPoint("BOTTOMLEFT", frame.hand, "BOTTOM", x, y)
end
local function placeBoard(w, x, y)
    w:SetPoint("TOPLEFT", frame, "TOP", x, y)
end

local function glideTo(w, place, x, y, from)
    w.place, w.tx, w.ty = place, x, y
    if from then
        w.gx, w.gy = from[1], from[2]
    elseif not w.gx then
        w.gx, w.gy = x, y
    end
    w:ClearAllPoints()
    place(w, w.gx, w.gy)
    if math.abs(w.gx - x) > 0.5 or math.abs(w.gy - y) > 0.5 then gliders[w] = true end
end

local function updateGliders(elapsed)
    local k = 1 - math.exp(-elapsed * 14)
    for w in pairs(gliders) do
        w.gx = w.gx + (w.tx - w.gx) * k
        w.gy = w.gy + (w.ty - w.gy) * k
        if math.abs(w.gx - w.tx) < 0.5 and math.abs(w.gy - w.ty) < 0.5 then
            w.gx, w.gy = w.tx, w.ty
            gliders[w] = nil
        end
        w.place(w, w.gx, w.gy)
    end
end

-- Ends every running effect at once (the board was hidden, or a new match begins): nothing may resume
-- half-way over a later state.
local function finishEffects()
    for w in pairs(flashing) do w.flash:SetAlpha(0) end
    wipe(flashing)
    for w in pairs(fading) do w:SetAlpha(w.baseAlpha or 1) end
    wipe(fading)
    for _, g in ipairs(flyers) do
        g.active = false
        g:Hide()
    end
    for _, g in ipairs(ghosts) do
        g.active = false
        g:Hide()
    end
    if arrow then arrow:Hide() end
    for w in pairs(gliders) do
        w.gx, w.gy = w.tx, w.ty
        w.place(w, w.gx, w.gy)
    end
    wipe(gliders)
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
        local name = e.owner == ME() and (UnitName("player") or "You")
            or (record and record.opponent and record.opponent.name) or "Opponent"
        GameTooltip:SetText(name, 1, 0.82, 0)
        GameTooltip:AddLine(("Health %d / %d"):format(e.health, e.max_health), 1, 1, 1)
        if e.armor > 0 then
            GameTooltip:AddLine(("Armor %d"):format(e.armor), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("  Armor soaks up damage before Health.", 0.6, 0.6, 0.6, true)
        end
        if e.attack > 0 then
            GameTooltip:AddLine(("Attack %d"):format(e.attack), 1, 1, 1)
            local w = eng:ent(p.weapon_id)
            local wcard = w and w.zone == ZONE.WEAPON and TC.Cards[w.card_id]
            GameTooltip:AddLine(wcard and ("  From your weapon, %s (%d uses left)."):format(wcard.name, w.durability)
                or "  A temporary boost: the hero can attack this turn; it wears off when the turn ends.", 0.6, 0.6, 0.6, true)
            if e.owner == ME() then
                GameTooltip:AddLine("  Click your hero, then an enemy, to attack.", 0.5, 0.75, 1, true)
            end
        end
        GameTooltip:AddLine(("Deck %d  ·  Hand %d"):format(#eng:deck_ids(e.owner), #eng:hand_ids(e.owner)), 0.7, 0.7, 0.7)
        if #p.secrets > 0 then
            GameTooltip:AddLine(("%d secret(s) in play"):format(#p.secrets), 0.8, 0.4, 1)
            if e.owner == ME() then
                for _, sid in ipairs(p.secrets) do
                    local se = eng:ent(sid)
                    local card = se and TC.Cards[se.card_id]
                    if card then GameTooltip:AddLine("  " .. card.name, 0.85, 0.6, 1) end
                end
            end
        end
    else
        TC:CardTooltip(e.card_id, true)
        local card = TC.Cards[e.card_id]
        if e.zone == ZONE.BOARD and card and card.type ~= "LOCATION" then
            GameTooltip:AddLine(" ")
            local atk = e.attack > card.attack and ("|cff40ff40%d Attack|r"):format(e.attack) or ("%d Attack"):format(e.attack)
            local hp = e.health < e.max_health and ("|cffff5050%d|r of %d Health"):format(e.health, e.max_health)
                or (e.max_health > card.health and ("|cff40ff40%d Health|r"):format(e.health) or ("%d Health"):format(e.health))
            GameTooltip:AddLine("On the board: " .. atk .. ", " .. hp, 1, 1, 1)
            if e.flags.exhausted and e.owner == ME() and not e.flags.frozen then
                GameTooltip:AddLine("Can't attack until your next turn.", 0.6, 0.6, 0.6)
            end
        elseif e.zone == ZONE.BOARD then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("%d uses left%s"):format(e.durability, e.flags.has_attacked and ", used this turn" or ""), 1, 1, 1)
        elseif e.zone == ZONE.WEAPON then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("Equipped: %d Attack, %d uses left"):format(e.attack, e.durability), 1, 1, 1)
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
    addFlash(b)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) Board.hover = self.entity entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil GameTooltip:Hide() end)
    return b
end

local function setMinion(b, e)
    local eng = engine()
    if fading[b] and b.fadeEntity ~= e.id then
        -- The row shifted mid-fade: this slot now shows another minion, which is already there.
        fading[b] = nil
    end
    local d = eng:def_of(e.id)
    local card = TC.Cards[e.card_id]
    b.entity = e.id
    b.art:SetTexture(Art:Icon(e.card_id))
    b.name:SetText(card and card.name or (d and d.name) or e.card_id)
    local r, g, bl = Art:RarityColor(card and card.rarity or "FREE")
    b:SetBackdropBorderColor(r, g, bl, 1)
    b.name:SetTextColor(r, g, bl)
    if card and card.type == "LOCATION" then
        -- Locations: uses left instead of attack/health, and a marker once used this turn.
        b.attack:Hide()
        b.health:Show()
        b.health.text:SetText(e.durability)
        b.health.text:SetTextColor(1, 1, 1)
        b.taunt:Hide()
        b.shield:Hide()
        b.baseAlpha = 1
        if not fading[b] then b:SetAlpha(1) end
        b.art:SetVertexColor(e.flags.has_attacked and 0.5 or 1, e.flags.has_attacked and 0.5 or 1, e.flags.has_attacked and 0.5 or 1)
        b.status:SetText(e.flags.has_attacked and "|cffccccccUsed|r" or "")
        b:Show()
        return
    end
    b.attack:Show()
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
    b.baseAlpha = e.flags.stealth and 0.6 or 1
    if not fading[b] then b:SetAlpha(b.baseAlpha) end
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
    b.flash = roundTexture(b, "OVERLAY", 4)
    b.flash:SetColorTexture(1, 1, 1, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAlpha(0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) Board.hover = self.entity entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil GameTooltip:Hide() end)
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
    b.flash = roundTexture(b, "OVERLAY", 3)
    b.flash:SetColorTexture(1, 1, 1, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAlpha(0)
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
    f:SetSize(200, 42)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.text:SetPoint("TOPLEFT")
    f.crystals = {}
    for i = 1, 10 do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(19, 19)
        t:SetPoint("BOTTOMLEFT", (i - 1) * 20, 0)
        t:SetTexture(Art:SafeIcon("INV_Misc_Gem_Sapphire_02"))
        f.crystals[i] = t
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        local p = self.player
        if not p then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Mana", 0.3, 0.65, 1)
        GameTooltip:AddLine(("%d of %d crystals available."):format(p.mana, p.max_mana), 1, 1, 1)
        GameTooltip:AddLine("You gain a crystal each turn (up to 10), refilled at the start of your turn.", 0.75, 0.75, 0.75, true)
        if p.overload_locked > 0 then
            GameTooltip:AddLine(("|cffff6040%d locked by Overload|r this turn."):format(p.overload_locked), 1, 1, 1, true)
        end
        if p.overload_next > 0 then
            GameTooltip:AddLine(("|cffff6040%d will be locked next turn|r (Overload)."):format(p.overload_next), 1, 1, 1, true)
        end
        GameTooltip:AddLine("|cffffd100Overload:|r " .. (TC.Keywords:Explain("Overload") or ""), 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

local function setMana(f, p)
    f.player = p
    local overload = p.overload_locked
    f.text:SetText(("Mana |cff66aaff%d|r / %d%s%s"):format(p.mana, p.max_mana,
        overload > 0 and ("  |cffff5533%d locked|r"):format(overload) or "",
        p.overload_next > 0 and ("  |cffff9966(%d next turn)|r"):format(p.overload_next) or ""))
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
    for i = 1, 10 do
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
        local perRow = n > 5 and math.ceil(n / 2) or n
        local rows = math.ceil(n / perRow)
        for i, opt in ipairs(options) do
            local w = c.cards[i]
            if w then
                local row, col = math.floor((i - 1) / perRow), (i - 1) % perRow
                local inRow = math.min(perRow, n - row * perRow)
                w:ClearAllPoints()
                w:SetPoint("CENTER", c, "CENTER", -(inRow - 1) * step / 2 + col * step, (rows - 1) * 75 - row * 150)
                w.costNow = nil
                w:SetCard(opt.card)
                w.onClick = function(_, button)
                    if button == "LeftButton" then pick(i, w) end
                end
            end
        end
        c:SetSize(math.max(360, perRow * step + 40), 250 + (rows - 1) * 150)
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

local function myDecisionNow()
    local eng = engine()
    return eng and not eng:is_terminal() and eng:current_player() == ME() and not Match.thinking
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
    local feltEdge = CreateFrame("Frame", nil, f, "BackdropTemplate")
    feltEdge:SetPoint("TOPLEFT", felt, -4, 4)
    feltEdge:SetPoint("BOTTOMRIGHT", felt, 4, -4)
    feltEdge:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    feltEdge:SetBackdropBorderColor(0.75, 0.6, 0.3, 0.9)
    local vignette = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    vignette:SetAllPoints(felt)
    vignette:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    vignette:SetVertexColor(0.35, 0.55, 0.35, 0.18)
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
    f.hand:SetPoint("BOTTOM", 0, 26)
    f.hand.cards = {}
    for i = 1, 10 do
        local w = CardWidget:CreateGame(f.hand)
        addGlow(w, 1.45)
        -- Hovered cards lift above their neighbours so the whole card can be read.
        w.onEnter = function(self)
            self.hovered = true
            if not self.baseX then return end
            glideTo(self, placeHand, self.baseX, 28)
            self:SetFrameLevel(f.hand:GetFrameLevel() + 45)
        end
        w.onLeave = function(self)
            self.hovered = false
            if not self.baseX then return end
            glideTo(self, placeHand, self.baseX, 0)
            self:SetFrameLevel(self.baseLevel or f.hand:GetFrameLevel())
        end
        w.onClick = function(self, button)
            if button == "RightButton" then return Board:Cancel() end
            TC:Safe("hand click", Board.ClickHand, Board, self.entity, self)
        end
        f.hand.cards[i] = w
    end

    -- Log (left) and turn controls (right).
    -- The match log: our own little panel (newest at the bottom, mouse wheel scrolls back).
    local log = CreateFrame("Frame", nil, f, "BackdropTemplate")
    log:SetPoint("TOPLEFT", 16, -184)
    log:SetSize(168, 236)
    log:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    log:SetBackdropColor(0.05, 0.03, 0.02, 0.75)
    log:SetBackdropBorderColor(0.6, 0.5, 0.3, 0.8)
    log.lines, log.entries, log.offset = {}, {}, 0
    local LOG_LINES = 13
    for i = 1, LOG_LINES do
        local fs = log:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("BOTTOMLEFT", 8, 6 + (i - 1) * 17)
        fs:SetWidth(154)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        log.lines[i] = fs
    end
    function log:Render()
        local n = #self.entries
        for i = 1, LOG_LINES do
            local e = self.entries[n - self.offset - i + 1]
            self.lines[i]:SetText(e or "")
        end
    end
    function log:Clear()
        wipe(self.entries)
        self.offset = 0
        self:Render()
    end
    function log:AddMessage(line)
        line = tostring(line)
        line = line:gsub("^You: ", "|cff60ff60You:|r "):gsub("^Opponent: ", "|cffff7050Them:|r ")
        self.entries[#self.entries + 1] = line
        self.offset = 0
        self:Render()
    end
    log:EnableMouseWheel(true)
    log:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, math.min(#self.entries - LOG_LINES, self.offset + delta))
        self:Render()
    end)
    log:EnableMouse(true)
    log:SetScript("OnEnter", function(self)
        -- Lines are cut to fit; the tooltip shows the last few in full.
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Match log", 1, 0.82, 0)
        for i = math.max(1, #self.entries - 11), #self.entries do
            GameTooltip:AddLine(self.entries[i], 1, 1, 1, true)
        end
        GameTooltip:AddLine("Mouse wheel scrolls back.", 0.5, 0.5, 0.5)
        GameTooltip:Show()
    end)
    log:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.log = log
    local logTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    logTitle:SetPoint("BOTTOMLEFT", log, "TOPLEFT", 4, 4)
    logTitle:SetText("Match log")

    f.endTurn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.endTurn:SetSize(140, 34)
    f.endTurn:SetPoint("RIGHT", -28, 35)
    f.endTurn:SetScript("OnClick", function() TC:Safe("end turn", Board.ClickEndTurn, Board) end)
    f.endGlow = addGlow(f.endTurn, 1.3)
    f.launch = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.launch:SetSize(140, 24)
    f.launch:SetPoint("BOTTOM", f.endTurn, "TOP", 0, 8)
    f.launch:SetText("Launch Starship")
    f.launch:SetScript("OnClick", function(self)
        if self.index and myDecisionNow() then Match:PlayerApply(self.index) end
    end)
    f.launch:Hide()
    f.claim = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.claim:SetSize(140, 24)
    f.claim:SetPoint("TOP", f.endTurn, "BOTTOM", 0, -52)
    f.claim:SetText("Claim Win")
    f.claim:SetScript("OnClick", function()
        TC:Confirm("Your opponent hasn't answered for a while. Claim the win?", function() TC.Duel:ClaimWin() end)
    end)
    f.claim:Hide()

    -- Escape cancels a half-made move before it closes the table.
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)
    f:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown and InCombatLockdown() then return end
        if key == "ESCAPE" and sel then
            Board:Cancel()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
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
    f.over.reward = f.over:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.over.reward:SetPoint("TOP", f.over.reason, "BOTTOM", 0, -8)
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
    buildArrow(f)

    local bannerTime = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        updateFloats(elapsed)
        updateGhosts(elapsed)
        updateEffects(elapsed)
        updateFlyers(elapsed)
        updateGliders(elapsed)
        updateArrow()
        local pulse = 0.6 + 0.4 * math.sin(GetTime() * 5)
        for _, g in ipairs(allGlows) do
            if g:IsShown() then g:SetAlpha(pulse) end
        end
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
        elseif TC.Duel and Match:IsDuel() then
            local quiet = TC.Duel:Silence()
            if quiet > TC.Duel.SILENT_WARN then
                local left = math.ceil(TC.Duel.SILENT_CLAIM - quiet)
                f.status:SetText(left > 0 and ("|cffff6040No word from your opponent.|r\nYou can claim the win in %ds."):format(left)
                    or "|cffff6040Your opponent seems to have left.|r")
            end
            f.claim:SetShown(quiet >= TC.Duel.SILENT_CLAIM)
        else
            f.claim:Hide()
        end
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Board:Cancel() end
    end)
    f:SetScript("OnShow", function() Art:Play("IG_MAINMENU_OPEN") Board:Refresh() end)
    f:SetScript("OnHide", function()
        finishEffects()
        Board:Cancel(true)
        GameTooltip:Hide()
    end)
end

-- ---- reading the state -------------------------------------------------------------------------

local function myDecision()
    local eng = engine()
    return eng and not eng:is_terminal() and eng:current_player() == ME() and not Match.thinking
end

local function movesWhere(test)
    local out = {}
    for i, m in ipairs(moves) do
        if test(m) then out[#out + 1] = { index = i, move = m } end
    end
    return out
end

local function layoutRow(side)
    local eng = engine()
    local ids = eng:board_ids(side == 0 and ME() or OPP())
    local row = frame.rows[side]
    local n = #ids
    local total = n * SLOT_W + math.max(0, n - 1) * SLOT_GAP
    local y = side == 1 and -186 or -310
    for i = 1, 7 do
        local b = row[i]
        local id = ids[i]
        if id then
            local x = -total / 2 + (i - 1) * (SLOT_W + SLOT_GAP)
            local from = b.entity ~= id and lastBoard[id] or nil
            if b.entity ~= id and not from then b.gx = nil end   -- a newcomer appears in place
            glideTo(b, placeBoard, x, y, from)
            lastBoard[id] = { x, y }
            setMinion(b, eng:ent(id))
            widgets[id] = b
        else
            b.entity = nil
            b:Hide()
        end
    end
    return ids, total, y
end

local function refreshHero(side)
    local seat = side == 0 and ME() or OPP()
    local eng = engine()
    local s = eng.state
    local p = eng:player(seat)
    local hero = eng:hero_of(seat)
    local b = frame.heroes[side]
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
    local name = seat == ME() and (UnitName("player") or "You")
        or (record and record.opponent and Ambiguate and Ambiguate(record.opponent.name, "short") or record and record.opponent and record.opponent.name) or "Opponent"
    b.name:SetText(name .. "  |cffaaaaaa" .. className(classes[seat + 1] or "") .. "|r")
    b.deck:SetText(("Deck %d   Fatigue %d"):format(#eng:deck_ids(seat), p.fatigue))

    local power = frame.powers[side]
    power.power = p.hero_power_id
    power.costNow = eng:hero_power_cost(seat)
    power.cost.text:SetText(power.costNow)
    power.icon:SetTexture(Art:SafeIcon(POWER_ICONS[p.hero_power_id] or "INV_Misc_QuestionMark"))
    local used = hero and (hero.flags.hero_power_used or p.hero_power_uses >= 1) and s.active == seat
    power.icon:SetDesaturated(used and true or false)
    power:SetShown(p.hero_power_id ~= 0)

    local wpn = frame.weapons[side]
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
    setMana(frame.mana[side], p)
end

local function refreshHand()
    local eng = engine()
    local ids = eng:hand_ids(ME())
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
            local x = -total / 2 + (i - 1) * step
            local from
            if w.entity ~= id then
                -- Another card moved into this slot: start where that card was, or (a new card) below.
                from = lastHand[id] or { x + 40, -CardWidget.HEIGHT }
            end
            w.entity = id
            w.costNow = eng:card_cost(ME(), id)
            w.baseX = x
            w.baseLevel = frame.hand:GetFrameLevel() + i * 3
            glideTo(w, placeHand, x, w.hovered and 28 or 0, from)
            lastHand[id] = { x, 0 }
            w:SetFrameLevel(w.hovered and (frame.hand:GetFrameLevel() + 45) or w.baseLevel)
            w:SetCard(e.card_id)
            widgets[id] = w
        else
            w.entity = nil
            w:Hide()
        end
    end
    local backs = frame.oppHand.backs
    local m = #eng:hand_ids(OPP())
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
            local ids = eng:board_ids(ME())
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
    local oppName = opp and opp.name or Match.lastOpponent or "Practice"
    if Ambiguate then oppName = Ambiguate(oppName, "short") end
    frame.title:SetText(((record and record.kind == "duel") and "Duel with %s" or "Tavern Table — %s"):format(oppName))
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
        frame.status:SetText(("|cff40ff40Your turn|r  (turn %d)"):format(math.floor((s.turn + 1) / 2)))
    else
        frame.endTurn:SetText(eng:current_player() == OPP() and "Enemy Turn" or "Your Turn")
        frame.endTurn:Disable()
        if not Match.thinking then
            frame.status:SetText(eng:current_player() == OPP()
                and (Match:IsDuel() and "|cffff6040Waiting for your opponent...|r" or "|cffff6040Enemy turn|r") or "")
        end
    end
    local launch
    for i, m in ipairs(moves) do
        if m.action == "launch" then launch = i end
    end
    frame.launch.index = launch
    frame.launch:SetShown(launch ~= nil and not sel)
    frame.concede:SetEnabled(not eng:is_terminal())
    frame.hint:SetText(sel and sel.hint or "")
    refreshGlows()

    -- Decisions that need a dialog: the opening hand, then any pending choice.
    if mine and s.phase == PHASE.MULLIGAN then
        self:ShowMulligan()
    elseif mine and s.pending.active and s.pending.seat == ME() then
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

-- Cards marked to replace survive refreshes (they are keyed by the match, so a new match starts clean).
local mulliganMarks = { match = nil, replace = {} }

function Board:ShowMulligan()
    local eng = engine()
    local ids = eng:mulligan_ids(ME())
    local record = Match:Record()
    local key = record and record.started
    if mulliganMarks.match ~= key then
        mulliganMarks.match, mulliganMarks.replace = key, {}
    end
    local replace = mulliganMarks.replace
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
                    mulliganMarks.replace = {}
                    Match:PlayerApply(index)
                    return
                end
            end
        end
    end)
    for i in ipairs(ids) do
        frame.choice.cards[i].mark:SetShown(replace[i] and true or false)
    end
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

function Board:Begin(list, source, power)
    sel = { list = list, source = source, power = power }
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
        local cost = eng:card_cost(ME(), id)
        UIErrorsFrame:AddMessage(cost > eng:player(ME()).mana and "Not enough mana." or "You can't play that now.", 1, 0.1, 0.1)
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
    if e and e.owner == ME() and e.zone == ZONE.BOARD then
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
    self:Begin(list, nil, true)
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
    local reward = Match.reward
    local parts = {}
    if reward and reward.dust then
        parts[#parts + 1] = ("|TInterface\\Icons\\INV_Enchant_DustArcane:14:14|t +%d dust"):format(reward.dust)
    end
    if reward and reward.card then parts[#parts + 1] = "and " .. Art:ColoredName(reward.card) end
    if reward and not reward.dust and not reward.card then parts[#parts + 1] = "|cffaaaaaaToday's winnings are already collected.|r" end
    over.reward:SetText(table.concat(parts, "  "))
    over:Show()
end

function Board:Rematch()
    frame.over:Hide()
    local last = TC.char.lastMatch
    if last and last.opponent and last.opponent.duel and TC.Duel then
        -- A duel rematch is a new challenge to the same player.
        frame:Hide()
        TC.Duel:Challenge(last.opponent.name)
        return
    end
    local setup = Match.lastSetup or (last and last.setup)
    if not setup or not TC:StartPractice(setup) then
        frame:Hide()
        TC:ShowWindow("play")
    end
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
        finishEffects()
        wipe(lastHand)
        wipe(lastBoard)
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
        -- The played card flies from the hand (yours, or the opponent's card backs) to where it lands.
        local flownTo
        if move and move.action == "play" and move.raw.entity then
            local e = eng:ent(move.raw.entity)
            local d = e and eng:def_of(e.id)
            if e and not (seat == OPP() and d and d.secret) then
                local from = before[e.id]
                if seat == OPP() then
                    local ox, oy = frameXY(frame.oppHand)
                    from = ox and { ox, oy }
                end
                local to = after[e.id] or { W / 2, H / 2 + 20 }
                if from then
                    flyCard(e.card_id, from, to)
                    flownTo = e.id
                end
            end
        end
        for _, ev in ipairs(eng.events or {}) do
            local at = after[ev.subject] or before[ev.subject]
            if ev.kind == "ATTACK_DECLARED" then
                local a, b = before[ev.subject] or after[ev.subject], before[ev.source] or after[ev.source]
                local e = eng:ent(ev.subject)
                if a and b and e then
                    local tex
                    if e.zone == ZONE.HERO then
                        local w = eng:ent(eng:player(e.owner).weapon_id)
                        tex = w and Art:Icon(w.card_id) or Art:SafeIcon("INV_Sword_04")
                    else
                        tex = Art:Icon(e.card_id)
                    end
                    lunge(a, b, tex)
                    Art:Play("IG_ABILITY_ICON_DROP")
                end
            elseif ev.kind == "DAMAGED" and at then
                floatText(at[1], at[2], "-" .. ev.amount, 1, 0.2, 0.15)
                flash(widgets[ev.subject], 1, 0.15, 0.1)
            elseif ev.kind == "SUMMONED" and widgets[ev.subject] then
                fadeIn(widgets[ev.subject], flownTo == ev.subject and FLY * 0.8 or 0)
            elseif ev.kind == "HERO_POWER_USED" then
                flash(frame.powers[sideOf(ev.seat)], 1, 0.85, 0.3, 0.6)
            elseif ev.kind == "DAMAGE_PREVENTED" and at then
                floatText(at[1], at[2], "Blocked", 1, 0.9, 0.4)
            elseif ev.kind == "DIED" and at then
                floatText(at[1], at[2] - 24, "Died", 0.7, 0.7, 0.7)
                local dead = eng:ent(ev.subject)
                if dead and not after[ev.subject] then
                    local ghost = lunge(at, at, Art:Icon(dead.card_id), "die")
                end
            elseif ev.kind == "TURN_STARTED" then
                turnStarted = ev.seat
            end
        end
        if seat == OPP() and move and move.action == "play" and move.raw.entity then
            local e = eng:ent(move.raw.entity)
            local d = e and eng:def_of(e.id)
            if d and d.secret then
                frame.showcase:Hide()
                frame.showcaseLabel:SetText("Opponent played a |cffcc66ffSecret|r")
                frame.showcaseUntil = GetTime() + 2.2
            elseif e then
                frame.showcase.costNow = nil
                frame.showcase:SetCard(e.card_id)
                frame.showcaseLabel:SetText("Opponent played")
                frame.showcaseUntil = GetTime() + 2.2
            end
        end
        if turnStarted == ME() and not eng:is_terminal() then
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
