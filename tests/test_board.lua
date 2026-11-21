-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Smoke test for the board (UI/Board/*.lua) and the Play tab against a permissive frame mock: whole
-- games are played by "clicking" (hand cards, gaps, targets, choices, End Turn), so every
-- interaction path runs against real engine states. It checks the Lua logic, not the layout.
local T = {}

local scriptsOf = setmetatable({}, { __mode = "k" })
local mock
local METHODS = {
    GetWidth = function() return 100 end, GetHeight = function() return 100 end,
    GetLeft = function() return 0 end, GetBottom = function() return 0 end,
    GetCenter = function() return 50, 50 end, GetEffectiveScale = function() return 1 end,
    GetFrameLevel = function() return 1 end,
    IsShown = function(self) return rawget(self, "_shown") ~= false end,
    IsVisible = function(self) return rawget(self, "_shown") ~= false end,
    Show = function(self)
        local was = rawget(self, "_shown") ~= false
        rawset(self, "_shown", true)
        local s = scriptsOf[self]
        if not was and s and s.OnShow then s.OnShow(self) end
    end,
    Hide = function(self)
        local was = rawget(self, "_shown") ~= false
        rawset(self, "_shown", false)
        local s = scriptsOf[self]
        if was and s and s.OnHide then s.OnHide(self) end
    end,
    SetShown = function(self, on) if on then self:Show() else self:Hide() end end,
    SetScript = function(self, name, fn)
        scriptsOf[self] = scriptsOf[self] or {}
        scriptsOf[self][name] = fn
    end,
    GetHighlightTexture = function() return mock() end,
}
mock = function(name)
    local o = setmetatable({}, { __index = function(_, k)
        if METHODS[k] then return METHODS[k] end
        if type(k) == "string" and k:match("^Create") then return function() return mock() end end
        if type(k) == "string" and k:match("^%u") then return function() end end
        return nil
    end })
    if name then _G[name] = o end
    return o
end

local function click(f, button)
    scriptsOf[f].OnClick(f, button or "LeftButton")
end

local clock = 0
local function setup(TC)
    clock = 0
    time = os.time
    date = os.date
    GetTime = function() return clock end
    debugprofilestop = function() return os.clock() * 1000 end
    geterrorhandler = function() return error end
    UIErrorsFrame = { AddMessage = function() end }
    local driver
    CreateFrame = function(_, name)
        local f = mock(name)
        if not driver then driver = f end
        return f
    end
    UIParent, GameTooltip = mock(), mock()
    UISpecialFrames = {}
    CreateColor = function() return {} end
    UnitName = function() return "Tester" end
    UnitClass = function() return "Mage", "MAGE" end
    InCombatLockdown = function() return false end
    wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    tinsert = table.insert
    unpack = unpack or table.unpack
    GameFontHighlightSmall = {}
    TC.On = function() end
    TC.Print = function() end
    TC.ReportError = function(_, where, err) error(where .. ": " .. tostring(err)) end
    TC.Safe = function(_, _, fn, ...) fn(...) return true end
    TC.Confirm = function(_, _, yes) yes() end
    TC.CardTooltip = function() end
    TC.PageSize = function() return 400, 470 end
    TC.BookPages = function() return {} end
    TC.BookLayout = function() return { top = -72, left = 46, right = 436, width = 316 } end
    TC.ShowWindow = function() end
    local panels = {}
    TC.RegisterPanel = function(_, key, _, builder) panels[key] = builder end
    TC.Compat = { HasAtlas = function() return false end }
    TC.Presence = { Online = function() return {} end, Subscribe = function() end, AskWho = function() end }
    TC.Channel = { Number = function() return nil end }
    TC.Duel = { Subscribe = function() end, Pending = function() return nil end, Cancel = function() end, FullName = function(n) return n end }
    C_Timer = { After = function() end }
    TC.db = { collection = {}, dust = 0, ledger = {}, decks = {}, settings = { mute = true } }
    TC.char = { granted = {} }
    for _, file in ipairs({ "Collection/Collection.lua", "Collection/Decks.lua", "UI/Art.lua", "UI/CardWidget.lua", "UI/CardBacks.lua", "UI/Models.lua",
        "UI/Match.lua", "UI/Board/Board.lua", "UI/Board/Widgets.lua", "UI/Board/Effects.lua",
        "UI/Board/Layout.lua", "UI/Board/Controller.lua", "UI/Board/Table.lua", "UI/PlayPanel.lua" }) do
        dofile(file)
    end
    return TC.Match, TC.Board, function()
        clock = clock + 0.1
        scriptsOf[driver].OnUpdate()
    end, panels
end

-- One "click" toward a move: whatever the board is asking for, pick the first thing offered.
local function finishSelection(TC, Board, board, steps)
    for _ = 1, steps do
        local choice = board.choice
        if rawget(choice, "_shown") ~= false then
            for _, b in ipairs(choice.buttons) do
                if rawget(b, "_shown") ~= false and scriptsOf[b] and scriptsOf[b].OnClick then
                    click(b)
                    return true
                end
            end
            for _, w in ipairs(choice.cards) do
                if rawget(w, "_shown") ~= false and w.onClick then
                    w.onClick(w, "LeftButton")
                    if rawget(choice.confirm, "_shown") ~= false then click(choice.confirm) end
                    return true
                end
            end
            if rawget(choice.confirm, "_shown") ~= false then
                click(choice.confirm)
                return true
            end
        end
        local gapClicked = false
        for _, g in ipairs(board.gaps) do
            if rawget(g, "_shown") ~= false then
                Board:ClickGap(g.position)
                gapClicked = true
                break
            end
        end
        if not gapClicked and Board:Selecting() == "target" then
            -- A target: any entity whose glow is on and red is fine; the board accepts only legal ones.
            local eng = TC.Match:Engine()
            local hit = false
            for id = 1, eng.state.next_entity_id - 1 do
                local before = TC.Match:Record() and #TC.Match:Record().moves
                Board:ClickEntity(id)
                local after = TC.Match:Record() and #TC.Match:Record().moves
                if before ~= after or not TC.Match:Active() then hit = true break end
            end
            return hit
        end
        return gapClicked
    end
    return true
end

local function playByClicks(TC, Match, Board, tick, maxSteps)
    local board = _G.TavernCardsBoard
    local plays, attacks = 0, 0
    for _ = 1, maxSteps do
        local eng = Match:Engine()
        if eng:is_terminal() then break end
        if eng:current_player() ~= 0 or Match.thinking then
            tick()
        elseif rawget(board.choice, "_shown") ~= false then
            finishSelection(TC, Board, board, 1)
        else
            local moved = false
            local count = #Match:Record().moves
            -- Try each hand card, then each minion/hero, then End Turn.
            for _, id in ipairs(eng:hand_ids(0)) do
                Board:ClickHand(id, mock())
                for _ = 1, 4 do
                    if not Match:Record() or #Match:Record().moves ~= count then break end
                    finishSelection(TC, Board, board, 1)
                end
                Board:Cancel()
                if not Match:Record() or #Match:Record().moves ~= count then moved = true plays = plays + 1 break end
            end
            if not moved then
                local ids = eng:board_ids(0)
                ids[#ids + 1] = eng:hero_of(0).id
                for _, id in ipairs(ids) do
                    Board:ClickEntity(id)
                    finishSelection(TC, Board, board, 1)
                    Board:Cancel()
                    if not Match:Record() or #Match:Record().moves ~= count then moved = true attacks = attacks + 1 break end
                end
            end
            if not moved then
                Board:ClickEndTurn()
            end
        end
    end
    return plays, attacks
end

T.board_plays_whole_games_by_clicks = function(TC)
    local Match, Board, tick, panels = setup(TC)
    local panel = panels.play(mock())
    panel:Open("house:MAGE")
    panel:Refresh()
    local totalPlays, totalAttacks = 0, 0
    for game = 1, 3 do
        local class = ({ "DRUID", "PALADIN", "HUNTER" })[game]
        local cards = TC.AI.buildDeck(class, game * 11, 3)
        local deck = { id = 1, class = class, name = "Test", cards = {} }
        for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
        assert(Match:StartPractice(deck, { name = "Test", class = "WARLOCK", profile = "novice" }))
        Board:Open()
        local plays, attacks = playByClicks(TC, Match, Board, tick, 30000)
        totalPlays, totalAttacks = totalPlays + plays, totalAttacks + attacks
        assert(Match:Engine():is_terminal(), "game " .. game .. " should finish")
        panel:Refresh()
    end
    assert(totalPlays > 10 and totalAttacks > 3, ("plays %d attacks %d"):format(totalPlays, totalAttacks))
    assert(TC.db.stats.played == 3)
end

-- The house's innkeeper is one steady face for the whole match: across a reload (the match replayed from
-- its record), closing and reopening the table, and the result screen after the match ends.
T.board_opponent_face_is_steady = function(TC)
    local Match, Board, tick = setup(TC)
    TC.HouseModels = { 1001, 1002, 1003, 1004, 1005 }
    local shown = {}
    local realShow = TC.Models.Show
    TC.Models.Show = function(self, m, kind, id, ...)
        if kind == "npc" and id and id > 1000 and id < 1010 then shown[#shown + 1] = id end
        return realShow(self, m, kind, id, ...)
    end
    local cards = TC.AI.buildDeck("MAGE", 5, 3)
    local deck = { id = 1, class = "MAGE", name = "Test", cards = {} }
    for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
    for round = 1, 4 do
        wipe(shown)
        assert(Match:StartPractice(deck, { name = "Test", class = "WARLOCK", profile = "novice" }))
        local house = Match:HouseModel()
        assert(house, "the house has an innkeeper")
        Board:Open()
        for _ = 1, 3 do tick() end
        assert(Match:Load(), "resumes")          -- what a /reload does
        Board:Open()
        Board:Close()
        assert(not Board:IsShown())
        Board:Open()                              -- back to the table
        for _ = 1, 3 do tick() end
        Match:Concede()
        Board:Refresh()                           -- the result screen
        assert(#shown > 0)
        for _, id in ipairs(shown) do
            assert(id == house, ("round %d: innkeeper %d shown, %d expected"):format(round, id, house))
        end
        assert(Match:HouseModel() == house, "kept after the match")
    end
end

-- A model whose load check runs while it is hidden (the table closed) is not taken for a missing creature.
T.models_hidden_load_is_not_missing = function(TC)
    setup(TC)
    local timers = {}
    C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
    local parent = CreateFrame("Frame")
    local m = TC.Models:Create(parent)
    assert(TC.Models:Show(m, "npc", 4242, 0.8, 1))
    parent:Hide()
    m:Hide()                 -- hidden with its parent before the client had the model
    for _, fn in ipairs(timers) do fn() end
    assert(TC.Models:Show(m, "npc", 4242, 0.8, 1), "still worth showing")
    -- Visible and still nothing after the check: that creature is missing.
    local fns = { unpack(timers) }
    for _, fn in ipairs(fns) do fn() end
    assert(not TC.Models:Show(m, "npc", 4242, 0.8, 1), "missing once seen to fail")
end

-- A whole game for every class, the new cards included: every minion that reaches the board is shown as a model
-- (a creature, by id or model, or a prop), and every model asked for is a real kind and id.
T.every_class_plays_with_models_on_the_board = function(TC)
    local Match, Board, tick = setup(TC)
    local shown, onBoard = 0, {}
    local realShow = TC.Models.Show
    TC.Models.Show = function(self, m, kind, id, ...)
        assert(kind == "npc" or kind == "display" or kind == "item" or kind == "file", "model kind " .. tostring(kind))
        assert(type(id) == "number" and id > 0, "model id " .. tostring(id))
        shown = shown + 1
        return realShow(self, m, kind, id, ...)
    end
    local classes = { "DRUID", "HUNTER", "MAGE", "PALADIN", "PRIEST", "ROGUE", "SHAMAN", "WARLOCK", "WARRIOR",
        "DEMONHUNTER", "DEATHKNIGHT", "MAGE" }
    for game, class in ipairs(classes) do
        local cards = TC.AI.buildDeck(class, 100 + game * 7, 3)
        local deck = { id = 1, class = class, name = "Test", cards = {} }
        for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
        local foe = classes[(game % #classes) + 1]
        assert(Match:StartPractice(deck, { name = "Test", class = foe, profile = "novice" }))
        Board:Open()
        playByClicks(TC, Match, Board, function()
            tick()
            local eng = Match:Engine()
            for seat = 0, 1 do
                for _, id in ipairs(eng:board_ids(seat)) do
                    local e = eng:ent(id)
                    if TC.Cards[e.card_id] and TC.Cards[e.card_id].type == "MINION" then onBoard[e.card_id] = true end
                end
            end
        end, 30000)
        assert(Match:Engine():is_terminal(), class .. " game should finish")
    end
    TC.Models.Show = realShow
    local n = 0
    for id in pairs(onBoard) do
        n = n + 1
        assert(TC.CardModels[id] or TC.CardDisplays[id] or TC.CardProps[id], id .. " stood on the board with no model")
    end
    assert(n > 40 and shown > n, ("%d minions on the board, %d models shown"):format(n, shown))
end

-- Every ability a minion has shows as its own icon (Taunt first); a Silenced minion shows none.
T.minion_abilities_show_as_icons = function(TC)
    setup(TC)
    local P, KW = TC.Board._P, TC.EngineDefs.KW
    local b = P.minionWidget(mock())
    local e = { id = 7, card_id = "CS2_179", attack = 3, health = 5, max_health = 5, durability = 0,
        keywords = bit.bor(KW.TAUNT, KW.DEATHRATTLE),
        flags = { divine_shield = true, stealth = false, silenced = false, frozen = false, dormant_turns = 0 } }
    local function shown()
        local n = 0
        for _, f in ipairs(b.keywords) do if rawget(f, "_shown") then n = n + 1 end end
        return n
    end
    P.setMinion(b, e, { effects = {} })
    assert(shown() == 3, "taunt, divine shield and deathrattle: " .. shown())
    P.setMinion(b, e, { effects = { { trigger = "END_TURN", inHand = 0 } } })
    assert(shown() == 4, "an end-of-turn effect adds the trigger icon")
    P.setMinion(b, e, { effects = { { trigger = "BATTLECRY", inHand = 0 } } })
    assert(shown() == 3, "a Battlecry is no ongoing effect")
    e.flags.silenced = true
    P.setMinion(b, e, { effects = {} })
    assert(shown() == 0, "silenced: no abilities")
end

-- No sound the board plays can go on forever: each is stopped after a few seconds, and StopSounds ends them all.
T.sounds_always_end = function(TC)
    setup(TC)
    local timers, stopped, handle = {}, {}, 0
    C_Timer = { After = function(_, fn) timers[#timers + 1] = fn end }
    PlaySound = function() handle = handle + 1 return true, handle end
    StopSound = function(h) stopped[h] = true end
    SOUNDKIT = { IG_QUEST_LIST_SELECT = 1 }
    TC.db.settings.mute = false
    TC.Art:PlayKit(5001)
    TC.Art:PlayKit(5002)
    TC.Art:Play("IG_QUEST_LIST_SELECT")
    assert(#timers == 3, "every sound gets its stop timer")
    for _, fn in ipairs(timers) do fn() end
    assert(stopped[1] and stopped[2] and stopped[3], "each sound is stopped when its time is up")
    TC.Art:PlayKit(5003)
    TC.Art:StopSounds()
    assert(stopped[4], "StopSounds ends what is still playing")
end

-- A card that costs more than printed shows its cost in white (red read as "can't cast"); cheaper is green.
T.raised_cost_is_white = function(TC)
    setup(TC)
    local w = TC.CardWidget:Create(mock())
    local color
    rawset(w.cost.text, "SetTextColor", function(_, r, g, b2) color = { r, g, b2 } end)
    w.game, w.costNow = true, 9
    w:SetCard("CS2_029")   -- Fireball, printed (4)
    assert(color[1] == 1 and color[2] == 1 and color[3] == 1, "raised cost: white")
    w.costNow = 2
    w:SetCard("CS2_029")
    assert(color[1] < 1 and color[2] == 1, "lowered cost: green")
end

-- The table can be moved and sized like the other windows: what the player chose is kept, never larger than the
-- screen, and Fit to screen brings back the default.
T.table_moves_and_sizes = function(TC)
    setup(TC)
    local Board, S = TC.Board, TC.Board._S
    rawset(UIParent, "GetWidth", function() return 2000 end)
    rawset(UIParent, "GetHeight", function() return 1200 end)
    TC.Board._P.build()
    local f = S.frame
    local scale, points = 1, {}
    rawset(f, "SetScale", function(_, s) scale = s end)
    rawset(f, "GetScale", function() return scale end)
    rawset(f, "ClearAllPoints", function() points = {} end)
    rawset(f, "SetPoint", function(_, ...) points[#points + 1] = { ... } end)
    local fit = Board:FitScale()
    Board:FitScreen()
    assert(scale == fit and points[1][1] == "CENTER" and points[1][2] == UIParent, "default: fills the screen, centred")
    Board:SetTableScale(0.7)
    assert(math.abs(scale - 0.7) < 1e-9, "a chosen size is used")
    Board:SetTableScale(99)
    assert(scale == fit, "never larger than the screen")
    -- A drag: the centre in UIParent units is kept and survives a size change.
    rawset(f, "GetCenter", function() return 500 / scale, 400 / scale end)
    Board:SavePlacement()
    assert(math.abs(TC.db.settings.tableX - 500) < 1e-6 and math.abs(TC.db.settings.tableY - 400) < 1e-6)
    Board:SetTableScale(0.8)
    local p = points[1]
    assert(p[3] == "BOTTOMLEFT" and math.abs(p[4] * 0.8 - 500) < 1e-6 and math.abs(p[5] * 0.8 - 400) < 1e-6,
        "the table stays where it was put")
    Board:ResetPlacement()
    assert(scale == fit and points[1][1] == "CENTER" and TC.db.settings.tableScale == nil, "Fit to screen")
end

return T
