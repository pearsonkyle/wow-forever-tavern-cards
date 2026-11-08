-- The scripted opponent: a port of the reference engine's tc/ai/scripted.cpp (choose_action) and
-- TcEngine::search_copy. Each candidate move is played on a private copy of the match whose decks are
-- reshuffled and whose opponent secrets are set aside (the copy cannot peek), the position is scored,
-- and the best few moves get a look at what they make possible.
--
--   local index = TC.AI.choose(engine, "regular", rng)   -- 1-based index into engine:legal_moves()
--
-- Long searches can be spread over frames: set TC.AI.yieldHook to a function that yields the running
-- coroutine when its time slice is used (the board does this); headless runs leave it nil.

local TC = TavernCards_NS
local D = TC.EngineDefs
local E = TC.Engine
local Rng = TC.Rng
local bit = bit
local band = bit.band
local min, max, sqrt = math.min, math.max, math.sqrt
local ZONE, KW = D.ZONE, D.KW

local AI = {}
TC.AI = AI

local WIN = 1.0e6
local CARD_IN_HAND = 0.7
local ACT_THRESHOLD = 0.05
local FOLLOW_UP = 0.9
local MAX_PLAYS_PER_TURN = 15

AI.PROFILES = {
    novice = { noise = 1.5, skip = 0.15, second_ply = 0, rollout = 0, budget = 100 },
    regular = { noise = 0, skip = 0, second_ply = 2, rollout = 0, budget = 120 },
    skilled = { noise = 0, skip = 0, second_ply = 4, rollout = 0, budget = 160 },
    expert = { noise = 0, skip = 0, second_ply = 4, rollout = 3, budget = 320 },
}

-- ---- search copies -----------------------------------------------------------------------------

-- TcEngine::search_copy: the match as `viewer` could know it, rolling its own dice.
function E:search_copy(seedHi, seedLo, viewer)
    local copy = setmetatable({}, E)
    copy.state = E.deepCopy(self.state)
    copy:resetTransient()
    copy.last_effect_count, copy.last_excess = self.last_effect_count, self.last_excess
    copy.scratch = true
    copy.events = nil
    local s = copy.state
    s.rng = Rng.new(seedHi, seedLo)
    for seat = 0, 1 do
        local deck = copy:deck_ids(seat)
        local slots = {}
        for i, id in ipairs(deck) do slots[i] = s.entities[id].zone_pos end
        s.rng:shuffle(deck)
        for i, id in ipairs(deck) do s.entities[id].zone_pos = slots[i] end
    end
    if viewer == 0 or viewer == 1 then
        local other = s.players[2 - viewer]
        for _, id in ipairs(other.secrets) do
            local secret = s.entities[id]
            if secret then secret.zone = ZONE.SETASIDE end
        end
        other.secrets = {}
    end
    return copy
end

local function actionsOf(engine)
    local out = {}
    for i, sp in ipairs(engine:enumerate_specs()) do out[i] = sp.action end
    return out
end

-- ---- reading a position ------------------------------------------------------------------------

local function heroWorth(healthAndArmor)
    if healthAndArmor <= 0 then return -1.0e5 end
    return 6.0 * sqrt(healthAndArmor)
end

local function lastingText(d)
    for _, fx in ipairs(d.effects) do
        if fx.trigger ~= "ON_PLAY" and fx.trigger ~= "BATTLECRY" then return true end
    end
    return false
end

local function minionWorth(engine, e)
    if e.flags.dead or e.health <= 0 then return 0 end
    local attack = max(0, e.attack)
    local worth = attack + 0.9 * e.health
    local kw = e.keywords
    if band(kw, KW.TAUNT) ~= 0 then worth = worth + 0.6 end
    if e.flags.divine_shield then worth = worth + 0.5 + 0.4 * attack end
    if band(kw, KW.LIFESTEAL) ~= 0 then worth = worth + 0.3 * attack end
    if band(kw, KW.POISONOUS) ~= 0 then worth = worth + 1.0 end
    if band(kw, KW.WINDFURY) ~= 0 then worth = worth + 0.5 * attack end
    if band(kw, KW.REBORN) ~= 0 and not e.flags.reborn_used then worth = worth + 1.0 end
    if e.flags.stealth then worth = worth + 0.4 end
    if band(kw, KW.ELUSIVE) ~= 0 then worth = worth + 0.3 end
    worth = worth + 0.8 * e.spell_damage
    if band(kw, KW.CANT_ATTACK) ~= 0 then worth = worth - 0.8 * attack end
    if e.flags.frozen then worth = worth - 0.4 * attack end
    if not e.flags.silenced then
        local d = engine:def_of(e.id)
        if d and lastingText(d) then worth = worth + 0.6 + 0.2 * min(d.cost, 10) end
    end
    worth = worth + 1.5 * engine:titan_abilities_left(e.id)
    if e.flags.dormant_turns > 0 then worth = worth * 0.5 end
    return worth
