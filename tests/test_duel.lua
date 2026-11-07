-- Duels end to end, headless: two complete clients (each its own copy of the addon) wired together by a
-- fake addon-message transport with a virtual clock. They handshake (commit-reveal), then play whole
-- games in lockstep, each side's "player" choosing with the AI. Both must end in the same state.
local T = {}

local clock, timers, current
local function schedule(delay, fn)
    timers[#timers + 1] = { at = clock + delay, fn = fn, ctx = current }
end

-- Runs the timers in time order until none are left (or `limit` steps), switching client contexts.
local function run(limit)
    for _ = 1, limit or 100000 do
        if #timers == 0 then return end
        table.sort(timers, function(a, b) return a.at < b.at end)
        local t = table.remove(timers, 1)
        clock = math.max(clock, t.at)
        local prev = current
        current = t.ctx
        t.fn()
        current = prev
    end
end

local function stubGlobals()
    clock, timers = 1000, {}
    time = function() return 1700000000 + math.floor(clock) end
    date = os.date
    GetTime = function() return clock end
    debugprofilestop = function() return clock * 1000 end
    geterrorhandler = function() return error end
    UIErrorsFrame = { AddMessage = function() end }
    CreateFrame = function() return { SetScript = function() end, RegisterEvent = function() end } end
    C_Timer = { After = schedule }
    GetNormalizedRealmName = function() return "Realm" end
    IsInGroup = function() return false end
    IsInRaid = function() return false end
    InCombatLockdown = function() return false end
    Ambiguate = function(n) return n end
    UnitFullName = function() return current.name, "Realm" end
end

local function loadClient(name)
    TavernCards_NS = {}
    local toc = io.open("TavernCards.toc"):read("*a")
    for line in toc:gmatch("[^\r\n]+") do
        local path = line:match("^(Engine[\\/].-%.lua)%s*$") or line:match("^(Data[\\/].-%.lua)%s*$")
        if path then dofile((path:gsub("\\", "/"))) end
    end
    local TC = TavernCards_NS
    TC.On = function() end
    TC.Print = function(_, fmt, ...) TC.printed[#TC.printed + 1] = select("#", ...) > 0 and fmt:format(...) or fmt end
    TC.printed = {}
    TC.ReportError = function(_, where, err) error(where .. ": " .. tostring(err)) end
    TC.Safe = function(_, _, fn, ...) fn(...) return true end
    TC.Chat = { IsSecret = function() return false end }
    TC.db = { collection = {}, dust = 0, ledger = {}, decks = {}, settings = {} }
    TC.char = { granted = {} }
    for _, file in ipairs({ "Collection/Collection.lua", "Collection/Decks.lua", "UI/Match.lua", "Net/Sha256.lua",
        "Net/Duel.lua" }) do
        dofile(file)
    end
    local client = { name = name, full = name .. "-Realm", TC = TC }
    TC.Confirm = function(_, _, yes, no) if client.decline then no() else yes() end end
    return client
end

local function wire(a, b, tamper)
    for _, pair in ipairs({ { a, b }, { b, a } }) do
        local from, to = pair[1], pair[2]
        from.TC.Duel.transport = function(text)
            if tamper then text = tamper(from, text) end
            if text then
                schedule(0.05, function()
                    local prev = current
                    current = to
                    to.TC.Duel:Receive(text, from.full)
                    current = prev
                end)
            end
            return true
        end
    end
end

local function setDeck(client, class, seed)
    local TC = client.TC
    local cards = TC.AI.buildDeck(class, seed, 7)
    local deck = { id = "house:" .. class, class = class, name = class .. " deck", cards = {} }
    for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
    TC.ChosenDeck = function() return deck end
end

local function setup(tamper)
    stubGlobals()
    local a = loadClient("Alice")
    local b = loadClient("Bob")
    wire(a, b, tamper)
    setDeck(a, "MAGE", 11)
    setDeck(b, "WARRIOR", 22)
    return a, b
end

local function challenge(a, b)
    current = a
    a.TC.Duel:Challenge(b.full)
    current = nil
    run()
end

-- Each side plays its own turns (AI choices standing in for the players) until the game ends.
local function playOut(a, b, steps, onStep)
    local rngs = { [a] = a.TC.Rng.new(5), [b] = b.TC.Rng.new(6) }
    for step = 1, steps do
        local moved = false
        for _, c in ipairs({ a, b }) do
            local M = c.TC.Match
            if M:Active() and M:Engine():current_player() == M.mySeat then
                current = c
                local index = c.TC.AI.choose(M:Engine(), "novice", rngs[c])
                assert(M:PlayerApply(index), c.name .. " move refused: " .. tostring(M:Engine().last_error))
                if onStep then onStep(c, step) end
                current = nil
                moved = true
            end
        end
        run()
        if not moved and not a.TC.Match:Active() and not b.TC.Match:Active() then return end
    end
end

T.handshake_and_full_game_in_lockstep = function()
    local a, b = setup()
    challenge(a, b)
    local A, B = a.TC.Match, b.TC.Match
    assert(A:Active() and B:Active(), "both sides should be in the duel: " .. table.concat(a.TC.printed, " | ")
        .. " || " .. table.concat(b.TC.printed, " | "))
    assert(A.mySeat == 0 and B.mySeat == 1)
    assert(A.StateHash(A:Engine()) == B.StateHash(B:Engine()), "same opening state")
    playOut(a, b, 5000)
    assert(not A:Active() and not B:Active(), ("the game should end on both sides: A %s moves %s cp %s | B %s moves %s cp %s | %s || %s"):format(
        tostring(A:Active()), A:Record() and #A:Record().moves or "-", A:Engine():current_player(),
        tostring(B:Active()), B:Record() and #B:Record().moves or "-", B:Engine():current_player(),
        table.concat(a.TC.printed, " | "), table.concat(b.TC.printed, " | ")))
    assert(A.StateHash(A:Engine()) == B.StateHash(B:Engine()), "same final state")
    local results = { win = "loss", loss = "win", draw = "draw" }
    assert(results[A.result] == B.result, ("results mirror: %s / %s"):format(tostring(A.result), tostring(B.result)))
    assert((a.TC.db.stats.duelsPlayed or 0) == 1 and (b.TC.db.stats.duelsPlayed or 0) == 1)
end

T.declined_challenge = function()
    local a, b = setup()
    b.decline = true
    challenge(a, b)
    assert(not a.TC.Match:Active() and not a.TC.Duel:Pending() and not b.TC.Duel:Pending())
end

T.concede_reaches_the_other_side = function()
    local a, b = setup()
    challenge(a, b)
    current = b
    b.TC.Match:Concede()
    current = nil
    run()
    assert(b.TC.Match.result == "loss" and a.TC.Match.result == "win")
end

T.lost_move_is_recovered_by_sync = function()
    local dropped = false
    local a, b = setup(function(from, text)
        -- Drop Alice's third move once; the next move (or a ping) makes Bob ask for it again.
        local n = tonumber(text:match("^MV\t[^\t]+\t(%d+)\t") or "")
        if not dropped and from.name == "Alice" and n and n >= 2 then
            dropped = true
            return nil
        end
        return text
    end)
    challenge(a, b)
    playOut(a, b, 5000)
    assert(dropped)
    local A, B = a.TC.Match, b.TC.Match
    assert(A.StateHash(A:Engine()) == B.StateHash(B:Engine()), "recovered from the lost move")
end

T.desync_voids_the_match = function()
    local a, b = setup(function(from, text)
        if from.name == "Alice" and text:match("^MV\t") then
            return (text:gsub("\t%x+$", "\tdeadbeef"))
        end
        return text
    end)
    challenge(a, b)
    playOut(a, b, 50)
    assert(not b.TC.Match:Active(), "a mismatched state hash should void the duel")
end

T.forged_commitment_is_refused = function()
    local a, b = setup(function(from, text)
        if from.name == "Bob" and text:match("^RV\t") then
            -- Bob reveals a different deck than he committed to.
            local code = from.TC.Decks:Encode({ class = "WARRIOR", cards = (function()
                local t = {}
                for _, id in ipairs(from.TC.AI.buildDeck("WARRIOR", 99, 9)) do t[id] = (t[id] or 0) + 1 end
                return t
            end)() })
            return (text:gsub("\t[^\t]+$", "\t" .. code))
        end
        return text
    end)
    challenge(a, b)
    assert(not a.TC.Match:Active(), "Alice must refuse a reveal that doesn't match the commitment")
end

return T
