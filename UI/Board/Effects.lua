-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Board effects: floating numbers, attack lunges, flashes and fades, flying cards, the targeting
-- arrow, gliding into place and the zoomed card. Purely visual.

local TC = TavernCards_NS
local Board = TC.Board
local P, S = Board._P, Board._S
local CardWidget = TC.CardWidget
local Art = TC.Art
local widgets = P.widgets

-- ---- floating numbers --------------------------------------------------------------------------

local floats = {}
local function floatText(x, y, text, r, g, b)
    local fs
    for _, f in ipairs(floats) do
        if not f.active then fs = f break end
    end
    if not fs then
        fs = S.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        fs:SetShadowOffset(2, -2)
        floats[#floats + 1] = fs
    end
    fs.active, fs.x, fs.y, fs.t = true, x, y, 0
    fs:SetText(text)
    fs:SetTextColor(r, g, b)
    fs:SetPoint("CENTER", S.frame, "BOTTOMLEFT", x, y)
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
                fs:SetPoint("CENTER", S.frame, "BOTTOMLEFT", fs.x, fs.y + fs.t * 28)
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
        g = CreateFrame("Frame", nil, S.frame)
        g:SetSize(62, 62)
        g:SetFrameLevel(S.frame:GetFrameLevel() + 30)
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
    g:SetPoint("CENTER", S.frame, "BOTTOMLEFT", from[1], from[2])
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
                g:SetPoint("CENTER", S.frame, "BOTTOMLEFT", g.from[1] / scale, (g.from[2] - 20 * p) / scale)
            else
                local k = p < 0.5 and p * 2 or (1 - p) * 2
                k = k * k * (3 - 2 * k) * 0.85
                g:SetPoint("CENTER", S.frame, "BOTTOMLEFT", g.from[1] + (g.to[1] - g.from[1]) * k,
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
        g = CardWidget:CreateGame(S.frame)
        g:EnableMouse(false)
        g:SetFrameLevel(S.frame:GetFrameLevel() + 40)
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
            g:SetPoint("CENTER", S.frame, "BOTTOMLEFT", (g.from[1] + (g.to[1] - g.from[1]) * k) / scale,
                (g.from[2] + (g.to[2] - g.from[2]) * k) / scale)
            g:SetAlpha(p < 0.75 and 1 or (1 - p) * 4)
            if p >= 1 then
                g.active = false
                g:Hide()
            end
        end
    end
end

-- The targeting arrow: a chain of chevrons marching from the card or minion being used to the cursor, an
-- arrowhead at the cursor, red when the cursor is over a legal target (Textures/arrow_segment, arrow_head).
local function buildArrow(f)
    S.arrow = CreateFrame("Frame", nil, f)
    S.arrow:SetAllPoints()
    S.arrow:SetFrameLevel(f:GetFrameLevel() + 45)
    S.arrow.dots = {}
    for i = 1, 14 do
        local t = S.arrow:CreateTexture(nil, "OVERLAY")
        t:SetTexture(Art:Tex("arrow_segment"))
        S.arrow.dots[i] = t
    end
    S.arrow.head = S.arrow:CreateTexture(nil, "OVERLAY", nil, 2)
    S.arrow.head:SetTexture(Art:Tex("arrow_head"))
    S.arrow.head:SetSize(44, 44)
    S.arrow:Hide()
end

local function frameXY(w)
    local x, y = w:GetCenter()
    if not x then return nil end
    local ws = w:GetEffectiveScale() / S.frame:GetEffectiveScale()
    return x * ws - S.frame:GetLeft(), y * ws - S.frame:GetBottom()
end

local function updateArrow()
    if not S.arrow then return end
    local src = S.sel and S.sel.step == "target" and (S.sel.source and widgets[S.sel.source] or (S.sel.power and S.frame.powers[0]))
    if not src or not src:IsShown() then
        S.arrow:Hide()
        return
    end
    local sx, sy = frameXY(src)
    if not sx then S.arrow:Hide() return end
    local scale = S.frame:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale - S.frame:GetLeft(), cy / scale - S.frame:GetBottom()
    local dx, dy = cx - sx, cy - sy
    local valid = false
    if Board.hover then
        for _, x in ipairs(S.sel.list) do
            if x.move.raw.target == Board.hover then valid = true break end
        end
    end
    local r, g, b = 1, 0.8, 0.2
    if valid then r, g, b = 1, 0.25, 0.15 end
    local n = #S.arrow.dots
    local phase = (GetTime() * 1.6) % 1
    local angle = math.atan2(dy, dx) - math.pi / 2
    -- Stop short of the head so the last chevron doesn't sit under it.
    local len = math.sqrt(dx * dx + dy * dy)
    local reach = len > 0 and math.max(0, (len - 18) / len) or 0
    for i, t in ipairs(S.arrow.dots) do
        local k = (i - 1 + phase) / n
        local size = 12 + 14 * k
        t:SetSize(size, size)
        t:ClearAllPoints()
        t:SetPoint("CENTER", S.arrow, "BOTTOMLEFT", sx + dx * k * reach, sy + dy * k * reach)
        t:SetRotation(angle)
        t:SetVertexColor(r, g, b, 0.45 + 0.55 * k)
    end
    S.arrow.head:ClearAllPoints()
    S.arrow.head:SetPoint("CENTER", S.arrow, "BOTTOMLEFT", cx, cy)
    S.arrow.head:SetVertexColor(r, g, b)
    S.arrow.head:SetRotation(angle)
    S.arrow:Show()
end

-- Gliding: widgets ease to their new places (the hand closing up after a play, the row closing up after
-- a death, a hovered card lifting) instead of jumping. Widgets are per slot, so each remembers where its
-- card/minion was drawn last and starts from there when the slot now shows that entity.
local gliders = {}
local lastHand, lastBoard = {}, {}

local function placeHand(w, x, y)
    w:SetPoint("BOTTOMLEFT", S.frame.hand, "BOTTOM", x, y)
end
local function placeBoard(w, x, y)
    w:SetPoint("TOPLEFT", S.frame, "TOP", x, y)
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

-- A big copy of the card beside a hovered minion or weapon, with the tooltip beside it.
local function showZoom(owner, cardId)
    if not S.zoom then
        S.zoom = CardWidget:CreateGame(S.frame)
        S.zoom:EnableMouse(false)
        S.zoom:SetScale(1.45)
        S.zoom:SetFrameLevel(S.frame:GetFrameLevel() + 48)
    end
    S.zoom.costNow = nil
    S.zoom:SetCard(cardId)
    S.zoom:ClearAllPoints()
    local x = owner:GetCenter()
    local right = x and S.frame:GetCenter() and x < S.frame:GetCenter()
    -- Offsets are in the zoom's own (scaled) units.
    if right then
        S.zoom:SetPoint("LEFT", owner, "RIGHT", 12 / 1.45, 0)
    else
        S.zoom:SetPoint("RIGHT", owner, "LEFT", -12 / 1.45, 0)
    end
    S.zoom:Show()
    return S.zoom, right
end

local function hideZoom()
    if S.zoom then S.zoom:Hide() end
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
    if S.arrow then S.arrow:Hide() end
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
    local left, bottom = S.frame:GetLeft(), S.frame:GetBottom()
    if not left then return out end
    local scale = S.frame:GetEffectiveScale()
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

-- Shared with the other board files.
P.FLY = FLY
P.addFlash = addFlash
P.buildArrow = buildArrow
P.fadeIn = fadeIn
P.fading = fading
P.finishEffects = finishEffects
P.flash = flash
P.floatText = floatText
P.flyCard = flyCard
P.frameXY = frameXY
P.glideTo = glideTo
P.gliders = gliders
P.hideZoom = hideZoom
P.lastBoard = lastBoard
P.lastHand = lastHand
P.lunge = lunge
P.placeBoard = placeBoard
P.placeHand = placeHand
P.positions = positions
P.showZoom = showZoom
P.updateArrow = updateArrow
P.updateEffects = updateEffects
P.updateFloats = updateFloats
P.updateFlyers = updateFlyers
P.updateGhosts = updateGhosts
P.updateGliders = updateGliders
