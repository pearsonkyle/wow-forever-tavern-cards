-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Scenario checks for cards the differential sweep (tests/sweep.py) can't reach in a real game:
-- their cost is above the 10-mana cap unless something else lowers it. Each puts the card in hand with
-- the mana it needs, plays it, and checks the printed effect.
local T = {}
local band = bit.band

local function newGame(TC, classA, classB)
    local E, D = TC.Engine, TC.EngineDefs
    local a = TC.AI.buildDeck(classA, 3, 3)
    local b = TC.AI.buildDeck(classB, 4, 4)
    local eng = assert(E.create(a, b, { 11, 22 }))
    eng:set_class(0, classA)
    eng:set_class(1, classB)
    eng:set_hero_power(0, E.heroPowerFor(classA))
    eng:set_hero_power(1, E.heroPowerFor(classB))
    -- Keep both opening hands.
    while eng.state.phase == D.PHASE.MULLIGAN do
        for i, m in ipairs(eng:legal_moves()) do
            if m.desc == "Keep all cards" then assert(eng:apply_move(i)) break end
        end
    end
    return eng, D
end

local function give(eng, D, seat, id)
    return eng:create_entity(D.def(id), seat, D.ZONE.HAND, -1)
end

local function play(eng, id)
    for i, m in ipairs(eng:legal_moves()) do
        if m.action == "play" and m.raw.entity == id then
            assert(eng:apply_move(i), "play refused: " .. tostring(eng.last_error))
            return true
        end
    end
    return false
end

local function endTurn(eng)
    for i, m in ipairs(eng:legal_moves()) do
        if m.action == "end_turn" then return eng:apply_move(i) end
    end
end

T.carrier_summons_four_interceptors_at_end_of_turn = function(TC)
    local eng, D = newGame(TC, "DRUID", "WARRIOR")
    local seat = eng.state.active
    local carrier = give(eng, D, seat, "SC_756")
    local p = eng:player(seat)
    p.mana, p.max_mana = 12, 10
    assert(eng:card_cost(seat, carrier) == 12)
    assert(play(eng, carrier), "Carrier should be playable with 12 mana")
    assert(eng:ent(carrier).zone == D.ZONE.BOARD)
    local before = eng.state.next_entity_id
    endTurn(eng)
    local made = 0
    for id = before, eng.state.next_entity_id - 1 do
        local e = eng:ent(id)
        if e and e.card_id == "SC_756t" then made = made + 1 end
    end
    assert(made == 4, "four Interceptors, got " .. made)
end

T.playhouse_giant_costs_less_per_card_drawn = function(TC)
    local eng, D = newGame(TC, "MAGE", "PRIEST")
    local seat = eng.state.active
    local giant = give(eng, D, seat, "TOY_530")
    local p = eng:player(seat)
    local drawn = p.game_cards_drawn
    assert(eng:card_cost(seat, giant) == math.max(0, 25 - drawn), "cost = 25 - cards drawn")
    p.game_cards_drawn = 17
    assert(eng:card_cost(seat, giant) == 8)
    p.mana = 8
    assert(play(eng, giant), "Playhouse Giant should be playable at 8 after 17 draws")
    local e = eng:ent(giant)
    assert(e.zone == D.ZONE.BOARD and e.attack == 8 and e.health == 8)
end

