-- The match controller (UI/Match.lua) headless: the AI thinks over "frames", a whole game finishes,
-- and a saved match rebuilds to the same state by replaying its moves.
local T = {}

local clock = 0
local function setup(TC)
    clock = 0
    time = os.time
    date = os.date
    GetTime = function() return clock end
    debugprofilestop = function() return os.clock() * 1000 end
    geterrorhandler = function() return error end
    UIErrorsFrame = { AddMessage = function() end }
    local scripts = {}
    CreateFrame = function()
        return { SetScript = function(_, name, fn) scripts[name] = fn end }
    end
    TC.On = function() end
    TC.Print = function() end
    TC.ReportError = function(_, where, err) error(where .. ": " .. tostring(err)) end
    TC.Safe = function(_, _, fn, ...) fn(...) return true end
    TC.db = { collection = {}, dust = 0, ledger = {}, decks = {} }
    TC.char = { granted = {} }
    dofile("Collection/Collection.lua")
    dofile("Collection/Decks.lua")
    dofile("UI/Match.lua")
    T.bad_ai_move_falls_back = function(TC)
    local Match, tick = setup(TC)
    local real = TC.AI.choose
    local broken = 0
    TC.AI.choose = function(engine, ...)
        if engine:current_player() == 1 and broken < 3 and engine.state.phase == TC.EngineDefs.PHASE.PLAYER_ACTIONS then
            broken = broken + 1
            return 9999  -- a move that doesn't exist
        end
        return real(engine, ...)
    end
    assert(Match:StartPractice(houseDeck(TC, "MAGE", 2), { name = "Test", class = "DRUID", profile = "novice" }))
    playOut(TC, Match, tick, 20000)
    TC.AI.choose = real
    assert(broken == 3 and Match:Engine():is_terminal(), "the opponent should play on after a refused move")
end

return TC.Match, function()
        clock = clock + 0.1
        scripts.OnUpdate()
    end
end

local function houseDeck(TC, class, seed)
    local cards = TC.AI.buildDeck(class, seed, 1)
    local deck = { id = 1, class = class, name = "Test", cards = {} }
    for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
    return deck
end

local function snapshot(engine)
    local s = engine.state
    local parts = { s.v, s.turn, s.active, s.next_entity_id }
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        parts[#parts + 1] = table.concat({ e.card_id, e.zone, e.zone_pos, e.attack, e.health }, ":")
    end
    return table.concat(parts, "|")
end

-- Plays the player's seat with the AI too, ticking frames while the opponent thinks.
local function playOut(TC, Match, tick, limit, stopAt)
    local rng = TC.Rng.new(99)
    for _ = 1, limit do
        local engine = Match:Engine()
        if engine:is_terminal() then return end
        if stopAt and #TC.char.match.moves >= stopAt then return end
        if engine:current_player() == 0 and not Match.thinking then
            local index = TC.AI.choose(engine, "novice", rng)
            assert(Match:PlayerApply(index), "player move rejected: " .. tostring(engine.last_error))
        else
            assert(not Match:PlayerApply(1), "player moved on the opponent's turn")
            tick()
        end
    end
end

T.full_game_against_ai = function(TC)
    local Match, tick = setup(TC)
    local seen = {}
    Match:Subscribe(function(what) seen[what] = (seen[what] or 0) + 1 end)
    assert(Match:StartPractice(houseDeck(TC, "MAGE", 5), { name = "Test", class = "WARRIOR", profile = "novice" }))
    playOut(TC, Match, tick, 20000)
    assert(Match:Engine():is_terminal(), "the game should finish")
    assert(Match.result == "win" or Match.result == "loss" or Match.result == "draw")
    assert(TC.char.match == nil and TC.char.lastMatch.result == Match.result)
    assert(TC.db.stats.played == 1)
    assert(seen["end"] == 1 and (seen.move or 0) > 10)
end

T.resume_replays_to_same_state = function(TC)
    local Match, tick = setup(TC)
    assert(Match:StartPractice(houseDeck(TC, "PRIEST", 8), { name = "Test", class = "ROGUE", profile = "novice" }))
    playOut(TC, Match, tick, 20000, 12)
    -- Let the opponent finish any thinking, then rebuild from the record as a /reload would.
    while Match.thinking do tick() end
    assert(TC.char.match, ("match ended early: %s %s after %d"):format(tostring(Match.result), tostring(Match.reason),
        Match:Engine().state.turn))
    local before = snapshot(Match:Engine())
    Match.engine = nil
    assert(Match:Load())
    assert(snapshot(Match:Engine()) == before, "replayed match differs")
end

T.concede_on_opponents_turn = function(TC)
    local Match, tick = setup(TC)
    assert(Match:StartPractice(houseDeck(TC, "HUNTER", 3), { name = "Test", class = "MAGE", profile = "novice" }))
    for _ = 1, 2000 do
        local e = Match:Engine()
        if e:current_player() == 1 then break end
        assert(Match:PlayerApply(TC.AI.choose(e, "novice", TC.Rng.new(1))))
    end
    Match:Concede()
    assert(Match.result == "loss" and TC.char.match == nil and not Match.thinking)
end

T.bad_ai_move_falls_back = function(TC)
    local Match, tick = setup(TC)
    local real = TC.AI.choose
    local broken = 0
    TC.AI.choose = function(engine, ...)
        if engine:current_player() == 1 and broken < 3 and engine.state.phase == TC.EngineDefs.PHASE.PLAYER_ACTIONS then
            broken = broken + 1
            return 9999  -- a move that doesn't exist
        end
        return real(engine, ...)
    end
    assert(Match:StartPractice(houseDeck(TC, "MAGE", 2), { name = "Test", class = "DRUID", profile = "novice" }))
    playOut(TC, Match, tick, 20000)
    TC.AI.choose = real
    assert(broken == 3 and Match:Engine():is_terminal(), "the opponent should play on after a refused move")
end

return T
