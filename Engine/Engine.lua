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
-- The rules engine core: a port of the reference engine's tc/engine.cpp (TcEngine), state, zones, entities,
-- buffs, auras, damage, turns, the resolution loop, deaths and draws.
--
-- Parity is the contract. The same seed and the same move indices must give the same state as the reference
-- engine, step by step (tests/test_parity.lua replays recorded matches and diffs every field), so
-- the code follows the reference statement for statement, including its order of RNG draws and its quirks.
-- Reference comments that explain a rule are kept short here; the reference source is the reference.
--
-- Seats are 0 (A) and 1 (B); `state.players[seat + 1]`. Entities live in `state.entities[id]`, ids are
-- never reused or removed, and "every entity in id order" is `for id = 1, state.next_entity_id - 1`.
--
-- Headless: no WoW API here (tools/lint_engine.py).

local TC = TavernCards_NS
local D = TC.EngineDefs
local Rng = TC.Rng
local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local floor, min, max = math.floor, math.min, math.max
local ZONE, PHASE, RESULT, REASON, KW, RACE = D.ZONE, D.PHASE, D.RESULT, D.REASON, D.KW, D.RACE
local def = D.def
local hasRace = D.hasRace

local E = {}
E.__index = E
TC.Engine = E

local function other(seat)
    return 1 - seat
end
E.other = other

local function u32(x)
    return x % 4294967296
end

-- ---- state construction ------------------------------------------------------------------------

local function newFlags()
    return {
        exhausted = false, attacks_this_turn = 0, frozen = false, silenced = false, divine_shield = false,
        stealth = false, dead = false, just_played_turn = -1, hero_power_used = false, has_attacked = false,
        cant_attack_heroes_this_turn = false, reborn_used = false, dormant_turns = 0, immune = false,
        spellburst_used = false, frenzy_used = false, corrupted = false, infuse_progress = 0, forged = false,
        prepared = false, prepared_turn = -1, drawn_this_turn = false, created_by_effect = false,
        twin_copy = false, charge_ready = false,
    }
end
E.newFlags = newFlags

local function newEntity()
    return {
        id = 0, card_id = "", owner = 0, controller = 0, zone = ZONE.DECK, zone_pos = 0, play_order = 0,
        attack = 0, health = 0, max_health = 0, armor = 0, durability = 0, drawn_from = "", keywords = 0,
        bonus_effect_bits = 0, spell_damage = 0, cost_delta = 0, temp_cost_delta = 0, made_minion = 0,
        cost_override = -1, cost_override_this_turn = false, pays_with = 0, pays_with_this_turn = false,
        titan_used = 0, held_spells_cast = 0, held_school_mask = 0, number = 0, turns_left = 0, stuffed = {},
        buffs = {}, granted = {}, magnetized = {}, flags = newFlags(), temp_card = false,
        -- run waves 2026-11-10..19: what `remember` lines took, "while holding this" counters, Echo copies, the
        -- price paid, the turn it died
        remembered = {}, held_minions_played = 0, held_race_mask = 0, held_higher_cost = false, echo_copy = false,
        paid_price = -1, died_turn = 0,
    }
end

local function newPlayer(seat)
    local race_played = {}
    for i = 1, 32 do race_played[i] = 0 end
    return {
        seat = seat, hero_id = 0, hero_power_id = 0, weapon_id = 0, max_mana = 0, mana = 0, temp_mana = 0,
        overload_locked = 0, overload_next = 0, fatigue = 0, cards_played_this_turn = 0, game_cards_played = 0,
        game_minions_summoned = 0, game_spells_cast = 0, spells_cast_this_turn = 0, game_cards_drawn = 0,
        restored_health_this_turn = false, heal_as_damage_this_turn = false, heal_as_damage_next = 0,
        hero_health_changed_this_turn = false, armor_changed_this_turn = false, armor_gained_this_turn = 0,
        hero_attack_gained_this_turn = 0, friendly_deaths_by_tribe = 0, cast_spell_this_turn = false,
        cast_spell_last_turn = false, schools_cast_this_turn = 0, spell_schools_game = { 0, 0, 0, 0, 0, 0, 0, 0 },
        game_hero_power_uses = 0, game_minions_died = 0, game_armor_gained = 0, game_health_restored = 0,
        game_hero_power_damage = 0, game_mana_overloaded = 0, excavate_count = 0, excavates_this_game = 0,
        jade_count = 0, herald_count = 0, starship_attack = 0, starship_health = 0, starship_keywords = 0,
        starship_building = false, game_starships_launched = 0, numbered_made = {},
        elementals_played_this_turn = 0, elementals_played_last_turn = 0, game_spells_cost_5_plus = 0,
        game_relics_played = 0, game_hero_attacks = 0, elemental_streak = 0, game_cards_discarded = 0,
        last_destroyed_cards = {}, game_cards_played_not_from_deck = 0, game_weapons_equipped = 0,
        game_secrets_played = 0, game_secrets_triggered = 0, corpses = 0, game_race_played = race_played,
        minions_died_this_turn = 0, friendly_minions_died_this_turn = 0, cards_drawn_this_turn = 0,
        hero_power_uses = 0, hero_power_cost_once = 0, hero_power_damage_once = 0, next_card_cost_this_turn = false,
        hero_power_once_this_turn = false, hero_power_free_once = false, next_card_cost_delta = 0,
        next_card_cost_filter = 0, next_pays_with = 0, next_pays_with_count = 0, next_pays_with_type = 0,
        next_card_cost_school = 0, next_card_cost_race = 0, next_card_cost_keyword = 0, next_turn_cost_delta = 0,
        next_turn_cost_filter = 0, next_turn_cost_floor = false, pending_turn_cost_delta = 0,
        pending_turn_cost_filter = 0, chain_card = "", chain_options = {}, delayed_effects = {},
        minions_double_damage_this_turn = false, secrets = {}, play_tribes_this_turn = 0, play_tribes_last_turn = 0,
        play_schools_this_turn = 0, play_schools_last_turn = 0, started_no_duplicates = false,
        hero_took_damage_this_turn = false, hero_damage_taken_this_turn = 0, combo_cards_played_this_turn = 0,
        hero_class = D.FAMILY.NEUTRAL,
        -- run waves 2026-11-10..19 (PlayerState): the play history ({card, paid, turn, target_side} rows), delays
        -- "in N turns" ({card, index, turns}), casts twice, next-card costs, Invoke, Imbue, quests.
        played_history = {}, delayed_later = {}, twice_spells = 0, twice_spells_turn = 0, twice_battlecries_turn = 0,
        next_card_cost_cap = 0, next_card_cost_set = -1, next_card_cost_secret = false, next_card_cost_trait = 0,
        next_card_cost_name = "", next_card_cost_name_family = false, chain_source = 0, game_invokes = 0,
        imbue_count = 0, quests = {}, game_quests_played = 0, quests_completed = 0, hero_power_card = "",
        hero_power_entity = 0,
    }
end

local function newPending()
    return {
        active = false, seat = 0, options = {}, card_options = {}, kind = "", dark_gift = false, summon = false,
        others_to_hand = false, guess_copy = false, chain = false, cost_delta = 0, temporary = false,
        resume = false, source = 0, trigger = "ON_PLAY", effect_index = -1, event_subject = 0, chosen = -1,
        previous_targets = {}, from_deck = false, ability = -1, then_on_play = false, resume_same = false,
        targets = {}, from_deck_copy = false, cast = false, outcast = false, rerun = 0, chain_source = 0,
    }
end
E.newPending = newPending

local function newState()
    return {
        v = 0, rules_version = TC.RULES_VERSION, catalogue_build = "unpinned", phase = PHASE.MULLIGAN, turn = 0,
        active = 0, players = { newPlayer(0), newPlayer(1) }, persistent = {}, entities = {},
        next_entity_id = 1, next_play_order = 1, rng = Rng.new(0), pending = newPending(),
        result = { result = RESULT.ONGOING, reason = REASON.NONE, winner = 0 },
        mulligan_answered = { false, false }, loop_steps = 0,
        -- "at the end of the turn" rows ({seat, card, index, source}) and the serial persistent rows are numbered by
        next_row_serial = 1, end_of_turn = {},
    }
end

-- Deep copy of plain data; the RNG is copied through its own save/restore.
local function deepCopy(v)
    if type(v) ~= "table" then
        return v
    end
    if getmetatable(v) == Rng then
        return Rng.restore(v:saveState())
    end
    local out = {}
    for k, x in pairs(v) do
        out[k] = deepCopy(x)
    end
    return out
end
E.deepCopy = deepCopy

local function newEngine()
    local self = setmetatable({}, E)
    self.state = newState()
    self:resetTransient()
    self.events = {}
    return self
end

-- The reference engine's per-action members (everything that is not MatchState).
function E:resetTransient()
    self.aborted = false
    self.summon_pos = -1
    self.dying_pos = -1
    self.last_drawn = 0
    self.last_summoned = 0
    self.drawn_this_effect = {}
    self.summoned_this_effect = {}
    self.copied_this_effect = {}
    self.buffed_this_effect = {}
    self.attacking_weapon = 0
    self.attacking_now = 0
    self.running_ability = -1
    self.fatigue_kill = { false, false }
    self.pending_attack = 0
    self.pending_attack_target = 0
    self.pending_events = {}
    self.pending_self_events = {}
    self.effect_source = 0
    self.beside_count = {}
    self.far_right_summons = false
    self.titan_last = 0
    self.titan_last_index = -1
    self.last_effect_count = self.last_effect_count or 0
    self.last_excess = self.last_excess or 0
    self.event_amount = 0
    self.kill_victim = 0
    self.kill_victims = {}
    self.removing_dead = false
    self.redirecting_damage = false
    self.hero_power_resolving = false
    self.play_was_outcast = false
    self.play_spent_last_mana = false
    self.effect_index = 0
    self.last_error = ""
    self.summon_chain = {}
    self.event_summon_chain = nil
    self.casting_spell = 0
    self.armor_reacting = false
    self.hero_answer_depth = 0
    self.lethal_damage = {}           -- {id, damage past 0} rows (answer_hero_damage)
    self.effect_controller = -1
    self.permanent_buff = false
    self.discarded_this_effect = {}
    self.last_blow = -1
    self.effect_lifesteal = false
    self.effect_lists = 0
    self.event_listeners = nil
    self.event_active_at = -1
    -- draw_card's filters for the draw in progress (DRAW sets them, draw_replacement parks them)
    self.draw_from_bottom = false
    self.draw_secret_only = false
    self.draw_trait = 0
    self.draw_pick_cost = 0
    self.draw_fx = nil
    self.draw_source = 0
    self.draw_distinct = 0
    self.draw_used_races = 0
    self.draw_used_cards = {}
    self.draw_used_costs = {}
    self.start_of_game_running = false
    self.shuffled_this_effect = {}
    self.adapt_group = {}
    self.summon_defender = 0
    self.random_cast = 0       -- inside a random cast: every choice it opens is made at random
    self.replay_depth = 0      -- inside a history cast: another history cast does nothing
    self.replay_lines = nil    -- run_random_battlecry's lines, where a choice they open resumes
    self.replay_source = 0
    self.replay_card = nil
    self.replay_index = nil
    self.last_paid_entity = 0
    self.power_triggered = false
    self.broken_weapon = 0          -- resolve_attack: the hero's weapon the swing broke (fire_attack_triggers)
    self.stealth_attackers = {}     -- attackers whose Stealth this action's attacks removed
    self.friendly_attack_fired = 0
    self.last_paid_price = -1
    self.play_edge = 0              -- apply_play: 1 leftmost, 2 rightmost (bits) as the card left the hand
    self.play_edge_id = 0
    self.doubled_cast = 0
    self.hand_scan_source = 0  -- fire_events: the in-hand card whose listening lines are being run
end

-- ---- construction (TcEngine::create / build_match) ---------------------------------------------

local function deckOk(deck)
    if #deck ~= 30 then
        return false
    end
    local counts = {}
    for _, id in ipairs(deck) do
        local card = def(id)
        if not card or not card.collectible or not card.implemented then
            return false
        end
        local limit = card.rarity == "LEGENDARY" and 1 or 2
        counts[id] = (counts[id] or 0) + 1
        if counts[id] > limit then
            return false
        end
    end
    return true
end

local function noDuplicates(deck)
    local counts = {}
    for _, id in ipairs(deck) do
        counts[id] = (counts[id] or 0) + 1
        if counts[id] > 1 then
            return false
        end
    end
    return true
end

-- seed: a number below 2^53, or {hi, lo}. Returns nil when a deck is illegal.
function E.create(deckA, deckB, seed)
    if not deckOk(deckA) or not deckOk(deckB) then
        return nil
    end
    local self = newEngine()
    local s = self.state
    local a, b = {}, {}
    for i, id in ipairs(deckA) do a[i] = id end
    for i, id in ipairs(deckB) do b[i] = id end
    local aClean, bClean = noDuplicates(a), noDuplicates(b)
    if type(seed) == "table" then
        s.rng = Rng.new(seed[1], seed[2])
    else
        s.rng = Rng.new(seed)
    end
    s.rng:shuffle(a) -- SPEC 7.9: A, then B, then the first seat.
    s.rng:shuffle(b)
    local first = s.rng:intBelow(2) == 0 and 0 or 1
    s.active = first
    s.phase = PHASE.MULLIGAN

    for seat = 0, 1 do
        local hero = newEntity()
        hero.id = s.next_entity_id
        s.next_entity_id = s.next_entity_id + 1
        hero.card_id = seat == 0 and "HERO_A" or "HERO_B"
        hero.owner, hero.controller = seat, seat
        hero.zone = ZONE.HERO
        hero.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        hero.health, hero.max_health = 30, 30
        s.entities[hero.id] = hero
        local p = s.players[seat + 1]
        p.seat = seat
        p.hero_id = hero.id
        p.hero_power_id = 0
    end
    for seat = 0, 1 do
        local deck = seat == 0 and a or b
        for i, id in ipairs(deck) do
            local dealt = self:create_entity(def(id), seat, ZONE.DECK, i - 1)
            -- A card dealt in the starting deck did start there: create_entity marks every card it makes as made by an
            -- effect, and "cards that didn't start in your deck" (and the not-from-deck counts) took every card.
            local d = self:ent(dealt)
            if d then d.flags.created_by_effect = false end
        end
    end
    for seat = 0, 1 do
        local count = seat == first and 3 or 4 -- SPEC 8.2: first 3, second 4 + Coin
        for _ = 1, count do
            local deck = self:deck_ids(seat)
            if #deck == 0 then break end
            self:relocate(deck[1], ZONE.HAND, -1)
        end
        if seat ~= first then
            local coin = def(D.COIN_ID)
            if coin then
                self:create_entity(coin, seat, ZONE.HAND, -1)
            end
        end
        s.players[seat + 1].started_no_duplicates = seat == 0 and aClean or bClean
    end
    return self
end

-- hero_power_for(Family)
local HERO_POWER = { WARRIOR = 1, PALADIN = 2, HUNTER = 3, ROGUE = 4, PRIEST = 5, DEATHKNIGHT = 6, SHAMAN = 7,
    MAGE = 8, WARLOCK = 9, DRUID = 11, DEMONHUNTER = 4 }
function E.heroPowerFor(family)
    return HERO_POWER[family] or 8
end

function E:set_class(seat, family)
    self.state.players[seat + 1].hero_class = D.FAMILY[family] or D.FAMILY.NEUTRAL
end

function E:set_hero_power(seat, power)
    self.state.players[seat + 1].hero_power_id = power
end

-- ---- lookup / zones ----------------------------------------------------------------------------

function E:ent(id)
    return self.state.entities[id]
end

function E:def_of(id)
    local e = self.state.entities[id]
    return e and def(e.card_id) or nil
end

function E:hero_of(seat)
    return self.state.entities[self.state.players[seat + 1].hero_id]
end

function E:player(seat)
    return self.state.players[seat + 1]
end

