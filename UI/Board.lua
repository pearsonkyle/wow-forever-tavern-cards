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
local SLOT_W, SLOT_H, SLOT_GAP = 84, 108, 6
local HAND_SCALE = 0.92
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

-- Hero portraits. You: your character's portrait. A friend you duel: theirs while they're in your group
-- or targeted. The house: a character portrait that fits its class. Every hero wears a class badge.
local HOUSE_FACE = { WARRIOR = "Orc_Male", PALADIN = "Human_Male", HUNTER = "Nightelf_Female", ROGUE = "Undead_Male",
    PRIEST = "Human_Female", SHAMAN = "Tauren_Male", MAGE = "Gnome_Male", WARLOCK = "Undead_Female",
    DRUID = "Nightelf_Male", DEATHKNIGHT = "Human_Male", DEMONHUNTER = "Bloodelf_Male" }
local CLASS_BADGE = { WARRIOR = "Ability_Warrior_BattleShout", PALADIN = "Spell_Holy_HolyBolt",
    HUNTER = "INV_Weapon_Bow_07", ROGUE = "Ability_Stealth", PRIEST = "Spell_Holy_PowerWordShield",
    SHAMAN = "Spell_Nature_BloodLust", MAGE = "Spell_Frost_FrostBolt02", WARLOCK = "Spell_Shadow_DeathCoil",
    DRUID = "Ability_Druid_CatForm", DEATHKNIGHT = "Spell_Deathknight_ClassIcon",
    DEMONHUNTER = "Ability_DemonHunter_SpecDPS" }