end

local function clamp(x, lo, hi)
    return max(lo, min(hi, x))
end

local function sideWorth(engine, seat, me)
    local s = engine.state
    local p = s.players[seat + 1]
    local worth = 0
    local weaponAttack = 0
    local weapon = s.entities[p.weapon_id]
    if weapon and weapon.zone == ZONE.WEAPON then
        weaponAttack = max(0, weapon.attack)
        worth = worth + 0.6 * weaponAttack * min(max(weapon.durability, 0), 4)
    end
    local hero = s.entities[p.hero_id]
    if hero then
        worth = worth + heroWorth(hero.health + hero.armor)
        if seat == me and s.active == me and not hero.flags.frozen and not hero.flags.exhausted
            and hero.flags.attacks_this_turn == 0 then
            worth = worth + 0.3 * max(0, hero.attack - weaponAttack)
        end
    end
    local deck = 0
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.zone == ZONE.DECK and e.owner == seat then
            deck = deck + 1
            if seat == me then worth = worth + 0.08 * clamp(-e.cost_delta, 0, 5) end
        end
        if e.zone == ZONE.BOARD and e.controller == seat then
            local d = engine:def_of(id)
            if d and d.type == "LOCATION" then
                worth = worth + 0.8 * max(0, e.durability)
            else
                worth = worth + minionWorth(engine, e)
            end
        end
    end
    if deck == 0 then worth = worth - 0.5 * (p.fatigue + 1) end
    local hand = engine:hand_ids(seat)
    worth = worth + CARD_IN_HAND * #hand
    if seat == me then
        local castable = min(8, p.max_mana + 2)
        for _, id in ipairs(hand) do
            local d = engine:def_of(id)
            if d then
                worth = worth + 0.05 * min(d.cost, castable)
                local now = engine:card_cost(p.seat, id)
                worth = worth + 0.12 * clamp(d.cost - now, 0, 5)
                local held = s.entities[id]
                if held and held.flags.forged then worth = worth + 1.0 end
            end
        end
    end
    worth = worth + 1.0 * p.max_mana
    worth = worth - 0.6 * p.overload_next
    worth = worth + 1.5 * #p.secrets
    worth = worth + 0.15 * p.corpses
    if p.starship_building then worth = worth + 0.4 * (p.starship_attack + p.starship_health) end
    for _, row in ipairs(s.persistent) do
        if row.owner == seat then worth = worth + 1.0 end
    end
    worth = worth + 1.0 * #p.delayed_effects
    return worth
end

local function threatAgainst(engine, attacker, defender)
    local s = engine.state
    local damage, taunted = 0, false
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.zone == ZONE.BOARD and not e.flags.dead and e.health > 0 and e.flags.dormant_turns <= 0 then
            local d = engine:def_of(id)
            if d and d.type == "MINION" then
                if e.controller == defender and band(e.keywords, KW.TAUNT) ~= 0 and not e.flags.stealth then
                    taunted = true
                end
                if e.controller == attacker and e.attack > 0 and not e.flags.frozen and band(e.keywords, KW.CANT_ATTACK) == 0 then
                    damage = damage + e.attack * (band(e.keywords, KW.WINDFURY) ~= 0 and 2 or 1)
                end
            end
        end
    end
    local weapon = s.entities[s.players[attacker + 1].weapon_id]
    if weapon and weapon.zone == ZONE.WEAPON then damage = damage + max(0, weapon.attack) end
    return damage, taunted
