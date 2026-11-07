-- Smoke test for the board (UI/Board.lua) and the Play tab against a permissive frame mock: whole
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
    for _, file in ipairs({ "Collection/Collection.lua", "Collection/Decks.lua", "UI/Art.lua", "UI/CardWidget.lua",
        "UI/Match.lua", "UI/Board.lua", "UI/PlayPanel.lua" }) do
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

return T
