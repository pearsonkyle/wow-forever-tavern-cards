-- A match in progress: the engine, the opponent's brain, and the record that lets a /reload resume.
--
-- The player is always seat 0, the opponent seat 1. Every move applied is appended to
-- TavernCardsCharDB.match.moves, so the match is rebuilt exactly by replaying them from the seed
-- (the engine is deterministic). The AI thinks in a coroutine, a few milliseconds per frame.

local TC = TavernCards_NS
local E, AI, Rng = TC.Engine, TC.AI, TC.Rng

local Match = {}
TC.Match = Match

local AI_SLICE_MS = 6       -- thinking time per frame
local AI_PACE = 0.7         -- seconds between the opponent's moves, so they can be followed

local listeners = {}
function Match:Subscribe(fn)
    listeners[#listeners + 1] = fn
end

local function notify(what)
    for _, fn in ipairs(listeners) do
        TC:Safe("match listener", fn, what)
    end
end

local function now()
    return debugprofilestop and debugprofilestop() or (GetTime() * 1000)
end

local function newSeed()
    -- Two 32-bit halves; time and frame noise are plenty for a practice game.
    local hi = math.floor((time() % 2147483647))
    local lo = math.floor((GetTime() * 1000003) % 4294967296)
    return hi, lo
end

local function build(record)
    local engine = E.create(record.decks[1], record.decks[2], { record.seed[1], record.seed[2] })
    if not engine then return nil end
    engine:set_class(0, record.classes[1])
    engine:set_class(1, record.classes[2])
    engine:set_hero_power(0, E.heroPowerFor(record.classes[1]))
    engine:set_hero_power(1, E.heroPowerFor(record.classes[2]))
    return engine
end

function Match:Active()
    return self.engine ~= nil and not self.engine:is_terminal()
end

function Match:Engine()
    return self.engine
end

function Match:Record()
    return TC.char.match
end

-- opts: { deck = Decks entry, opponent = { name, class, profile, npc } }
function Match:StartPractice(deck, opponent)
    local cards = TC.Decks:CardList(deck)
    local hi, lo = newSeed()
    local oppDeck = AI.buildDeck(opponent.class, (hi * 31 + 7) % 4294967296, lo, function(id) return TC.PlayableNow[id] end)
    if not oppDeck then
        TC:Print("Could not build a deck for the opponent.")
        return false
    end
    self.lastSetup = { deck = deck, opponent = opponent }
    TC.char.match = {
        seed = { hi, lo }, decks = { cards, oppDeck }, classes = { deck.class, opponent.class },
        opponent = opponent, deckName = deck.name, moves = {}, started = time(),
    }
    return self:Load()
end

-- (Re)builds the engine from the saved record by replaying its moves.
function Match:Load()
    local record = TC.char.match
    if not record then return false end
    local engine = build(record)
    if not engine then
        TC:Print("The saved match could not be restored.")
        TC.char.match = nil
        return false
    end
    for i, index in ipairs(record.moves) do
        if not engine:apply_move(index) then
            TC:Print("The saved match diverged at move %d and was abandoned.", i)
            TC.char.match = nil
            return false
        end
    end
    engine.events = {}
    self.engine = engine
    self.aiRng = Rng.new(record.seed[1], (record.seed[2] + #record.moves * 7919) % 4294967296)
    self.thinking = nil
    self.waitUntil = nil
    self.result = nil
    notify("load")
    self:Pump()
    return true
end

-- Short log line for a move: the engine's description without its board-slot detail.
local function describe(move, seat)
    local desc = move and move.desc or "?"
    desc = desc:gsub(" at position %d+", ""):gsub(" #[%d%.]+$", "")
    return (seat == 0 and "You: " or "Opponent: ") .. desc
end

function Match:Apply(index)
    local engine = self.engine
    if not engine or engine:is_terminal() then return false end
    local seat = engine:current_player()
    local moves = engine:legal_moves()
    local ok = engine:apply_move(index)
    if not ok then
        UIErrorsFrame:AddMessage(Match.ErrorText(engine.last_error), 1, 0.1, 0.1)
        return false
    end
    local record = TC.char.match
    record.moves[#record.moves + 1] = index
    local move = moves[index]
    if move and move.action ~= "mulligan" and move.action ~= "resolve" then
        self:Log(describe(move, seat))
    end
    notify("move", seat, move)
    if engine:is_terminal() then
        self:Finish()
    else
        self:Pump()
    end
    return true
end

-- The player's moves: only on their own decision and never while the opponent is thinking.
function Match:PlayerApply(index)
    if not self:Active() or self.engine:current_player() ~= 0 or self.thinking then return false end
    return self:Apply(index)
end

-- The last lines of the match log (kept with the record, so a reload keeps them).
function Match:Log(line)
    local record = TC.char.match
    if not record then return end
    record.log = record.log or {}
    record.log[#record.log + 1] = line
    while #record.log > 60 do table.remove(record.log, 1) end
    notify("log", line)
end

local ERRORS = { E_COST = "Not enough mana.", E_BOARD_FULL = "Your board is full.", E_TARGET = "Invalid target.",
    E_NEEDS_TARGET = "Choose a target.", E_USED = "Already used this turn.", E_PHASE = "Not now.",
    E_NOT_YOUR_TURN = "It is not your turn.", E_PENDING = "Make your choice first.",
    E_SECRET_LIMIT = "You already have 5 secrets.", E_SECRET_DUPLICATE = "That secret is already in play.",
    E_LOOP = "The rules got stuck in a loop; the match is a draw." }
function Match.ErrorText(code)
    return ERRORS[code] or ("That can't be done (" .. tostring(code) .. ").")
end

-- Conceding on the opponent's turn: the engine only takes moves from the deciding seat, so the loss is
-- recorded directly (there is nothing left to replay).
function Match:Concede()
    if not self:Active() then return end
    self.thinking = nil
    if self.engine:current_player() == 0 then
        for i, m in ipairs(self.engine:legal_moves()) do
            if m.action == "concede" then
                self:Apply(i)
                return
            end
        end
    end
    local s = self.engine.state
    s.result.result, s.result.reason, s.result.winner = TC.EngineDefs.RESULT.WIN_B, TC.EngineDefs.REASON.CONCEDE, 1
    s.phase = TC.EngineDefs.PHASE.MATCH_FINISHED
    self:Finish()
end

function Match:Finish()
    local s = self.engine.state
    local won = s.result.result == TC.EngineDefs.RESULT.WIN_A
    local draw = s.result.result == TC.EngineDefs.RESULT.DRAW
    local record = TC.char.match
    local stats = TC.db.stats or {}
    TC.db.stats = stats
    stats.played = (stats.played or 0) + 1
    if won then stats.won = (stats.won or 0) + 1 end
    self.result = draw and "draw" or (won and "win" or "loss")
    if won and record and record.opponent and record.opponent.npc and TC.Duels then
        TC.Duels:Reward(record.opponent)
    end
    self.reason = self.engine:end_reason()
    self.lastClasses = record and record.classes
    self.lastOpponent = record and record.opponent and record.opponent.name
    TC.char.lastMatch = { result = self.result, opponent = record and record.opponent, ended = time() }
    TC.char.match = nil
    notify("end")
end

-- Called after every change: if the opponent is to move, it thinks (spread over frames) then moves.
function Match:Pump()
    local engine = self.engine
    if not engine or engine:is_terminal() then return end
    if engine:current_player() ~= 1 then return end
    if self.thinking then return end
    self.waitUntil = GetTime() + AI_PACE
    local profile = (TC.char.match and TC.char.match.opponent and TC.char.match.opponent.profile) or "regular"
    self.thinking = coroutine.create(function()
        return AI.choose(engine, profile, self.aiRng)
    end)
end

local driver = CreateFrame("Frame")
driver:SetScript("OnUpdate", function()
    local self = Match
    local co = self.thinking
    if not co then return end
    local deadline = now() + AI_SLICE_MS
    AI.yieldHook = function()
        if now() > deadline then coroutine.yield() end
    end
    local ok, result = coroutine.resume(co)
    AI.yieldHook = nil
    if not ok then
        self.thinking = nil
        TC:ReportError("ai", result)
        return
    end
    if coroutine.status(co) == "dead" then
        if self.waitUntil and GetTime() < self.waitUntil then
            -- Thought fast; wait out the pace before moving.
            self.thinking = coroutine.create(function()
                while GetTime() < self.waitUntil do coroutine.yield() end
                return result
            end)
            return
        end
        self.thinking = nil
        if result and self.engine and self.engine:current_player() == 1 and not self.engine:is_terminal() then
            self:Apply(result)
        end
    end
end)

TC:On("PLAYER_ENTERING_WORLD", function(isLogin, isReload)
    if (isLogin or isReload) and TC.char and TC.char.match and not Match.engine then
        Match:Load()
    end
end)
