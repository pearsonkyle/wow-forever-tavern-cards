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
-- Imbue (imbue.cpp): the Imbued Hero Powers and what each Imbue does.

local TC = TavernCards_NS
local D = TC.EngineDefs
local E = TC.Engine
local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local min, max = math.min, math.max
local ZONE, KW, RACE = D.ZONE, D.KW, D.RACE
local def = D.def
local other = E.other

-- imbue.h: the Imbued Hero Powers, after the basic ones (1 to 11).
E.IMBUED_GOLEM, E.IMBUED_WOLF, E.IMBUED_WISP, E.IMBUED_DRAGON = 21, 22, 23, 24
E.IMBUED_MOON, E.IMBUED_WIND, E.IMBUED_BRONZE, E.IMBUED_INFINITE = 25, 26, 27, 28
E.IMBUE_PLANT_GOLEM = "EDR_847pt2"
E.IMBUE_WISP = "EDR_851t"
E.IMBUE_PORTAL = "EDR_445pt3"
local FAMILY = D.FAMILY
E.IMBUED_POWERS = {
    { family = FAMILY.DRUID, id = 21, card_id = "EDR_847p", name = "Blessing of the Golem", cost = 2, passive = false, targeted = false },
    { family = FAMILY.HUNTER, id = 22, card_id = "EDR_850p", name = "Blessing of the Wolf", cost = 2, passive = false, targeted = false },
    { family = FAMILY.MAGE, id = 23, card_id = "EDR_851p", name = "Blessing of the Wisp", cost = 2, passive = false, targeted = false },
    { family = FAMILY.PALADIN, id = 24, card_id = "EDR_445p", name = "Blessing of the Dragon", cost = 1, passive = false, targeted = false },
    { family = FAMILY.PRIEST, id = 25, card_id = "EDR_449p", name = "Blessing of the Moon", cost = 2, passive = false, targeted = false },
    { family = FAMILY.SHAMAN, id = 26, card_id = "EDR_448p", name = "Blessing of the Wind", cost = 2, passive = false, targeted = true },
    { family = FAMILY.ROGUE, id = 27, card_id = "END_000p", name = "Blessing of the Bronze", cost = 1, passive = false, targeted = false },
    { family = FAMILY.DEATHKNIGHT, id = 28, card_id = "END_003p", name = "Blessing of the Infinite", cost = 0, passive = true, targeted = false },
}

function E.imbued_power(id)
    for _, power in ipairs(E.IMBUED_POWERS) do
        if power.id == id then return power end
    end
    return nil
end

function E.imbued_power_for(family)
    for _, power in ipairs(E.IMBUED_POWERS) do
        if power.family == family then return power end
    end
    return nil
end

-- The power's number at a count: the count itself, and never below one.
function E.imbue_level(count)
    return count < 1 and 1 or count
end

local function articleStats(n)
    local stats = n .. "/" .. n
    local an = n == 8 or n == 11 or n == 18 or (n >= 80 and n <= 89)
    return (an and "an " or "a ") .. stats
end
function E.imbued_power_text(id, level)
    local n = tostring(level)
    if id == 21 then
        return "Summon " .. articleStats(level) .. " Plant Golem."
    elseif id == 22 then
        return "A random Beast in your hand gets +" .. n .. " Attack and costs (" .. n .. ") less."
    elseif id == 23 then
        return "Summon " .. n .. (level == 1 and " Wisp" or " Wisps") .. ", then deal " .. n
            .. " damage split at random among your enemies."
    elseif id == 24 then
        return "Shuffle two Emerald Portals into your deck. A Portal you draw summons a random " .. n .. "-Cost Dragon."
    elseif id == 25 then
        return "Pick one of three Priest minions or spells to add to your hand. It costs (" .. n
            .. ") less, and leaves your hand when your turn ends."
    elseif id == 26 then
        return "Transform a friendly minion into a random one that costs (" .. n .. ") more."
    elseif id == 27 then
        return "Add a random minion from another class to your hand. It costs (" .. n .. ") less."
    elseif id == 28 then
        return "Passive. The first Undead you play each turn gets +" .. n .. " Attack."
    end
    return ""
end

-- "Imbue your Hero Power (twice)(, then trigger it)".
function E:imbue(seat, times, trigger, source)
    local p = self.state.players[seat + 1]
    p.imbue_count = p.imbue_count + math.max(1, times)
    -- The first Imbue gives a class its Imbued power; a later one only raises the number.
    local imbued = E.imbued_power_for(p.hero_class)
    if imbued ~= nil then p.hero_power_id = imbued.id end
    -- ", then trigger it": the power as it is now, free. (The IMBUED wire entry is reference-only.)
    if trigger then self:trigger_hero_power(seat) end
end