-- The unit token for a player name, when the client has one (group, raid, target).
local function unitForName(name)
    if not name or not UnitName then return nil end
    local want = (Ambiguate and Ambiguate(name, "none") or name):lower()
    local units = { "target" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for _, unit in ipairs(units) do
        local n, realm = UnitName(unit)
        if n then
            local full = (realm and realm ~= "") and (n .. "-" .. realm) or n
            if full:lower() == want or n:lower() == want then return unit end
        end
    end
end

local setClassIcon

local function setHeroPortrait(b, class, unit, house)
    local tex = b.portrait
    if unit and SetPortraitTexture and UnitExists and UnitExists(unit) then
        SetPortraitTexture(tex, unit)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        local face = HOUSE_FACE[class] and Art:IconIfExists("Achievement_Character_" .. HOUSE_FACE[class])
        if face then
            tex:SetTexture(face)
            tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            setClassIcon(tex, class)
        end
    end
    -- 3D on top when available: the unit, else (the house) the innkeeper chosen for this match. A friend
    -- out of sight keeps their class portrait: an innkeeper would be the wrong face for them.
    local shown
    local function back() tex:SetAlpha(1) end
    if unit and UnitExists and UnitExists(unit) then
        shown = TC.Models:Show(b.model, "unit", unit, 0.85, 1, nil, back)
    elseif house then
        shown = TC.Models:Show(b.model, "npc", house, 0.85, 1, nil, back)
    else
        TC.Models:Hide(b.model)
    end
    tex:SetAlpha(shown and TC.Models:ArtAlpha(1) or 1)
    local badge = CLASS_BADGE[class] and Art:IconIfExists(CLASS_BADGE[class])
    b.badge:SetShown(badge ~= nil)
    if badge then b.badge.icon:SetTexture(badge) end
    b.badge.class = class
end

function setClassIcon(tex, class)
    local square = Art:SquareClassIcon(class)
    if square then
        tex:SetTexture(square)
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        return
    end
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

-- A glowing frame around a whole card (the hand): a bright line on its edge and a soft halo outside it.
-- Same interface as addGlow's texture (SetVertexColor, Show, Hide, SetAlpha).
local function addBorderGlow(f, out)
    out = out or 9
    local g = CreateFrame("Frame", nil, f)
    g:SetPoint("TOPLEFT", -out, out)
    g:SetPoint("BOTTOMRIGHT", out, -out)
    g:SetFrameLevel(f:GetFrameLevel() + 6)
    g:EnableMouse(false)
    local parts = {}
    local function strip(layer, horizontal, a1, a2)
        local t = g:CreateTexture(nil, layer)
        t:SetTexture("Interface\\Buttons\\WHITE8x8")
        t:SetBlendMode("ADD")
        t.horizontal, t.a1, t.a2 = horizontal, a1, a2
        parts[#parts + 1] = t
        return t
    end
    local w = 3   -- the bright line, just inside the card's edge
    local top = strip("OVERLAY", false, 1, 1)
    top:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0) top:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, -w)
    local bottom = strip("OVERLAY", false, 1, 1)
    bottom:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, w) bottom:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    local left = strip("OVERLAY", true, 1, 1)
    left:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -w) left:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", w, w)
    local right = strip("OVERLAY", true, 1, 1)
    right:SetPoint("TOPLEFT", f, "TOPRIGHT", -w, -w) right:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, w)
    -- The halo: strips fading outward (gradient from the card's edge to nothing).
    local ht = strip("ARTWORK", false, 0, 0.75)    -- above: transparent at its top, bright at the card
    ht:SetPoint("TOPLEFT", g, "TOPLEFT", out, 0) ht:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 0)
    local hb = strip("ARTWORK", false, 0.75, 0)
    hb:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 0, 0) hb:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", -out, 0)
    local hl = strip("ARTWORK", true, 0, 0.75)     -- left: transparent far left, bright at the card
    hl:SetPoint("TOPLEFT", g, "TOPLEFT", 0, -out) hl:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 0, 0)
    local hr = strip("ARTWORK", true, 0.75, 0)
    hr:SetPoint("TOPLEFT", f, "TOPRIGHT", 0, 0) hr:SetPoint("BOTTOMRIGHT", g, "BOTTOMRIGHT", 0, out)
    function g:SetVertexColor(r, gg, b)
        for _, t in ipairs(parts) do
            if t.a1 == t.a2 then
                t:SetVertexColor(r, gg, b, t.a1)
            elseif CreateColor and t.SetGradient then
                -- VERTICAL runs bottom -> top; HORIZONTAL left -> right.
                local c1, c2 = CreateColor(r, gg, b, t.a1), CreateColor(r, gg, b, t.a2)
                if t.horizontal then
                    t:SetGradient("HORIZONTAL", c1, c2)
                else
                    t:SetGradient("VERTICAL", c2, c1)
                end
            else
                t:SetVertexColor(r, gg, b, 0.4)
            end
        end
    end
    g:Hide()
    allGlows[#allGlows + 1] = g
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

-- A square framed portrait: a gold tooltip-style border and the picture inset, icon edges trimmed.
local function squareFrame(b, r, g, bl)
    b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    b:SetBackdropColor(0.05, 0.04, 0.03, 1)
    b:SetBackdropBorderColor(r or 0.85, g or 0.7, bl or 0.3, 1)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", 4, -4)
    t:SetPoint("BOTTOMRIGHT", -4, 4)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local f = b:CreateTexture(nil, "OVERLAY", nil, 6)
    f:SetAllPoints(t)
    f:SetColorTexture(1, 1, 1, 1)
    f:SetBlendMode("ADD")
    f:SetAlpha(0)
    b.flash = f
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
        g.ring = g:CreateTexture(nil, "ARTWORK")
        g.ring:SetAllPoints()
        g.ring:SetColorTexture(0.9, 0.75, 0.3, 1)
        g.tex = g:CreateTexture(nil, "OVERLAY")
        g.tex:SetPoint("TOPLEFT", 3, -3)
        g.tex:SetPoint("BOTTOMRIGHT", -3, 3)
        g.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
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
        local dx = 0
        if w.shake then
            w.shake = w.shake - elapsed
            if w.shake <= 0 then
                w.shake = nil
            else
                dx = math.sin(w.shake * 70) * 4 * (w.shake / 0.3)
            end
        end
        if not w.shake and math.abs(w.gx - w.tx) < 0.5 and math.abs(w.gy - w.ty) < 0.5 then
            w.gx, w.gy = w.tx, w.ty
            gliders[w] = nil
        end
        w.place(w, w.gx + dx, w.gy)
    end
end

local zoom
-- A big copy of the card beside a hovered minion or weapon, with the tooltip beside it.
local function showZoom(owner, cardId)
    if not zoom then
        zoom = CardWidget:CreateGame(frame)
        zoom:EnableMouse(false)
        zoom:SetScale(1.45)
        zoom:SetFrameLevel(frame:GetFrameLevel() + 48)
    end
    zoom.costNow = nil
    zoom:SetCard(cardId)
    zoom:ClearAllPoints()
    local x = owner:GetCenter()
    local right = x and frame:GetCenter() and x < frame:GetCenter()
    -- Offsets are in the zoom's own (scaled) units.
    if right then
        zoom:SetPoint("LEFT", owner, "RIGHT", 12 / 1.45, 0)
    else
        zoom:SetPoint("RIGHT", owner, "LEFT", -12 / 1.45, 0)
    end
    zoom:Show()
    return zoom, right
end

local function hideZoom()
    if zoom then zoom:Hide() end
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
    hideZoom()
    for w in pairs(gliders) do
        w.gx, w.gy, w.shake = w.tx, w.ty, nil
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
    b.art:SetHeight(SLOT_W - 12)   -- square: the whole portrait, no stretching
    b.art:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    b.name:SetPoint("TOPLEFT", b.art, "BOTTOMLEFT", -2, -1)
    b.name:SetPoint("TOPRIGHT", b.art, "BOTTOMRIGHT", 2, -1)
    b.name:SetHeight(14)
    b.name:SetWordWrap(false)
    -- The creature in 3D over its (dimmed) icon, when it has one; markers and gems stay on top.
    b.model = TC.Models:Create(b)
    b.model:SetAllPoints(b.art)
    b.model:SetFrameLevel(b:GetFrameLevel() + 1)
    b.top = CreateFrame("Frame", nil, b)
    b.top:SetAllPoints()
    b.top:SetFrameLevel(b:GetFrameLevel() + 2)
    b.attack = gem(b, 26, 0.85, 0.65, 0.15, "GameFontHighlight")
    b.attack:SetPoint("BOTTOMLEFT", -5, -5)
    b.attack:SetFrameLevel(b:GetFrameLevel() + 3)
    b.health = gem(b, 26, 0.75, 0.12, 0.1, "GameFontHighlight")
    b.health:SetPoint("BOTTOMRIGHT", 5, -5)
    b.health:SetFrameLevel(b:GetFrameLevel() + 3)
    b.taunt = b.top:CreateTexture(nil, "OVERLAY")
    b.taunt:SetSize(22, 22)
    b.taunt:SetPoint("TOP", 0, 8)
    b.taunt:SetTexture(Art:SafeIcon("INV_Shield_06"))
    b.shield = b.top:CreateTexture(nil, "OVERLAY", nil, 2)
    b.shield:SetTexture("Interface\\Buttons\\CheckButtonGlow")
    b.shield:SetBlendMode("ADD")
    b.shield:SetVertexColor(1, 0.9, 0.3, 0.9)
    b.shield:SetPoint("TOPLEFT", -10, 10)
    b.shield:SetPoint("BOTTOMRIGHT", 10, -10)
    b.status = b.top:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.status:SetPoint("CENTER", b.art, "CENTER")
    b.status:SetShadowOffset(2, -2)
    addGlow(b, 1.7)
    addFlash(b.top)
    b.flash = b.top.flash
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) Board.hover = self.entity entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil hideZoom() GameTooltip:Hide() end)
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
    -- A prop (item or object), a creature by its model, or a creature.
    local prop = TC.CardProps and TC.CardProps[e.card_id]
    local disp = not prop and TC.CardDisplays and TC.CardDisplays[e.card_id]
    local kind = prop and prop[1] or (disp and "display" or "npc")
    local npc = prop and prop[2] or disp or (TC.CardModels and TC.CardModels[e.card_id])
    if npc and card and card.type ~= "LOCATION" and TC.Models:Show(b.model, kind, npc, prop and 0 or 0.6, 1.05, nil,
        function() b.art:SetAlpha(1) end, prop and prop[3]) then
        b.art:SetAlpha(TC.Models:ArtAlpha(0.3))
    else
        TC.Models:Hide(b.model)
        b.art:SetAlpha(1)
    end
    b.name:SetText(card and card.name or (d and d.name) or e.card_id)
    local r, g, bl = Art:RarityColor(card and card.rarity or "FREE")
    b:SetBackdropBorderColor(0.9, 0.9, 0.9, 1)   -- rarity shows in the name's colour
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
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(84, 84)
    b.portrait = squareFrame(b)
    -- The hero in 3D (your character, a grouped friend, the house's innkeeper) over the flat portrait.
    b.model = TC.Models:Create(b)
    b.model:SetAllPoints(b.portrait)
    b.model:SetFrameLevel(b:GetFrameLevel() + 1)
    b.badge = CreateFrame("Frame", nil, b, "BackdropTemplate")
    b.badge:SetSize(24, 24)
    b.badge:SetPoint("TOPLEFT", -7, 7)
    b.badge:SetFrameLevel(b:GetFrameLevel() + 4)
    b.badge.icon = squareFrame(b.badge, 0.85, 0.7, 0.3)
    b.badge:EnableMouse(true)
    b.badge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[self.class]) or self.class or "", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    b.badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.attack = gem(b, 30, 0.85, 0.65, 0.15, "GameFontHighlightLarge")
    b.attack:SetPoint("BOTTOMLEFT", -8, -4)
    b.health = gem(b, 30, 0.75, 0.12, 0.1, "GameFontHighlightLarge")
    b.health:SetPoint("BOTTOMRIGHT", 8, -4)
    b.armor = gem(b, 26, 0.55, 0.55, 0.6, "GameFontHighlight")
    b.armor:SetPoint("BOTTOM", b.health, "TOP", 0, -2)
    for _, g in ipairs({ b.attack, b.health, b.armor }) do g:SetFrameLevel(b:GetFrameLevel() + 3) end
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
    b:SetScript("OnEnter", function(self) Board.hover = self.entity entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil hideZoom() GameTooltip:Hide() end)
    return b
