-- Scenario checks for cards the differential sweep (tests/sweep.py) can't reach in a real game:
-- their cost is above the 10-mana cap unless something else lowers it. Each puts the card in hand with
-- the mana it needs, plays it, and checks the printed effect.
local T = {}

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

return T
