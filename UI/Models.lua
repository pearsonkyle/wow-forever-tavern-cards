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
-- Animation ids of the game (the first one a model has is played).
local ANIM = { attack = { 17, 18, 16 }, hit = { 9, 8, 10 }, cast = { 52, 2 }, stand = { 0 },
               block = { 24, 21, 22, 20, 36 },     -- shield block, parry (1H, 2H, unarmed), block
               ready = { 26, 27, 25, 29 },         -- combat-ready stance (1H, 2H, unarmed, bow)
               roar = { 53, 55 } }                 -- battle roar

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
    pcall(m.SetFacing, m, m.camFacing or 0)   -- reset too: a reused frame mustn't keep the last card's turn
end

function Models:Create(parent)
    -- A dress-up model when the client has one: it can hold items (weapons) as well as show creatures.
    local ok, m = pcall(CreateFrame, "DressUpModel", nil, parent)
    if not ok or not m then m = CreateFrame("PlayerModel", nil, parent) end
    m:EnableMouse(false)
    pcall(m.HookScript, m, "OnModelLoaded", function(self) applyCam(self) Models:Arm(self) end)
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
    elseif m.kind == "display" then
        pcall(m.SetDisplayInfo, m, m.id)   -- a model the client has, of a creature it doesn't know
    elseif m.kind == "item" then
        -- An item (a weapon): by item when the frame can, else its model file.
        if not (m.SetItem and pcall(m.SetItem, m, m.id)) and m.file then pcall(m.SetModel, m, m.file) end
    elseif m.kind == "file" then
        pcall(m.SetModel, m, m.id)   -- an object (a prop) by its model file
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
    C_Timer.After(0.6, function() if m.token == token then Models:Arm(m) end end)
    -- No model after a second: this client doesn't have the creature.
    C_Timer.After(1.2, function()
        if m.token ~= token or not m.GetModelFileID then return end
        local ok, fid = pcall(m.GetModelFileID, m)
        if ok and (not fid or fid == 0) and m.kind == "item" and m.file and not m.triedFile then
            m.triedFile = true   -- SetItem showed nothing: the item's model file instead
            pcall(m.SetModel, m, m.file)
            return
        end
        if ok and (not fid or fid == 0) then
            -- Hidden (the board closed, a page turned) before the model arrived: that proves nothing,
            -- so load it again the next time it shows rather than calling the creature missing.
            if not m:IsVisible() then
                m.loaded, m.pending = false, true
                return
            end
            if m.kind ~= "npc" and m.kind ~= "unit" and m.id then missing[m.kind .. m.id] = true end
            if m.kind == "npc" and m.id then
                missing[m.id] = true
                -- Remembered for tools/picker (it flags creatures this client can't show).
                if TC.db then
                    TC.db.missingModels = TC.db.missingModels or {}
                    TC.db.missingModels[m.id] = true
                end
            end
            m.loaded, m.id = false, nil
            m:Hide()
            if m.onFail then TC:Safe("model fallback", m.onFail) end
        end
    end)
end

-- Shows a creature ("npc", id), a creature model ("display", display id), a unit ("unit", token), an item
-- ("item", item id; `file` its model file as a fallback) or an object ("file", model file). The same subject again only gets its camera
-- back (reloading on every board refresh would make it flicker). Returns false when it can't show.
function Models:Show(m, kind, id, zoom, dist, facing, onFail, file)
    if not self:Enabled() or not id or (kind == "npc" and missing[id]) or (kind ~= "npc" and missing[kind .. id]) then
        m:Hide()
        return false
    end
    m.camZoom, m.camDist, m.camFacing, m.onFail = zoom or 0.7, dist or 1, facing, onFail
    if m.kind == kind and m.id == id and m.loaded then
        m:Show()
        applyCam(m)
        return true
    end
    m.kind, m.id, m.pending, m.file, m.triedFile = kind, id, nil, file, nil
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

-- Puts the model's weapons (m.weapons = {main hand item, off hand item}) in its hands: works on character-style
-- models in a dress-up frame; anything else quietly keeps its own look.
function Models:Arm(m)
    if not m or not m.weapons or not m.TryOn then return end
    for _, item in ipairs(m.weapons) do
        if item and item > 0 then
            if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, item) end
            pcall(m.TryOn, m, "item:" .. item)
        end
    end
end

-- Holds a looping stance ("ready") until called again without one (back to standing).
function Models:Stance(m, what)
    if not m or not m:IsShown() or not m.loaded or m.stance == what then return end
    m.stance = what
    m.animToken = (m.animToken or 0) + 1
    local list = what and ANIM[what] or ANIM.stand
    for _, anim in ipairs(list) do
        if not m.HasAnimation or m:HasAnimation(anim) then
            pcall(m.SetAnimation, m, anim)
            return
        end
    end
end

-- Plays an animation once (attack, hit, cast, block, roar), then back to standing (or its stance).
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
        if m.animToken == token and m:IsShown() then
            local back = m.stance and ANIM[m.stance] or ANIM.stand
            for _, anim in ipairs(back) do
                if not m.HasAnimation or m:HasAnimation(anim) then pcall(m.SetAnimation, m, anim) break end
            end
        end
    end)
end