end

local function healthAndArmor(engine, seat)
    local hero = engine.state.entities[engine.state.players[seat + 1].hero_id]
    return hero and (hero.health + hero.armor) or 0
end

local function evaluate(engine, me)
    local s = engine.state
    if s.result.result ~= D.RESULT.ONGOING then
        if s.result.result == D.RESULT.DRAW then return -WIN / 2 end
        local won = (s.result.result == D.RESULT.WIN_A) == (me == 0)
        return won and WIN or -WIN
    end
    local score = sideWorth(engine, me, me) - sideWorth(engine, 1 - me, me)
    local incoming, taunted = threatAgainst(engine, 1 - me, me)
    if not taunted and incoming >= healthAndArmor(engine, me) then score = score - 30 end
    local outgoing, theirTaunt = threatAgainst(engine, me, 1 - me)
    if not theirTaunt and outgoing >= healthAndArmor(engine, 1 - me) then score = score + 4 end
    return score
end
AI.evaluate = evaluate

-- ---- trying moves ------------------------------------------------------------------------------

local Search = {}
Search.__index = Search

function Search:play(from, action)
    if AI.yieldHook then AI.yieldHook() end
    local copy = from:search_copy(self.seedHi, self.seedLo, self.me)
    self.trials = self.trials + 1
    if not copy:apply_action(action) then return nil end
    return copy
end

function Search:settle(game, depth)
    local me = self.me
    if depth < 2 and game.state.pending.active and game:current_player() == me and self.trials < self.budget then
        local best = -2 * WIN
        for _, option in ipairs(actionsOf(game)) do
            if option.type == "resolve" then
                local after = self:play(game, option)
                if after then best = max(best, self:settle(after, depth + 1)) end
                if self.trials >= self.budget then break end
            end
        end
        if best > -2 * WIN then return best end
    end
    return evaluate(game, me)
end

local function passOrConcede(t)
    return t == "end_turn" or t == "concede" or t == "timeout"
end

function Search:rollout(game, steps)
    local me = self.me
    local here = evaluate(game, me)
    if steps <= 0 or game:is_terminal() or game.state.pending.active or game:current_player() ~= me then return here end
    local best = here + ACT_THRESHOLD
    local bestAfter
    for _, nxt in ipairs(actionsOf(game)) do
        if self.trials >= self.budget then break end
        if not passOrConcede(nxt.type) and nxt.type ~= "trade" and not (nxt.type == "play" and nxt.position > 0) then
            local after = self:play(game, nxt)
            if after then
                local value = self:settle(after, 0)
                if value > best then
                    best = value
                    bestAfter = after
                end
            end
        end
    end
    if not bestAfter then return here end
    return max(best, self:rollout(bestAfter, steps - 1))
end

function Search:best_next(game, base)
    local me = self.me
    if game:is_terminal() or game.state.pending.active or game:current_player() ~= me then return 0 end
    local best = 0
    for _, nxt in ipairs(actionsOf(game)) do
        if self.trials >= self.budget then break end
        if not passOrConcede(nxt.type) and not (nxt.type == "play" and nxt.position > 0) then
            local after = self:play(game, nxt)
            if after then best = max(best, self:settle(after, 0) - base) end
        end
    end
    return best
end

local function readsNeighbours(d)
    if not d then return false end
    local t = d.text
    return t:find("djacent", 1, true) or t:find("eftmost", 1, true) or t:find("ightmost", 1, true)
end

local function placementMatters(engine, action, me)
    if readsNeighbours(engine:def_of(action.entity)) then return true end
    local s = engine.state
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.zone == ZONE.BOARD and e.controller == me and readsNeighbours(engine:def_of(id)) then return true end
    end
    return false
end

local function heroPowerDamage(engine, seat)
    local power = engine.state.players[seat + 1].hero_power_id
    if power == 3 then return 2 end
    if power == 8 then return 1 end
    return 0
end

local function faceDamage(engine, action, me)
    local foe = 1 - me
    local s = engine.state
    if action.type == "attack" then
        local atk, tgt = s.entities[action.entity], s.entities[action.target]
        if atk and tgt and tgt.zone == ZONE.HERO and tgt.controller == foe then return atk.attack end
    elseif action.type == "hero_power" then
        local tgt = s.entities[action.target]
        if tgt and tgt.zone == ZONE.HERO and tgt.controller == foe then return heroPowerDamage(engine, me) end
    end
    return 0
