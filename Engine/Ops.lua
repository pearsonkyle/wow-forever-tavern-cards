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
-- apply_op: what each effect op does to one target. A port of TcEngine::apply_op (the reference engine
-- tc/engine.cpp), every case, in the same order of RNG draws.

local TC = TavernCards_NS
local D = TC.EngineDefs
local E = TC.Engine
local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local min, max = math.min, math.max
local ZONE, KW, RACE = D.ZONE, D.KW, D.RACE
local def = D.def
local hasRace = D.hasRace
local poolCard = D.poolCard
local other = E.other
local cardMatches = E.card_matches_filters
local EMPTY = D.EMPTY

local PLAYABLE_TYPE = { MINION = true, SPELL = true, WEAPON = true, LOCATION = true }

local function nextSummonPos(pos)
    return pos >= 0 and pos + 1 or -1
end

local EXCAVATE_COMMON = { "WW_001t", "WW_001t2", "WW_001t3", "WW_001t4", "WW_001t18", "DEEP_999t1" }
local EXCAVATE_RARE = { "WW_001t5", "WW_001t7", "WW_001t8", "WW_001t9", "WW_001t16", "DEEP_999t2" }
local EXCAVATE_EPIC = { "WW_001t11", "WW_001t12", "WW_001t13", "WW_001t14", "WW_001t17", "DEEP_999t3" }
local EXCAVATE_LEGENDARY = { [D.FAMILY.DEATHKNIGHT] = "WW_001t26", [D.FAMILY.MAGE] = "WW_001t24",
    [D.FAMILY.PALADIN] = "DEEP_999t4", [D.FAMILY.ROGUE] = "WW_001t23", [D.FAMILY.SHAMAN] = "DEEP_999t5",
    [D.FAMILY.WARLOCK] = "WW_001t25", [D.FAMILY.WARRIOR] = "WW_001t27" }
local HERALD_SOLDIERS = { [D.FAMILY.DEATHKNIGHT] = "CATA_780t", [D.FAMILY.DEMONHUNTER] = "CATA_525t",
    [D.FAMILY.ROGUE] = "CATA_158t", [D.FAMILY.SHAMAN] = "CATA_565t", [D.FAMILY.WARLOCK] = "CATA_725t",
    [D.FAMILY.WARRIOR] = "CATA_580t" }

function E.herald_soldier(familyNum)
    return HERALD_SOLDIERS[familyNum]
end

-- What the Herald upgrade multiplies a Soldier's (and a Colossal appendage's) stats and number by: base for the first
-- two Heralds, doubled once two have happened, quadrupled from four.
function E.herald_multiplier(heraldsMade)
    return heraldsMade < 2 and 1 or (heraldsMade < 4 and 2 or 4)
end

-- "Herald twice to upgrade": a Colossal appendage that grows with its owner's Heralds. Read off the printed text.
function E.upgrades_with_herald(d)
    return d.text:find("Herald", 1, true) ~= nil and d.text:find("to upgrade", 1, true) ~= nil
end

local function keywordFilterOk(fx, d)
    return fx.keywordFilterBits == 0 or band(d.keywords, fx.keywordFilterBits) == fx.keywordFilterBits
end

local OPS = {}

function E:apply_op(rawFx, target, source, controller)
    local outer = self.effect_source
    local outerController = self.effect_controller
    -- "Become Immune this turn" answering damage from an end-of-turn effect: the turn it was for is over by the time
    -- the queued event is dispatched, so a this-turn grant has nothing left to last through.
    if rawFx.temporary and self.event_active_at >= 0 and self.event_active_at ~= self.state.active then
        return
    end
    self.effect_source = source
    self.effect_controller = controller
    local fx = rawFx
    local vs = rawFx.valueSource
    if vs == "TARGET_ATTACK" or vs == "TARGET_HEALTH" or vs == "TARGET_MAX_HEALTH" or vs == "TARGET_COST" then
        fx = D.copyEffect(rawFx)
        local t = self:ent(target)
        if t then
            if vs == "TARGET_ATTACK" then fx.amount = t.attack
            elseif vs == "TARGET_HEALTH" then fx.amount = t.health
            elseif vs == "TARGET_MAX_HEALTH" then fx.amount = t.max_health
            else fx.amount = self:card_cost(t.controller, target) end
        end
    end
    local handler = OPS[fx.op]
    if handler then
        handler(self, fx, target, source, controller, self:ent(source))
    elseif fx.op ~= "" then
        error("op not implemented: " .. tostring(fx.op))
    end
    self.effect_source = outer
    self.effect_controller = outerController
end

local function srcCard(src)
    return src and src.card_id or ""
end

local function passive() end
OPS.CANT_ATTACK_HEROES = passive
OPS.MAY_ATTACK_AGAIN = passive
OPS.TAKES_DAMAGE_INSTEAD = passive
OPS.KEEPS_ENCHANTMENTS = passive
OPS.FREEZE_ON_DAMAGE = passive
OPS.MISDIRECT = passive
OPS.CLEAVE = passive
OPS.SPELL_DAMAGE_AURA = passive
OPS.CANT_ATTACK_UNLESS = passive
OPS.DAMAGE_CAP = passive

-- ---- run waves 2026-11-10..19 and run 16 ------------------------------------------------------------

-- As an AURA, a PASSIVE read where each doubled kind runs (triggers_twice). As an effect, "your next spell (this turn)
-- casts twice" and "your next Battlecry this turn triggers twice": counters the next ones spend.
OPS.TRIGGERS_TWICE = function(self, fx, target, source, controller)
    if fx.trigger == "AURA" then return end
    -- Two of them name the same next spell (Battlecry): the counter is the larger, not the sum.
    local p = self:player(controller)
    local n = max(1, fx.amount)
    if band(fx.amount2, 32) ~= 0 then
        if fx.temporary then p.twice_spells_turn = max(p.twice_spells_turn, n)
        else p.twice_spells = max(p.twice_spells, n) end
    end
    if band(fx.amount2, 1) ~= 0 then
        p.twice_battlecries_turn = max(p.twice_battlecries_turn, n)
    end
end

-- "For the rest of the game, ...": the lines this effect carries become a row of its player's, named by the effect's
-- place in the card's list (the same trigger finds it).
OPS.GAME_LONG = function(self, fx, target, source, controller)
    local d = self:def_of(source)
    if not d then return end
    local index = -1
    for i, line in ipairs(d.effects) do
        if line.op == "GAME_LONG" and line.trigger == fx.trigger then
            index = i - 1
            break
        end
    end
    if index < 0 then return end
    local s = self.state
    s.persistent[#s.persistent + 1] = { owner = controller, source = source, card_id = d.id,
        turns_remaining = 2 ^ 30, target = 0, replay_school = 0, game_long = index,
        uses = max(0, fx.amount),   -- "the next Draenei you play": one firing, then gone
        serial = s.next_row_serial }
    s.next_row_serial = s.next_row_serial + 1
    self:recompute_auras()
end

OPS.REPEAT_IF = passive   -- control flow, read by run_effect_list before an effect is applied

-- "Steal 1 Attack and Health from all enemy minions": the target loses what it has of the amounts and the stealer
-- gains exactly that. A hero loses Health, not its maximum; Armor does not shield it.
OPS.STEAL_STATS = function(self, fx, target, source, controller)
    local victim = self:ent(target)
    local thiefId = fx.setVerb and self:player(controller).hero_id or source
    local thief = self:ent(thiefId)
    if not victim or not thief or thiefId == target or victim.flags.dead then return end
    local attack = max(0, min(fx.amount, victim.attack))
    local health = max(0, min(fx.amount2, victim.health))
    if attack == 0 and health == 0 then return end
    local stealer = self:def_of(source)
    local tag = stealer and stealer.id or ""
    if victim.zone == ZONE.HERO then
        victim.health = victim.health - health
        if attack > 0 then self:apply_buff(target, -attack, 0, 0, fx.temporary, tag) end
    else
        self:apply_buff(target, -attack, -health, 0, fx.temporary, tag)
    end
    self:apply_buff(thiefId, attack, health, 0, fx.temporary, tag)
end

