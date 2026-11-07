-- Effects: targeting, filters, conditions, counts, costs, event firing, the effect runner and combat.
-- A port of the matching TcEngine members in jankcraft's tc/engine.cpp; see Engine.lua for the rules
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
        x = band(x, x - 1)
        n = n + 1
    end
    return n
end

-- ---- targets -----------------------------------------------------------------------------------

local OFF_BOARD = { YOUR_WEAPON = true, FRIENDLY_HAND_MINIONS = true, FRIENDLY_HAND = true, ENEMY_WEAPON = true,
    ENEMY_SECRET = true, FRIENDLY_DECK = true, ENEMY_DECK = true }

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
        return self:deck_ids(side == "FRIENDLY_DECK" and controller or other(controller))
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
        if (e.zone == ZONE.BOARD or e.zone == ZONE.HERO) and not (e.zone == ZONE.BOARD and e.health <= 0)
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
        if self:effect_has_target_filter(fx) or fx.targetAttackMin > 0 or fx.targetAttackMax > 0
            or fx.targetHealthMin > 0 or fx.targetHealthMax > 0 then
            local kept = {}
            for _, id in ipairs(pool) do
                if self:target_matches_filters(id, fx, source) then kept[#kept + 1] = id end
            end
            pool = kept
        end
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
    return fx.type_filter ~= 0 or fx.costMin ~= 0 or fx.costMax ~= 0 or fx.raceFilterBits ~= 0
        or fx.keywordFilterBits ~= 0 or fx.familyFilter ~= 0 or fx.rarityFilter ~= 0 or fx.excludeSource
        or fx.damagedOnly or fx.undamagedOnly or fx.excludeRaceBits ~= 0
end

function E:target_matches_filters(id, fx, source)
    if fx.op == "TRANSFORM" and fx.token == "" and (fx.type_filter ~= 0 or fx.costMin ~= 0 or fx.costMax ~= 0
        or fx.raceFilterBits ~= 0 or fx.keywordFilterBits ~= 0 or fx.familyFilter ~= 0 or fx.rarityFilter ~= 0) then
        local only = copyEffect(fx)
        only.type_filter, only.costMin, only.costMax, only.raceFilterBits = 0, 0, 0, 0
        only.keywordFilterBits, only.familyFilter, only.rarityFilter = 0, 0, 0
        return self:target_matches_filters(id, only, source)
    end
    local entity = self:ent(id)
    if entity then
        if fx.targetAttackMin > 0 and entity.attack < fx.targetAttackMin then return false end
        if fx.targetAttackMax > 0 and entity.attack > fx.targetAttackMax then return false end
        if fx.targetHealthMin > 0 and entity.health < fx.targetHealthMin then return false end
        if fx.targetHealthMax > 0 and entity.health > fx.targetHealthMax then return false end
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
    if fx.keywordFilterBits ~= 0 and band(e.keywords, fx.keywordFilterBits) ~= fx.keywordFilterBits then return false end
    if fx.excludeSource and id == source then return false end
    if fx.damagedOnly and e.health >= e.max_health then return false end
    if fx.undamagedOnly and e.health < e.max_health then return false end
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
    return true -- the C++ switch falls through to true for an unlisted value
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
CONDITIONS.OTHER_MINIONS_AT_LEAST = function(self, fx, c, source)
    local board = #self:board_ids(c)
    local src = self:ent(source)
    local mine = (src and src.zone == ZONE.BOARD and src.controller == c) and 1 or 0
    return board - mine >= fx.conditionAmount
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
CONDITIONS.DECK_NO_DUPLICATES = function(self, fx, c)
    local deck = self:deck_ids(c)
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
CONDITIONS.OPPONENT_TURN = function(self, fx, c) return self.state.active ~= c end
CONDITIONS.YOUR_TURN = function(self, fx, c) return self.state.active == c end
CONDITIONS.HAS_WEAPON = function(self, fx, c)
    local w = self:ent(self:player(c).weapon_id)
    return w ~= nil and w.zone == ZONE.WEAPON
end
CONDITIONS.PLAYED_RACE_LAST_TURN = function(self, fx, c)
    return band(self:player(c).play_tribes_last_turn, fx.conditionRaceBits) ~= 0
end
CONDITIONS.HOLDING_TYPE_COST = function(self, fx, c) return self:holds_type_cost(c, fx.conditionType, fx.conditionAmount) end
CONDITIONS.DECK_NO_NEUTRAL = function(self, fx, c)
    for _, id in ipairs(self:deck_ids(c)) do
        local d = self:def_of(id)
        if d and d.family == "NEUTRAL" then return false end
    end
    return true
end
CONDITIONS.DECK_NO_COST = function(self, fx, c)
    for _, id in ipairs(self:deck_ids(c)) do
        local d = self:def_of(id)
        if d and d.cost == fx.conditionAmount then return false end
    end
    return true
end
CONDITIONS.HELD_SPELLS_AT_LEAST = function(self, fx, c, source)
    local e = self:ent(source)
    return e ~= nil and e.held_spells_cast >= fx.conditionAmount
end
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
CONDITIONS.ONLY_MINION = function(self, fx, c) return #self:board_ids(c) + #self:board_ids(other(c)) == 1 end
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
CONDITIONS.DECK_NO_TYPE = function(self, fx, c)
    for _, id in ipairs(self:deck_ids(c)) do
        local d = self:def_of(id)
        if d and d.typeNum + 1 == fx.conditionType then return false end
    end
    return true
end
CONDITIONS.DECK_ONLY_PARITY = function(self, fx, c)
    for _, id in ipairs(self:deck_ids(c)) do
        local d = self:def_of(id)
        if d then
            local odd = d.cost % 2 ~= 0
            if (fx.conditionAmount == 1) ~= odd then return false end
        end
    end
    return true
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
CONDITIONS.MINION_DIED_THIS_TURN = function(self, fx, c) return self:player(c).minions_died_this_turn > 0 end
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
CONDITIONS.CONTROL_NO_OTHER_MINIONS = function(self, fx, c) return #self:board_ids(c) == 1 end
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
CONDITIONS.GAME_COUNT = function(self, fx, c)
    local name = TC.CostCounts[fx.conditionType + 1] or "NONE"
    return self:count_for(c, name, fx.conditionRaceBits, 0, "", 0) >= fx.conditionAmount
end
CONDITIONS.ENEMY_MINION_TAUNT = function(self, fx, c)
    for _, id in ipairs(self:board_ids(other(c))) do
        local e = self:ent(id)
        if e and band(e.keywords, KW.TAUNT) ~= 0 then return true end
    end
    return false
end

-- ---- counts ------------------------------------------------------------------------------------

local COUNT_FRIENDLY = { FRIENDLY_CHARACTER = true, FRIENDLY_MINION = true, FRIENDLY_MINIONS = true,
    FRIENDLY_HAND = true, FRIENDLY_HAND_MINIONS = true, YOUR_HERO = true, YOUR_WEAPON = true }
local COUNT_ENEMY = { ENEMY_CHARACTER = true, ENEMY_MINION = true, ENEMY_MINIONS = true, ENEMY_HERO = true }

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

function E:scaled_effect(fx, controller, source)
    local out = fx
    local vs = fx.valueSource
    if TARGET_VALUES[vs] then return fx end
    if vs ~= "NONE" and vs ~= "" then
        local value = 0
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
        end
        out = copyEffect(fx)
        if fx.op == "DISCOVER" then
            out.costMin, out.costMax, out.valueSource = value, value, "NONE"
            return out
        end
        if fx.op == "SUMMON_RANDOM" then
            out.costMin, out.costMax, out.amount, out.valueSource = value, value, 0, "NONE"
            return out
        end
        if (vs == "PREVIOUS_AMOUNT" or vs == "PREVIOUS_MUCH")
            and (fx.op == "SUMMON" or fx.op == "SUMMON_COPY" or fx.op == "SUMMON_FROM_DECK") then
            out["repeat"] = value < 0 and 0 or value
            out.amount = 0
        else
            out.amount = value
            if fx.statsBoth then out.amount2 = value end
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
        fx.schoolFilter)
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
    return self:count_for(seat, fx.costCount, fx.costCountRaceBits, 0, fx.costCountName, fx.schoolFilter)