-- Cards the differential sweep never saw played (tests/sweep.py --never): checked against their text here.
T.divination_destroys_a_wisp_to_draw_three = function(TC)
    local eng, D = newGame(TC, "MAGE", "WARRIOR")
    local seat = eng.state.active
    local wisp = eng:summon_token("CS2_231", seat, -1, false)
    local spell = give(eng, D, seat, "EDR_804")
    eng:player(seat).mana = 10
    local hand = #eng:hand_ids(seat)
    assert(play(eng, spell), "Divination should be castable on a friendly Wisp")
    if eng.state.pending.active then
        for i, m in ipairs(eng:legal_moves()) do if m.raw.target == wisp or m.raw.chosen == wisp then eng:apply_move(i) break end end
    end
    assert(eng:ent(wisp).zone ~= D.ZONE.BOARD, "the Wisp is destroyed")
    assert(#eng:hand_ids(seat) == hand - 1 + 3, "three cards drawn")
end

T.mothership_gets_two_protoss_minions_twice = function(TC)
    local eng, D = newGame(TC, "PRIEST", "WARRIOR")
    local seat = eng.state.active
    local ship = give(eng, D, seat, "SC_762")
    eng:player(seat).mana, eng:player(seat).max_mana = 12, 10
    local before = {}
    for _, id in ipairs(eng:hand_ids(seat)) do before[id] = true end
    assert(play(eng, ship), "Mothership should be playable with 12 mana")
    local function protossGained()
        local n = 0
        for _, id in ipairs(eng:hand_ids(seat)) do
            local d = eng:def_of(id)
            if not before[id] and d and d.type == "MINION" and D.cardIsNamed(d, "Protoss", true) then n = n + 1 end
            before[id] = true
        end
        return n
    end
    assert(protossGained() == 2, "Battlecry: two Protoss minions")
    assert(band(eng:ent(ship).keywords, D.KW.TAUNT) ~= 0, "Taunt")
    eng:deal_damage(ship, 99, 0, false)
    eng:resolve_deaths()
    assert(protossGained() == 2, "Deathrattle: two more")
end

T.ultragigasaur_is_a_fourteen_twenty_eight = function(TC)
    local eng, D = newGame(TC, "HUNTER", "WARRIOR")
    local seat = eng.state.active
    local saur = give(eng, D, seat, "TLC_248")
    eng:player(seat).mana = 11
    assert(eng:card_cost(seat, saur) == 11)
    assert(play(eng, saur))
    local e = eng:ent(saur)
    assert(e.zone == D.ZONE.BOARD and e.attack == 14 and e.health == 28)
end

T.shirvallah_costs_less_for_mana_spent_on_spells = function(TC)
    local eng, D = newGame(TC, "PALADIN", "WARRIOR")
    local seat = eng.state.active
    local tiger = give(eng, D, seat, "TRL_300")
    local start = eng:card_cost(seat, tiger)
    local spell = give(eng, D, seat, "CS2_092")   -- Blessing of Kings, (4)
    eng:player(seat).mana = 10
    eng:summon_token("CS2_231", seat, -1, false)   -- a minion for the Blessing
    assert(play(eng, spell), "a spell to spend mana on")
    if eng.state.pending.active then eng:apply_move(1) end
    assert(eng:card_cost(seat, tiger) == start - 4, ("4 mana on a spell takes 4 off: %d -> %d"):format(start,
        eng:card_cost(seat, tiger)))
end

-- A deck down to Corrupted Blood (casts when drawn, 3 damage to its owner, shuffles two copies in) ends the game
-- when its drawer dies, instead of drawing forever until E_LOOP (jankcraft 94067d016, draw_replacement).
T.corrupted_blood_ends_the_game_instead_of_looping = function(TC)
    local eng, D = newGame(TC, "WARRIOR", "WARRIOR")
    local seat = eng.state.active
    local foe = 1 - seat
    for _, id in ipairs(eng:deck_ids(foe)) do eng:relocate(id, D.ZONE.GRAVEYARD, -1) end
    eng:create_entity(D.def("TRL_541t"), foe, D.ZONE.DECK, -1)
    eng:hero_of(foe).health = 10
    assert(endTurn(eng), "ending the turn is no longer refused: " .. tostring(eng.last_error))
    assert(eng:is_terminal(), "the Corrupted Blood player dies, and the game is over")
    assert(eng.state.result.winner == seat, "they are the one beaten")
end

-- "Battlecry: If you control another Murloc, deal 2 damage" (South Coast Chieftain) asks for a target only when
-- the player controls another Murloc (jankcraft: card_choose_targets_for).
T.south_coast_chieftain_targets_only_with_another_murloc = function(TC)
    local eng, D = newGame(TC, "SHAMAN", "WARRIOR")
    local seat = eng.state.active
    for _, id in ipairs(eng:board_ids(seat)) do eng:relocate(id, D.ZONE.GRAVEYARD, -1) end
    local chief = give(eng, D, seat, "BAR_040")
    eng:player(seat).mana = 10
    local function targeted()
        local any, aimed = false, false
        for _, m in ipairs(eng:legal_moves()) do
            if m.action == "play" and m.raw.entity == chief then
                any = true
                aimed = aimed or (m.raw.target or 0) ~= 0
            end
        end
        assert(any, "the Chieftain is playable")
        return aimed
    end
    assert(not targeted(), "no other Murloc: played without a target")
    eng:summon_token("CS2_168", seat, -1, false)   -- Murloc Raider
    assert(targeted(), "another Murloc: it asks for a target")
end

-- "Combo: Deal 3 damage" (Rite of Twilight) asks for a target only once a card was played earlier this turn.
T.combo_spell_targets_only_after_another_card = function(TC)
    local eng, D = newGame(TC, "ROGUE", "WARRIOR")
    local seat = eng.state.active
    local rite = give(eng, D, seat, "CATA_785")
    local wisp = give(eng, D, seat, "CS2_231")
    eng:player(seat).mana = 10
    eng:player(seat).cards_played_this_turn = 0
    local function targeted()
        local any, aimed = false, false
        for _, m in ipairs(eng:legal_moves()) do
            if m.action == "play" and m.raw.entity == rite then
                any = true
                aimed = aimed or (m.raw.target or 0) ~= 0
            end
        end
        assert(any, "Rite of Twilight is castable")
        return aimed
    end
    assert(not targeted(), "first card of the turn: no Combo, no target")
    assert(play(eng, wisp), "a card first")
    assert(targeted(), "Combo now: it asks for a target")
end

return T