-- "Put an enemy minion on the bottom of your deck": the card itself, not a copy. It leaves play the way a bounce
-- does (no death), and takes the side of the deck it goes into.
OPS.MOVE_TO_DECK = function(self, fx, target, source, controller)
    local card = self:ent(target)
    if not card or card.flags.dead or (card.zone ~= ZONE.BOARD and card.zone ~= ZONE.HAND and card.zone ~= ZONE.DECK) then
        return
    end
    local deckSeat = fx.forOpponent and other(controller) or controller
    card.owner, card.controller = deckSeat, deckSeat
    local size = #self:deck_ids(deckSeat)
    local at
    if fx.deckPosition == 1 then at = 0
    elseif fx.deckPosition == 2 then at = size
    elseif size == 0 then at = 0
    else at = self.state.rng:intBelow(size + 1) end
    self:relocate(target, ZONE.DECK, at)
    self.shuffled_this_effect[#self.shuffled_this_effect + 1] = target
    if deckSeat == controller and fx.deckPosition == 0 then
        self:quest_count(controller, "SHUFFLE", source, 1)   -- run 16: a shuffle into your own deck
    end
end

-- Run 16: the quest card being cast goes into its player's quest zone. Cast twice, it is still one quest; cast by
-- another card with no room for it (quest_room), it does nothing.
OPS.QUEST = function(self, fx, target, source, controller)
    local own = self:ent(source)
    local d = self:def_of(source)
    if not own or not d or not E.quest_line_of(d) or own.zone == ZONE.QUEST or not self:quest_room(controller, d) then
        return
    end
    -- "If you played a Quest this game": a quest its player played from the hand (the card being paid for).
    local played = source == self.last_paid_entity
    self:start_quest(controller, source, 1)
    if played then
        local p = self:player(controller)
        p.game_quests_played = p.game_quests_played + 1
    end
end

-- "Imbue your Hero Power (twice)(, then trigger it)" (run 16, Engine/Imbue.lua): the controller's, whatever the
-- effect's target says.
OPS.IMBUE = function(self, fx, target, source, controller)
    self:imbue(controller, fx.amount > 1 and fx.amount or 1, fx.amount2 == 1, source)
end

OPS.CANT_ATTACK_HEROES_TURN = function(self, fx, target)
    local t = self:ent(target)
    if t then t.flags.cant_attack_heroes_this_turn = true end
end

OPS.SHUFFLE_COPY_SELF = function(self, fx, target, source)
    local me = self:ent(source)
    local d = me and self:def_of(source)
    if not d then return end
    local size = #self:deck_ids(me.owner)
    local at = size == 0 and 0 or self.state.rng:intBelow(size + 1)
    -- "... with permanent +3/+3": the copy is what "it" names next, and it carries this card's permanent buffs.
    local copy = self:create_entity(d, me.owner, ZONE.DECK, at)
    self:carry_permanent_buffs(source, copy)
    self.shuffled_this_effect[#self.shuffled_this_effect + 1] = copy
    self:quest_count(me.owner, "SHUFFLE", source, 1)   -- run 16
end

OPS.SHUFFLE_SELF = function(self, fx, target, source)
    local me = self:ent(source)
    if not me then return end
    -- "It keeps any enchantments": leaving play resets a card to its printing, so the lasting buffs it carried are put
    -- back after the move. Auras and "this turn" buffs are the board's, not the card's, and stay behind.
    local kept = {}
    local d = self:def_of(source)
    if d then
        for _, line in ipairs(d.effects) do
            if line.op == "KEEPS_ENCHANTMENTS" then
                for _, b in ipairs(me.buffs) do
                    if not b.from_aura and not b.temporary and not b.permanent then   -- reset_to_card keeps a permanent one
                        local copy = {}
                        for k, v in pairs(b) do copy[k] = v end
                        kept[#kept + 1] = copy
                    end
                end
                break
            end
        end
    end
    local size = #self:deck_ids(me.owner)
    local at = size == 0 and 0 or self.state.rng:intBelow(size + 1)
    self:relocate(source, ZONE.DECK, at)
    local moved = self:ent(source)
    if moved then
        for _, b in ipairs(kept) do
            moved.attack = moved.attack + b.attack
            moved.max_health = moved.max_health + b.health
            moved.health = moved.health + b.health
            moved.keywords = bor(moved.keywords, b.keyword)
            moved.spell_damage = moved.spell_damage + (b.spell_damage or 0)
            moved.buffs[#moved.buffs + 1] = b
        end
    end
end

OPS.TAKE_CONTROL = function(self, fx, target, source, controller)
    local s = self.state
    local t = self:ent(target)
    if not t or t.owner == controller then return end
    local from = t.owner
    if t.zone == ZONE.SECRET then
        local theirs = self:player(from).secrets
        for i = #theirs, 1, -1 do
            if theirs[i] == t.id then table.remove(theirs, i) end
        end
        local mine = self:player(controller)
        if #mine.secrets >= 5 or self:secret_in_play(controller, t.card_id) then
            self:relocate(t.id, ZONE.GRAVEYARD, -1)
            return
        end
        t.owner, t.controller = controller, controller
        self:relocate(t.id, ZONE.SECRET, -1)
        mine.secrets[#mine.secrets + 1] = t.id
        return
    end
    if t.zone ~= ZONE.BOARD then return end
    if self:board_size(controller) >= 7 then
        self:mark_dead(t.id)
        return
    end
    t.owner, t.controller = controller, controller
    self:relocate(t.id, ZONE.BOARD, -1)
    for i, id in ipairs(self:board_ids(from)) do
        s.entities[id].zone_pos = i - 1
    end
    t.flags.exhausted = true
    t.flags.attacks_this_turn = 0
    t.flags.just_played_turn = s.turn
    self:ready_if_charged(t)
    self:recompute_auras()
end

OPS.GAIN_DURABILITY = function(self, fx, target, source, controller)
    local owner = fx.target.side == "ENEMY_WEAPON" and other(controller) or controller
    local weapon = self:ent(self:player(owner).weapon_id)
    if not weapon then return end
    weapon.durability = weapon.durability + fx.amount
    if weapon.durability <= 0 then self:destroy_weapon(owner) end
end

OPS.SET_HEALTH = function(self, fx, target)
    local t = self:ent(target)
    if not t then return end
    if t.zone == ZONE.HERO then
        t.health = min(fx.amount, max(t.max_health, fx.amount))
        if t.health > t.max_health then t.max_health = t.health end
        return
    end
    t.max_health = fx.amount
    t.health = fx.amount
    self:forget_buff_stats(t, false, true)
end

OPS.SET_ATTACK = function(self, fx, target)
    local t = self:ent(target)
    if not t then return end
    t.attack = fx.amount
    self:forget_buff_stats(t, true, false)
end

OPS.SWAP_STATS = function(self, fx, target)
    local t = self:ent(target)
    if not t then return end
    local attack = t.attack
    t.attack = t.health
    t.health = attack
    t.max_health = attack
end

OPS.HERALD = function(self, fx, target, source, controller)
    local p = self:player(controller)
    local soldier = HERALD_SOLDIERS[p.hero_class]
    if not soldier then return end
    local multiplier = E.herald_multiplier(p.herald_count)
    p.herald_count = p.herald_count + 1
    local at = self.summon_pos
    local made = self:summon_token(soldier, controller, at, false)
    self.summon_pos = nextSummonPos(at)
    local unit = self:ent(made)
    if unit then
        unit.attack = unit.attack * multiplier
        unit.max_health = unit.max_health * multiplier
        unit.health = unit.health * multiplier
        unit.number = multiplier
        self:run_effects(made, "ON_PLAY", 0, made)
    end
end

OPS.JADE_GOLEM = function(self, fx, target, source, controller)
    local p = self:player(controller)
    local n = min(30, p.jade_count + 1)
    p.jade_count = n
    local at = self.summon_pos
    local made = self:summon_token("CFM_712_t01", controller, at, false)
    self.summon_pos = nextSummonPos(at)
    local golem = self:ent(made)
    if golem then
        golem.attack, golem.max_health, golem.health = n, n, n
    end
end

OPS.EXCAVATE = function(self, fx, target, source, controller)
    local p = self:player(controller)
    p.excavates_this_game = p.excavates_this_game + 1
    local legendary = EXCAVATE_LEGENDARY[p.hero_class]
    local pool
    local tier = p.excavate_count
    if tier >= 3 and legendary then
        pool = { legendary }
        p.excavate_count = 0
    elseif tier <= 0 then
        pool = EXCAVATE_COMMON
        p.excavate_count = 1
    elseif tier == 1 then
        pool = EXCAVATE_RARE
        p.excavate_count = 2
    else
        pool = EXCAVATE_EPIC
        p.excavate_count = legendary and 3 or 0
    end
    if #pool == 0 then return end
    local d = def(pool[self.state.rng:intBelow(#pool) + 1])
    if not d then return end
    local made = self:create_entity(d, controller, ZONE.HAND, -1)
    if made ~= 0 and #self:hand_ids(controller) > 10 then
        self:relocate(made, ZONE.GRAVEYARD, -1)
    elseif made ~= 0 then
        self.drawn_this_effect[#self.drawn_this_effect + 1] = made
    end
end

OPS.UNLOCK_OVERLOAD = function(self, fx, target, source, controller)
    local p = self:player(controller)
    self.last_effect_count = p.overload_locked
    p.mana = min(p.max_mana, p.mana + p.overload_locked)
    p.overload_locked = 0
end

OPS.ADAPT = function(self, fx, target, source, controller)
    local pend = self.state.pending
    local pool = {}
    for i = 0, 9 do pool[#pool + 1] = i end
    pend.active = true
    pend.seat = controller
    pend.kind = "adapt"
    pend.source = target
    -- "Adapt your Murlocs": one choice for the whole group the effect named (run wave 78).
    if #self.adapt_group == 0 then
        pend.targets = { target }
    else
        local group = {}
        for i, t in ipairs(self.adapt_group) do group[i] = t end
        pend.targets = group
    end
    pend.options = {}
    pend.card_options = {}
    for _ = 1, 3 do
        if #pool == 0 then break end
        local picked = self.state.rng:intBelow(#pool) + 1
        pend.options[#pend.options + 1] = pool[picked]
        table.remove(pool, picked)
    end
end

OPS.SWAP_STAT_WITH = function(self, fx, target, source)
    local me, o = self:ent(source), self:ent(target)
    if not me or not o or me == o then return end
    if fx.amount2 == 2 or fx.amount2 == 3 then
        me.attack, o.attack = o.attack, me.attack
    end
    if fx.amount2 ~= 2 then
        me.health, o.health = o.health, me.health
        me.max_health = me.health
        o.max_health = o.health
    end
end

OPS.SWAP_WITH = function(self, fx, target, source, controller)
    local s = self.state
    local me = self:ent(source)
    local dying = me ~= nil and me.zone == ZONE.GRAVEYARD and self.dying_pos >= 0
    if not me or (me.zone ~= ZONE.BOARD and not dying) then return end
    if dying and self:board_size(me.owner) >= 7 then return end
    local owner = fx.forOpponent and other(controller) or controller
    local candidates = fx.buffHand and self:hand_ids(owner) or self:deck_ids(owner)
    local pool = {}
    for _, id in ipairs(candidates) do
        local d = self:def_of(id)
        if d and d.type == "MINION" and (fx.type_filter == 0 or d.typeNum + 1 == fx.type_filter)
            and (fx.raceFilterBits == 0 or hasRace(d.races, fx.raceFilterBits)) and keywordFilterOk(fx, d) then
            pool[#pool + 1] = id
        end
    end
    if #pool == 0 then return end
    local o = fx.buffRandom and pool[s.rng:intBelow(#pool) + 1] or pool[1]
    if not self:def_of(o) then return end
    local boardPos = dying and self.dying_pos or me.zone_pos
    local otherZone = fx.buffHand and ZONE.HAND or ZONE.DECK
    local selfDef = self:def_of(source)
    if fx.forOpponent then
        local mine = me.owner
        local theirs = s.entities[o]
        theirs.owner, theirs.controller = mine, mine
        me.owner, me.controller = owner, owner
    end
    self:relocate(o, ZONE.BOARD, boardPos)
    if selfDef then self:relocate(source, otherZone, -1) end
end

local function zoneFilterOk(fx, d)
    return (fx.type_filter == 0 or d.typeNum + 1 == fx.type_filter)
        and (fx.raceFilterBits == 0 or hasRace(d.races, fx.raceFilterBits))
        and keywordFilterOk(fx, d)
        and (fx.schoolFilter == 0 or d.schoolNum + 1 == fx.schoolFilter)
end

OPS.COST_ZONE = function(self, fx, target, source, controller)
    local heroClass = self:player(controller).hero_class
    local function admits(d)
        if not zoneFilterOk(fx, d) then return false end
        -- "Reduce the Cost of Overload cards in your hand": the trait narrows the zone too.
        if fx.traitFilterNum ~= 0 and not E.card_has_trait(d, fx.traitFilterNum, heroClass, 0) then return false end
        return true
    end
    local function reduce(id)
        local d = self:def_of(id)
        if d and admits(d) then
            local t = self:ent(id)
            if t then
                -- "They cost (1) more (up to 10)": an increase stops at the cap.
                if fx.costCap > 0 and fx.amount < 0 then
                    t.cost_delta = t.cost_delta + max(0, min(-fx.amount, fx.costCap - self:card_cost(t.owner, id)))
                else
                    t.cost_delta = t.cost_delta - fx.amount
                end
            end
        end
    end
    if fx.buffHand and fx.buffRandom then
        local pool = {}
        for _, id in ipairs(self:hand_ids(controller)) do
            local d = self:def_of(id)
            if d and admits(d) then pool[#pool + 1] = id end
        end
        -- "Reduce the Cost of the highest Cost spell in your hand": the pick by Cost narrows this pool too.
        pool = self:narrow_by_cost(pool, fx.pickCostNum)
        if #pool > 0 then reduce(pool[self.state.rng:intBelow(#pool) + 1]) end
    else
        if fx.buffHand then for _, id in ipairs(self:hand_ids(controller)) do reduce(id) end end
        if fx.buffDeck then for _, id in ipairs(self:deck_ids(controller)) do reduce(id) end end
    end
end

OPS.MULTIPLY_STATS = function(self, fx, target, source, controller)
    local function scale(id)
        local t = self:ent(id)
        if not t then return end
        local d = self:def_of(id)
        if d and not ((fx.type_filter == 0 or d.typeNum + 1 == fx.type_filter)
            and (fx.raceFilterBits == 0 or hasRace(d.races, fx.raceFilterBits)) and keywordFilterOk(fx, d)) then
            return
        end
        if fx.amount2 ~= 2 then t.attack = t.attack * fx.amount end
        if fx.amount2 ~= 1 then
            t.max_health = t.max_health * fx.amount
            t.health = t.health * fx.amount
        end
    end
    if fx.buffHand or fx.buffDeck or fx.buffBoard then
        if fx.buffHand then for _, id in ipairs(self:hand_ids(controller)) do scale(id) end end
        if fx.buffDeck then for _, id in ipairs(self:deck_ids(controller)) do scale(id) end end
        if fx.buffBoard then for _, id in ipairs(self:board_ids(controller)) do scale(id) end end
    else
        scale(target)
    end
end

OPS.HERO_POWER_DAMAGE = function(self, fx, target, source, controller)
    if fx.trigger ~= "AURA" then
        local p = self:player(controller)
        p.hero_power_damage_once = p.hero_power_damage_once + fx.amount
        p.hero_power_once_this_turn = p.hero_power_once_this_turn or fx.temporary
    end
end

OPS.DAMAGE = function(self, fx, target, source, controller)
    local amount = fx.amount
    if fx.damageRange and fx.amount2 > fx.amount then
        amount = amount + self.state.rng:intBelow(fx.amount2 - fx.amount + 1)
    end
    if fx.doubleSpellDamage and fx.spell then
        amount = amount + self:spell_bonus(controller)
    end
    -- "Deal $4 damage with Lifesteal": this line heals as a Lifesteal source would.
    self.effect_lifesteal = band(fx.keywordBits, KW.LIFESTEAL) ~= 0
    self:deal_damage(target, amount, source, fx.spell, fx.excessToHero)
    self.effect_lifesteal = false
    -- "Draw that many cards" after this: the blow's amount with Spell Damage (set once the blow lands).
    if self.last_blow >= 0 then self.last_effect_count = self.last_blow end
end

OPS.BUFF_NAMED = function(self, fx, target, source, controller, src)
    local name = fx.tokenDisplay
    if not fx.namedAnywhere and name ~= "" and name:sub(-1) == "s"
        and not (fx.nameFamily and D.isDesignerFamily(name)) then
        name = name:sub(1, -2)
    end
    local named
    if fx.namedAnywhere then
        named = {}
        for _, z in ipairs({ self:board_ids(controller), self:hand_ids(controller), self:deck_ids(controller) }) do
            for _, id in ipairs(z) do named[#named + 1] = id end
        end
    else
        named = self:board_ids(controller)
    end
    for _, id in ipairs(named) do
        local d = self:def_of(id)
        if d and not self:is_location(id) and (fx.nameFamily and D.cardIsNamed(d, name, true)
            or (not fx.nameFamily and d.name == name)) then
            self:apply_buff(id, fx.amount, fx.amount2, fx.keywordBits, false, srcCard(src))
        end
    end
end

local function discardBy(self, controller, better)
    local pick, pickCost = 0, 0
    for _, id in ipairs(self:hand_ids(controller)) do
        local d = self:def_of(id)
        if d and (pick == 0 or better(d.cost, pickCost)) then
            pick, pickCost = id, d.cost
        end
    end
    if pick ~= 0 then self:discard_card(pick, controller) end
end

OPS.DISCARD_LOWEST = function(self, fx, target, source, controller)
    discardBy(self, controller, function(a, b) return a < b end)
end

OPS.DISCARD_HIGHEST = function(self, fx, target, source, controller)
    discardBy(self, controller, function(a, b) return a > b end)
end

OPS.GRANT_BONUS_EFFECT = function(self, fx, target, source, controller, src)
    local t = self:ent(target)
    if not t or t.zone ~= ZONE.BOARD then return end
    local granted = 0
    for _ = 1, fx.amount do
        local pick = 0
        for _ = 1, 32 do
            local b = E.BONUS_EFFECT_KEYWORDS[self.state.rng:intBelow(8)]
            if band(granted, b) == 0 then
                pick = b
                break
            end
        end
        if pick == 0 then break end
        granted = bor(granted, pick)
    end
    if granted ~= 0 then self:apply_buff(target, 0, 0, granted, false, srcCard(src)) end
end

OPS.DISCARD_HAND = function(self, fx, target, source, controller)
    local hand = self:hand_ids(controller)
    if fx.amount > 0 then
        for _ = 1, fx.amount do
            if #hand == 0 then break end
            local pick = self.state.rng:intBelow(#hand) + 1
            self:discard_card(hand[pick], controller)
            table.remove(hand, pick)
        end
    else
        for _, id in ipairs(hand) do self:discard_card(id, controller) end
    end
end

OPS.DAMAGE_ADJACENT = function(self, fx, target, source)
    local victim = self:ent(target)
    if not victim or victim.zone ~= ZONE.BOARD then return end
    local board = self:board_ids(victim.controller)
    local at = #board + 1
    for i, id in ipairs(board) do
        if id == target then at = i break end
    end
    local splash = fx.amount2 > 0 and fx.amount2 or fx.amount
    self:deal_damage(target, fx.amount, source, fx.spell)
    if at > 1 and at <= #board + 1 then self:deal_damage(board[at - 1], splash, source, fx.spell) end
    if at < #board then self:deal_damage(board[at + 1], splash, source, fx.spell) end
end

OPS.HEAL = function(self, fx, target, source, controller)
    if self:heal_becomes_damage(controller) then
        self:deal_damage(target, fx.amount, source, false)
        self:consume_heal_as_damage(controller)
    else
        local heal = fx.amount
        if self:player_doubles(controller, 3) or (fx.spell and self:player_doubles(controller, 1)) then
            heal = heal * 2
        end
        self:heal_entity(target, heal)
    end
end

OPS.DRAW = function(self, fx, target, source, controller)
    local args = { fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.schoolFilter, fx.keywordFilterBits }
    if fx.target.side == "ENEMY_HERO" then
        for _ = 1, fx.amount do self:draw_card(other(controller), unpack(args)) end
        return
    end
    -- "Draw the bottom two cards from your deck": the plain draw takes from the other end.
    self.draw_from_bottom = fx.deckPosition == 2
    self.draw_secret_only = fx.secretOnly   -- "Draw a Secret"
    self.draw_trait = fx.traitFilterNum     -- "draw a card with Overload"
    self.draw_pick_cost = fx.pickCostNum    -- "draw your highest Cost minion"
    -- "Draw two 1-Attack minions", "draw a different spell".
    if E.has_stat_bounds(fx) or fx.excludeSource or fx.origin ~= 0 or fx.targetName ~= "" then
        self.draw_fx = fx
    else
        self.draw_fx = nil
    end
    self.draw_source = source
    self.draw_distinct = fx.distinct
    self.draw_used_races = 0
    self.draw_used_cards = {}
    self.draw_used_costs = {}
    for _ = 1, fx.amount do self:draw_card(controller, unpack(args)) end
    self.draw_distinct = 0
    self.draw_from_bottom = false
    self.draw_secret_only = false
    self.draw_trait = 0
    self.draw_pick_cost = 0
    self.draw_fx = nil
    self.draw_source = 0
    -- "Each player draws 2 cards": the same draw for the other seat.
    if fx.bothPlayers then
        for _ = 1, fx.amount do self:draw_card(other(controller), unpack(args)) end
    end
end

OPS.SUMMON = function(self, fx, target, source, controller, src)
    if fx.stuffed then
        if not src then return end
        local stuffing = src.stuffed
        src.stuffed = {}
        for _, id in ipairs(stuffing) do
            local minion = self:ent(id)
            if minion and minion.zone == ZONE.SETASIDE then
                if self:summon_existing(id, controller, -1) == 0 then break end
            end
        end
        return
    end
    local group = fx.tokens or EMPTY
    if #group > 0 then
        for _, token in ipairs(group) do
            if self:board_size(controller) >= 7 then break end
            local at = self.summon_pos
            self:summon_token(token, controller, at, false)
            self.summon_pos = nextSummonPos(at)
        end
        return
    end
    local pos = self.summon_pos
    self.summon_pos = nextSummonPos(pos)
    local side = fx.forOpponent and other(controller) or controller
    local created = self:summon_token(fx.token, side, fx.forOpponent and -1 or pos, false)
    if created ~= 0 and fx.keywordBits ~= 0 then
        self:apply_buff(created, 0, 0, fx.keywordBits, false, srcCard(src))
    end
    if created ~= 0 then
        self:after_summon_attack(created, fx, self.summon_defender)
    end
    local body = self:ent(created)
    if body and fx.statsFromHeroGains then
        local p = self:player(controller)
        body.attack = body.attack + p.hero_attack_gained_this_turn
        body.health = body.health + p.armor_gained_this_turn
        body.max_health = body.max_health + p.armor_gained_this_turn
    end
end

OPS.BUFF = function(self, fx, target, source, controller, src)
    if target == source and src and self:def_of(source) and self:def_of(source).type == "SPELL" then
        local hero = self:hero_of(controller)
        if hero then target = hero.id end
    end
    if fx.valueSource ~= "NONE" and fx.valueSource ~= "" then
        local scaled = self:scaled_effect(fx, controller, source)
        local value = scaled.amount
        if scaled.pairValue or fx.healthOnly then
            -- "Give it this minion's stats", "gain stats equal to your weapon's", "gain Health equal to ...".
            self:apply_buff(target, scaled.amount, scaled.amount2, fx.keywordBits, fx.temporary, srcCard(src),
                fx.durationTurns)
        else
            self:apply_buff(target, value, fx.statsBoth and value or 0, fx.keywordBits, fx.temporary, srcCard(src),
                fx.durationTurns)
        end
        return
    end
    self:apply_buff(target, fx.amount, fx.amount2, fx.keywordBits, fx.temporary, srcCard(src), fx.durationTurns)
    if fx.diesEndOfTurn then
        self:apply_buff(target, 0, 0, 0, false, "EOT_DESTROY")
    end
end

OPS.GAIN_ARMOR = function(self, fx, target, source, controller)
    -- "Spend all your Armor", "lose up to 5 Armor": a negative amount takes Armor, never below 0, and "that much" is
    -- what it took.
    if fx.amount < 0 then
        local t = self:ent(target)
        local hero = t and (t.zone == ZONE.HERO and t or self:hero_of(t.controller)) or nil
        local taken = 0
        if hero then
            taken = min(hero.armor, -fx.amount)
            hero.armor = hero.armor - taken
            if taken > 0 then self:player(hero.owner).armor_changed_this_turn = true end
        end
        self.last_effect_count = taken
        return
    end
    local t = self:ent(target)
    if t then self:gain_armor(t, fx.amount) end
    -- "Each player ... gains 6 Armor": the other hero too.
    if fx.bothPlayers then
        local foe = self:hero_of(other(controller))
        if foe and foe.id ~= target then self:gain_armor(foe, fx.amount) end
    end
end

OPS.RAISE_CORPSES = function(self, fx, target, source, controller)
    local p = self:player(controller)
    local wanted = fx.corpseMax < 0 and p.corpses or min(p.corpses, fx.corpseMax)
    if wanted <= 0 then return end
    local raised = 0
    for _ = 1, wanted do
        if self:board_size(controller) >= 7 then break end
        local at = self.summon_pos
        if self:summon_token(fx.token, controller, at, false) ~= 0 then raised = raised + 1 end
        self.summon_pos = nextSummonPos(at)
    end
    p.corpses = p.corpses - raised
    self:quest_count(controller, "SPEND_CORPSES", 0, raised)
end

OPS.GRANT_ABILITY = function(self, fx, target, source, controller)
    -- "Gain the Deathrattles of your minions that died this turn", "... of 3 friendly minions that died this game"
    -- (copyDeathrattle 1, fromGraveyard): printed Deathrattles of the dead, onto this minion.
    if fx.copyDeathrattle == 1 and fx.fromGraveyard then
        local me = self:ent(source)
        if not me or me.zone ~= ZONE.BOARD then return end
        local pool = {}
        for _, dead in ipairs(self:graveyard_pool(fx, controller, source)) do
            local corpse = self:ent(dead)
            local dd = self:def_of(dead)
            if corpse and dd and self:died_in_window(fx, corpse, controller) then
                for _, line in ipairs(dd.effects) do
                    if line.trigger == "DEATHRATTLE" then
                        pool[#pool + 1] = dd.id
                        break
                    end
                end
            end
        end
        local picked = {}
        if fx.amount > 0 and fx.amount < #pool then
            for _ = 1, fx.amount do
                if #pool == 0 then break end
                local at = self.state.rng:intBelow(#pool) + 1
                picked[#picked + 1] = pool[at]
                table.remove(pool, at)
            end
        else
            picked = pool
        end
        for _, cid in ipairs(picked) do
            me.granted[#me.granted + 1] = { card_id = cid, index = -1, seat = -1 }
        end
        return
    end
    if target == 0 then return end
    -- "Choose a friendly minion. Gain a copy of its Deathrattle" (copyDeathrattle 1): this minion takes the target's
    -- printed Deathrattle; a Silenced target has none.
    if fx.copyDeathrattle == 1 then
        local me = self:ent(source)
        local model = self:ent(target)
        local md = self:def_of(target)
        if not me or not model or not md or target == source or (model.zone == ZONE.BOARD and model.flags.silenced) then
            return
        end
        for _, line in ipairs(md.effects) do
            if line.trigger == "DEATHRATTLE" then
                me.granted[#me.granted + 1] = { card_id = md.id, index = -1, seat = -1 }
                break
            end
        end
        return
    end
    -- "... and this Deathrattle" (copyDeathrattle 2): the ability that is running, passed on. A line read from a grant
    -- names it; a card's own line names its printed Deathrattle.
    if fx.copyDeathrattle == 2 then
        local ref
        if fx.grant_origin_card and fx.grant_origin_card ~= "" then
            ref = { card_id = fx.grant_origin_card, index = fx.grant_origin_index, seat = -1 }
        else
            local own = self:def_of(source)
            if own then ref = { card_id = own.id, index = -1, seat = -1 } end
        end
        if ref then
            local t = self.state.entities[target]
            t.granted[#t.granted + 1] = ref
        end
        return
    end
    local grantee = self.state.entities[target]
    if not grantee then return end
    -- A Silenced minion can be given new text: Silence strips what it had, not what comes after.
    local giver = self:def_of(source)
    if not giver then return end
    -- "Choose a minion. Whenever it attacks, draw a card" (setVerb): the line is the caster's, whoever's minion.
    grantee.granted[#grantee.granted + 1] = { card_id = giver.id, index = self.effect_index,
        seat = fx.setVerb and controller or -1 }
end

-- Resolve an open choice at random, as a random cast makes every choice (Yogg-Saron's rule): up to 8 in a row, while
-- the choice is still this source's.
local function resolveRandomly(self, source)
    local s = self.state
    for _ = 1, 8 do
        if not (s.pending.active and s.pending.source == source and not self.aborted) then break end
        local count = #s.pending.card_options == 0 and #s.pending.options or #s.pending.card_options
        if count == 0 then break end
        if not self:apply_resolve({ type = "resolve", choice = s.rng:intBelow(count) }) then break end
    end
end

-- Cast a picked card (in hand, or just made) free: a Secret goes into play face down; a spell gets a random legal
-- target ("targets chosen randomly"), the enemy ones first with enemiesFirst, `prefer` when it can ("on this"; strict:
-- only it). Its choices are made at random.
function E:cast_picked(picked, enemiesFirst, prefer, strict)
    prefer = prefer or 0
    local s = self.state
    local castDef, castEntity = self:def_of(picked), self:ent(picked)
    if not castDef or not castEntity then return end
    local caster = castEntity.controller
    if castDef.secret then
        local p = self:player(caster)
        -- No second copy of a Secret in play (and none past five).
        if #p.secrets >= 5 or self:secret_in_play(caster, castDef.id) then
            self:relocate(picked, ZONE.GRAVEYARD, -1)
            return
        end
        self:relocate(picked, ZONE.SECRET, -1)
        s.entities[picked].play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        p.secrets[#p.secrets + 1] = picked
        p.game_secrets_played = p.game_secrets_played + 1
        return
    end
    self:relocate(picked, ZONE.GRAVEYARD, -1)
    local chosenTarget = 0
    -- "Cast a random spell" with the action's step budget nearly spent: no more casts.
    if s.loop_steps > 400 then return end
    -- A Choose One spell rolls its option first and aims with that option's targets.
    local option = 1
    if #castDef.choices > 0 then option = s.rng:intBelow(#castDef.choices) + 1 end
    local legal
    if #castDef.choices == 0 then
        legal = self:card_choose_targets(castDef, "ON_PLAY", caster, picked)
    else
        legal = self:card_choose_targets_for(castDef, castDef.choices[option], "ON_PLAY", caster, picked)
    end
    if enemiesFirst then
        local enemies = {}
        for _, id in ipairs(legal) do
            local t = self:ent(id)
            if t and t.controller ~= caster then enemies[#enemies + 1] = id end
        end
        if #enemies > 0 then legal = enemies end
    end
    local function contains(list, x)
        for _, v in ipairs(list) do if v == x then return true end end
        return false
    end
    if strict and (prefer == 0 or not contains(legal, prefer)) then return end
    if prefer ~= 0 and contains(legal, prefer) then
        chosenTarget = prefer
    elseif #legal > 0 then
        chosenTarget = legal[s.rng:intBelow(#legal) + 1]
    end
    self.random_cast = self.random_cast + 1
    -- A cast copy is not the play: "Outcast:" and "Finale:" read the card that was PLAYED.
    local outerOutcast, outerFinale = self.play_was_outcast, self.play_spent_last_mana
    self.play_was_outcast, self.play_spent_last_mana = false, false
    if #castDef.choices > 0 then
        self:run_effect_list(castDef.choices[option], picked, "ON_PLAY", chosenTarget, picked, nil)
    else
        self:run_effects(picked, "ON_PLAY", chosenTarget, picked)
    end
    -- A spell an effect casts is still a spell its controller cast: it Overloads, counts, and raises the cast events.
    if castDef.type == "SPELL" then
        local p = self:player(caster)
        if castDef.overload > 0 then
            p.overload_next = p.overload_next + castDef.overload
            p.game_mana_overloaded = p.game_mana_overloaded + castDef.overload
        end
        self:note_spell_cast(caster, castDef.schoolNum)
        self:queue("AFTER_CAST_SPELL", caster, picked)
        self:queue("SPELLBURST", caster, picked)
        self:queue("AFTER_OPPONENT_CAST_SPELL", other(caster), picked)
    end
    resolveRandomly(self, picked)
    self.play_was_outcast, self.play_spent_last_mana = outerOutcast, outerFinale
    self.random_cast = self.random_cast - 1
end

-- "Replay the last card you played": a spell is cast, a location goes into play, a minion is summoned and a weapon
-- equipped, then its Battlecry runs at random.
function E:replay_card(d, controller, enemiesFirst)
    if d.type == "SPELL" then
        self:cast_picked(self:create_entity(d, controller, ZONE.HAND, -1), enemiesFirst)
        return
    end
    local body = 0
    if d.type == "LOCATION" then
        if self:board_size(controller) >= 7 then return end
        local id = self:create_entity(d, controller, ZONE.HAND, -1)
        local s = self.state
        local location = s.entities[id]
        location.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        location.durability = d.durability
        location.attack, location.health, location.max_health = 0, 1, 1
        self:relocate(id, ZONE.BOARD, -1)
        self:recompute_auras()
        return
    end
    if d.type == "MINION" then
        if self:board_size(controller) >= 7 then return end
        body = self:summon_token(d.id, controller, -1, false)
    elseif d.type == "WEAPON" then
        self:equip_weapon(d.id, controller)
        body = self:player(controller).weapon_id
    end
    if body == 0 or self.aborted then return end
    self:run_random_battlecry(d, body, controller, enemiesFirst, true)
end

-- A card's Battlecry (or, with `choices`, one of its options at random) run from `source` with a random target, its
-- choices made at random. A repeated Battlecry is the Battlecry alone: no Combo, Quickdraw, Outcast or Finale lines.
function E:run_random_battlecry(d, source, controller, enemiesFirst, choices)
    local s = self.state
    if s.loop_steps > 400 or self.aborted then return end
    local lines, indexInCard, legal = {}, {}, nil
    local trigger = "BATTLECRY"
    local battlecryOption = false
    if choices and #d.choices > 0 then
        local option = s.rng:intBelow(#d.choices) + 1
        lines = d.choices[option]
        for i = 1, #lines do indexInCard[i] = -1 end
        battlecryOption = band(d.keywords, KW.BATTLECRY) ~= 0
        trigger = battlecryOption and "BATTLECRY" or "ON_PLAY"
        legal = self:card_choose_targets_for(d, d.choices[option], "ON_PLAY", controller, source)
    else
        for i, line in ipairs(d.effects) do
            if line.trigger == "BATTLECRY" and (choices or (line.condition ~= "COMBO" and line.condition ~= "QUICKDRAW"
                and line.condition ~= "OUTCAST" and line.condition ~= "FINALE")) then
                lines[#lines + 1] = line
                indexInCard[#indexInCard + 1] = i - 1
            end
        end
        legal = self:card_choose_targets(d, "BATTLECRY", controller, source)
    end
    if #lines == 0 then return end
    if enemiesFirst then
        local enemies = {}
        for _, id in ipairs(legal) do
            local t = self:ent(id)
            if t and t.controller ~= controller then enemies[#enemies + 1] = id end
        end
        if #enemies > 0 then legal = enemies end
    end
    local target = #legal == 0 and 0 or legal[s.rng:intBelow(#legal) + 1]
    self.random_cast = self.random_cast + 1
    local outerOutcast, outerFinale = self.play_was_outcast, self.play_spent_last_mana
    self.play_was_outcast, self.play_spent_last_mana = false, false
    -- A repeated "Discover ..." resumes in THESE lines, with the flat index the choice recorded.
    local outerLines, outerSource, outerAbility = self.replay_lines, self.replay_source, self.running_ability
    local outerCard, outerIndex = self.replay_card, self.replay_index
    self.replay_lines = lines
    self.replay_source = source
    self.running_ability = -1
    self.replay_card = d
    self.replay_index = indexInCard
    self:run_effect_list(lines, source, trigger, target, source, nil)
    if battlecryOption and not self.aborted and not s.pending.active then
        self:run_effect_list(lines, source, "ON_PLAY", target, source, nil)
    end
    resolveRandomly(self, source)
    self.replay_lines, self.replay_source, self.running_ability = outerLines, outerSource, outerAbility
    self.replay_card, self.replay_index = outerCard, outerIndex
    self.play_was_outcast, self.play_spent_last_mana = outerOutcast, outerFinale
    self.random_cast = self.random_cast - 1
end

OPS.CAST_FROM = function(self, fx, target, source, controller)
    local s = self.state
    local function admits(d)
        if not cardMatches(d, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.familyFilter,
            fx.rarityFilter, fx.schoolFilter) then
            return false
        end
        if not keywordFilterOk(fx, d) then return false end
        if fx.secretOnly and not d.secret then return false end
        if d.type ~= "SPELL" then return false end
        return not (d.secret and self:secret_in_play(controller, d.id))
    end
    -- "Repeat the last spell you've cast", "cast all Fel spells you've played this game" (fromHistory): copies of the
    -- history's spells, cast in play order.
    if fx.fromHistory ~= 0 then
        -- A history cast inside a history cast does nothing.
        if self.replay_depth > 0 then return end
        local function admitsHistory(d)
            if fx.replay == 0 then return admits(d) end
            if d.type ~= "MINION" and d.type ~= "SPELL" and d.type ~= "WEAPON" and not (fx.replay == 1 and d.type == "LOCATION") then
                return false
            end
            if fx.replay == 2 and not E.has_battlecry_line(d) then return false end
            return not (d.secret and self:secret_in_play(controller, d.id))
        end
        local pool = {}
        local own = self:def_of(source)
        for _, cid in ipairs(self:history_pool(fx, controller, source)) do
            local d = def(cid)
            if d and admitsHistory(d) and (not own or d.id ~= own.id) then pool[#pool + 1] = cid end
        end
        if #pool == 0 then return end
        local cast = {}
        if fx.historyPick == 0 and fx.amount > 1 then
            -- "Replay 5 cards from other classes you've played this game": N different plays at random.
            local left = {}
            for i, x in ipairs(pool) do left[i] = x end
            for _ = 1, fx.amount do
                if #left == 0 then break end
                local at = s.rng:intBelow(#left) + 1
                cast[#cast + 1] = left[at]
                table.remove(left, at)
            end
        elseif fx.historyPick == 1 then
            cast[1] = pool[#pool]
        elseif fx.historyPick == 2 or fx.historyPick == 3 then
            cast = pool
        elseif fx.historyPick == 5 then
            -- One at random of each Cost, cheapest first.
            local byCost, costs = {}, {}
            for _, cid in ipairs(pool) do
                local d = def(cid)
                if d then
                    if not byCost[d.cost] then
                        byCost[d.cost] = {}
                        costs[#costs + 1] = d.cost
                    end
                    local list = byCost[d.cost]
                    list[#list + 1] = cid
                end
            end
            table.sort(costs)
            for _, c in ipairs(costs) do
                local list = byCost[c]
                cast[#cast + 1] = list[s.rng:intBelow(#list) + 1]
            end
        else
            cast[1] = pool[s.rng:intBelow(#pool) + 1]
        end
        self.replay_depth = self.replay_depth + 1
        for _, cid in ipairs(cast) do
            if self.aborted or not self:step_budget() then break end
            local d = def(cid)
            if d and not (d.secret and self:secret_in_play(controller, d.id)) then
                if fx.replay == 1 then
                    self:replay_card(d, controller, fx.forOpponent)
                elseif fx.replay == 2 then
                    local me = self:ent(source)
                    if not me or me.zone ~= ZONE.BOARD then break end
                    -- A Battlecry that offers a choice repeats as one of its options, picked at random.
                    self:run_random_battlecry(d, source, controller, fx.forOpponent,
                        band(d.keywords, KW.BATTLECRY) ~= 0 and #d.choices > 0)
                else
                    -- A strict "on this" stops once this minion is gone.
                    local me = self:ent(source)
                    local here = me ~= nil and me.zone == ZONE.BOARD and not me.flags.dead
                    if fx.castStrict and not here then break end
                    self:cast_picked(self:create_entity(d, controller, ZONE.HAND, -1), fx.forOpponent,
                        fx.castOnSelf and source or 0, fx.castStrict)
                end
            end
        end
        self.replay_depth = self.replay_depth - 1
        return
    end
    local picked = 0
    if fx.amount2 == 3 then
        local pool = {}
        local own = self:def_of(source)
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            -- Convoke never casts Convoke.
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] and admits(cand) and (not own or cand.id ~= own.id) then
                pool[#pool + 1] = cid
            end
        end
        if #pool == 0 then return end
        local castDef = def(pool[s.rng:intBelow(#pool) + 1])
        if not castDef then return end
        picked = self:create_entity(castDef, controller, ZONE.HAND, -1)
    else
        local pool = {}
        local bestCost = -1
        for _, candId in ipairs(fx.amount2 == 2 and self:deck_ids(controller) or self:hand_ids(controller)) do
            local d = self:def_of(candId)
            if d and admits(d) then
                if fx.amount == 1 then
                    if d.cost > bestCost then
                        bestCost = d.cost
                        pool = { candId }
                    end
                else
                    pool[#pool + 1] = candId
                end
            end
        end
        if #pool == 0 then return end
        picked = pool[s.rng:intBelow(#pool) + 1]
    end
    -- "(targets this if possible)": castOnSelf.
    self:cast_picked(picked, fx.forOpponent, fx.castOnSelf and source or 0)
end

OPS.CHOOSE_HAND = function(self, fx, target, source, controller)
    local pend = self.state.pending
    pend.active = true
    pend.seat = controller
    pend.kind = "hand_action"
    pend.options = { fx.amount2 }
    pend.card_options = {}
    for _, handId in ipairs(self:hand_ids(controller)) do
        local d = self:def_of(handId)
        if d then
            local ok = true
            if fx.amount2 == 4 then
                if not keywordFilterOk(fx, d) then ok = false end
                if fx.costMax ~= 0 and d.cost > fx.costMax then ok = false end
                if fx.costMin ~= 0 and d.cost < fx.costMin then ok = false end
            end
            if ok then pend.card_options[#pend.card_options + 1] = d.id end
        end
    end
    if #pend.card_options == 0 then
        pend.active = false
        pend.kind = ""
        pend.options = {}
    end
end

OPS.INVOKE = function(self, fx, target, source, controller)
    local times = fx.amount > 0 and fx.amount or 1
    -- "If you've Invoked twice": every invocation counts, whatever the class makes of it.
    local inv = self:player(controller)
    inv.game_invokes = inv.game_invokes + times
    local cls = self:player(controller).hero_class
    for _ = 1, times do
        local power, powerTarget, applied
        if cls == D.FAMILY.WARRIOR then
            power = D.prepareEffect({ op = "BUFF", amount = 3, temporary = true })
            powerTarget = self:player(controller).hero_id
        elseif cls == D.FAMILY.WARLOCK then
            power = D.prepareEffect({ op = "SUMMON", tokens = { "EX1_598", "EX1_598" } })
        elseif cls == D.FAMILY.SHAMAN then
            power = D.prepareEffect({ op = "SUMMON", tokens = { "DRG_238t14t3" } })
        elseif cls == D.FAMILY.PRIEST then
            power = D.prepareEffect({ op = "ADD_TO_HAND", familyFilter = D.FAMILY.PRIEST + 1,
                type_filter = D.CARDTYPE.MINION + 1 })
        elseif cls == D.FAMILY.ROGUE then
            local pool = {}
            for _, cid in ipairs(D.all()) do
                local cand = def(cid)
                if cand and not cand.collectible and cand.type == "MINION" and cand.cost == 1 and cand.attack == 1
                    and cand.health == 1 and #cand.name > 7 and cand.name:sub(-7):lower() == " lackey" then
                    pool[#pool + 1] = cid
                end
            end
            if #pool > 0 then
                local d = def(pool[self.state.rng:intBelow(#pool) + 1])
                if d then
                    local id = self:create_entity(d, controller, ZONE.HAND, -1)
                    if #self:hand_ids(controller) > 10 then self:relocate(id, ZONE.GRAVEYARD, -1) end
                end
            end
            applied = true
        else
            applied = true
        end
        if not applied then self:apply_op(power, powerTarget or 0, source, controller) end
    end
end

OPS.GAIN_CORPSES = function(self, fx, target, source, controller)
    -- "Spend up to 5 Corpses" (a negative amount; -99 all): never below 0, and "that much" is what it took.
    if fx.amount < 0 then
        local p = self:player(controller)
        local taken = min(p.corpses, -fx.amount)
        p.corpses = p.corpses - taken
        self.last_effect_count = taken
        self:quest_count(controller, "SPEND_CORPSES", 0, taken)
        return
    end
    local p = self:player(controller)
    p.corpses = p.corpses + fx.amount
end

OPS.GAIN_MANA = function(self, fx, target, source, controller)
    local function gain(p)
        local got = min(max(0, 10 - p.mana), fx.amount)
        p.temp_mana = p.temp_mana + got
        p.mana = p.mana + got
    end
    gain(self:player(controller))
    if fx.bothPlayers then gain(self:player(other(controller))) end
end

OPS.SET_MANA_CRYSTALS = function(self, fx)
    for seat = 0, 1 do
        local p = self:player(seat)
        p.max_mana = min(10, fx.amount)
        p.mana = min(10, fx.amount)
    end
end

OPS.GAIN_MANA_CRYSTAL = function(self, fx, target, source, controller)
    local full = fx.amount2 == 1
    local function gain(p)
        local got = min(fx.amount, max(0, 10 - p.max_mana))
        p.max_mana = p.max_mana + got
        if full then p.mana = min(10, p.mana + got) end
    end
    -- "Give your opponent a Mana Crystal": theirs only.
    if not fx.forOpponent then gain(self:player(controller)) end
    if fx.bothPlayers or fx.forOpponent then gain(self:player(other(controller))) end
end

OPS.GO_DORMANT = function(self, fx, target)
    local t = self:ent(target)
    if not t or t.zone ~= ZONE.BOARD then return end
    -- "After you play 3 cards, this awakens" (amount 0; amount2 counts the events on the minion).
    if fx.amount == 0 then
        if t.flags.dormant_turns == 0 then return end
        if fx.amount2 > 1 then
            t.number = t.number + 1
            if t.number < fx.amount2 then return end
        end
        t.number = 0   -- a bounced and replayed sleeper counts from zero again
        t.flags.dormant_turns = 0
        t.flags.exhausted = band(t.keywords, bor(KW.CHARGE, KW.RUSH)) == 0
        -- It arrives now: Rush reaches only minions this turn, however long ago it was played.
        t.flags.just_played_turn = self.state.turn
        self:queue_self("WHEN_AWAKENS", target)
        return
    end
    t.flags.dormant_turns = fx.amount
    t.flags.exhausted = true
end

OPS.SUMMON_COPY = function(self, fx, target, source, controller)
    local copyOf = self:ent(target)
    if not copyOf or (copyOf.zone ~= ZONE.BOARD and copyOf.zone ~= ZONE.GRAVEYARD and copyOf.zone ~= ZONE.HAND
        and copyOf.zone ~= ZONE.DECK) then
        return
    end
    local d = self:def_of(copyOf.id)
    if not d then return end
    -- "Destroy a minion, then return it to life with full Health": the minion this text destroyed dies first (its
    -- Deathrattle resolves and its slot empties) and comes back where it stood.
    local returnsAt = -1
    if fx.setVerb and fx.freshCopy and (fx.target.kind == "PREVIOUS" or fx.target.kind == "REMEMBERED")
        and copyOf.zone == ZONE.BOARD and (copyOf.flags.dead or copyOf.health <= 0) then
        returnsAt = copyOf.zone_pos
        -- The death pass runs other cards' text: this line's summon slot and "it" are its own again after.
        local outerPos = self.summon_pos
        local outerSummoned = {}
        for i, x in ipairs(self.summoned_this_effect) do outerSummoned[i] = x end
        local settled = self:settle()
        self.summon_pos = outerPos
        self.summoned_this_effect = outerSummoned
        if not settled or self.aborted or self:is_terminal() then return end
        copyOf = self:ent(target)
        if not copyOf then return end
    end
    -- "Battlecry: destroy a minion. Deathrattle: RESUMMON it": a remembered minion comes back for its owner.
    local copySide = (fx.setVerb and fx.target.kind == "REMEMBERED") and copyOf.owner or controller
    local n = max(1, fx["repeat"])
    local pos = returnsAt >= 0 and min(returnsAt, self:board_size(copySide)) or self.summon_pos
    self.summon_pos = pos < 0 and -1 or pos + n
    local madeIds = {}
    for k = 0, n - 1 do
        local made = self:summon_token(d.id, copySide, pos < 0 and -1 or pos + k, false)
        if made == 0 then break end
        madeIds[#madeIds + 1] = made
    end
    -- A minion that already died, or is dying, is resummoned fresh from its card; "a NEW copy" is fresh too.
    local asItIs = copyOf.zone == ZONE.BOARD and not copyOf.flags.dead and copyOf.health > 0 and not fx.freshCopy
    for _, madeId in ipairs(madeIds) do
        local made = self:ent(madeId)
        if made then
            if fx.amount < 0 or fx.amount2 < 0 then
                -- "Resummon this with -1/-1": the print names a CHANGE, not replacement stats.
                made.attack = max(0, made.attack + fx.amount)
                made.max_health = max(1, made.max_health + fx.amount2)
                made.health = min(made.health + fx.amount2, made.max_health)
            elseif fx.amount > 0 or fx.amount2 > 0 then
                made.attack = fx.amount
                made.max_health = fx.amount2
                made.health = fx.amount2
                if asItIs then
                    made.keywords = copyOf.keywords
                    made.flags.divine_shield = copyOf.flags.divine_shield
                    -- A 1/1 copy is still a copy: its Silence, granted text and Magnetic cards come along.
                    made.flags.silenced = copyOf.flags.silenced
                    made.granted = E.deepCopy(copyOf.granted)
                    made.magnetized = E.deepCopy(copyOf.magnetized)
                    self:ready_if_charged(made)
                end
            elseif asItIs then
                made.attack = copyOf.attack
                made.max_health = copyOf.max_health
                made.health = copyOf.health
                made.keywords = copyOf.keywords
                made.spell_damage = copyOf.spell_damage
                made.flags.divine_shield = copyOf.flags.divine_shield
                -- The buff records come along with the stats they made.
                made.buffs = E.deepCopy(copyOf.buffs)
                made.flags.silenced = copyOf.flags.silenced
                made.granted = E.deepCopy(copyOf.granted)
                made.magnetized = E.deepCopy(copyOf.magnetized)
                self:ready_if_charged(made)
            end
            -- "... with 1 Health remaining", "return it to life with 1 Health": the Health left, the Max kept.
            if fx.remainingHealth > 0 then made.health = min(fx.remainingHealth, made.max_health) end
        end
    end
    -- "Summon a copy of an enemy minion. It attacks the original": the copy attacks what it copied.
    for _, madeId in ipairs(madeIds) do
        self:after_summon_attack(madeId, fx, target)
    end
end

OPS.SUMMON_WITH_STATS = function(self, fx, target, source, controller, src)
    local attack, health = 0, 0
    if fx.statsFromSource then
        local from = self:ent(source)
        if not from then return end
        attack, health = from.attack, from.health
    else
        local scaled = (fx.valueSource == "NONE" or fx.valueSource == "") and fx
            or self:scaled_effect(fx, controller, source)
        -- "Summon a Giant with its stats": a pair's Health is its own.
        attack, health = scaled.amount, scaled.pairValue and scaled.amount2 or scaled.amount
    end
    local pos = self.summon_pos
    self.summon_pos = nextSummonPos(pos)
    local created
    if fx.summonNamed then
        created = self:summon_token(fx.token, controller, pos, false)
    else
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and cand.type == "MINION" and cand.health > 0
                and (fx.raceFilterBits == 0 or hasRace(cand.races, fx.raceFilterBits)) then
                pool[#pool + 1] = cid
            end
        end
        if #pool == 0 then return end
        created = self:summon_token(pool[self.state.rng:intBelow(#pool) + 1], controller, pos, false)
    end
    if created == 0 then return end
    local made = self:ent(created)
    if made then
        made.attack, made.max_health, made.health = attack, health, health
        if fx.keywordBits ~= 0 then self:apply_buff(created, 0, 0, fx.keywordBits, false, srcCard(src)) end
    end
    self:after_summon_attack(created, fx, self.summon_defender)
end

OPS.DESTROY_MANA_CRYSTAL = function(self, fx, target, source, controller)
    local function destroy(seat)
        local p = self:player(seat)
        p.max_mana = max(0, p.max_mana - fx.amount)
        p.mana = min(p.mana, p.max_mana)
    end
    destroy(controller)
    if fx.bothPlayers then destroy(other(controller)) end
end

OPS.DRAW_UNTIL = function(self, fx, target, source, controller)
    -- "Draw cards until you have N": the shortfall is counted once and that many cards are drawn.
    -- "Each player draws until they have 5 cards", "your opponent draws until ...".
    for _, who in ipairs({ fx.forOpponent and other(controller) or controller, other(controller) }) do
        if who == other(controller) and not fx.bothPlayers and not fx.forOpponent then break end
        local shortBy = fx.amount - #self:hand_ids(who)
        local i = 0
        while i < shortBy and i < 10 do
            self:draw_card(who, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.schoolFilter,
                fx.keywordFilterBits)
            i = i + 1
        end
        if not fx.bothPlayers then break end
    end
end

OPS.SUMMON_COPY_FROM = function(self, fx, target, source, controller)
    local owner = fx.target.side == "ENEMY_HERO" and other(controller) or controller
    local pool = {}
    for _, id in ipairs(fx.fromDeck and self:deck_ids(owner) or self:hand_ids(owner)) do
        local d = self:def_of(id)
        if d and d.type == "MINION" then pool[#pool + 1] = id end
    end
    if #pool == 0 then return end
    local pick = pool[self.state.rng:intBelow(#pool) + 1]
    local original, d = self:ent(pick), self:def_of(pick)
    if not original or not d then return end
    local pos = self.summon_pos
    self.summon_pos = nextSummonPos(pos)
    local created = self:summon_token(d.id, controller, pos, false)
    if created == 0 then return end
    local made = self:ent(created)
    if not made then return end
    if fx.amount > 0 or fx.amount2 > 0 then
        made.attack, made.max_health, made.health = fx.amount, fx.amount2, fx.amount2
    else
        made.attack = original.attack
        made.max_health = original.max_health
        made.health = original.health
        made.keywords = original.keywords
        made.spell_damage = original.spell_damage
    end
end

OPS.FATIGUE_DAMAGE = function(self, fx, target, source, controller)
    local seats = { controller, other(controller) }
    local dealt = 0
    for n = 1, fx.bothPlayers and 2 or 1 do
        local p = self:player(seats[n])
        p.fatigue = p.fatigue + 1
        local hero = self:hero_of(seats[n])
        if hero then
            dealt = self:deal_damage(hero.id, p.fatigue, 0, false)
            if hero.health <= 0 then self.fatigue_kill[seats[n] + 1] = true end
        end
    end
    self.last_effect_count = dealt
end

OPS.SPEND_ALL_MANA = function(self, fx, target, source, controller)
    local p = self:player(controller)
    local spent = p.mana
    p.mana = 0
    p.temp_mana = 0
    self.last_effect_count = spent
end

OPS.EMPOWER_ABILITIES = function(self, fx, target, source)
    local titan = self:ent(source)
    if titan then titan.number = max(1, titan.number) * max(2, fx.amount) end
end

OPS.REPEAT_ABILITY = function(self, fx, target, source, controller)
    if self.titan_last ~= source or self.titan_last_index < 0 then return end
    local others = {}
    for _, id in ipairs(self:board_ids(controller)) do
        local o = self:ent(id)
        if id ~= source and o and not o.flags.dead and o.health > 0 and not self:is_location(id) then
            others[#others + 1] = id
        end
    end
    if #others == 0 then return end
    local picked = others[self.state.rng:intBelow(#others) + 1]
    self:run_titan_ability(source, self.titan_last_index, 0, picked)
end

-- When the dead minion died (RESURRECT, fromGraveyard): 1 this turn, 2 after your last turn, 0 any time.
function E:died_in_window(fx, e, controller)
    if fx.diedWhen == 1 then return e.died_turn == self.state.turn end
    -- "After your last turn": the opponent's turn since then and this one.
    if fx.diedWhen == 2 then
        return e.died_turn >= (controller == self.state.active and self.state.turn - 1 or self.state.turn)
    end
    return true
end

-- "Your last Demon that died": the latest death among `dead`, by the owner's death record.
function E:last_to_die(dead, owner)
    local order = self:player(owner).last_destroyed_cards
    for i = #order, 1, -1 do
        for _, id in ipairs(dead) do
            local d = self:def_of(id)
            if d and d.id == order[i] then return id end
        end
    end
    return #dead == 0 and 0 or dead[#dead]
end

OPS.RESURRECT = function(self, fx, target, source, controller)
    local s = self.state
    local own = self:def_of(source)
    local dead = {}
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e and e.zone == ZONE.GRAVEYARD and e.owner == controller and e.flags.dead
            and self:died_in_window(fx, e, controller) then
            local d = self:def_of(id)
            local ok = d ~= nil and d.type == "MINION"
            if ok and fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits) then ok = false end
            -- "Resurrect four friendly Imps": the pool by name (a family with nameFamily).
            if ok and fx.targetName ~= "" and not D.cardIsNamed(d, fx.targetName, fx.nameFamily) then ok = false end
            if ok and fx.keywordFilterBits ~= 0 then
                local have = d.keywords
                for _, x in ipairs(d.effects) do
                    if x.trigger == "DEATHRATTLE" then have = bor(have, KW.DEATHRATTLE) end
                end
                if band(have, fx.keywordFilterBits) ~= fx.keywordFilterBits then ok = false end
            end
            if ok and fx.costMin ~= 0 and d.cost < fx.costMin then ok = false end
            if ok and fx.costMax ~= 0 and d.cost > fx.costMax then ok = false end
            if ok and fx.excludeSource and own and d.id == own.id then ok = false end
            -- "Resurrect a 2-Attack minion from your class": the printed stats and the controller's class.
            if ok and E.has_stat_bounds(fx) and not self:stats_admit(fx, d.attack, d.health, source) then ok = false end
            if ok and fx.classPool == 3 and d.familyNum ~= self:player(controller).hero_class then ok = false end
            if ok then dead[#dead + 1] = id end
        end
    end
    -- "Resurrect your last Demon that died": the latest death only.
    if fx.historyPick == 1 and #dead > 0 then dead = { self:last_to_die(dead, controller) } end
    -- "Resurrect two DIFFERENT friendly Mechs": no card comes back twice. Read off the printed word.
    local different = fx.amount > 1 and own ~= nil and own.text:find("different", 1, true) ~= nil
    for _ = 1, max(1, fx.amount) do
        if #dead == 0 then break end
        local pool = dead
        if fx.amount2 == 1 then
            local highest = -1
            for _, id in ipairs(dead) do highest = max(highest, self:def_of(id).cost) end
            pool = {}
            for _, id in ipairs(dead) do
                if self:def_of(id).cost == highest then pool[#pool + 1] = id end
            end
        end
        local picked = pool[s.rng:intBelow(#pool) + 1]
        if different then
            local card = self:def_of(picked).id
            local kept = {}
            for _, id in ipairs(dead) do
                if self:def_of(id).id ~= card then kept[#kept + 1] = id end
            end
            dead = kept
        else
            for i, id in ipairs(dead) do
                if id == picked then table.remove(dead, i) break end
            end
        end
        local pos = self.summon_pos
        self.summon_pos = nextSummonPos(pos)
        local madeHere = self:summon_token(self:def_of(picked).id, controller, pos, false)
        if madeHere == 0 then break end   -- a full board
        self:after_summon_attack(madeHere, fx, self.summon_defender)
    end
end

OPS.DAMAGE_MULTIPLIER = function(self, fx, target, source, controller)
    if fx.trigger ~= "AURA" then
        self:player(controller).minions_double_damage_this_turn = true
    end
end

OPS.HEAL_TO_FULL = function(self, fx, target)
    local e = self:ent(target)
    if e and e.max_health > 0 then e.health = e.max_health end
end

OPS.HEAL_AS_DAMAGE = function(self, fx, target, source, controller)
    local p = self:player(controller)
    if fx.amount2 == 0 then
        p.heal_as_damage_next = p.heal_as_damage_next + 1
    elseif fx.amount2 == 1 then
        p.heal_as_damage_this_turn = true
    end
end

OPS.TRIGGER_DEATHRATTLE = function(self, fx, target, source, controller)
    -- "Trigger the Deathrattle of a random friendly minion that died this game" (fromGraveyard): dead minions with a
    -- printed Deathrattle, `amount` different deaths at random, each run as its own source.
    if fx.fromGraveyard then
        local pool = {}
        for _, id in ipairs(self:graveyard_pool(fx, controller, source)) do
            local dd = self:def_of(id)
            if dd then
                for _, line in ipairs(dd.effects) do
                    if line.trigger == "DEATHRATTLE" then
                        pool[#pool + 1] = id
                        break
                    end
                end
            end
        end
        local outer = self.far_right_summons
        self.far_right_summons = true
        for _ = 1, max(1, fx.amount) do
            if #pool == 0 or self.aborted or not self:step_budget() then break end
            local at = self.state.rng:intBelow(#pool) + 1
            local dead = pool[at]
            table.remove(pool, at)
            self.summon_pos = -1
            -- The dead card's printed Deathrattle: a Silence it took in play stayed on it.
            local corpse = self:ent(dead)
            local wasSilenced = corpse and corpse.flags.silenced or false
            if corpse then corpse.flags.silenced = false end
            self:run_effects(dead, "DEATHRATTLE", 0, dead)
            local again = self:ent(dead)
            if again and again.zone == ZONE.GRAVEYARD then again.flags.silenced = wasSilenced end
        end
        self.far_right_summons = outer
        self.summon_pos = -1
        return
    end
    local t = self:ent(target)
    -- "Draw a Deathrattle card. Trigger its Deathrattle" (PREVIOUS in hand): the printed Deathrattle runs from the
    -- card where it is; what it summons arrives at the right end.
    if t and t.zone == ZONE.HAND and fx.target.kind == "PREVIOUS" then
        local hasLine = false
        local hd = self:def_of(target)
        if hd then
            for _, line in ipairs(hd.effects) do hasLine = hasLine or line.trigger == "DEATHRATTLE" end
        end
        if hasLine then
            self.summon_pos = -1
            self:run_effects(target, "DEATHRATTLE", 0, target)
            self.summon_pos = -1
        end
        return
    end
    -- A Silenced minion triggers only what was granted after the Silence (has_deathrattle says whether any).
    if not t or t.zone ~= ZONE.BOARD then return end
    if not self:def_of(target) or not self:has_deathrattle(target) then return end
    -- A living minion's Deathrattle summons at the far right of the board.
    self.summon_pos = -1
    local outerFar = self.far_right_summons
    self.far_right_summons = true
    local grants = {}
    for i, g in ipairs(t.granted) do grants[i] = g end
    -- "Your minions trigger their Deathrattles twice" doubles one an effect triggers too (Feign Death).
    local passes = self:triggers_twice(t.owner, 2) and 2 or 1
    for pass = 1, passes do
        if self.aborted then break end
        if pass > 1 and self.state.pending.active then break end
        self:run_effects(target, "DEATHRATTLE", 0, target)
        for _, g in ipairs(grants) do
            if self.aborted then break end
            local lines = self:granted_lines(g)
            if #lines > 0 then
                self:run_effect_list(lines, target, "DEATHRATTLE", 0, target, nil, 0,
                    t.flags.silenced and t.owner or nil)
            end
        end
    end
    self.far_right_summons = outerFar
    self.summon_pos = -1
end

OPS.REFRESH_MANA = function(self, fx, target, source, controller)
    local p = self:player(controller)
    -- Mana already above the crystals (The Coin) is kept: a refresh fills, it never takes away.
    if p.mana < p.max_mana then
        p.mana = min(p.max_mana, p.mana + fx.amount)
    end
end

OPS.TRANSFORM = function(self, fx, target, source, controller)
    local s = self.state
    -- "Become a copy of it" (Faceless Manipulator), "transform adjacent minions into a copy of this": copyFrom 1 is
    -- the target becoming a copy of this, 2 this becoming a copy of the target.
    local model
    local victim = target
    if fx.copyFrom == 1 or fx.copyFrom == 2 then
        victim = fx.copyFrom == 1 and target or source
        model = self:ent(fx.copyFrom == 1 and source or target)
        if not model or victim == model.id then return end
    end
    local t = self:ent(victim)
    if not t or (t.zone ~= ZONE.BOARD and t.zone ~= ZONE.HAND and t.zone ~= ZONE.DECK) then return end
    local into
    local absolutePool = fx.token == "" and (fx.costMin ~= 0 or fx.costMax ~= 0 or fx.raceFilterBits ~= 0
        or fx.type_filter ~= 0 or fx.familyFilter ~= 0 or fx.schoolFilter ~= 0 or fx.keywordFilterBits ~= 0
        or fx.rarityFilter ~= 0)
    if model then
        into = self:def_of(model.id)
    elseif fx.token == "" and (fx.fromHand or fx.fromDeck) then
        local whose = fx.forOpponent and other(controller) or controller
        local pool = {}
        for _, candId in ipairs(fx.fromHand and self:hand_ids(whose) or self:deck_ids(whose)) do
            local cand = self:def_of(candId)
            if cand then pool[#pool + 1] = cand.id end
        end
        if #pool == 0 then return end
        into = def(pool[s.rng:intBelow(#pool) + 1])
    elseif absolutePool then
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type]
                and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.familyFilter,
                    fx.rarityFilter, fx.schoolFilter)
                and keywordFilterOk(fx, cand) then
                pool[#pool + 1] = cid
            end
        end
        if #pool == 0 then return end
        into = def(pool[s.rng:intBelow(#pool) + 1])
    elseif fx.token == "" then
        local was = def(t.card_id)
        if not was then return end
        local wanted = max(0, was.cost + fx.amount)
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and cand.type == "MINION" and cand.cost == wanted then pool[#pool + 1] = cid end
        end
        if #pool == 0 then return end
        into = def(pool[s.rng:intBelow(#pool) + 1])
    else
        into = def(fx.token)
    end
    if not into then return end
    for _, b in ipairs(t.buffs) do
        t.attack = t.attack - b.attack
        t.max_health = t.max_health - b.health
    end
    t.buffs = {}
    t.card_id = into.id
    t.cost_delta, t.temp_cost_delta, t.cost_override, t.cost_override_this_turn = 0, 0, -1, false
    t.pays_with, t.pays_with_this_turn, t.bonus_effect_bits = 0, false, 0
    t.attack = (absolutePool and fx.amount > 0) and fx.amount or into.attack
    t.max_health = (absolutePool and fx.amount2 > 0) and fx.amount2 or into.health
    t.health = (absolutePool and fx.amount2 > 0) and fx.amount2 or into.health
    t.durability = into.durability
    t.keywords = bor(into.keywords, fx.keywordBits)
    t.spell_damage = into.spell_damage + (absolutePool and fx.bonusSpellDamage or 0)
    t.flags.divine_shield = band(t.keywords, KW.DIVINE_SHIELD) ~= 0
    t.flags.stealth = band(t.keywords, KW.STEALTH) ~= 0
    t.flags.frozen = false
    t.flags.dead = false
    t.flags.silenced = false
    t.flags.dormant_turns = 0
    t.granted = {}
    t.magnetized = {}
    -- A copy of a minion in play is the minion AS IT IS (stats, keywords, buffs, Silence); "a 4/4 copy" names the
    -- stats instead, with no buff records under them.
    if model then
        local asItIs = model.zone == ZONE.BOARD and not model.flags.dead and model.health > 0
        if asItIs then
            t.attack, t.max_health, t.health = model.attack, model.max_health, model.health
            t.keywords = model.keywords
            t.spell_damage = model.spell_damage
            t.buffs = E.deepCopy(model.buffs)
            t.flags.divine_shield = model.flags.divine_shield
            t.flags.stealth = model.flags.stealth
            t.flags.silenced = model.flags.silenced
            t.granted = E.deepCopy(model.granted)
            t.magnetized = E.deepCopy(model.magnetized)
        end
        if fx.amount > 0 or fx.amount2 > 0 then
            t.buffs = {}
            t.attack = fx.amount
            t.max_health = fx.amount2
            t.health = fx.amount2
        end
    end
    self:ready_if_charged(t)
end

OPS.SHUFFLE = function(self, fx, target, source, controller)
    local s = self.state
    local owner = fx.target.side == "ENEMY_HERO" and other(controller) or controller
    -- Run 16: "Shuffle cards into your deck, 5 times": one shuffle into the player's own deck, however many cards.
    if owner == controller then self:quest_count(controller, "SHUFFLE", source, 1) end
    if fx.amount2 == 4 then
        local seatState = self:player(controller)
        for _, cid in ipairs(seatState.chain_options) do
            local d = def(cid)
            if d then
                local made = self:create_entity(d, controller, ZONE.DECK, -1)
                local size = #self:deck_ids(controller)
                local at = size == 0 and 0 or s.rng:intBelow(size)
                self:relocate(made, ZONE.DECK, at)
            end
        end
        seatState.chain_options = {}
        seatState.chain_card = ""
        seatState.chain_source = 0
        return
    end
    if fx.amount2 == 1 then
        self.last_effect_count = #self:hand_ids(controller)
        for _, id in ipairs(self:hand_ids(controller)) do
            local size = #self:deck_ids(owner)
            local at = size == 0 and 0 or s.rng:intBelow(size + 1)
            self:relocate(id, ZONE.DECK, at)
            if self.aborted then return end
        end
        return
    end
    -- "Shuffle two random Plagues into your opponent's deck": a random card of the effect's own group, drawn afresh.
    local grouped
    local group = fx.tokens or EMPTY
    if #group > 1 then
        local pool = {}
        for _, token in ipairs(group) do
            if def(token) then pool[#pool + 1] = token end
        end
        if #pool > 0 then grouped = pool[s.rng:intBelow(#pool) + 1] end
    end
    -- "Put a random spell on top of your opponent's deck": an empty token with a pool filter draws from the pool.
    local pooled
    if not grouped and fx.token == "" and fx.target.kind == "SELF" and (fx.type_filter ~= 0 or fx.raceFilterBits ~= 0
        or fx.costMin ~= 0 or fx.costMax ~= 0 or fx.schoolFilter ~= 0 or fx.familyFilter ~= 0 or fx.rarityFilter ~= 0) then
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax,
                fx.raceFilterBits, fx.familyFilter, fx.rarityFilter, fx.schoolFilter) then
                pool[#pool + 1] = cid
            end
        end
        if #pool == 0 then return end
        pooled = pool[s.rng:intBelow(#pool) + 1]
    end
    local d
    if grouped then
        d = def(grouped)
    elseif pooled then
        d = def(pooled)
    elseif fx.token ~= "" then
        d = def(fx.token)
    elseif fx.target.kind == "SELF" then
        d = self:def_of(source)
    elseif target ~= 0 then
        d = self:def_of(target)
    end
    if not d then return end
    local id = self:create_entity(d, owner, ZONE.DECK, -1)
    local shuffled = self:ent(id)
    local shuffling = self:def_of(source)
    if shuffled and shuffling then
        shuffled.drawn_from = shuffling.id
        -- A card shuffling another of itself "with permanent +2/+1": the new one has this one's permanent buffs too.
        if shuffling.id == d.id then self:carry_permanent_buffs(source, id) end
    end
    local size = #self:deck_ids(owner)
    local at
    if fx.deckPosition == 1 then at = 0
    elseif fx.deckPosition == 2 then at = size
    elseif size == 0 then at = 0
    else at = s.rng:intBelow(size) end
    self:relocate(id, ZONE.DECK, at)
    self.shuffled_this_effect[#self.shuffled_this_effect + 1] = id
end

OPS.FILL_HAND = function(self, fx, target, source, controller)
    local s = self.state
    if fx.target.kind == "PREVIOUS" then
        local original = self:ent(target)
        local d = original and self:def_of(target)
        local guard = 0
        while d and guard < 10 do
            guard = guard + 1
            if #self:hand_ids(controller) >= 10 then break end
            local id = self:create_entity(d, controller, ZONE.HAND, -1)
            local made = self:ent(id)
            if made and original.zone == ZONE.HAND then
                made.attack, made.health, made.max_health = original.attack, original.health, original.max_health
                made.keywords, made.cost_delta = original.keywords, original.cost_delta
            end
            self.drawn_this_effect[#self.drawn_this_effect + 1] = id
        end
        return
    end
    if fx.token ~= "" then
        local whose = fx.forOpponent and other(controller) or controller
        local d = def(fx.token)
        local guard = 0
        while d and guard < 10 do
            guard = guard + 1
            if #self:hand_ids(whose) >= 10 then break end
            self.drawn_this_effect[#self.drawn_this_effect + 1] = self:create_entity(d, whose, ZONE.HAND, -1)
        end
        return
    end
    local mine = self:player(controller).hero_class
    for _ = 1, 20 do
        if #self:hand_ids(controller) >= 10 then break end
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] then
                local ok
                if fx.familyFilter ~= 0 then
                    ok = cand.familyNum == fx.familyFilter - 1
                else
                    ok = not (fx.classPool == 3 and cand.familyNum ~= mine)
                end
                if ok and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                    fx.rarityFilter, fx.schoolFilter) then
                    pool[#pool + 1] = cid
                end
            end
        end
        if #pool == 0 then break end
        local d = def(pool[s.rng:intBelow(#pool) + 1])
        if not d then break end
        local id = self:create_entity(d, controller, ZONE.HAND, -1)
        if #self:hand_ids(controller) > 10 then
            self:relocate(id, ZONE.GRAVEYARD, -1)
        else
            self.drawn_this_effect[#self.drawn_this_effect + 1] = id
        end
    end
end

-- The cards in a player's play history (fromHistory 1 the controller's, 2 the opponent's), oldest first, that the
-- effect's filters admit. historyPick 3 keeps only that player's last turn, 4 this turn. The card being played is the
-- newest entry of its controller's history, and it is not its own last play.
function E:history_pool(fx, controller, source)
    local owner = fx.fromHistory == 2 and other(controller) or controller
    local p = self:player(owner)
    local s = self.state
    local lastTurn = owner == s.active and s.turn - 2 or s.turn - 1
    local stop = #p.played_history
    if owner == controller and stop > 0 then
        local me = self:ent(source)
        if me and p.played_history[stop].card == me.card_id then stop = stop - 1 end
    end
    local out = {}
    for i = 1, stop do
        local played = p.played_history[i]
        local keep = true
        if fx.historyPick == 3 and (lastTurn < 1 or played.turn ~= lastTurn) then keep = false end
        if keep and fx.historyPick == 4 and played.turn ~= s.turn then keep = false end
        if keep and fx.historyTarget == 1 and played.target_side ~= 1 then keep = false end
        if keep and fx.historyTarget == 2 and played.target_side ~= 2 and played.target_side ~= 3 then keep = false end
        local d = keep and def(played.card)
        if d and PLAYABLE_TYPE[d.type]
            and cardMatches(d, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.familyFilter,
                fx.rarityFilter, fx.schoolFilter)
            and keywordFilterOk(fx, d)
            and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(d, fx.traitFilterNum, p.hero_class, d.keywords))
            and not (fx.targetName ~= "" and not D.cardIsNamed(d, fx.targetName, fx.nameFamily))
            and not (fx.excludeSource and self:same_card_as_source(d.id, source))
            and not (E.has_stat_bounds(fx) and not self:stats_admit(fx, d.attack, d.health, source))
            and not (fx.otherClass and (d.familyNum == p.hero_class or d.family == "NEUTRAL")) then
            out[#out + 1] = d.id
        end
    end
    return out
end

-- The dead minions an effect may take from the graveyard (the controller's; historyBoth either player's), by its
-- filters and its death window.
function E:graveyard_pool(fx, controller, source)
    local own = self:def_of(source)
    local s = self.state
    local out = {}
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e and e.zone == ZONE.GRAVEYARD and e.flags.dead and (e.owner == controller or fx.historyBoth)
            and self:died_in_window(fx, e, controller) then
            local d = self:def_of(id)
            local ok = d ~= nil and d.type == "MINION"
            if ok and fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits) then ok = false end
            if ok and fx.targetName ~= "" and not D.cardIsNamed(d, fx.targetName, fx.nameFamily) then ok = false end
            if ok and fx.keywordFilterBits ~= 0 then
                local have = d.keywords
                for _, x in ipairs(d.effects) do
                    if x.trigger == "DEATHRATTLE" then have = bor(have, KW.DEATHRATTLE) end
                end
                if band(have, fx.keywordFilterBits) ~= fx.keywordFilterBits then ok = false end
            end
            if ok and fx.costMin ~= 0 and d.cost < fx.costMin then ok = false end
            if ok and fx.costMax ~= 0 and d.cost > fx.costMax then ok = false end
            if ok and fx.excludeSource and own and d.id == own.id then ok = false end
            if ok and E.has_stat_bounds(fx) and not self:stats_admit(fx, d.attack, d.health, source) then ok = false end
            if ok then out[#out + 1] = id end
        end
    end
    return out
end

-- A made card goes to the hand, or burns when the hand is full; one in hand is what "it" names next.
local function intoHand(self, d, recipient)
    local id = self:create_entity(d, recipient, ZONE.HAND, -1)
    if #self:hand_ids(recipient) > 10 then
        self:relocate(id, ZONE.GRAVEYARD, -1)
    else
        self.drawn_this_effect[#self.drawn_this_effect + 1] = id
    end
    return id
end

OPS.ADD_TO_HAND = function(self, fx, target, source, controller)
    local s = self.state
    local recipient = fx.forOpponent and other(controller) or controller
    local me = self:player(recipient)
    -- "Add a copy of the last card your opponent played to your hand" (fromHistory): copies of the plays historyPick
    -- names.
    if fx.fromHistory ~= 0 then
        local plays = self:history_pool(fx, controller, source)
        local picks = {}
        if fx.historyPick == 1 then
            if #plays > 0 then picks[1] = plays[#plays] end
        elseif fx.historyPick >= 2 then
            picks = plays
        elseif #plays > 0 then
            picks[1] = plays[s.rng:intBelow(#plays) + 1]
        end
        for _, cid in ipairs(picks) do
            local d = def(cid)
            if d then intoHand(self, d, recipient) end
        end
        return
    end
    -- "Get a copy of the last friendly Deathrattle minion that died" (historyPick 1), "get copies of all friendly
    -- minions that died this turn" (historyPick 2): the graveyard's picks, not one at random.
    if fx.fromGraveyard and fx.historyPick ~= 0 then
        local deaths = self:graveyard_pool(fx, controller, source)
        if fx.historyPick == 1 and #deaths > 0 then deaths = { self:last_to_die(deaths, controller) } end
        for _, deadId in ipairs(deaths) do
            local d = self:def_of(deadId)
            if d then intoHand(self, d, recipient) end
        end
        return
    end
    local picked = fx.token
    local group = fx.tokens or EMPTY
    if picked == "" and #group > 0 then
        local valid = {}
        for _, token in ipairs(group) do
            if def(token) then valid[#valid + 1] = token end
        end
        if #valid == 0 then return end
        picked = valid[s.rng:intBelow(#valid) + 1]
    end
    if picked ~= "" then
        local d = def(picked)
        if not d then return end
        local id = self:create_entity(d, recipient, ZONE.HAND, -1)
        if d.numbered then
            local made = self:ent(id)
            if made then
                local counts = self:player(controller).numbered_made
                counts[d.id] = (counts[d.id] or 0) + 1
                made.number = counts[d.id]
            end
        end
        if #self:hand_ids(recipient) > 10 then
            self:relocate(id, ZONE.GRAVEYARD, -1)
        else
            self.drawn_this_effect[#self.drawn_this_effect + 1] = id
        end
        return
    end
    local pool = {}
    -- "Get a copy of a random friendly Deathrattle minion that died this game" (fromGraveyard): one entry per death.
    if fx.fromGraveyard then
        for _, id in ipairs(self:graveyard_pool(fx, controller, source)) do
            local d = self:def_of(id)
            if d then pool[#pool + 1] = d.id end
        end
    else
        local theirs = self:player(other(controller)).hero_class
        local myClass = self:player(controller).hero_class
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] then
                local ok
                if fx.familyFilter ~= 0 then
                    ok = cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.familyFilter,
                        fx.rarityFilter, fx.schoolFilter)
                        and not (fx.otherClass and (cand.familyNum == me.hero_class or cand.family == "NEUTRAL"))
                else
                    local excluded
                    if fx.classPool == 1 then
                        excluded = cand.familyNum ~= theirs
                    elseif fx.classPool == 2 then
                        excluded = cand.family == "NEUTRAL"
                    elseif fx.classPool == 3 then
                        excluded = cand.familyNum ~= me.hero_class
                    elseif fx.otherClass then
                        excluded = cand.familyNum == me.hero_class or cand.family == "NEUTRAL"
                    else
                        excluded = false
                    end
                    ok = not excluded and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits,
                        0, fx.rarityFilter, fx.schoolFilter)
                end
                if ok and keywordFilterOk(fx, cand)
                    -- "Add a random Combo card", "a random Secret" (traitFilter).
                    and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(cand, fx.traitFilterNum, myClass, 0))
                    -- "Get a random Protoss spell": a family (or a card's own name).
                    and not (fx.targetName ~= "" and not D.cardIsNamed(cand, fx.targetName, fx.nameFamily))
                    -- "A random minion with 5 or more Attack" (printed stats); "2 OTHER random Dragons".
                    and not (E.has_stat_bounds(fx) and not self:stats_admit(fx, cand.attack, cand.health, source))
                    and not (fx.excludeSource and self:same_card_as_source(cand.id, source)) then
                    pool[#pool + 1] = cid
                end
            end
        end
    end
    if #pool > 0 then
        local d = def(pool[s.rng:intBelow(#pool) + 1])
        if d then intoHand(self, d, recipient) end
    end
end

OPS.DISCOVER = function(self, fx, target, source, controller)
    local s = self.state
    local mine = self:player(controller).hero_class
    local pool = {}
    local group = fx.tokens or EMPTY
    if #group > 0 then
        for _, token in ipairs(group) do
            if def(token) then pool[#pool + 1] = token end
        end
    elseif fx.fromHistory ~= 0 then
        -- "Discover a copy of a card your opponent played this game": the plays, each card once.
        local seen = {}
        for _, cid in ipairs(self:history_pool(fx, controller, source)) do
            if not seen[cid] then
                seen[cid] = true
                pool[#pool + 1] = cid
            end
        end
    elseif fx.fromGraveyard then
        -- "Discover a friendly Beast that died this game": the dead minions, each card once.
        local seen = {}
        for _, id in ipairs(self:graveyard_pool(fx, controller, source)) do
            local d = self:def_of(id)
            if d and not seen[d.id] then
                seen[d.id] = true
                pool[#pool + 1] = d.id
            end
        end
    elseif fx.fromDeck or (fx.forOpponent and fx.fromHand) then
        -- "Discover a card from your deck"; "discover a copy of a card in your OPPONENT'S hand / deck" (forOpponent):
        -- their zone, and the pick is a copy (they keep theirs).
        local zoneOwner = fx.forOpponent and other(controller) or controller
        local seen = {}
        for _, id in ipairs(fx.fromHand and self:hand_ids(zoneOwner) or self:deck_ids(zoneOwner)) do
            local cand = self:def_of(id)
            local held = self:ent(id)
            if cand and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                fx.rarityFilter, fx.schoolFilter) and keywordFilterOk(fx, cand)
                and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(cand, fx.traitFilterNum, mine, 0))
                and not (fx.targetName ~= "" and not D.cardIsNamed(cand, fx.targetName, fx.nameFamily))
                and not (fx.discoverCast ~= 0 and cand.secret and self:secret_in_play(controller, cand.id))
                and not seen[cand.id]
                and not (held and not self:stats_admit(fx, held.attack, held.health, source))
                and not (fx.excludeSource and self:same_card_as_source(cand.id, source)) then
                seen[cand.id] = true
                pool[#pool + 1] = cand.id
            end
        end
    else
        local theirs = self:player(other(controller)).hero_class
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] then
                local excluded
                if fx.familyFilter ~= 0 then
                    excluded = cand.familyNum ~= fx.familyFilter - 1
                elseif fx.classPool == 1 then
                    excluded = cand.familyNum ~= theirs
                elseif fx.classPool == 2 then
                    excluded = cand.family == "NEUTRAL"
                elseif fx.classPool == 3 then
                    excluded = cand.familyNum ~= mine
                elseif fx.otherClass then
                    excluded = cand.familyNum == mine or cand.family == "NEUTRAL"
                else
                    excluded = cand.familyNum ~= mine and cand.family ~= "NEUTRAL"
                end
                if not excluded and not (fx.secretOnly and not cand.secret)
                    -- "Discover a Choose One card": a Battlecry that offers a choice is not one.
                    and not (fx.chooseOneOnly and (#cand.choices == 0 or band(cand.keywords, KW.BATTLECRY) ~= 0))
                    and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                        fx.rarityFilter, fx.schoolFilter)
                    and keywordFilterOk(fx, cand)
                    and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(cand, fx.traitFilterNum, mine, 0))
                    and not (fx.targetName ~= "" and not D.cardIsNamed(cand, fx.targetName, fx.nameFamily))
                    and not (fx.discoverCast ~= 0 and cand.secret and self:secret_in_play(controller, cand.id))
                    and not (E.has_stat_bounds(fx) and not self:stats_admit(fx, cand.attack, cand.health, source))
                    and not (fx.excludeSource and self:same_card_as_source(cand.id, source)) then
                    pool[#pool + 1] = cid
                end
            end
        end
    end
    if #pool == 0 then return end
    local wanted = fx.amount > 0 and fx.amount or 3
    local pend = s.pending
    pend.active = true
    pend.seat = controller
    pend.kind = "discover"
    pend.cost_delta = fx.discoverCostDelta
    pend.from_deck = fx.fromDeck
    -- The opponent's card is never moved: a Discover from their zone is a copy.
    pend.from_deck_copy = fx.fromDeck and (fx.discoverCopy or fx.forOpponent)
    pend.cast = fx.discoverCast ~= 0   -- "discover and cast a Secret"
    pend.options = {}
    pend.card_options = {}
    pend.temporary = fx.temporary
    pend.dark_gift = fx.darkGift
    pend.summon = fx.discoverSummon
    pend.others_to_hand = fx.discoverTakeAll and fx.discoverSummon
    pend.guess_copy = fx.discoverGuessCopy
    pend.chain = fx.discoverChain
    for _ = 1, wanted do
        if #pool == 0 then break end
        local picked = s.rng:intBelow(#pool) + 1
        pend.card_options[#pend.card_options + 1] = pool[picked]
        table.remove(pool, picked)
    end
    if fx.discoverTakeAll and not fx.discoverSummon then
        for _, option in ipairs(pend.card_options) do
            local d = def(option)
            if d then
                local made = self:create_entity(d, controller, ZONE.HAND, -1)
                if #self:hand_ids(controller) > 10 then self:relocate(made, ZONE.GRAVEYARD, -1) end
            end
        end
        pend.active = false
        pend.card_options = {}
    end
end

OPS.SUMMON_FROM_DECK = function(self, fx, target, source, controller)
    local s = self.state
    -- "Put a random minion from each player's hand into the battlefield": once for each seat.
    if fx.bothPlayers then
        local mine = D.copyEffect(fx)
        mine.bothPlayers = false
        mine.forOpponent = false
        self:apply_op(mine, target, source, controller)
        local theirs = D.copyEffect(mine)
        theirs.forOpponent = true
        self:apply_op(theirs, target, source, controller)
        return
    end
    -- "Your opponent summons a minion from their deck": their card, to their board.
    local deckOwner = fx.forOpponent and other(controller) or controller
    if fx.secretOnly then
        local p = self:player(controller)
        local secrets = {}
        for _, id in ipairs(self:deck_ids(controller)) do
            local d = self:def_of(id)
            if d and d.secret and #p.secrets < 5 and not self:secret_in_play(controller, d.id) then
                secrets[#secrets + 1] = id
            end
        end
        if #secrets == 0 then return end
        local picked = secrets[s.rng:intBelow(#secrets) + 1]
        self:relocate(picked, ZONE.SECRET, -1)
        s.entities[picked].play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        p.secrets[#p.secrets + 1] = picked
        return
    end
    local pool = {}
    -- "After you play a Pirate, summon THIS minion from your hand": an in-hand line on SELF picks the card itself.
    local heldSelf = self:ent(source)
    local selfFromHand = fx.fromHand and fx.inHand ~= 0 and fx.target.kind == "SELF"
    local candidates
    if selfFromHand then
        candidates = (heldSelf and heldSelf.zone == ZONE.HAND) and { source } or {}
    elseif fx.fromHand then
        candidates = self:hand_ids(deckOwner)
    else
        candidates = self:deck_ids(deckOwner)
    end
    for _, id in ipairs(candidates) do
        local cand = self:def_of(id)
        local held = self:ent(id)
        if cand and cand.type == "MINION" and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax,
            fx.raceFilterBits, 0, fx.rarityFilter, fx.schoolFilter) and keywordFilterOk(fx, cand)
            -- "A 1-Attack minion", "with less Attack than this minion", "a different Demon".
            and not (held and not self:stats_admit(fx, held.attack, held.health, source))
            and not (fx.excludeSource and not selfFromHand and self:same_card_as_source(cand.id, source))
            and not (held and not E.origin_matches(fx, held)) then
            pool[#pool + 1] = id
        end
    end
    local want = fx["repeat"] > 1 and fx["repeat"] or 1
    -- "Your opponent puts a minion from their deck into the battlefield": the right end of THEIR row.
    local pos = fx.forOpponent and -1 or self.summon_pos
    if not fx.forOpponent then self.summon_pos = pos < 0 and -1 or pos + want end
    for k = 0, want - 1 do
        if #pool == 0 then break end
        local picked = s.rng:intBelow(#pool) + 1
        local id = pool[picked]
        table.remove(pool, picked)
        local madeHere = self:summon_existing(id, deckOwner, pos < 0 and -1 or pos + k)
        if madeHere == 0 then break end
        self:after_summon_attack(madeHere, fx, self.summon_defender)
    end
end

OPS.SUMMON_RANDOM = function(self, fx, target, source, controller, src)
    local s = self.state
    local pool = {}
    local group = fx.tokens or EMPTY
    if #group > 0 then
        for _, token in ipairs(group) do
            if def(token) then pool[#pool + 1] = token end
        end
        if #pool == 0 then return end
        local chosen = pool[s.rng:intBelow(#pool) + 1]
        local at = self.summon_pos
        local madeHere = self:summon_token(chosen, controller, at, false)
        self.summon_pos = nextSummonPos(at)
        self:after_summon_attack(madeHere, fx, self.summon_defender)
        return
    end
    local costMin, costMax = fx.costMin, fx.costMax
    -- A read bound is an EXACT Cost, zero included.
    local exact, exactCost = false, 0
    -- "Summon a random minion with the same Cost" (a previous card's Cost, resolved in run_effect_list).
    if fx.resolvedCost >= 0 then
        exact, exactCost = true, fx.resolvedCost
    end
    if fx.valueSource ~= "NONE" and fx.valueSource ~= "" then
        local scaled = self:scaled_effect(fx, controller, source)
        costMin, costMax = scaled.costMin, scaled.costMax
        exact = costMin == costMax
        exactCost = costMin
    end
    for _, cid in ipairs(D.all()) do
        local cand = def(cid)
        if poolCard(cand) and cand.type == "MINION" and cand.health > 0
            and not (exact and cand.cost ~= exactCost)
            and cardMatches(cand, 0, exact and 0 or costMin, exact and 0 or costMax, fx.raceFilterBits, 0,
                fx.rarityFilter, 0, fx.zeroCost)
            and keywordFilterOk(fx, cand) then
            pool[#pool + 1] = cid
        end
    end
    if #pool == 0 then return end
    local chosen = pool[s.rng:intBelow(#pool) + 1]
    local pos = self.summon_pos
    self.summon_pos = nextSummonPos(pos)
    local created = self:summon_token(chosen, fx.forOpponent and other(controller) or controller, pos, false)
    if created ~= 0 and fx.keywordBits ~= 0 then
        self:apply_buff(created, 0, 0, fx.keywordBits, false, srcCard(src))
    end
    self:after_summon_attack(created, fx, self.summon_defender)
end

OPS.FORCE_ATTACK = function(self, fx, target, source, controller, src)
    if fx.amount2 >= 2 and fx.amount2 <= 7 then
        local function standing(id)
            local e = self:ent(id)
            return e ~= nil and not e.flags.dead and e.health > 0 and e.flags.dormant_turns == 0
                and (e.zone == ZONE.BOARD or e.zone == ZONE.HERO) and not self:is_location(id)
        end
        local t = self:ent(target)
        if fx.amount2 == 2 then
            -- "Force all enemy minions to attack this": each target attacks the source.
            if standing(target) and t.zone == ZONE.BOARD and standing(source) then self:forced_attack(target, source) end
        elseif fx.amount2 == 3 or fx.amount2 == 4 then
            -- "Enemy minions attack it" / "your minions attack it": every minion of that side, in order.
            local side = fx.amount2 == 3 and other(controller) or controller
            for _, attacker in ipairs(self:board_ids(side)) do
                if not standing(target) or self.aborted then break end
                if attacker ~= target and standing(attacker) then self:forced_attack(attacker, target) end
            end
        elseif fx.amount2 == 5 or fx.amount2 == 6 then
            -- "It attacks a random enemy minion"; "force a minion to attack one of its neighbors".
            if not standing(target) or t.zone ~= ZONE.BOARD then return end
            local pool = {}
            if fx.amount2 == 5 then
                for _, id in ipairs(self:board_ids(other(t.controller))) do
                    if standing(id) then pool[#pool + 1] = id end
                end
            else
                local row = self:board_ids(t.controller)
                for i, id in ipairs(row) do
                    if id == target then
                        if i > 1 and standing(row[i - 1]) then pool[#pool + 1] = row[i - 1] end
                        if i < #row and standing(row[i + 1]) then pool[#pool + 1] = row[i + 1] end
                    end
                end
            end
            if #pool > 0 then self:forced_attack(target, pool[self.state.rng:intBelow(#pool) + 1]) end
        elseif fx.amount2 == 7 then
            -- "Attack three different random enemies": one after another while this stands.
            local used = {}
            for _ = 1, max(1, fx.amount) do
                if not standing(source) or self.aborted then break end
                local pool = {}
                for _, id in ipairs(self:side_ids("ENEMY_CHARACTER", controller, source)) do
                    if standing(id) and not used[id] then pool[#pool + 1] = id end
                end
                if #pool == 0 then break end
                local pick = pool[self.state.rng:intBelow(#pool) + 1]
                used[pick] = true
                self:forced_attack(source, pick)
            end
        end
        return
    end
    if fx.amount2 == 1 then
        -- "Force each enemy minion to attack a random enemy minion": every minion of the side, in order, attacks
        -- another random living one of the same side.
        local side = (fx.target.side == "ENEMY_MINIONS" or fx.target.side == "ENEMY_MINION") and other(controller)
            or controller
        for _, attacker in ipairs(self:board_ids(side)) do
            local a = self:ent(attacker)
            if a and not a.flags.dead and a.health > 0 and not self:is_location(attacker) then
                local pool = {}
                for _, o in ipairs(self:board_ids(side)) do
                    local oe = self:ent(o)
                    if o ~= attacker and oe and not oe.flags.dead and oe.health > 0 and not self:is_location(o) then
                        pool[#pool + 1] = o
                    end
                end
                if #pool > 0 then
                    self:forced_attack(attacker, pool[self.state.rng:intBelow(#pool) + 1])
                end
            end
        end
        return
    end
    -- The source attacks the target out of turn. A source that took lethal damage on an earlier target stops, and the
    -- target must still stand.
    local tt = self:ent(target)
    if src and src.zone == ZONE.BOARD and src.health > 0 and not src.flags.dead and tt and not tt.flags.dead
        and tt.health > 0 and (tt.zone == ZONE.BOARD or tt.zone == ZONE.HERO) then
        self:forced_attack(src.id, target)
    end
end

OPS.DESTROY = function(self, fx, target)
    local t = self:ent(target)
    if t and t.zone == ZONE.DECK then
        self:relocate(target, ZONE.GRAVEYARD, -1)
        return
    end
    self:mark_dead(target)
end

OPS.EQUIP = function(self, fx, target, source, controller)
    self:equip_weapon(fx.token, controller)
    -- "Each player equips a 2/2 Knife with Poisonous".
    if fx.bothPlayers then self:equip_weapon(fx.token, other(controller)) end
end

OPS.DISCARD = function(self, fx, target, source, controller)
    local t = self:ent(target)
    -- The card's owner discards it ("your opponent discards a spell" counts and answers for them).
    if t and t.zone == ZONE.HAND then self:discard_card(t.id, t.owner) end
end

OPS.GIVE_KEYWORD = function(self, fx, target, source, controller, src)
    -- "Give a minion Spell Damage +1", "Gain Spell Damage +2 this turn": a VALUED keyword, the amount riding in the
    -- buff. A spell or weapon that "gains" it gives it to its hero, whose Spell Damage counts too.
    local valued = band(fx.keywordBits, KW.SPELL_DAMAGE) ~= 0 and max(0, fx.amount) or 0
    local to = target
    if valued > 0 then
        local t = self:ent(target)
        if t and t.zone ~= ZONE.BOARD and t.zone ~= ZONE.HERO and t.zone ~= ZONE.HAND and t.zone ~= ZONE.DECK then
            -- Only the spell or weapon that "gains" it gives it to its hero.
            if target ~= source and t.zone ~= ZONE.WEAPON then return end
            to = self:player(controller).hero_id
        end
    end
    self:apply_buff(to, 0, 0, fx.keywordBits, fx.temporary, srcCard(src), fx.durationTurns, valued)
end

OPS.SET_STATS = function(self, fx, target)
    local t = self:ent(target)
    if not t then return end
    t.attack = fx.amount
    t.max_health = fx.amount2
    t.health = fx.amount2
    self:forget_buff_stats(t, true, true)
end

OPS.COPY = function(self, fx, target, source, controller)
    local t = self:ent(target)
    local d = t and self:def_of(t.id)
    if not d then return end
    local id = self:create_entity(d, controller, ZONE.HAND, -1)
    self.copied_this_effect[#self.copied_this_effect + 1] = id
    if #self:hand_ids(controller) > 10 then
        self:relocate(id, ZONE.GRAVEYARD, -1)
        return
    end
    local made = self:ent(id)
    if made then
        if t.zone == ZONE.HAND then
            made.attack, made.health, made.max_health = t.attack, t.health, t.max_health
            made.keywords, made.cost_delta = t.keywords, t.cost_delta
            -- "It costs (0)" and this turn's price are enchantments the copy keeps.
            made.cost_override, made.cost_override_this_turn = t.cost_override, t.cost_override_this_turn
            made.temp_cost_delta = t.temp_cost_delta
        end
        if fx.amount > 0 or fx.amount2 > 0 then
            made.attack, made.health, made.max_health = fx.amount, fx.amount2, fx.amount2
        end
        if fx.costOverride >= 0 then made.cost_override = fx.costOverride end
    end
end

OPS.RETURN_TO_HAND = function(self, fx, target, source, controller)
    local t = self:ent(target)
    if not t then return end
    local d = self:def_of(t.id)
    if not (t.zone == ZONE.BOARD or (t.zone == ZONE.GRAVEYARD and d and d.type == "MINION")) then return end
    local owner = fx.toOwnHand and controller or t.owner
    if fx.toOwnHand then
        t.owner, t.controller = controller, controller
    end
    if #self:hand_ids(owner) >= 10 then
        self:relocate(t.id, ZONE.GRAVEYARD, -1)
    else
        self:relocate(t.id, ZONE.HAND, -1)
    end
end

OPS.BUFF_ZONE = function(self, fx, target, source, controller, src)
    local pool = {}
    local function collect(ids)
        for _, id in ipairs(ids) do
            local d = self:def_of(id)
            if d and (fx.type_filter == 0 or d.typeNum == fx.type_filter - 1)
                and (fx.raceFilterBits == 0 or hasRace(d.races, fx.raceFilterBits)) and keywordFilterOk(fx, d)
                and not (fx.excludeSource and id == source) then
                pool[#pool + 1] = id
            end
        end
    end
    if fx.buffHand then collect(self:hand_ids(controller)) end
    if fx.buffDeck then collect(self:deck_ids(controller)) end
    if fx.buffBoard then collect(self:board_ids(controller)) end
    if #pool == 0 then return end
    if fx.buffRandom then
        pool = self:narrow_by_cost(pool, fx.pickCostNum)
        local picked = pool[self.state.rng:intBelow(#pool) + 1]
        self:apply_buff(picked, fx.amount, fx.amount2, 0, false, srcCard(src))
        self.buffed_this_effect[#self.buffed_this_effect + 1] = picked
    else
        for _, id in ipairs(pool) do
            self:apply_buff(id, fx.amount, fx.amount2, 0, false, srcCard(src))
        end
    end
end

OPS.DREDGE = function(self, fx, target, source, controller)
    local s = self.state
    local deck = self:deck_ids(controller)
    if #deck == 0 then return end
    -- deck_ids is already in zone_pos order (ties by id), which std::sort by zone_pos keeps for distinct slots.
    local options = {}
    for i = #deck, 1, -1 do
        if #options >= 3 then break end
        options[#options + 1] = deck[i]
    end
    local pend = s.pending
    pend.active = true
    pend.seat = controller
    pend.kind = "dredge"
    pend.options = options
    pend.card_options = {}
end

OPS.CARD_COST = function(self, fx, target, source, controller)
    local s = self.state
    -- "It costs (1) less", "reduce the Cost of the right-most card in your hand by (2)": the cards the effect's own
    -- target names (the ends of the hand) are priced one by one, like the previous clause's. "Costs (1) less whenever
    -- ...": an in-hand line prices the card itself.
    local kind = fx.target.kind
    local selfPriced = kind == "SELF" and fx.inHand ~= 0
    local named = kind == "PREVIOUS" or kind == "LEFTMOST" or kind == "RIGHTMOST" or kind == "EDGES" or selfPriced
    local priced = selfPriced and source or target
    if named and priced ~= 0 then
        local card = self:ent(priced)
        if card then
            if fx.amount2 == 8 then
                card.cost_override = fx.amount
                card.cost_override_this_turn = fx.temporary
            elseif fx.amount2 == 11 then
                card.pays_with = 1
                card.pays_with_this_turn = fx.temporary
            elseif fx.amount2 == 12 then
                card.pays_with = 2
            elseif fx.temporary then
                card.temp_cost_delta = card.temp_cost_delta + fx.amount
            elseif fx.amount2 == 5 and fx.amount < 0 then
                local now = self:card_cost(card.owner, card.id)
                card.cost_delta = card.cost_delta + max(fx.amount, min(0, 1 - now))
            elseif fx.costCap > 0 and fx.amount > 0 then
                -- "It costs (1) more (up to 10)": the increase stops at the cap.
                local now = self:card_cost(card.owner, card.id)
                card.cost_delta = card.cost_delta + max(0, min(fx.amount, fx.costCap - now))
            else
                card.cost_delta = card.cost_delta + fx.amount
            end
        end
        return
    end
    local seat = fx.target.side == "ENEMY_HERO" and other(controller) or controller
    local p = self:player(seat)
    if fx.amount2 == 0 then
        p.next_card_cost_this_turn = fx.temporary
        -- "The next Secret you play costs (0)": `setVerb` makes the number an absolute Cost.
        if fx.setVerb then
            p.next_card_cost_set = max(0, fx.amount)
        else
            p.next_card_cost_delta = p.next_card_cost_delta + fx.amount
            -- "(up to 10)": an increase stops at the cap.
            if fx.amount > 0 then p.next_card_cost_cap = fx.costCap end
        end
        p.next_card_cost_filter = fx.type_filter
        p.next_card_cost_school = fx.schoolFilter
        p.next_card_cost_race = fx.raceFilterBits
        p.next_card_cost_keyword = fx.keywordFilterBits
        p.next_card_cost_secret = fx.secretOnly
        p.next_card_cost_trait = fx.traitFilterNum
        p.next_card_cost_name = fx.targetName
        p.next_card_cost_name_family = fx.nameFamily
    elseif fx.amount2 == 5 then
        p.next_turn_cost_delta = fx.amount
        p.next_turn_cost_filter = fx.type_filter
        p.next_turn_cost_floor = true
    elseif fx.amount2 == 7 then
        p.pending_turn_cost_delta = fx.amount
        p.pending_turn_cost_filter = fx.type_filter
    elseif fx.amount2 == 9 or fx.amount2 == 10 then
        p.next_pays_with = fx.amount2 == 9 and 1 or 2
        p.next_pays_with_count = seat ~= controller and 99 or (fx.amount > 0 and fx.amount or 1)
        p.next_pays_with_type = fx.type_filter
    elseif fx.amount2 == 4 then
        -- "Minions in your OPPONENT's hand" (ENEMY_HAND_MINIONS) is their hand, minions only.
        local theirs = fx.target.side == "ENEMY_HAND" or fx.target.side == "ENEMY_HAND_MINIONS"
        local matches = {}
        for _, id in ipairs(self:hand_ids(theirs and other(controller) or seat)) do
            local d = self:def_of(id)
            local e = self:ent(id)
            if d and E.costFilterMatches(fx.type_filter, d)
                and not (fx.target.side == "ENEMY_HAND_MINIONS" and d.type ~= "MINION")
                and not (fx.schoolFilter ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.schoolFilter))
                and keywordFilterOk(fx, d)
                and not (fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits))
                and not (fx.excludeRaceBits ~= 0 and hasRace(d.races, fx.excludeRaceBits))
                and not (fx.otherClass and (d.familyNum == p.hero_class or d.family == "NEUTRAL"))
                -- "Reduce the Cost of Combo cards in your hand", "... the cards that didn't start in your deck".
                and not (fx.traitFilterNum ~= 0 and not E.card_has_trait(d, fx.traitFilterNum, p.hero_class, e.keywords))
                and E.origin_matches(fx, e) then
                matches[#matches + 1] = id
            end
        end
        if fx.oneInHand and #matches > 0 then
            matches = self:narrow_by_cost(matches, fx.pickCostNum)   -- "the highest Cost spell in your hand"
            matches = { matches[s.rng:intBelow(#matches) + 1] }
        end
        for _, id in ipairs(matches) do
            s.entities[id].cost_delta = s.entities[id].cost_delta + fx.amount
        end
    end
end

OPS.HERO_POWER_COST = function(self, fx, target, source, controller)
    local seat = fx.target.side == "ENEMY_HERO" and other(controller) or controller
    local p = self:player(seat)
    if 2 + p.hero_power_cost_once + fx.amount <= 0 then
        p.hero_power_free_once = true
    else
        p.hero_power_cost_once = p.hero_power_cost_once + fx.amount
    end
    p.hero_power_once_this_turn = p.hero_power_once_this_turn or fx.temporary
end

OPS.SILENCE = function(self, fx, target)
    local t = self:ent(target)
    if not t or (t.zone ~= ZONE.BOARD and t.zone ~= ZONE.HERO) then return end
    for _, b in ipairs(t.buffs) do
        t.attack = t.attack - b.attack
        t.max_health = t.max_health - b.health
    end
    t.buffs = {}
    t.granted = {}
    t.magnetized = {}
    t.keywords = 0
    t.spell_damage = 0
    t.health = min(t.health, t.max_health)
    t.flags.divine_shield = false
    t.flags.stealth = false
    t.flags.frozen = false
    t.flags.immune = false
    t.flags.silenced = true
end

E.OPS = OPS