end

local function bareName(v)
    v = v:lower()
    if v:sub(1, 4) == "the " then v = v:sub(5) end
    return v
end

local COUNT = {}

function E:count_for(seat, source, race, sourceEntity, name, school)
    if source == "NONE" or source == "" then return 1 end
    local handler = COUNT[source]
    if not handler then return 1 end
    return handler(self, seat, self:player(seat), race, sourceEntity, name or "", school or 0)
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
COUNT.NAMED_ON_BOARD = function(self, seat, p, race, se, name)
    local n = 0
    for _, id in ipairs(self:board_ids(seat)) do
        local d = self:def_of(id)
        if d and name ~= "" and bareName(d.name) == bareName(name) then n = n + 1 end
    end
    return n
end
COUNT.NAMED_IN_HAND = function(self, seat, p, race, se, name)
    local n = 0
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and name ~= "" and bareName(d.name) == bareName(name) then n = n + 1 end
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
    for srcSeat = 0, 1 do
        for _, sid in ipairs(self:board_ids(srcSeat)) do
            local src = self:ent(sid)
            local sd = src and not src.flags.silenced and self:def_of(sid)
            if sd then
                for _, fx in ipairs(sd.effects) do
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
                            and not (fx.otherClass and (d.familyNum == self:player(seat).hero_class or d.family == "NEUTRAL")) then
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
    end
    local p = self:player(seat)
    if p.next_turn_cost_delta ~= 0 and costFilterMatches(p.next_turn_cost_filter, d) then
        if p.next_turn_cost_floor then
            floored = floored + p.next_turn_cost_delta
        else
            delta = delta + p.next_turn_cost_delta
        end
    end
    if p.next_card_cost_delta ~= 0 and costFilterMatches(p.next_card_cost_filter, d)
        and (p.next_card_cost_school == 0 or (d.type == "SPELL" and d.schoolNum + 1 == p.next_card_cost_school))
        and (p.next_card_cost_race == 0 or hasRace(d.races, p.next_card_cost_race))
        and (p.next_card_cost_keyword == 0 or band(d.keywords, p.next_card_cost_keyword) == p.next_card_cost_keyword) then
        delta = delta + p.next_card_cost_delta
    end
    local total = d.cost + delta
    if floored == 0 then return max(0, total) end
    return max(min(1, max(0, total)), total + floored)
