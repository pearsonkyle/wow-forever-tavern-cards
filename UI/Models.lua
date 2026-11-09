-- 3D models for the board: creatures for minions (Data/Models.lua), your own character and the house's
-- innkeeper for heroes. A PlayerModel forgets its camera when the model (re)loads, shows or resizes, so
-- the camera wanted is remembered and put back each time. A creature this client has no model for is
-- remembered as missing and the caller's fallback (the card's icon) shows instead.
--   local m = TC.Models:Create(parent)
--   TC.Models:Show(m, "npc", 448, zoom, distance, facing, onFail)    TC.Models:Show(m, "unit", "player")
--   TC.Models:Animate(m, "attack" | "hit" | "cast")

local TC = TavernCards_NS

local Models = {}
TC.Models = Models

local missing = {}   -- creature ids without a model in this client (this session)
local ANIM = { attack = { 16, 17, 18 }, hit = { 9, 8, 10 }, cast = { 52, 2 }, stand = { 0 } }

function Models:Enabled()
    return not (TC.db and TC.db.settings and TC.db.settings.noModels)
end

-- How much of the card's art shows behind its 3D creature: none, unless the player asked for it.
function Models:ArtAlpha(full)
    return (TC.db and TC.db.settings and TC.db.settings.artBehindModels) and (full or 0.3) or 0
end

local function applyCam(m)
    if not m.camZoom then return end
    if m.RefreshCamera then pcall(m.RefreshCamera, m) end
    pcall(m.SetPortraitZoom, m, m.camZoom)
    pcall(m.SetCamDistanceScale, m, m.camDist or 1)
    if m.camFacing then pcall(m.SetFacing, m, m.camFacing) end
end

function Models:Create(parent)
    local m = CreateFrame("PlayerModel", nil, parent)
    m:EnableMouse(false)
    pcall(m.HookScript, m, "OnModelLoaded", applyCam)
    pcall(m.HookScript, m, "OnSizeChanged", applyCam)
    pcall(m.HookScript, m, "OnShow", function(self)
        if self.pending then
            self.pending = nil
            Models:Load(self)
        else
            applyCam(self)
        end
    end)
    m:Hide()
    return m
end

function Models:Load(m)
    if m.ClearModel then pcall(m.ClearModel, m) end
    if m.kind == "unit" then
        pcall(m.SetUnit, m, m.id)
    else
        pcall(m.SetCreature, m, m.id)
    end
    m.loaded = true
    applyCam(m)
    local token = (m.token or 0) + 1
    m.token = token
    -- The client loads the model a moment later and may reset the camera then.
    for _, d in ipairs({ 0, 0.15, 0.5 }) do
        C_Timer.After(d, function() if m.token == token then applyCam(m) end end)
    end
    -- No model after a second: this client doesn't have the creature.
    C_Timer.After(1.2, function()
        if m.token ~= token or not m.GetModelFileID then return end
        local ok, fid = pcall(m.GetModelFileID, m)
        if ok and (not fid or fid == 0) then
            -- Hidden (the board closed, a page turned) before the model arrived: that proves nothing,
            -- so load it again the next time it shows rather than calling the creature missing.
            if not m:IsVisible() then
                m.loaded, m.pending = false, true
                return
            end
            if m.kind == "npc" and m.id then missing[m.id] = true end
            m.loaded, m.id = false, nil
            m:Hide()
            if m.onFail then TC:Safe("model fallback", m.onFail) end
        end
    end)
end

-- Shows a creature ("npc", id) or a unit ("unit", token). The same subject again only gets its camera
-- back (reloading on every board refresh would make it flicker). Returns false when it can't show.
function Models:Show(m, kind, id, zoom, dist, facing, onFail)
    if not self:Enabled() or not id or (kind == "npc" and missing[id]) then
        m:Hide()
        return false
    end
    m.camZoom, m.camDist, m.camFacing, m.onFail = zoom or 0.7, dist or 1, facing, onFail
    if m.kind == kind and m.id == id and m.loaded then
        m:Show()
        applyCam(m)
        return true
    end
    m.kind, m.id, m.pending = kind, id, nil
    m:Show()
    if not m:IsVisible() then
        m.pending = true   -- loads when the board shows
        return true
    end
    self:Load(m)
    return true
end

function Models:Hide(m)
    if m then
        m:Hide()
        m.id, m.loaded = nil, false
        m.token = (m.token or 0) + 1   -- cancels a pending load check
    end
end

-- Plays an animation once (attack, hit, cast), then back to standing.
function Models:Animate(m, what)
    if not m or not m:IsShown() or not m.loaded then return end
    for _, anim in ipairs(ANIM[what] or {}) do
        if not m.HasAnimation or m:HasAnimation(anim) then
            pcall(m.SetAnimation, m, anim)
            break
        end
    end
    local token = (m.animToken or 0) + 1
    m.animToken = token
    C_Timer.After(1.1, function()
        if m.animToken == token and m:IsShown() then pcall(m.SetAnimation, m, 0) end
    end)
end
