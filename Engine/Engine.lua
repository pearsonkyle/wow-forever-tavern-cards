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
        twin_copy = false,
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
    }
end

local function newPending()
    return {
        active = false, seat = 0, options = {}, card_options = {}, kind = "", dark_gift = false, summon = false,
        others_to_hand = false, guess_copy = false, chain = false, cost_delta = 0, temporary = false,
        resume = false, source = 0, trigger = "ON_PLAY", effect_index = -1, event_subject = 0, chosen = -1,
        previous_targets = {}, from_deck = false, ability = -1, then_on_play = false, resume_same = false,
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
            self:create_entity(def(id), seat, ZONE.DECK, i - 1)
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
    if not e or e.flags.silenced then return false end
    if anyDeathrattle(self:def_of(id)) then return true end
    for _, cid in ipairs(e.magnetized) do
        if anyDeathrattle(def(cid)) then return true end
    end
    for _, g in ipairs(e.granted) do
        local gd = def(g.card_id)
        local fx = gd and gd.effects[g.index + 1]
        if fx then
            for _, follow in ipairs(fx.followUp) do
                if follow.trigger == "DEATHRATTLE" then return true end
            end
        end
    end
    return false
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
    self:queue("WHEN_SUMMON_MINION", controller, id)
    self:queue("AFTER_SUMMON_MINION", controller, id)
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
    e.flags.attacks_this_turn = 0
    if d and d.dormant_turns > 0 then
        e.flags.dormant_turns = d.dormant_turns
        e.flags.exhausted = true
    end
    e.flags.just_played_turn = self.state.turn
    self:emit_event("SUMMONED", id, 0)
    self:queue("WHEN_SUMMON_MINION", controller, id)
    self:queue("AFTER_SUMMON_MINION", controller, id)
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
    end
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        local d = def(e.card_id)
        e.spell_damage = (not d or e.flags.silenced) and 0 or d.spell_damage
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
        for _, srcId in ipairs(sources) do
            local src = self:ent(srcId)
            local sd = src and not src.flags.silenced and self:def_of(srcId)
            if sd then
                for _, fx in ipairs(sd.effects) do
                    if fx.trigger == "AURA" and not fx.printOnly
                        and (fx.op == "BUFF" or fx.op == "GIVE_KEYWORD" or fx.op == "BUFF_NAMED")
                        and not (fx.amount == 0 and fx.amount2 == 0 and fx.keywordBits == 0)
                        and self:condition_holds(fx, src.controller, srcId) then
                        local selfAura = fx.target.kind == "SELF" or fx.target.kind == "TRIGGER_SOURCE"
                        local skip = (selfAura and fx.damagedOnly and src.health >= src.max_health)
                            or (fx.whileAttacking and srcId ~= self.attacking_now)
                        if not skip then
                            if fx.op == "BUFF_NAMED" then
                                local name = fx.tokenDisplay
                                if not fx.namedAnywhere and name ~= "" and name:sub(-1) == "s" then
                                    name = name:sub(1, -2)
                                end
                                local named = self:board_ids(src.controller)
                                if fx.namedAnywhere then
                                    for _, z in ipairs({ self:hand_ids(src.controller), self:deck_ids(src.controller) }) do
                                        for _, x in ipairs(z) do named[#named + 1] = x end
                                    end
                                end
                                for _, t in ipairs(named) do
                                    local td = self:def_of(t)
                                    if td and td.name == name then
                                        self:apply_aura_buff(t, fx.amount, fx.amount2, fx.keywordBits, sd.id)
                                    end
                                end
                            else
                                local counted = fx
                                if fx.countSelector or fx.amountSource ~= "NONE" or fx.costCount ~= "NONE" then
                                    counted = self:scaled_effect(fx, src.controller, srcId)
                                end
                                local targets
                                if selfAura and fx.target.side == "YOUR_HERO" then
                                    local hero = self:hero_of(src.controller)
                                    targets = hero and { hero.id } or {}
                                elseif selfAura then
                                    targets = { srcId }
                                else
                                    targets = self:resolve_targets(fx, srcId, 0, srcId, src.controller)
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
    for _, id in ipairs(self:board_ids(seat)) do
        local e = self:ent(id)
        if e then
            total = total + e.spell_damage
            local d = not e.flags.silenced and self:def_of(id)
            if d then
                for _, fx in ipairs(d.effects) do
                    if fx.op == "SPELL_DAMAGE_AURA" and fx.trigger == "AURA" and not fx.printOnly
                        and not (fx.damagedOnly and e.health >= e.max_health)
                        and self:condition_holds(fx, e.controller, id) then
                        total = total + (fx.amountSource ~= "NONE" and self:scaled_effect(fx, e.controller, id).amount
                            or fx.amount)
                    end
                end
            end
        end
    end
    return total
end

function E:ready_if_charged(e)
    if e.zone ~= ZONE.BOARD or not e.flags.exhausted or e.flags.dormant_turns > 0 then return end
    if band(e.keywords, KW.CHARGE) ~= 0 and e.flags.attacks_this_turn == 0 then
        e.flags.exhausted = false
    elseif band(e.keywords, KW.RUSH) ~= 0 and e.flags.just_played_turn == self.state.turn
        and e.flags.attacks_this_turn == 0 then
        e.flags.exhausted = false
    end
end

function E:summon_attacks(attacker, mode)
    local a = self:ent(attacker)
    if not a or a.zone ~= ZONE.BOARD then return end
    local side = a.controller
    local function alive(id)
        local e = self:ent(id)
        return e ~= nil and not e.flags.dead and e.health > 0 and (e.zone == ZONE.BOARD or e.zone == ZONE.HERO)
    end
    if mode == 4 then
        for _, id in ipairs(self:board_ids(side)) do
            local me = self:ent(attacker)
            if not me or me.flags.dead or me.health <= 0 or me.zone ~= ZONE.BOARD or self.aborted then
                return
            end
            if id ~= attacker and self:ent(id) and not self:is_location(id) and alive(id) then
                self:resolve_attack(attacker, id)
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
    self:resolve_attack(attacker, pool[self.state.rng:intBelow(#pool) + 1])
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
    end
end

function E:apply_buff(id, attack, health, keyword, temporary, source, turns)
    local e = self:ent(id)
    if not e then return end
    if e.zone == ZONE.HERO and attack > 0 then
        local p = self:player(e.owner)
        p.hero_attack_gained_this_turn = p.hero_attack_gained_this_turn + attack
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
    e.keywords = bor(e.keywords, keyword)
    if band(keyword, KW.DIVINE_SHIELD) ~= 0 then e.flags.divine_shield = true end
    if band(keyword, KW.STEALTH) ~= 0 then e.flags.stealth = true end
    if band(keyword, KW.IMMUNE) ~= 0 then e.flags.immune = true end
    self:ready_if_charged(e)
    e.buffs[#e.buffs + 1] = { attack = attack, health = health, keyword = keyword, temporary = temporary and true or false,
        turns_remaining = turns or 0, from_aura = false, source = source or "" }
end

function E:apply_aura_buff(id, attack, health, keyword, source)
    local e = self:ent(id)
    if not e then return end
    e.attack = e.attack + attack
    e.max_health = e.max_health + health
    e.health = e.health + health
    e.keywords = bor(e.keywords, keyword)
    self:ready_if_charged(e)
    if band(keyword, KW.DIVINE_SHIELD) ~= 0 then e.flags.divine_shield = true end
    if band(keyword, KW.STEALTH) ~= 0 then e.flags.stealth = true end
    if band(keyword, KW.FREEZE) ~= 0 then e.flags.frozen = true end
    if band(keyword, KW.IMMUNE) ~= 0 then e.flags.immune = true end
    e.buffs[#e.buffs + 1] = { attack = attack, health = health, keyword = keyword, temporary = false,
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
        if e.owner == seat then
            local i = 1
            while i <= #e.buffs do
                local b = e.buffs[i]
                if b.turns_remaining <= 0 then
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
    e.flags.frozen = true
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
    self:relocate(id, ZONE.GRAVEYARD, -1)
    local p = self:player(seat)
    p.game_cards_discarded = p.game_cards_discarded + 1
    self:emit_event("DISCARDED", id, 0)
    self:queue("AFTER_DISCARD", seat, id)
end

function E:mark_dead(id)
    local e = self:ent(id)
    if not e then return end
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
function E:emit_event(kind, subject, source, amount)
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
        return 0
    end
    if t.zone == ZONE.HERO then
        local hp = self:player(t.owner)
        hp.hero_took_damage_this_turn = true
        hp.hero_damage_taken_this_turn = hp.hero_damage_taken_this_turn + amount
        hp.hero_health_changed_this_turn = true
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
    if t.health <= 0 and t.zone == ZONE.BOARD then t.flags.dead = true end
    if lost > 0 and t.zone == ZONE.BOARD then
        self:queue("SELF_TAKES_DAMAGE", t.owner, target, lost)
    end
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
        end
        if band(srcKeywords, KW.FREEZE) ~= 0 and isCharacter(t) and remaining > 0 then
            self:freeze_entity(target)
        end
        if band(srcKeywords, KW.LIFESTEAL) ~= 0 and remaining + absorbed > 0 then
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
    for _, each in ipairs(s.players) do
        each.armor_gained_this_turn = 0
        each.hero_attack_gained_this_turn = 0
    end
    s.turn = s.turn + 1
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
    self:run_persistent(s.active, "START_TURN", false)
    self:run_trigger(s.active, "START_TURN")
    self:run_each_turn("START_EACH_TURN")
    self:draw_card(s.active)
end

function E:end_turn_cleanup()
    local s = self.state
    local seat = s.active
    local hero = self:hero_of(seat)
    if hero then self:emit_event("TURN_ENDED", hero.id, 0) end
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
    if p.next_card_cost_this_turn then
        p.next_card_cost_delta = 0
        p.next_card_cost_filter = 0
        p.next_card_cost_school = 0
        p.next_card_cost_race = 0
        p.next_card_cost_keyword = 0
        p.next_card_cost_this_turn = false
    end
    if p.hero_power_once_this_turn then
        p.hero_power_cost_once = 0
        p.hero_power_free_once = false
        p.hero_power_damage_once = 0
        p.hero_power_once_this_turn = false
    end
    p.heal_as_damage_this_turn = false
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
                self:fire_events(ev.trigger, ev.seat, ev.subject, ev.amount)
            end
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
            owner.game_minions_died = owner.game_minions_died + 1
            self:emit_event("DIED", e.id, 0)
            self:queue("AFTER_FRIENDLY_MINION_DIES", e.owner, e.id)
            for _, handId in ipairs(self:hand_ids(e.owner)) do
                local he = self:ent(handId)
                if he and he.zone == ZONE.HAND then
                    he.flags.infuse_progress = he.flags.infuse_progress + 1
                end
            end
            self:relocate(e.id, ZONE.GRAVEYARD, -1)
        end
        self.removing_dead = false

        for _, e in ipairs(dead) do
            local id = e.id
            if not e.flags.silenced then
                local d = self:def_of(id)
                if d then
                    local hasDeathrattle = anyDeathrattle(d)
                    for _, cid in ipairs(e.magnetized) do
                        if anyDeathrattle(def(cid)) then hasDeathrattle = true end
                    end
                    local grants = {}
                    for i, g in ipairs(e.granted) do grants[i] = g end
                    if hasDeathrattle or #grants > 0 then
                        if not self:step_budget() then return false end
                        self.summon_pos = lastPosition[id]
                        self.dying_pos = lastPosition[id]
                        if hasDeathrattle then
                            self:run_effects(id, "DEATHRATTLE", 0, id)
                        end
                        for _, g in ipairs(grants) do
                            local giver = def(g.card_id)
                            local fx = giver and g.index >= 0 and giver.effects[g.index + 1]
                            if fx then
                                self:run_effect_list(fx.followUp, id, "DEATHRATTLE", 0, id, nil)
                                if self.aborted then break end
                            end
                        end
                        self.summon_pos = -1
                        self.dying_pos = -1
                        if self.aborted then return false end
                    end
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

function E:cast_when_drawn(id)
    local drawn = self:ent(id)
    if not drawn then return true end
    local own = self:def_of(id)
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
        if not casts then return true end
        self:run_effect_list(shuffling.effects, id, "CAST_WHEN_DRAWN", -1, 0, nil)
    end
    if self.aborted then return false end
    self:relocate(id, ZONE.GRAVEYARD, -1)
    return true
end

function E:draw_card(seat, typeFilter, costMin, costMax, raceFilter, schoolFilter, keywordFilter)
    typeFilter, costMin, costMax = typeFilter or 0, costMin or 0, costMax or 0
    raceFilter, schoolFilter, keywordFilter = raceFilter or 0, schoolFilter or 0, keywordFilter or 0
    local s = self.state
    local p = self:player(seat)
    if typeFilter ~= 0 or costMin ~= 0 or costMax ~= 0 or raceFilter ~= 0 or schoolFilter ~= 0 or keywordFilter ~= 0 then
        local order = self:deck_ids(seat)
        local found
        for i, id in ipairs(order) do
            local e = self:ent(id)
            local d = e and def(e.card_id)
            if d and E.card_matches_filters(d, typeFilter, costMin, costMax, raceFilter, 0, 0, schoolFilter)
                and (keywordFilter == 0 or band(d.keywords, keywordFilter) == keywordFilter) then
                found = i
                break
            end
        end
        if not found then return end
        local taken = order[found]
        p.cards_drawn_this_turn = p.cards_drawn_this_turn + 1
        if #self:hand_ids(seat) >= 10 then
            self:relocate(taken, ZONE.GRAVEYARD, -1)
        else
            self:relocate(taken, ZONE.HAND, -1)
            local drawn = self:ent(taken)
            if drawn then drawn.flags.drawn_this_turn = true end
            if not self:cast_when_drawn(taken) then return end
            self.last_drawn = taken
            self.drawn_this_effect[#self.drawn_this_effect + 1] = taken
        end
        self:emit_event("DRAWN", taken, 0)
        self:queue("AFTER_DRAW", seat, taken)
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
    local id = deck[1]
    p.cards_drawn_this_turn = p.cards_drawn_this_turn + 1
    if #self:hand_ids(seat) >= 10 then
        self:relocate(id, ZONE.GRAVEYARD, -1)
    else
        self:relocate(id, ZONE.HAND, -1)
        local drawn = self:ent(id)
        if drawn then drawn.flags.drawn_this_turn = true end
        if not self:cast_when_drawn(id) then return end
        self.last_drawn = id
        self.drawn_this_effect[#self.drawn_this_effect + 1] = id
    end
    self:emit_event("DRAWN", id, 0)
    self:queue("AFTER_DRAW", seat, id)
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

E.u32 = u32