end

local function firstOf(actions, t)
    for i, a in ipairs(actions) do
        if a.type == t then return i end
    end
    return nil
end

local function lethalIndex(engine, actions, me)
    local hero = engine.state.entities[engine.state.players[2 - me].hero_id]
    if not hero then return nil end
    local remaining = hero.health + hero.armor
    if remaining <= 0 then return nil end
    local total, used, best, bestDamage = 0, 0, nil, 0
    for i, a in ipairs(actions) do
        local dmg = faceDamage(engine, a, me)
        if dmg > 0 then
            if used < 6 then
                total = total + dmg
                used = used + 1
            end
            if dmg > bestDamage then
                bestDamage = dmg
                best = i
            end
        end
    end
    return total >= remaining and best or nil
end

local function chooseMulligan(engine, actions, me)
    local offered = {}
    for _, id in ipairs(engine:hand_ids(me)) do
        local e = engine:ent(id)
        if e and e.card_id ~= D.COIN_ID then offered[#offered + 1] = id end
    end
    local wanted = {}
    for i, id in ipairs(offered) do
        local d = engine:def_of(id)
        if d and d.cost >= 4 then wanted[#wanted + 1] = i - 1 end
    end
    for i, a in ipairs(actions) do
        if a.type == "mulligan" and #a.replace == #wanted then
            local same = true
            for k = 1, #wanted do
                if a.replace[k] ~= wanted[k] then same = false break end
            end
            if same then return i end
        end
    end
    return 1
end

local function chooseDredge(engine, actions, me)
    local nextTurn = engine.state.players[me + 1].max_mana + 1
    local options = engine.state.pending.options
    local best, bestValue = 1, -1.0e9
    for i, a in ipairs(actions) do
        if a.type == "resolve" and a.choice >= 0 and a.choice < #options then
            local d = engine:def_of(options[a.choice + 1])
            if d then
                local value = d.cost <= nextTurn and 10 + d.cost or 10 - d.cost
                if value > bestValue then
                    bestValue = value
                    best = i
                end
            end
        end
    end
    return best
end

-- choose_action. `rng` is the caller's own stream (an Rng); returns a 1-based index into the move list.
function AI.choose(engine, profileName, rng)
    local actions = actionsOf(engine)
    local n = #actions
    if n == 0 then return nil end
    local me = engine:current_player()
    if me ~= 0 and me ~= 1 then return 1 end
    if n == 1 then return 1 end
    if actions[1].type == "mulligan" then return chooseMulligan(engine, actions, me) end
    local lethal = lethalIndex(engine, actions, me)
    if lethal then return lethal end
    if engine.state.pending.active and engine.state.pending.kind == "dredge" then
        return chooseDredge(engine, actions, me)
    end
    local endTurn = firstOf(actions, "end_turn")
    if endTurn and engine.state.players[me + 1].cards_played_this_turn >= MAX_PLAYS_PER_TURN then return endTurn end
    local style = AI.PROFILES[profileName] or AI.PROFILES.regular
    if endTurn and style.skip > 0 and rng:nextDouble() < style.skip then return endTurn end

    local seedHi = rng:next()
    local seedLo = rng:next()
    local search = setmetatable({ me = me, seedHi = seedHi, seedLo = seedLo, budget = style.budget, trials = 0 }, Search)
    local start = engine:search_copy(seedHi, seedLo, me)
    local base = evaluate(start, me)

    local UNTRIED = -1.0e9
    local gain, rightmost, tried = {}, {}, {}
    for i = 1, n do gain[i] = UNTRIED end
    for i, a in ipairs(actions) do
        if a.type == "play" and a.position >= 0 then
            for j, b in ipairs(actions) do
                if b.type == "play" and b.entity == a.entity and b.target == a.target and b.choice == a.choice
                    and (not rightmost[i] or b.position > actions[rightmost[i]].position) then
                    rightmost[i] = j
                end
            end
        end
    end
    for i, a in ipairs(actions) do
        if not passOrConcede(a.type) then
            local standIn = rightmost[i]
            if not (standIn and standIn ~= i and not placementMatters(engine, a, me)) and search.trials < search.budget then
                tried[i] = true
                local after = search:play(start, a)
                if after then gain[i] = search:settle(after, 0) - base end
                if a.type == "trade" and gain[i] > UNTRIED / 2 then gain[i] = gain[i] - 0.3 end
            end
        end
    end
    for i = 1, n do
        local standIn = rightmost[i]
        if gain[i] == UNTRIED and standIn and standIn ~= i then gain[i] = gain[standIn] - 0.001 end
    end

    local score = {}
    for i = 1, n do score[i] = gain[i] end
    if style.second_ply > 0 then
        search.budget = search.trials + style.budget
        local order = {}
        for i = 1, n do
            if tried[i] and gain[i] > UNTRIED / 2 then order[#order + 1] = i end
        end
        -- stable sort by gain, descending
        for i = 2, #order do
            local x, j = order[i], i - 1
            while j >= 1 and gain[order[j]] < gain[x] do
                order[j + 1] = order[j]
                j = j - 1
            end
            order[j + 1] = x
        end
        local looked = {}
        local function lookAhead(i)
            looked[i] = true
            local after = search:play(start, actions[i])
            if not after then return end
            local here = evaluate(after, me)
            local later = style.rollout > 0 and (search:rollout(after, style.rollout) - here) or search:best_next(after, here)
            score[i] = score[i] + FOLLOW_UP * max(0, later)
        end
        local expanded = 0
        for _, i in ipairs(order) do
            if expanded >= style.second_ply or search.trials >= search.budget then break end
            if actions[i].type == "resolve" then break end
            expanded = expanded + 1
            lookAhead(i)
        end
        for i = 1, n do
            if search.trials >= search.budget then break end
            local a = actions[i]
            if a.type == "play" and not looked[i] and tried[i] and gain[i] > UNTRIED / 2
                and engine:card_cost(me, a.entity) == 0 then
                lookAhead(i)
            end
        end
    end
    if style.noise > 0 then
        for i = 1, n do
            if score[i] > ACT_THRESHOLD then
                score[i] = max(ACT_THRESHOLD * 1.5, score[i] + style.noise * (rng:nextDouble() - 0.5) * 2)
            end
        end
    end
    local best, bestScore = nil, -1.0e18
    for i, a in ipairs(actions) do
        if not passOrConcede(a.type) then
            local sc = score[i]
            if a.type == "play" and a.position >= 0 then sc = sc + 1.0e-5 * a.position end
            if sc > bestScore then
                bestScore = sc
                best = i
            end
        end
    end
    if endTurn and (not best or bestScore < ACT_THRESHOLD) then return endTurn end
    if best then return best end
    local concede = firstOf(actions, "concede")
    for i, a in ipairs(actions) do
        if i ~= concede and a.type ~= "timeout" then return i end
    end
    return 1
end

-- build_deck (reference engine, tc/ai/deck.cpp): 30 legal cards of `family` plus Neutral, deterministic in
-- (family, seed). `allowed(id)` narrows the pool further (nil = every implemented card).
function AI.buildDeck(family, seedHi, seedLo, allowed)
    local pool = {}
    for _, id in ipairs(D.all()) do
        local d = D.def(id)
        if d and d.implemented and d.collectible and d.droppable and id ~= D.COIN_ID
            and (d.family == family or d.family == "NEUTRAL") and (not allowed or allowed(id)) then
            pool[#pool + 1] = { id = id, legendary = d.rarity == "LEGENDARY" }
        end
    end
    local capacity = 0
    for _, entry in ipairs(pool) do capacity = capacity + (entry.legendary and 1 or 2) end
    if capacity < 30 then return nil end
    local rng = Rng.new(seedHi, seedLo)
    rng:shuffle(pool)
    local deck = {}
    for _, entry in ipairs(pool) do
        for _ = 1, entry.legendary and 1 or 2 do
            if #deck < 30 then deck[#deck + 1] = entry.id end
        end
        if #deck >= 30 then break end
    end
    return #deck == 30 and deck or nil
end