end

local function powerButton(parent)
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(52, 52)
    b.icon = squareFrame(b, 0.75, 0.6, 0.3)
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
    local b = CreateFrame("Button", nil, parent, "BackdropTemplate")
    b:SetSize(52, 52)
    b.icon = squareFrame(b, 0.6, 0.6, 0.65)
    b.attack = gem(b, 22, 0.85, 0.65, 0.15, "GameFontHighlightSmall")
    b.attack:SetPoint("BOTTOMLEFT", -6, -4)
    b.durability = gem(b, 22, 0.45, 0.45, 0.5, "GameFontHighlightSmall")
    b.durability:SetPoint("BOTTOMRIGHT", 6, -4)
    b:SetScript("OnEnter", function(self) entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() hideZoom() GameTooltip:Hide() end)
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

local function cardBack(parent, w, h)
    return TC.CardBacks:Create(parent, w or 34, h or 48)
end

-- The two sides' card backs (kept with the match): yours from your deck, the house's at random.
local function backOf(seat)
    local record = Match:Record()
    local backs = record and record.backs
    return backs and backs[seat + 1] or TC.CardBacks.DEFAULT
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
        -- Above everything on the card (a 3D portrait included), so the replace mark always shows.
        w.markFrame = CreateFrame("Frame", nil, w)
        w.markFrame:SetAllPoints()
        w.markFrame:SetFrameLevel(w:GetFrameLevel() + 6)
        w.mark = w.markFrame:CreateTexture(nil, "OVERLAY", nil, 7)
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
    -- A title over more lines makes room for itself (the cards move down).
    local extra = select(2, title:gsub("\n", "")) * 20
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
                w:SetPoint("CENTER", c, "CENTER", -(inRow - 1) * step / 2 + col * step, (rows - 1) * 75 - row * 150 - extra / 2)
                w.costNow = nil
                w:SetCard(opt.card)
                w.onClick = function(_, button)
                    if button == "LeftButton" then pick(i, w) end
                end
            end
        end
        c:SetSize(math.max(360, perRow * step + 40), 250 + (rows - 1) * 150 + extra)
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
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 32,
        insets = { left = 8, right = 8, top = 8, bottom = 8 } })
    f:SetBackdropColor(0.1, 0.07, 0.05, 1)
    f:Hide()
    tinsert(UISpecialFrames, "TavernCardsBoard")

    -- The table top: dark wood with a lighter felt where the minions stand.
    -- The table: a dungeon painting (Board:SetTable) under a dark wash so cards and text read; plain dark
    -- wood when there's no painting.
    -- A soft-focus painting (a small patch, enlarged: the texture filter blurs it), muted colours, a dark
    -- wash and darker edges, so the cards stand out against it.
    f.tableArt = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.tableArt:SetPoint("TOPLEFT", 10, -10)
    f.tableArt:SetPoint("BOTTOMRIGHT", -10, 10)
    f.tableArt:Hide()
    f.tableSoft = {}
    f.tableEdge = f:CreateTexture(nil, "BACKGROUND", nil, 4)
    f.tableEdge:SetPoint("TOPLEFT", 10, -10)
    f.tableEdge:SetPoint("BOTTOMRIGHT", -10, 10)
    f.tableEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.tableEdge:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.3), CreateColor(0, 0, 0, 0))
    f.tableEdge:Hide()
    f.tableEdgeR = f:CreateTexture(nil, "BACKGROUND", nil, 4)
    f.tableEdgeR:SetPoint("TOPRIGHT", -10, -10)
    f.tableEdgeR:SetPoint("BOTTOMRIGHT", -10, 10)
    f.tableEdgeR:SetWidth(220)
    f.tableEdgeR:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.tableEdgeR:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.3))
    f.tableEdgeR:Hide()
    f.tableEdge:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 230, 10)
    local top = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    top:SetPoint("TOPLEFT", 10, -10)
    top:SetPoint("BOTTOMRIGHT", -10, 10)
    top:SetColorTexture(1, 1, 1, 1)
    top:SetGradient("VERTICAL", CreateColor(0.16, 0.1, 0.06, 0.93), CreateColor(0.22, 0.14, 0.08, 0.93))
    f.wash = top
    -- The play mat: a world map (the zone you're in, Board:SetMat) under a felt-and-glass tint.
    local mat = CreateFrame("Frame", nil, f)
    mat:SetPoint("TOPLEFT", 190, -178)
    mat:SetPoint("TOPRIGHT", -190, -178)
    mat:SetHeight(244)
    mat:SetFrameLevel(f:GetFrameLevel())
    if mat.SetClipsChildren then mat:SetClipsChildren(true) end
    local matW = W - 380
    local tile = matW / 4
    mat.grid = CreateFrame("Frame", nil, mat)
    mat.grid:SetFrameLevel(f:GetFrameLevel())
    mat.grid:SetSize(matW, tile * 3)
    mat.grid:SetPoint("CENTER", mat, "CENTER", 0, 0)
    mat.tiles = {}
    for i = 1, 12 do
        local t = mat.grid:CreateTexture(nil, "BACKGROUND", nil, 1)
        t:SetSize(tile, tile)
        t:SetPoint("TOPLEFT", ((i - 1) % 4) * tile, -math.floor((i - 1) / 4) * tile)
        mat.tiles[i] = t
    end
    local felt = mat.grid:CreateTexture(nil, "BORDER")
    felt:SetAllPoints(mat)
    felt:SetColorTexture(1, 1, 1, 1)
    felt:SetGradient("VERTICAL", CreateColor(0.06, 0.12, 0.07, 0.62), CreateColor(0.05, 0.1, 0.06, 0.55))
    f.felt = felt
    local glass = mat.grid:CreateTexture(nil, "BORDER", nil, 1)
    glass:SetAllPoints(mat)
    glass:SetTexture("Interface\\FrameGeneral\\UI-Background-Marble")
    glass:SetVertexColor(0.35, 0.55, 0.35, 0.12)
    f.mat = mat
    local feltEdge = CreateFrame("Frame", nil, f, "BackdropTemplate")
    feltEdge:SetPoint("TOPLEFT", mat, -4, 4)
    feltEdge:SetPoint("BOTTOMRIGHT", mat, 4, -4)
    feltEdge:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14 })
    feltEdge:SetBackdropBorderColor(0.75, 0.6, 0.3, 0.9)
    feltEdge:SetFrameLevel(f:GetFrameLevel() + 1)
    local line = mat.grid:CreateTexture(nil, "ARTWORK")
    line:SetPoint("LEFT", mat, "LEFT", 0, 0)
    line:SetPoint("RIGHT", mat, "RIGHT", 0, 0)
    line:SetHeight(2)
    line:SetColorTexture(0.8, 0.65, 0.3, 0.5)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 22, -18)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    close:SetScript("OnClick", function() f:Hide() end)
    -- Sound on/off, right on the table.
    f.sound = CreateFrame("Button", nil, f)
    f.sound:SetSize(22, 22)
    f.sound:SetPoint("RIGHT", close, "LEFT", -4, 0)
    f.sound.icon = f.sound:CreateTexture(nil, "ARTWORK")
    f.sound.icon:SetAllPoints()
    f.sound:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local function soundIcon()
        local muted = TC.db.settings.mute
        f.sound.icon:SetTexture(Art:SafeIcon(muted and "Spell_Shadow_SoulLeech_3" or "Spell_Holy_Silence"))
        f.sound.icon:SetDesaturated(muted and true or false)
    end
    f.sound:SetScript("OnClick", function()
        TC.db.settings.mute = not TC.db.settings.mute
        soundIcon()
    end)
    f.sound:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(TC.db.settings.mute and "Sounds off" or "Sounds on", 1, 0.82, 0)
        GameTooltip:AddLine("Click to turn the card game's sounds " .. (TC.db.settings.mute and "on." or "off."), 1, 1, 1)
        GameTooltip:Show()
    end)
    f.sound:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sound:SetScript("OnShow", soundIcon)
    soundIcon()
    f.concede = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.concede:SetSize(90, 22)
    f.concede:SetPoint("RIGHT", f.sound, "LEFT", -6, 0)
    f.concede:SetText("Concede")
    f.concede:SetScript("OnClick", function()
        TC:Confirm("Concede this match?", function() Match:Concede() end)
    end)

    -- Opponent (top).
    f.oppHand = CreateFrame("Frame", nil, f)
    f.oppHand:SetSize(400, 48)
    f.oppHand:SetPoint("TOP", 0, -26)
    f.oppHand.backs = {}
    -- Each side's deck: a pile of its card backs with the cards left.
    f.piles = {}
    for side = 0, 1 do
        local pile = cardBack(f, 42, 60)
        pile:SetPoint("TOPRIGHT", f, "TOPRIGHT", -150, side == 1 and -96 or -446)
        pile.count = pile:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        pile.count:SetPoint("BOTTOM", 0, 4)
        pile.count:SetShadowOffset(1, -1)
        pile.shadow = pile:CreateTexture(nil, "BACKGROUND", nil, -1)
        pile.shadow:SetPoint("TOPLEFT", 3, -3)
        pile.shadow:SetPoint("BOTTOMRIGHT", 5, -5)
        pile.shadow:SetColorTexture(0, 0, 0, 0.5)
        pile:EnableMouse(true)
        pile:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(side == 0 and "Your deck" or "Opponent's deck", 1, 0.82, 0)
            GameTooltip:AddLine(("%s cards left. Card back: %s."):format(self.count:GetText() or "?",
                TC.CardBacks:Name(self.backId)), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        pile:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.piles[side] = pile
    end
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
        addBorderGlow(w)
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
    local unit
    if seat == ME() then
        unit = "player"
    elseif record and record.kind == "duel" and record.opponent then
        unit = unitForName(record.opponent.name)
    end
    setHeroPortrait(b, classes[seat + 1], unit, seat ~= ME() and Match:HouseModel())
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
    local pile = frame.piles[side]
    local left = #eng:deck_ids(seat)
    if pile.backId ~= backOf(seat) then pile:SetBack(backOf(seat)) end
    pile.count:SetText(left)
    pile:SetAlpha(left > 0 and 1 or 0.35)

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
    local oppBack = backOf(OPP())
    for i = 1, 10 do
        local back = backs[i]
        if back.backId ~= oppBack then back:SetBack(oppBack) end
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
    self:ShowChoice("Your opening hand\nClick the cards you want to replace", options, function(i, w)
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
            Art:Sfx("select")
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
        local rec = Match:Record()
        -- Matches from before the painted table kept their painting as the mat: it is the table now.
        if rec and type(rec.mat) == "number" then rec.mat = nil end   -- map art Forever lacks
    if rec and type(rec.mat) == "string" and rec.mat:find("^paint:") then
            rec.table, rec.mat = rec.mat:sub(7), nil
        end
        if rec and not rec.mat then rec.mat = Board.PickMat() end
        if rec and rec.table == nil then rec.table = Board.PickTable() end
        Board:SetMat(rec and rec.mat)
        Board:SetTable(rec and rec.table)
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
                    Art:Sfx("play")
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
                    Art:Sfx("attack")
                    local aw = widgets[ev.subject]
                    if aw and aw.model then TC.Models:Animate(aw.model, "attack") end
                end
            elseif ev.kind == "DAMAGED" and at then
                floatText(at[1], at[2], "-" .. ev.amount, 1, 0.2, 0.15)
                flash(widgets[ev.subject], 1, 0.15, 0.1)
                local hit = widgets[ev.subject]
                if hit and hit.model then TC.Models:Animate(hit.model, "hit") end
                if hit and hit.place then
                    -- A short shake on the minion that took the hit.
                    hit.shake = 0.3
                    gliders[hit] = true
                end
                Art:Sfx("hit")
            elseif ev.kind == "SUMMONED" and widgets[ev.subject] then
                fadeIn(widgets[ev.subject], flownTo == ev.subject and FLY * 0.8 or 0)
            elseif ev.kind == "HERO_POWER_USED" then
                flash(frame.powers[sideOf(ev.seat)], 1, 0.85, 0.3, 0.6)
                TC.Models:Animate(frame.heroes[sideOf(ev.seat)].model, "cast")
                Art:Sfx("power")
            elseif ev.kind == "DAMAGE_PREVENTED" and at then
                floatText(at[1], at[2], "Blocked", 1, 0.9, 0.4)
            elseif ev.kind == "DIED" and at then
                floatText(at[1], at[2] - 24, "Died", 0.7, 0.7, 0.7)
                local dead = eng:ent(ev.subject)
                if dead and not after[ev.subject] then
                    lunge(at, at, Art:Icon(dead.card_id), "die")
                    Art:Sfx("death")
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
            Art:Sfx("turn")
        end
        return
    end
    if what == "end" then
        Art:Sfx(Match.result == "win" and "win" or "lose")
        Board:Refresh()
    end
end

Match:Subscribe(onMatch)

-- Play mats: the painted world maps (4x3 tiles of Interface\WorldMap\<zone>\<zone>N). The mat is the
-- map of the zone you're in when the match starts (kept with the match), else one of these at random.
local ZONE_MAPS = {
    ["Elwynn Forest"] = "Elwynn", ["Westfall"] = "Westfall", ["Duskwood"] = "Duskwood",
    ["Redridge Mountains"] = "Redridge", ["Stranglethorn Vale"] = "Stranglethorn", ["The Barrens"] = "Barrens",
    ["Durotar"] = "Durotar", ["Mulgore"] = "Mulgore", ["Ashenvale"] = "Ashenvale", ["Darkshore"] = "Darkshore",
    ["Teldrassil"] = "Teldrassil", ["Dun Morogh"] = "DunMorogh", ["Loch Modan"] = "LochModan", ["Wetlands"] = "Wetlands",
    ["Arathi Highlands"] = "Arathi", ["Hillsbrad Foothills"] = "Hilsbrad", ["Alterac Mountains"] = "Alterac",
    ["Tirisfal Glades"] = "Tirisfal", ["Silverpine Forest"] = "Silverpine", ["Tanaris"] = "Tanaris", ["Feralas"] = "Feralas",
    ["Desolace"] = "Desolace", ["Stonetalon Mountains"] = "StonetalonMountains", ["Thousand Needles"] = "ThousandNeedles",
    ["Dustwallow Marsh"] = "Dustwallow", ["Burning Steppes"] = "BurningSteppes", ["Searing Gorge"] = "SearingGorge",
    ["Badlands"] = "Badlands", ["Swamp of Sorrows"] = "SwampOfSorrows", ["Blasted Lands"] = "BlastedLands",
    ["Deadwind Pass"] = "DeadwindPass", ["Eastern Plaguelands"] = "EasternPlaguelands",
    ["Western Plaguelands"] = "WesternPlaguelands", ["Winterspring"] = "Winterspring", ["Felwood"] = "Felwood",
    ["Azshara"] = "Aszhara", ["Un'Goro Crater"] = "UngoroCrater", ["Silithus"] = "Silithus", ["Moonglade"] = "Moonglade",
    ["The Hinterlands"] = "Hinterlands", ["Ironforge"] = "Ironforge", ["Orgrimmar"] = "Ogrimmar",
    ["Thunder Bluff"] = "ThunderBluff", ["Undercity"] = "Undercity", ["Darnassus"] = "Darnassis",
}
local MAT_POOL = { "Elwynn", "Westfall", "Duskwood", "Barrens", "Durotar", "Mulgore", "Ashenvale", "DunMorogh",
    "Stranglethorn", "Tanaris", "Feralas", "Arathi", "Wetlands", "Tirisfal", "Hinterlands", "Winterspring", "Silithus" }

local function mapExists(zone)
    return not GetFileIDFromPath or GetFileIDFromPath(("Interface\\WorldMap\\%s\\%s1"):format(zone, zone)) ~= nil
end

-- Classic zone maps (uiMapIDs) for when the zone you're in has no map art: Elwynn, Westfall, Duskwood,
-- the Barrens, Durotar, Mulgore, Ashenvale, Dun Morogh, Stranglethorn, Tanaris, Feralas, Arathi,
-- Wetlands, Tirisfal, the Hinterlands, Winterspring, Silithus, Redridge, Loch Modan, Darkshore.
local CLASSIC_MAPS = { 1429, 1436, 1431, 1413, 1411, 1412, 1440, 1426, 1434, 1446, 1444, 1417, 1437, 1420, 1425,
    1452, 1451, 1433, 1432, 1439 }

-- A map's art in the client: its tile layout and the tile textures (file ids), or nil.
local function mapArt(mapID)
    if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then return nil end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local layer = ok and type(layers) == "table" and layers[1]
    if not layer or not layer.tileWidth or layer.tileWidth <= 0 or not layer.layerWidth then return nil end
    local ok2, tiles = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if not ok2 or type(tiles) ~= "table" or #tiles == 0 then return nil end
    return layer, tiles
end
Board.MapArt = mapArt

-- When the client offers no map art: the painting of the dungeon nearest to where you stand (the game's
-- loading screens), else a random one, as a wide crop.
local ZONE_PAINTINGS = {
    ["Durotar"] = "RagefireChasm", ["Orgrimmar"] = "RagefireChasm", ["The Barrens"] = "WailingCaverns",
    ["Westfall"] = "Deadmines", ["Elwynn Forest"] = "StormwindStockade", ["Stormwind City"] = "StormwindStockade",
    ["Silverpine Forest"] = "ShadowfangKeep", ["Ashenvale"] = "BlackfathomDeeps", ["Darkshore"] = "BlackfathomDeeps",
    ["Dun Morogh"] = "Gnomeregan", ["Ironforge"] = "Gnomeregan", ["Tirisfal Glades"] = "Monastery",
    ["Undercity"] = "Monastery", ["Badlands"] = "Uldaman", ["Loch Modan"] = "Uldaman", ["Tanaris"] = "ZulFarrak",
    ["Desolace"] = "Maraudon", ["Swamp of Sorrows"] = "SunkenTemple", ["Burning Steppes"] = "BlackrockDepths",
    ["Searing Gorge"] = "BlackrockDepths", ["Feralas"] = "DireMaul", ["Western Plaguelands"] = "Scholomance",
    ["Eastern Plaguelands"] = "Strathome", ["Stranglethorn Vale"] = "ZulGurub", ["Silithus"] = "AhnQiraj40man",
    ["Thousand Needles"] = "RazorfenDowns", ["Mulgore"] = "RazorfenKraul", ["Thunder Bluff"] = "RazorfenKraul",
    ["Winterspring"] = "Kalimdor", ["Moonglade"] = "Kalimdor", ["Teldrassil"] = "Kalimdor", ["Darnassus"] = "Kalimdor",
    ["Duskwood"] = "EasternKingdom", ["Redridge Mountains"] = "BlackrockSpire", ["Wetlands"] = "EasternKingdom",
}
local PAINTINGS = { "Deadmines", "WailingCaverns", "ShadowfangKeep", "Gnomeregan", "Monastery", "Uldaman", "ZulFarrak",
    "Maraudon", "SunkenTemple", "BlackrockDepths", "DireMaul", "Scholomance", "Strathome", "MoltenCore", "ZulGurub",
    "BlackwingLair", "AhnQiraj40man", "Naxxramas", "Kalimdor", "EasternKingdom" }

local function paintingExists(name)
    return not GetFileIDFromPath or GetFileIDFromPath("Interface\\Glues\\LoadingScreens\\LoadScreen" .. name) ~= nil
end

-- The mat for a new match: the map of where you stand (or the zone around your city/sub-zone), else a
-- random classic zone; the old world-map file paths as a last resort.
function Board.PickMat()
    -- WoW: Forever's client reports map art (tile file ids) for its zones but doesn't ship the files: the
    -- tiles draw nothing. The play field is felt over the painted table instead.
    if true then return nil end
    if C_Map and C_Map.GetBestMapForUnit then
        local id = C_Map.GetBestMapForUnit("player")
        for _ = 1, 4 do
            if not id then break end
            if mapArt(id) then return id end
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            id = info and info.parentMapID
        end
        for _ = 1, 8 do
            local id2 = CLASSIC_MAPS[math.random(#CLASSIC_MAPS)]
            if mapArt(id2) then return id2 end
        end
    end
    local here = GetRealZoneText and GetRealZoneText()
    local zone = here and ZONE_MAPS[here]
    if zone and mapExists(zone) then return zone end
end

-- The table painting for a new match: the Play tab's choice (TC.db.settings.tableArt: a painting file,
-- "plain", or automatic), automatic being the dungeon nearest to where you stand, else a random one.
function Board.PickTable()
    local choice = TC.db and TC.db.settings.tableArt
    if choice == "plain" then return false end
    if type(choice) == "string" and choice ~= "auto" and paintingExists(choice:gsub("^LoadScreen", "")) then
        return (choice:gsub("^LoadScreen", ""))
    end
    local here = GetRealZoneText and GetRealZoneText()
    local painting = here and ZONE_PAINTINGS[here]
    if painting and paintingExists(painting) then return painting end
    for _ = 1, 8 do
        local p = PAINTINGS[math.random(#PAINTINGS)]
        if paintingExists(p) then return p end
    end
    return false
end

-- painting: a loading-screen name ("Deadmines") or false (plain table).
function Board:SetTable(painting)
    if not frame then return end
    local ok = painting and paintingExists(painting)
    local layers = { frame.tableArt, unpack(frame.tableSoft) }
    if ok then
        -- Below the game logo the loading screens carry across their top, cropped to the board's shape
        -- (which also zooms it a little: softer).
        local w, h = W - 20, H - 20
        -- A true soft focus without ghosting: a patch of the painting (just under a third of its width)
        -- stretched over the whole board. The texture filter smooths it into the painting's colours and
        -- light, with no shapes to catch the eye.
        local wfrac = 0.42  -- smaller = blurrier, larger = more of the painting's detail
        local hfrac = wfrac * 4 / (3 * (w / h))
        local cx, cy = 0.5, 0.62
        frame.tableArt:SetTexture("Interface\\Glues\\LoadingScreens\\LoadScreen" .. painting)
        frame.tableArt:SetTexCoord(cx - wfrac / 2, cx + wfrac / 2, cy - hfrac / 2, cy + hfrac / 2)
        if frame.tableArt.SetDesaturation then pcall(frame.tableArt.SetDesaturation, frame.tableArt, 0.3) end
        frame.tableArt:SetVertexColor(0.95, 0.9, 0.85)
        frame.tableArt:Show()
        for _, t in ipairs(frame.tableSoft) do t:Hide() end
    else
        for _, t in ipairs(layers) do t:Hide() end
    end
    frame.tableEdge:SetShown(ok and true or false)
    frame.tableEdgeR:SetShown(ok and true or false)
    Board.tableShown = ok and painting or nil
    frame.wash:SetGradient("VERTICAL", CreateColor(0.06, 0.04, 0.03, ok and 0.55 or 0.93),
        CreateColor(0.1, 0.07, 0.04, ok and 0.45 or 0.93))
    self:SetMat(Board.matCurrent)
end

local function tileTexture(i)
    local tiles = frame.mat.tiles
    if not tiles[i] then
        tiles[i] = frame.mat.grid:CreateTexture(nil, "BACKGROUND", nil, 1)
    end
    return tiles[i]
end

-- mat: a uiMapID (map art from C_Map), a zone folder name (older clients), or nil/false (plain felt).
function Board:SetMat(mat)
    if not frame then return end
    for _, t in ipairs(frame.mat.tiles) do t:Hide() end
    if frame.mat.paint then frame.mat.paint:Hide() end
    local matW = frame.mat:GetWidth()
    if not matW or matW <= 0 then matW = W - 380 end
    local ok = false
    if type(mat) == "number" then
        local layer, tiles = mapArt(mat)
        if layer then
            local cols = math.max(1, math.ceil(layer.layerWidth / layer.tileWidth))
            local scale = matW / layer.layerWidth
            local tw, th = layer.tileWidth * scale, layer.tileHeight * scale
            frame.mat.grid:SetSize(matW, layer.layerHeight * scale)
            for i, fileID in ipairs(tiles) do
                local t = tileTexture(i)
                t:ClearAllPoints()
                t:SetSize(tw, th)
                t:SetPoint("TOPLEFT", ((i - 1) % cols) * tw, -math.floor((i - 1) / cols) * th)
                t:SetTexture(fileID)
                t:Show()
            end
            ok = true
        end
    elseif type(mat) == "string" and mat:find("^paint:") and paintingExists(mat:sub(7)) then
        -- A wide band across the middle of the 4:3 painting.
        local t = frame.mat.paint
        if not t then
            t = frame.mat.grid:CreateTexture(nil, "BACKGROUND", nil, 2)
            frame.mat.paint = t
        end
        local band = math.min(1, (4 / 3) * (frame.mat:GetHeight() or 244) / matW)
        frame.mat.grid:SetSize(matW, frame.mat:GetHeight() or 244)
        t:ClearAllPoints()
        t:SetAllPoints(frame.mat)
        t:SetTexture("Interface\\Glues\\LoadingScreens\\LoadScreen" .. mat:sub(7))
        t:SetTexCoord(0, 1, 0.5 - band / 2, 0.5 + band / 2)
        t:Show()
        ok = true
    elseif type(mat) == "string" and mapExists(mat) then
        local tile = matW / 4
        frame.mat.grid:SetSize(matW, tile * 3)
        for i = 1, 12 do
            local t = tileTexture(i)
            t:ClearAllPoints()
            t:SetSize(tile, tile)
            t:SetPoint("TOPLEFT", ((i - 1) % 4) * tile, -math.floor((i - 1) / 4) * tile)
            t:SetTexture(("Interface\\WorldMap\\%s\\%s%d"):format(mat, mat, i))
            t:Show()
        end
        ok = true
    end
    Board.matShown, Board.matCurrent = ok and mat or nil, mat
    -- Over a map the felt is a light tint so the map reads; over a painted table it is translucent green
    -- felt; on the plain table it is solid.
    local a1, a2 = 0.92, 0.9
    if ok then a1, a2 = 0.42, 0.36 elseif Board.tableShown then a1, a2 = 0.6, 0.52 end
    frame.felt:SetGradient("VERTICAL", CreateColor(0.06, 0.12, 0.07, a1), CreateColor(0.05, 0.1, 0.06, a2))
end

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
    local record = Match:Record()
    -- Matches from before the painted table kept their painting as the mat: it is the table now.
    if record and type(record.mat) == "number" then record.mat = nil end   -- map art Forever lacks
    if record and type(record.mat) == "string" and record.mat:find("^paint:") then
        record.table, record.mat = record.mat:sub(7), nil
    end
    if record and not record.mat then record.mat = Board.PickMat() end
    if record and record.table == nil then record.table = Board.PickTable() end
    self:SetMat(record and record.mat or Board.lastMat)
    self:SetTable(record and record.table or Board.lastTable)
    Board.lastMat = record and record.mat or Board.lastMat
    Board.lastTable = record and record.table or Board.lastTable
    if not frame:IsShown() then
        frame.log:Clear()
        local record = Match:Record()
        for _, line in ipairs(record and record.log or {}) do frame.log:AddMessage(line) end
    end
    frame:Show()
    self:Refresh()
end

function Board:Close()
    if frame then frame:Hide() end
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
