-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
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

local widgets = {}   -- entity id -> widget, rebuilt every refresh
-- Shared by the UI/Board/*.lua files: P holds their functions and constants, S the board's
-- mutable state (frame: the board; moves: legal moves for the player's current decision;
-- sel: the half-made move, { list = {{index, move}...}, step, source }; arrow; zoom).
local P, S = {}, { moves = {} }
Board._P, Board._S = P, S

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
-- The table's size and place. Until the player moves or sizes it, it fills the screen (a little margin), centred.
-- Dragging its background moves it, the corner grip and Options size it, and both are kept in
-- TavernCardsDB.settings (tableScale, tableX/tableY: its centre in UIParent units). Never larger than the screen.
TC.TABLE_SCALES = { 0.5, 0.6, 0.7, 0.8, 0.9, 1, 1.1, 1.25, 1.4, 1.6 }
local MIN_TABLE_SCALE = 0.4

function Board:FitScale()
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or sw <= 0 or not sh or sh <= 0 then return 1 end
    return math.max(0.6, math.min(sw * 0.97 / W, sh * 0.95 / H))
end

-- The scale in use: the player's, clamped to what fits, else the fitted one.
function Board:TableScale()
    local s = TC.db and TC.db.settings or {}
    local fit = self:FitScale()
    if type(s.tableScale) == "number" then return math.max(MIN_TABLE_SCALE, math.min(fit, s.tableScale)), false end
    return fit, true
end

function Board:FitScreen()
    local f = S.frame
    if not f or not UIParent then return end
    local scale = self:TableScale()
    f:SetScale(scale)
    f:ClearAllPoints()
    local s = TC.db and TC.db.settings or {}
    if type(s.tableX) == "number" and type(s.tableY) == "number" then
        -- SetPoint offsets are in the table's own (scaled) units.
        f:SetPoint("CENTER", UIParent, "BOTTOMLEFT", s.tableX / scale, s.tableY / scale)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- Keeps where the table is now (after a drag or a resize).
function Board:SavePlacement()
    local f = S.frame
    if not f or not TC.db then return end
    local x, y = f:GetCenter()
    if not x then return end
    local scale = f:GetScale()
    TC.db.settings.tableX, TC.db.settings.tableY = x * scale, y * scale
    if f.SetUserPlaced then f:SetUserPlaced(false) end   -- ours to keep, not the client's layout cache
end

function Board:SetTableScale(scale)
    if TC.db then TC.db.settings.tableScale = scale end
    self:FitScreen()
end

-- Back to filling the screen, centred.
function Board:ResetPlacement()
    if TC.db then
        local s = TC.db.settings
        s.tableScale, s.tableX, s.tableY = nil, nil, nil
    end
    self:FitScreen()
end

function Board:Open()
    if not S.frame then P.build() end
    self:FitScreen()
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
    if not S.frame:IsShown() then
        S.frame.log:Clear()
        local record = Match:Record()
        for _, line in ipairs(record and record.log or {}) do S.frame.log:AddMessage(line) end
    end
    S.frame:Show()
    self:Refresh()
end

function Board:Close()
    if S.frame then S.frame:Hide() end
end

-- The step of the half-made move ("choice", "position", "target"), or nil.
function Board:Selecting()
    return S.sel and S.sel.step
end

function Board:IsShown()
    return S.frame and S.frame:IsShown()
end

-- Combat: the table folds away and comes back after.
TC:On("PLAYER_REGEN_DISABLED", function()
    if S.frame and S.frame:IsShown() then
        S.frame.reopen = true
        S.frame:Hide()
    end
end)
TC:On("PLAYER_REGEN_ENABLED", function()
    if S.frame and S.frame.reopen then
        S.frame.reopen = nil
        if Match:Engine() then Board:Open() end
    end
end)

-- Shared with the other board files.
P.H = H
P.HAND_SCALE = HAND_SCALE
P.HUGE_FONT = HUGE_FONT
P.KEYWORD_LABELS = KEYWORD_LABELS
P.ME = ME
P.OPP = OPP
P.POWER_ICONS = POWER_ICONS
P.SLOT_GAP = SLOT_GAP
P.SLOT_H = SLOT_H
P.SLOT_W = SLOT_W
P.W = W
P.engine = engine
P.gem = gem
P.sideOf = sideOf
P.widgets = widgets
TC:On("DISPLAY_SIZE_CHANGED", function() Board:FitScreen() end)
TC:On("UI_SCALE_CHANGED", function() Board:FitScreen() end)