end

function E:hero_power_cost(seat)
    local p = self:player(seat)
    if p.hero_power_free_once then return 0 end
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
    return max(0, 2 + delta)
end

-- ---- events ------------------------------------------------------------------------------------

local SELF_ARRIVALS = { AFTER_SUMMON_MINION = true, AFTER_PLAY_MINION = true, AFTER_PLAY_CARD = true,
    WHEN_SUMMON_MINION = true, WHEN_PLAY_MINION = true, WHEN_PLAY_CARD = true }

function E:subject_matches(fx, subject, reactor)
    if fx.trigger == "AFTER_ATTACK_KILL" and fx.subjectType == -2 then
        local s, r = self:ent(subject), self:ent(reactor)
        return s ~= nil and r ~= nil and (s.zone == ZONE.WEAPON or s.zone == ZONE.HERO) and s.controller == r.controller
    end
    if fx.subjectType == -1 or fx.subjectType == -2 then return subject == reactor end
    if reactor >= 0 and subject == reactor and SELF_ARRIVALS[fx.trigger] then return false end
    if fx.subjectType == -3 then return true end
    if fx.subjectRaceBits == 0 and fx.subjectKeywordBits == 0 and fx.subjectCost == 0 and fx.subjectHealth == 0
        and fx.subjectAttackMax == 0 and fx.subjectAttackMin == 0 and fx.subjectType == 0 and fx.subjectName == "" then
        return true
    end
    local e = self:ent(subject)
    if not e then return false end
    local d = self:def_of(subject)
    if not d then return false end
    if fx.subjectType ~= 0 and d.typeNum + 1 ~= fx.subjectType then return false end
    if fx.subjectSchoolNum ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.subjectSchoolNum) then return false end
    if fx.subjectRaceBits ~= 0 and not hasRace(d.races, fx.subjectRaceBits) then return false end
    if fx.subjectKeywordBits ~= 0 and band(e.keywords, fx.subjectKeywordBits) == 0 then return false end
    if fx.subjectCost ~= 0 and d.cost ~= fx.subjectCost then return false end
    if fx.subjectHealth ~= 0 and e.health ~= fx.subjectHealth then return false end
    if fx.subjectAttackMax ~= 0 and e.attack > fx.subjectAttackMax then return false end
    if fx.subjectAttackMin ~= 0 and e.attack < fx.subjectAttackMin then return false end
    if fx.subjectName ~= "" and d.name ~= fx.subjectName then return false end
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
end