function E:run_imbued_power(power, seat, target, bonus)
    local s = self.state
    local p = s.players[seat + 1]
    local n = E.imbue_level(p.imbue_count)
    local hero = self:hero_of(seat)
    local heroId = hero ~= nil and hero.id or 0
    local imbued = E.imbued_power(power)
    local powerCard = imbued ~= nil and imbued.card_id or ""
    if power == E.IMBUED_GOLEM then
        -- An N/N Plant Golem: the token's numbers are the count.
        local made = self:summon_token(E.IMBUE_PLANT_GOLEM, seat, -1, false)
        local golem = self:ent(made)
        if golem ~= nil then
            golem.attack = n
            golem.max_health = n
            golem.health = n
        end
    elseif power == E.IMBUED_WOLF then
        -- A random Beast in the hand: +N Attack, and N off its Cost.
        local beasts = {}
        for _, id in ipairs(self:hand_ids(seat)) do
            local d = self:def_of(id)
            if d ~= nil and d.type == "MINION" and D.hasRace(d.races, D.RACE.beast) then beasts[#beasts + 1] = id end
        end
        if #beasts > 0 then
            local picked = beasts[s.rng:intBelow(#beasts) + 1]
            self:apply_buff(picked, n, 0, KW.NONE, false, powerCard)
            local card = self:ent(picked)
            if card ~= nil then card.cost_delta = card.cost_delta - n end
        end
    elseif power == E.IMBUED_WISP then
        -- N Wisps, then N damage one at a time, each at a random enemy still standing.
        local i = 0
        while i < n and self:board_size(seat) < 7 do
            self:summon_token(E.IMBUE_WISP, seat, -1, false)
            i = i + 1
        end
        local foe = 1 - seat
        for _ = 1, n + math.max(0, bonus) do
            local enemies = {}
            local theirHero = self:hero_of(foe)
            if theirHero ~= nil and theirHero.health > 0 then enemies[#enemies + 1] = theirHero.id end
            for _, id in ipairs(self:board_ids(foe)) do
                local e = self:ent(id)
                if e ~= nil and not e.flags.dead and e.health > 0 and e.flags.dormant_turns == 0
                    and not self:is_location(id) then
                    enemies[#enemies + 1] = id
                end
            end
            if #enemies == 0 then break end
            local struck = enemies[s.rng:intBelow(#enemies) + 1]
            p.game_hero_power_damage = p.game_hero_power_damage + self:deal_damage(struck, 1, 0, false)
        end
    elseif power == E.IMBUED_DRAGON then
        -- Two Emerald Portals into the deck, each at a random place. What one does is read when it is drawn.
        local shuffle = D.prepareEffect({ op = "SHUFFLE", token = E.IMBUE_PORTAL,
            target = { kind = "SELF", side = "YOUR_HERO" } })
        for _ = 1, 2 do self:apply_op(shuffle, heroId, heroId, seat) end
    elseif power == E.IMBUED_MOON then
        -- Pick one of three Priest minions or spells, N off its Cost, Temporary. The pool is handed over as a list.
        local group = {}
        for _, id in ipairs(D.all()) do
            local card = D.def(id)
            if D.poolCard(card) and card.familyNum == FAMILY.PRIEST
                and (card.type == "MINION" or card.type == "SPELL") then
                group[#group + 1] = card.id
            end
        end
        if #group > 0 then
            local pick = D.prepareEffect({ op = "DISCOVER", amount = 3, discoverCostDelta = -n, temporary = true,
                tokens = group })
            self:apply_op(pick, 0, heroId, seat)
            -- The choice belongs to the power: nothing resumes after it.
            local pend = s.pending
            if pend.active and pend.kind == "discover" then
                pend.resume = false
                pend.source = heroId
                pend.effect_index = -1
                pend.then_on_play = false
                pend.rerun = 0
            end
        end
    elseif power == E.IMBUED_WIND then
        -- "Into a random one that costs (N) more": TRANSFORM's cost-relative form, on the chosen friendly minion.
        local aimed = self:ent(target)
        if aimed ~= nil and aimed.zone == ZONE.BOARD and aimed.controller == seat then
            local transform = D.prepareEffect({ op = "TRANSFORM", amount = n,
                target = { kind = "CHOOSE", side = "FRIENDLY_MINION" } })
            self:apply_op(transform, target, heroId, seat)
        end
    elseif power == E.IMBUED_BRONZE then
        -- A random minion from another class, N off its Cost.
        local held = {}
        for _, id in ipairs(self:hand_ids(seat)) do held[id] = true end
        local get = D.prepareEffect({ op = "ADD_TO_HAND", type_filter = 0 + 1, otherClass = true,
            target = { kind = "SELF", side = "YOUR_HERO" } })
        self:apply_op(get, heroId, heroId, seat)
        for _, id in ipairs(self:hand_ids(seat)) do
            if not held[id] then
                local card = self:ent(id)
                if card ~= nil then card.cost_delta = card.cost_delta - n end
            end
        end
    end
    -- IMBUED_INFINITE is Passive: imbue_first_undead does its work.
end

-- An Emerald Portal drawn: cast as it is drawn (cast_when_drawn's rule). Returns 1, or -1 when aborted.
function E:imbue_portal_drawn(id)
    local portal = self:ent(id)
    if portal == nil then return 0 end
    local owner = portal.owner
    -- "A random N-Cost Dragon", N the owner's count now.
    local dragon = D.prepareEffect({ op = "SUMMON_RANDOM", raceFilter = "dragon", resolvedCost = 0,
        target = { kind = "SELF", side = "YOUR_HERO" } })
    dragon.resolvedCost = self.state.players[owner + 1].imbue_count
    self:apply_op(dragon, 0, id, owner)
    if self.aborted then return -1 end
    self:relocate(id, ZONE.GRAVEYARD, -1)
    return 1
end

-- Blessing of the Infinite: the first Undead its player plays each turn gets +N Attack.
function E:imbue_first_undead(seat, id, card)
    local p = self.state.players[seat + 1]
    if p.hero_power_id ~= E.IMBUED_INFINITE or card.type ~= "MINION" or not D.hasRace(card.races, D.RACE.undead) then
        return
    end
    -- The tribes played this turn are recorded once each play resolves, so an Undead among them was an earlier one.
    if D.hasRace(p.play_tribes_this_turn, D.RACE.undead) then return end
    self:apply_buff(id, E.imbue_level(p.imbue_count), 0, KW.NONE, false, "END_003p")
end









