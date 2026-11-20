-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- A note before you edit or reuse this file. The engine is a statement-for-statement port of jankcraft's
-- C++ engine (mod-tavern-sim, tc/engine.cpp and the files around it). Before changing any engine, ops,
-- effects or AI behaviour, compare it with the C++ source, keep the RNG draw order identical and run
-- tests/test_parity.lua. A divergence is fixed in the C++ first, never in the Lua alone.
-- Please don't lift this engine into another project as-is: contribute upstream, or fork it under
-- GPL-3.0-or-later with attribution. This comment is only a friendly notice; the licence is what makes
-- those terms binding.
--
-- Effects: targeting, filters, conditions, counts, costs, event firing, the effect runner and combat.
-- A port of the matching TcEngine members in the reference engine's tc/engine.cpp; see Engine.lua for the rules
-- of the port (statement order, RNG order and quirks are kept).

local TC = TavernCards_NS
local D = TC.EngineDefs
local E = TC.Engine
local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local min, max = math.min, math.max
local ZONE, PHASE, KW, RACE = D.ZONE, D.PHASE, D.KW, D.RACE
local def = D.def
local hasRace = D.hasRace
local copyEffect = D.copyEffect
local other = E.other

local HERO_POWER_TARGETING = -2
E.HERO_POWER_TARGETING = HERO_POWER_TARGETING

local function contains(list, x)
    for i = 1, #list do
        if list[i] == x then return true end
    end
    return false
end
E.contains = contains

local function popcount(x)
    local n = 0
    while x ~= 0 do
        x = bit.band(x, x - 1)
        n = n + 1
    end
    return n
end
E.popcount = popcount
function E.quest_goal_target(line)
    if line.questGoal == "FILL_THEN_EMPTY" then return 2 end
    -- A listed set ("a 2, 3, and 4-Cost card") needs each value once.
    if (line.distinct == 3 or line.distinct == 4 or line.distinct == 5) and line.amount2 ~= 0 then
        return popcount(line.amount2)
    end
    return math.max(1, line.amount)
end

-- ---- targets -----------------------------------------------------------------------------------

local OFF_BOARD = { YOUR_WEAPON = true, FRIENDLY_HAND_MINIONS = true, FRIENDLY_HAND = true, ENEMY_WEAPON = true,
    ENEMY_SECRET = true, FRIENDLY_DECK = true, ENEMY_DECK = true, ENEMY_HAND = true, ENEMY_HAND_MINIONS = true }

