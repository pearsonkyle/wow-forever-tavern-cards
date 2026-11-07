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
-- `setup` (optional) is what the Play tab chose ({deck, opponent, difficulty}); kept so Rematch works
-- after a reload too.
function Match:StartPractice(deck, opponent, setup)
    local cards = TC.Decks:CardList(deck)
    local hi, lo = newSeed()
    local oppDeck = AI.buildDeck(opponent.class, (hi * 31 + 7) % 4294967296, lo, function(id) return TC.PlayableNow[id] end)
    if not oppDeck then
        TC:Print("Could not build a deck for the opponent.")
        return false
    end
    self.lastSetup = setup
    TC.char.match = {
        setup = setup,
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
local function describe(engine, move, seat)
    local desc = move and move.desc or "?"
    if seat == 1 and move and move.action == "play" then
        -- The opponent's secrets stay secret.
        local d = engine:def_of(move.raw.entity)
        if d and d.secret then return "Opponent: Play a Secret" end
    end
    desc = desc:gsub(" at position %d+", ""):gsub(" #[%d%.]+$", "")
    return (seat == 0 and "You: " or "Opponent: ") .. desc
end

-- The opponent's way out when a chosen move is refused or its search fails: end the turn, or take the
-- first option of a pending choice, so the table never stalls.
local function fallbackIndex(engine)
    local first
    for i, m in ipairs(engine:legal_moves()) do
        if m.action == "end_turn" then return i end
        if not first and m.action ~= "concede" then first = i end
    end
    return first
end

function Match:Apply(index, isFallback)
    local engine = self.engine
    if not engine or engine:is_terminal() then return false end
    local seat = engine:current_player()
    local moves = engine:legal_moves()
    local ok = engine:apply_move(index)
    if not ok then
        if engine:is_terminal() then
            -- The rules looped (E_LOOP): the engine called the match a draw.
            TC:Print(Match.ErrorText(engine.last_error))
            self:Finish()
        elseif seat == 1 and not isFallback then
            local fb = fallbackIndex(engine)
            if fb then return self:Apply(fb, true) end
        else
            UIErrorsFrame:AddMessage(Match.ErrorText(engine.last_error), 1, 0.1, 0.1)
        end
        return false
    end
    local record = TC.char.match
    record.moves[#record.moves + 1] = index
    local move = moves[index]
    if move and move.action ~= "mulligan" and move.action ~= "resolve" then
        self:Log(describe(engine, move, seat))
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

-- ---- rewards and history ---------------------------------------------------------------------
-- Practice wins pay dust by difficulty, for the first few wins each day; the day's first win also
-- brings a card. Nothing for losses: practice is for fun, quests are where the cards come from.

Match.WIN_DUST = { novice = 5, regular = 10, skilled = 20, expert = 40 }
Match.PAID_WINS_PER_DAY = 5
local CARD_ODDS = { { "LEGENDARY", 2 }, { "EPIC", 6 }, { "RARE", 22 }, { "COMMON", 70 } }

local function today()
    return date("%Y-%m-%d")
end

local function rewardCard(class, rng)
    local roll, rarity = rng:intBelow(100), "COMMON"
    for _, entry in ipairs(CARD_ODDS) do
        if roll < entry[2] then rarity = entry[1] break end
        roll = roll - entry[2]
    end
    local pool = {}
    for _, id in ipairs(TC.CardOrder) do
        local card = TC.Cards[id]
        if card.rarity == rarity and bit.band(card.flags, 3) == 3 and (card.family == class or card.family == "NEUTRAL") then
            pool[#pool + 1] = id
        end
    end
    return #pool > 0 and pool[rng:intBelow(#pool) + 1] or nil
end

function Match:Reward(record)
    local daily = TC.db.daily
    if not daily or daily.day ~= today() then
        daily = { day = today(), wins = 0 }
        TC.db.daily = daily
    end
    daily.wins = daily.wins + 1
    local reward = {}
    local profile = record.opponent and record.opponent.profile or "regular"
    if daily.wins <= self.PAID_WINS_PER_DAY then
        reward.dust = self.WIN_DUST[profile] or 10
        TC.Collection:AddDust(reward.dust, "Tavern win")
    end
    if daily.wins == 1 then
        local rng = TC.Rng.new(math.floor(time() % 2147483647), #record.moves)
        reward.card = rewardCard(record.classes[1], rng)
        if reward.card then
            TC.Collection:AddCard(reward.card, "First tavern win of the day")
        end
    end
    reward.left = math.max(0, self.PAID_WINS_PER_DAY - daily.wins)
    return reward
end

function Match:History()
    TC.char.history = TC.char.history or {}
    return TC.char.history
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
    self.reward = nil
    if won and record then
        self.reward = self:Reward(record)
    end
    self.reason = self.engine:end_reason()
    self.lastClasses = record and record.classes
    self.lastOpponent = record and record.opponent and record.opponent.name
    TC.char.lastMatch = { result = self.result, opponent = record and record.opponent, ended = time(),
        setup = record and record.setup }
    self.lastSetup = record and record.setup or self.lastSetup
    if record then
        local history = self:History()
        table.insert(history, 1, { t = time(), result = self.result, reason = self.reason, opponent = record.opponent,
            deck = record.deckName, class = record.classes[1], turns = math.floor((self.engine.state.turn + 1) / 2),
            dust = self.reward and self.reward.dust, card = self.reward and self.reward.card })
        while #history > 20 do table.remove(history) end
    end
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
        local engine = self.engine
        if engine and not engine:is_terminal() and engine:current_player() == 1 then
            local fb = fallbackIndex(engine)
            if fb then self:Apply(fb, true) end
        end
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
