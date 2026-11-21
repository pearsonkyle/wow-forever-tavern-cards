-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).

local T = {}

-- Bytewise "a < b", independent of the host locale (what std::string and the exporter use).
local function byteLess(a, b)
    local n = math.min(#a, #b)
    for i = 1, n do
        local x, y = a:byte(i), b:byte(i)
        if x ~= y then
            return x < y
        end
    end
    return #a < #b
end

T.card_order_is_engine_order = function(TC)
    local order = TC.CardOrder
    assert(#order > 3000, "expected the full engine card set, got " .. #order)
    for i = 2, #order do
        assert(byteLess(order[i - 1], order[i]), "out of order at " .. i .. ": " .. order[i - 1] .. " / " .. order[i])
    end
end

T.playable_cards_have_programs = function(TC)
    local playable = 0
    for id, card in pairs(TC.Cards) do
        if bit.band(card.flags, 8) ~= 0 then
            playable = playable + 1
            assert(TC.Programs[id], "playable card without a program: " .. id)
        end
    end
    assert(playable == 4569, "expected 4569 playable cards, got " .. playable)
end

T.known_cards = function(TC)
    local fireball = TC.Cards.CS2_029
    assert(fireball.name == "Fireball" and fireball.cost == 4 and fireball.type == "SPELL")
    local fx = TC.Programs.CS2_029.effects[1]
    assert(fx.op == "DAMAGE" and fx.amount == 6 and fx.target.kind == "CHOOSE" and fx.spell == true)

    local leeroy = TC.Cards.EX1_116
    assert(leeroy.attack == 6 and leeroy.health == 2 and leeroy.rarity == "LEGENDARY")
    assert(bit.band(leeroy.keywords, 2) ~= 0, "Leeroy has Charge")
    local summon = TC.Programs.EX1_116.effects[1]
    assert(summon.forOpponent and summon["repeat"] == 2 and TC.Cards[summon.token], "Whelp token is exported")
end

T.coin_is_exported = function(TC)
    local coin
    for _, id in ipairs(TC.CardOrder) do
        if TC.Cards[id].name == "The Coin" then
            coin = TC.Cards[id]
        end
    end
    assert(coin and coin.cost == 0 and TC.Programs[coin.id], "The Coin must be in the engine data")
end

-- Every minion stands on the board as something of the game: a creature (by id or model) or a prop.
T.every_minion_has_a_model = function(TC)
    local missing = {}
    for _, id in ipairs(TC.CardOrder) do
        if TC.Cards[id].type == "MINION" and not (TC.CardModels[id] or TC.CardDisplays[id] or TC.CardProps[id]) then
            missing[#missing + 1] = id
        end
    end
    assert(#missing == 0, #missing .. " minions without a model: " .. table.concat(missing, " ", 1, math.min(#missing, 10)))
end

return T