function E:off_board_side(side, controller)
    local out = {}
    if side == "YOUR_WEAPON" or side == "ENEMY_WEAPON" then
        local owner = side == "YOUR_WEAPON" and controller or other(controller)
        local id = self:player(owner).weapon_id
        local w = self:ent(id)
        if w and w.zone == ZONE.WEAPON then out[1] = id end
        return out
    end
    if side == "ENEMY_SECRET" then
        for _, id in ipairs(self:player(other(controller)).secrets) do out[#out + 1] = id end
        return out
    end
    if side == "FRIENDLY_DECK" or side == "ENEMY_DECK" then
        -- Run 16: during the Start of Game lines "your deck" is the STARTING deck (deck_scan_ids).
        local whose = side == "FRIENDLY_DECK" and controller or other(controller)
        return self.start_of_game_running and self:deck_scan_ids(whose) or self:deck_ids(whose)
    end
    -- ENEMY_HAND / ENEMY_HAND_MINIONS: the opponent's hand, every card or its minions.
    if side == "ENEMY_HAND" or side == "ENEMY_HAND_MINIONS" then
        for _, id in ipairs(self:hand_ids(other(controller))) do
            local d = self:def_of(id)
            if side == "ENEMY_HAND" or (d and d.type == "MINION") then out[#out + 1] = id end
        end
        return out
    end
    if side == "FRIENDLY_HAND" then
        return self:hand_ids(controller)
    end
    for _, id in ipairs(self:hand_ids(controller)) do
        local d = self:def_of(id)
        if d and d.type == "MINION" then out[#out + 1] = id end
    end
    return out
end

-- The membership switch shared by choose_targets and side_ids.
local function sideIncludes(self, side, e, id, controller, source)
    local foe = other(controller)
    if side == "ANY_CHARACTER" then return true end
    if side == "ANY_MINION" then return e.zone == ZONE.BOARD end
    if side == "ANY_OTHER_CHARACTER" then return id ~= source end
    if side == "ANY_OTHER_MINION" then return e.zone == ZONE.BOARD and id ~= source end
    if side == "FRIENDLY_OTHER_MINIONS" then
        return e.zone == ZONE.BOARD and id ~= source and e.controller == controller
    end
    if side == "ENEMY_CHARACTER" then return e.controller == foe end
    if side == "ENEMY_MINION" or side == "ENEMY_MINIONS" then return e.zone == ZONE.BOARD and e.controller == foe end
    if side == "FRIENDLY_CHARACTER" then return e.controller == controller end
    if side == "FRIENDLY_MINION" or side == "FRIENDLY_MINIONS" then
        return e.zone == ZONE.BOARD and e.controller == controller
    end
    if side == "YOUR_HERO" then return e.zone == ZONE.HERO and e.owner == controller end
    if side == "ENEMY_HERO" then return e.zone == ZONE.HERO and e.owner == foe end
    if side == "ANY_HERO" then return e.zone == ZONE.HERO end
    if side == "ENEMY_LOCATION" then
        local d = self:def_of(id)
        return e.zone == ZONE.BOARD and e.controller == foe and d ~= nil and d.type == "LOCATION"
    end
    if side == "MINIONS_AND_LOCATIONS" then return e.zone == ZONE.BOARD end
    return false
end

function E:choose_targets(side, controller, source)
    if OFF_BOARD[side] then return {} end
    local out = {}
    local asking = source > 0 and self:def_of(source) or nil
    local spellOrPower = source == HERO_POWER_TARGETING
        or (asking ~= nil and (asking.type == "SPELL" or asking.type == "HERO_POWER"))
    local s = self.state
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if (e.zone == ZONE.BOARD or e.zone == ZONE.HERO) and not e.flags.dead
            and not (e.zone == ZONE.BOARD and e.health <= 0) and e.flags.dormant_turns <= 0
            and sideIncludes(self, side, e, id, controller, source)
            and not (side ~= "ENEMY_LOCATION" and side ~= "MINIONS_AND_LOCATIONS" and self:is_location(id))
            and not (e.controller ~= controller and band(e.keywords, KW.STEALTH) ~= 0)
            and not (band(e.keywords, KW.ELUSIVE) ~= 0 and spellOrPower) then
            out[#out + 1] = id
        end
    end
    return out
end

function E:side_ids(side, controller, source)
    if OFF_BOARD[side] then
        return self:off_board_side(side, controller)
    end
    local out = {}
    local s = self.state
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if (e.zone == ZONE.BOARD or e.zone == ZONE.HERO)
            and not (e.zone == ZONE.BOARD and (e.health <= 0 or e.flags.dead))
            and e.flags.dormant_turns <= 0 and sideIncludes(self, side, e, id, controller, source)
            and not (side ~= "ENEMY_LOCATION" and side ~= "MINIONS_AND_LOCATIONS" and self:is_location(id)) then
            out[#out + 1] = id
        end
    end
    return out
end

function E:resolve_targets(fx, source, chosen, triggerSource, controller)
    local out = {}
    local kind, side = fx.target.kind, fx.target.side
    local rng = self.state.rng
    if kind == "PREVIOUS" then
        return out
    elseif kind == "CHOOSE" then
        if side == "ENEMY_WEAPON" or side == "YOUR_WEAPON" then
            return self:side_ids(side, controller, source)
        end
        if side == "ENEMY_SECRET" then
            local pool = self:side_ids(side, controller, source)
            if #pool > 0 then out[1] = pool[rng:intBelow(#pool) + 1] end
            return out
        end
        if contains(self:choose_targets(side, controller, source), chosen) then
            out[1] = chosen
        end
    elseif kind == "ALL" then
        out = self:side_ids(side, controller, source)
        if fx.excludeRaceBits ~= 0 then
            local kept = {}
            for _, id in ipairs(out) do
                local d = self:def_of(id)
                if not (d and hasRace(d.races, fx.excludeRaceBits)) then kept[#kept + 1] = id end
            end
            out = kept
        end
        if fx.op == "DESTROY" and fx.amount2 == 1 and #out > 0 then
            table.remove(out, rng:intBelow(#out) + 1)
        end
    elseif kind == "RANDOM" then
        local pool = self:side_ids(side, controller, source)
        if self:effect_has_target_filter(fx) or E.has_stat_bounds(fx) then
            local kept = {}
            for _, id in ipairs(pool) do
                if self:target_matches_filters(id, fx, source) then kept[#kept + 1] = id end
            end
            pool = kept
        end
        pool = self:narrow_by_cost(pool, fx.pickCostNum)   -- "the lowest Cost minion in your hand"
        if #pool > 0 then out[1] = pool[rng:intBelow(#pool) + 1] end
    elseif kind == "SELF" then
        if side == "YOUR_HERO" then
            local h = self:hero_of(controller)
            if h then out[1] = h.id end
        elseif side == "ENEMY_HERO" then
            local h = self:hero_of(other(controller))
            if h then out[1] = h.id end
        else
            out[1] = source
        end
    elseif kind == "LOWEST_HEALTH" or kind == "HIGHEST_ATTACK" then
        local best = 0
        for _, id in ipairs(self:side_ids(side, controller, source)) do
            local e = self:ent(id)
            if e then
                if best == 0 or (kind == "LOWEST_HEALTH" and e.health < self:ent(best).health
                    or kind == "HIGHEST_ATTACK" and e.attack > self:ent(best).attack) then
                    best = id
                end
            end
        end
        if best ~= 0 then out[1] = best end
    elseif kind == "ADJACENT" then
        local e = self:ent(source)
        local anchorId = source
        local d = self:def_of(source)
        if d and d.type == "SPELL" and chosen ~= 0 then
            local anchor = self:ent(chosen)
            if anchor and anchor.zone == ZONE.BOARD then
                e = anchor
                anchorId = chosen
            end
        end
        if e and e.zone == ZONE.GRAVEYARD and self.dying_pos >= 0 then
            local left, right, leftPos, rightPos = 0, 0, -1, 2 ^ 20
            for _, id in ipairs(self:board_ids(e.owner)) do
                local pos = self.state.entities[id].zone_pos
                if pos < self.dying_pos and pos > leftPos then left, leftPos = id, pos end
                if pos >= self.dying_pos and pos < rightPos then right, rightPos = id, pos end
            end
            if left ~= 0 then out[#out + 1] = left end
            if right ~= 0 then out[#out + 1] = right end
        end
        if e and e.zone == ZONE.BOARD then
            local board = self:board_ids(e.owner)
            for i, id in ipairs(board) do
                if id == anchorId then
                    if i > 1 then out[#out + 1] = board[i - 1] end
                    if i < #board then out[#out + 1] = board[i + 1] end
                    break
                end
            end
        end
    elseif kind == "REMEMBERED" then
        -- "Deathrattle: resummon it": what the card's `remember` lines took, wherever those cards are now.
        local keeper = self:ent(source)
        if keeper then
            for _, id in ipairs(keeper.remembered) do
                if self:ent(id) then out[#out + 1] = id end
            end
        end
    elseif kind == "LEFTMOST" or kind == "RIGHTMOST" or kind == "EDGES" then
        -- "The left-most minion in your hand", "your opponent's left and right-most minions": the ends of the side's
        -- row among the members its filters admit, in board (or hand) order. A lone member is counted once.
        local row = self:side_ids(side, controller, source)
        if self:effect_has_target_filter(fx) then
            local kept = {}
            for _, id in ipairs(row) do
                if self:target_matches_filters(id, fx, source) then kept[#kept + 1] = id end
            end
            row = kept
        end
        row = E.stable_sort(row, function(a, b)
            local x, y = self:ent(a), self:ent(b)
            return (x and x.zone_pos or 0) < (y and y.zone_pos or 0)
        end)
        if #row > 0 then
            if kind ~= "RIGHTMOST" then out[#out + 1] = row[1] end
            if kind ~= "LEFTMOST" and (#out == 0 or out[1] ~= row[#row]) then out[#out + 1] = row[#row] end
        end
    elseif kind == "LEFT_SIDE" or kind == "RIGHT_SIDE" then
        local e = self:ent(source)
        if e and e.zone == ZONE.BOARD then
            local board = self:board_ids(e.owner)
            local at
            for i, id in ipairs(board) do
                if id == source then at = i break end
            end
            if at then
                local from, to = 1, at - 1
                if kind == "RIGHT_SIDE" then from, to = at + 1, #board end
                for i = from, to do
                    if not self:is_location(board[i]) then out[#out + 1] = board[i] end
                end
            end
        end
    elseif kind == "RIGHT" then
        local e = self:ent(source)
        if e and e.zone == ZONE.BOARD then
            local board = self:board_ids(e.owner)
            for i = 1, #board - 1 do
                if board[i] == source then
                    out[1] = board[i + 1]
                    break
                end
            end
        end
    elseif kind == "TRIGGER_SOURCE" then
        if self.kill_victim ~= 0 and (fx.trigger == "HONORABLE_KILL" or fx.trigger == "OVERKILL"
            or fx.trigger == "AFTER_ATTACK_KILL") then
            return { self.kill_victim }
        end
        if triggerSource ~= 0 and self:ent(triggerSource) then out[1] = triggerSource end
    end
    return out
end

-- ---- filters -----------------------------------------------------------------------------------

-- A stable sort (std::stable_sort): equal keys keep their order. Lua's table.sort is not stable.
function E.stable_sort(list, less)
    local indexed = {}
    for i, v in ipairs(list) do indexed[i] = { v, i } end
    table.sort(indexed, function(a, b)
        if less(a[1], b[1]) then return true end
        if less(b[1], a[1]) then return false end
        return a[2] < b[2]
    end)
    local out = {}
    for i, x in ipairs(indexed) do out[i] = x[1] end
    return out
end

function E.has_stat_bounds(fx)
    return fx.targetAttackMin > 0 or fx.targetAttackMax ~= 0 or fx.targetHealthMin > 0 or fx.targetHealthMax > 0
        or fx.attackBelowSource
end

-- "Draw your highest Cost minion", "the lowest Cost minion in your hand": keep only the cards at that extreme of
-- Cost as it stands now (1 highest, 2 lowest). Returns the kept list in the same order.
function E:narrow_by_cost(ids, pickCost)
    if pickCost == 0 or #ids == 0 then return ids end
    local function costOf(id)
        local e = self:ent(id)
        return e and self:card_cost(e.controller, id) or 0
    end
    local best = costOf(ids[1])
    for _, id in ipairs(ids) do
        best = pickCost == 1 and max(best, costOf(id)) or min(best, costOf(id))
    end
    local kept = {}
    for _, id in ipairs(ids) do
        if costOf(id) == best then kept[#kept + 1] = id end
    end
    return kept
end

-- The cards a deck condition reads: the deck, or during the Start of Game lines the STARTING deck (the cards dealt to
-- the seat that are still in its deck or hand; not what an effect made).
function E:deck_scan_ids(seat)
    if not self.start_of_game_running then return self:deck_ids(seat) end
    local out = {}
    for _, zone in ipairs({ self:deck_ids(seat), self:hand_ids(seat) }) do
        for _, id in ipairs(zone) do
            local e = self:ent(id)
            if e and not e.flags.created_by_effect then out[#out + 1] = id end
        end
    end
    return out
end

function E:holds_race(seat, race)
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and hasRace(d.races, race) then return true end
    end
    return false
end

function E:controls_race(seat, race)
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e and e.health > 0 then
            local d = self:def_of(id)
            if d and hasRace(d.races, race) then return true end
        end
    end
    return false
end

function E:effect_has_target_filter(fx)
    -- A quest's filters (its origin among them) name what its goal counts (run 16), never its own target.
    if fx.op == "QUEST" then return false end
    return fx.type_filter ~= 0 or fx.costMin ~= 0 or fx.costMax ~= 0 or fx.raceFilterBits ~= 0
        or fx.keywordFilterBits ~= 0 or fx.familyFilter ~= 0 or fx.rarityFilter ~= 0 or fx.excludeSource
        or fx.damagedOnly or fx.undamagedOnly or fx.frozenOnly or fx.excludeRaceBits ~= 0 or fx.traitFilterNum ~= 0
        or fx.origin ~= 0
        or fx.op == "TRIGGER_DEATHRATTLE"   -- "a random friendly minion's Deathrattle": one that has one
end

function E:target_matches_filters(id, fx, source)
    -- A quest's filters name what its goal counts (run 16): its own target is never filtered.
    if fx.op == "QUEST" then return true end
    -- On a transform with no token the card filters name the POOL it draws from, not what it transforms. A copy
    -- transform's filters DO narrow its targets: its model is the target, not a pool.
    if fx.op == "TRANSFORM" and fx.token == "" and fx.copyFrom == 0 and (fx.type_filter ~= 0 or fx.costMin ~= 0
        or fx.costMax ~= 0 or fx.raceFilterBits ~= 0 or fx.keywordFilterBits ~= 0 or fx.familyFilter ~= 0
        or fx.rarityFilter ~= 0) then
        local only = copyEffect(fx)
        only.type_filter, only.costMin, only.costMax, only.raceFilterBits = 0, 0, 0, 0
        only.keywordFilterBits, only.familyFilter, only.rarityFilter = 0, 0, 0
        return self:target_matches_filters(id, only, source)
    end
    -- "Trigger the Deathrattle of a random friendly minion": among the minions that have one.
    if fx.op == "TRIGGER_DEATHRATTLE" and fx.target.kind == "RANDOM" and not self:has_deathrattle(id) then
        return false
    end
    -- "Transform your Treants", "destroy a friendly Lackey": a name (a family with nameFamily) narrows the targets.
    if fx.targetName ~= "" then
        local named = self:def_of(id)
        if not named or not D.cardIsNamed(named, fx.targetName, fx.nameFamily) then return false end
    end
    local entity = self:ent(id)
    if entity then
        if not self:stats_admit(fx, entity.attack, entity.health, source) then return false end
        if not E.origin_matches(fx, entity) then return false end
        -- "Give all ARCANE spells in your hand Spell Damage +1": a school on a card in the hand or deck.
        if fx.schoolFilter ~= 0 and (entity.zone == ZONE.HAND or entity.zone == ZONE.DECK) then
            local sd = self:def_of(id)
            if not sd or sd.type ~= "SPELL" or sd.schoolNum + 1 ~= fx.schoolFilter then return false end
        end
    end
    if not self:effect_has_target_filter(fx) then return true end
    local e = self:ent(id)
    if not e then return false end
    local d = self:def_of(id)
    local healthOnly = fx.type_filter == 0 and fx.costMin == 0 and fx.costMax == 0 and fx.raceFilterBits == 0
        and fx.keywordFilterBits == 0 and fx.familyFilter == 0 and fx.rarityFilter == 0
    if not d and not healthOnly then return false end
    if d and not E.card_matches_filters(d, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits,
        fx.familyFilter, fx.rarityFilter) then
        return false
    end
    if d and fx.excludeRaceBits ~= 0 and hasRace(d.races, fx.excludeRaceBits) then return false end
    -- "Destroy ALL odd-Attack minions": the Attack a minion has now, not its printed one.
    if fx.traitFilterNum == D.TRAIT.oddAttack and e.zone == ZONE.BOARD then
        if e.attack % 2 ~= 1 then return false end
    elseif fx.traitFilterNum ~= 0 and (not d or not E.card_has_trait(d, fx.traitFilterNum,
        self:player(e.controller).hero_class, e.keywords)) then
        return false
    end
    if fx.keywordFilterBits ~= 0 and band(e.keywords, fx.keywordFilterBits) ~= fx.keywordFilterBits then return false end
    if fx.excludeSource and id == source then return false end
    if fx.damagedOnly and e.health >= e.max_health then return false end
    if fx.undamagedOnly and e.health < e.max_health then return false end
    if fx.frozenOnly and not e.flags.frozen then return false end
    return true
end

function E:holds_type_cost(seat, typeFilter, minCost)
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and (typeFilter == 0 or d.typeNum + 1 == typeFilter) and self:card_cost(seat, id) >= minCost then
            return true
        end
    end
    return false
end

-- ---- conditions --------------------------------------------------------------------------------

local CONDITIONS = {}

function E:condition_holds(fx, controller, source, previousTarget)
    local c = fx.condition
    if c == "NONE" or c == "" then return true end
    local handler = CONDITIONS[c]
    if handler then
        return handler(self, fx, controller, source, previousTarget or 0)
    end
    return true -- the reference switch falls through to true for an unlisted value
end

CONDITIONS.HOLDING_RACE = function(self, fx, controller) return self:holds_race(controller, fx.conditionRaceBits) end
local function targetIs(self, fx, controller, source, previous)
    local d = previous ~= 0 and self:def_of(previous) or nil
    if not d then return false end
    if fx.condition == "TARGET_IS_RACE" then return hasRace(d.races, fx.conditionRaceBits) end
    if fx.condition == "TARGET_IS_TYPE" then return d.typeNum == fx.conditionType - 1 end
    return fx.conditionSchoolNum ~= 0 and d.schoolNum == fx.conditionSchoolNum - 1
end
CONDITIONS.TARGET_IS_RACE = targetIs
CONDITIONS.TARGET_IS_TYPE = targetIs
CONDITIONS.TARGET_IS_SCHOOL = targetIs
CONDITIONS.FINALE = function(self) return self.play_spent_last_mana end
CONDITIONS.MANATHIRST = function(self, fx, c) return self:player(c).max_mana >= fx.conditionAmount end
local function infuse(self, fx, c, source)
    local e = self:ent(source)
    return e ~= nil and e.flags.infuse_progress >= fx.conditionAmount
end
CONDITIONS.INFUSE = infuse
CONDITIONS.INFUSE_PROGRESS = infuse
CONDITIONS.RESTORED_HEALTH_THIS_TURN = function(self, fx, c) return self:player(c).restored_health_this_turn end
CONDITIONS.CAST_SPELL_THIS_TURN = function(self, fx, c) return self:player(c).cast_spell_this_turn end
CONDITIONS.PLAYED_CARD_THIS_TURN = function(self, fx, c) return self:player(c).cards_played_this_turn > 0 end
CONDITIONS.CONTROL_OTHER_RACE = function(self, fx, c, source)
    for _, id in ipairs(self:board_ids(c)) do
        if id ~= source then
            local d = self:def_of(id)
            if d and hasRace(d.races, fx.conditionRaceBits) then return true end
        end
    end
    return false
end
CONDITIONS.QUICKDRAW = function(self, fx, c, source)
    local src = self:ent(source)
    return src ~= nil and src.flags.drawn_this_turn
end
CONDITIONS.CONTROL_KEYWORD = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local e = self:ent(id)
        if e then
            local have = e.keywords
            have = e.flags.stealth and bor(have, KW.STEALTH) or band(have, bnot(KW.STEALTH))
            have = e.flags.divine_shield and bor(have, KW.DIVINE_SHIELD) or band(have, bnot(KW.DIVINE_SHIELD))
            if e.spell_damage > 0 then have = bor(have, KW.SPELL_DAMAGE) end
            if band(have, fx.conditionKeywordBits) == fx.conditionKeywordBits then return true end
        end
    end
    return false
end
CONDITIONS.HOLDING_SCHOOL = function(self, fx, c, source)
    local school = fx.conditionSchoolNum - 1
    for _, id in ipairs(self:hand_ids(c)) do
        if id ~= source then
            local d = self:def_of(id)
            if d and d.type == "SPELL" and d.schoolNum == school then return true end
        end
    end
    return false
end
CONDITIONS.HOLDING_OTHER_CLASS = function(self, fx, c, source)
    local mine = self:player(c).hero_class
    for _, id in ipairs(self:hand_ids(c)) do
        if id ~= source then
            local d = self:def_of(id)
            if d and d.family ~= "NEUTRAL" and d.familyNum ~= mine then return true end
        end
    end
    return false
end
CONDITIONS.CONTROL_RACE = function(self, fx, c) return self:controls_race(c, fx.conditionRaceBits) end
CONDITIONS.SELF_ATTACK_AT_LEAST = function(self, fx, c, source)
    local e = self:ent(source)
    return e ~= nil and e.attack >= fx.conditionAmount
end
CONDITIONS.HEALTH_AT_MOST = function(self, fx, c)
    local hero = self:hero_of(c)
    return hero ~= nil and hero.health <= fx.conditionAmount
end
CONDITIONS.ARMOR_AT_LEAST = function(self, fx, c)
    local hero = self:hero_of(c)
    return hero ~= nil and hero.armor >= fx.conditionAmount
end
local function manaAtLeast(self, fx, c) return self:player(c).max_mana >= fx.conditionAmount end
CONDITIONS.MANA_CRYSTALS_AT_LEAST = manaAtLeast
CONDITIONS.MANA_AT_LEAST = manaAtLeast
CONDITIONS.HAND_EMPTY = function(self, fx, c, source)
    for _, id in ipairs(self:hand_ids(c)) do
        if id ~= source then
            local d = self:def_of(id)
            if d and d.id ~= D.COIN_ID then return false end
        end
    end
    return true
end
CONDITIONS.DECK_EMPTY = function(self, fx, c) return #self:deck_ids(c) == 0 end
CONDITIONS.HAS_WEAPON = function(self, fx, c)
    local w = self:ent(self:player(c).weapon_id)
    return w ~= nil and w.zone == ZONE.WEAPON
end
CONDITIONS.PLAYED_RACE_LAST_TURN = function(self, fx, c)
    return band(self:player(c).play_tribes_last_turn, fx.conditionRaceBits) ~= 0
end
CONDITIONS.HOLDING_TYPE_COST = function(self, fx, c) return self:holds_type_cost(c, fx.conditionType, fx.conditionAmount) end
CONDITIONS.HELD_DISTINCT_SCHOOLS_AT_LEAST = function(self, fx, c, source)
    local e = self:ent(source)
    return e ~= nil and popcount(e.held_school_mask) >= fx.conditionAmount
end
CONDITIONS.HERO_TOOK_DAMAGE_THIS_TURN = function(self, fx, c) return self:player(c).hero_took_damage_this_turn end
CONDITIONS.CONTROL_SECRET = function(self, fx, c) return #self:player(c).secrets > 0 end
CONDITIONS.DECK_STARTED_NO_DUPLICATES = function(self, fx, c) return self:player(c).started_no_duplicates end
CONDITIONS.KINDRED = function(self, fx, c, source)
    local sc = self:def_of(source)
    if not sc then return false end
    local p = self:player(c)
    local tribes, mine = p.play_tribes_last_turn, sc.races
    if mine ~= 0 and tribes ~= 0 and (band(tribes, RACE.ALL) ~= 0 or band(mine, RACE.ALL) ~= 0 or band(tribes, mine) ~= 0) then
        return true
    end
    return sc.type == "SPELL" and sc.schoolNum ~= 0 and band(p.play_schools_last_turn, bit.lshift(1, sc.schoolNum)) ~= 0
end
CONDITIONS.OUTCAST = function(self, fx, c, source)
    local card = self:ent(source)
    if card and card.zone == ZONE.HAND then
        local hand = self:hand_ids(card.owner)
        return #hand > 0 and (hand[1] == source or hand[#hand] == source)
    end
    return self.play_was_outcast
end
CONDITIONS.COMBO = function(self, fx, c) return self:player(c).cards_played_this_turn > 1 end
CONDITIONS.OVERLOADED = function(self, fx, c) return self:player(c).overload_locked > 0 end
CONDITIONS.OPPONENT_HEALTH_AT_MOST = function(self, fx, c)
    local h = self:hero_of(other(c))
    return h ~= nil and h.health <= fx.conditionAmount
end
CONDITIONS.ENEMY_MINION_FROZEN = function(self, fx, c)
    local h = self:hero_of(other(c))
    if h and h.flags.frozen then return true end
    for _, id in ipairs(self:board_ids(other(c))) do
        local e = self:ent(id)
        if e and (e.flags.frozen or band(e.keywords, KW.FREEZE) ~= 0) then return true end
    end
    return false
end
CONDITIONS.CAST_SPELL_LAST_TURN = function(self, fx, c) return self:player(c).cast_spell_last_turn end
CONDITIONS.HERO_ATTACKED_THIS_TURN = function(self, fx, c)
    local h = self:hero_of(c)
    return h ~= nil and h.flags.attacks_this_turn > 0
end
CONDITIONS.HERO_POWER_USED_THIS_TURN = function(self, fx, c) return self:player(c).hero_power_uses > 0 end
CONDITIONS.HERO_HEALTH_CHANGED_THIS_TURN = function(self, fx, c) return self:player(c).hero_health_changed_this_turn end
CONDITIONS.CONTROL_FROZEN_MINION = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local e = self:ent(id)
        if e and e.flags.frozen then return true end
    end
    return false
end
CONDITIONS.DAMAGED_MINION_EXISTS = function(self)
    for seat = 0, 1 do
        for _, id in ipairs(self:board_ids(seat)) do
            local e = self:ent(id)
            if e and e.health < e.max_health then return true end
        end
    end
    return false
end
CONDITIONS.DECK_AT_LEAST = function(self, fx, c) return #self:deck_ids(c) >= fx.conditionAmount end
CONDITIONS.OPPONENT_HAND_EMPTY = function(self, fx, c) return #self:hand_ids(other(c)) == 0 end
CONDITIONS.OPPONENT_HAND_AT_LEAST = function(self, fx, c) return #self:hand_ids(other(c)) >= fx.conditionAmount end
CONDITIONS.ANY_HERO_TOOK_DAMAGE_THIS_TURN = function(self)
    return self.state.players[1].hero_took_damage_this_turn or self.state.players[2].hero_took_damage_this_turn
end
CONDITIONS.HOLDING_ANOTHER_COST = function(self, fx, c, source)
    for _, id in ipairs(self:hand_ids(c)) do
        if id ~= source and self:card_cost(c, id) == fx.conditionAmount then return true end
    end
    return false
end
CONDITIONS.EXCAVATED = function(self, fx, c) return self:player(c).excavate_count >= fx.conditionAmount end
CONDITIONS.TARGET_IS_CONTROLLED_RACE = function(self, fx, c, source, previous)
    if previous == 0 then return false end
    local prev = self:ent(previous)
    if not prev or prev.controller ~= c then return false end
    local d = self:def_of(previous)
    return d ~= nil and hasRace(d.races, fx.conditionRaceBits)
end
CONDITIONS.BUILDING_STARSHIP = function(self, fx, c) return self:player(c).starship_building end
CONDITIONS.CONTROL_LOCATION = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local d = self:def_of(id)
        if d and d.type == "LOCATION" then return true end
    end
    return false
end
CONDITIONS.WEAPON_ATTACK_AT_LEAST = function(self, fx, c)
    local w = self:ent(self:player(c).weapon_id)
    return w ~= nil and w.attack >= fx.conditionAmount
end
CONDITIONS.ENEMY_CONTROL_RACE = function(self, fx, c)
    for _, id in ipairs(self:board_ids(other(c))) do
        local d = self:def_of(id)
        if d and hasRace(d.races, fx.conditionRaceBits) then return true end
    end
    return false
end
CONDITIONS.ENEMY_MINIONS_AT_LEAST = function(self, fx, c) return #self:board_ids(other(c)) >= fx.conditionAmount end
CONDITIONS.SPELLS_CAST_AT_LEAST = function(self, fx, c) return self:player(c).spells_cast_this_turn >= fx.conditionAmount end
CONDITIONS.ARMOR_CHANGED_THIS_TURN = function(self, fx, c) return self:player(c).armor_changed_this_turn end
CONDITIONS.FRIENDLY_RACE_DIED_THIS_TURN = function(self, fx, c)
    return band(self:player(c).friendly_deaths_by_tribe, fx.conditionRaceBits) ~= 0
end
CONDITIONS.FRIENDLY_MINION_DIED_THIS_TURN = function(self, fx, c) return self:player(c).friendly_minions_died_this_turn > 0 end
CONDITIONS.HAS_SPELL_DAMAGE = function(self, fx, c) return self:spell_damage_of(c) > 0 end
CONDITIONS.CONTROL_MINION_HEALTH_AT_LEAST = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local e = self:ent(id)
        if e and e.health >= fx.conditionAmount then return true end
    end
    return false
end
CONDITIONS.CONTROL_MINION_ATTACK_AT_LEAST = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local e = self:ent(id)
        if e and e.attack >= fx.conditionAmount then return true end
    end
    return false
end
CONDITIONS.PLAYED_SCHOOL_THIS_TURN = function(self, fx, c)
    return fx.conditionSchoolNum > 0
        and band(self:player(c).schools_cast_this_turn, bit.lshift(1, fx.conditionSchoolNum - 1)) ~= 0
end
CONDITIONS.CORRUPTED = function(self, fx, c, source)
    local e = self:ent(source)
    return e ~= nil and e.flags.corrupted
end
CONDITIONS.JOUST_WON = function(self, fx, c)
    local function randomMinion(who)
        local pool = {}
        for _, id in ipairs(self:deck_ids(who)) do
            local d = self:def_of(id)
            if d and d.type == "MINION" then pool[#pool + 1] = id end
        end
        if #pool == 0 then return 0 end
        return pool[self.state.rng:intBelow(#pool) + 1]
    end
    local mine = randomMinion(c)
    local theirs = randomMinion(other(c))
    if mine == 0 then return false end
    if theirs == 0 then return true end
    return self:card_cost(c, mine) > self:card_cost(other(c), theirs)
end
CONDITIONS.ENEMY_MINION_TAUNT = function(self, fx, c)
    for _, id in ipairs(self:board_ids(other(c))) do
        local e = self:ent(id)
        if e and band(e.keywords, KW.TAUNT) ~= 0 then return true end
    end
    return false
end

-- Minions only: a location in play is no minion (run wave 79; CS3_002's reviewer counted one).
CONDITIONS.OTHER_MINIONS_AT_LEAST = function(self, fx, c, source)
    local board = 0
    for _, id in ipairs(self:board_ids(c)) do
        if not self:is_location(id) then board = board + 1 end
    end
    local src = self:ent(source)
    local mine = (src and src.zone == ZONE.BOARD and src.controller == c) and 1 or 0
    return board - mine >= fx.conditionAmount
end
CONDITIONS.DECK_NO_DUPLICATES = function(self, fx, c)
    local deck = self:deck_scan_ids(c)
    for i = 1, #deck do
        local a = self:def_of(deck[i])
        if a then
            for j = i + 1, #deck do
                local b = self:def_of(deck[j])
                if b and b.id == a.id then return false end
            end
        end
    end
    return true
end
CONDITIONS.OPPONENT_TURN = function(self, fx, c) return self:turn_owner() ~= c end
CONDITIONS.YOUR_TURN = function(self, fx, c) return self:turn_owner() == c end
CONDITIONS.DECK_NO_NEUTRAL = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d and d.family == "NEUTRAL" then return false end
    end
    return true
end
CONDITIONS.DECK_NO_COST = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d and d.cost == fx.conditionAmount then return false end
    end
    return true
end
CONDITIONS.HELD_SPELLS_AT_LEAST = function(self, fx, c, source)
    local held = self:ent(source)
    if not held then return false end
    -- "If you've cast a Nature spell while holding this": a school asks for that school's bit.
    if fx.conditionSchoolNum > 0 then
        return band(held.held_school_mask, bit.lshift(1, fx.conditionSchoolNum - 1)) ~= 0
    end
    return held.held_spells_cast >= fx.conditionAmount
end
CONDITIONS.HELD_PLAYED_RACE = function(self, fx, c, source)
    local held = self:ent(source)
    return held ~= nil and held.held_minions_played > 0 and hasRace(held.held_race_mask, fx.conditionRaceBits)
end
CONDITIONS.HELD_PLAYED_MINION = function(self, fx, c, source)
    local held = self:ent(source)
    return held ~= nil and held.held_minions_played > 0
end
CONDITIONS.HELD_HIGHER_COST = function(self, fx, c, source)
    local held = self:ent(source)
    return held ~= nil and held.held_higher_cost
end
-- "Costs (1) if you control a Legendary card": a minion, weapon or hero of the controller's.
CONDITIONS.CONTROL_LEGENDARY = function(self, fx, c, source)
    local mine = self:board_ids(c)
    local list = {}
    for i, id in ipairs(mine) do list[i] = id end
    list[#list + 1] = self:player(c).weapon_id
    for _, id in ipairs(list) do
        local d = self:def_of(id)
        if d and id ~= source and d.rarity == "LEGENDARY" then return true end
    end
    return false
end
CONDITIONS.HERO_ATTACK_AT_LEAST = function(self, fx, c)
    local hero = self:hero_of(c)
    return hero ~= nil and hero.attack >= fx.conditionAmount
end
-- A location is not a minion (JAIL_204 paid 5 with only a location in play).
CONDITIONS.NO_MINIONS_IN_PLAY = function(self, fx, c, source)
    for seat = 0, 1 do
        for _, id in ipairs(self:board_ids(seat)) do
            if id ~= source and not self:is_location(id) then return false end
        end
    end
    return true
end
CONDITIONS.NO_ARMOR = function(self, fx, c)
    local hero = self:hero_of(c)
    return hero == nil or hero.armor == 0
end
CONDITIONS.CHARACTER_FROZEN = function(self)
    for seat = 0, 1 do
        local hero = self:hero_of(seat)
        if hero and hero.flags.frozen then return true end
        for _, id in ipairs(self:board_ids(seat)) do
            local e = self:ent(id)
            if e and e.flags.frozen then return true end
        end
    end
    return false
end
CONDITIONS.CONTROL_DAMAGED_MINION = function(self, fx, c)
    for _, id in ipairs(self:board_ids(c)) do
        local e = self:ent(id)
        if e and e.health < e.max_health then return true end
    end
    return false
end
CONDITIONS.MINION_DORMANT = function(self)
    for seat = 0, 1 do
        for _, id in ipairs(self:board_ids(seat)) do
            local e = self:ent(id)
            if e and e.flags.dormant_turns > 0 then return true end
        end
    end
    return false
end
CONDITIONS.HAND_FULL = function(self, fx, c) return #self:hand_ids(c) >= 10 end
CONDITIONS.HAND_AT_LEAST = function(self, fx, c) return #self:hand_ids(c) >= fx.conditionAmount end
CONDITIONS.SELF_FULL_HEALTH = function(self, fx, c, source)
    local me = self:ent(source)
    return me ~= nil and me.health >= me.max_health
end
CONDITIONS.SELF_DAMAGED = function(self, fx, c, source)
    local me = self:ent(source)
    return me ~= nil and me.health < me.max_health
end
CONDITIONS.SELF_DORMANT = function(self, fx, c, source)
    local me = self:ent(source)
    return me ~= nil and me.flags.dormant_turns > 0
end
-- "50% chance to draw another" (run wave 92): rolled each time the line runs.
CONDITIONS.CHANCE = function(self, fx) return self.state.rng:intBelow(100) < fx.conditionAmount end
-- "If this costs (3) or less": the price this card was played for (its current Cost when it is not the card being
-- played, e.g. a Deathrattle read later).
CONDITIONS.PAID_COST_AT_MOST = function(self, fx, c, source)
    local me = self:ent(source)
    if not me then return false end
    local paid
    if source == self.last_paid_entity and self.last_paid_price >= 0 then
        paid = self.last_paid_price
    elseif me.paid_price >= 0 then
        paid = me.paid_price
    else
        paid = self:card_cost(me.controller, source)
    end
    return paid <= fx.conditionAmount
end
CONDITIONS.TARGET_IS_FROZEN = function(self, fx, c, source, previous)
    local it = previous ~= 0 and self:ent(previous) or nil
    return it ~= nil and it.flags.frozen
end
-- Run 16: "If you control a Quest", "if you played a Quest this game".
CONDITIONS.CONTROL_QUEST = function(self, fx, c) return #self:player(c).quests > 0 end
CONDITIONS.PLAYED_QUEST = function(self, fx, c) return self:player(c).game_quests_played > 0 end
-- Run 16, Start of Game: "if the spells in your deck are all Shadow" (a deck with no spell holds it) and "if your
-- deck only has cards that cost (3) or less", by printed Cost, over the deck deck_scan_ids reads.
CONDITIONS.DECK_SPELLS_SCHOOL = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d and d.type == "SPELL" and d.schoolNum + 1 ~= fx.conditionSchoolNum then return false end
    end
    return true
end
CONDITIONS.DECK_COST_AT_MOST = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d and d.cost > fx.conditionAmount then return false end
    end
    return true
end
-- "If this is the only minion on the BATTLEFIELD": both boards, and locations are no minions.
CONDITIONS.ONLY_MINION = function(self, fx, c)
    local minions = 0
    for _, seat in ipairs({ c, other(c) }) do
        for _, id in ipairs(self:board_ids(seat)) do
            if not self:is_location(id) then minions = minions + 1 end
        end
    end
    return minions == 1
end
CONDITIONS.DECK_NO_TYPE = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d and d.typeNum + 1 == fx.conditionType then return false end
    end
    return true
end
CONDITIONS.DECK_ONLY_PARITY = function(self, fx, c)
    for _, id in ipairs(self:deck_scan_ids(c)) do
        local d = self:def_of(id)
        if d then
            local odd = d.cost % 2 ~= 0
            if (fx.conditionAmount == 1) ~= odd then return false end
        end
    end
    return true
end
-- "If a minion died this turn": either player's.
CONDITIONS.MINION_DIED_THIS_TURN = function(self, fx, c)
    return self:player(c).minions_died_this_turn + self:player(other(c)).minions_died_this_turn > 0
end
-- A location shares the board but is no minion: "if you control no other minions" holds beside one.
CONDITIONS.CONTROL_NO_OTHER_MINIONS = function(self, fx, c)
    local minions = 0
    for _, id in ipairs(self:board_ids(c)) do
        if not self:is_location(id) then minions = minions + 1 end
    end
    return minions == 1
end
-- "If you control a Treant": a NAMED_ON_BOARD count reads the effect's costCountName (and its family). A play-history
-- or death count reads the effect's filter, and "other" knows the card by its source.
CONDITIONS.GAME_COUNT = function(self, fx, c, source)
    local name = TC.CostCounts[fx.conditionType + 1] or "NONE"
    local who = (E.is_history_count(name) or fx.historyOther) and source or 0
    return self:count_for(c, name, fx.conditionRaceBits, who, fx.costCountName, 0, fx.nameFamily, fx)
        >= fx.conditionAmount
end

-- ---- counts ------------------------------------------------------------------------------------


local COUNT_FRIENDLY = { FRIENDLY_CHARACTER = true, FRIENDLY_MINION = true, FRIENDLY_MINIONS = true,
    FRIENDLY_HAND = true, FRIENDLY_HAND_MINIONS = true, YOUR_HERO = true, YOUR_WEAPON = true }
local COUNT_ENEMY = { ENEMY_CHARACTER = true, ENEMY_MINION = true, ENEMY_MINIONS = true, ENEMY_HERO = true,
    ENEMY_HAND = true, ENEMY_HAND_MINIONS = true }

function E:count_for_selector(fx, controller, source)
    local friendly, enemy = COUNT_FRIENDLY[fx.countSide], COUNT_ENEMY[fx.countSide]
    if not friendly and not enemy then friendly, enemy = true, true end
    local ids = {}
    local zone = fx.countZone ~= "" and fx.countZone or "BOARD"
    local function addSeat(seat)
        local list
        if zone == "BOARD" then list = self:board_ids(seat)
        elseif zone == "HAND" then list = self:hand_ids(seat)
        elseif zone == "DECK" then list = self:deck_ids(seat)
        else
            list = {}
            local s = self.state
            for id = 1, s.next_entity_id - 1 do
                local e = s.entities[id]
                if e.owner == seat and e.zone == ZONE.GRAVEYARD then list[#list + 1] = id end
            end
        end
        for _, id in ipairs(list) do ids[#ids + 1] = id end
    end
    if friendly then addSeat(controller) end
    if enemy then addSeat(other(controller)) end
    local count = 0
    for _, id in ipairs(ids) do
        if not (fx.countExcludeSource and id == source) then
            local e, d = self:ent(id), self:def_of(id)
            if e and d and (fx.countType == 0 or d.typeNum + 1 == fx.countType)
                and (fx.countRaceBits == 0 or hasRace(d.races, fx.countRaceBits))
                and (fx.countKeywordBits == 0 or band(d.keywords, fx.countKeywordBits) == fx.countKeywordBits)
                and not (fx.countDamagedOnly and e.health >= e.max_health) then
                count = count + 1
            end
        end
    end
    return count
end

local TARGET_VALUES = { TARGET_ATTACK = true, TARGET_HEALTH = true, TARGET_MAX_HEALTH = true, TARGET_COST = true,
    PREVIOUS_ATTACK = true, PREVIOUS_HEALTH = true, PREVIOUS_COST = true }
local CREATES = { SUMMON = true, SUMMON_RANDOM = true, SUMMON_COPY = true, ADD_TO_HAND = true, DISCOVER = true }

local TARGET_VALUES = { TARGET_ATTACK = true, TARGET_HEALTH = true, TARGET_MAX_HEALTH = true, TARGET_COST = true,
    PREVIOUS_ATTACK = true, PREVIOUS_HEALTH = true, PREVIOUS_COST = true, PREVIOUS_STATS = true }
local CREATES = { SUMMON = true, SUMMON_RANDOM = true, SUMMON_COPY = true, ADD_TO_HAND = true, DISCOVER = true }

function E:scaled_effect(fx, controller, source)
    local out = fx
    local vs = fx.valueSource
    if TARGET_VALUES[vs] then return fx end
    if vs ~= "NONE" and vs ~= "" then
        local value = 0
        local second = 0      -- a pair's Health
        local pair = false
        local src = self:ent(source)
        local p = self:player(controller)
        if vs == "SELF_ATTACK" then value = src and src.attack or 0
        elseif vs == "SELF_HEALTH" then value = src and src.health or 0
        elseif vs == "SELF_MAX_HEALTH" then value = src and src.max_health or 0
        elseif vs == "SELF_COST" then value = src and self:card_cost(controller, source) or 0
        elseif vs == "HERO_ATTACK" then local h = self:ent(p.hero_id) value = h and h.attack or 0
        elseif vs == "HERO_HEALTH" then local h = self:ent(p.hero_id) value = h and h.health or 0
        elseif vs == "HERO_ARMOR" then local h = self:ent(p.hero_id) value = h and h.armor or 0
        elseif vs == "HAND_SIZE" then value = #self:hand_ids(controller)
        elseif vs == "BOARD_SIZE" then value = #self:board_ids(controller)
        elseif vs == "ENEMY_BOARD_SIZE" then value = #self:board_ids(other(controller))
        elseif vs == "CORPSES" then value = p.corpses
        elseif vs == "MANA" then value = p.mana
        elseif vs == "MAX_MANA" then value = p.max_mana
        elseif vs == "EVENT_AMOUNT" then value = self.event_amount
        elseif vs == "EXCESS_DAMAGE" then value = self.last_excess
        elseif vs == "PREVIOUS_AMOUNT" or vs == "PREVIOUS_MUCH" then value = self.last_effect_count
        -- The pairs: Attack into Attack, Health (a weapon's Durability) into Health.
        elseif vs == "SELF_STATS" then
            pair = true
            value = src and src.attack or 0
            second = src and src.health or 0
        elseif vs == "WEAPON_STATS" then
            pair = true
            local w = p.weapon_id ~= 0 and self:ent(p.weapon_id) or nil
            if w then
                value = w.attack
                second = w.durability
            end
        elseif vs == "WEAPON_ATTACK" then
            local w = p.weapon_id ~= 0 and self:ent(p.weapon_id) or nil
            if w then value = w.attack end
        end
        out = copyEffect(fx)
        if fx.op == "DISCOVER" then
            out.costMin, out.costMax, out.valueSource = value, value, "NONE"
            return out
        end
        if fx.op == "SUMMON_RANDOM" then
            -- "With Cost equal to your Armor (up to 10)": the program's costMax caps the read value.
            if fx.costMax > 0 then value = min(value, fx.costMax) end
            out.costMin, out.costMax = value, value
            -- The bound is exact, 0 included.
            out.resolvedCost = max(0, value)
            out.amount, out.valueSource = 0, "NONE"
            return out
        end
        if (vs == "PREVIOUS_AMOUNT" or vs == "PREVIOUS_MUCH")
            and (fx.op == "SUMMON" or fx.op == "SUMMON_COPY" or fx.op == "SUMMON_FROM_DECK") then
            out["repeat"] = value < 0 and 0 or value
            out.amount = 0
        else
            out.amount = value
            -- "Your next Mech costs that much less" (MIS_902): a cost cut by a value keeps the program's sign.
            if fx.op == "CARD_COST" and fx.amount < 0 then out.amount = -value end
            if pair then
                out.amount2 = second
                out.pairValue = true
            elseif fx.statsBoth then
                out.amount2 = value
            end
            if fx.healthOnly and not pair then
                out.amount2 = value
                out.amount = 0
            end
        end
        out.valueSource = "NONE"
    end
    if fx.countSelector then
        local count = self:count_for_selector(fx, controller, source)
        out = copyEffect(fx)
        out.countSelector = false
        if CREATES[fx.op] then
            out["repeat"] = (fx["repeat"] < 1 and 1 or fx["repeat"]) * count
        else
            out.amount = fx.amount * count
            out.amount2 = fx.op == "CARD_COST" and fx.amount2 or fx.amount2 * count
        end
        return out
    end
    if fx.amountSource == "NONE" or fx.amountSource == "" then return out end
    local count = self:count_for(controller, fx.amountSource, fx.amountSourceRaceBits, source, fx.costCountName,
        fx.schoolFilter, fx.nameFamily, fx)
    out = copyEffect(fx)
    out.amountSource = "NONE"
    out.amountSourceRaceBits = 0
    if fx.improved then
        if fx.op == "SUMMON_RANDOM" or fx.op == "CAST_FROM" then
            out.costMin = fx.costMin + count
            out.costMax = fx.costMax + count
        else
            out.amount = fx.amount + count
            if fx.amount2 > 0 then out.amount2 = fx.amount2 + count end
        end
    elseif fx.repeatPerCount then
        out["repeat"] = (fx["repeat"] < 1 and 1 or fx["repeat"]) * count
    elseif fx.amountSource == "SELF_NUMBER" and CREATES[fx.op] and fx.costMin > 0 and fx.costMin == fx.costMax then
        out.costMin = fx.costMin * max(1, count)
        out.costMax = fx.costMax * max(1, count)
    elseif CREATES[fx.op] then
        out["repeat"] = (fx["repeat"] < 1 and 1 or fx["repeat"]) * count
    else
        out.amount = fx.amount * count
        out.amount2 = fx.op == "CARD_COST" and fx.amount2 or fx.amount2 * count
    end
    return out
end

function E:cost_count_value(seat, fx)
    return self:count_for(seat, fx.costCount, fx.costCountRaceBits, 0, fx.costCountName, fx.schoolFilter,
        fx.nameFamily, fx)
end

local function bareName(v)
    v = v:lower()
    if v:sub(1, 4) == "the " then v = v:sub(5) end
    return v
end

local COUNT = {}

-- `family` and `filter` (the effect) are optional: a name family counts every card whose name holds the word, and a
-- history count reads the effect's own filter.
local NO_FILTER = copyEffect({})

function E:count_for(seat, source, race, sourceEntity, name, school, family, filter)
    if source == "NONE" or source == "" then return 1 end
    -- What this player did this game (the play history, the friendly deaths), through the effect's filter.
    if E.is_history_count(source) then
        local who = self:player(seat)
        local me = self:ent(sourceEntity)
        local own = me and me.card_id or ""
        local f = filter or NO_FILTER
        name = name or ""
        -- The card itself is in the list already: "other" skips it once, and a count of minion types never counts it.
        local skipSelf = own ~= "" and (f.historyOther or source == "HISTORY_DISTINCT_TYPES")
        if source == "GAME_NAMED_DIED" then
            local count = 0
            -- "If Feugen also died this game": either player's (historyBoth), else the controller's own.
            local sides = { who }
            if f.historyBoth then sides[2] = self:player(other(seat)) end
            for _, side in ipairs(sides) do
                local list = side.last_destroyed_cards
                for i = #list, 1, -1 do
                    local d = def(list[i])
                    if d and name ~= "" and D.cardIsNamed(d, name, family) then
                        if skipSelf and side == who and list[i] == own then
                            skipSelf = false
                        else
                            count = count + 1
                        end
                    end
                end
            end
            return count
        end
        local count, mana = 0, 0
        local minionTypes = {}
        local history = who.played_history
        for i = #history, 1, -1 do
            local row = history[i]
            local d = def(row.card)
            if d and E.history_matches(d, row.paid, f, who.hero_class) then
                if skipSelf and row.card == own then
                    skipSelf = false
                else
                    count = count + 1
                    mana = mana + row.paid
                    if d.type == "MINION" and d.races ~= 0 then minionTypes[#minionTypes + 1] = d.races end
                end
            end
        end
        if source == "HISTORY_MANA_SPENT" then return mana end
        if source == "HISTORY_DISTINCT_TYPES" then return E.distinct_minion_types(minionTypes) end
        return count
    end
    local handler = COUNT[source]
    if not handler then return 1 end
    return handler(self, seat, self:player(seat), race, sourceEntity, name or "", school or 0, family or false, filter)
end

COUNT.MINIONS_DIED_THIS_TURN = function(self)
    return self.state.players[1].minions_died_this_turn + self.state.players[2].minions_died_this_turn
end
COUNT.CARDS_PLAYED_THIS_TURN = function(self, seat, p) return p.cards_played_this_turn end
COUNT.OTHER_CARDS_PLAYED_THIS_TURN = function(self, seat, p)
    return p.cards_played_this_turn > 1 and p.cards_played_this_turn - 1 or 0
end
COUNT.CARDS_DRAWN_THIS_TURN = function(self, seat, p) return p.cards_drawn_this_turn end
COUNT.HERO_DAMAGE_TAKEN_THIS_TURN = function(self, seat, p) return p.hero_damage_taken_this_turn end
COUNT.COMBO_CARDS_PLAYED_THIS_TURN = function(self, seat, p) return p.combo_cards_played_this_turn end
COUNT.SCHOOL_SPELLS_GAME = function(self, seat, p, race, se, name, school)
    if school <= 0 then return 0 end
    return p.spell_schools_game[school] or 0
end
COUNT.SCHOOL_SPELLS_TURN = function(self, seat, p, race, se, name, school)
    return (school > 0 and band(bit.rshift(p.schools_cast_this_turn, school - 1), 1) ~= 0) and 1 or 0
end
COUNT.SPELLS_CAST_THIS_TURN = function(self, seat, p) return p.spells_cast_this_turn end
COUNT.FRIENDLY_MINIONS = function(self, seat) return #self:board_ids(seat) end
COUNT.ENEMY_MINIONS = function(self, seat) return #self:board_ids(other(seat)) end
COUNT.OTHER_CARDS_IN_HAND = function(self, seat, p, race, sourceEntity)
    local hand = #self:hand_ids(seat)
    local selfE = self:ent(sourceEntity)
    local held = sourceEntity == 0 or (selfE ~= nil and selfE.zone == ZONE.HAND)
    return held and max(0, hand - 1) or hand
end
COUNT.ARMOR_YOU_HAVE = function(self, seat)
    local h = self:hero_of(seat)
    return h and h.armor or 0
end
COUNT.SPELLS_IN_HAND = function(self, seat)
    local n = 0
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and d.type == "SPELL" then n = n + 1 end
    end
    return n
end
COUNT.FRIENDLY_MINIONS_OF_RACE = function(self, seat, p, race)
    local n = 0
    for _, id in ipairs(self:board_ids(seat)) do
        local d = self:def_of(id)
        if d and hasRace(d.races, race) then n = n + 1 end
    end
    return n
end
COUNT.WEAPON_ATTACK = function(self, seat, p)
    local w = p.weapon_id ~= 0 and self:ent(p.weapon_id) or nil
    return w and w.attack or 0
end
COUNT.HERO_ATTACK = function(self, seat)
    local h = self:hero_of(seat)
    return h and h.attack or 0
end
COUNT.HERO_MISSING_HEALTH = function(self, seat)
    local h = self:hero_of(seat)
    return h and max(0, h.max_health - h.health) or 0
end
COUNT.OPPONENT_CARDS_IN_HAND = function(self, seat) return #self:hand_ids(other(seat)) end
COUNT.FROZEN_ENEMIES = function(self, seat)
    local n = 0
    for _, id in ipairs(self:board_ids(other(seat))) do
        local e = self:ent(id)
        if e and e.flags.frozen then n = n + 1 end
    end
    return n
end
COUNT.SECRETS_CONTROLLED = function(self, seat, p) return #p.secrets end
COUNT.CARDS_IN_HAND = function(self, seat) return #self:hand_ids(seat) end
COUNT.GAME_CARDS_PLAYED = function(self, seat, p) return p.game_cards_played end
COUNT.GAME_MINIONS_SUMMONED = function(self, seat, p) return p.game_minions_summoned end
COUNT.GAME_SPELLS_CAST = function(self, seat, p) return p.game_spells_cast end
COUNT.GAME_CARDS_DRAWN = function(self, seat, p) return p.game_cards_drawn end
COUNT.GAME_HERO_POWER_USES = function(self, seat, p) return p.game_hero_power_uses end
COUNT.GAME_FRIENDLY_MINIONS_DIED = function(self, seat, p) return p.game_minions_died end
COUNT.GAME_MINIONS_DIED = function(self)
    return self.state.players[1].game_minions_died + self.state.players[2].game_minions_died
end
COUNT.GAME_MANA_OVERLOADED = function(self, seat, p) return p.game_mana_overloaded end
COUNT.DECK_CARDS_NOT_FROM_DECK = function(self, seat)
    local n = 0
    for _, id in ipairs(self:deck_ids(seat)) do
        local e = self:ent(id)
        if e and e.flags.created_by_effect then n = n + 1 end
    end
    return n
end
COUNT.GAME_CARDS_PLAYED_NOT_FROM_DECK = function(self, seat, p) return p.game_cards_played_not_from_deck end
COUNT.GAME_CARDS_DISCARDED = function(self, seat, p) return p.game_cards_discarded end
COUNT.GAME_WEAPONS_EQUIPPED = function(self, seat, p) return p.game_weapons_equipped end
COUNT.GAME_SECRETS_PLAYED = function(self, seat, p) return p.game_secrets_played end
COUNT.GAME_STARSHIPS_LAUNCHED = function(self, seat, p) return p.game_starships_launched end
COUNT.ELEMENTALS_PLAYED_LAST_TURN = function(self, seat, p) return p.elementals_played_last_turn end
COUNT.GAME_SPELLS_COST_5_PLUS = function(self, seat, p) return p.game_spells_cost_5_plus end
COUNT.GAME_RELICS_PLAYED = function(self, seat, p) return p.game_relics_played end
COUNT.GAME_HERO_ATTACKS = function(self, seat, p) return p.game_hero_attacks end
COUNT.SCHOOLS_CAST_GAME = function(self, seat, p)
    local n = 0
    for _, x in ipairs(p.spell_schools_game) do
        if x > 0 then n = n + 1 end
    end
    return n
end
COUNT.ELEMENTAL_STREAK = function(self, seat, p) return p.elemental_streak end
COUNT.MINIONS_DYING = function(self)
    local n = 0
    for side = 0, 1 do
        for _, id in ipairs(self:board_ids(side)) do
            local e = self:ent(id)
            if e and (e.flags.dead or e.health <= 0) then n = n + 1 end
        end
    end
    return n
end
COUNT.GAME_NAMED_SUMMONED = function(self, seat, p, race, se, name)
    local part = name:lower()
    local n = 0
    if part ~= "" then
        local s = self.state
        for id = 1, s.next_entity_id - 1 do
            local e = s.entities[id]
            if e.owner == seat and e.play_order > 0 then
                local d = self:def_of(id)
                if d and d.type == "MINION" and d.name:lower():find(part, 1, true) then n = n + 1 end
            end
        end
    end
    return n
end
COUNT.GAME_NAMED_PLAYED = function(self, seat, p, race, sourceEntity, name)
    local want = name:lower()
    local n = 0
    if want ~= "" then
        local s = self.state
        for id = 1, s.next_entity_id - 1 do
            local e = s.entities[id]
            if id ~= sourceEntity and e.owner == seat then
                local d = self:def_of(id)
                if d and d.name:lower() == want then
                    local played = d.type == "SPELL" and e.zone == ZONE.GRAVEYARD or (d.type ~= "SPELL" and e.play_order > 0)
                    if played then n = n + 1 end
                end
            end
        end
    end
    return n
end
COUNT.SELF_NUMBER = function(self, seat, p, race, sourceEntity)
    local e = self:ent(sourceEntity)
    return e and e.number or 0
end
COUNT.GAME_EXCAVATES = function(self, seat, p) return p.excavates_this_game end
COUNT.GAME_ARMOR_GAINED = function(self, seat, p) return p.game_armor_gained end
COUNT.GAME_HEALTH_RESTORED = function(self, seat, p) return p.game_health_restored end
COUNT.GAME_HERO_POWER_DAMAGE = function(self, seat, p) return p.game_hero_power_damage end
COUNT.GAME_SECRETS_TRIGGERED = function(self, seat, p) return p.game_secrets_triggered end
COUNT.GAME_MINIONS_OF_RACE = function(self, seat, p, race)
    local n = 0
    for i = 1, #p.game_race_played do
        if band(race, bit.lshift(1, i - 1)) ~= 0 then n = n + p.game_race_played[i] end
    end
    return n
end
COUNT.OTHER_MINIONS_BATTLEFIELD = function(self, seat, p, race, sourceEntity)
    local count = #self:board_ids(0) + #self:board_ids(1)
    local src = self:ent(sourceEntity)
    if src and src.zone == ZONE.BOARD then count = count - 1 end
    for each = 0, 1 do
        for _, id in ipairs(self:board_ids(each)) do
            if self:is_location(id) then count = count - 1 end
        end
    end
    return max(0, count)
end
COUNT.OTHER_FRIENDLY_MINIONS = function(self, seat, p, race, sourceEntity)
    local board = #self:board_ids(seat)
    local src = self:ent(sourceEntity)
    local onBoard = src ~= nil and src.zone == ZONE.BOARD and src.controller == seat
    return onBoard and max(0, board - 1) or board
end

-- Case-blind and blind to a leading "The"; a family counts every card whose name holds the word.
local function sameName(d, name, family)
    if family then return D.cardIsNamed(d, name, true) end
    return name ~= "" and bareName(d.name) == bareName(name)
end
COUNT.NAMED_ON_BOARD = function(self, seat, p, race, se, name, school, family, filter)
    -- "For each OTHER Zerg minion you control" (historyOther). A location is not a minion.
    local otherOnly = filter ~= nil and filter.historyOther
    local n = 0
    for _, id in ipairs(self:board_ids(seat)) do
        local d = self:def_of(id)
        if d and not self:is_location(id) and sameName(d, name, family) and not (otherOnly and id == se) then
            n = n + 1
        end
    end
    return n
end
COUNT.NAMED_IN_HAND = function(self, seat, p, race, se, name, school, family, filter)
    local otherOnly = filter ~= nil and filter.historyOther
    local n = 0
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and sameName(d, name, family) and not (otherOnly and id == se) then n = n + 1 end
    end
    return n
end
-- "For each card drawn this turn" (SW_037, run wave 93): both players' draws.
COUNT.BOTH_CARDS_DRAWN_THIS_TURN = function(self)
    return self.state.players[1].cards_drawn_this_turn + self.state.players[2].cards_drawn_this_turn
end
-- "For each damaged friendly character / minion / character" (run wave 82).
local function damagedCount(self, seat, source)
    local count = 0
    local function damaged(id)
        local e = self:ent(id)
        return e ~= nil and not e.flags.dead and e.health > 0 and e.health < e.max_health and not self:is_location(id)
    end
    for _, side in ipairs({ seat, other(seat) }) do
        if not (side ~= seat and source == "DAMAGED_FRIENDLY_CHARACTERS") then
            for _, id in ipairs(self:board_ids(side)) do
                if damaged(id) then count = count + 1 end
            end
            if source ~= "DAMAGED_MINIONS" and damaged(self:player(side).hero_id) then count = count + 1 end
        end
    end
    return count
end
COUNT.DAMAGED_FRIENDLY_CHARACTERS = function(self, seat) return damagedCount(self, seat, "DAMAGED_FRIENDLY_CHARACTERS") end
COUNT.DAMAGED_MINIONS = function(self, seat) return damagedCount(self, seat, "DAMAGED_MINIONS") end
COUNT.DAMAGED_CHARACTERS = function(self, seat) return damagedCount(self, seat, "DAMAGED_CHARACTERS") end
COUNT.GAME_INVOKES = function(self, seat, p) return p.game_invokes end
-- "If you've Imbued your Hero Power twice" (run 16).
COUNT.GAME_IMBUES = function(self, seat, p) return p.imbue_count end
-- Answered in count_for, through the effect's filter.
COUNT.HISTORY_PLAYED = function() return 0 end
COUNT.HISTORY_MANA_SPENT = function() return 0 end
COUNT.HISTORY_DISTINCT_TYPES = function() return 0 end
COUNT.GAME_NAMED_DIED = function() return 0 end

-- ---- costs -------------------------------------------------------------------------------------

local function costFilterMatches(filter, d)
    return filter == 0 or filter == d.typeNum + 1
end
E.costFilterMatches = costFilterMatches

function E:card_pays_with_effect(seat, id)
    local d = self:def_of(id)
    if not d then return 0 end
    for _, fx in ipairs(d.effects) do
        if fx.op == "CARD_COST" and (fx.amount2 == 13 or fx.amount2 == 14) and self:condition_holds(fx, seat, id) then
            return fx.amount2 == 13 and 1 or 2
        end
    end
    return 0
end

function E:card_cost(seat, id)
    local e = self:ent(id)
    local d = e and self:def_of(id)
    if not e or not d then return 0 end
    if e.cost_override >= 0 then return e.cost_override end
    local function upgradeMissing(fx)
        return (fx.trigger == "CORRUPT" and not e.flags.corrupted) or (fx.trigger == "FORGED" and not e.flags.forged)
    end
    for _, fx in ipairs(d.effects) do
        if fx.op == "CARD_COST" and fx.amount2 == 6 and not upgradeMissing(fx) and self:condition_holds(fx, seat, id) then
            return max(0, fx.amount)
        end
    end
    local delta = e.cost_delta + e.temp_cost_delta
    local floored = 0
    for _, fx in ipairs(d.effects) do
        if fx.op == "CARD_COST" and fx.amount2 == 2 and fx.target.side ~= "ENEMY_HERO" and not upgradeMissing(fx)
            and self:condition_holds(fx, seat, id) then
            delta = delta + fx.amount * self:cost_count_value(seat, fx)
        end
    end
    local s = self.state
    local heroClass = self:player(seat).hero_class
    for srcSeat = 0, 1 do
        -- The board's cost auras, then the ones a card installed for the rest of the game ("your Librams cost (1)
        -- less this game").
        local costLines = {}
        for _, sid in ipairs(self:board_ids(srcSeat)) do
            local src = self:ent(sid)
            if src and not src.flags.silenced then
                local sd = self:def_of(sid)
                if sd then costLines[#costLines + 1] = sd.effects end
            end
        end
        for _, row in ipairs(s.persistent) do
            if row.owner == srcSeat and row.game_long >= 0 then
                local rd = def(row.card_id)
                if rd and row.game_long < #rd.effects then
                    costLines[#costLines + 1] = rd.effects[row.game_long + 1].followUp
                end
            end
        end
        for _, lines in ipairs(costLines) do
            for _, fx in ipairs(lines) do
                if fx.op == "CARD_COST" and fx.trigger == "AURA" and not fx.printOnly then
                    local affects
                    if fx.bothPlayers then
                        affects = true
                    elseif fx.target.side == "ENEMY_HERO" or fx.target.side == "ENEMY_CHARACTER"
                        or fx.target.side == "ENEMY_MINIONS" then
                        affects = srcSeat ~= seat
                    else
                        affects = srcSeat == seat
                    end
                    if affects and costFilterMatches(fx.type_filter, d)
                        and not (fx.schoolFilter ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.schoolFilter))
                        and not (fx.keywordFilterBits ~= 0 and band(d.keywords, fx.keywordFilterBits) ~= fx.keywordFilterBits)
                        and not (fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits))
                        and not (fx.excludeRaceBits ~= 0 and hasRace(d.races, fx.excludeRaceBits))
                        and not (fx.otherClass and (d.familyNum == heroClass or d.family == "NEUTRAL"))
                        -- "Your Secrets cost (1) less", "your Outcast cards cost (1) less".
                        and not (fx.secretOnly and not d.secret)
                        and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(d, fx.traitFilterNum, heroClass, e.keywords))
                        -- "Cards that didn't start in your deck cost (2) less".
                        and E.origin_matches(fx, e)
                        -- "Your Protoss minions cost (1) less this game": a family (or a card's own name).
                        and not (fx.targetName ~= "" and not D.cardIsNamed(d, fx.targetName, fx.nameFamily))
                        -- "The first minion you play each turn costs (1) less": spent once one is played this turn.
                        and not (fx.firstEachTurn ~= 0 and self:played_covered_this_turn(seat, fx)) then
                        if fx.amount2 == 3 then
                            return max(0, fx.amount)
                        end
                        if fx.amount2 == 5 then
                            floored = floored + fx.amount * self:cost_count_value(seat, fx)
                        else
                            delta = delta + fx.amount * self:cost_count_value(seat, fx)
                        end
                    end
                end
            end
        end
    end
    local p = self:player(seat)
    if p.next_turn_cost_delta ~= 0 and costFilterMatches(p.next_turn_cost_filter, d) then
        if p.next_turn_cost_floor then
            floored = floored + p.next_turn_cost_delta
        else
            delta = delta + p.next_turn_cost_delta
        end
    end
    local nextOne = costFilterMatches(p.next_card_cost_filter, d)
        and (p.next_card_cost_school == 0 or (d.type == "SPELL" and d.schoolNum + 1 == p.next_card_cost_school))
        and (p.next_card_cost_race == 0 or hasRace(d.races, p.next_card_cost_race))
        and (p.next_card_cost_keyword == 0 or band(d.keywords, p.next_card_cost_keyword) == p.next_card_cost_keyword)
        and (not p.next_card_cost_secret or d.secret)
        and (p.next_card_cost_trait == 0 or E.card_has_trait(d, p.next_card_cost_trait, p.hero_class, 0))
        and (p.next_card_cost_name == "" or D.cardIsNamed(d, p.next_card_cost_name, p.next_card_cost_name_family))
    -- "Your next card costs (1) more (up to 10)": a capped increase applies last, and never past its cap.
    local cappedIncrease = 0
    if p.next_card_cost_delta ~= 0 and nextOne then
        if p.next_card_cost_delta > 0 and p.next_card_cost_cap > 0 then
            cappedIncrease = p.next_card_cost_delta
        else
            delta = delta + p.next_card_cost_delta
        end
    end
    -- "The next Secret you play this turn costs (0)": the one-shot names the Cost outright.
    if p.next_card_cost_set >= 0 and nextOne then return p.next_card_cost_set end
    local total = d.cost + delta
    if cappedIncrease > 0 then
        total = max(total, min(total + cappedIncrease, p.next_card_cost_cap))
    end
    if floored == 0 then return max(0, total) end
    return max(min(1, max(0, total)), total + floored)
end

function E:hero_power_cost(seat)
    local p = self:player(seat)
    if p.hero_power_free_once then return 0 end
    -- Auras come off the board, so a Maiden of the Lake that dies stops discounting.
    local delta = p.hero_power_cost_once
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        local d = e and not e.flags.silenced and self:def_of(id)
        if d then
            for _, fx in ipairs(d.effects) do
                if fx.op == "HERO_POWER_COST" and fx.trigger == "AURA" and fx.target.side ~= "ENEMY_HERO" then
                    delta = delta + fx.amount
                end
            end
        end
    end
    -- Never negative. An Imbued power has its own price, and a Hero Power card costs what it prints.
    local card = self:card_power(seat)
    return max(0, (card and card.cost or E.power_base_cost(p.hero_power_id)) + delta)
end

-- ---- events ------------------------------------------------------------------------------------

local SELF_ARRIVALS = { AFTER_SUMMON_MINION = true, AFTER_PLAY_MINION = true, AFTER_PLAY_CARD = true,
    WHEN_SUMMON_MINION = true, WHEN_PLAY_MINION = true, WHEN_PLAY_CARD = true }

local SELF_ARRIVALS = { AFTER_SUMMON_MINION = true, AFTER_PLAY_MINION = true, AFTER_PLAY_CARD = true,
    WHEN_SUMMON_MINION = true, WHEN_PLAY_MINION = true, WHEN_PLAY_CARD = true,
    -- A draw and a discard: "Whenever you draw a card, add a copy of it" in hand copied ITSELF as it was drawn.
    AFTER_DRAW = true, AFTER_DISCARD = true,
    -- A row a spell installed is not answered by that spell's own cast.
    AFTER_CAST_SPELL = true, WHEN_CAST_SPELL = true }

function E:subject_matches(fx, subject, reactor)
    if fx.trigger == "AFTER_ATTACK_KILL" and fx.subjectType == -2 then
        local s, r = self:ent(subject), self:ent(reactor)
        return s ~= nil and r ~= nil and (s.zone == ZONE.WEAPON or s.zone == ZONE.HERO) and s.controller == r.controller
    end
    -- -4 on AFTER_SPELL_ON_MINION is "whenever you TARGET this minion with a spell".
    if fx.subjectType == -1 or fx.subjectType == -2 or (fx.subjectType == -4 and fx.trigger == "AFTER_SPELL_ON_MINION") then
        return subject == reactor
    end
    -- "After you cast a spell on ANOTHER friendly minion": not when it was cast on the reactor itself.
    if fx.trigger == "AFTER_SPELL_ON_MINION" and fx.excludeSource and subject == reactor then return false end
    -- "After a friendly MINION loses Divine Shield": a hero's shield answers only "a friendly character" (-3).
    if fx.trigger == "AFTER_LOSE_DIVINE_SHIELD" and fx.subjectType == 0 then
        local s = self:ent(subject)
        if not s or s.zone == ZONE.HERO then return false end
    end
    -- "After this attacks a minion / a hero": the defender filter is read where the attack is dispatched.
    if fx.trigger == "AFTER_SELF_ATTACK" and subject == reactor and reactor >= 0 then return true end
    if reactor >= 0 and subject == reactor and SELF_ARRIVALS[fx.trigger] then return false end
    if fx.subjectType == -3 then return true end
    if fx.subjectRaceBits == 0 and fx.subjectKeywordBits == 0 and fx.subjectCost == 0 and fx.subjectHealth == 0
        and fx.subjectAttackMax == 0 and fx.subjectAttackMin == 0 and fx.subjectType == 0 and fx.subjectName == ""
        and fx.subjectSchoolNum == 0 and fx.subjectSide == 0 and fx.subjectTraitNum == 0
        and fx.subjectCostMin == 0 and fx.subjectCostMax == 0 then
        return true
    end
    local e = self:ent(subject)
    if not e then return false end
    -- "After this minion attacks a HERO": a hero has no catalogue card, so its zone says what it is.
    if fx.subjectType == D.CARDTYPE.HERO + 1 then return e.zone == ZONE.HERO end
    -- "Whenever your hero takes damage" (subjectSide 1): only its side qualifies a hero.
    if e.zone == ZONE.HERO and (fx.trigger == "AFTER_HERO_DAMAGED" or (fx.trigger == "AFTER_FROZEN" and fx.subjectType == 0)) then
        local r = reactor >= 0 and self:ent(reactor) or nil
        return r == nil or fx.subjectSide == 0 or (fx.subjectSide == 1 and e.controller == r.controller)
            or (fx.subjectSide == 2 and e.controller ~= r.controller)
    end
    local d = self:def_of(subject)
    if not d then return false end
    local trait = fx.subjectTraitNum
    if trait >= D.TRAIT.handEdge and trait <= D.TRAIT.handRight then
        -- "After you play the left- or right-most card in your hand": where the played card sat as it left the hand.
        local want = trait == D.TRAIT.handLeft and 1 or trait == D.TRAIT.handRight and 2 or 3
        if subject ~= self.play_edge_id or band(self.play_edge, want) == 0 then return false end
    elseif trait ~= 0 then
        local r = self:ent(reactor)
        local seat = r and r.controller or e.controller
        if not E.card_has_trait(d, trait, self:player(seat).hero_class, e.keywords) then return false end
    end
    local subjectCost = (subject == self.last_paid_entity and self.last_paid_price >= 0) and self.last_paid_price or d.cost
    if fx.subjectCostMin ~= 0 and subjectCost < fx.subjectCostMin then return false end
    if fx.subjectCostMax ~= 0 and subjectCost > fx.subjectCostMax then return false end
    if fx.subjectType ~= 0 and d.typeNum + 1 ~= fx.subjectType then return false end
    if fx.subjectSchoolNum ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.subjectSchoolNum) then return false end
    if fx.subjectRaceBits ~= 0 and not hasRace(d.races, fx.subjectRaceBits) then return false end
    if fx.subjectKeywordBits ~= 0 then
        local have = e.keywords
        -- It attacked with Stealth, which the attack itself removed (CAP_000).
        if contains(self.stealth_attackers, subject) then have = bor(have, KW.STEALTH) end
        if band(have, fx.subjectKeywordBits) == 0 then return false end
    end
    -- "After you play a 1-Cost minion" reads the Cost it was PLAYED for.
    if fx.subjectCost ~= 0 and subjectCost ~= fx.subjectCost then return false end
    if fx.subjectHealth ~= 0 and e.health ~= fx.subjectHealth then return false end
    if fx.subjectAttackMax ~= 0 and e.attack > fx.subjectAttackMax then return false end
    if fx.subjectAttackMin ~= 0 and e.attack < fx.subjectAttackMin then return false end
    if fx.subjectName ~= "" then
        if fx.nameFamily then
            if not D.cardIsNamed(d, fx.subjectName, true) then return false end
        elseif d.name ~= fx.subjectName then
            return false
        end
    end
    if fx.subjectSide ~= 0 and reactor >= 0 then
        local r = self:ent(reactor)
        if r and ((fx.subjectSide == 1 and e.controller ~= r.controller) or (fx.subjectSide == 2 and e.controller == r.controller)) then
            return false
        end
    end
    return true
end

function E:fire_self_event(trigger, subject)
    if trigger == "HONORABLE_KILL" or trigger == "OVERKILL" then
        local victim = self.kill_victims[subject]
        self.kill_victims[subject] = nil
        local outer = self.kill_victim
        self.kill_victim = victim or 0
        self:fire_self_event_now(trigger, subject)
        self.kill_victim = outer
        return
    end
    self:fire_self_event_now(trigger, subject)
end

local function reactsTo(d, trigger)
    for _, fx in ipairs(d.effects) do
        if fx.trigger == trigger then return true end
    end
    return false
end

function E:fire_self_event_now(trigger, subject)
    local e = self:ent(subject)
    if not e or e.flags.silenced then return end
    local d = self:def_of(subject)
    if not d or not reactsTo(d, trigger) then return end
    if not self:step_budget() then return end
    self:run_effects(subject, trigger, 0, subject)
    -- A weapon's Deathrattle under "your Deathrattles trigger twice" (not "your minions' ...").
    if trigger == "DEATHRATTLE" and d.type == "WEAPON" and not self.aborted and not self.state.pending.active
        and self:triggers_twice(e.owner, 2, false) then
        self:run_effects(subject, trigger, 0, subject)
    end
end

function E:fire_secrets(trigger, seat, subject)
    -- A Secret is armed only on its owner's OPPONENT's turn; the turn boundary itself is the printed exception.
    if seat == self:turn_owner() and trigger ~= "START_TURN" then return false end
    local p = self:player(seat)
    local secrets = {}
    for i, id in ipairs(p.secrets) do secrets[i] = id end
    local any = false
    for _, id in ipairs(secrets) do
        local e = self:ent(id)
        local d = e and not e.flags.silenced and self:def_of(id)
        if d then
            local reacts = false
            for _, fx in ipairs(d.effects) do
                if fx.trigger == trigger and self:subject_matches(fx, subject, id) then reacts = true end
            end
            if reacts then
                if not self:step_budget() then return any end
                self:run_effects(id, trigger, 0, subject)
                -- "Your Secrets trigger twice" (Commander Rhyssa).
                if not self.aborted and not self.state.pending.active and self:triggers_twice(seat, 8) then
                    self:run_effects(id, trigger, 0, subject)
                end
                if self:ent(id) then self:relocate(id, ZONE.GRAVEYARD, -1) end
                for i = #p.secrets, 1, -1 do
                    if p.secrets[i] == id then table.remove(p.secrets, i) end
                end
                p.game_secrets_triggered = p.game_secrets_triggered + 1
                -- "After a friendly Secret is revealed" (Eaglehorn Bow, Crossroads Gossiper).
                self:queue("AFTER_SECRET_REVEALED", seat, id)
                any = true
                if self.aborted then return any end
            end
        end
    end
    return any
end

function E:fire_when_played(seat, id, card, magnetic)
    local function fire(trigger, reacting)
        if self.aborted or self:is_terminal() then return end
        self:fire_events(trigger, reacting, id)
    end
    if card.type == "MINION" then
        if not magnetic then fire("WHEN_SUMMON_MINION", seat) end
        fire("WHEN_PLAY_MINION", seat)
    end
    fire("WHEN_PLAY_CARD", seat)
    if card.type == "SPELL" then
        fire("WHEN_CAST_SPELL", seat)
        fire("WHEN_OPPONENT_CASTS_SPELL", other(seat))
    end
end

local function byPlayOrder(self, ids)
    local board = {}
    for _, id in ipairs(ids) do
        local e = self:ent(id)
        if e then board[#board + 1] = e end
    end
    table.sort(board, function(x, y)
        if x.play_order ~= y.play_order then return x.play_order < y.play_order end
        return x.id < y.id
    end)
    local out = {}
    for i, e in ipairs(board) do out[i] = e.id end
    return out
end

local QUEST_EVENTS = { AFTER_PLAY_MINION = "PLAY_MINION", AFTER_SUMMON_MINION = "SUMMON_MINION",
    AFTER_CAST_SPELL = "CAST_SPELL", AFTER_SPELL_ON_MINION = "SPELL_ON_MINION", AFTER_DRAW = "DRAW",
    AFTER_DISCARD = "DISCARD" }

function E:fire_events(trigger, seat, subject, eventAmount)
    eventAmount = eventAmount or 0
    local s = self.state
    -- The summon reactors whose own reactions summoned this minion: none of them answers it. Read once here.
    local chain = self.event_summon_chain or {}
    self.event_summon_chain = nil
    local summonEvent = trigger == "WHEN_SUMMON_MINION" or trigger == "AFTER_SUMMON_MINION"
    -- "After you gain Armor, gain 2 more": the Armor a reaction gains is no new event.
    local savedArmor = self.armor_reacting
    if trigger == "AFTER_GAIN_ARMOR" then self.armor_reacting = true end
    self:fire_events_body(trigger, seat, subject, eventAmount, chain, summonEvent)
    self.armor_reacting = savedArmor
end

function E:fire_events_body(trigger, seat, subject, eventAmount, chain, summonEvent)
    local s = self.state
    -- Run 16: the play, summon, cast, draw and discard events count toward the seat's quests as they are dispatched.
    if trigger == "AFTER_PLAY_CARD" then
        self:quest_count(seat, "PLAY_CARD", subject, 1)
        self:quest_count(seat, "TURNS_IN_ROW", subject, 1)
    elseif QUEST_EVENTS[trigger] then
        self:quest_count(seat, QUEST_EVENTS[trigger], subject, 1)
    end
    -- "Secret: When your hero takes damage, deal that much damage to the enemy hero": the Secret reads the amount.
    do
        local savedAmount = self.event_amount
        self.event_amount = eventAmount
        self:fire_secrets(trigger, seat, subject)
        self.event_amount = savedAmount
    end
    if trigger == "AFTER_CAST_SPELL" then
        local cast = self:def_of(subject)
        if cast and cast.type == "SPELL" then
            local due, kept = {}, {}
            for _, row in ipairs(s.persistent) do
                if row.owner == seat and row.replay_school == cast.schoolNum + 1 and cast.schoolNum ~= 0
                    and row.source ~= subject then
                    due[#due + 1] = row
                else
                    kept[#kept + 1] = row
                end
            end
            s.persistent = kept
            for _, row in ipairs(due) do
                local d = self:def_of(row.source)
                if d and self:step_budget() then
                    local again = {}
                    for _, fx in ipairs(d.effects) do
                        if fx.trigger == "ON_PLAY" then again[#again + 1] = fx end
                    end
                    self:run_effect_list(again, row.source, "ON_PLAY", 0, row.source, nil)
                    if self.aborted then return end
                end
            end
        end
    end
    local sources = {}
    local weapon = self:player(seat).weapon_id
    if weapon ~= 0 and self:ent(weapon) then sources[1] = weapon end
    -- A damage-taken event hears the board as it was when the damage landed.
    local snapshot = self.event_listeners
    local listeners = snapshot or self:board_ids(seat)
    self.event_listeners = nil   -- nested events gather their own
    local board = {}
    for _, id in ipairs(listeners) do
        local e = self:ent(id)
        if e and (snapshot ~= nil or e.zone == ZONE.BOARD) then board[#board + 1] = e end
    end
    table.sort(board, function(x, y)
        if x.play_order ~= y.play_order then return x.play_order < y.play_order end
        return x.id < y.id
    end)
    for _, e in ipairs(board) do sources[#sources + 1] = e.id end
    if (trigger == "AFTER_DRAW" or trigger == "AFTER_DISCARD") and subject ~= 0 and self:ent(subject) then
        sources[#sources + 1] = subject
    end
    if (trigger == "SELF_TAKES_DAMAGE" or trigger == "SELF_DEALS_DAMAGE" or trigger == "WHEN_YOUR_MINION_ATTACKED")
        and subject ~= 0 then
        local gone = self:ent(subject)
        if gone and gone.zone == ZONE.GRAVEYARD and gone.owner == seat and not contains(sources, subject) then
            sources[#sources + 1] = subject
        end
    end
    for _, id in ipairs(sources) do
        local e = self:ent(id)
        local granted = e ~= nil and self:granted_reacts(e, trigger)
        local skip = not e or (e.flags.silenced and not granted)
            or ((trigger == "SELF_TAKES_DAMAGE" or trigger == "SELF_DEALS_DAMAGE" or trigger == "OVERHEAL") and id ~= subject)
            or (trigger == "SPELLBURST" and e.flags.spellburst_used)
            or (trigger == "FRENZY" and (e.flags.frenzy_used or id ~= subject))
        local d = not skip and self:def_of(id)
        local reacts = false
        if d then
            reacts = granted or (not e.flags.silenced and reactsTo(d, trigger))
            if reacts and summonEvent and contains(chain, id) then reacts = false end
        end
        if reacts then
            if not self:step_budget() then return end
            local savedAmount = self.event_amount
            self.event_amount = eventAmount
            local outerVictim = self.kill_victim
            if trigger == "AFTER_ATTACK_KILL" then self.kill_victim = eventAmount end
            local outerChain
            if summonEvent then
                outerChain = self.summon_chain
                local c = {}
                for i, x in ipairs(chain) do c[i] = x end
                c[#c + 1] = id
                self.summon_chain = c
            end
            self:run_effects(id, trigger, 0, subject ~= 0 and subject or id)
            if summonEvent then self.summon_chain = outerChain end
            self.kill_victim = outerVictim
            self.event_amount = savedAmount
            if trigger == "SPELLBURST" then
                local reactor = self:ent(id)
                if reactor then
                    local cast = self:def_of(subject)
                    local kept = d.spellburst_kept_by ~= 0 and cast and cast.schoolNum == d.spellburst_kept_by
                    if not kept then reactor.flags.spellburst_used = true end
                end
            end
            if trigger == "FRENZY" then
                local reactor = self:ent(id)
                if reactor then reactor.flags.frenzy_used = true end
            end
            if self.aborted then return end
        end
    end
    -- "Whenever a friendly minion dies while this is in your hand, gain +1 Attack": a held card's in-hand lines answer
    -- from the hand of the player the event belongs to.
    if self:in_hand_listens(trigger) then
        local held = self:hand_ids(seat)
        for _, id in ipairs(held) do
            if not ((trigger == "AFTER_DRAW" or trigger == "AFTER_DISCARD") and id == subject) then
                local e = self:ent(id)
                local d = e and e.zone == ZONE.HAND and not e.flags.silenced and self:def_of(id) or nil
                if d then
                    local listens = false
                    for _, fx in ipairs(d.effects) do
                        listens = listens or (fx.inHand ~= 0 and fx.trigger == trigger)
                    end
                    if listens then
                        if not self:step_budget() then return end
                        local savedAmount, savedScan = self.event_amount, self.hand_scan_source
                        self.event_amount = eventAmount
                        self.hand_scan_source = id
                        self:run_effect_list(d.effects, id, trigger, 0, subject ~= 0 and subject or id, nil)
                        self.hand_scan_source = savedScan
                        self.event_amount = savedAmount
                        if self.aborted then return end
                    end
                end
            end
        end
    end
    -- A SPELL's lasting trigger is a persistent row of its owner, answered here like a minion in play; a GAME_LONG row
    -- runs the lines its card installed, whatever the card is and wherever it went.
    local rows = {}
    for i, row in ipairs(s.persistent) do rows[i] = row end
    for _, row in ipairs(rows) do
        if row.owner == seat then
            local d
            if row.game_long >= 0 then
                d = def(row.card_id)
            elseif self:ent(row.source) then
                d = self:def_of(row.source)
            end
            local lines
            if d then
                if row.game_long >= 0 and row.game_long < #d.effects then
                    lines = d.effects[row.game_long + 1].followUp
                elseif row.game_long < 0 and d.type == "SPELL" then
                    lines = d.effects
                end
            end
            if lines then
                local list = {}
                for _, fx in ipairs(lines) do
                    if fx.trigger == trigger and self:subject_matches(fx, subject, row.source) then
                        local one = copyEffect(fx)
                        one.durationTurns = 0
                        list[#list + 1] = one
                    end
                end
                if #list > 0 and not (summonEvent and contains(chain, row.source)) and self:step_budget() then
                    local savedAmount = self.event_amount
                    self.event_amount = eventAmount
                    local rowOwner = row.owner
                    -- A row with firings left spends one now ("the next Draenei you play"), and is gone when none are.
                    if row.game_long >= 0 and row.uses > 0 then
                        for i, live in ipairs(s.persistent) do
                            if live.serial == row.serial and live.source == row.source
                                and live.game_long == row.game_long and live.owner == row.owner then
                                live.uses = live.uses - 1
                                if live.uses <= 0 then table.remove(s.persistent, i) end
                                break
                            end
                        end
                    end
                    local outerChain
                    if summonEvent then
                        outerChain = self.summon_chain
                        local c = {}
                        for i, x in ipairs(chain) do c[i] = x end
                        c[#c + 1] = row.source
                        self.summon_chain = c
                    end
                    self:run_effect_list(list, row.source, trigger, 0, subject ~= 0 and subject or row.source, nil, 0,
                        row.game_long >= 0 and rowOwner or nil)
                    if summonEvent then self.summon_chain = outerChain end
                    self.event_amount = savedAmount
                    if self.aborted then return end
                end
            end
        end
    end
end

function E:secret_in_play(seat, cardId)
    for _, id in ipairs(self:player(seat).secrets) do
        local e = self:ent(id)
        if e and e.card_id == cardId then return true end
    end
    return false
end

function E:fire_attack_triggers(attacker)
    local a = self:ent(attacker)
    if not a then return end
    local seat = a.owner
    local heroAttacked = a.zone == ZONE.HERO
    local sources = {}
    local broken = self.broken_weapon or 0
    self.broken_weapon = 0
    if heroAttacked then
        local weapon = self:player(seat).weapon_id
        if weapon ~= 0 and self:ent(weapon) then
            sources[1] = weapon
        elseif broken ~= 0 and self:ent(broken) then
            -- "After your hero attacks" on the weapon this swing broke: it answers from the graveyard.
            sources[1] = broken
        end
    end
    for _, id in ipairs(byPlayOrder(self, self:board_ids(seat))) do sources[#sources + 1] = id end
    for _, id in ipairs(sources) do
        local e = self:ent(id)
        if e then
            -- A granted "after it attacks" / "after your hero attacks" line answers too, a Silenced holder's included.
            local granted = (id == attacker and self:granted_reacts(e, "AFTER_SELF_ATTACK"))
                or (heroAttacked and self:granted_reacts(e, "AFTER_HERO_ATTACK"))
            local d = (not e.flags.silenced or granted) and self:def_of(id)
            if d then
                local reacts = granted
                -- "After your hero attacks a MINION, set ITS Health to 1": a defender filter on the hero's attack; the
                -- effects then run with the DEFENDER as the event's subject.
                local heroDefender = false
                if not e.flags.silenced then
                    for _, fx in ipairs(d.effects) do
                        if fx.trigger == "AFTER_SELF_ATTACK" and id == attacker
                            and (fx.subjectType == 0 or self:subject_matches(fx, self.pending_attack_target, attacker)) then
                            reacts = true
                        end
                        if fx.trigger == "AFTER_HERO_ATTACK" and heroAttacked then
                            if fx.subjectType == 0 then
                                reacts = true
                            elseif self:subject_matches(fx, self.pending_attack_target, id) then
                                reacts = true
                                heroDefender = true
                            end
                        end
                    end
                end
                if reacts then
                    if not self:step_budget() then return end
                    self:run_effects(id, "AFTER_SELF_ATTACK", 0, id)
                    self:run_effects(id, "AFTER_HERO_ATTACK", 0, heroDefender and self.pending_attack_target or attacker)
                    if self.aborted then return end
                end
            end
        end
    end
end

-- ---- running effects ---------------------------------------------------------------------------

-- A grammar card's abilities as {kind, list} slices of its flat effects (cached on the def).
local function abilitySlices(d)
    if d.slices then return d.slices end
    local slices = {}
    local at = 0
    for i, a in ipairs(d.abilities) do
        local list = {}
        for k = 1, a[2] do list[k] = d.effects[at + k] end
        at = at + a[2]
        slices[i] = { kind = a[1], list = list }
    end
    d.slices = slices
    return slices
end

function E:run_effects(source, trigger, chosen, triggerSource)
    self:run_printed_effects(source, trigger, chosen, triggerSource)
    self:run_granted_effects(source, trigger, chosen, triggerSource)
end

function E:run_program_effects(source, trigger, chosen, triggerSource)
    local src = self:ent(source)
    if not src or src.flags.silenced then return end
    local d = self:def_of(source)
    if not d or not d.abilities then return end
    local frame = self:newFrame()
    frame.source, frame.controller, frame.event_subject, frame.chosen = source, src.controller, triggerSource, chosen
    local kind = TC.TriggerKinds[trigger]
    for a, slice in ipairs(abilitySlices(d)) do
        if slice.kind == kind then
            local saved = self.running_ability
            self.running_ability = a - 1
            self:run_effect_list(slice.list, source, trigger, chosen, triggerSource, frame)
            self.running_ability = saved
            if self.aborted then return end
            local pending = self.state.pending
            if pending.active and pending.resume and pending.source == source then return end
        end
    end
end

function E:run_persistent(seat, trigger, decrement)
    local s = self.state
    local i = 1
    while i <= #s.persistent do
        local row = s.persistent[i]
        -- An Elder Word's row waits for a spell, not for turns (fire_events runs it).
        if row.owner ~= seat or row.replay_school ~= 0 then
            i = i + 1
        else
            local src = self:ent(row.source)
            local d
            if row.game_long >= 0 then
                d = def(row.card_id)
            elseif src then
                d = self:def_of(row.source)
            end
            local gone = not d or (row.game_long < 0 and (not src or (d.type ~= "SPELL" and src.zone ~= ZONE.BOARD)))
            if gone then
                table.remove(s.persistent, i)
            elseif row.game_long >= 0 then
                -- "For the rest of the game, ... at the end of your turn": the installed lines, its player's whatever
                -- became of the card; it never runs out.
                local stop = false
                if row.game_long < #d.effects then
                    local owner, rowSource = row.owner, row.source
                    local lines = d.effects[row.game_long + 1].followUp
                    local rowAt = i
                    self:run_effect_list(lines, rowSource, trigger, -1, rowSource, nil, 0, owner)
                    if self.aborted then return end
                    i = math.min(rowAt, #s.persistent + 1)
                    if i > #s.persistent then stop = true end
                end
                if stop then break end
                i = i + 1
            elseif row.target ~= 0 then
                -- A row that remembers its chosen target runs only while that target is in play.
                local aimed = self:ent(row.target)
                if trigger == "START_TURN" and aimed and aimed.zone == ZONE.BOARD and not aimed.flags.dead then
                    self:run_effect_list(d.effects, row.source, trigger, row.target, row.source, nil)
                end
                if trigger == "START_TURN" then
                    -- C++ erases at the iterator it held: the row's position now.
                    table.remove(s.persistent, i)
                else
                    i = i + 1
                end
            else
                local rowSource = row.source
                local rowTwice = trigger == "END_TURN" and d.type == "SPELL" and self:triggers_twice(seat, 4, false)
                local rowAt = i
                self:run_effect_list(d.effects, rowSource, trigger, -1, rowSource, nil)
                if self.aborted then return end
                -- "Your end of turn effects trigger twice": a spell's lasting end-of-turn row is one.
                if rowTwice and not s.pending.active then
                    self:run_effect_list(d.effects, rowSource, trigger, -1, rowSource, nil)
                    if self.aborted then return end
                end
                -- The runs may have added rows: find this one again before counting it down.
                i = math.min(rowAt, #s.persistent + 1)
                if i > #s.persistent then break end
                local here = s.persistent[i]
                if decrement then here.turns_remaining = here.turns_remaining - 1 end
                if here.turns_remaining <= 0 then
                    table.remove(s.persistent, i)
                else
                    i = i + 1
                end
            end
        end
    end
end

function E:run_trigger(seat, trigger)
    -- Secrets react to the turn boundary too: "Secret: When your turn starts, ...".
    self:fire_secrets(trigger, seat, 0)
    local ordered = {}
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e then ordered[#ordered + 1] = e end
    end
    local weapon = self:player(seat).weapon_id
    if weapon ~= 0 then
        local w = self:ent(weapon)
        if w and w.zone == ZONE.WEAPON then ordered[#ordered + 1] = w end
    end
    table.sort(ordered, function(x, y)
        if x.play_order ~= y.play_order then return x.play_order < y.play_order end
        return x.id < y.id
    end)
    for _, e in ipairs(ordered) do
        local id = e.id
        -- "Your end of turn effects trigger twice" (Drakkari Enchanter); a weapon's under "your minions' ..." does not.
        local here = self:ent(id)
        local twice = trigger == "END_TURN" and here ~= nil and self:triggers_twice(seat, 4, here.zone == ZONE.BOARD)
        self:run_effects(id, trigger, 0, id)
        if self.aborted then return end
        if twice and not self.state.pending.active then
            self:run_effects(id, trigger, 0, id)
            if self.aborted then return end
        end
    end
end

function E:run_each_turn(trigger)
    local ordered = {}
    for seat = 0, 1 do
        local ids = self:board_ids(seat)
        local weapon = self:player(seat).weapon_id
        if weapon ~= 0 then
            local w = self:ent(weapon)
            if w and w.zone == ZONE.WEAPON then ids[#ids + 1] = weapon end
        end
        for _, id in ipairs(ids) do
            local e, d = self:ent(id), self:def_of(id)
            if e and d and reactsTo(d, trigger) then ordered[#ordered + 1] = e end
        end
    end
    table.sort(ordered, function(x, y)
        if x.play_order ~= y.play_order then return x.play_order < y.play_order end
        return x.id < y.id
    end)
    for _, e in ipairs(ordered) do
        local id = e.id
        self:run_effects(id, trigger, 0, id)
        if self.aborted then return end
        -- "At the end of each turn" is an end of turn effect of its owner's (Gruul under Drakkari Enchanter).
        if trigger == "END_EACH_TURN" and not self.state.pending.active then
            local here = self:ent(id)
            if here and self:triggers_twice(here.owner, 4, here.zone == ZONE.BOARD) then
                self:run_effects(id, trigger, 0, id)
                if self.aborted then return end
            end
        end
    end
end

function E:capture_pending(source, trigger, index, chosen, triggerSource, frame)
    local p = self.state.pending
    p.resume = true
    p.outcast = self.play_was_outcast   -- "Outcast:" after the choice reads the play that raised it
    p.source = source
    p.trigger = trigger
    p.effect_index = index
    p.event_subject = triggerSource
    p.chosen = chosen
    local prev = {}
    if frame then
        for i, id in ipairs(frame.previous_targets) do prev[i] = id end
    end
    p.previous_targets = prev
    p.ability = self.running_ability
end

function E:run_minion_on_play(id, target, frame)
    local d = self:def_of(id)
    local src = self:ent(id)
    if frame and d and src and not src.flags.silenced then
        if d.abilities then
            local kind = TC.TriggerKinds.ON_PLAY
            for a, slice in ipairs(abilitySlices(d)) do
                if slice.kind == kind then
                    local saved = self.running_ability
                    self.running_ability = a - 1
                    self:run_effect_list(slice.list, id, "ON_PLAY", target, id, frame)
                    self.running_ability = saved
                    if self.aborted or (self.state.pending.active and self.state.pending.resume) then return end
                end
            end
        else
            self:run_effect_list(d.effects, id, "ON_PLAY", target, id, frame)
        end
    else
        self:run_effects(id, "ON_PLAY", target, id)
    end
    local played = self:ent(id)
    if played and played.flags.corrupted and d and d.abilities then
        self:run_effects(id, "CORRUPT", target, id)
    end
end

function E:resume_pending()
    local pending = E.deepCopy(self.state.pending)
    if not pending.resume or pending.effect_index < 0 or pending.source == 0 then return end
    local live = self.state.pending
    live.resume = false
    live.effect_index = -1
    live.ability = -1
    live.then_on_play = false
    self.play_was_outcast = pending.outcast
    live.outcast = false
    live.resume_same = false
    live.rerun = 0
    local nextIndex = pending.effect_index + (pending.resume_same and 0 or 1)
    local src = self:ent(pending.source)
    local d = self:def_of(pending.source)
    if not src or not d then return end
    local frame = self:newFrame()
    frame.source, frame.controller = pending.source, src.controller
    frame.event_subject, frame.chosen = pending.event_subject, pending.chosen
    frame.previous_targets = pending.previous_targets
    if pending.ability >= 0 and d.abilities then
        local slices = abilitySlices(d)
        local kind = TC.TriggerKinds[pending.trigger]
        for a = pending.ability + 1, #slices do
            if slices[a].kind == kind then
                local first = a == pending.ability + 1
                local saved = self.running_ability
                self.running_ability = a - 1
                self:run_effect_list(slices[a].list, pending.source, pending.trigger, pending.chosen,
                    pending.event_subject, frame, first and nextIndex or 0)
                self.running_ability = saved
                if self.aborted or self.state.pending.active then break end
            end
        end
    else
        -- A repeated or replayed Battlecry's choice resumes in the list it was raised in (run_random_battlecry).
        local list = (self.replay_lines ~= nil and pending.source == self.replay_source) and self.replay_lines
            or d.effects
        self:run_effect_list(list, pending.source, pending.trigger, pending.chosen, pending.event_subject,
            frame, nextIndex)
    end
    if self.state.pending.active then
        -- Another choice opened on the way: the owed on-play text, and the doubled run, wait for that one too.
        if pending.then_on_play then self.state.pending.then_on_play = true end
        if pending.rerun > 0 and self.state.pending.source == pending.source then
            self.state.pending.rerun = pending.rerun
        end
        return
    end
    -- "Your Battlecries trigger twice": the second run, now that the first one's choices are made.
    if pending.rerun > 0 and not self.aborted then
        local outerCast = self.casting_spell
        local sd = self:def_of(pending.source)
        if sd and sd.type == "SPELL" then self.casting_spell = pending.source end
        self:run_doubled(pending.source, pending.trigger, pending.chosen, pending.event_subject)
        self.casting_spell = outerCast
        if self.state.pending.active then
            if pending.then_on_play then self.state.pending.then_on_play = true end
            if self.state.pending.source == pending.source and pending.rerun > 1 then
                self.state.pending.rerun = pending.rerun - 1
            end
            return
        end
    end
    if pending.then_on_play and not self.aborted then
        self:run_minion_on_play(pending.source, pending.chosen, frame)
    end
end

local TARGETLESS = { SUMMON = true, SUMMON_RANDOM = true, EQUIP = true, DRAW = true, GAIN_MANA = true,
    REFRESH_MANA = true, DISCOVER = true, ADD_TO_HAND = true, HERO_POWER_COST = true, DREDGE = true,
    BUFF_ZONE = true, GAME_LONG = true, GAIN_DURABILITY = true, DISCARD_HAND = true, BUFF_NAMED = true,
    SUMMON_WITH_STATS = true }
local ZONE_OPS = { SUMMON_FROM_DECK = true, COST_ZONE = true, CAST_FROM = true, CHOOSE_HAND = true,
    SUMMON_COPY_FROM = true, SWAP_WITH = true, RESURRECT = true, EMPOWER_ABILITIES = true, REPEAT_ABILITY = true,
    HERALD = true, JADE_GOLEM = true, INVOKE = true, DISCARD_LOWEST = true, DISCARD_HIGHEST = true,
    SET_MANA_CRYSTALS = true, SHUFFLE_SELF = true, SHUFFLE_COPY_SELF = true, KEEPS_ENCHANTMENTS = true, EXCAVATE = true,
    IMBUE = true }
local SUMMONISH = { SUMMON = true, SUMMON_RANDOM = true, SUMMON_COPY = true, RAISE_CORPSES = true,
    SUMMON_FROM_DECK = true, RESURRECT = true }
local SUMMON_NAMES = { SUMMON_COPY = true, SUMMON = true, SUMMON_RANDOM = true, SUMMON_FROM_DECK = true,
    SUMMON_WITH_STATS = true, RESURRECT = true }
local HAND_ENDS = { LEFTMOST = true, RIGHTMOST = true, EDGES = true }
local ABOUT_IT = { TARGET_IS_RACE = true, TARGET_IS_TYPE = true, TARGET_IS_SCHOOL = true,
    TARGET_IS_CONTROLLED_RACE = true, TARGET_IS_FROZEN = true }
local MIRRORED = { FRIENDLY_DECK = "ENEMY_DECK", FRIENDLY_MINION = "ENEMY_MINION",
    FRIENDLY_MINIONS = "ENEMY_MINIONS", FRIENDLY_HAND = "ENEMY_HAND" }

local function isTargetless(fx)
    local op = fx.op
    return ((TARGETLESS[op] or (op == "SHUFFLE" and (fx.token ~= "" or fx.amount2 == 1 or fx.amount2 == 4
            or fx.target.kind == "SELF"))
            or (op == "CARD_COST" and not HAND_ENDS[fx.target.kind])
            or (op == "TRIGGER_DEATHRATTLE" and fx.fromGraveyard))
            and not (op == "CARD_COST" and fx.target.kind == "PREVIOUS"))
        or (op == "DAMAGE_MULTIPLIER" and fx.trigger ~= "AURA")
        or ZONE_OPS[op]
        or (op == "FILL_HAND" and fx.target.kind ~= "PREVIOUS")
        or (op == "FORCE_ATTACK" and fx.amount2 == 1)
        or (op == "MULTIPLY_STATS" and (fx.buffHand or fx.buffDeck or fx.buffBoard))
end

local function copyList(list)
    local out = {}
    for i, x in ipairs(list) do out[i] = x end
    return out
end

-- run_effect_list: `controllerOverride` is a seat number for a delayed effect (no live source).
-- A hero's damage dealt while a list runs is answered at the end of its hit (answer_hero_damage): the depth counts it.
function E:run_effect_list(effects, source, trigger, chosen, triggerSource, frame, startIndex, controllerOverride)
    self.effect_lists = self.effect_lists + 1
    self:run_effect_list_body(effects, source, trigger, chosen, triggerSource, frame, startIndex, controllerOverride)
    self.effect_lists = self.effect_lists - 1
end

-- One line's outcome in the loop below: nil runs the next line, STOP leaves the list.
local STOP = {}

function E:run_effect_list_body(effects, source, trigger, chosen, triggerSource, frame, startIndex, controllerOverride)
    startIndex = startIndex or 0
    local s = self.state
    local src = self:ent(source)
    if controllerOverride == nil then
        if not src or src.flags.silenced then return end
    end
    frame = frame or self:newFrame()
    local d = controllerOverride == nil and self:def_of(source) or nil
    if controllerOverride == nil and not d then return end
    local controller = controllerOverride == nil and src.controller or controllerOverride
    local rng = s.rng

    local function runFollowUps(parent, target)
        if #parent.followUp == 0 or parent.op == "GRANT_ABILITY" or parent.op == "GAME_LONG" then return end
        local pass = parent.followUpCondition == "NONE"
        local victim = target ~= 0 and self:ent(target) or nil
        if parent.followUpCondition == "IF_DIES" then
            pass = not victim or victim.flags.dead or victim.health <= 0 or victim.zone == ZONE.GRAVEYARD
        elseif parent.followUpCondition == "IF_SURVIVES" then
            pass = victim ~= nil and not victim.flags.dead and victim.health > 0 and victim.zone == ZONE.BOARD
        end
        if not pass then return end
        local child = self:newFrame()
        child.source, child.controller, child.event_subject, child.chosen = source, controller, triggerSource, chosen
        if target ~= 0 then child.previous_targets = { target } end
        self:run_effect_list(parent.followUp, source, trigger, chosen, target ~= 0 and target or triggerSource, child)
    end

    -- "If any die, repeat this" (REPEAT_IF): the game's death count against the pass's start.
    local function countDying()
        local n = s.players[1].game_minions_died + s.players[2].game_minions_died
        for _, side in ipairs({ 0, 1 }) do
            for _, id in ipairs(self:board_ids(side)) do
                local e = self:ent(id)
                if e and (e.flags.dead or e.health <= 0) and not self:is_location(id) then n = n + 1 end
            end
        end
        return n
    end
    local repeatPasses = 0
    local dyingAtPass = countDying()
    -- A `remember` line's PREVIOUS set is kept on its card once the line has run.
    local rememberAfter = (startIndex > 0 and startIndex <= #effects and effects[startIndex].remember)
        and startIndex - 1 or -1
    local function flushRemembered()
        if rememberAfter < 0 or frame == nil then return end
        rememberAfter = -1
        local keeper = self:ent(source)
        if keeper then
            for _, id in ipairs(frame.previous_targets) do
                if id ~= 0 and id ~= source and not contains(keeper.remembered, id) then
                    keeper.remembered[#keeper.remembered + 1] = id
                end
            end
        end
    end

    -- The rest of one line, once its gates have passed (C++: from the subject test to the line's end).
    local function runRest(stored, fx, effectIndex)
        if fx.op ~= "QUEST" and not self:subject_matches(fx, triggerSource, source) then return end
        -- Parked lines: a repeated Battlecry's line is the repeated card's, at its index there.
        local parkedCard, parkedIndex = nil, effectIndex
        if fx.delayed or fx.delayTurns > 0 or fx.delayEnd then
            if effects == self.replay_lines and self.replay_card ~= nil and self.replay_index
                and effectIndex < #self.replay_index and self.replay_index[effectIndex + 1] >= 0 then
                parkedCard = self.replay_card.id
                parkedIndex = self.replay_index[effectIndex + 1]
            else
                local ownerDef = self:def_of(source)
                if ownerDef then parkedCard = ownerDef.id end
            end
        end
        if fx.delayed then
            if parkedCard then
                local de = self:player(controller).delayed_effects
                de[#de + 1] = { parkedCard, parkedIndex }
            end
            return
        end
        -- "In 2 turns, ...": counted down at each of their turn starts.
        if fx.delayTurns > 0 then
            if parkedCard then
                local dl = self:player(controller).delayed_later
                dl[#dl + 1] = { card = parkedCard, index = parkedIndex, turns = fx.delayTurns }
            end
            return
        end
        -- "At the end of the turn, ...": parked until this turn ends, whoever's it is.
        if fx.delayEnd then
            if parkedCard then
                s.end_of_turn[#s.end_of_turn + 1] = { seat = controller, card = parkedCard, index = parkedIndex,
                    source = source }
            end
            return
        end
        local previousTarget = #frame.previous_targets > 0 and frame.previous_targets[#frame.previous_targets] or 0
        if fx.requiresPrevious and previousTarget == 0 then return end
        if fx.op == "DISCOVER" and fx.discoverTakeAll then
            local payer = self:player(controller)
            if fx == stored then fx = copyEffect(fx) end
            local takeAllMet = self:condition_holds(fx, controller, source, previousTarget)
            fx.discoverTakeAll = takeAllMet and payer.corpses >= fx.corpseCost
            if fx.discoverTakeAll then
                payer.corpses = payer.corpses - fx.corpseCost
                self:quest_count(controller, "SPEND_CORPSES", 0, fx.corpseCost)
            end
            fx.condition = "NONE"
            fx.corpseCost = 0
        end
        if not self:condition_holds(fx, controller, source, previousTarget) then return end

        local handPick = {}
        if fx.target.kind == "CHOOSE" and (fx.target.side == "FRIENDLY_HAND_MINIONS" or fx.target.side == "FRIENDLY_HAND") then
            local candidates = {}
            for _, id in ipairs(self:side_ids(fx.target.side, controller, source)) do
                if id ~= source and self:target_matches_filters(id, fx, source) then candidates[#candidates + 1] = id end
            end
            if fx.prompt then
                local answered = #frame.previous_targets > 0 and frame.previous_targets[#frame.previous_targets] or 0
                if contains(candidates, answered) then
                    handPick[1] = answered
                elseif #candidates > 0 then
                    local p = s.pending
                    p.active = true
                    p.seat = controller
                    p.kind = "hand_action"
                    p.options = { 5 }
                    p.card_options = {}
                    for _, id in ipairs(candidates) do
                        local cd = self:def_of(id)
                        if cd then p.card_options[#p.card_options + 1] = cd.id end
                    end
                    self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                    p.resume_same = true
                    return STOP
                end
            elseif #candidates > 0 then
                handPick[1] = candidates[rng:intBelow(#candidates) + 1]
            end
            if #handPick == 0 then return end
        end

        local additive, additiveAboutIt = {}, {}
        if #fx.replacement > 0 then
            local instead = {}
            local subject = (fx.target.kind == "CHOOSE" and chosen ~= 0) and chosen or previousTarget
            for _, child in ipairs(fx.replacement) do
                local aboutIt = ABOUT_IT[child.condition] == true
                if self:condition_holds(child, controller, source, aboutIt and subject or previousTarget) then
                    if child.additional and aboutIt then
                        local held = copyEffect(child)
                        held.condition = "NONE"
                        additiveAboutIt[#additiveAboutIt + 1] = held
                    elseif child.additional then
                        -- A coin is rolled once, here.
                        local held = child
                        if child.condition == "CHANCE" then
                            held = copyEffect(child)
                            held.condition = "NONE"
                        end
                        additive[#additive + 1] = held
                    else
                        local held = child
                        if aboutIt or child.condition == "CHANCE" then
                            held = copyEffect(child)
                            held.condition = "NONE"
                        end
                        instead[#instead + 1] = held
                    end
                end
            end
            if #instead > 0 then
                local named = (fx.target.kind == "CHOOSE" and chosen ~= 0) and chosen or triggerSource
                self:run_effect_list(instead, source, trigger, chosen, named, frame)
                if self.aborted then return STOP end
                return
            end
        end
        if fx.corpseCost > 0 then
            local payer = self:player(controller)
            if payer.corpses < fx.corpseCost then return end
            if fx.target.kind == "PREVIOUS" and previousTarget == 0 and #frame.previous_targets == 0 then return end
            payer.corpses = payer.corpses - fx.corpseCost
            self:quest_count(controller, "SPEND_CORPSES", 0, fx.corpseCost)
        end
        if fx.armorCost > 0 then
            local hero = self:ent(self:player(controller).hero_id)
            if not hero or hero.armor < fx.armorCost then return end
            hero.armor = hero.armor - fx.armorCost
        end
        if fx.discardCostSchool ~= 0 then
            local paid = 0
            for _, handId in ipairs(self:hand_ids(controller)) do
                local hd = self:def_of(handId)
                if hd and hd.schoolNum + 1 == fx.discardCostSchool then
                    paid = handId
                    break
                end
            end
            if paid == 0 then return end
            self:relocate(paid, ZONE.GRAVEYARD, -1)
        end
        if fx.deckCostToken ~= "" then
            local paid = 0
            for _, deckId in ipairs(self:deck_ids(controller)) do
                if s.entities[deckId].card_id == fx.deckCostToken then
                    paid = deckId
                    break
                end
            end
            if paid == 0 then return end
            self:relocate(paid, ZONE.GRAVEYARD, -1)
        end

        local resolved = copyEffect(fx)
        if fx.op == "DAMAGE" then
            self.last_effect_count = fx.amount
            self.last_blow = -1   -- the blow this line deals replaces the printed number below
        end
        local eventCard = triggerSource ~= 0 and triggerSource ~= source and trigger ~= "ON_PLAY"
            and trigger ~= "BATTLECRY"
        local valueOf = #frame.previous_targets > 0 and frame.previous_targets[#frame.previous_targets]
            or (fx.target.kind == "CHOOSE" and chosen) or (eventCard and triggerSource) or 0
        local vs = fx.valueSource
        if (vs == "PREVIOUS_ATTACK" or vs == "PREVIOUS_HEALTH" or vs == "PREVIOUS_COST" or vs == "PREVIOUS_STATS")
            and valueOf ~= 0 then
            local prev = self:ent(valueOf)
            if prev then
                if vs == "PREVIOUS_ATTACK" then
                    resolved.amount = prev.attack
                elseif vs == "PREVIOUS_HEALTH" then
                    resolved.amount = prev.health
                elseif vs == "PREVIOUS_STATS" then
                    -- "Gain its stats": its Attack and its Health.
                    resolved.amount = prev.attack
                    resolved.amount2 = prev.health
                    resolved.pairValue = true
                else
                    resolved.amount = self:card_cost(prev.controller, valueOf)
                end
                if not resolved.pairValue then
                    if fx.statsBoth then resolved.amount2 = resolved.amount end
                    if fx.healthOnly then
                        resolved.amount2 = resolved.amount
                        resolved.amount = 0
                    end
                    -- "Summon a random minion with the same Cost": an exact bound, 0 included.
                    if fx.op == "SUMMON_RANDOM" then resolved.resolvedCost = math.max(0, resolved.amount) end
                end
            end
            resolved.valueSource = "NONE"
        end
        local targetless = isTargetless(fx)
        local countsItself = fx.op == "SUMMON_COPY" or fx.op == "SUMMON_FROM_DECK"
        local rep = (countsItself or fx["repeat"] < 1) and 1 or fx["repeat"]
        if fx.split and fx.op == "DAMAGE" and rep == 1 and resolved.amount > 1 then
            rep = resolved.amount
            resolved.amount = 1
        end
        if fx.split and fx.spell and fx.op == "DAMAGE" and source ~= 0 then
            local caster = self:ent(source)
            if caster then
                rep = rep + self:spell_bonus(caster.controller) * (fx.doubleSpellDamage and 2 or 1)
                resolved.spell = false
            end
        end

        if fx.repeatLess and fx.op == "DAMAGE" and not targetless then
            for amount = fx.amount, 1, -1 do
                if not self:step_budget() then return STOP end
                local one = copyEffect(resolved)
                one.repeatLess = false
                one.amount = amount
                local hits = fx.target.kind == "PREVIOUS" and frame.previous_targets
                    or self:resolve_targets(one, source, chosen, triggerSource, controller)
                for _, t in ipairs(hits) do
                    self:apply_op(one, t, source, controller)
                    if self.aborted then return STOP end
                end
                self:answer_hero_damage()
            end
            return
        end
        if not targetless and fx.target.kind == "RANDOM" and rep > 1 and not fx.split then
            local used = {}
            for _ = 1, rep do
                if not self:step_budget() then return STOP end
                local pool = {}
                for _, id in ipairs(self:side_ids(fx.target.side, controller, source)) do
                    local cand = self:ent(id)
                    -- Health matters on the board: a card in a deck or hand has none and is still a card.
                    if cand and not cand.flags.dead
                        and not ((cand.zone == ZONE.BOARD or cand.zone == ZONE.HERO) and cand.health <= 0)
                        and not (not fx.repeatPerCount and not fx.repeatPrinted and contains(used, id))
                        and self:target_matches_filters(id, fx, source) then
                        pool[#pool + 1] = id
                    end
                end
                if #pool == 0 then break end
                local picked = pool[rng:intBelow(#pool) + 1]
                used[#used + 1] = picked
                self:apply_op(resolved, picked, source, controller)
                runFollowUps(fx, picked)
                self:answer_hero_damage()
                if self.aborted then return STOP end
                if s.pending.active and s.pending.effect_index < 0 and targetless then
                    self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                    return STOP
                end
            end
            return
        end
        for n = 0, rep - 1 do
            if not self:step_budget() then return STOP end
            -- "Deal 1 damage to the enemy hero four times": each hit is answered before the next one lands.
            if n > 0 then
                self:answer_hero_damage()
                if self.aborted then return STOP end
            end
            if targetless then
                -- "Summon four 2/2 Treants that attack it": the minion the summon's own target names.
                local kind = fx.target.kind
                self.summon_defender = kind == "CHOOSE" and chosen or kind == "TRIGGER_SOURCE" and triggerSource
                    or kind == "PREVIOUS" and previousTarget or 0
                self:apply_op(resolved, 0, source, controller)
                self.summon_defender = 0
                runFollowUps(fx, 0)
                if s.pending.active and s.pending.effect_index < 0 then
                    self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                    return STOP
                end
                -- "They are Temporary": the cards this moved leave the hand at the end of the turn.
                if fx.temporary and (fx.op == "DRAW" or fx.op == "ADD_TO_HAND" or fx.op == "FILL_HAND") then
                    for _, id in ipairs(self.drawn_this_effect) do
                        local made = self:ent(id)
                        if made and made.zone == ZONE.HAND then made.temp_card = true end
                    end
                end
                if fx.op == "DRAW" or fx.op == "ADD_TO_HAND" or fx.op == "FILL_HAND" or fx.op == "EXCAVATE" then
                    frame.previous_targets = copyList(self.drawn_this_effect)
                end
                if (fx.op == "DISCARD_HIGHEST" or fx.op == "DISCARD_LOWEST") and #self.discarded_this_effect > 0 then
                    frame.previous_targets = copyList(self.discarded_this_effect)
                end
                if fx.op == "SHUFFLE" and fx.deckPosition ~= 0 and #self.shuffled_this_effect > 0 then
                    frame.previous_targets = copyList(self.shuffled_this_effect)
                end
                if SUMMONISH[fx.op] and #self.summoned_this_effect > 0 then
                    frame.previous_targets = { self.summoned_this_effect[#self.summoned_this_effect] }
                end
                if self.aborted then return STOP end
            else
                local effectiveChosen = chosen
                local playerChooses = trigger == "ON_PLAY" or trigger == "BATTLECRY" or trigger == "CORRUPT"
                    or trigger == "FORGED"
                local skipRep = false
                if fx.target.kind == "CHOOSE" and (trigger == "END_TURN" or trigger == "START_TURN"
                    or (not playerChooses and #handPick == 0)) then
                    local pool = {}
                    for _, id in ipairs(self:choose_targets(fx.target.side, controller, source)) do
                        if self:target_matches_filters(id, fx, source) then pool[#pool + 1] = id end
                    end
                    if #pool == 0 then
                        skipRep = true
                    elseif chosen > 0 and contains(pool, chosen) then
                        -- A MARKED target is kept while it is still legal (Corruption).
                        effectiveChosen = chosen
                    else
                        effectiveChosen = pool[rng:intBelow(#pool) + 1]
                    end
                end
                if not skipRep then
                    local targets
                    if #handPick > 0 then
                        targets = handPick
                    elseif fx.target.kind == "PREVIOUS" then
                        targets = frame.previous_targets
                    else
                        targets = self:resolve_targets(fx, source, effectiveChosen, triggerSource, controller)
                    end
                    if #targets == 0 and fx.target.kind == "PREVIOUS" and trigger == "DEATHRATTLE" then
                        local maker = self:ent(source)
                        if maker and maker.made_minion ~= 0 then
                            local made = self:ent(maker.made_minion)
                            if made and made.zone == ZONE.BOARD and not made.flags.dead then
                                targets = { maker.made_minion }
                            end
                        end
                    end
                    -- A Deathrattle's trigger source is the minion itself, which "it" never names.
                    if #targets == 0 and fx.target.kind == "PREVIOUS" and triggerSource ~= 0
                        and trigger ~= "ON_PLAY" and trigger ~= "BATTLECRY" and trigger ~= "DEATHRATTLE" then
                        targets = { triggerSource }
                    end
                    if fx.op == "BUFF" and fx.target.kind == "ALL" and fx.target.side == "FRIENDLY_MINIONS"
                        and (fx.buffHand or fx.buffDeck) then
                        targets = copyList(targets)
                        local function add(ids)
                            for _, id in ipairs(ids) do
                                local td = self:def_of(id)
                                if td and td.type == "MINION" then targets[#targets + 1] = id end
                            end
                        end
                        if fx.buffHand then add(self:hand_ids(controller)) end
                        if fx.buffDeck then add(self:deck_ids(controller)) end
                    end
                    -- "Destroy the top 3 cards of your deck": that many cards from that end. The top is the next draw.
                    if fx.deckPosition ~= 0 and (fx.target.side == "FRIENDLY_DECK" or fx.target.side == "ENEMY_DECK") then
                        targets = copyList(targets)
                        E.stable_sort(targets, function(a, b)
                            local ea, eb = self:ent(a), self:ent(b)
                            return (ea and ea.zone_pos or 0) < (eb and eb.zone_pos or 0)
                        end)
                        local count = math.min(#targets, math.max(1, fx.deckCount))
                        local kept = {}
                        if fx.deckPosition == 1 then
                            for i = 1, count do kept[i] = targets[i] end
                        else
                            for i = #targets - count + 1, #targets do kept[#kept + 1] = targets[i] end
                        end
                        targets = kept
                    end
                    local chosenBefore = copyList(frame.previous_targets)
                    local sourceDef = self:def_of(source)
                    local otherThanChosen = sourceDef ~= nil and sourceDef.type == "SPELL"
                        and fx.target.kind == "ALL" and (fx.excludeSource or fx.target.side == "ANY_OTHER_MINION"
                            or fx.target.side == "ANY_OTHER_CHARACTER")
                    frame.previous_targets = copyList(targets)
                    -- "Adapt your Murlocs": ONE choice for the group; the first target opens it for all.
                    self.adapt_group = {}
                    if fx.op == "ADAPT" and fx.target.kind ~= "SELF" then
                        for _, t in ipairs(targets) do
                            if self:target_matches_filters(t, fx, source) then
                                local e = self:ent(t)
                                if e and e.zone == ZONE.BOARD and not e.flags.dead then
                                    self.adapt_group[#self.adapt_group + 1] = t
                                end
                            end
                        end
                    end
                    for _, t in ipairs(targets) do
                        if self:target_matches_filters(t, fx, source)
                            and not (otherThanChosen and contains(chosenBefore, t))
                            and not (fx.op == "ADAPT" and #self.adapt_group > 0 and not contains(self.adapt_group, t)) then
                            self:apply_op(resolved, t, source, controller)
                            self.adapt_group = {}
                            runFollowUps(fx, t)
                            if self.aborted then return STOP end
                            if s.pending.active and s.pending.effect_index < 0 then
                                self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                                return STOP
                            end
                        end
                    end
                end
            end
        end
        -- What this effect summoned becomes the frame's PREVIOUS set; a summon that made nothing names nothing.
        if #self.summoned_this_effect > 0 or SUMMON_NAMES[fx.op] then
            frame.previous_targets = copyList(self.summoned_this_effect)
        end
        if fx.op == "COPY" and #self.copied_this_effect > 0 then
            frame.previous_targets = copyList(self.copied_this_effect)
        end
        -- "Get a Temporary copy of it": the copy leaves the hand at the end of the turn.
        if fx.op == "COPY" and fx.temporary then
            for _, id in ipairs(self.copied_this_effect) do
                local made = self:ent(id)
                if made and made.zone == ZONE.HAND then made.temp_card = true end
            end
        end
        if (fx.op == "SHUFFLE" or fx.op == "SHUFFLE_COPY_SELF") and #self.shuffled_this_effect > 0 then
            frame.previous_targets = copyList(self.shuffled_this_effect)
        end
        if fx.op == "BUFF_ZONE" and fx.buffRandom and #self.buffed_this_effect > 0 then
            frame.previous_targets = copyList(self.buffed_this_effect)
        end
        if #additive > 0 then
            self:run_effect_list(additive, source, trigger, chosen, triggerSource, frame)
            if self.aborted then return STOP end
        end
        if #additiveAboutIt > 0 then
            local named = (fx.target.kind == "CHOOSE" and chosen ~= 0) and chosen or triggerSource
            self:run_effect_list(additiveAboutIt, source, trigger, chosen, named, frame)
            if self.aborted then return STOP end
        end
    end

    -- Returns nil to run the next line, STOP to leave the list, or a number: the index the next line is.
    local function runLine(effectIndex)
        flushRemembered()
        self:answer_hero_damage()
        if self.aborted then return STOP end
        local stored = effects[effectIndex + 1]
        if stored.printOnly then return end
        -- A DESTROY for both players runs once for each side, the controller's first.
        if stored.op == "DESTROY" and stored.bothPlayers and stored.trigger == trigger then
            local mine = copyEffect(stored)
            mine.bothPlayers = false
            local theirs = copyEffect(mine)
            theirs.target = {}
            for k, v in pairs(mine.target) do theirs.target[k] = v end
            theirs.target.side = MIRRORED[mine.target.side] or mine.target.side
            self:run_effect_list({ mine, theirs }, source, trigger, chosen, triggerSource, frame, 0, controllerOverride)
            if self.aborted or (s.pending.active and s.pending.source == source) then return STOP end
            return
        end
        if stored.op == "REPEAT_IF" and stored.trigger == trigger then
            if not self:settle() then return STOP end
            if self.aborted or self:is_terminal() or (s.pending.active and s.pending.source == source) then
                return STOP
            end
            local again = false
            local dyingNow = countDying()
            local previous = frame.previous_targets
            local function dead(id)
                local e = self:ent(id)
                local ed = self:def_of(id)
                return not e or e.flags.dead or e.health <= 0 or e.zone == ZONE.GRAVEYARD
                    or (ed ~= nil and ed.type == "LOCATION") or e.flags.dormant_turns > 0
            end
            local mode = stored.amount2
            if mode == 1 then
                again = dyingNow > dyingAtPass
            elseif mode == 2 then
                again = dyingNow == dyingAtPass
            elseif mode == 3 then
                again = #previous > 0
                for _, id in ipairs(previous) do if not dead(id) then again = false end end
            elseif mode == 7 then
                again = #previous > 0
                for _, id in ipairs(previous) do if dead(id) then again = false end end
            elseif mode == 4 then
                for _, side in ipairs({ 0, 1 }) do
                    for _, id in ipairs(self:board_ids(side)) do again = again or not dead(id) end
                end
            elseif mode == 5 then
                local function living(side)
                    local n = 0
                    for _, id in ipairs(self:board_ids(side)) do if not dead(id) then n = n + 1 end end
                    return n
                end
                again = living(1 - controller) > living(controller)
            elseif mode == 6 then
                for _, id in ipairs(previous) do
                    local e = self:ent(id)
                    if e and band(e.keywords, KW.DEATHRATTLE) ~= 0 then again = true end
                end
            end
            if mode == 2 or mode == 7 then
                local anyAlive = false
                for _, side in ipairs({ 0, 1 }) do
                    for _, id in ipairs(self:board_ids(side)) do anyAlive = anyAlive or not dead(id) end
                end
                again = again and anyAlive
            end
            local cap = stored["repeat"] > 1 and stored["repeat"] or 15
            if again and repeatPasses + 1 < cap and s.loop_steps < 420 and not self.aborted and self:step_budget() then
                repeatPasses = repeatPasses + 1
                dyingAtPass = dyingNow
                -- A recast spell Overloads again.
                local cast = self:def_of(source)
                if cast and cast.type == "SPELL" and cast.overload > 0 and trigger == "ON_PLAY" then
                    local p = self:player(controller)
                    p.overload_next = p.overload_next + cast.overload
                    p.game_mana_overloaded = p.game_mana_overloaded + cast.overload
                end
                return startIndex
            end
            return
        end
        if #self.summoned_this_effect > 0 and (trigger == "BATTLECRY" or trigger == "ON_PLAY") then
            local maker = self:ent(source)
            if maker and maker.zone == ZONE.BOARD then
                maker.made_minion = self.summoned_this_effect[#self.summoned_this_effect]
            end
        end
        self.summoned_this_effect = {}
        self.copied_this_effect = {}
        self.shuffled_this_effect = {}
        self.buffed_this_effect = {}
        self.drawn_this_effect = {}
        self.discarded_this_effect = {}
        local upgrade = trigger == "ON_PLAY" and src ~= nil
            and ((stored.trigger == "CORRUPT" and src.flags.corrupted) or (stored.trigger == "FORGED" and src.flags.forged))
        if stored.trigger ~= trigger and not upgrade then return end
        -- "... while this is in your hand" answers only from its owner's hand; the hand scan runs only such lines.
        if stored.inHand ~= 0 then
            if not src or src.zone ~= ZONE.HAND then return end
        elseif source == self.hand_scan_source then
            return
        end
        local fx = self:scaled_effect(stored, controller, source)
        -- "Freeze that many enemy minions": the clause runs once for each of what the clause before took.
        if stored.repeatPerCount and stored.amountSource == "NONE"
            and (stored.valueSource == "PREVIOUS_MUCH" or stored.valueSource == "PREVIOUS_AMOUNT") then
            fx = copyEffect(stored)
            fx["repeat"] = math.max(0, self.last_effect_count) * math.max(1, stored["repeat"])
            fx.valueSource = "NONE"
            if stored.op ~= "DAMAGE" then fx.repeatPerCount = false end
        end
        if stored.amountSource == "MINIONS_DYING" and not self:resolve_deaths() then return STOP end
        if fx["repeat"] < 1 and (stored.repeatPerCount or ((stored.amountSource ~= "NONE" or stored.countSelector
            or stored.valueSource == "PREVIOUS_AMOUNT" or stored.valueSource == "PREVIOUS_MUCH")
            and CREATES[stored.op])) then
            return
        end
        self.effect_index = effectIndex
        -- "Shuffle ... into your deck with permanent +2/+1": the set_verb BUFF on what a shuffle of its own made.
        local lineBefore = effectIndex > 0 and effects[effectIndex] or nil
        local outerPermanent = self.permanent_buff
        self.permanent_buff = stored.op == "BUFF" and stored.setVerb and stored.target.kind == "PREVIOUS"
            and lineBefore ~= nil and (lineBefore.op == "SHUFFLE" or lineBefore.op == "SHUFFLE_COPY_SELF")
            and lineBefore.target.kind ~= "PREVIOUS"
        local result = runRest(stored, fx, effectIndex)
        self.permanent_buff = outerPermanent
        if stored.remember then rememberAfter = effectIndex end
        return result
    end

    local effectIndex = startIndex
    while effectIndex < #effects do
        local r = runLine(effectIndex)
        if r == STOP then return end
        effectIndex = type(r) == "number" and r or effectIndex + 1
    end
    flushRemembered()
    -- The last line's last hit.
    self:answer_hero_damage()
end

-- ---- target questions for plays ----------------------------------------------------------------

function E:card_choose_targets_for(card, effects, trigger, controller, source)
    local out = {}
    for _, fx in ipairs(effects) do
        local relevant = fx.trigger == trigger
        if trigger == "ON_PLAY" and fx.trigger == "BATTLECRY" then relevant = true end
        if trigger == "ON_PLAY" and card.type == "SPELL" and fx.trigger == "START_TURN" and fx.prompt then relevant = true end
        if relevant and fx.target.kind == "CHOOSE" then
            for _, t in ipairs(self:choose_targets(fx.target.side, controller, source)) do
                if self:target_matches_filters(t, fx, source)
                    and not (fx.op == "TRIGGER_DEATHRATTLE" and not self:has_deathrattle(t))
                    and not contains(out, t) then
                    out[#out + 1] = t
                end
            end
        end
    end
    table.sort(out)
    return out
end

function E:card_choose_targets(card, trigger, controller, source)
    return self:card_choose_targets_for(card, card.effects, trigger, controller, source)
end

local NOT_OFFERED = { YOUR_WEAPON = true, ENEMY_WEAPON = true, ENEMY_SECRET = true, FRIENDLY_HAND_MINIONS = true,
    FRIENDLY_HAND = true, FRIENDLY_DECK = true, ENEMY_DECK = true }

function E:requires_chosen_target(card, effects)
    for _, fx in ipairs(effects) do
        local asks = fx.trigger == "ON_PLAY" or (card.type == "SPELL" and fx.trigger == "START_TURN" and fx.prompt)
        if asks and not NOT_OFFERED[fx.target.side] and fx.target.kind == "CHOOSE"
            and (fx.condition == "NONE" or fx.condition == "") and not fx.printOnly then
            return true
        end
    end
    return false
end

-- ---- combat ------------------------------------------------------------------------------------

-- "Can only attack if you cast a spell this turn": a default EffectSpec carrying only the condition.
local CAST_SPELL_CONDITION = D.copyEffect({ condition = "CAST_SPELL_THIS_TURN" })
function E:can_minion_attack(id)
    local e = self:ent(id)
    if not e or e.zone ~= ZONE.BOARD then return false end
    -- A location never attacks, whatever Attack a buff gave it.
    if self:is_location(id) then return false end
    if e.flags.dormant_turns > 0 then return false end
    if e.flags.exhausted or e.flags.frozen then return false end
    local d = self:def_of(id)
    -- Silence takes "Can't attack" away; a given one counts too.
    if d and not e.flags.silenced and (d.cant_attack or band(bor(d.keywords, e.keywords), KW.CANT_ATTACK) ~= 0) then
        return false
    end
    if d and not e.flags.silenced then
        for _, fx in ipairs(d.effects) do
            if fx.op == "CANT_ATTACK_UNLESS" then
                if fx.amount2 == 3 then
                    if e.health < e.max_health then return false end
                elseif fx.amount2 == 2 then
                    local hero = self:hero_of(e.controller)
                    if not hero or hero.armor < (fx.amount > 0 and fx.amount or 7) then return false end
                elseif fx.amount2 == 5 then
                    if #self:hand_ids(e.controller) < fx.amount then return false end
                elseif fx.amount2 == 4 then
                    if not self:condition_holds(CAST_SPELL_CONDITION, e.controller, e.id, 0) then return false end
                else
                    local hero = self:hero_of(e.controller)
                    if not hero or hero.flags.attacks_this_turn <= 0 then return false end
                end
            end
        end
    end
    if e.attack <= 0 then return false end
    if self:titan_abilities_left(id) > 0 then return false end
    local limit = band(e.keywords, KW.WINDFURY) ~= 0 and 2 or 1
    return e.flags.attacks_this_turn < limit
end

function E:titan_abilities_left(id)
    local e, d = self:ent(id), self:def_of(id)
    if not e or not d or #d.titan_abilities == 0 or e.flags.silenced then return 0 end
    local left = 0
    for i = 1, #d.titan_abilities do
        if band(e.titan_used, bit.lshift(1, i - 1)) == 0 then left = left + 1 end
    end
    return left
end

function E:titan_can_act(id)
    local e = self:ent(id)
    if not e or e.zone ~= ZONE.BOARD or e.flags.dormant_turns > 0 or e.flags.frozen then return false end
    if self:titan_abilities_left(id) == 0 then return false end
    local limit = band(e.keywords, KW.WINDFURY) ~= 0 and 2 or 1
    return e.flags.attacks_this_turn < limit
end

function E:hero_attack_keywords(seat)
    local hero = self:hero_of(seat)
    if not hero then return 0 end
    local kw = hero.keywords
    local w = self:ent(self:player(seat).weapon_id)
    if w and w.zone == ZONE.WEAPON and not w.flags.silenced then kw = bor(kw, w.keywords) end
    return kw
end

function E:can_hero_attack(seat)
    local hero = self:hero_of(seat)
    if not hero or hero.flags.exhausted or hero.flags.frozen then return false end
    if hero.attack <= 0 then return false end
    local limit = band(self:hero_attack_keywords(seat), KW.WINDFURY) ~= 0 and 2 or 1
    return hero.flags.attacks_this_turn < limit
end

local function cardEntityFor(self, attacker)
    local a = self:ent(attacker)
    if not a then return nil end
    local card = attacker
    if a.zone == ZONE.HERO then
        local weapon = self:player(a.owner).weapon_id
        if weapon == 0 then return nil, a end
        card = weapon
    end
    return card, a
end

function E:has_cant_attack_heroes(attacker)
    local a = self:ent(attacker)
    if not a then return false end
    local card = attacker
    if a.zone == ZONE.HERO then
        -- "Gain +10 Attack and can't attack heroes this turn" binds a hero without a weapon as well.
        if a.flags.cant_attack_heroes_this_turn then return true end
        local weapon = self:player(a.owner).weapon_id
        if weapon == 0 then return false end
        card = weapon
    end
    local src = self:ent(card)
    if src and src.flags.silenced then return false end
    if a.flags.cant_attack_heroes_this_turn then return true end
    local d = self:def_of(card)
    if not d then return false end
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "AURA" and fx.op == "CANT_ATTACK_HEROES" then return true end
    end
    return false
end

function E:has_cleave(attacker)
    local card, a = cardEntityFor(self, attacker)
    if not a or not card then return false end
    local src = self:ent(card)
    if src and src.flags.silenced then return false end
    local d = self:def_of(card)
    if not d then return false end
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "AURA" and fx.op == "CLEAVE" then return true end
    end
    return false
end

-- Run wave 93: "All minions have a 50% chance to attack the wrong enemy" (GVG_112), read off any minion in play for
-- every attacking minion, and "Enemies attacking this have a 50% chance to attack someone else" (TRL_532), read off
-- the defender. The attacker's own line is own_misdirect_chance.
function E:misdirect_chance(attacker, target)
    local boardChance = 0
    local who = self:ent(attacker)
    if who and who.zone == ZONE.BOARD then
        for side = 0, 1 do
            for _, id in ipairs(self:board_ids(side)) do
                local m = self:ent(id)
                if m and not m.flags.silenced and m.flags.dormant_turns == 0 then
                    local md = self:def_of(id)
                    if md then
                        for _, fx in ipairs(md.effects) do
                            if fx.trigger == "AURA" and fx.op == "MISDIRECT" and fx.target.kind == "ALL"
                                and fx.target.side == "ANY_MINION" then
                                boardChance = math.max(boardChance, fx.amount)
                            end
                        end
                    end
                end
            end
        end
    end
    local defender = self:ent(target)
    if defender and defender.zone == ZONE.BOARD and not defender.flags.silenced then
        local dd = self:def_of(target)
        if dd then
            for _, fx in ipairs(dd.effects) do
                if fx.trigger == "AURA" and fx.op == "MISDIRECT" and fx.target.kind == "ALL"
                    and fx.target.side == "ENEMY_CHARACTER" then
                    boardChance = math.max(boardChance, fx.amount)
                end
            end
        end
    end
    local own = self:own_misdirect_chance(attacker)
    return math.max(own, boardChance)
end

function E:attack_targets(attacker)
    local a = self:ent(attacker)
    if not a then return {} end
    local foe = other(a.controller)
    local taunts = {}
    for _, id in ipairs(self:board_ids(foe)) do
        local e = self:ent(id)
        if e and band(e.keywords, KW.TAUNT) ~= 0 and band(e.keywords, KW.STEALTH) == 0 and e.flags.dormant_turns == 0
            and not self:is_location(id) then
            taunts[#taunts + 1] = id
        end
    end
    if #taunts > 0 then return taunts end
    local canHitHero = true
    if self:has_cant_attack_heroes(attacker) then canHitHero = false end
    if a.zone == ZONE.BOARD and band(a.keywords, KW.RUSH) ~= 0 and band(a.keywords, KW.CHARGE) == 0
        and a.flags.just_played_turn == self.state.turn then
        canHitHero = false
    end
    local out = {}
    for _, id in ipairs(self:board_ids(foe)) do
        local e = self:ent(id)
        if e and band(e.keywords, KW.STEALTH) == 0 and e.flags.dormant_turns == 0 and not self:is_location(id) then
            out[#out + 1] = id
        end
    end
    if canHitHero then
        local hero = self:hero_of(foe)
        if hero then out[#out + 1] = hero.id end
    end
    table.sort(out)
    return out
end

-- An attack an effect forces ("it attacks a random enemy"): resolved like any attack, but it spends none of the
-- attacker's own attacks this turn.
function E:forced_attack(attacker, target)
    local before = self:ent(attacker)
    local spent = before and before.flags.attacks_this_turn or 0
    self:resolve_attack(attacker, target)
    local after = self:ent(attacker)
    if after then after.flags.attacks_this_turn = spent end
end

function E:resolve_attack(attacker, target)
    local s = self.state
    local chance = self:misdirect_chance(attacker, target)
    if chance > 0 then
        local a = self:ent(attacker)
        if a then
            local wrong = s.rng:intBelow(100) < chance
            if wrong then
                local pool = {}
                for _, id in ipairs(self:side_ids("ENEMY_CHARACTER", a.controller, attacker)) do
                    local e = self:ent(id)
                    if e and not e.flags.dead and e.health > 0 and id ~= target then pool[#pool + 1] = id end
                end
                if #pool > 0 then target = pool[s.rng:intBelow(#pool) + 1] end
            end
        end
    end
    self:emit_event("ATTACK_DECLARED", attacker, target)
    local a, d = self:ent(attacker), self:ent(target)
    if not a or not d then return end
    local whileAttacking = false
    if a.zone == ZONE.BOARD and not a.flags.silenced then
        local own = self:def_of(attacker)
        if own then
            for _, fx in ipairs(own.effects) do
                whileAttacking = whileAttacking or (fx.trigger == "AURA" and fx.whileAttacking)
            end
        end
    end
    if whileAttacking then
        self.attacking_now = attacker
        self:recompute_auras()
    end
    local attackerAttack = a.attack
    local defenderAttack = d.zone == ZONE.HERO and 0 or d.attack
    self.attacking_weapon = a.zone == ZONE.HERO and self:player(a.owner).weapon_id or 0
    local blowsFrom = #self.pending_events   -- hero damage this attack raises starts after here
    self:deal_damage(target, attackerAttack, attacker, false)
    if d.zone == ZONE.BOARD and self:has_cleave(attacker) and a.attack > 0 then
        local board = self:board_ids(d.owner)
        for i, id in ipairs(board) do
            if id == target then
                if i > 1 then self:deal_damage(board[i - 1], attackerAttack, attacker, false) end
                if i < #board then self:deal_damage(board[i + 1], attackerAttack, attacker, false) end
                break
            end
        end
    end
    local attackerKeywords = a.zone == ZONE.HERO and self:hero_attack_keywords(a.owner) or a.keywords
    local attackerImmune = band(attackerKeywords, KW.IMMUNE_ATTACKING) ~= 0 or a.flags.immune
    self.attacking_weapon = 0
    if E.isCharacter(d) and not attackerImmune and defenderAttack > 0 then
        self:deal_damage(attacker, defenderAttack, target, false)
    end
    -- "After a hero takes damage" answers the blows of this attack now, before the death pass.
    for i = blowsFrom + 1, #self.pending_events do
        local ev = self.pending_events[i]
        if ev.trigger == "AFTER_HERO_DAMAGED" then ev.now = true end
    end
    self:answer_hero_damage()
    if whileAttacking then
        self.attacking_now = 0
        self:recompute_auras()
    end
    a.flags.attacks_this_turn = a.flags.attacks_this_turn + 1
    a.flags.has_attacked = true
    if a.zone == ZONE.HERO then
        local p = self:player(a.owner)
        p.game_hero_attacks = p.game_hero_attacks + 1
        self:quest_count(a.owner, "HERO_ATTACK", attacker, 1)   -- run 16: "Attack 5 times with your hero"
    end
    if a.zone == ZONE.BOARD then
        local victim = self:ent(target)
        if victim and victim.zone == ZONE.BOARD and victim.flags.dead then
            local own = self:def_of(attacker)
            if own then
                for _, fx in ipairs(own.effects) do
                    if fx.op == "MAY_ATTACK_AGAIN" then
                        a.flags.has_attacked = false
                        if a.flags.attacks_this_turn > 0 then a.flags.attacks_this_turn = a.flags.attacks_this_turn - 1 end
                        break
                    end
                end
            end
        end
    end
    local victim = self:ent(target)
    if victim and victim.zone == ZONE.BOARD and victim.flags.dead then
        local weaponId = self:player(a.owner).weapon_id
        local subject = a.zone == ZONE.HERO and (weaponId ~= 0 and weaponId or attacker) or attacker
        if subject ~= 0 then
            self:queue("AFTER_ATTACK_KILL", a.controller, subject, target)
        end
    end
    if band(a.keywords, KW.STEALTH) ~= 0 then
        a.keywords = band(a.keywords, bnot(KW.STEALTH))
        a.flags.stealth = false
        self.stealth_attackers[#self.stealth_attackers + 1] = attacker
    end
    if a.zone == ZONE.HERO then
        local p = self:player(a.owner)
        local weapon = self:ent(p.weapon_id)
        if weapon then
            weapon.durability = weapon.durability - 1
            if weapon.durability <= 0 then
                self.broken_weapon = p.weapon_id
                self:destroy_weapon(a.owner)
            end
        end
    end
    self.pending_attack = attacker
    self.pending_attack_target = target
    if d.zone == ZONE.BOARD then
        self:queue("WHEN_YOUR_MINION_ATTACKED", d.owner, target)
    elseif d.zone == ZONE.HERO then
        self:queue("WHEN_YOUR_HERO_ATTACKED", d.owner, attacker)
        self:queue("AFTER_YOUR_HERO_ATTACKED", d.owner, attacker)
    end
    if a.zone == ZONE.BOARD then
        self:queue("WHEN_ENEMY_MINION_ATTACKS", other(a.owner), attacker)
        -- A declared attack answered this before the blow (apply_attack); a forced attack queues it here.
        if self.friendly_attack_fired ~= attacker then
            self:queue("WHEN_FRIENDLY_MINION_ATTACKS", a.owner, attacker)
        end
        self.friendly_attack_fired = 0
    end
end

-- (Goes after E:card_choose_targets.)
function E:card_needs_target(card, trigger, source)
    local src = self:ent(source)
    local controller = src and src.controller or 0
    return #self:card_choose_targets(card, trigger, controller, source) > 0
end

-- The triggers some card's "while this is in your hand" line answers, gathered once from the catalogue.
local inHandTriggers = nil
function E:in_hand_listens(trigger)
    if not inHandTriggers then
        -- Read from the exported programs, not def(): building every CardDef here stalled the client once per
        -- session and kept ~5,000 of them alive. Same answer: def() takes `effects` as exported, with defaults.
        inHandTriggers = {}
        local defaults = D.EFFECT_DEFAULTS
        for _, cid in ipairs(D.all()) do
            local prog = TC.Programs[cid]
            if prog and prog.effects then
                for _, fx in ipairs(prog.effects) do
                    if (fx.inHand or defaults.inHand) ~= 0 then inHandTriggers[fx.trigger or defaults.trigger] = true end
                end
            end
        end
    end
    return inHandTriggers[trigger] == true
end

-- "Your Deathrattles / end of turn effects / Secrets trigger twice": `kind` is the TRIGGERS_TWICE bit (amount2), and
-- `minion` whether the doubled thing is a minion's (amount 1 doubles only those).
function E:triggers_twice(seat, kind, minion)
    if minion == nil then minion = true end
    local function doubles(id)
        local d = self:def_of(id)
        if not d then return false end
        for _, fx in ipairs(d.effects) do
            if fx.trigger == "AURA" and fx.op == "TRIGGERS_TWICE" and band(fx.amount2, kind) ~= 0
                and (minion or fx.amount ~= 1) then
                return true
            end
        end
        return false
    end
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e and not e.flags.silenced and e.health > 0 and doubles(id) then return true end
    end
    local weapon = self:player(seat).weapon_id
    if weapon ~= 0 and doubles(weapon) then return true end
    for _, row in ipairs(self.state.persistent) do
        if row.owner == seat and doubles(row.source) then
            local d = self:def_of(row.source)
            if d and d.type == "SPELL" then return true end
        end
    end
    return false
end

function E:spell_casts_twice(seat, spell)
    local p = self:player(seat)
    -- "Your next spell casts twice" is spent by the next spell whatever else doubles it.
    local spent = false
    if p.twice_spells_turn > 0 then
        p.twice_spells_turn = p.twice_spells_turn - 1
        spent = true
    elseif p.twice_spells > 0 then
        p.twice_spells = p.twice_spells - 1
        spent = true
    end
    if spent then return true end
    local function doubles(id)
        local d = self:def_of(id)
        if not d then return false end
        for _, fx in ipairs(d.effects) do
            if fx.trigger == "AURA" and fx.op == "TRIGGERS_TWICE" and band(fx.amount2, 32) ~= 0
                and (fx.schoolFilter == 0 or spell.schoolNum + 1 == fx.schoolFilter)
                and (fx.traitFilterNum == 0 or E.card_has_trait(spell, fx.traitFilterNum, p.hero_class, 0)) then
                return true
            end
        end
        return false
    end
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e and not e.flags.silenced and e.health > 0 and doubles(id) then return true end
    end
    local weapon = p.weapon_id
    if weapon ~= 0 and doubles(weapon) then return true end
    return false
end

function E:battlecry_twice(seat)
    -- The counter is spent by the next Battlecry even while Brann already doubles it.
    local p = self:player(seat)
    local spent = false
    if p.twice_battlecries_turn > 0 then
        p.twice_battlecries_turn = p.twice_battlecries_turn - 1
        spent = true
    end
    return spent or self:triggers_twice(seat, 1)
end

-- The second run of a doubled trigger: a Battlecry's keyword-conditioned lines ("Combo:", "Outcast:") are not doubled.
function E:run_doubled(source, trigger, chosen, subject)
    local d = self:def_of(source)
    if not d then return end
    if trigger ~= "BATTLECRY" or E.plain_battlecry(d) then
        self:run_effects(source, trigger, chosen, subject)
        return
    end
    local lines = {}
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "BATTLECRY" and not E.keyword_condition(fx.condition) then lines[#lines + 1] = fx end
    end
    self:run_effect_list(lines, source, trigger, chosen, subject, nil)
end

function E:run_printed_effects(source, trigger, chosen, triggerSource)
    local src = self:ent(source)
    if not src or src.flags.silenced then return end
    local d = self:def_of(source)
    if not d then return end
    if d.abilities then
        self:run_program_effects(source, trigger, chosen, triggerSource)
    else
        self:run_effect_list(d.effects, source, trigger, chosen, triggerSource, nil)
    end
    -- The text of every Magnetic minion attached to it is its own. Copied first: running them can move the host.
    local attached = {}
    for i, cid in ipairs(src.magnetized) do attached[i] = cid end
    for _, cid in ipairs(attached) do
        if self.aborted or (self.state.pending.active and self.state.pending.source == source) then return end
        local host = self:ent(source)
        if not host or host.flags.silenced then return end
        local m = def(cid)
        if m then
            self:run_effect_list(m.effects, source, trigger, chosen, triggerSource, nil)
        end
    end
end

-- The lines granted to the source ("give a minion 'At the end of your turn, ...'"), each grant's from its giver's
-- seat when it names one. A Silenced holder keeps what was granted after the Silence. Deathrattles run from
-- resolve_deaths.
function E:run_granted_effects(source, trigger, chosen, triggerSource)
    if trigger == "DEATHRATTLE" or self.aborted or self.state.pending.active then return end
    local src = self:ent(source)
    if not src or #src.granted == 0 then return end
    local grants = {}
    for i, g in ipairs(src.granted) do grants[i] = g end
    for _, grant in ipairs(grants) do
        local lines = {}
        for _, line in ipairs(self:granted_lines(grant)) do
            if line.trigger == trigger then lines[#lines + 1] = line end
        end
        if #lines > 0 then
            local now = self:ent(source)
            if not now then return end
            local owner = grant.seat >= 0 and grant.seat or now.owner
            self:run_effect_list(lines, source, trigger, chosen, triggerSource, nil, 0,
                (grant.seat >= 0 or now.flags.silenced) and owner or nil)
            if self.aborted or self.state.pending.active then return end
        end
    end
end

function E:own_misdirect_chance(attacker)
    local src = self:ent(attacker)
    -- A hero swings with its weapon's text ("Ogre Warmaul: 50% chance to attack the wrong enemy").
    if src and src.zone == ZONE.HERO then
        src = self:ent(self:player(src.owner).weapon_id)
    end
    if not src or src.flags.silenced then return 0 end
    local d = self:def_of(src.id)
    if not d then return 0 end
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "AURA" and fx.op == "MISDIRECT" and fx.target.kind ~= "ALL" then return fx.amount end
    end
    return 0
end

-- "The first X you play each turn costs (N) less": whether a card of that kind was already played this turn.
function E:played_covered_this_turn(seat, fx)
    local p = self:player(seat)
    local turn = self.state.turn
    for _, played in ipairs(p.played_history) do
        if played.turn == turn then
            local d = def(played.card)
            if d and E.costFilterMatches(fx.type_filter, d)
                and not (fx.schoolFilter ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.schoolFilter))
                and not (fx.keywordFilterBits ~= 0 and band(d.keywords, fx.keywordFilterBits) ~= fx.keywordFilterBits)
                and not (fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits))
                and not (fx.secretOnly and not d.secret)
                and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(d, fx.traitFilterNum, p.hero_class, d.keywords))
                and not (fx.targetName ~= "" and not D.cardIsNamed(d, fx.targetName, fx.nameFamily)) then
                return true
            end
        end
    end
    return false
end

-- How many different minion types a set of minions covers, each minion standing for ONE of its types (a bipartite
-- matching): an Amalgam (RACE_ALL) can be any of the twelve.
-- How many different minion types a list of race masks covers, each minion counted for ONE of its types (a
-- matching): a dual-type minion fills whichever slot is free, an "All" minion any of the twelve.
local DISTINCT_TYPES = 12   -- RACE_BEAST .. RACE_QUILBOAR
function E.distinct_minion_types(minions)
    local holder = {}
    for t = 0, DISTINCT_TYPES - 1 do holder[t] = -1 end
    local seen
    local function place(m)
        local races = minions[m + 1]
        if band(races, RACE.ALL) ~= 0 then races = bit.lshift(1, DISTINCT_TYPES) - 1 end
        for t = 0, DISTINCT_TYPES - 1 do
            local b = bit.lshift(1, t)
            if band(races, b) ~= 0 and band(seen, b) == 0 then
                seen = bor(seen, b)
                if holder[t] < 0 or place(holder[t]) then
                    holder[t] = m
                    return true
                end
            end
        end
        return false
    end
    local count = 0
    for m = 0, #minions - 1 do
        if count >= DISTINCT_TYPES then break end
        seen = 0
        if place(m) then count = count + 1 end
    end
    return count
end