-- Ids of one seat's zone, by (zone_pos, id): exactly zone_ids.
function E:zone_ids(seat, zone)
    local s = self.state
    local tmp = {}
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e and e.zone == zone and e.owner == seat then
            tmp[#tmp + 1] = e
        end
    end
    table.sort(tmp, function(x, y)
        if x.zone_pos ~= y.zone_pos then return x.zone_pos < y.zone_pos end
        return x.id < y.id
    end)
    local out = {}
    for i = 1, #tmp do out[i] = tmp[i].id end
    return out
end

function E:board_ids(seat) return self:zone_ids(seat, ZONE.BOARD) end
function E:hand_ids(seat) return self:zone_ids(seat, ZONE.HAND) end
function E:deck_ids(seat) return self:zone_ids(seat, ZONE.DECK) end
function E:board_size(seat) return #self:zone_ids(seat, ZONE.BOARD) end

function E:mulligan_ids(seat)
    local out = {}
    for _, id in ipairs(self:hand_ids(seat)) do
        local e = self:ent(id)
        if e and e.card_id ~= D.COIN_ID then
            out[#out + 1] = id
        end
    end
    return out
end

-- A card that leaves play for hand or deck is the printed card again.
function E:reset_to_card(e)
    local d = def(e.card_id)
    if not d then return end
    -- "With permanent +3/+3": the card's own buffs go with it (Buff.permanent).
    local keptBuffs = {}
    for _, b in ipairs(e.buffs) do
        if b.permanent then keptBuffs[#keptBuffs + 1] = b end
    end
    e.controller = e.owner
    e.attack = d.attack
    e.max_health = d.health
    e.health = d.health
    e.armor = 0
    e.durability = d.durability
    e.keywords = d.keywords
    e.spell_damage = d.spell_damage
    e.cost_delta = 0
    e.temp_cost_delta = 0
    e.made_minion = 0
    e.remembered = {}
    e.cost_override = -1
    e.bonus_effect_bits = 0
    e.titan_used = 0
    if #d.titan_abilities > 0 then
        e.number = 1
    end
    e.buffs = {}
    e.granted = {}
    e.magnetized = {}
    local kept = e.flags
    e.flags = newFlags()
    e.flags.created_by_effect = kept.created_by_effect
    e.flags.twin_copy = kept.twin_copy
    e.flags.corrupted = kept.corrupted
    e.flags.forged = kept.forged
    e.flags.divine_shield = band(d.keywords, KW.DIVINE_SHIELD) ~= 0
    e.flags.stealth = band(d.keywords, KW.STEALTH) ~= 0
    for _, b in ipairs(keptBuffs) do
        e.attack = e.attack + b.attack
        e.max_health = e.max_health + b.health
        e.health = e.health + b.health
        e.keywords = bor(e.keywords, b.keyword)
        e.spell_damage = e.spell_damage + (b.spell_damage or 0)
        e.buffs[#e.buffs + 1] = b
    end
end

-- "... with permanent +3/+3": a copy of a card takes the card's permanent buffs along (carry_permanent_buffs).
function E:carry_permanent_buffs(from, to)
    local original, made = self:ent(from), self:ent(to)
    if not original or not made or original == made then return end
    local buffs = {}
    for i, b in ipairs(original.buffs) do buffs[i] = b end
    for _, b in ipairs(buffs) do
        if b.permanent then
            made.attack = made.attack + b.attack
            made.max_health = made.max_health + b.health
            made.health = made.health + b.health
            made.keywords = bor(made.keywords, b.keyword)
            made.spell_damage = made.spell_damage + (b.spell_damage or 0)
            local copy = {}
            for k, v in pairs(b) do copy[k] = v end
            made.buffs[#made.buffs + 1] = copy
        end
    end
end

function E:compact_board(seat)
    local row = self:board_ids(seat)
    for i, id in ipairs(row) do
        self.state.entities[id].zone_pos = i - 1
    end
end

function E:relocate(id, zone, pos)
    local s = self.state
    local e = s.entities[id]
    if not e then return end
    local from = e.zone
    local leavesPlay = from == ZONE.BOARD or from == ZONE.GRAVEYARD or from == ZONE.WEAPON or from == ZONE.SECRET
    if leavesPlay and (zone == ZONE.HAND or zone == ZONE.DECK) then
        self:reset_to_card(e)
    end
    local seat = e.owner
    local tmp = {}
    for oid = 1, s.next_entity_id - 1 do
        local o = s.entities[oid]
        if oid ~= id and o and o.zone == zone and o.owner == seat then
            tmp[#tmp + 1] = o
        end
    end
    table.sort(tmp, function(x, y)
        if x.zone_pos ~= y.zone_pos then return x.zone_pos < y.zone_pos end
        return x.id < y.id
    end)
    if pos < 0 or pos > #tmp then
        pos = #tmp
    end
    table.insert(tmp, pos + 1, e)
    e.zone = zone
    for i, o in ipairs(tmp) do
        o.zone_pos = i - 1
    end
    if from == ZONE.BOARD and not self.removing_dead then
        self:compact_board(0)
        self:compact_board(1)
    end
    if zone == ZONE.HAND and e.bonus_effect_bits == 0 then
        self:roll_bonus_effects(id)
    end
end

local BONUS_EFFECT_KEYWORDS = { [0] = KW.TAUNT, KW.WINDFURY, KW.DIVINE_SHIELD, KW.POISONOUS, KW.ELUSIVE, KW.RUSH,
    KW.LIFESTEAL, KW.REBORN }
E.BONUS_EFFECT_KEYWORDS = BONUS_EFFECT_KEYWORDS

function E:roll_bonus_effects(id)
    local e = self:ent(id)
    if not e then return end
    local d = self:def_of(id)
    if not d or d.bonus_effects <= 0 then return end
    e.keywords = band(e.keywords, bnot(e.bonus_effect_bits))
    e.bonus_effect_bits = 0
    for _ = 1, d.bonus_effects do
        local pick = 0
        for _ = 1, 32 do
            local b = BONUS_EFFECT_KEYWORDS[self.state.rng:intBelow(8)]
            if band(e.bonus_effect_bits, b) == 0 then
                pick = b
                break
            end
        end
        if pick == 0 then break end
        e.bonus_effect_bits = bor(e.bonus_effect_bits, pick)
    end
    e.keywords = bor(e.keywords, e.bonus_effect_bits)
end

local function anyDeathrattle(d)
    if d then
        for _, fx in ipairs(d.effects) do
            if fx.trigger == "DEATHRATTLE" then return true end
        end
    end
    return false
end

function E:has_deathrattle(id)
    local e = self:ent(id)
    if not e then return false end
    -- A Silenced minion has only what was granted after the Silence (Silence clears the grants it finds).
    if e.flags.silenced then
        for _, g in ipairs(e.granted) do
            for _, follow in ipairs(self:granted_lines(g)) do
                if follow.trigger == "DEATHRATTLE" then return true end
            end
        end
        return false
    end
    if anyDeathrattle(self:def_of(id)) then return true end
    for _, cid in ipairs(e.magnetized) do
        if anyDeathrattle(def(cid)) then return true end
    end
    for _, g in ipairs(e.granted) do
        for _, follow in ipairs(self:granted_lines(g)) do
            if follow.trigger == "DEATHRATTLE" then return true end
        end
    end
    return false
end

function E:granted_reacts(e, trigger)
    for _, g in ipairs(e.granted) do
        for _, line in ipairs(self:granted_lines(g)) do
            if line.trigger == trigger then return true end
        end
    end
    return false
end

-- The lines a grant gives (granted_lines): the follow_up of the giver's effect at `index`, or with index -1 every
-- Deathrattle of the giver ("copy a Deathrattle"). Copies, each marked with where it came from.
function E:granted_lines(grant)
    local out = {}
    local giver = def(grant.card_id)
    if not giver then return out end
    if grant.index >= 0 then
        local fx = giver.effects[grant.index + 1]
        if fx then
            for i, line in ipairs(fx.followUp) do out[i] = line end
        end
    elseif grant.index == -1 then
        for _, line in ipairs(giver.effects) do
            if line.trigger == "DEATHRATTLE" then out[#out + 1] = line end
        end
    end
    for i, line in ipairs(out) do
        local copy = D.copyEffect(line)
        copy.grant_origin_card = grant.card_id
        copy.grant_origin_index = grant.index
        out[i] = copy
    end
    return out
end

function E:launch_upgrade_of(card)
    if card.launch_upgrade == "" then return nil end
    local up = def(card.launch_upgrade)
    if not up or (not up.implemented and up.text ~= "") then return nil end
    return up
end

function E:create_entity(printed, owner, zone, pos)
    local s = self.state
    local upgraded
    if (zone == ZONE.HAND or zone == ZONE.DECK) and s.players[owner + 1].game_starships_launched > 0 then
        upgraded = self:launch_upgrade_of(printed)
    end
    local d = upgraded or printed
    local e = newEntity()
    e.id = s.next_entity_id
    s.next_entity_id = s.next_entity_id + 1
    e.card_id = d.id
    e.owner, e.controller = owner, owner
    e.zone = zone
    e.attack = d.attack
    e.max_health = d.health
    e.health = d.health
    e.durability = d.durability
    e.keywords = d.keywords
    e.spell_damage = d.spell_damage
    e.turns_left = d.hand_turns
    if #d.titan_abilities > 0 then
        e.number = 1
    end
    e.flags.created_by_effect = true
    e.flags.divine_shield = band(d.keywords, KW.DIVINE_SHIELD) ~= 0
    e.flags.stealth = band(d.keywords, KW.STEALTH) ~= 0
    if zone == ZONE.BOARD or zone == ZONE.SECRET or zone == ZONE.WEAPON then
        e.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
    end
    s.entities[e.id] = e
    self:relocate(e.id, zone, pos)
    return e.id
end

function E:beside_summoner(side)
    local summoner = self:ent(self.effect_source)
    local d = summoner and self:def_of(self.effect_source)
    if self.far_right_summons or not summoner or not d or d.type ~= "MINION" or summoner.zone ~= ZONE.BOARD
        or summoner.owner ~= side or summoner.flags.dead or summoner.health <= 0 then
        return -1
    end
    local row = self:board_ids(side)
    for i, id in ipairs(row) do
        if id == self.effect_source then
            local placed = self.beside_count[id] or 0
            self.beside_count[id] = placed + 1
            return (i - 1) + 1 + placed
        end
    end
    return -1
end

function E:queue(trigger, seat, subject, amount)
    local q = self.pending_events
    q[#q + 1] = { trigger = trigger, seat = seat, subject = subject, amount = amount or 0 }
end

function E:queue_self(trigger, subject)
    local q = self.pending_self_events
    q[#q + 1] = { trigger, subject }
end

-- A minion a summon reaction summoned for its own text ("after you summon a Pirate, summon a copy of it") carries the
-- reaction's chain: the reactors whose reactions led to it, none of which fire_events lets answer it. What a
-- Deathrattle the reaction triggered summons is the dying minion's (its source is not the reactor): it carries none.
function E:queue_summon_events(controller, id)
    local chain = self.summon_chain
    local carried = #chain > 0 and self.effect_source == chain[#chain] and { unpack(chain) } or nil
    local q = self.pending_events
    q[#q + 1] = { trigger = "WHEN_SUMMON_MINION", seat = controller, subject = id, amount = 0, summon_chain = carried }
    q[#q + 1] = { trigger = "AFTER_SUMMON_MINION", seat = controller, subject = id, amount = 0, summon_chain = carried }
end

function E:summon_token(token, controller, pos, endOfTurnDestroy)
    if self:board_size(controller) >= 7 then return 0 end
    local d = def(token)
    if not d then return 0 end
    if pos < 0 then
        pos = self:beside_summoner(controller)
    end
    local id = self:create_entity(d, controller, ZONE.BOARD, pos)
    self.summoned_this_effect[#self.summoned_this_effect + 1] = id
    local e = self:ent(id)
    if e then
        e.flags.exhausted = band(e.keywords, bor(KW.CHARGE, KW.RUSH)) == 0
        e.flags.charge_ready = band(e.keywords, KW.CHARGE) ~= 0
        if d.dormant_turns > 0 then
            e.flags.dormant_turns = d.dormant_turns
            e.flags.exhausted = true
        end
        e.flags.just_played_turn = self.state.turn
        if endOfTurnDestroy then
            self:apply_buff(id, 0, 0, 0, false, "EOT_DESTROY")
        end
    end
    self:emit_event("SUMMONED", id, 0)
    -- A summon by an effect has no Battlecry to precede: "whenever you summon" answers it in the queue too.
    self:queue_summon_events(controller, id)
    self:note_summoned(controller, d)
    self.last_summoned = id
    return id
end

function E:summon_existing(id, controller, pos)
    local e = self:ent(id)
    if not e or self:board_size(controller) >= 7 then return 0 end
    if pos < 0 then
        pos = self:beside_summoner(controller)
    end
    local d = self:def_of(id)
    e.owner, e.controller = controller, controller
    e.play_order = self.state.next_play_order
    self.state.next_play_order = self.state.next_play_order + 1
    self:relocate(id, ZONE.BOARD, pos)
    self.summoned_this_effect[#self.summoned_this_effect + 1] = id
    e.flags.exhausted = band(e.keywords, bor(KW.CHARGE, KW.RUSH)) == 0
    e.flags.charge_ready = band(e.keywords, KW.CHARGE) ~= 0
    e.flags.attacks_this_turn = 0
    if d and d.dormant_turns > 0 then
        e.flags.dormant_turns = d.dormant_turns
        e.flags.exhausted = true
    end
    e.flags.just_played_turn = self.state.turn
    self:emit_event("SUMMONED", id, 0)
    self:queue_summon_events(controller, id)
    self:note_summoned(controller, d)
    self.last_summoned = id
    return id
end

function E:make_sandwiches()
    for seat = 0, 1 do
        local hand = self:hand_ids(seat)
        for first = 1, #hand do
            local bread = self:def_of(hand[first])
            local sandwich = bread and bread.sandwich ~= "" and def(bread.sandwich)
            if sandwich then
                for second = first + 1, #hand do
                    local o = self:def_of(hand[second])
                    if o and o.id == bread.id then
                        local stuffing = {}
                        for between = first + 1, second - 1 do
                            local bd = self:def_of(hand[between])
                            if bd and bd.type == "MINION" then
                                stuffing[#stuffing + 1] = hand[between]
                            end
                        end
                        for _, id in ipairs(stuffing) do
                            self:relocate(id, ZONE.SETASIDE, -1)
                        end
                        self:relocate(hand[first], ZONE.GRAVEYARD, -1)
                        self:relocate(hand[second], ZONE.GRAVEYARD, -1)
                        local made = self:create_entity(sandwich, seat, ZONE.HAND, first - 1)
                        local me = self:ent(made)
                        if me then me.stuffed = stuffing end
                        return true
                    end
                end
            end
        end
    end
    return false
end

function E:destroy_weapon(seat)
    local p = self:player(seat)
    local weapon = p.weapon_id
    if weapon ~= 0 then
        self:relocate(weapon, ZONE.GRAVEYARD, -1)
        self:queue_self("DEATHRATTLE", weapon)
    end
    p.weapon_id = 0
    local hero = self:hero_of(seat)
    if hero then hero.attack = 0 end
end

function E:equip_weapon(token, seat)
    local d = def(token)
    if not d or d.type ~= "WEAPON" then return end
    self:destroy_weapon(seat)
    local id = self:create_entity(d, seat, ZONE.WEAPON, 0)
    self:player(seat).weapon_id = id
    self:emit_event("EQUIPPED", id, 0)
    self:recompute_auras()
end

-- ---- auras -------------------------------------------------------------------------------------

local function clearKeywordFlags(e, kw)
    if band(kw, KW.DIVINE_SHIELD) ~= 0 then e.flags.divine_shield = false end
    if band(kw, KW.STEALTH) ~= 0 then e.flags.stealth = false end
    if band(kw, KW.FREEZE) ~= 0 then e.flags.frozen = false end
    if band(kw, KW.IMMUNE) ~= 0 then e.flags.immune = false end
end

function E:recompute_auras()
    local s = self.state
    -- 1. Take back what the last pass's auras added.
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        local buffs = e.buffs
        local i = 1
        while i <= #buffs do
            local b = buffs[i]
            if not b.from_aura then
                i = i + 1
            else
                e.attack = e.attack - b.attack
                e.max_health = e.max_health - b.health
                e.health = e.health - b.health
                if b.keyword ~= 0 then
                    e.keywords = band(e.keywords, bnot(b.keyword))
                    clearKeywordFlags(e, b.keyword)
                end
                table.remove(buffs, i)
            end
        end
        -- A keyword a lasting buff gave (not an aura's) survives the take-back: "give a minion Taunt" after the aura
        -- gave it Taunt is still Taunt. The spent kinds (Divine Shield, Stealth, Freeze, Immune) are not restored.
        if not e.flags.silenced then
            local spent = bor(KW.DIVINE_SHIELD, KW.STEALTH, KW.FREEZE, KW.IMMUNE)
            for _, b in ipairs(buffs) do
                if not b.from_aura then e.keywords = bor(e.keywords, band(b.keyword, bnot(spent))) end
            end
        end
    end
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        local d = def(e.card_id)
        -- What an effect gave it ("Give a minion Spell Damage +1") rides in its buffs, which silence clears.
        e.spell_damage = (not d or e.flags.silenced) and 0 or d.spell_damage
        if not e.flags.silenced then
            for _, b in ipairs(e.buffs) do e.spell_damage = e.spell_damage + (b.spell_damage or 0) end
        end
    end
    -- 2. Re-derive the static stat auras.
    for seat = 0, 1 do
        local sources = self:board_ids(seat)
        local weapon = s.players[seat + 1].weapon_id
        if weapon ~= 0 then
            local w = self:ent(weapon)
            if w and w.zone == ZONE.WEAPON then
                sources[#sources + 1] = weapon
            end
        end
        for _, row in ipairs(s.persistent) do
            if row.owner == seat then
                local rd = self:def_of(row.source)
                if rd and rd.type == "SPELL" then
                    sources[#sources + 1] = row.source
                end
            end
        end
        -- A source's own lines, then the lines a card installed for the rest of the game (a GAME_LONG row): those keep
        -- working whatever became of the card. A row is its PLAYER's and its CARD's: read by the card it was installed
        -- from (a Hexed or Polymorphed source keeps it) and for the player who installed it.
        local lined = {}
        for _, srcId in ipairs(sources) do
            local d = self:def_of(srcId)
            local e = self:ent(srcId)
            if d and e then lined[#lined + 1] = { srcId, d.effects, d, e.controller, false } end
        end
        for _, row in ipairs(s.persistent) do
            if row.owner == seat and row.game_long >= 0 then
                local d = def(row.card_id)
                if d and row.game_long < #d.effects then
                    lined[#lined + 1] = { row.source, d.effects[row.game_long + 1].followUp, d, row.owner, true }
                end
            end
        end
        for _, entry in ipairs(lined) do
            local srcId, lines, sd, owner, isRow = entry[1], entry[2], entry[3], entry[4], entry[5]
            local src = self:ent(srcId)
            if src and sd and not (src.flags.silenced and not isRow) then
                for _, fx in ipairs(lines) do
                    if fx.trigger == "AURA" and not fx.printOnly
                        and (fx.op == "BUFF" or fx.op == "GIVE_KEYWORD" or fx.op == "BUFF_NAMED")
                        and not (fx.amount == 0 and fx.amount2 == 0 and fx.keywordBits == 0)
                        and self:condition_holds(fx, owner, srcId) then
                        local selfAura = fx.target.kind == "SELF" or fx.target.kind == "TRIGGER_SOURCE"
                        local skip = (selfAura and fx.damagedOnly and src.health >= src.max_health)
                            or (fx.whileAttacking and srcId ~= self.attacking_now)
                        if not skip then
                            if fx.op == "BUFF_NAMED" then
                                local name = fx.tokenDisplay
                                -- "Your Protoss minions": a family name keeps its s (it looked for "Protos").
                                if not fx.namedAnywhere and name ~= "" and name:sub(-1) == "s"
                                    and not (fx.nameFamily and D.isDesignerFamily(name)) then
                                    name = name:sub(1, -2)
                                end
                                local named = self:board_ids(owner)
                                if fx.namedAnywhere then
                                    for _, z in ipairs({ self:hand_ids(owner), self:deck_ids(owner) }) do
                                        for _, x in ipairs(z) do named[#named + 1] = x end
                                    end
                                end
                                for _, t in ipairs(named) do
                                    local td = self:def_of(t)
                                    -- "Your Zerg minions have +1 Attack": not the Zerg locations.
                                    if td and not self:is_location(t) and (fx.nameFamily and D.cardIsNamed(td, name, true)
                                        or (not fx.nameFamily and td.name == name)) then
                                        self:apply_aura_buff(t, fx.amount, fx.amount2, fx.keywordBits, sd.id)
                                    end
                                end
                            else
                                local counted = fx
                                if fx.countSelector or fx.amountSource ~= "NONE" or fx.costCount ~= "NONE" then
                                    counted = self:scaled_effect(fx, owner, srcId)
                                end
                                local targets
                                if selfAura and fx.target.side == "YOUR_HERO" then
                                    local hero = self:hero_of(owner)
                                    targets = hero and { hero.id } or {}
                                elseif selfAura then
                                    targets = { srcId }
                                else
                                    targets = self:resolve_targets(fx, srcId, 0, srcId, owner)
                                end
                                for _, t in ipairs(targets) do
                                    if (t == srcId and selfAura) or self:target_matches_filters(t, fx, srcId) then
                                        self:apply_aura_buff(t, counted.amount, counted.amount2, fx.keywordBits, sd.id)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- 3. A hero's Attack is its weapon's plus its own buffs.
    for seat = 0, 1 do
        local hero = self:hero_of(seat)
        if hero then
            local attack = 0
            local w = self:ent(s.players[seat + 1].weapon_id)
            if w and w.zone == ZONE.WEAPON then
                attack = attack + w.attack
            end
            for _, b in ipairs(hero.buffs) do
                attack = attack + b.attack
            end
            hero.attack = attack
        end
    end
    -- A minion that was ready this turn only because it had Charge goes back to sleep when the Charge ends. Rush keeps
    -- a minion played this turn ready, for minions only (attack_targets).
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e and e.zone == ZONE.BOARD and e.flags.charge_ready and band(e.keywords, KW.CHARGE) == 0 then
            e.flags.charge_ready = false
            if not (band(e.keywords, KW.RUSH) ~= 0 and e.flags.just_played_turn == s.turn) then
                e.flags.exhausted = true
            end
        end
    end
end

function E:spells_double_bonus(seat)
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        local d = e and not e.flags.silenced and self:def_of(id)
        if d then
            for _, fx in ipairs(d.effects) do
                if fx.trigger == "AURA" and fx.doubleSpellDamage then return true end
            end
        end
    end
    return false
end

function E:spell_bonus(seat)
    local b = self:spell_damage_of(seat)
    return (b > 0 and self:spells_double_bonus(seat)) and b * 2 or b
end

function E:spell_damage_of(seat)
    local total = 0
    -- "Gain Spell Damage +1 this turn" on a spell or a weapon lands on the hero (GIVE_KEYWORD), and counts like a minion's.
    local hero = self:ent(self.state.players[seat + 1].hero_id)
    if hero then total = total + hero.spell_damage end
    -- "Give a spell in your hand Spell Damage +1": the spell being cast adds its own.
    if self.casting_spell ~= 0 then
        local cast = self:ent(self.casting_spell)
        if cast and cast.controller == seat then total = total + cast.spell_damage end
    end
    for _, id in ipairs(self:board_ids(seat)) do
        total = total + self:minion_spell_damage(id)
    end
    return total
end

-- One minion's share of its side's Spell Damage: its own (printed, buffed) and its auras'.
function E:minion_spell_damage(id)
    local e = self:ent(id)
    if not e then return 0 end
    local total = e.spell_damage
    local d = not e.flags.silenced and self:def_of(id)
    if not d then return total end
    for _, fx in ipairs(d.effects) do
        if fx.op == "SPELL_DAMAGE_AURA" and fx.trigger == "AURA" and not fx.printOnly
            and not (fx.damagedOnly and e.health >= e.max_health)
            and self:condition_holds(fx, e.controller, id) then
            total = total + (fx.amountSource ~= "NONE" and self:scaled_effect(fx, e.controller, id).amount or fx.amount)
        end
    end
    return total
end

function E:ready_if_charged(e)
    if e.zone ~= ZONE.BOARD or not e.flags.exhausted or e.flags.dormant_turns > 0 then return end
    if band(e.keywords, KW.CHARGE) ~= 0 and e.flags.attacks_this_turn == 0 then
        e.flags.exhausted = false
        e.flags.charge_ready = true
    elseif band(e.keywords, KW.RUSH) ~= 0 and e.flags.just_played_turn == self.state.turn
        and e.flags.attacks_this_turn == 0 then
        e.flags.exhausted = false
    end
end

-- After a summon op made `created`: its attack ("summoned minions that attack"), then "... and dies".
function E:after_summon_attack(created, fx, defender)
    if created == 0 or self.aborted then return end
    if fx.summonAttacks ~= 0 then
        self:summon_attacks(created, fx.summonAttacks, defender)
    end
    -- "... that attacks a random enemy, then dies": a minion the attack did not kill dies now.
    if fx.attackThenDies then
        local made = self:ent(created)
        if made and made.zone == ZONE.BOARD then self:mark_dead(created) end
    end
end

function E:summon_attacks(attacker, mode, defender)
    local a = self:ent(attacker)
    if not a or a.zone ~= ZONE.BOARD then return end
    local side = a.controller
    local function alive(id)
        local e = self:ent(id)
        return e ~= nil and not e.flags.dead and e.health > 0 and (e.zone == ZONE.BOARD or e.zone == ZONE.HERO)
    end
    -- "... to attack the enemy hero" (5) and "that attack it" (6: the chosen minion, the trigger source, the original).
    if mode == 5 or mode == 6 then
        local at
        if mode == 5 then
            local h = self:hero_of(other(side))
            at = h and h.id or 0
        else
            at = defender or 0
        end
        if at ~= 0 and at ~= attacker and alive(at) then self:forced_attack(attacker, at) end
        return
    end
    -- "Summon a 3/3 Dread Imp to attack each enemy minion" (7): one after another, while it lives.
    if mode == 7 then
        for _, id in ipairs(self:board_ids(other(side))) do
            local me = self:ent(attacker)
            if not me or me.flags.dead or me.health <= 0 or me.zone ~= ZONE.BOARD or self.aborted then return end
            if self:ent(id) and not self:is_location(id) and alive(id) then
                self:forced_attack(attacker, id)
            end
        end
        return
    end
    if mode == 8 then mode = 2 end   -- "they attack enemy minions": a random enemy minion each, as mode 2
    if mode == 4 then
        for _, id in ipairs(self:board_ids(side)) do
            local me = self:ent(attacker)
            if not me or me.flags.dead or me.health <= 0 or me.zone ~= ZONE.BOARD or self.aborted then
                return
            end
            if id ~= attacker and self:ent(id) and not self:is_location(id) and alive(id) then
                self:forced_attack(attacker, id)
            end
        end
        return
    end
    local pool = {}
    for _, id in ipairs(self:side_ids(mode == 2 and "ENEMY_MINION" or "ENEMY_CHARACTER", side, attacker)) do
        if self:ent(id) and alive(id) and not self:is_location(id) then
            pool[#pool + 1] = id
        end
    end
    if #pool == 0 then return end
    if mode == 3 then
        local lowest = 2 ^ 30
        for _, id in ipairs(pool) do lowest = min(lowest, self:ent(id).health) end
        local kept = {}
        for _, id in ipairs(pool) do
            if self:ent(id).health == lowest then kept[#kept + 1] = id end
        end
        pool = kept
    end
    self:forced_attack(attacker, pool[self.state.rng:intBelow(#pool) + 1])
end

function E:gain_armor(target, amount)
    local hero = target.zone == ZONE.HERO and target or self:hero_of(target.controller)
    if not hero then return end
    hero.armor = hero.armor + amount
    local p = self:player(hero.owner)
    p.armor_changed_this_turn = true
    if amount > 0 then
        p.game_armor_gained = p.game_armor_gained + amount
        p.armor_gained_this_turn = p.armor_gained_this_turn + amount
        -- "After you gain Armor": the hero's owner's reactions -- unless this Armor is one of theirs.
        if not self.armor_reacting then
            self:queue("AFTER_GAIN_ARMOR", hero.owner, hero.id, amount)
        end
    end
end

function E:apply_buff(id, attack, health, keyword, temporary, source, turns, spellDamage)
    spellDamage = spellDamage or 0
    local e = self:ent(id)
    if not e then return end
    if e.zone == ZONE.HERO and attack > 0 then
        local p = self:player(e.owner)
        p.hero_attack_gained_this_turn = p.hero_attack_gained_this_turn + attack
        self:quest_count(e.owner, "GAIN_ATTACK", id, attack)   -- run 16: "Gain 4 Attack with your hero"
    end
    local d = self:def_of(id)
    if d and d.type == "WEAPON" and health ~= 0 then
        e.durability = e.durability + health
        health = 0
    end
    if band(keyword, KW.FREEZE) ~= 0 then
        keyword = band(keyword, bnot(KW.FREEZE))
        self:freeze_entity(id)
        if attack == 0 and health == 0 and keyword == 0 then return end
    end
    e.attack = e.attack + attack
    e.max_health = e.max_health + health
    e.health = e.health + health
    -- "Whenever your hero takes damage on your turn, gain +2/+2": an answer to a hero's damage runs before the death
    -- pass (answer_hero_damage), and the Health it gives a minion the same blow brought to 0 pays the damage past 0
    -- first; what is left saves it.
    if health > 0 and self.hero_answer_depth > 0 and e.zone == ZONE.BOARD and e.flags.dead then
        for i, row in ipairs(self.lethal_damage) do
            if row[1] == id then
                local owed = min(row[2], health)
                e.health = e.health - owed
                row[2] = row[2] - owed
                if e.health > 0 then
                    e.flags.dead = false
                    table.remove(self.lethal_damage, i)
                end
                break
            end
        end
    end
    e.keywords = bor(e.keywords, keyword)
    if band(keyword, KW.DIVINE_SHIELD) ~= 0 then e.flags.divine_shield = true end
    if band(keyword, KW.STEALTH) ~= 0 then e.flags.stealth = true end
    if band(keyword, KW.IMMUNE) ~= 0 then e.flags.immune = true end
    e.spell_damage = e.spell_damage + spellDamage
    self:ready_if_charged(e)
    turns = turns or 0
    local b = { attack = attack, health = health, keyword = keyword, temporary = temporary and true or false,
        turns_remaining = turns, from_aura = false, source = source or "", spell_damage = spellDamage }
    -- "Give an ENEMY minion -2 Attack until your next turn" counts down on the GIVER's turn starts.
    if turns > 0 and self.effect_controller >= 0 and self.effect_controller ~= e.owner then
        b.ticks_on = self.effect_controller
    end
    if self.permanent_buff and not b.temporary and turns == 0 then b.permanent = true end
    e.buffs[#e.buffs + 1] = b
end

function E:apply_aura_buff(id, attack, health, keyword, source)
    local e = self:ent(id)
    if not e then return end
    e.attack = e.attack + attack
    e.max_health = e.max_health + health
    e.health = e.health + health
    -- The aura's keywords are only the bits it ADDS: one the minion already has is not the aura's to take back.
    local added = band(keyword, bnot(e.keywords))
    e.keywords = bor(e.keywords, keyword)
    self:ready_if_charged(e)
    if band(added, KW.DIVINE_SHIELD) ~= 0 then e.flags.divine_shield = true end
    if band(added, KW.STEALTH) ~= 0 then e.flags.stealth = true end
    if band(added, KW.FREEZE) ~= 0 then e.flags.frozen = true end
    if band(added, KW.IMMUNE) ~= 0 then e.flags.immune = true end
    e.buffs[#e.buffs + 1] = { attack = attack, health = health, keyword = added, temporary = false,
        turns_remaining = 0, from_aura = true, source = source or "" }
end

local function takeBuffBack(e, b)
    e.attack = e.attack - b.attack
    e.max_health = e.max_health - b.health
    e.health = min(e.health, e.max_health)
    e.keywords = band(e.keywords, bnot(b.keyword))
    clearKeywordFlags(e, b.keyword)
end

function E:clear_temp_buffs(seat)
    local s = self.state
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.owner == seat then
            local i = 1
            while i <= #e.buffs do
                local b = e.buffs[i]
                if b.temporary then
                    takeBuffBack(e, b)
                    table.remove(e.buffs, i)
                else
                    i = i + 1
                end
            end
        end
    end
    self:recompute_auras()
end

function E:expire_timed_buffs(seat)
    local s = self.state
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e then
            local own = e.owner == seat
            local i = 1
            while i <= #e.buffs do
                local b = e.buffs[i]
                -- A buff counts down on the turn starts of the player who gave it when that is not the owner.
                local counts
                if (b.ticks_on or -1) >= 0 then counts = b.ticks_on == seat else counts = own end
                if b.turns_remaining <= 0 or not counts then
                    i = i + 1
                else
                    b.turns_remaining = b.turns_remaining - 1
                    if b.turns_remaining > 0 then
                        i = i + 1
                    else
                        takeBuffBack(e, b)
                        table.remove(e.buffs, i)
                    end
                end
            end
        end
    end
    self:recompute_auras()
end

function E:freeze_entity(id)
    self:emit_event("FROZEN", id, 0)
    local e = self:ent(id)
    if not e or not (e.zone == ZONE.BOARD or e.zone == ZONE.HERO) then return end
    if not e.flags.frozen then
        self:apply_buff(id, 0, 0, 0, false, "freeze:" .. self.state.turn)
    else
        for _, b in ipairs(e.buffs) do
            if b.source:sub(1, 7) == "freeze:" then
                b.source = "freeze:" .. self.state.turn
                break
            end
        end
    end
    local newly = not e.flags.frozen
    e.flags.frozen = true
    -- "After an enemy is Frozen": both players hear it, once per freeze that took.
    if newly then
        self:queue("AFTER_FROZEN", e.owner, id)
        self:queue("AFTER_FROZEN", other(e.owner), id)
    end
end

function E:heal_becomes_damage(seat)
    local p = self:player(seat)
    if p.heal_as_damage_this_turn or p.heal_as_damage_next > 0 then return true end
    for _, id in ipairs(self:board_ids(seat)) do
        local d = self:def_of(id)
        if d then
            for _, fx in ipairs(d.effects) do
                if fx.trigger == "AURA" and fx.op == "HEAL_AS_DAMAGE" and fx.amount2 >= 2 then return true end
            end
        end
    end
    return false
end

function E:consume_heal_as_damage(seat)
    local p = self:player(seat)
    if p.heal_as_damage_next > 0 then
        p.heal_as_damage_next = p.heal_as_damage_next - 1
    end
end

function E:heal_entity(id, amount)
    local e = self:ent(id)
    if not e or amount <= 0 then return end
    if e.zone ~= ZONE.BOARD and e.zone ~= ZONE.HERO then return end
    local before = e.health
    e.health = min(e.max_health, e.health + amount)
    if e.health > 0 then e.flags.dead = false end
    if e.health > before then
        if e.zone == ZONE.HERO then
            self:player(e.owner).hero_health_changed_this_turn = true
        end
        local owner = self:player(e.owner)
        owner.game_health_restored = owner.game_health_restored + (e.health - before)
        -- Run 16: "Quest: Restore 15 Health" counts for the player whose effect healed (a Lifesteal blow: its owner).
        self:quest_count(self.effect_controller >= 0 and self.effect_controller or e.owner, "RESTORE_HEALTH", id,
            e.health - before)
        self:player(self.state.active).restored_health_this_turn = true
        self:queue("AFTER_HEAL", 0, id)
        self:queue("AFTER_HEAL", 1, id)
        if before + amount > e.max_health then
            self:queue("OVERHEAL", e.owner, id)
        end
    end
end

function E:forget_buff_stats(e, attack, health)
    for _, b in ipairs(e.buffs) do
        if not b.from_aura then
            if attack then b.attack = 0 end
            if health then b.health = 0 end
        end
    end
end

function E:is_location(id)
    local d = self:def_of(id)
    return d ~= nil and d.type == "LOCATION"
end

function E:discard_card(id, seat)
    local e = self:ent(id)
    if not e or e.zone ~= ZONE.HAND then return end
    self.discarded_this_effect[#self.discarded_this_effect + 1] = id
    self:relocate(id, ZONE.GRAVEYARD, -1)
    local p = self:player(seat)
    p.game_cards_discarded = p.game_cards_discarded + 1
    self:emit_event("DISCARDED", id, 0)
    self:queue("AFTER_DISCARD", seat, id)
end

function E:mark_dead(id)
    local e = self:ent(id)
    if not e then return end
    -- Destroyed is dead whatever Health it gets back (see answer_hero_damage).
    self:forget_lethal_damage(id)
    if e.zone == ZONE.BOARD then
        e.flags.dead = true
    elseif e.zone == ZONE.HERO then
        e.health = 0
    elseif e.zone == ZONE.WEAPON then
        if self:player(e.owner).weapon_id == id then
            self:destroy_weapon(e.owner)
        end
    elseif e.zone == ZONE.SECRET then
        local secrets = self:player(e.owner).secrets
        for i = #secrets, 1, -1 do
            if secrets[i] == id then table.remove(secrets, i) end
        end
        self:relocate(id, ZONE.GRAVEYARD, -1)
    end
end

-- The observer log (not part of the rules or the snapshot): the board UI animates from it.
-- The observer log (not part of the rules or the snapshot): the board UI animates from it. A search copy writes none.
function E:emit_event(kind, subject, source, amount)
    if self.scratch then return end
    local events = self.events
    if events then
        local e = self:ent(subject)
        events[#events + 1] = { kind = kind, subject = subject, source = source, amount = amount or 0,
            seat = e and e.controller or self.state.active }
    end
end

function E:redirect_target_for(target)
    local victim = self:ent(target)
    if not victim or (victim.zone ~= ZONE.HERO and victim.zone ~= ZONE.BOARD) then return 0 end
    local owner = victim.owner
    for _, id in ipairs(self:board_ids(owner)) do
        local carrier = self:ent(id)
        local d = carrier and not carrier.flags.silenced and id ~= target and self:def_of(id)
        if d then
            for _, fx in ipairs(d.effects) do
                if fx.trigger == "AURA" and fx.op == "TAKES_DAMAGE_INSTEAD" and not fx.printOnly then
                    if fx.target.side == "YOUR_HERO" and victim.zone == ZONE.HERO then
                        return id
                    end
                    if fx.target.kind == "ADJACENT" and victim.zone == ZONE.BOARD then
                        local row = self:board_ids(owner)
                        local function at(which)
                            for i, x in ipairs(row) do
                                if x == which then return i end
                            end
                            return #row + 1
                        end
                        if math.abs(at(id) - at(target)) == 1 then
                            return id
                        end
                    end
                end
            end
        end
    end
    return 0
end

function E:damage_multiplier_for(victim)
    local v = self:ent(victim)
    if not v then return 1 end
    if v.zone == ZONE.BOARD then
        for _, p in ipairs(self.state.players) do
            if p.minions_double_damage_this_turn then return 2 end
        end
    end
    local function matches(fx, e, auraSeat)
        if fx.op ~= "DAMAGE_MULTIPLIER" or fx.trigger ~= "AURA" or fx.printOnly then return false end
        if fx.condition == "YOUR_TURN" and self.state.active ~= auraSeat then return false end
        if fx.undamagedOnly and e.health < e.max_health then return false end
        local side = fx.target.side
        if side == "YOUR_HERO" then return e.zone == ZONE.HERO and e.controller == auraSeat end
        if side == "ENEMY_MINIONS" then return e.zone == ZONE.BOARD and e.controller ~= auraSeat end
        if side == "FRIENDLY_MINIONS" then return e.zone == ZONE.BOARD and e.controller == auraSeat end
        if side == "ANY_MINION" or side == "ANY_CHARACTER" then return e.zone == ZONE.BOARD end
        return false
    end
    local own = self:def_of(victim)
    if own then
        for _, fx in ipairs(own.effects) do
            if fx.op == "DAMAGE_MULTIPLIER" and fx.trigger == "AURA" and fx.target.kind == "SELF" then return 2 end
        end
    end
    for seat = 0, 1 do
        local holders = self:board_ids(seat)
        local weapon = self:player(seat).weapon_id
        if weapon ~= 0 then holders[#holders + 1] = weapon end
        for _, id in ipairs(holders) do
            local holder = self:ent(id)
            local d = holder and not holder.flags.silenced and self:def_of(id)
            if d then
                for _, fx in ipairs(d.effects) do
                    if matches(fx, v, seat) then return 2 end
                end
            end
        end
    end
    return 1
end

function E:player_doubles(seat, kind)
    for _, id in ipairs(self:board_ids(seat)) do
        local d = self:def_of(id)
        if d then
            for _, fx in ipairs(d.effects) do
                if fx.op == "DAMAGE_MULTIPLIER" and fx.trigger == "AURA"
                    and (fx.amount2 == kind or (kind ~= 3 and fx.amount2 == 1 and kind == 2)) then
                    return true
                end
            end
        end
    end
    return false
end

function E:damage_cap_for(victim)
    local v = self:ent(victim)
    if not v then return 0 end
    local cap = 0
    for _, id in ipairs(self:board_ids(v.controller)) do
        local e = self:ent(id)
        local d = self:def_of(id)
        if e and d and not e.flags.silenced and not e.flags.dead then
            for _, fx in ipairs(d.effects) do
                if fx.op == "DAMAGE_CAP" and fx.trigger == "AURA" and not fx.printOnly and fx.amount > 0 then
                    cap = cap == 0 and fx.amount or min(cap, fx.amount)
                end
            end
        end
    end
    return cap
end

local function isCharacter(e)
    return e.zone == ZONE.BOARD or e.zone == ZONE.HERO
end
E.isCharacter = isCharacter

function E:deal_damage(target, amount, source, spell, excessToHero)
    local t = self:ent(target)
    if not t then return 0 end
    if spell and source ~= 0 then
        local src = self:ent(source)
        if src then amount = amount + self:spell_bonus(src.controller) end
    end
    self.last_blow = amount
    local multiplier = self:damage_multiplier_for(target)
    if multiplier > 1 then amount = amount * multiplier end
    local dealer = source ~= 0 and self:ent(source) or nil
    if dealer then
        if (spell and self:player_doubles(dealer.controller, 1))
            or (self.hero_power_resolving and (self:player_doubles(dealer.controller, 1)
                or self:player_doubles(dealer.controller, 2))) then
            amount = amount * 2
        end
    elseif self.hero_power_resolving and self:player_doubles(self.state.active, 1) then
        amount = amount * 2
    end
    local victim = self:ent(target)
    if victim and victim.zone == ZONE.BOARD then
        local cap = self:damage_cap_for(target)
        if cap > 0 then amount = min(amount, cap) end
    end
    if amount <= 0 then return 0 end
    if not self.redirecting_damage then
        local redirector = self:redirect_target_for(target)
        if redirector ~= 0 and redirector ~= target then
            self.redirecting_damage = true
            local dealt = self:deal_damage(redirector, amount, source, spell, excessToHero)
            self.redirecting_damage = false
            return dealt
        end
    end
    if t.flags.immune then
        self:emit_event("DAMAGE_PREVENTED", target, source, amount)
        return 0
    end
    if t.flags.divine_shield then
        t.flags.divine_shield = false
        t.keywords = band(t.keywords, bnot(KW.DIVINE_SHIELD))
        self:emit_event("DAMAGE_PREVENTED", target, source, amount)
        -- "After a friendly minion loses Divine Shield" (Bolvar, Fireblood; Light's Sorrow).
        self:queue("AFTER_LOSE_DIVINE_SHIELD", t.owner, target)
        return 0
    end
    if t.zone == ZONE.HERO then
        local hp = self:player(t.owner)
        hp.hero_took_damage_this_turn = true
        hp.hero_damage_taken_this_turn = hp.hero_damage_taken_this_turn + amount
        hp.hero_health_changed_this_turn = true
        -- Run 16: "Take 12 damage on your turns" (Armor's share counts: the hero was damaged).
        if t.owner == self.state.active then
            self:quest_count(t.owner, "TAKE_DAMAGE", target, amount)
        end
    end
    self.last_excess = 0
    local remaining = amount
    local absorbed = 0
    if t.armor > 0 then
        absorbed = min(t.armor, remaining)
        t.armor = t.armor - absorbed
        if t.zone == ZONE.HERO then
            self:player(t.owner).armor_changed_this_turn = true
        end
        remaining = remaining - absorbed
    end
    local lost = 0
    local beforeHealth = t.health
    if remaining > 0 and t.health > 0 then
        lost = min(t.health, remaining)
        t.health = t.health - lost
    end
    -- Run 16: the blow toward its dealer's quests: "deal exactly 2 damage to an enemy on your turn" (the dealer's turn),
    -- "deal damage with 3 spells" (a spell, once each). A Hero Power's blow has no entity: the active seat dealt it.
    if lost > 0 or absorbed > 0 then
        local by = dealer and dealer.controller or self.state.active
        if by == self.state.active and t.controller ~= by then
            self:quest_count(by, "DEAL_DAMAGE", target, remaining + absorbed)
        end
        local dealtBy = dealer and self:def_of(source)
        if dealtBy and dealtBy.type == "SPELL" then
            self:quest_count(by, "SPELL_DAMAGE", source, 1)
        end
    end
    local killReactor = source
    if dealer and dealer.zone == ZONE.HERO then
        killReactor = self:player(dealer.owner).weapon_id
    end
    if killReactor ~= 0 and t.zone == ZONE.BOARD and absorbed == 0 and beforeHealth > 0
        and remaining == beforeHealth and t.health == 0 then
        self:queue_self("HONORABLE_KILL", killReactor)
        self.kill_victims[killReactor] = target
    end
    if killReactor ~= 0 and t.zone == ZONE.BOARD and remaining > lost and t.health <= 0 then
        local kr = self:ent(killReactor)
        if kr and (kr.zone == ZONE.BOARD or kr.zone == ZONE.WEAPON or (kr.zone == ZONE.GRAVEYARD
            and self:def_of(killReactor) and self:def_of(killReactor).type == "SPELL")) then
            self:queue_self("OVERKILL", killReactor)
            self.kill_victims[killReactor] = target
        end
    end
    if excessToHero and t.zone == ZONE.BOARD and remaining > lost then
        local hero = self:hero_of(t.owner)
        if hero then self:deal_damage(hero.id, remaining - lost, source, false) end
    end
    if lost > 0 then self:emit_event("DAMAGED", target, source, lost) end
    self.last_excess = remaining > lost and remaining - lost or 0
    if t.health <= 0 and t.zone == ZONE.BOARD then
        t.flags.dead = true
        -- The damage past 0 Health, which a Health buff before the death pass pays first (apply_buff).
        local past = remaining - lost
        local known
        for _, row in ipairs(self.lethal_damage) do
            if row[1] == target then known = row break end
        end
        if known then known[2] = known[2] + past else self.lethal_damage[#self.lethal_damage + 1] = { target, past } end
    end
    if lost > 0 and t.zone == ZONE.BOARD then
        self:queue("SELF_TAKES_DAMAGE", t.owner, target, lost)
    end
    -- "Whenever a minion takes damage", "whenever your hero takes damage" (Armor that soaked it counts): both players
    -- hear it, with the board and the turn as they were now.
    local function raiseDamaged(trigger, amt)
        for _, hearer in ipairs({ t.owner, other(t.owner) }) do
            local q = self.pending_events
            q[#q + 1] = { trigger = trigger, seat = hearer, subject = target, amount = amt, snapshot = true,
                listeners = self:board_ids(hearer), active_at = self.state.active,
                -- "After a hero takes damage" answers a blow an effect dealt at the end of that hit
                -- (answer_hero_damage); an attack's still waits for the action, its death pass and its attack triggers.
                now = trigger == "AFTER_HERO_DAMAGED" and self.effect_lists > 0 }
        end
    end
    if lost > 0 and t.zone == ZONE.BOARD then raiseDamaged("AFTER_MINION_DAMAGED", lost) end
    if lost + absorbed > 0 and t.zone == ZONE.HERO then raiseDamaged("AFTER_HERO_DAMAGED", lost + absorbed) end
    if lost > 0 and source ~= 0 then
        local dd = self:ent(source)
        if dd and dd.zone == ZONE.BOARD then
            self:queue("SELF_DEALS_DAMAGE", dd.owner, source, lost)
        end
    end
    local src = self:ent(source)
    if src then
        local srcKeywords = src.keywords
        local textSource = src.id
        if src.zone == ZONE.HERO and self.attacking_weapon ~= 0 then
            local weapon = self:ent(self.attacking_weapon)
            if weapon and weapon.zone == ZONE.WEAPON and not weapon.flags.silenced then
                srcKeywords = bor(srcKeywords, weapon.keywords)
                textSource = weapon.id
            end
        end
        if band(srcKeywords, KW.POISONOUS) ~= 0 and t.zone == ZONE.BOARD and remaining > 0 then
            t.flags.dead = true
            self:forget_lethal_damage(target)
        end
        -- A spell freezes by its own lines; its catalogue Freeze keyword froze everything it damaged.
        local srcDef = self:def_of(src.id)
        if band(srcKeywords, KW.FREEZE) ~= 0 and isCharacter(t) and remaining > 0
            and not (srcDef and srcDef.type == "SPELL") then
            self:freeze_entity(target)
        end
        if (band(srcKeywords, KW.LIFESTEAL) ~= 0 or self.effect_lifesteal) and remaining + absorbed > 0 then
            local hero = self:hero_of(src.controller)
            if hero then self:heal_entity(hero.id, remaining + absorbed) end
        end
        if remaining > 0 and isCharacter(t) and not src.flags.silenced then
            local freezes = false
            local sd = self:def_of(textSource)
            if sd then
                for _, f in ipairs(sd.effects) do
                    freezes = freezes or (f.trigger == "AURA" and f.op == "FREEZE_ON_DAMAGE")
                end
            end
            local ts = self:ent(textSource)
            if ts then
                for _, cid in ipairs(ts.magnetized) do
                    local m = def(cid)
                    if m then
                        for _, f in ipairs(m.effects) do
                            freezes = freezes or (f.trigger == "AURA" and f.op == "FREEZE_ON_DAMAGE")
                        end
                    end
                end
            end
            if freezes then self:freeze_entity(target) end
        end
    end
    if lost > 0 and t.zone == ZONE.BOARD and not t.flags.dead and t.health > 0 then
        self:queue("FRENZY", t.owner, target)
        self:queue("SURVIVED_DAMAGE", t.owner, target)
    end
    return lost
end

-- ---- turns -------------------------------------------------------------------------------------

function E:start_turn()
    local s = self.state
    -- "... this turn" counters are the turn's, whoever's it is: a new turn starts at zero.
    for _, each in ipairs(s.players) do
        each.armor_gained_this_turn = 0
        each.hero_attack_gained_this_turn = 0
        each.hero_took_damage_this_turn = false
        each.hero_damage_taken_this_turn = 0
        each.minions_died_this_turn = 0
        each.friendly_minions_died_this_turn = 0
        each.hero_health_changed_this_turn = false
        each.armor_changed_this_turn = false
    end
    s.turn = s.turn + 1
    self:quest_turn_start()   -- run 16: "survive 10 turns", "draw 4 cards in one turn"
    local p = self:player(s.active)
    p.max_mana = min(10, p.max_mana + 1)
    p.overload_locked = p.overload_next
    p.overload_next = 0
    p.mana = max(0, p.max_mana - p.overload_locked)
    p.temp_mana = 0
    p.elemental_streak = hasRace(p.play_tribes_this_turn, RACE.elemental) and p.elemental_streak + 1 or 0
    p.play_tribes_last_turn = p.play_tribes_this_turn
    p.play_schools_last_turn = p.play_schools_this_turn
    p.play_tribes_this_turn = 0
    p.play_schools_this_turn = 0
    p.elementals_played_last_turn = p.elementals_played_this_turn
    p.elementals_played_this_turn = 0
    p.minions_double_damage_this_turn = false
    self:clear_temp_buffs(s.active)
    self:expire_timed_buffs(s.active)
    for _, id in ipairs(self:board_ids(s.active)) do
        local e = self:ent(id)
        if e then
            local skip = false
            if e.flags.dormant_turns > 0 then
                e.flags.dormant_turns = e.flags.dormant_turns - 1
                if e.flags.dormant_turns > 0 then
                    e.flags.exhausted = true
                    e.flags.attacks_this_turn = 0
                    e.flags.has_attacked = false
                    skip = true
                else
                    self:queue_self("WHEN_AWAKENS", id)
                end
            end
            if not skip then
                e.flags.exhausted = false
                e.flags.attacks_this_turn = 0
                e.flags.has_attacked = false
                e.flags.cant_attack_heroes_this_turn = false
                e.flags.charge_ready = false
            end
        end
    end
    for _, id in ipairs(self:hand_ids(s.active)) do
        local d = self:def_of(id)
        local e = self:ent(id)
        if d and d.swap_in_hand and e then
            local attack = e.attack
            e.attack = e.health
            e.health = attack
            e.max_health = attack
        end
    end
    p.chain_card = ""
    p.chain_options = {}
    p.chain_source = 0
    for _, id in ipairs(self:hand_ids(s.active)) do
        local d = self:def_of(id)
        if d then
            local recurring = false
            for _, fx in ipairs(d.effects) do
                if fx.trigger == "IN_HAND_TURN_START" then recurring = true end
            end
            if recurring then
                self:run_effects(id, "IN_HAND_TURN_START", 0, id)
            end
        end
    end
    for _, id in ipairs(self:hand_ids(s.active)) do
        local d = self:def_of(id)
        local e = self:ent(id)
        if d and e and d.hand_turns > 0 then
            e.turns_left = e.turns_left - 1
            if e.turns_left <= 0 then
                self:relocate(id, ZONE.GRAVEYARD, -1)
            end
        end
    end
    local hero = self:hero_of(s.active)
    if hero then self:emit_event("TURN_STARTED", hero.id, 0) end
    -- The parked queues run with the START_TURN triggers, after the board is readied, so what they summon arrives
    -- exhausted as a start-of-turn summon does.
    -- "At the start of your next turn, ...": run what was parked for this seat, from the HERO.
    if #p.delayed_effects > 0 then
        local queued = p.delayed_effects
        p.delayed_effects = {}
        local hero = p.hero_id
        local shared, sharedCard, sharedLast = nil, nil, -1
        for _, entry in ipairs(queued) do
            local d = def(entry[1])
            local fx = d and entry[2] >= 0 and d.effects[entry[2] + 1]
            if fx then
                if entry[1] ~= sharedCard or entry[2] ~= sharedLast + 1 then
                    shared = self:newFrame()
                end
                sharedCard, sharedLast = entry[1], entry[2]
                local one = D.copyEffect(fx)
                one.delayed = false
                one.trigger = "ON_PLAY"
                self:run_effect_list({ one }, hero, "ON_PLAY", -1, 0, shared, 0, s.active)
                if self.aborted then return end
            end
        end
    end
    -- "In 2 turns, ...": one of this player's turns closer; what is due now runs, from the hero, as above.
    if #p.delayed_later > 0 then
        local due = {}
        local i = 1
        while i <= #p.delayed_later do
            local row = p.delayed_later[i]
            row.turns = row.turns - 1
            if row.turns <= 0 then
                due[#due + 1] = row
                table.remove(p.delayed_later, i)
            else
                i = i + 1
            end
        end
        local heroId = p.hero_id
        local shared = self:newFrame()
        for _, entry in ipairs(due) do
            local d = def(entry.card)
            local fx = d and entry.index >= 0 and d.effects[entry.index + 1]
            if fx then
                local one = D.copyEffect(fx)
                one.delayTurns = 0
                one.trigger = "ON_PLAY"
                self:run_effect_list({ one }, heroId, "ON_PLAY", -1, 0, shared, 0, s.active)
                if self.aborted then return end
            end
        end
    end
    self:run_persistent(s.active, "START_TURN", false)
    self:run_trigger(s.active, "START_TURN")
    self:run_each_turn("START_EACH_TURN")
    -- A turn start that left a hero dead ("in 5 turns, destroy the enemy hero") ends the match before the turn's draw.
    self:check_win()
    if self:is_terminal() then return end
    self:draw_card(s.active)
end

-- Only change: the hero is read again where the C++ reads hero_of(seat) again (a hero replaced during the turn end).
function E:end_turn_cleanup()
    local s = self.state
    local seat = s.active
    local hero = self:hero_of(seat)
    if hero then self:emit_event("TURN_ENDED", hero.id, 0) end
    -- "At the end of the turn, summon a Dreadsteed": what was parked this turn runs now, whoever's turn it is, from
    -- the entity that parked it (a dead one included), or its player's hero.
    if #s.end_of_turn > 0 then
        local queued = s.end_of_turn
        s.end_of_turn = {}
        local shared, sharedCard, sharedLast = self:newFrame(), nil, -1
        for _, entry in ipairs(queued) do
            if entry.card ~= sharedCard or entry.index ~= sharedLast + 1 then shared = self:newFrame() end
            sharedCard, sharedLast = entry.card, entry.index
            local d = def(entry.card)
            local fx = d and entry.index >= 0 and d.effects[entry.index + 1]
            local skip = not fx
            -- "Battlecry: Summon an exact copy of this minion at the end of the turn" is an enchantment on the minion:
            -- gone with it (dead, bounced, Silenced, transformed). A Deathrattle's or a spell's parked clause runs
            -- whatever became of its card.
            if fx and d.type == "MINION" and (fx.trigger == "BATTLECRY" or fx.trigger == "ON_PLAY") then
                local own = self:ent(entry.source)
                if not own or own.zone ~= ZONE.BOARD or own.flags.dead or own.flags.silenced
                    or own.card_id ~= entry.card then
                    skip = true
                end
            end
            if not skip then
                local one = D.copyEffect(fx)
                one.delayEnd = false
                one.trigger = "ON_PLAY"
                local from = self:ent(entry.source) and entry.source or s.players[entry.seat + 1].hero_id
                self:run_effect_list({ one }, from, "ON_PLAY", -1, 0, shared, 0, entry.seat)
                if self.aborted then return end
            end
        end
    end
    self:run_trigger(seat, "END_TURN")
    self:run_each_turn("END_EACH_TURN")
    self:run_persistent(seat, "END_TURN", true)
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e then
            for _, b in ipairs(e.buffs) do
                if b.source == "EOT_DESTROY" then
                    e.flags.dead = true
                    break
                end
            end
        end
    end
    self:clear_temp_buffs(seat)
    local p = self:player(seat)
    p.restored_health_this_turn = false
    p.hero_health_changed_this_turn = false
    p.armor_changed_this_turn = false
    p.next_pays_with = 0
    p.next_pays_with_count = 0
    p.next_pays_with_type = 0
    p.friendly_deaths_by_tribe = 0
    p.twice_spells_turn = 0        -- "your next spell this turn casts twice"
    p.twice_battlecries_turn = 0   -- "your next Battlecry this turn triggers twice"
    if p.next_card_cost_this_turn then
        p.next_card_cost_delta = 0
        p.next_card_cost_cap = 0
        p.next_card_cost_filter = 0
        p.next_card_cost_school = 0
        p.next_card_cost_race = 0
        p.next_card_cost_keyword = 0
        p.next_card_cost_set = -1
        p.next_card_cost_secret = false
        p.next_card_cost_trait = 0
        p.next_card_cost_name = ""
        p.next_card_cost_name_family = false
        p.next_card_cost_this_turn = false
    end
    if p.hero_power_once_this_turn then
        p.hero_power_cost_once = 0
        p.hero_power_free_once = false
        p.hero_power_damage_once = 0
        p.hero_power_once_this_turn = false
    end
    p.heal_as_damage_this_turn = false
    -- "Temporary" cards and Echo's repeat copies leave the hand as their owner's turn ends: a Temporary card is
    -- DISCARDED (it counts, and "whenever you discard" sees it); an Echo copy just leaves.
    local fading = {}
    for _, id in ipairs(self:hand_ids(seat)) do
        local e = self:ent(id)
        if e and e.temp_card then fading[#fading + 1] = id end
    end
    for _, id in ipairs(fading) do
        local e = self:ent(id)
        if e and not e.echo_copy then
            self:discard_card(id, seat)
        else
            self:relocate(id, ZONE.GRAVEYARD, -1)
        end
    end
    for _, id in ipairs(self:hand_ids(seat)) do
        local e = self:ent(id)
        if e then
            e.flags.drawn_this_turn = false
            e.temp_cost_delta = 0
            if e.cost_override_this_turn then
                e.cost_override = -1
                e.cost_override_this_turn = false
            end
            if e.pays_with_this_turn then
                e.pays_with = 0
                e.pays_with_this_turn = false
            end
        end
    end
    local characters = self:board_ids(seat)
    hero = self:hero_of(seat)
    if hero then characters[#characters + 1] = hero.id end
    for _, id in ipairs(characters) do
        local e = self:ent(id)
        if e and e.flags.frozen then
            local frozenTurn = s.turn
            for _, b in ipairs(e.buffs) do
                if b.source:sub(1, 7) == "freeze:" then
                    frozenTurn = tonumber(b.source:sub(8)) or 0
                    break
                end
            end
            if frozenTurn < s.turn then
                e.flags.frozen = false
                for i, b in ipairs(e.buffs) do
                    if b.source:sub(1, 7) == "freeze:" then
                        table.remove(e.buffs, i)
                        break
                    end
                end
            end
        end
    end
    -- Run 16: "end 4 turns with any unspent Mana", "take no damage for a turn", "... 2 turns in a row" (before the Mana goes).
    self:quest_turn_end(seat)
    p.next_turn_cost_delta = p.pending_turn_cost_delta
    p.next_turn_cost_filter = p.pending_turn_cost_filter
    p.next_turn_cost_floor = false
    p.pending_turn_cost_delta = 0
    p.pending_turn_cost_filter = 0
    p.mana = 0
    p.temp_mana = 0
    p.cards_played_this_turn = 0
    p.cast_spell_last_turn = p.cast_spell_this_turn
    p.cast_spell_this_turn = false
    p.schools_cast_this_turn = 0
    p.spells_cast_this_turn = 0
    p.cards_drawn_this_turn = 0
    p.minions_died_this_turn = 0
    p.friendly_minions_died_this_turn = 0
    p.hero_took_damage_this_turn = false
    p.hero_damage_taken_this_turn = 0
    p.combo_cards_played_this_turn = 0
    p.hero_power_uses = 0
    hero = self:hero_of(seat)
    if hero then
        hero.flags.hero_power_used = false
        hero.flags.attacks_this_turn = 0
        hero.flags.has_attacked = false
    end
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e then e.flags.attacks_this_turn = 0 end
    end
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and d.bonus_effects_reroll then
            self:roll_bonus_effects(id)
        end
    end
    self:recompute_auras()
end

-- One queued event, fired with its listeners and turn as they were when it was raised (PendingEvent.snapshot) and the
-- summon chain it carries.
function E:fire_pending(ev)
    local outerListeners, outerActive = self.event_listeners, self.event_active_at
    self.event_listeners = ev.snapshot and ev.listeners or nil
    self.event_active_at = ev.active_at or -1
    self.event_summon_chain = ev.summon_chain
    self:fire_events(ev.trigger, ev.seat, ev.subject, ev.amount)
    self.event_listeners, self.event_active_at = outerListeners, outerActive
end

-- Deaths, Deathrattles, Reborn and the event queue, as finish_resolution runs them, without its attack and phase steps:
-- what one REPEAT_IF pass changed resolves before the next one. False when the match aborted; stops early at a
-- terminal state or a choice that opened.
function E:settle()
    for _ = 1, 200 do
        self:recompute_auras()
        if not self:resolve_deaths() then return false end
        self:check_win()
        if self:is_terminal() then return true end
        if self:make_sandwiches() then
            -- loop again
        elseif #self.pending_self_events > 0 then
            local events = self.pending_self_events
            self.pending_self_events = {}
            for _, ev in ipairs(events) do self:fire_self_event(ev[1], ev[2]) end
        elseif #self.pending_events > 0 then
            local events = self.pending_events
            self.pending_events = {}
            for _, ev in ipairs(events) do self:fire_pending(ev) end
        else
            return true
        end
    end
    self.aborted = true
    return false
end

function E:finish_resolution()
    local s = self.state
    for _ = 1, 1000 do
        self:recompute_auras()
        if not self:resolve_deaths() then return false end
        self:check_win()
        if self:is_terminal() then return true end
        if self:make_sandwiches() then
            -- loop again
        elseif self.pending_attack ~= 0 then
            local attacker = self.pending_attack
            self.pending_attack = 0
            self:fire_attack_triggers(attacker)
        elseif #self.pending_self_events > 0 then
            local events = self.pending_self_events
            self.pending_self_events = {}
            for _, ev in ipairs(events) do
                self:fire_self_event(ev[1], ev[2])
            end
        elseif #self.pending_events > 0 then
            local events = self.pending_events
            self.pending_events = {}
            for _, ev in ipairs(events) do
                self:fire_pending(ev)
            end
        -- Run 16: a quest whose goal the action reached gives its reward now that the action has settled, one at a
        -- time (what a reward does settles before the next).
        elseif self:settle_quests() then
            -- loop again
        elseif s.phase == PHASE.MULLIGAN then
            if s.mulligan_answered[1] and s.mulligan_answered[2] then
                for _, p in ipairs(s.players) do
                    p.max_mana = 0
                    p.mana = 0
                    p.temp_mana = 0
                    p.overload_locked = 0
                    p.overload_next = 0
                    p.fatigue = 0
                    p.cards_played_this_turn = 0
                    p.cast_spell_this_turn = false
                    p.schools_cast_this_turn = 0
                    p.spells_cast_this_turn = 0
                    p.cards_drawn_this_turn = 0
                    p.minions_died_this_turn = 0
                    p.friendly_minions_died_this_turn = 0
                    p.hero_power_uses = 0
                end
                -- Run 16: the Start of Game lines, once, before the first turn starts (the order is start_of_game's).
                -- What they set off (a death, an event) settles in this loop before the turn does.
                self:start_of_game()
                if self.aborted then return false end
                s.phase = PHASE.START_TURN
            else
                return true
            end
        elseif s.phase == PHASE.END_TURN_RESOLUTION then
            self:end_turn_cleanup()
            if self.aborted then return false end
            s.active = other(s.active)
            s.phase = PHASE.START_TURN
        elseif s.phase == PHASE.START_TURN then
            self:start_turn()
            if self.aborted then return false end
            s.phase = PHASE.PLAYER_ACTIONS
        else
            return true
        end
    end
    self.aborted = true
    return false
end

function E:check_win()
    local s = self.state
    local a, b = self:hero_of(0), self:hero_of(1)
    local aDead = not a or a.health <= 0
    local bDead = not b or b.health <= 0
    if not aDead and not bDead then return end
    if aDead and bDead then
        s.result.result, s.result.reason, s.result.winner = RESULT.DRAW, REASON.DRAW, 0
    elseif aDead then
        s.result.result = RESULT.WIN_B
        s.result.reason = self.fatigue_kill[1] and REASON.FATIGUE or REASON.LIFE
        s.result.winner = 1
    else
        s.result.result = RESULT.WIN_A
        s.result.reason = self.fatigue_kill[2] and REASON.FATIGUE or REASON.LIFE
        s.result.winner = 0
    end
    s.phase = PHASE.MATCH_FINISHED
end

function E:step_budget()
    local s = self.state
    s.loop_steps = s.loop_steps + 1
    if s.loop_steps > 500 then
        self.aborted = true
        return false
    end
    return true
end

function E:resolve_deaths()
    local s = self.state
    local passes = 0
    while true do
        if self.aborted then return false end
        passes = passes + 1
        if passes > 50 then
            self.aborted = true
            return false
        end
        self:recompute_auras()
        -- What damage brought to 0 Health dies now; an answer that saved one already took it off the list.
        self.lethal_damage = {}
        self:compact_board(0)
        self:compact_board(1)
        local dead = {}
        for id = 1, s.next_entity_id - 1 do
            local e = s.entities[id]
            if e.zone == ZONE.BOARD and (e.flags.dead or e.health <= 0) then
                dead[#dead + 1] = e
            end
        end
        if #dead == 0 then return true end
        table.sort(dead, function(x, y)
            if x.play_order ~= y.play_order then return x.play_order < y.play_order end
            return x.id < y.id
        end)
        local lastPosition = {}
        for _, e in ipairs(dead) do
            lastPosition[e.id] = e.zone_pos
        end
        self.removing_dead = true
        for _, e in ipairs(dead) do
            e.flags.dead = true
            e.died_turn = s.turn   -- "minions that died this turn"
            local owner = self:player(e.owner)
            owner.minions_died_this_turn = owner.minions_died_this_turn + 1
            local recorded = self:def_of(e.id)
            if recorded then
                owner.last_destroyed_cards[#owner.last_destroyed_cards + 1] = recorded.id
            end
            owner.friendly_minions_died_this_turn = owner.friendly_minions_died_this_turn + 1
            local dd = self:def_of(e.id)
            if dd then
                owner.friendly_deaths_by_tribe = bor(owner.friendly_deaths_by_tribe, dd.races)
                if dd.starship_piece then
                    owner.starship_attack = owner.starship_attack + (e.attack > 0 and e.attack or 0)
                    owner.starship_health = owner.starship_health + (e.max_health > 0 and e.max_health or 0)
                    owner.starship_keywords = bor(owner.starship_keywords, e.keywords)
                    owner.starship_building = true
                end
                if dd.type == "MINION" and owner.hero_class == D.FAMILY.DEATHKNIGHT and not dd.leaves_no_corpse then
                    owner.corpses = owner.corpses + 1
                end
            end
            self:emit_event("DIED", e.id, 0)
            -- A location that breaks is no minion dying: no minion-death count, no "after a minion dies", no Infuse.
            if not self:is_location(e.id) then
                owner.game_minions_died = owner.game_minions_died + 1
                self:queue("AFTER_FRIENDLY_MINION_DIES", e.owner, e.id)
                -- "Whenever a minion dies" and "whenever an ENEMY minion dies": both players hear it.
                self:queue("AFTER_MINION_DIES", e.owner, e.id)
                self:queue("AFTER_MINION_DIES", other(e.owner), e.id)
                for _, handId in ipairs(self:hand_ids(e.owner)) do
                    local he = self:ent(handId)
                    if he and he.zone == ZONE.HAND then
                        he.flags.infuse_progress = he.flags.infuse_progress + 1
                    end
                end
            end
            self:relocate(e.id, ZONE.GRAVEYARD, -1)
        end
        self.removing_dead = false

        for _, e in ipairs(dead) do   -- deathrattles in ascending play_order
            local id = e.id
            -- A Silenced minion's own Deathrattle does not run; what was granted after the Silence does.
            local d = not (e.flags.silenced and #e.granted == 0) and self:def_of(id)
            if d then
                local hasDeathrattle = false
                for _, fx in ipairs(d.effects) do
                    if fx.trigger == "DEATHRATTLE" and not e.flags.silenced then hasDeathrattle = true end
                end
                for _, cid in ipairs(e.magnetized) do
                    if anyDeathrattle(def(cid)) then hasDeathrattle = true end
                end
                local grants = {}
                for i, g in ipairs(e.granted) do grants[i] = g end
                if hasDeathrattle or #grants > 0 then
                    if not self:step_budget() then return false end
                    self.summon_pos = lastPosition[id]
                    self.dying_pos = lastPosition[id]
                    -- "Your minions trigger their Deathrattles twice" (Baron Rivendare): read once the dead are gone.
                    local passes2 = self:triggers_twice(e.owner, 2) and 2 or 1
                    for pass = 1, passes2 do
                        if self.aborted then break end
                        if pass > 1 and s.pending.active then
                            -- The first run stopped for a choice: the second runs once it is made.
                            if s.pending.resume and s.pending.source == id and s.pending.trigger == "DEATHRATTLE" then
                                s.pending.rerun = 1
                            end
                            break
                        end
                        if hasDeathrattle then
                            self:run_effects(id, "DEATHRATTLE", 0, id)
                        end
                        for _, g in ipairs(grants) do
                            local lines = self:granted_lines(g)
                            if #lines > 0 then
                                -- Granted after any Silence, so the minion's Silence does not stop it: run for its owner.
                                local ge = s.entities[id]
                                self:run_effect_list(lines, id, "DEATHRATTLE", 0, id, nil, 0,
                                    ge.flags.silenced and ge.owner or nil)
                                if self.aborted then break end
                            end
                        end
                    end
                    self.summon_pos = -1
                    self.dying_pos = -1
                    if self.aborted then return false end
                end
            end
        end

        for _, e in ipairs(dead) do
            if band(e.keywords, KW.REBORN) ~= 0 and not e.flags.silenced and not e.flags.reborn_used then
                local d = self:def_of(e.id)
                if d then
                    local back = self:summon_token(d.id, e.owner, lastPosition[e.id], false)
                    local reborn = self:ent(back)
                    if reborn then
                        reborn.health = 1
                        reborn.keywords = band(reborn.keywords, bnot(KW.REBORN))
                        reborn.flags.reborn_used = true
                    end
                end
            end
        end
    end
end

-- card_matches_filters (engine.cpp anonymous namespace).
function E.card_matches_filters(d, typeFilter, costMin, costMax, raceFilter, familyFilter, rarityFilter,
                                schoolFilter, zeroCost)
    familyFilter, rarityFilter, schoolFilter = familyFilter or 0, rarityFilter or 0, schoolFilter or 0
    if typeFilter ~= 0 and d.typeNum + 1 ~= typeFilter then return false end
    if familyFilter ~= 0 and d.familyNum + 1 ~= familyFilter then return false end
    if schoolFilter ~= 0 and d.schoolNum + 1 ~= schoolFilter then return false end
    if rarityFilter ~= 0 and d.rarityNum + 1 ~= rarityFilter then return false end
    if zeroCost and d.cost ~= 0 then return false end
    if costMin ~= 0 and d.cost < costMin then return false end
    if costMax ~= 0 and d.cost > costMax then return false end
    if raceFilter ~= 0 and not hasRace(d.races, raceFilter) then return false end
    return true
end

-- ---- card traits and the play history (engine.cpp, run waves 2026-11-10..19) ----------------------

-- Combo, Outcast, Kindred, Finale, Manathirst, Infuse and Quickdraw are stored on the BATTLECRY trigger too, and
-- "your Battlecries trigger twice" doubles none of them.
local KEYWORD_CONDITIONS = { COMBO = true, OUTCAST = true, KINDRED = true, FINALE = true, MANATHIRST = true,
    INFUSE = true, QUICKDRAW = true }
function E.keyword_condition(c) return KEYWORD_CONDITIONS[c] == true end

-- A card whose BATTLECRY-timed lines are all Battlecries proper.
function E.plain_battlecry(d)
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "BATTLECRY" and KEYWORD_CONDITIONS[fx.condition] then return false end
    end
    return true
end

-- A card with at least one Battlecry proper among its BATTLECRY-timed lines: something a doubler can double.
function E.has_battlecry_line(d)
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "BATTLECRY" and not KEYWORD_CONDITIONS[fx.condition] then return true end
    end
    -- "Battlecry: Choose to ...": the options are the Battlecry.
    return band(d.keywords, KW.BATTLECRY) ~= 0 and #d.choices > 0
end

local TRAIT = D.TRAIT
-- card_has_trait: the SubjectTrait (int) a card has, for its class seat `heroClass` (a FAMILY number).
function E.card_has_trait(d, trait, heroClass, entityKeywords)
    local function inList(list, c)
        for _, x in ipairs(list) do
            if x.condition == c or inList(x.replacement, c) or inList(x.followUp, c) then return true end
        end
        return false
    end
    local function hasCondition(c)
        if inList(d.effects, c) then return true end
        for _, option in ipairs(d.choices) do
            if inList(option, c) then return true end
        end
        return false
    end
    if trait == 0 then return true end
    if trait == TRAIT.secret then return d.secret end
    if trait == TRAIT.overload then return d.overload > 0 end
    if trait == TRAIT.combo then return hasCondition("COMBO") end
    if trait == TRAIT.outcast then return hasCondition("OUTCAST") end
    if trait == TRAIT.echo then return d.echo end
    if trait == TRAIT.neutral then return d.family == "NEUTRAL" end
    if trait == TRAIT.otherClass then return d.family ~= "NEUTRAL" and d.familyNum ~= heroClass end
    if trait == TRAIT.battlecryOrCombo then
        return band(bor(d.keywords, entityKeywords or 0), KW.BATTLECRY) ~= 0 or hasCondition("COMBO")
    end
    -- A place in the hand is the play's, not the card's: no card in a pool has one.
    if trait == TRAIT.handEdge or trait == TRAIT.handLeft or trait == TRAIT.handRight then return false end
    if trait == TRAIT.libram then return d.name:sub(1, 6) == "Libram" end
    if trait == TRAIT.frenzy then
        for _, x in ipairs(d.effects) do
            if x.trigger == "FRENZY" then return true end
        end
        return false
    end
    if trait == TRAIT.colossal then return d.colossal > 0 end
    if trait == TRAIT.magnetic then return d.magnetic end
    if trait == TRAIT.quickdraw then return hasCondition("QUICKDRAW") end
    if trait == TRAIT.oddAttack then return d.type == "MINION" and d.attack % 2 == 1 end
    if trait == TRAIT.hasType then return d.type == "MINION" and d.races ~= 0 end
    if trait == TRAIT.multiType then
        if d.type ~= "MINION" then return false end
        if band(d.races, D.RACE.ALL) ~= 0 then return true end
        local r, bits = d.races, 0
        while r ~= 0 do
            r = band(r, r - 1)
            bits = bits + 1
        end
        return bits >= 2
    end
    return false
end

function E.history_matches(d, paid, f, heroClass)
    if f.historyType ~= 0 and d.typeNum + 1 ~= f.historyType then return false end
    if f.historyClass ~= 0 and d.familyNum + 1 ~= f.historyClass then return false end
    if f.historyCost ~= 0 and d.cost ~= f.historyCost - 1 then return false end
    if f.historyPaid ~= 0 and paid ~= f.historyPaid - 1 then return false end
    if f.historySchool ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= f.historySchool) then return false end
    if f.historyTrait ~= 0 and not E.card_has_trait(d, f.historyTrait, heroClass, d.keywords) then return false end
    if f.costCountName ~= "" and not D.cardIsNamed(d, f.costCountName, f.nameFamily) then return false end
    return true
end

-- Stat bounds on a target or a pick: "a 1-Attack minion", "with 5 or more Attack", "with less Attack than this".
function E:stats_admit(fx, attack, health, source)
    if fx.targetAttackMin > 0 and attack < fx.targetAttackMin then return false end
    if fx.targetAttackMax > 0 and attack > fx.targetAttackMax then return false end
    if fx.targetAttackMax < 0 and attack > 0 then return false end   -- "a 0-Attack minion"
    if fx.targetHealthMin > 0 and health < fx.targetHealthMin then return false end
    if fx.targetHealthMax > 0 and health > fx.targetHealthMax then return false end
    if fx.attackBelowSource then
        local me = self:ent(source)
        if not me or attack >= me.attack then return false end
    end
    return true
end

function E:same_card_as_source(cardId, source)
    local own = self:def_of(source)
    return own ~= nil and own.id == cardId
end

-- Where a card came from: 1 it did not start in its owner's deck, 2 it started there.
function E.origin_matches(fx, e)
    return fx.origin == 0 or (fx.origin == 1) == e.flags.created_by_effect
end

-- "Casts When Drawn" / "Summoned When Drawn": -1 when the cast aborted, 1 when the card was cast (or summoned), 0
-- when it stays in hand. A cast card is replaced: its drawer draws another card (draw_card).
function E:cast_when_drawn(id)
    local drawn = self:ent(id)
    if not drawn then return 0 end
    -- An Emerald Portal that Blessing of the Dragon shuffled (run 16): no program says what it casts, its power does.
    if drawn.card_id == E.IMBUE_PORTAL then
        return self:imbue_portal_drawn(id)
    end
    local own = self:def_of(id)
    -- "Summoned When Drawn": the drawn minion itself is summoned, for its drawer or, "(for your opponent)", for the
    -- other player. A full board leaves it in the hand.
    if own and own.summons_when_drawn and own.type == "MINION" then
        local to = own.summons_for_opponent and other(drawn.owner) or drawn.owner
        if self:summon_existing(id, to, -1) == 0 then return 0 end
        return self.aborted and -1 or 1
    end
    if own and own.casts_when_drawn then
        self:run_effect_list(own.effects, id, "ON_PLAY", -1, 0, nil)
    else
        local shuffling = drawn.drawn_from ~= "" and def(drawn.drawn_from) or nil
        local casts = false
        if shuffling then
            for _, fx in ipairs(shuffling.effects) do
                casts = casts or fx.trigger == "CAST_WHEN_DRAWN"
            end
        end
        if not casts then return 0 end
        self:run_effect_list(shuffling.effects, id, "CAST_WHEN_DRAWN", -1, 0, nil)
    end
    if self.aborted then return -1 end
    self:relocate(id, ZONE.GRAVEYARD, -1)
    return 1
end

-- The card a cast card's drawer draws in its place: an ordinary draw from the top, whatever filter the draw had.
function E:draw_replacement(seat)
    -- A drawer whose hero is dead draws nothing more: the game ends at the next death check. A deck of Corrupted
    -- Blood otherwise cast, shuffled two and drew again forever, past the hero's death, until E_LOOP
    -- (jankcraft 94067d016).
    local hero = self:hero_of(seat)
    if not hero or hero.health <= 0 then return end
    local bottom, secret, trait, pick, bounds = self.draw_from_bottom, self.draw_secret_only, self.draw_trait,
        self.draw_pick_cost, self.draw_fx
    self.draw_from_bottom, self.draw_secret_only, self.draw_trait, self.draw_pick_cost, self.draw_fx =
        false, false, 0, 0, nil
    if self:step_budget() then self:draw_card(seat) end
    self.draw_from_bottom, self.draw_secret_only, self.draw_trait, self.draw_pick_cost, self.draw_fx =
        bottom, secret, trait, pick, bounds
end

function E:draw_card(seat, typeFilter, costMin, costMax, raceFilter, schoolFilter, keywordFilter)
    typeFilter, costMin, costMax = typeFilter or 0, costMin or 0, costMax or 0
    raceFilter, schoolFilter, keywordFilter = raceFilter or 0, schoolFilter or 0, keywordFilter or 0
    local s = self.state
    local p = self:player(seat)
    -- "Draw three minions of different minion types", "5 different Secrets", "3 cards of different Costs".
    local function distinctOk(d)
        if self.draw_distinct == 1 then
            return d.type == "MINION" and d.races ~= 0 and band(d.races, self.draw_used_races) == 0
        elseif self.draw_distinct == 2 then
            for _, used in ipairs(self.draw_used_cards) do
                if used == d.id then return false end
            end
        elseif self.draw_distinct == 3 then
            for _, used in ipairs(self.draw_used_costs) do
                if used == d.cost then return false end
            end
        end
        return true
    end
    if typeFilter ~= 0 or costMin ~= 0 or costMax ~= 0 or raceFilter ~= 0 or schoolFilter ~= 0 or keywordFilter ~= 0
        or self.draw_secret_only or self.draw_trait ~= 0 or self.draw_pick_cost ~= 0 or self.draw_fx ~= nil
        or self.draw_distinct ~= 0 then
        -- Reveal from the top until a wanted card appears, take it, and shuffle the revealed cards back.
        local order = self:deck_ids(seat)
        local found
        local fxb = self.draw_fx
        for i, id in ipairs(order) do
            local e = self:ent(id)
            local d = e and def(e.card_id)
            if d and distinctOk(d)
                and E.card_matches_filters(d, typeFilter, costMin, costMax, raceFilter, 0, 0, schoolFilter)
                and (keywordFilter == 0 or band(d.keywords, keywordFilter) == keywordFilter)
                and (not self.draw_secret_only or d.secret)
                and (self.draw_trait == 0 or E.card_has_trait(d, self.draw_trait, p.hero_class, e.keywords))
                and (fxb == nil or (self:stats_admit(fxb, e.attack, e.health, self.draw_source)
                    and E.origin_matches(fxb, e)
                    and not (fxb.excludeSource and self:same_card_as_source(d.id, self.draw_source))
                    -- "Draw two Zerg cards": a family (or a card's own name).
                    and (fxb.targetName == "" or D.cardIsNamed(d, fxb.targetName, fxb.nameFamily)))) then
                -- "Draw your highest Cost minion": every match is a candidate and the extreme Cost wins; the first
                -- such card from the top breaks a tie.
                if self.draw_pick_cost ~= 0 then
                    if not found then
                        found = i
                    else
                        local here = self:card_cost(seat, order[i])
                        local best = self:card_cost(seat, order[found])
                        if (self.draw_pick_cost == 1 and here > best) or (self.draw_pick_cost ~= 1 and here < best) then
                            found = i
                        end
                    end
                else
                    found = i
                    break
                end
            end
        end
        if not found then return end
        local taken = order[found]
        local td = self:def_of(taken)
        if td and self.draw_distinct ~= 0 then
            self.draw_used_races = bor(self.draw_used_races, td.races)
            self.draw_used_cards[#self.draw_used_cards + 1] = td.id
            self.draw_used_costs[#self.draw_used_costs + 1] = td.cost
        end
        p.cards_drawn_this_turn = p.cards_drawn_this_turn + 1
        p.game_cards_drawn = p.game_cards_drawn + 1
        local castOut = false
        if #self:hand_ids(seat) >= 10 then
            self:relocate(taken, ZONE.GRAVEYARD, -1)
        else
            self:relocate(taken, ZONE.HAND, -1)
            local drawn = self:ent(taken)
            if drawn then drawn.flags.drawn_this_turn = true end
            local cast = self:cast_when_drawn(taken)
            if cast < 0 then return end
            if cast > 0 then
                castOut = true
            else
                self.last_drawn = taken
                self.drawn_this_effect[#self.drawn_this_effect + 1] = taken
            end
        end
        self:emit_event("DRAWN", taken, 0)
        self:queue("AFTER_DRAW", seat, taken)
        self:queue("AFTER_OPPONENT_DRAW", other(seat), taken)
        local remaining = {}
        for i = found + 1, #order do remaining[#remaining + 1] = order[i] end
        for i = 1, found - 1 do
            local at = #remaining == 0 and 0 or s.rng:intBelow(#remaining + 1)
            table.insert(remaining, at + 1, order[i])
        end
        for i, id in ipairs(remaining) do
            local e = self:ent(id)
            if e then e.zone_pos = i - 1 end
        end
        if castOut then self:draw_replacement(seat) end
        return
    end
    local deck = self:deck_ids(seat)
    if #deck == 0 then
        p.fatigue = p.fatigue + 1
        local hero = self:hero_of(seat)
        if hero then
            self:deal_damage(hero.id, p.fatigue, 0, false)
            if hero.health <= 0 then
                self.fatigue_kill[seat + 1] = true
            end
        end
        return
    end
    local id = self.draw_from_bottom and deck[#deck] or deck[1]
    p.cards_drawn_this_turn = p.cards_drawn_this_turn + 1   -- a burned card was still drawn
    p.game_cards_drawn = p.game_cards_drawn + 1
    local castOut = false
    if #self:hand_ids(seat) >= 10 then
        self:relocate(id, ZONE.GRAVEYARD, -1)
    else
        self:relocate(id, ZONE.HAND, -1)
        local drawn = self:ent(id)
        if drawn then drawn.flags.drawn_this_turn = true end
        local cast = self:cast_when_drawn(id)
        if cast < 0 then return end
        if cast > 0 then
            castOut = true   -- "it" is the card drawn in its place
        else
            self.last_drawn = id
            self.drawn_this_effect[#self.drawn_this_effect + 1] = id
        end
    end
    self:emit_event("DRAWN", id, 0)
    self:queue("AFTER_DRAW", seat, id)
    self:queue("AFTER_OPPONENT_DRAW", other(seat), id)
    if castOut then self:draw_replacement(seat) end
end

function E:note_summoned(seat, d)
    local p = self:player(seat)
    p.game_minions_summoned = p.game_minions_summoned + 1
    if not d or d.races == 0 then return end
    local races = band(d.races, RACE.ALL) ~= 0 and bor(RACE.ALL - 1, RACE.ALL) or d.races
    for i = 1, 32 do
        if band(races, bit.lshift(1, i - 1)) ~= 0 then
            p.game_race_played[i] = p.game_race_played[i] + 1
        end
    end
end

function E:note_spell_cast(seat, schoolNum)
    local p = self:player(seat)
    p.cast_spell_this_turn = true
    p.game_spells_cast = p.game_spells_cast + 1
    p.spells_cast_this_turn = p.spells_cast_this_turn + 1
    if schoolNum ~= 0 then
        p.schools_cast_this_turn = bor(p.schools_cast_this_turn, bit.lshift(1, schoolNum))
        while #p.spell_schools_game < schoolNum + 1 do
            p.spell_schools_game[#p.spell_schools_game + 1] = 0
        end
        p.spell_schools_game[schoolNum + 1] = p.spell_schools_game[schoolNum + 1] + 1
    end
    for _, id in ipairs(self:hand_ids(seat)) do
        local e = self:ent(id)
        if e then
            e.held_spells_cast = e.held_spells_cast + 1
            if schoolNum ~= 0 then
                e.held_school_mask = bor(e.held_school_mask, bit.lshift(1, schoolNum))
            end
            local d = self:def_of(id)
            if d and d.held_spell_transform ~= "" and e.held_spells_cast >= d.held_spell_threshold then
                local minion = def(d.held_spell_transform)
                if minion and minion.implemented then
                    e.card_id = minion.id
                    self:reset_to_card(e)
                    e.held_spells_cast = 0
                end
            end
        end
    end
end

function E:is_terminal()
    local s = self.state
    return s.result.result ~= RESULT.ONGOING or s.phase == PHASE.MATCH_FINISHED
end

function E:newFrame()
    return { source = 0, controller = 0, event_subject = 0, chosen = 0, previous_targets = {}, created = {} }
end


-- card.h: kQuestKind* and quest_kind_of (an unset or unknown kind is a plain Quest).
E.QUEST_KIND_QUEST, E.QUEST_KIND_QUESTLINE, E.QUEST_KIND_SIDEQUEST, E.QUEST_KIND_REPEATABLE = 1, 2, 3, 4
function E.quest_kind_of(kind)
    if kind >= 1 and kind <= 4 then return kind end
    return 1
end


-- The card's Op::QUEST line, or nil.
function E.quest_line_of(card)
    if card == nil then return nil end
    for _, fx in ipairs(card.effects) do
        if fx.op == "QUEST" then return fx end
    end
    return nil
end


local QUEST_GOAL_TRIGGERS = { PLAY_CARD = "AFTER_PLAY_CARD", TURNS_IN_ROW = "AFTER_PLAY_CARD",
    SPEND_MANA = "AFTER_PLAY_CARD", PLAY_MINION = "AFTER_PLAY_MINION", SUMMON_MINION = "AFTER_SUMMON_MINION",
    CAST_SPELL = "AFTER_CAST_SPELL", SPELL_ON_MINION = "AFTER_SPELL_ON_MINION", DRAW = "AFTER_DRAW",
    DISCARD = "AFTER_DISCARD" }
function E.quest_goal_trigger(goal)
    return QUEST_GOAL_TRIGGERS[goal] or "ON_PLAY"
end


-- Wire-only in the reference (the replay log): nothing to do here.
function E:note_quest(kind, quest)
end


-- A step toward the seat's quests whose goal is `goal` (a D.QUEST_GOAL name): `subject` is the card or entity the event
-- named, `amount` how much it counts.
function E:quest_count(seat, goal, subject, amount)
    local s = self.state
    local p = s.players[seat + 1]
    if #p.quests == 0 or amount <= 0 then return end
    for _, q in ipairs(p.quests) do
        local line = E.quest_line_of(self:def_of(q.entity))
        if line ~= nil and line.questGoal == goal then
            local target = E.quest_goal_target(line)
            local repeatable = E.quest_kind_of(line.questKind) == E.QUEST_KIND_REPEATABLE
            -- Reached: it waits for settle_quests (a Repeatable Quest keeps counting, and carries the excess over).
            local skip = q.progress >= target and not repeatable
            local se = (not skip and subject ~= 0) and self:ent(subject) or nil
            local sd = (not skip and subject ~= 0) and self:def_of(subject) or nil
            if not skip and E.quest_goal_trigger(goal) ~= "ON_PLAY" then
                if se == nil or sd == nil or subject == q.entity then
                    skip = true
                else
                    local probe = D.copyEffect(line)
                    probe.trigger = E.quest_goal_trigger(goal)
                    if not self:subject_matches(probe, subject, q.entity) or not E.origin_matches(line, se) then
                        skip = true
                    -- "Play 6 Temporary cards".
                    elseif goal == "PLAY_CARD" and line.temporary and not se.temp_card then
                        skip = true
                    end
                end
            end
            if not skip then
                local before = q.progress
                -- One effect, or one spell, counts once however many cards or blows it makes.
                local once = (s.v % 20000) * 100000 + subject % 100000
                if goal == "SPEND_MANA" or goal == "RESTORE_HEALTH" or goal == "TAKE_DAMAGE" or goal == "GAIN_ATTACK"
                    or goal == "SPEND_CORPSES" then
                    q.progress = q.progress + amount
                elseif goal == "DEAL_DAMAGE" then
                    if line.amount2 == 0 or amount == line.amount2 then q.progress = q.progress + 1 end
                elseif goal == "SPELL_DAMAGE" or goal == "SHUFFLE" then
                    if q.mark ~= once then
                        q.mark = once
                        q.progress = q.progress + 1
                    end
                elseif goal == "TURNS_IN_ROW" then
                    q.mark = s.turn   -- a matching card this turn: quest_turn_end counts the turn
                else
                    local mode = line.distinct
                    if mode == 0 or se == nil or sd == nil then
                        q.progress = q.progress + 1
                    elseif mode == 1 then
                        -- Of unique types: a minion brings one type not counted yet (an all-types minion, any one).
                        local tribes = D.RACE.ALL - 1
                        local types = bit.band(sd.races, D.RACE.ALL) ~= 0 and tribes or bit.band(sd.races, tribes)
                        local fresh = bit.band(types, bit.bnot(q.mask))
                        if fresh ~= 0 then
                            q.mask = bit.bor(q.mask, bit.band(fresh, bit.bnot(fresh) + 1))
                            q.progress = E.popcount(q.mask)
                        end
                    elseif mode == 2 then
                        -- Different cards, by name.
                        local seen = false
                        for _, name in ipairs(q.names) do if name == sd.name then seen = true end end
                        if not seen then
                            q.names[#q.names + 1] = sd.name
                            q.progress = #q.names
                        end
                    elseif mode == 3 or mode == 4 or mode == 5 then
                        -- A listed set: the Cost it was played for, the spell's school, the minion's Attack now.
                        local value
                        if mode == 3 then
                            if subject == self.last_paid_entity and self.last_paid_price >= 0 then
                                value = self.last_paid_price
                            elseif se.paid_price >= 0 then
                                value = se.paid_price
                            else
                                value = sd.cost
                            end
                        elseif mode == 4 then
                            value = sd.schoolNum
                        else
                            value = se.attack
                        end
                        if not (value < 0 or value > 30 or (mode == 4 and value == 0)) then
                            local b = bit.lshift(1, value)
                            if not (line.amount2 ~= 0 and bit.band(line.amount2, b) == 0) then
                                q.mask = bit.bor(q.mask, b)
                                q.progress = E.popcount(q.mask)
                            end
                        end
                    elseif mode == 6 then
                        -- With the same name: the most played of any one name.
                        q.names[#q.names + 1] = sd.name
                        local best = 0
                        for _, name in ipairs(q.names) do
                            local n = 0
                            for _, other in ipairs(q.names) do if other == name then n = n + 1 end end
                            best = math.max(best, n)
                        end
                        q.progress = best
                    end
                end
                if q.progress > before then
                    if not repeatable then q.progress = math.min(q.progress, target) end
                    self:note_quest("QUEST_PROGRESSED", q)
                end
            end
        end
    end
end


-- `index` is 1-based here (p.quests[index]).
function E:complete_quest(seat, index)
    local p = self.state.players[seat + 1]
    if index > #p.quests then return end
    local done = p.quests[index]
    local entity = done.entity
    local d = self:def_of(entity)
    local line = E.quest_line_of(d)
    if d == nil or line == nil then
        table.remove(p.quests, index)
        return
    end
    local kind = E.quest_kind_of(line.questKind)
    local goal = E.quest_goal_target(line)
    self:note_quest("QUEST_COMPLETED", done)
    p.quests_completed = p.quests_completed + 1
    local reward = line.token
    local nextStage = kind == E.QUEST_KIND_QUESTLINE and line.questNext or ""
    local doneStage, doneProgress = done.stage, done.progress
    -- The quest leaves its zone (a Repeatable Quest starts again, with any excess) BEFORE its reward.
    if kind == E.QUEST_KIND_REPEATABLE then
        local again = p.quests[index]
        again.progress = math.max(0, doneProgress - goal)
        again.mask = 0
        again.names = {}
        again.mark = -1
    else
        table.remove(p.quests, index)
        self:relocate(entity, ZONE.GRAVEYARD, -1)
    end
    -- The reward: a card to the hand (a full hand burns it), or a Hero Power card that replaces the player's own.
    if reward ~= "" then
        local r = D.def(reward)
        if r ~= nil then
            if r.type == "HERO_POWER" then
                self:replace_hero_power(seat, r)
            else
                local made = self:create_entity(r, seat, ZONE.HAND, -1)
                if #self:hand_ids(seat) > 10 then self:relocate(made, ZONE.GRAVEYARD, -1) end
            end
        end
    end
    local lines = false
    for _, fx in ipairs(d.effects) do lines = lines or fx.trigger == "QUEST_REWARD" end
    if lines and self:step_budget() then
        self:run_effects(entity, "QUEST_REWARD", 0, entity)
    end
    -- A Questline's next stage starts once this stage's reward is out: its own card, one stage on.
    if nextStage ~= "" then
        local stage = D.def(nextStage)
        if stage ~= nil and E.quest_line_of(stage) ~= nil then
            self:start_quest(seat, self:create_entity(stage, seat, ZONE.SETASIDE, -1), doneStage + 1)
        end
    end
end


function E:settle_quests()
    local s = self.state
    if s.pending.active or self:is_terminal() then return false end
    -- The goals a board or a hand reaches rather than an event.
    for _, seat in ipairs({ 0, 1 }) do
        for _, q in ipairs(s.players[seat + 1].quests) do
            local line = E.quest_line_of(self:def_of(q.entity))
            if line ~= nil then
                local goal = line.questGoal
                local before = q.progress
                if goal == "FULL_BOARD" and seat == s.active and s.phase == PHASE.PLAYER_ACTIONS
                    and q.mark ~= s.turn and self:board_size(seat) >= 7 then
                    q.mark = s.turn
                    q.progress = q.progress + 1
                end
                if goal == "FILL_THEN_EMPTY" then
                    local held = #self:hand_ids(seat)
                    if q.mark ~= 1 and held >= 10 then
                        q.mark = 1
                        q.progress = 1
                    elseif q.mark == 1 and held == 0 then
                        q.progress = 2
                    end
                end
                if q.progress > before then self:note_quest("QUEST_PROGRESSED", q) end
            end
        end
    end
    -- The quests that reached their goals, the active player's first: one at a time.
    for _, seat in ipairs({ s.active, 1 - s.active }) do
        local p = s.players[seat + 1]
        for i = 1, #p.quests do
            local line = E.quest_line_of(self:def_of(p.quests[i].entity))
            if line ~= nil and p.quests[i].progress >= E.quest_goal_target(line) then
                self:complete_quest(seat, i)
                return true
            end
        end
    end
    return false
end


function E:quest_turn_start()
    local s = self.state
    for _, seat in ipairs({ 0, 1 }) do
        for _, q in ipairs(s.players[seat + 1].quests) do
            local line = E.quest_line_of(self:def_of(q.entity))
            if line ~= nil then
                local goal = line.questGoal
                local before = q.progress
                -- "Draw 4 cards in one turn": each turn's count starts again, unless the goal is already reached.
                if goal == "DRAW" and line.temporary and q.progress < E.quest_goal_target(line) then q.progress = 0 end
                -- "Survive 10 turns": each of its player's turn starts.
                if goal == "SURVIVE_TURNS" and seat == s.active then q.progress = q.progress + 1 end
                if q.progress > before then self:note_quest("QUEST_PROGRESSED", q) end
            end
        end
    end
end


function E:quest_turn_end(seat)
    local s = self.state
    for _, side in ipairs({ 0, 1 }) do
        local p = s.players[side + 1]
        for _, q in ipairs(p.quests) do
            local line = E.quest_line_of(self:def_of(q.entity))
            if line ~= nil then
                local goal = line.questGoal
                local before = q.progress
                -- "Take no damage for a turn": a whole turn ended and the hero took none in it.
                if goal == "NO_DAMAGE_TURN" and q.mark < s.turn and not p.hero_took_damage_this_turn then
                    q.progress = math.max(q.progress, 1)
                end
                if side == seat then
                    -- "End 4 turns with any unspent Mana".
                    if goal == "UNSPENT_MANA" and p.mana > 0 then q.progress = q.progress + 1 end
                    -- "Play an Elemental 2 turns in a row": a turn without one starts the count again.
                    if goal == "TURNS_IN_ROW" then
                        q.progress = q.mark == s.turn and q.progress + 1 or 0
                    end
                end
                if q.progress > before then self:note_quest("QUEST_PROGRESSED", q) end
            end
        end
    end
end


-- Room for this quest card: true, or false and the error code ("E_QUEST_LIMIT" / "E_QUEST_DUPLICATE").
-- One Quest at a time, never two of the same Sidequest, five in all.
function E:quest_room(seat, card)
    local line = E.quest_line_of(card)
    if line == nil then return true end
    local p = self.state.players[seat + 1]
    if #p.quests >= 5 then return false, "E_QUEST_LIMIT" end
    local side = E.quest_kind_of(line.questKind) == E.QUEST_KIND_SIDEQUEST
    for _, q in ipairs(p.quests) do
        local e = self:ent(q.entity)
        local other = e ~= nil and E.quest_line_of(self:def_of(q.entity)) or nil
        if other ~= nil then
            if e.card_id == card.id then return false, side and "E_QUEST_DUPLICATE" or "E_QUEST_LIMIT" end
            if not side and E.quest_kind_of(other.questKind) ~= E.QUEST_KIND_SIDEQUEST then
                return false, "E_QUEST_LIMIT"
            end
        end
    end
    return true
end


function E:start_quest(seat, entity, stage)
    local e = self:ent(entity)
    local line = E.quest_line_of(self:def_of(entity))
    if e == nil or line == nil then return end
    local p = self.state.players[seat + 1]
    for _, q in ipairs(p.quests) do
        if q.entity == entity then return end
    end
    e.owner = seat
    e.controller = seat
    self:relocate(entity, ZONE.QUEST, -1)
    local quest = { entity = entity, progress = 0, stage = math.max(1, stage), mask = 0, names = {}, mark = -1 }
    -- "Take no damage for a turn" counts whole turns: the one it arrived in is not one of them.
    if line.questGoal == "NO_DAMAGE_TURN" then quest.mark = self.state.turn end
    p.quests[#p.quests + 1] = quest
    self:note_quest("QUEST_STARTED", quest)
end


-- How many Questline stages follow this card's (for the UI's "stage 1 of 3").
function E.quest_stages_after(cardId)
    local stages = 0
    local at = cardId
    for _ = 1, 8 do
        local line = E.quest_line_of(D.def(at))
        if line == nil or line.questNext == "" or E.quest_line_of(D.def(line.questNext)) == nil then break end
        at = line.questNext
        stages = stages + 1
    end
    return stages
end


-- (Goes before E:mark_dead / E:deal_damage, which call it.)
function E:forget_lethal_damage(id)
    local rows, kept = self.lethal_damage, {}
    for _, row in ipairs(rows) do
        if row[1] ~= id then kept[#kept + 1] = row end
    end
    self.lethal_damage = kept
end


-- (Goes after E:fire_pending.) "After a hero takes damage" raised by an effect's blow (deal_damage's `now` rows)
-- answers at the end of that hit, before the line carries on.
function E:answer_hero_damage()
    local q = self.pending_events
    local anyNow = false
    for _, ev in ipairs(q) do
        if ev.now then anyNow = true break end
    end
    if not anyNow then return end
    -- Three answers deep (two such cards answering each other's damage), the rest wait for the queue as they used to.
    if self.hero_answer_depth >= 3 then
        for _, ev in ipairs(q) do ev.now = false end
        return
    end
    local due, rest = {}, {}
    for _, ev in ipairs(q) do
        if ev.now then due[#due + 1] = ev else rest[#rest + 1] = ev end
    end
    self.pending_events = rest
    -- The line that dealt the hit carries on afterwards: its summon slot, what it made so far ("it"), its own index.
    local function copy(list)
        local out = {}
        for i, x in ipairs(list) do out[i] = x end
        return out
    end
    local summonPos, effectIndex, runningAbility = self.summon_pos, self.effect_index, self.running_ability
    local lastEffectCount, lastExcess, lastSummoned = self.last_effect_count, self.last_excess, self.last_summoned
    local summoned, copied = copy(self.summoned_this_effect), copy(self.copied_this_effect)
    local shuffled, buffed = copy(self.shuffled_this_effect), copy(self.buffed_this_effect)
    local drawn, discarded = copy(self.drawn_this_effect), copy(self.discarded_this_effect)
    self.hero_answer_depth = self.hero_answer_depth + 1
    for _, event in ipairs(due) do
        if self.aborted then break end
        local outerListeners, outerActive = self.event_listeners, self.event_active_at
        self.event_listeners = event.snapshot and event.listeners or nil
        self.event_active_at = event.active_at or -1
        self:fire_events(event.trigger, event.seat, event.subject, event.amount)
        self.event_listeners, self.event_active_at = outerListeners, outerActive
    end
    self.hero_answer_depth = self.hero_answer_depth - 1
    self.summon_pos, self.effect_index, self.running_ability = summonPos, effectIndex, runningAbility
    self.last_effect_count, self.last_excess, self.last_summoned = lastEffectCount, lastExcess, lastSummoned
    self.summoned_this_effect, self.copied_this_effect = summoned, copied
    self.shuffled_this_effect, self.buffed_this_effect = shuffled, buffed
    self.drawn_this_effect, self.discarded_this_effect = drawn, discarded
end


-- The seat whose turn an event belongs to: a queued event remembers the turn it was raised in (fire_pending).
-- Whose turn an event belongs to: an event raised during the other seat's queued turn (event_active_at) reads that
-- seat; otherwise the active one.
function E:turn_owner()
    return self.event_active_at >= 0 and self.event_active_at or self.state.active
end


function E.has_start_of_game(d)
    for _, fx in ipairs(d.effects) do
        if fx.trigger == "START_OF_GAME" then return true end
    end
    return false
end


-- Run 16: each starting deck's Start of Game lines, after both mulligans and before the first turn: the first seat's
-- cards first, in deal order (entity id order).
function E:start_of_game()
    local s = self.state
    local first = s.active
    for _, seat in ipairs({ first, 1 - first }) do
        local dealt = {}
        for id = 1, s.next_entity_id - 1 do
            local e = s.entities[id]
            if e and e.owner == seat and (e.zone == ZONE.DECK or e.zone == ZONE.HAND) and not e.flags.created_by_effect then
                local d = def(e.card_id)
                if d and E.has_start_of_game(d) then dealt[#dealt + 1] = id end
            end
        end
        for _, id in ipairs(dealt) do
            local e = self:ent(id)
            -- An earlier line took it out of the deck and the hand (or changed whose it is): it has no Start of Game.
            if e and e.owner == seat and (e.zone == ZONE.DECK or e.zone == ZONE.HAND) then
                local d = self:def_of(id)
                if d and E.has_start_of_game(d) then
                    if not self:step_budget() then return end
                    local effects = {}
                    for _, fx in ipairs(d.effects) do
                        if fx.trigger == "START_OF_GAME" then effects[#effects + 1] = fx end
                    end
                    self.start_of_game_running = true
                    self:run_effect_list(effects, id, "START_OF_GAME", 0, id, nil)
                    self.start_of_game_running = false
                    if self.aborted then return end
                end
            end
        end
    end
end


-- A scratch copy of the whole engine (TcEngine's copy constructor): the state and every member, the observer log
-- left behind. A probe is thrown away, so nothing it does reaches this match.
-- Members that are pointers in the C++ (to an effect, a card, a list being run) are shared, as a copied pointer is;
-- every other member table is plain data and copied.
local SHARED_MEMBERS = { draw_fx = true, replay_lines = true, replay_card = true, event_listeners = true,
    event_summon_chain = true }
function E:probe_copy()
    local copy = setmetatable({}, E)
    for k, v in pairs(self) do
        if k == "events" then
            copy[k] = nil
        elseif type(v) == "table" and not SHARED_MEMBERS[k] then
            copy[k] = E.deepCopy(v)
        else
            copy[k] = v
        end
    end
    copy.scratch = true
    return copy
end


-- The members apply_action clears at the start of every action, and no others: the rest live on across actions as
-- the C++ engine's members do (a search copy and a probe copy carry them too). resetTransient stays the
-- constructor's full initialisation.
function E:reset_action(a)
    self.aborted = false
    self.summon_pos = -1
    self.last_drawn = 0
    self.last_summoned = 0
    self.drawn_this_effect = {}
    self.discarded_this_effect = {}
    self.summoned_this_effect = {}
    self.stealth_attackers = {}
    self.attacking_weapon = 0
    self.running_ability = -1
    self.fatigue_kill = { false, false }
    self.state.loop_steps = 0
    self.pending_attack = 0
    self.broken_weapon = 0
    self.pending_events = {}
    self.pending_self_events = {}
    self.effect_source = 0
    self.beside_count = {}
    self.far_right_summons = false
    self.titan_last = 0
    self.titan_last_index = -1
    -- "That many" and "the excess" belong to the effect before, in the same action; a choice's answer continues the
    -- action that asked it, and keeps them.
    if a.type ~= "resolve" then
        self.last_effect_count = 0
        self.last_excess = 0
    end
end


-- The counts that read what a player did this game through the effect's own filter.
local HISTORY_COUNTS = { HISTORY_PLAYED = true, HISTORY_MANA_SPENT = true, HISTORY_DISTINCT_TYPES = true,
    GAME_NAMED_DIED = true }
function E.is_history_count(count)
    return HISTORY_COUNTS[count] == true
end

E.u32 = u32
