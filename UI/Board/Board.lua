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
-- The table is the one thing on screen while it's open: as large as the screen allows (a little margin),
-- centred. Recomputed on open and when the screen or UI scale changes.
function Board:FitScreen()
    local f = S.frame
    if not f or not UIParent then return end
    local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
    if not sw or sw <= 0 or not sh or sh <= 0 then return end
    f:SetScale(math.max(0.6, math.min(sw * 0.97 / W, sh * 0.95 / H)))
    f:ClearAllPoints()
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
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