function E:fire_secrets(trigger, seat, subject)
    if seat == self.state.active and trigger ~= "START_TURN" then return false end
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
                if self:ent(id) then self:relocate(id, ZONE.GRAVEYARD, -1) end
                for i = #p.secrets, 1, -1 do
                    if p.secrets[i] == id then table.remove(p.secrets, i) end
                end
                p.game_secrets_triggered = p.game_secrets_triggered + 1
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

function E:fire_events(trigger, seat, subject, eventAmount)
    eventAmount = eventAmount or 0
    local s = self.state
    self:fire_secrets(trigger, seat, subject)
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
    for _, id in ipairs(byPlayOrder(self, self:board_ids(seat))) do sources[#sources + 1] = id end
    if (trigger == "AFTER_DRAW" or trigger == "AFTER_DISCARD") and subject ~= 0 and self:ent(subject) then
        sources[#sources + 1] = subject
    end
    if (trigger == "SELF_TAKES_DAMAGE" or trigger == "SELF_DEALS_DAMAGE") and subject ~= 0 then
        local gone = self:ent(subject)
        if gone and gone.zone == ZONE.GRAVEYARD and gone.owner == seat and not contains(sources, subject) then
            sources[#sources + 1] = subject
        end
    end
    for _, id in ipairs(sources) do
        local e = self:ent(id)
        local skip = not e or e.flags.silenced
            or ((trigger == "SELF_TAKES_DAMAGE" or trigger == "SELF_DEALS_DAMAGE" or trigger == "OVERHEAL") and id ~= subject)
            or (trigger == "SPELLBURST" and e.flags.spellburst_used)
            or (trigger == "FRENZY" and (e.flags.frenzy_used or id ~= subject))
        local d = not skip and self:def_of(id)
        if d and reactsTo(d, trigger) then
            if not self:step_budget() then return end
            local savedAmount = self.event_amount
            self.event_amount = eventAmount
            local outerVictim = self.kill_victim
            if trigger == "AFTER_ATTACK_KILL" then self.kill_victim = eventAmount end
            self:run_effects(id, trigger, 0, subject ~= 0 and subject or id)
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
    local rows = {}
    for i, row in ipairs(s.persistent) do rows[i] = row end
    for _, row in ipairs(rows) do
        if row.owner == seat then
            local src = self:ent(row.source)
            local d = src and self:def_of(row.source)
            if d and d.type == "SPELL" then
                local list = {}
                for _, fx in ipairs(d.effects) do
                    if fx.trigger == trigger and self:subject_matches(fx, subject, row.source) then
                        local one = copyEffect(fx)
                        one.durationTurns = 0
                        list[#list + 1] = one
                    end
                end
                if #list > 0 and self:step_budget() then
                    local savedAmount = self.event_amount
                    self.event_amount = eventAmount
                    self:run_effect_list(list, row.source, trigger, 0, subject ~= 0 and subject or row.source, nil)
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
    if heroAttacked then
        local weapon = self:player(seat).weapon_id
        if weapon ~= 0 and self:ent(weapon) then sources[1] = weapon end
    end
    for _, id in ipairs(byPlayOrder(self, self:board_ids(seat))) do sources[#sources + 1] = id end
    for _, id in ipairs(sources) do
        local e = self:ent(id)
        local d = e and not e.flags.silenced and self:def_of(id)
        if d then
            local reacts = false
            for _, fx in ipairs(d.effects) do
                if fx.trigger == "AFTER_SELF_ATTACK" and id == attacker
                    and (fx.subjectType == 0 or self:subject_matches(fx, self.pending_attack_target, attacker)) then
                    reacts = true
                end
                if fx.trigger == "AFTER_HERO_ATTACK" and heroAttacked then reacts = true end
            end
            if reacts then
                if not self:step_budget() then return end
                self:run_effects(id, "AFTER_SELF_ATTACK", 0, id)
                self:run_effects(id, "AFTER_HERO_ATTACK", 0, attacker)
                if self.aborted then return end
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
    local src = self:ent(source)
    if not src or src.flags.silenced then return end
    local d = self:def_of(source)
    if not d then return end
    if d.abilities then
        self:run_program_effects(source, trigger, chosen, triggerSource)
    else
        self:run_effect_list(d.effects, source, trigger, chosen, triggerSource, nil)
    end
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
        local removed = false
        if row.owner == seat and row.replay_school == 0 then
            local src = self:ent(row.source)
            local d = src and self:def_of(row.source)
            local gone = not src or not d or (d.type ~= "SPELL" and src.zone ~= ZONE.BOARD)
            if gone then
                table.remove(s.persistent, i)
                removed = true
            elseif row.target ~= 0 then
                local aimed = self:ent(row.target)
                if trigger == "START_TURN" and aimed and aimed.zone == ZONE.BOARD and not aimed.flags.dead then
                    self:run_effect_list(d.effects, row.source, trigger, row.target, row.source, nil)
                end
                if trigger == "START_TURN" then
                    table.remove(s.persistent, i)
                    removed = true
                end
            else
                self:run_effect_list(d.effects, row.source, trigger, -1, row.source, nil)
                if self.aborted then return end
                if decrement then row.turns_remaining = row.turns_remaining - 1 end
                if row.turns_remaining <= 0 then
                    table.remove(s.persistent, i)
                    removed = true
                end
            end
        end
        if not removed then i = i + 1 end
    end
end

function E:run_trigger(seat, trigger)
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
        self:run_effects(e.id, trigger, 0, e.id)
        if self.aborted then return end
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
        self:run_effects(e.id, trigger, 0, e.id)
        if self.aborted then return end
    end
end

function E:capture_pending(source, trigger, index, chosen, triggerSource, frame)
    local p = self.state.pending
    p.resume = true
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
    live.resume_same = false
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
        self:run_effect_list(d.effects, pending.source, pending.trigger, pending.chosen, pending.event_subject,
            frame, nextIndex)
    end
    if self.state.pending.active then
        if pending.then_on_play then self.state.pending.then_on_play = true end
        return
    end
    if pending.then_on_play and not self.aborted then
        self:run_minion_on_play(pending.source, pending.chosen, frame)
    end
end

local TARGETLESS = { SUMMON = true, SUMMON_RANDOM = true, EQUIP = true, DRAW = true, GAIN_MANA = true,
    REFRESH_MANA = true, DISCOVER = true, ADD_TO_HAND = true, HERO_POWER_COST = true, CARD_COST = true, DREDGE = true,
    BUFF_ZONE = true, SUMMON_WITH_STATS = true }
local ZONE_OPS = { SUMMON_FROM_DECK = true, COST_ZONE = true, CAST_FROM = true, CHOOSE_HAND = true,
    SUMMON_COPY_FROM = true, SWAP_WITH = true, RESURRECT = true, EMPOWER_ABILITIES = true, REPEAT_ABILITY = true,
    HERALD = true, JADE_GOLEM = true, INVOKE = true, DISCARD_LOWEST = true, DISCARD_HIGHEST = true,
    SET_MANA_CRYSTALS = true, SHUFFLE_SELF = true, SHUFFLE_COPY_SELF = true, KEEPS_ENCHANTMENTS = true, EXCAVATE = true }
local SUMMONISH = { SUMMON = true, SUMMON_RANDOM = true, SUMMON_COPY = true, RAISE_CORPSES = true,
    SUMMON_FROM_DECK = true, RESURRECT = true }

local function isTargetless(fx)
    local op = fx.op
    return ((TARGETLESS[op] or (op == "SHUFFLE" and (fx.token ~= "" or fx.amount2 == 1 or fx.amount2 == 4
            or fx.target.kind == "SELF"))) and not (op == "CARD_COST" and fx.target.kind == "PREVIOUS"))
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
function E:run_effect_list(effects, source, trigger, chosen, triggerSource, frame, startIndex, controllerOverride)
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
        if #parent.followUp == 0 or parent.op == "GRANT_ABILITY" then return end
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

    for effectIndex = startIndex, #effects - 1 do
        local stored = effects[effectIndex + 1]
        if not stored.printOnly then
            local continue = false
            if #self.summoned_this_effect > 0 and (trigger == "BATTLECRY" or trigger == "ON_PLAY") then
                local maker = self:ent(source)
                if maker and maker.zone == ZONE.BOARD then
                    maker.made_minion = self.summoned_this_effect[#self.summoned_this_effect]
                end
            end
            self.summoned_this_effect = {}
            self.copied_this_effect = {}
            self.buffed_this_effect = {}
            self.drawn_this_effect = {}
            local upgrade = trigger == "ON_PLAY" and src ~= nil
                and ((stored.trigger == "CORRUPT" and src.flags.corrupted) or (stored.trigger == "FORGED" and src.flags.forged))
            if stored.trigger ~= trigger and not upgrade then continue = true end

            local fx
            if not continue then
                fx = self:scaled_effect(stored, controller, source)
                if stored.amountSource == "MINIONS_DYING" and not self:resolve_deaths() then return end
                if fx["repeat"] < 1 and (stored.repeatPerCount or ((stored.amountSource ~= "NONE" or stored.countSelector
                    or stored.valueSource == "PREVIOUS_AMOUNT" or stored.valueSource == "PREVIOUS_MUCH")
                    and CREATES[stored.op])) then
                    continue = true
                end
            end
            if not continue then
                self.effect_index = effectIndex
                if not self:subject_matches(fx, triggerSource, source) then continue = true end
            end
            if not continue and fx.delayed then
                local ownerDef = self:def_of(source)
                if ownerDef then
                    local de = self:player(controller).delayed_effects
                    de[#de + 1] = { ownerDef.id, effectIndex }
                end
                continue = true
            end
            local previousTarget = 0
            if not continue then
                previousTarget = #frame.previous_targets > 0 and frame.previous_targets[#frame.previous_targets] or 0
                if fx.requiresPrevious and previousTarget == 0 then continue = true end
            end
            if not continue and fx.op == "DISCOVER" and fx.discoverTakeAll then
                local payer = self:player(controller)
                if fx == stored then fx = copyEffect(fx) end
                fx.discoverTakeAll = self:condition_holds(fx, controller, source, previousTarget)
                    and payer.corpses >= fx.corpseCost
                if fx.discoverTakeAll then payer.corpses = payer.corpses - fx.corpseCost end
                fx.condition = "NONE"
                fx.corpseCost = 0
            end
            if not continue and not self:condition_holds(fx, controller, source, previousTarget) then continue = true end

            local handPick = {}
            if not continue and fx.target.kind == "CHOOSE"
                and (fx.target.side == "FRIENDLY_HAND_MINIONS" or fx.target.side == "FRIENDLY_HAND") then
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
                        return
                    end
                elseif #candidates > 0 then
                    handPick[1] = candidates[rng:intBelow(#candidates) + 1]
                end
                if #handPick == 0 then continue = true end
            end

            local additive = {}
            if not continue and #fx.replacement > 0 then
                local instead = {}
                local subject = (fx.target.kind == "CHOOSE" and chosen ~= 0) and chosen or previousTarget
                for _, child in ipairs(fx.replacement) do
                    local aboutIt = child.condition == "TARGET_IS_RACE" or child.condition == "TARGET_IS_TYPE"
                        or child.condition == "TARGET_IS_SCHOOL" or child.condition == "TARGET_IS_CONTROLLED_RACE"
                    if self:condition_holds(child, controller, source, aboutIt and subject or previousTarget) then
                        if child.additional then
                            additive[#additive + 1] = child
                        else
                            local held = child
                            if aboutIt then
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
                    if self.aborted then return end
                    continue = true
                end
            end
            if not continue and fx.corpseCost > 0 then
                local payer = self:player(controller)
                if payer.corpses < fx.corpseCost then
                    continue = true
                elseif fx.target.kind == "PREVIOUS" and previousTarget == 0 and #frame.previous_targets == 0 then
                    continue = true
                else
                    payer.corpses = payer.corpses - fx.corpseCost
                end
            end
            if not continue and fx.armorCost > 0 then
                local hero = self:ent(self:player(controller).hero_id)
                if not hero or hero.armor < fx.armorCost then
                    continue = true
                else
                    hero.armor = hero.armor - fx.armorCost
                end
            end
            if not continue and fx.discardCostSchool ~= 0 then
                local paid = 0
                for _, handId in ipairs(self:hand_ids(controller)) do
                    local hd = self:def_of(handId)
                    if hd and hd.schoolNum + 1 == fx.discardCostSchool then
                        paid = handId
                        break
                    end
                end
                if paid == 0 then
                    continue = true
                else
                    self:relocate(paid, ZONE.GRAVEYARD, -1)
                end
            end
            if not continue and fx.deckCostToken ~= "" then
                local paid = 0
                for _, deckId in ipairs(self:deck_ids(controller)) do
                    if s.entities[deckId].card_id == fx.deckCostToken then
                        paid = deckId
                        break
                    end
                end
                if paid == 0 then
                    continue = true
                else
                    self:relocate(paid, ZONE.GRAVEYARD, -1)
                end
            end

            if not continue then
                local resolved = copyEffect(fx)
                if fx.op == "DAMAGE" then self.last_effect_count = fx.amount end
                local eventCard = triggerSource ~= 0 and triggerSource ~= source and trigger ~= "ON_PLAY"
                    and trigger ~= "BATTLECRY"
                local valueOf = #frame.previous_targets > 0 and frame.previous_targets[#frame.previous_targets]
                    or (fx.target.kind == "CHOOSE" and chosen) or (eventCard and triggerSource) or 0
                if (fx.valueSource == "PREVIOUS_ATTACK" or fx.valueSource == "PREVIOUS_HEALTH"
                    or fx.valueSource == "PREVIOUS_COST") and valueOf ~= 0 then
                    local prev = self:ent(valueOf)
                    if prev then
                        if fx.valueSource == "PREVIOUS_ATTACK" then
                            resolved.amount = prev.attack
                        elseif fx.valueSource == "PREVIOUS_HEALTH" then
                            resolved.amount = prev.health
                        else
                            resolved.amount = self:card_cost(prev.controller, valueOf)
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

                -- The repeat-less and the random-repeat paths end with `continue` in the C++: no post steps.
                local skipPost = true
                if fx.repeatLess and fx.op == "DAMAGE" and not targetless then
                    for amount = fx.amount, 1, -1 do
                        if not self:step_budget() then return end
                        local one = copyEffect(resolved)
                        one.repeatLess = false
                        one.amount = amount
                        local hits = fx.target.kind == "PREVIOUS" and frame.previous_targets
                            or self:resolve_targets(one, source, chosen, triggerSource, controller)
                        for _, t in ipairs(hits) do
                            self:apply_op(one, t, source, controller)
                            if self.aborted then return end
                        end
                    end
                elseif not targetless and fx.target.kind == "RANDOM" and rep > 1 and not fx.split then
                    local used = {}
                    for _ = 1, rep do
                        if not self:step_budget() then return end
                        local pool = {}
                        for _, id in ipairs(self:side_ids(fx.target.side, controller, source)) do
                            local cand = self:ent(id)
                            if cand and not cand.flags.dead and cand.health > 0
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
                        if self.aborted then return end
                        if s.pending.active and s.pending.effect_index < 0 and targetless then
                            self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                            return
                        end
                    end
                else
                    skipPost = false
                    for _ = 1, rep do
                        if not self:step_budget() then return end
                        if targetless then
                            self:apply_op(resolved, 0, source, controller)
                            runFollowUps(fx, 0)
                            if s.pending.active and s.pending.effect_index < 0 then
                                self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                                return
                            end
                            if fx.op == "DRAW" or fx.op == "ADD_TO_HAND" or fx.op == "FILL_HAND" or fx.op == "EXCAVATE" then
                                frame.previous_targets = copyList(self.drawn_this_effect)
                            end
                            if SUMMONISH[fx.op] and #self.summoned_this_effect > 0 then
                                frame.previous_targets = { self.summoned_this_effect[#self.summoned_this_effect] }
                            end
                            if self.aborted then return end
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
                                if #targets == 0 and fx.target.kind == "PREVIOUS" and triggerSource ~= 0
                                    and trigger ~= "ON_PLAY" and trigger ~= "BATTLECRY" then
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
                                local chosenBefore = copyList(frame.previous_targets)
                                local sourceDef = self:def_of(source)
                                local otherThanChosen = sourceDef ~= nil and sourceDef.type == "SPELL"
                                    and fx.target.kind == "ALL" and (fx.excludeSource or fx.target.side == "ANY_OTHER_MINION"
                                        or fx.target.side == "ANY_OTHER_CHARACTER")
                                frame.previous_targets = copyList(targets)
                                for _, t in ipairs(targets) do
                                    if self:target_matches_filters(t, fx, source)
                                        and not (otherThanChosen and contains(chosenBefore, t)) then
                                        self:apply_op(resolved, t, source, controller)
                                        runFollowUps(fx, t)
                                        if self.aborted then return end
                                        if s.pending.active and s.pending.effect_index < 0 then
                                            self:capture_pending(source, trigger, effectIndex, chosen, triggerSource, frame)
                                            return
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
                if not skipPost then
                    if #self.summoned_this_effect > 0 then
                        frame.previous_targets = copyList(self.summoned_this_effect)
                    end
                    if fx.op == "COPY" and #self.copied_this_effect > 0 then
                        frame.previous_targets = copyList(self.copied_this_effect)
                    end
                    if fx.op == "BUFF_ZONE" and fx.buffRandom and #self.buffed_this_effect > 0 then
                        frame.previous_targets = copyList(self.buffed_this_effect)
                    end
                    if #additive > 0 then
                        self:run_effect_list(additive, source, trigger, chosen, triggerSource, frame)
                        if self.aborted then return end
                    end
                end
            end
        end
    end
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

function E:can_minion_attack(id)
    local e = self:ent(id)
    if not e or e.zone ~= ZONE.BOARD then return false end
    if e.flags.dormant_turns > 0 then return false end
    if e.flags.exhausted or e.flags.frozen then return false end
    local d = self:def_of(id)
    if d and (d.cant_attack or band(d.keywords, KW.CANT_ATTACK) ~= 0) then return false end
    if d then
        for _, fx in ipairs(d.effects) do
            if fx.op == "CANT_ATTACK_UNLESS" then
                if fx.amount2 == 3 then
                    if e.health < e.max_health then return false end
                elseif fx.amount2 == 2 then
                    local hero = self:hero_of(e.controller)
                    if not hero or hero.armor < 7 then return false end
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
    local card, a = cardEntityFor(self, attacker)
    if not a then return false end
    if not card then return false end
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

function E:misdirect_chance(attacker)
    local src = self:ent(attacker)
    if src and src.zone == ZONE.HERO then
        src = self:ent(self:player(src.owner).weapon_id)
    end
    if not src or src.flags.silenced then return 0 end
    local d = self:def_of(src.id)
    if not d then return 0 end
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "AURA" and fx.op == "MISDIRECT" then return fx.amount end
    end
    return 0
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

function E:resolve_attack(attacker, target)
    local s = self.state
    local chance = self:misdirect_chance(attacker)
    if chance > 0 then
        local a = self:ent(attacker)
        if a and s.rng:intBelow(100) < chance then
            local pool = {}
            for _, id in ipairs(self:side_ids("ENEMY_CHARACTER", a.controller, attacker)) do
                local e = self:ent(id)
                if e and not e.flags.dead and e.health > 0 and id ~= target then pool[#pool + 1] = id end
            end
            if #pool > 0 then target = pool[s.rng:intBelow(#pool) + 1] end
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
    if whileAttacking then
        self.attacking_now = 0
        self:recompute_auras()
    end
    a.flags.attacks_this_turn = a.flags.attacks_this_turn + 1
    a.flags.has_attacked = true
    if a.zone == ZONE.HERO then
        local p = self:player(a.owner)
        p.game_hero_attacks = p.game_hero_attacks + 1
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
    end
    if a.zone == ZONE.HERO then
        local p = self:player(a.owner)
        local weapon = self:ent(p.weapon_id)
        if weapon then
            weapon.durability = weapon.durability - 1
            if weapon.durability <= 0 then self:destroy_weapon(a.owner) end
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
        self:queue("WHEN_FRIENDLY_MINION_ATTACKS", a.owner, attacker)
    end
end
