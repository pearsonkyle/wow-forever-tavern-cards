-- Actions: move enumeration, the reducers, hero powers, dispatch and the move API (legal_moves /
-- apply_move). A port of the matching TcEngine members in jankcraft's tc/engine.cpp.
--
--   local moves = engine:legal_moves()       -- { {action, desc, cards, payload}, ... }
--   engine:apply_move(index)                  -- 1-based here; the C++ API (and tavern-trace) is 0-based

local TC = TavernCards_NS
local D = TC.EngineDefs
local E = TC.Engine
local bit = bit
local band, bor, bnot = bit.band, bit.bor, bit.bnot
local min, max = math.min, math.max
local ZONE, PHASE, RESULT, REASON, KW, RACE = D.ZONE, D.PHASE, D.RESULT, D.REASON, D.KW, D.RACE
local def = D.def
local hasRace = D.hasRace
local other = E.other
local contains = E.contains
local HERO_POWER_TARGETING = E.HERO_POWER_TARGETING

local TRADE_COST = 1

local POWER_NAME = { [1] = "Armor Up!", [2] = "Reinforce", [3] = "Steady Shot", [4] = "Dagger Mastery",
    [5] = "Lesser Heal", [6] = "Raise Dead", [7] = "Totemic Call", [8] = "Fireblast", [9] = "Life Tap",
    [11] = "Shapeshift" }
local POWER_TEXT = { [1] = "Gain 2 Armor.", [2] = "Summon a 1/1 Silver Hand Recruit.",
    [3] = "Deal 2 damage to the enemy hero.", [4] = "Equip a 1/2 Dagger.", [5] = "Restore 2 Health.",
    [6] = "Summon a 1/1 Ghoul with Charge. It dies at the end of your turn.", [7] = "Summon a 1/1 Searing Totem.",
    [8] = "Deal 1 damage.", [9] = "Lose 2 Health. Draw a card.", [11] = "+1 Attack this turn and +1 Armor." }
E.POWER_NAME, E.POWER_TEXT = POWER_NAME, POWER_TEXT

local function powerSupported(power)
    return POWER_NAME[power] ~= nil
end

local function powerNeedsTarget(power)
    return power == 5 or power == 8
end

-- ---- hero powers -------------------------------------------------------------------------------

function E:hero_power_targets_impl(power, seat)
    if power == 5 then return self:choose_targets("FRIENDLY_CHARACTER", seat, HERO_POWER_TARGETING) end
    if power == 8 then return self:choose_targets("ANY_CHARACTER", seat, HERO_POWER_TARGETING) end
    return {}
end

function E:hero_power_legal(power, seat, target)
    local hero = self:hero_of(seat)
    if not hero then return false, "E_NO_ENTITY" end
    local p = self:player(seat)
    if p.hero_power_uses >= 1 or hero.flags.hero_power_used then return false, "E_POWER_USED" end
    if p.mana < self:hero_power_cost(seat) then return false, "E_COST" end
    if not powerSupported(power) then return false, "E_NOT_IMPLEMENTED" end
    if powerNeedsTarget(power) then
        local targets = self:hero_power_targets_impl(power, seat)
        if #targets == 0 or target == 0 then return false, "E_NEEDS_TARGET" end
        if not contains(targets, target) then return false, "E_TARGET" end
    elseif (power == 2 or power == 6 or power == 7) and self:board_size(seat) >= 7 then
        return false, "E_BOARD_FULL"
    end
    return true
end

function E:apply_hero_power(power, seat, target)
    self.hero_power_resolving = true
    local hero = self:hero_of(seat)
    if hero then self:emit_event("HERO_POWER_USED", hero.id, 0) end
    local bonus = 0
    for _, id in ipairs(self:board_ids(seat)) do
        local bd = self:def_of(id)
        if bd then
            for _, fx in ipairs(bd.effects) do
                if fx.op == "HERO_POWER_DAMAGE" and fx.trigger == "AURA" then bonus = bonus + fx.amount end
            end
        end
    end
    local p = self:player(seat)
    bonus = bonus + p.hero_power_damage_once
    p.hero_power_damage_once = 0
    p.hero_power_once_this_turn = false
    p.mana = p.mana - self:hero_power_cost(seat)
    p.hero_power_cost_once = 0
    p.hero_power_free_once = false
    p.hero_power_uses = p.hero_power_uses + 1
    p.game_hero_power_uses = p.game_hero_power_uses + 1
    hero = self:hero_of(seat)
    if hero then hero.flags.hero_power_used = true end
    if power == 1 then
        if hero then self:gain_armor(hero, 2) end
    elseif power == 2 then
        self:summon_token("TAVERN_RECRUIT", seat, -1, false)
    elseif power == 3 then
        local foe = self:hero_of(other(seat))
        if foe then p.game_hero_power_damage = p.game_hero_power_damage + self:deal_damage(foe.id, 2 + bonus, 0, false) end
    elseif power == 4 then
        self:equip_weapon("TAVERN_DAGGER", seat)
    elseif power == 5 then
        self:heal_entity(target, 2)
    elseif power == 6 then
        self:summon_token("TAVERN_GHOUL", seat, -1, true)
    elseif power == 7 then
        self:summon_token("TAVERN_TOTEM", seat, -1, false)
    elseif power == 8 then
        p.game_hero_power_damage = p.game_hero_power_damage + self:deal_damage(target, 1 + bonus, 0, false)
    elseif power == 9 then
        if hero then
            hero.health = hero.health - 2
            if hero.health > 0 then self:draw_card(seat) end
        end
    elseif power == 11 then
        if hero then
            self:apply_buff(hero.id, 1, 0, 0, true, "shapeshift")
            self:gain_armor(hero, 1)
        end
    end
    self:run_trigger(seat, "INSPIRE")
    self.hero_power_resolving = false
end

-- ---- enumeration -------------------------------------------------------------------------------

function E:target_label(target, viewer)
    local e = self:ent(target)
    if not e then return "nothing" end
    if e.zone == ZONE.HERO then return e.owner == viewer and "your hero" or "enemy hero" end
    local d = self:def_of(target)
    return d and d.name or e.card_id
end

local function spec(action, desc, disambig, cards)
    return { action = action, desc = desc, disambig = disambig, card_ids = cards or {} }
end

local function act(t, fields)
    fields = fields or {}
    fields.type = t
    fields.entity = fields.entity or 0
    fields.target = fields.target or 0
    fields.position = fields.position == nil and 0 or fields.position
    fields.choice = fields.choice or 0
    fields.replace = fields.replace or {}
    return fields
end

function E:enumerate_mulligan()
    local out = {}
    local cur = self:current_player()
    if cur < 0 then return out end
    local cards = self:mulligan_ids(cur)
    local n = #cards
    for mask = 0, 2 ^ n - 1 do
        local a = act("mulligan")
        local ids, count = {}, 0
        for i = 0, n - 1 do
            if band(bit.rshift(mask, i), 1) == 1 then
                a.replace[#a.replace + 1] = i
                ids[#ids + 1] = cards[i + 1]
                count = count + 1
            end
        end
        out[#out + 1] = spec(a, mask == 0 and "Keep all cards" or ("Replace " .. count .. " card(s)"), mask, ids)
    end
    return out
end

local PLAYABLE_TYPE = { MINION = true, SPELL = true, WEAPON = true, LOCATION = true }

function E:enumerate_play(seat)
    local out = {}
    local p = self:player(seat)
    local s = self.state
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        local hand = self:ent(id)
        local affordable = false
        if d then
            local price = self:card_cost(seat, id)
            local resource = d.pays_with
            if resource == 0 then resource = self:card_pays_with_effect(seat, id) end
            if resource == 0 and hand then resource = hand.pays_with end
            if resource == 0 and p.next_pays_with ~= 0 and p.next_pays_with_count > 0
                and (p.next_pays_with_type == 0 or p.next_pays_with_type == d.typeNum + 1) then
                resource = p.next_pays_with
            end
            local payer = self:hero_of(seat)
            if resource == 1 then
                affordable = payer ~= nil and payer.health > price
            elseif resource == 2 then
                affordable = payer ~= nil and payer.armor >= price
            else
                affordable = price <= p.mana
            end
        end
        if d and affordable and not (hand and hand.flags.prepared_turn == s.turn) and PLAYABLE_TYPE[d.type] then
            if d.magnetic and d.type == "MINION" and #d.choices == 0 then
                for _, host in ipairs(self:board_ids(seat)) do
                    local hd = self:def_of(host)
                    if hd and hasRace(hd.races, RACE.mechanical) then
                        out[#out + 1] = spec(act("play", { entity = id, target = host, position = -1 }),
                            "Play " .. d.name .. " (Magnetic) on " .. self:target_label(host, seat), id, { id, host })
                    end
                end
            end
            local boardFull = (d.type == "MINION" or d.type == "LOCATION") and self:board_size(seat) >= 7
            local secretBlocked = d.secret and (#p.secrets >= 5 or self:secret_in_play(seat, d.id))
            if not boardFull and not secretBlocked then
                local function addPlays(effects, choice, suffix)
                    local targets = d.type == "LOCATION" and {}
                        or self:card_choose_targets_for(d, effects, "ON_PLAY", seat, id)
                    if d.type == "MINION" then
                        local bs = self:board_size(seat)
                        for _, t in ipairs(targets) do
                            for pos = 0, bs do
                                out[#out + 1] = spec(act("play", { entity = id, target = t, position = pos, choice = choice }),
                                    "Play " .. d.name .. suffix .. " at position " .. pos .. " on " .. self:target_label(t, seat),
                                    id, { id, t })
                            end
                        end
                        if #targets == 0 then
                            for pos = 0, bs do
                                out[#out + 1] = spec(act("play", { entity = id, position = pos, choice = choice }),
                                    "Play " .. d.name .. suffix .. " at position " .. pos, id, { id })
                            end
                        end
                    elseif #targets > 0 then
                        for _, t in ipairs(targets) do
                            out[#out + 1] = spec(act("play", { entity = id, target = t, position = -1, choice = choice }),
                                "Play " .. d.name .. suffix .. " on " .. self:target_label(t, seat), id, { id, t })
                        end
                    elseif d.type ~= "SPELL" or not self:requires_chosen_target(d, effects) then
                        out[#out + 1] = spec(act("play", { entity = id, position = -1, choice = choice }),
                            "Play " .. d.name .. suffix, id, { id })
                    end
                end
                if #d.choices > 0 then
                    for i, option in ipairs(d.choices) do
                        local label = d.choice_labels and d.choice_labels[i] and d.choice_labels[i] ~= ""
                            and (" [" .. d.choice_labels[i] .. "]") or (" [option " .. i .. "]")
                        addPlays(option, i - 1, label)
                    end
                else
                    addPlays(d.effects, 0, "")
                end
            end
        end
    end
    return out
end

function E:enumerate_locations(seat)
    local out = {}
    for _, id in ipairs(self:board_ids(seat)) do
        local e, d = self:ent(id), self:def_of(id)
        if e and d and d.type == "LOCATION" and e.durability > 0 and not e.flags.has_attacked then
            local targets = self:card_choose_targets(d, "ON_PLAY", seat, id)
            if not (#targets == 0 and self:requires_chosen_target(d, d.effects)) then
                if #targets == 0 then
                    out[#out + 1] = spec(act("activate", { entity = id }), "Activate " .. d.name, id, { id })
                else
                    for _, t in ipairs(targets) do
                        out[#out + 1] = spec(act("activate", { entity = id, target = t }),
                            "Activate " .. d.name .. " on " .. self:target_label(t, seat), id, { id, t })
                    end
                end
            end
        end
    end
    return out
end

function E:enumerate_titan_abilities(seat)
    local out = {}
    for _, id in ipairs(self:board_ids(seat)) do
        if self:titan_can_act(id) then
            local e, d = self:ent(id), self:def_of(id)
            for i, abilityId in ipairs(d.titan_abilities) do
                if band(e.titan_used, bit.lshift(1, i - 1)) == 0 then
                    local ability = def(abilityId)
                    if ability and ability.implemented then
                        local targets = self:card_choose_targets(ability, "ON_PLAY", seat, id)
                        if not (#targets == 0 and self:requires_chosen_target(ability, ability.effects)) then
                            local function add(target)
                                out[#out + 1] = spec(act("activate", { entity = id, choice = i - 1, target = target }),
                                    "Use " .. d.name .. ": " .. ability.name
                                        .. (target ~= 0 and (" on " .. self:target_label(target, seat)) or ""),
                                    id, target ~= 0 and { id, target } or { id })
                            end
                            if #targets == 0 then
                                add(0)
                            else
                                for _, t in ipairs(targets) do add(t) end
                            end
                        end
                    end
                end
            end
        end
    end
    return out
end

function E:enumerate_forge(seat)
    local out = {}
    if self:player(seat).mana < 2 then return out end
    for _, id in ipairs(self:hand_ids(seat)) do
        local e, d = self:ent(id), self:def_of(id)
        if e and d and not e.flags.forged and (d.text:find("Forge:", 1, true) or d.text:find("forge:", 1, true)) then
            out[#out + 1] = spec(act("forge", { entity = id }), "Forge " .. d.name, id, { id })
        end
    end
    return out
end

function E:enumerate_prepare(seat)
    local out = {}
    if self:player(seat).mana < 1 then return out end
    for _, id in ipairs(self:hand_ids(seat)) do
        local e, d = self:ent(id), self:def_of(id)
        if e and d and d.prepare and not e.flags.prepared and e.flags.prepared_turn ~= self.state.turn then
            out[#out + 1] = spec(act("prepare", { entity = id }), "Prepare " .. d.name, id, { id })
        end
    end
    return out
end

function E:enumerate_trade(seat)
    local out = {}
    if self:player(seat).mana < 1 then return out end
    for _, id in ipairs(self:hand_ids(seat)) do
        local d = self:def_of(id)
        if d and d.tradeable then
            out[#out + 1] = spec(act("trade", { entity = id, position = -1 }), "Trade " .. d.name, id, { id })
        end
    end
    return out
end

function E:enumerate_attacks(seat)
    local out = {}
    for _, id in ipairs(self:board_ids(seat)) do
        if self:can_minion_attack(id) then
            local d, a = self:def_of(id), self:ent(id)
            local name = d and d.name or (a and a.card_id or "minion")
            for _, t in ipairs(self:attack_targets(id)) do
                out[#out + 1] = spec(act("attack", { entity = id, target = t, position = -1 }),
                    "Attack with " .. name .. " into " .. self:target_label(t, seat), id, { id, t })
            end
        end
    end
    if self:can_hero_attack(seat) then
        local hero = self:hero_of(seat)
        if hero then
            for _, t in ipairs(self:attack_targets(hero.id)) do
                out[#out + 1] = spec(act("attack", { entity = hero.id, target = t, position = -1 }),
                    "Attack with hero into " .. self:target_label(t, seat), hero.id, { hero.id, t })
            end
        end
    end
    return out
end

function E:enumerate_hero_power(seat)
    local out = {}
    local p = self:player(seat)
    local power = p.hero_power_id
    if power == 0 or not powerSupported(power) then return out end
    local hero = self:hero_of(seat)
    if not hero or p.hero_power_uses >= 1 or hero.flags.hero_power_used or p.mana < self:hero_power_cost(seat) then
        return out
    end
    if powerNeedsTarget(power) then
        for _, t in ipairs(self:hero_power_targets_impl(power, seat)) do
            out[#out + 1] = spec(act("hero_power", { target = t, position = -1 }),
                "Use hero power " .. POWER_NAME[power] .. " on " .. self:target_label(t, seat), t, { t })
        end
    else
        if (power == 2 or power == 6 or power == 7) and self:board_size(seat) >= 7 then return out end
        out[#out + 1] = spec(act("hero_power", { position = -1 }), "Use hero power " .. POWER_NAME[power], 0)
    end
    return out
end

function E:enumerate_specs()
    local out = {}
    if self:is_terminal() then return out end
    local s = self.state
    if s.pending.active then
        local count = #s.pending.card_options == 0 and #s.pending.options or #s.pending.card_options
        for i = 0, count - 1 do
            out[#out + 1] = spec(act("resolve", { choice = i }), "Resolve choice " .. i, i)
        end
        return out
    end
    if s.phase == PHASE.MULLIGAN then return self:enumerate_mulligan() end
    if s.phase ~= PHASE.PLAYER_ACTIONS then return out end
    local seat = s.active
    for _, list in ipairs({ self:enumerate_attacks(seat), self:enumerate_play(seat), self:enumerate_locations(seat),
        self:enumerate_titan_abilities(seat), self:enumerate_forge(seat), self:enumerate_prepare(seat),
        self:enumerate_trade(seat), self:enumerate_hero_power(seat) }) do
        for _, x in ipairs(list) do out[#out + 1] = x end
    end
    local p = self:player(seat)
    if p.starship_building and p.mana >= 5 and self:board_size(seat) < 7 then
        out[#out + 1] = spec(act("launch", { position = -1 }),
            "Launch your Starship (" .. p.starship_attack .. "/" .. p.starship_health .. ")", 0)
    end
    out[#out + 1] = spec(act("end_turn", { position = -1 }), "End turn", 0)
    out[#out + 1] = spec(act("concede", { position = -1 }), "Concede", 0)
    return out
end

-- action_payload, as a table (the C++ writes it as JSON with these keys).
local function payload(a)
    local t = { t = a.type }
    if a.type == "mulligan" then
        t.replace = a.replace
    elseif a.type == "play" then
        t.entity = a.entity
        if a.target ~= 0 then t.target = a.target end
        if a.position >= 0 then t.position = a.position end
        if a.choice > 0 then t.choice = a.choice end
    elseif a.type == "trade" or a.type == "activate" or a.type == "forge" or a.type == "prepare" then
        t.entity = a.entity
        if a.type == "activate" then t.target = a.target end
        if a.type == "activate" and a.choice > 0 then t.choice = a.choice end
    elseif a.type == "attack" then
        t.entity, t.target = a.entity, a.target
    elseif a.type == "hero_power" then
        if a.target ~= 0 then t.target = a.target end
    elseif a.type == "resolve" then
        t.choice = a.choice
    end
    return t
end

function E:legal_moves()
    local out = {}
    local used = {}
    for _, sp in ipairs(self:enumerate_specs()) do
        local desc = sp.desc
        if used[desc] then
            local candidate = desc .. " #" .. sp.disambig
            local extra = 1
            while used[candidate] do
                candidate = desc .. " #" .. sp.disambig .. "." .. extra
                extra = extra + 1
            end
            desc = candidate
        end
        used[desc] = true
        out[#out + 1] = { action = sp.action.type, desc = desc, cards = sp.card_ids, payload = payload(sp.action),
            raw = sp.action }
    end
    return out
end

-- ---- reducers ----------------------------------------------------------------------------------

function E:apply_mulligan(a)
    local cur = self:current_player()
    if cur < 0 then return self:fail("E_PHASE") end
    local cards = self:mulligan_ids(cur)
    for i, pos in ipairs(a.replace) do
        if pos < 0 or pos >= #cards then return self:fail("E_SCHEMA") end
        if i > 1 and pos <= a.replace[i - 1] then return self:fail("E_SCHEMA") end
    end
    local returned = {}
    for _, pos in ipairs(a.replace) do returned[#returned + 1] = cards[pos + 1] end
    for _ = 1, #returned do self:draw_card(cur) end
    for _, id in ipairs(returned) do self:relocate(id, ZONE.DECK, -1) end
    local deck = self:deck_ids(cur)
    self.state.rng:shuffle(deck)
    for i, id in ipairs(deck) do self.state.entities[id].zone_pos = i - 1 end
    self.state.mulligan_answered[cur + 1] = true
    return true
end

function E:fail(code)
    self.last_error = code
    return false
end

function E:apply_play(a)
    local s = self.state
    local function notePlayed(ps, card, played)
        ps.cards_played_this_turn = ps.cards_played_this_turn + 1
        if played and played.flags.created_by_effect then
            ps.game_cards_played_not_from_deck = ps.game_cards_played_not_from_deck + 1
        end
        for _, fx in ipairs(card.effects) do
            if fx.condition == "COMBO" then
                ps.combo_cards_played_this_turn = ps.combo_cards_played_this_turn + 1
                break
            end
        end
    end
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local seat = s.active
    local e = self:ent(a.entity)
    if not e or e.zone ~= ZONE.HAND or e.owner ~= seat then return self:fail("E_NOT_IN_HAND") end
    local card = self:def_of(e.id)
    if not card then return self:fail("E_NO_ENTITY") end
    local p = self:player(seat)
    if p.chain_card ~= "" and p.chain_card == card.id and #p.chain_options > 0 then
        local pd = s.pending
        pd.active, pd.seat, pd.kind = true, seat, "discover"
        pd.options = {}
        pd.card_options = p.chain_options
        pd.cost_delta, pd.temporary, pd.dark_gift, pd.guess_copy, pd.chain = 0, false, false, false, false
        p.chain_card = ""
        p.chain_options = {}
    end
    for _, otherId in ipairs(self:hand_ids(seat)) do
        if otherId ~= e.id then
            local od, oe = self:def_of(otherId), self:ent(otherId)
            if od and oe and oe.zone == ZONE.HAND and card.cost > od.cost then
                oe.flags.corrupted = true
            end
        end
    end
    if e.flags.prepared_turn == s.turn then return self:fail("E_NOT_IMPLEMENTED") end
    local payer = self:hero_of(seat)
    local price = self:card_cost(seat, e.id)
    local resource = card.pays_with
    if resource == 0 then resource = self:card_pays_with_effect(seat, e.id) end
    if resource == 0 and e.pays_with ~= 0 then resource = e.pays_with end
    local usedNextPaysWith = false
    if resource == 0 and p.next_pays_with ~= 0 and p.next_pays_with_count > 0
        and (p.next_pays_with_type == 0 or p.next_pays_with_type == card.typeNum + 1) then
        resource = p.next_pays_with
        usedNextPaysWith = true
    end
    if resource == 1 then
        if not payer or payer.health <= price then return self:fail("E_COST") end
    elseif resource == 2 then
        if not payer or payer.armor < price then return self:fail("E_COST") end
    elseif price > p.mana then
        return self:fail("E_COST")
    end
    local tgt = self:ent(a.target)
    local tgtDef = a.target ~= 0 and self:def_of(a.target) or nil
    local magnetizing = card.magnetic and a.target ~= 0 and tgt ~= nil and tgt.zone == ZONE.BOARD and tgt.owner == seat
        and tgtDef ~= nil and hasRace(tgtDef.races, RACE.mechanical)
    if card.type == "MINION" and self:board_size(seat) >= 7 and not magnetizing then return self:fail("E_BOARD_FULL") end
    local playEffects = card.effects
    local choice = 0
    if #card.choices > 0 then
        if a.choice < 0 or a.choice >= #card.choices then return self:fail("E_SCHEMA") end
        choice = a.choice
        playEffects = card.choices[choice + 1]
    end
    local targets = card.type == "LOCATION" and {} or self:card_choose_targets_for(card, playEffects, "ON_PLAY", seat, e.id)
    if card.magnetic then
        targets[#targets + 1] = 0
        for _, o in ipairs(self:board_ids(seat)) do
            local hd = self:def_of(o)
            if hd and hasRace(hd.races, RACE.mechanical) then targets[#targets + 1] = o end
        end
    end
    if #targets == 0 and card.type == "SPELL" and self:requires_chosen_target(card, playEffects) then
        return self:fail("E_NEEDS_TARGET")
    end
    local target = 0
    if #targets > 0 then
        if a.target == 0 and not contains(targets, 0) then return self:fail("E_NEEDS_TARGET") end
        if not contains(targets, a.target) then return self:fail("E_TARGET") end
        target = a.target
    end
    if resource == 1 and payer then
        payer.health = payer.health - price
        p.hero_health_changed_this_turn = true
        self:emit_event("DAMAGED", payer.id, 0, price)
    elseif resource == 2 and payer then
        payer.armor = payer.armor - price
        p.armor_changed_this_turn = true
    else
        p.mana = p.mana - price
    end
    self.play_spent_last_mana = resource ~= 1 and resource ~= 2 and p.mana == 0
    if usedNextPaysWith then
        p.next_pays_with_count = p.next_pays_with_count - 1
        if p.next_pays_with_count <= 0 then
            p.next_pays_with = 0
            p.next_pays_with_type = 0
        end
    end
    if p.next_card_cost_delta ~= 0 and E.costFilterMatches(p.next_card_cost_filter, card)
        and (p.next_card_cost_school == 0 or (card.type == "SPELL" and card.schoolNum + 1 == p.next_card_cost_school))
        and (p.next_card_cost_race == 0 or hasRace(card.races, p.next_card_cost_race))
        and (p.next_card_cost_keyword == 0 or band(card.keywords, p.next_card_cost_keyword) == p.next_card_cost_keyword) then
        p.next_card_cost_delta, p.next_card_cost_filter, p.next_card_cost_school = 0, 0, 0
        p.next_card_cost_race, p.next_card_cost_keyword, p.next_card_cost_this_turn = 0, 0, false
    end
    if card.overload > 0 then
        p.overload_next = p.overload_next + card.overload
        p.game_mana_overloaded = p.game_mana_overloaded + card.overload
    end
    local id = e.id
    self:emit_event("PLAYED", id, 0)
    local hand = self:hand_ids(seat)
    self.play_was_outcast = #hand > 0 and (hand[1] == id or hand[#hand] == id)
    if card.magnetic and target ~= 0 then
        local host = self:ent(target)
        if not host or host.zone ~= ZONE.BOARD then return self:fail("E_TARGET") end
        local hostId = host.id
        notePlayed(p, card, e)
        self:relocate(id, ZONE.GRAVEYARD, -1)
        self:fire_when_played(seat, id, card, true)
        local still = self:ent(hostId)
        if still and still.zone == ZONE.BOARD and not self.aborted then
            self:apply_buff(hostId, card.attack, card.health, band(card.keywords, bnot(KW.BATTLECRY)), false, card.id)
            local merged = self:ent(hostId)
            if merged then merged.magnetized[#merged.magnetized + 1] = card.id end
        end
        self:recompute_auras()
        self:queue("AFTER_PLAY_MINION", seat, id)
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
        return true
    end
    if card.type == "MINION" then
        local pos = a.position
        if pos < 0 or pos > self:board_size(seat) then pos = self:board_size(seat) end
        local placed = s.entities[id]
        placed.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        self:relocate(id, ZONE.BOARD, pos)
        placed.flags.exhausted = band(placed.keywords, bor(KW.CHARGE, KW.RUSH)) == 0
        if card.dormant_turns > 0 then
            placed.flags.dormant_turns = card.dormant_turns
            placed.flags.exhausted = true
        end
        placed.flags.just_played_turn = s.turn
        placed.flags.attacks_this_turn = 0
        notePlayed(p, card, e)
        self:fire_when_played(seat, id, card, false)
        if self.aborted then return true end
        if #card.choices == 0 then
            self:run_effects(id, "BATTLECRY", target, id)
            if s.pending.active and s.pending.resume and s.pending.source == id then
                s.pending.then_on_play = true
            else
                self:run_minion_on_play(id, target)
            end
        else
            self:run_effect_list(playEffects, id, "ON_PLAY", target, id, nil)
        end
        self:queue("AFTER_PLAY_MINION", seat, id)
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_SUMMON_MINION", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
        self:note_summoned(seat, card)
    elseif card.type == "SPELL" and card.secret then
        if #p.secrets >= 5 then return self:fail("E_SECRET_LIMIT") end
        if self:secret_in_play(seat, card.id) then return self:fail("E_SECRET_DUPLICATE") end
        notePlayed(p, card, e)
        self:relocate(id, ZONE.SECRET, -1)
        p.secrets[#p.secrets + 1] = id
        p.game_secrets_played = p.game_secrets_played + 1
        self:note_spell_cast(seat, card.schoolNum)
        self:fire_when_played(seat, id, card, false)
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_CAST_SPELL", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
        self:queue("AFTER_OPPONENT_CAST_SPELL", other(seat), id)
        self:queue("SPELLBURST", seat, id)
    elseif card.type == "SPELL" then
        notePlayed(p, card, e)
        self:relocate(id, ZONE.GRAVEYARD, -1)
        self:note_spell_cast(seat, card.schoolNum)
        self:fire_when_played(seat, id, card, false)
        if self.aborted then return true end
        if #card.choices == 0 then
            self:run_effects(id, "ON_PLAY", target, id)
        else
            self:run_effect_list(playEffects, id, "ON_PLAY", target, id, nil)
        end
        if card.repeat_next_school ~= 0 then
            s.persistent[#s.persistent + 1] = { owner = seat, source = id, card_id = card.id, turns_remaining = 1,
                target = 0, replay_school = card.repeat_next_school + 1 }
        end
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_CAST_SPELL", seat, id)
        self:queue("SPELLBURST", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
        self:queue("AFTER_OPPONENT_CAST_SPELL", other(seat), id)
        if card.next_drink ~= "" and #self:hand_ids(seat) < 10 then
            local nextDrink = def(card.next_drink)
            if nextDrink and (nextDrink.implemented or nextDrink.text == "") then
                self:create_entity(nextDrink, seat, ZONE.HAND, -1)
            end
        end
        local stays = false
        for _, fx in ipairs(card.effects) do stays = stays or fx.staysInHand end
        if stays and #self:hand_ids(seat) < 10 then
            local spent = self:ent(id)
            if spent and spent.zone == ZONE.GRAVEYARD then
                self:relocate(id, ZONE.HAND, -1)
                local back = self:ent(id)
                if back then self:reset_to_card(back) end
            end
        end
    elseif card.type == "LOCATION" then
        notePlayed(p, card, e)
        local location = s.entities[id]
        location.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        location.durability = card.durability
        location.attack = 0
        location.health = 1
        location.max_health = 1
        self:relocate(id, ZONE.BOARD, a.position >= 0 and a.position or -1)
        self:recompute_auras()
        self:fire_when_played(seat, id, card, false)
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
    elseif card.type == "WEAPON" then
        notePlayed(p, card, e)
        self:fire_when_played(seat, id, card, false)
        if self.aborted then return true end
        self:destroy_weapon(seat)
        local weapon = s.entities[id]
        weapon.play_order = s.next_play_order
        s.next_play_order = s.next_play_order + 1
        if weapon.durability <= 0 then weapon.durability = card.durability end
        self:relocate(id, ZONE.WEAPON, 0)
        p.weapon_id = id
        p.game_weapons_equipped = p.game_weapons_equipped + 1
        self:recompute_auras()
        if #card.choices == 0 then
            self:run_effects(id, "BATTLECRY", target, id)
            self:run_effects(id, "ON_PLAY", target, id)
        else
            self:run_effect_list(playEffects, id, "ON_PLAY", target, id, nil)
        end
        self:queue("AFTER_PLAY_CARD", seat, id)
        self:queue("AFTER_OPPONENT_PLAY_CARD", other(seat), id)
        self:recompute_auras()
    else
        return self:fail("E_NOT_IMPLEMENTED")
    end
    if band(card.keywords, KW.MINIATURIZE) ~= 0 then
        local made = self:create_entity(card, seat, ZONE.HAND, -1)
        local copy = self:ent(made)
        if copy then
            copy.attack, copy.health, copy.max_health = 1, 1, 1
            copy.cost_delta = 1 - card.cost
            copy.keywords = band(copy.keywords, bnot(KW.MINIATURIZE))
            if #self:hand_ids(seat) > 10 then self:relocate(made, ZONE.GRAVEYARD, -1) end
        end
    end
    local duration = 0
    for _, fx in ipairs(card.effects) do
        if fx.durationTurns > duration and (fx.trigger == "END_TURN" or fx.trigger == "START_TURN"
            or (card.type == "SPELL" and fx.trigger ~= "ON_PLAY")) then
            duration = fx.durationTurns
        end
    end
    if duration > 0 then
        s.persistent[#s.persistent + 1] = { owner = seat, source = id, card_id = card.id, turns_remaining = duration,
            target = 0, replay_school = 0 }
    end
    if card.type == "SPELL" and target ~= 0 then
        for _, fx in ipairs(card.effects) do
            if fx.trigger == "START_TURN" and fx.prompt and fx.target.kind == "CHOOSE" then
                s.persistent[#s.persistent + 1] = { owner = seat, source = id, card_id = card.id, turns_remaining = 1,
                    target = target, replay_school = 0 }
                break
            end
        end
    end
    p.game_cards_played = p.game_cards_played + 1
    if card.twinspell and not (self:ent(id) and self:ent(id).flags.twin_copy) then
        local made = self:create_entity(card, seat, ZONE.HAND, -1)
        local copy = self:ent(made)
        if copy then
            copy.flags.twin_copy = true
            if #self:hand_ids(seat) > 10 then self:relocate(made, ZONE.GRAVEYARD, -1) end
        end
    end
    if card.echo or card.repeatable then
        local made = self:create_entity(card, seat, ZONE.HAND, -1)
        local copy = self:ent(made)
        if copy then
            copy.temp_card = true
            if #self:hand_ids(seat) > 10 then self:relocate(made, ZONE.GRAVEYARD, -1) end
        end
    end
    if card.type == "MINION" and card.colossal > 0 then
        local appendages = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if cand and not cand.collectible and cand.type == "MINION" and cid:sub(1, #card.id) == card.id and cid ~= card.id then
                appendages[#appendages + 1] = cid
            end
        end
        for i = 1, min(#appendages, card.colossal) do
            if self:board_size(seat) >= 7 then break end
            self:summon_token(appendages[i], seat, -1, false)
        end
    end
    -- A Forged grammar card runs its own Forge ability as part of the play (a flat program runs it inside
    -- the ON_PLAY pass in run_effect_list).
    local played = self:ent(id)
    if played and played.flags.forged and card.abilities then
        self:run_effects(id, "FORGED", target, id)
    end
    if card.type == "SPELL" and card.schoolNum ~= 0 then
        p.play_schools_this_turn = bor(p.play_schools_this_turn, bit.lshift(1, card.schoolNum))
    end
    if card.races ~= 0 then
        p.play_tribes_this_turn = bor(p.play_tribes_this_turn, card.races)
    end
    if card.type == "MINION" and hasRace(card.races, RACE.elemental) then
        p.elementals_played_this_turn = p.elementals_played_this_turn + 1
    end
    if card.type == "SPELL" and card.cost >= 5 then p.game_spells_cost_5_plus = p.game_spells_cost_5_plus + 1 end
    if card.name:sub(1, 6) == "Relic " then p.game_relics_played = p.game_relics_played + 1 end
    return true
end

function E:apply_activate(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local e = self:ent(a.entity)
    local d = e and self:def_of(a.entity)
    if d and d.type == "MINION" and #d.titan_abilities > 0 then return self:apply_titan_ability(a) end
    if not e or not d or d.type ~= "LOCATION" then return self:fail("E_NO_ENTITY") end
    if e.zone ~= ZONE.BOARD or e.owner ~= s.active then return self:fail("E_NOT_IN_HAND") end
    if e.durability <= 0 or e.flags.has_attacked then return self:fail("E_NOT_IMPLEMENTED") end
    local targets = self:card_choose_targets(d, "ON_PLAY", s.active, a.entity)
    if #targets == 0 and self:requires_chosen_target(d, d.effects) then return self:fail("E_NEEDS_TARGET") end
    if #targets > 0 and not contains(targets, a.target) then return self:fail("E_TARGET") end
    e.flags.has_attacked = true
    e.durability = e.durability - 1
    self:run_effects(a.entity, "ON_PLAY", a.target, a.entity)
    if self.aborted then return true end
    if e.durability <= 0 then self:relocate(a.entity, ZONE.GRAVEYARD, -1) end
    return true
end

function E:apply_titan_ability(a)
    local s = self.state
    local titan, d = self:ent(a.entity), self:def_of(a.entity)
    if not titan or not d or titan.zone ~= ZONE.BOARD or titan.owner ~= s.active then return self:fail("E_NO_ENTITY") end
    if a.choice < 0 or a.choice >= #d.titan_abilities or band(titan.titan_used, bit.lshift(1, a.choice)) ~= 0 then
        return self:fail("E_USED")
    end
    if not self:titan_can_act(a.entity) then return self:fail(titan.flags.frozen and "E_FROZEN" or "E_USED") end
    local ability = def(d.titan_abilities[a.choice + 1])
    if not ability or not ability.implemented then return self:fail("E_NO_ENTITY") end
    local targets = self:card_choose_targets(ability, "ON_PLAY", s.active, a.entity)
    local bad
    if #targets == 0 then
        bad = a.target ~= 0 or self:requires_chosen_target(ability, ability.effects)
    else
        bad = not contains(targets, a.target)
    end
    if bad then return self:fail(#targets == 0 and "E_NEEDS_TARGET" or "E_TARGET") end
    titan.titan_used = bor(titan.titan_used, bit.lshift(1, a.choice))
    titan.flags.attacks_this_turn = titan.flags.attacks_this_turn + 1
    local id = titan.id
    self:run_titan_ability(id, a.choice, a.target, id)
    if self.aborted then return true end
    self.titan_last, self.titan_last_index = id, a.choice
    local still = self:ent(id)
    if still and still.zone == ZONE.BOARD and not still.flags.silenced and not s.pending.active then
        self:run_effects(id, "AFTER_TITAN_ABILITY", 0, id)
    end
    self.titan_last, self.titan_last_index = 0, -1
    return true
end

function E:run_titan_ability(titan, index, chosen, source)
    local d = self:def_of(titan)
    if not d or index < 0 or index >= #d.titan_abilities then return end
    local ability = def(d.titan_abilities[index + 1])
    if not ability then return end
    local effects = {}
    for i, fx in ipairs(ability.effects) do
        local one = D.copyEffect(fx)
        one.spell = false
        effects[i] = one
    end
    self:run_effect_list(effects, source, "ON_PLAY", chosen, source, nil)
    if self.state.pending.active and self.state.pending.source == source then
        self.state.pending.resume = false
    end
end

function E:apply_trade(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local e = self:ent(a.entity)
    if not e then return self:fail("E_NO_ENTITY") end
    if e.zone ~= ZONE.HAND or e.owner ~= s.active then return self:fail("E_NOT_IN_HAND") end
    local card = self:def_of(e.id)
    if not card or not card.tradeable then return self:fail("E_NOT_IMPLEMENTED") end
    local p = self:player(e.owner)
    if p.mana < TRADE_COST then return self:fail("E_COST") end
    local id, seat = e.id, e.owner
    p.mana = p.mana - TRADE_COST
    local deckSize = #self:deck_ids(seat)
    local at = deckSize == 0 and 0 or s.rng:intBelow(deckSize)
    self:relocate(id, ZONE.DECK, at)
    self:draw_card(seat, 0, 0, 0, 0)
    return true
end

function E:apply_forge(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local e = self:ent(a.entity)
    local d = e and self:def_of(a.entity)
    if not e or not d or e.zone ~= ZONE.HAND or e.owner ~= s.active then return self:fail("E_NOT_IN_HAND") end
    if e.flags.forged or not (d.text:find("Forge:", 1, true) or d.text:find("forge:", 1, true)) then
        return self:fail("E_NOT_IMPLEMENTED")
    end
    local p = self:player(s.active)
    if p.mana < 2 then return self:fail("E_COST") end
    p.mana = p.mana - 2
    e.flags.forged = true
    return true
end

function E:apply_prepare(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local e = self:ent(a.entity)
    local d = e and self:def_of(a.entity)
    if not e or not d or e.zone ~= ZONE.HAND or e.owner ~= s.active then return self:fail("E_NOT_IN_HAND") end
    local p = self:player(s.active)
    if not d.prepare or e.flags.prepared or e.flags.prepared_turn == s.turn or p.mana < 1 then
        return self:fail("E_NOT_IMPLEMENTED")
    end
    local spent = p.mana
    p.mana = 0
    e.cost_delta = e.cost_delta - (spent + 1)
    e.flags.prepared = true
    e.flags.prepared_turn = s.turn
    return true
end

function E:apply_launch()
    local s = self.state
    local p = self:player(s.active)
    if not p.starship_building or p.mana < 5 then return self:fail("E_COST") end
    local battlecruiser = p.hero_class == D.FAMILY.PALADIN or p.hero_class == D.FAMILY.SHAMAN
        or p.hero_class == D.FAMILY.WARRIOR
    local made = self:summon_token(battlecruiser and "SC_999t" or "GDB_100t2", s.active, self.summon_pos, false)
    self.summon_pos = -1
    if made == 0 then return self:fail("E_COST") end
    p.mana = p.mana - 5
    local launched = self:ent(made)
    if launched then
        launched.attack = p.starship_attack
        launched.max_health = p.starship_health
        launched.health = p.starship_health
        launched.keywords = bor(launched.keywords, p.starship_keywords)
    end
    p.starship_attack, p.starship_health, p.starship_keywords, p.starship_building = 0, 0, 0, false
    p.game_starships_launched = p.game_starships_launched + 1
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.owner == s.active and (e.zone == ZONE.HAND or e.zone == ZONE.DECK) then
            local d = self:def_of(id)
            local up = d and self:launch_upgrade_of(d)
            if up then
                e.card_id = up.id
                self:reset_to_card(e)
            end
        end
    end
    return true
end

function E:apply_attack(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local at, t = self:ent(a.entity), self:ent(a.target)
    if not at or not t then return self:fail("E_NO_ENTITY") end
    if at.controller ~= s.active then return self:fail("E_NOT_YOUR_TURN") end
    if not E.isCharacter(t) then return self:fail("E_TARGET") end
    if at.zone == ZONE.BOARD then
        if not self:can_minion_attack(at.id) then
            return self:fail(at.flags.frozen and "E_FROZEN" or at.flags.exhausted and "E_SICK" or "E_USED")
        end
    elseif not self:can_hero_attack(at.owner) then
        return self:fail(at.flags.frozen and "E_FROZEN" or "E_USED")
    end
    if not contains(self:attack_targets(at.id), t.id) then
        self.last_error = "E_TARGET"
        for _, id in ipairs(self:board_ids(other(at.controller))) do
            local e2 = self:ent(id)
            if e2 and band(e2.keywords, KW.TAUNT) ~= 0 and band(e2.keywords, KW.STEALTH) == 0 then
                self.last_error = "E_TAUNT"
                break
            end
        end
        return false
    end
    local attacker, target = at.id, t.id
    local defender = t.owner
    local fired = self:fire_secrets(t.zone == ZONE.HERO and "WHEN_YOUR_HERO_ATTACKED" or "WHEN_YOUR_MINION_ATTACKED",
        defender, t.zone == ZONE.HERO and attacker or target)
    local firstNew = s.next_entity_id
    if self:fire_secrets("WHEN_ENEMY_MINION_ATTACKS", defender, attacker) then
        fired = true
        for _, id in ipairs(self:board_ids(defender)) do
            if id >= firstNew and not self:is_location(id) then
                target = id
                break
            end
        end
    end
    local function attackSurvives()
        if not self:resolve_deaths() then return false end
        local still, defending = self:ent(attacker), self:ent(target)
        local attackerOk = still ~= nil and E.isCharacter(still) and not still.flags.dead and still.health > 0
            and still.controller == s.active
        local targetOk = defending ~= nil and E.isCharacter(defending) and not defending.flags.dead and defending.health > 0
        if not attackerOk or not targetOk then
            if still and E.isCharacter(still) then still.flags.attacks_this_turn = still.flags.attacks_this_turn + 1 end
            return false
        end
        return true
    end
    if fired and not attackSurvives() then return true end
    local striker = self:ent(attacker)
    if striker and striker.zone == ZONE.HERO then
        local side = striker.owner
        local reactors = {}
        local weapon = self:player(side).weapon_id
        if weapon ~= 0 then reactors[1] = weapon end
        local board = {}
        for _, id in ipairs(self:board_ids(side)) do
            local e = self:ent(id)
            if e then board[#board + 1] = e end
        end
        table.sort(board, function(x, y)
            if x.play_order ~= y.play_order then return x.play_order < y.play_order end
            return x.id < y.id
        end)
        for _, e in ipairs(board) do reactors[#reactors + 1] = e.id end
        for _, id in ipairs(reactors) do
            local e = self:ent(id)
            local d = e and not e.flags.silenced and self:def_of(id)
            if d then
                local reacts = false
                for _, fx in ipairs(d.effects) do reacts = reacts or fx.trigger == "WHEN_HERO_ATTACKS" end
                if reacts and self:step_budget() then
                    self:run_effects(id, "WHEN_HERO_ATTACKS", 0, attacker)
                    if self.aborted or not attackSurvives() then return true end
                end
            end
        end
    end
    striker = self:ent(attacker)
    if striker and striker.zone == ZONE.BOARD and not striker.flags.silenced then
        local own = self:def_of(attacker)
        if own then
            local reacts = false
            for _, fx in ipairs(own.effects) do
                if fx.trigger == "WHEN_SELF_ATTACKS" and self:subject_matches(fx, target, attacker) then reacts = true end
            end
            if reacts and self:step_budget() then
                self:run_effects(attacker, "WHEN_SELF_ATTACKS", 0, target)
                if self.aborted or not attackSurvives() then return true end
            end
        end
    end
    self:resolve_attack(attacker, target)
    return true
end

function E:apply_hero_power_action(a)
    local s = self.state
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    local seat = s.active
    local power = self:player(seat).hero_power_id
    local ok, err = self:hero_power_legal(power, seat, a.target)
    if not ok then return self:fail(err) end
    self:apply_hero_power(power, seat, a.target)
    return true
end

local DARK_GIFTS = { [0] = { 1, 1, 0 }, { 2, 2, 0 }, { 1, 1, KW.TAUNT }, { 0, 0, KW.DIVINE_SHIELD },
    { 0, 0, KW.LIFESTEAL }, { 0, 0, KW.RUSH } }
local ADAPTS = { [0] = { "BUFF", 1, 1, 0 }, { "BUFF", 3, 0, 0 }, { "BUFF", 0, 3, 0 }, { "GIVE_KEYWORD", 0, 0, KW.TAUNT },
    { "GIVE_KEYWORD", 0, 0, KW.WINDFURY }, { "GIVE_KEYWORD", 0, 0, KW.DIVINE_SHIELD },
    { "GIVE_KEYWORD", 0, 0, KW.POISONOUS }, { "GIVE_KEYWORD", 0, 0, KW.STEALTH }, { "GIVE_KEYWORD", 0, 0, KW.LIFESTEAL } }
E.ADAPT_LABELS = { [0] = "+1/+1", "+3 Attack", "+3 Health", "Taunt", "Windfury", "Divine Shield", "Poisonous",
    "Stealth", "Lifesteal" }

local function adaptEffect(which)
    local a = ADAPTS[which] or ADAPTS[0]
    return D.prepareEffect({ trigger = "ON_PLAY", op = a[1], amount = a[2], amount2 = a[3],
        keyword = nil, target = { kind = "SELF", side = "ANY_MINION" } }), a[4]
end

function E:apply_resolve(a)
    local s = self.state
    local live = s.pending
    if not live.active then return self:fail("E_PENDING") end
    local count = #live.card_options == 0 and #live.options or #live.card_options
    if a.choice < 0 or a.choice >= count then return self:fail("E_SCHEMA") end
    local pending = E.deepCopy(live)
    local created = 0
    local function carryResume()
        live.resume = pending.resume
        live.source = pending.source
        live.trigger = pending.trigger
        live.effect_index = pending.effect_index
        live.event_subject = pending.event_subject
        live.chosen = pending.chosen
    end
    if pending.kind == "adapt" then
        local fx, keyword = adaptEffect(pending.options[a.choice + 1])
        fx.keywordBits = keyword
        live.active = false
        live.kind = ""
        live.options = {}
        carryResume()
        live.previous_targets = pending.previous_targets
        self:apply_op(fx, pending.source, pending.source, pending.seat)
        self:resume_pending()
        return true
    end
    if pending.kind == "hand_action" and a.choice >= 0 and a.choice < #live.card_options then
        local chosenId = live.card_options[a.choice + 1]
        local verb = #live.options == 0 and 1 or live.options[1]
        local target = 0
        for _, handId in ipairs(self:hand_ids(live.seat)) do
            if s.entities[handId].card_id == chosenId then
                target = handId
                break
            end
        end
        if target ~= 0 and verb ~= 5 then
            if verb == 1 then
                local size = #self:deck_ids(live.seat)
                local at = size == 0 and 0 or s.rng:intBelow(size + 1)
                self:relocate(target, ZONE.DECK, at)
            elseif verb == 2 then
                self:discard_card(target, live.seat)
            elseif verb == 4 then
                self:summon_existing(target, live.seat, -1)
            elseif verb == 3 then
                local coin = def(D.COIN_ID)
                local e = self:ent(target)
                if coin and e then
                    e.card_id = coin.id
                    e.attack, e.max_health, e.health, e.keywords = coin.attack, coin.health, coin.health, coin.keywords
                end
            end
        end
        live.active = false
        live.kind = ""
        live.options = {}
        live.card_options = {}
        if pending.resume then
            live.previous_targets = target ~= 0 and { target } or pending.previous_targets
            self:resume_pending()
        end
        return true
    end
    if pending.kind == "dredge" then
        local chosenId = pending.options[a.choice + 1]
        local oldPos = s.entities[chosenId].zone_pos
        for _, id in ipairs(self:deck_ids(pending.seat)) do
            if id ~= chosenId and s.entities[id].zone_pos < oldPos then
                s.entities[id].zone_pos = s.entities[id].zone_pos + 1
            end
        end
        s.entities[chosenId].zone_pos = 0
        live.active = false
        live.kind = ""
        live.options = {}
        carryResume()
        live.previous_targets = { chosenId }
        self:resume_pending()
        return true
    end
    local function clearChoice()
        live.active = false
        live.options = {}
        live.card_options = {}
        live.kind = ""
        live.cost_delta = 0
        live.temporary = false
        live.summon = false
        live.dark_gift = false
        live.guess_copy = false
        live.chain = false
        live.from_deck = false
        live.others_to_hand = false
    end
    if #live.card_options > 0 then
        local chosen = live.card_options[a.choice + 1]
        local cd = def(chosen)
        if cd then
            local id = 0
            if live.summon and cd.type == "MINION" then
                local made = self:summon_token(cd.id, live.seat, -1, false)
                if made ~= 0 then
                    created = made
                    if pending.resume and #live.previous_targets == 0 then live.previous_targets = { made } end
                end
                if live.others_to_hand then
                    for k, optionId in ipairs(live.card_options) do
                        if k - 1 ~= a.choice then
                            local od = def(optionId)
                            if od then
                                local kept = self:create_entity(od, live.seat, ZONE.HAND, -1)
                                if kept ~= 0 and #self:hand_ids(live.seat) > 10 then
                                    self:relocate(kept, ZONE.GRAVEYARD, -1)
                                end
                            end
                        end
                    end
                end
                clearChoice()
                if pending.resume then
                    carryResume()
                    self:resume_pending()
                end
                return true
            end
            if pending.from_deck then
                for _, deckId in ipairs(self:deck_ids(live.seat)) do
                    if s.entities[deckId].card_id == chosen and id == 0 then id = deckId end
                end
                if id ~= 0 then
                    self:relocate(id, #self:hand_ids(live.seat) >= 10 and ZONE.GRAVEYARD or ZONE.HAND, -1)
                end
            elseif #self:hand_ids(live.seat) >= 10 then
                id = self:create_entity(cd, live.seat, ZONE.HAND, -1)
                self:relocate(id, ZONE.GRAVEYARD, -1)
            else
                id = self:create_entity(cd, live.seat, ZONE.HAND, -1)
            end
            created = id
            if id ~= 0 then
                local chooser = self:player(live.seat)
                chooser.chain_card = live.chain and chosen or ""
                chooser.chain_options = {}
                for _, option in ipairs(live.card_options) do
                    if option ~= chosen then chooser.chain_options[#chooser.chain_options + 1] = option end
                end
            end
            if id ~= 0 and live.guess_copy then
                local options = #live.card_options == 0 and 1 or #live.card_options
                if s.rng:intBelow(options) == 0 then
                    self:create_entity(cd, other(live.seat), ZONE.HAND, -1)
                end
            end
            if id ~= 0 and live.cost_delta ~= 0 then
                s.entities[id].cost_delta = s.entities[id].cost_delta + live.cost_delta
            end
            if id ~= 0 and live.temporary then s.entities[id].temp_card = true end
            if id ~= 0 and live.dark_gift then
                local gift = DARK_GIFTS[s.rng:intBelow(6)]
                local made = self:ent(id)
                if made then
                    made.attack = made.attack + gift[1]
                    made.max_health = made.max_health + gift[2]
                    made.health = made.health + gift[2]
                    made.keywords = bor(made.keywords, gift[3])
                end
            end
        end
    end
    clearChoice()
    if pending.resume and created ~= 0 then live.previous_targets = { created } end
    if pending.resume then
        carryResume()
        live.previous_targets = created ~= 0 and { created } or pending.previous_targets
        self:resume_pending()
    end
    return true
end

function E:apply_end_turn()
    if self.state.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    self.state.phase = PHASE.END_TURN_RESOLUTION
    return true
end

function E:apply_concede()
    local s = self.state
    if self:is_terminal() then return self:fail("E_FINISHED") end
    local cur = self:current_player()
    local loser = (s.phase == PHASE.MULLIGAN and cur >= 0) and cur or s.active
    s.result.result = loser == 0 and RESULT.WIN_B or RESULT.WIN_A
    s.result.reason = REASON.CONCEDE
    s.result.winner = other(loser)
    s.phase = PHASE.MATCH_FINISHED
    return true
end

local REDUCERS = {
    play = E.apply_play, trade = E.apply_trade, activate = E.apply_activate, forge = E.apply_forge,
    prepare = E.apply_prepare, launch = E.apply_launch, attack = E.apply_attack,
    hero_power = E.apply_hero_power_action, end_turn = E.apply_end_turn, concede = E.apply_concede,
}

function E:dispatch(a)
    local s = self.state
    if s.pending.active then
        if a.type ~= "resolve" then return self:fail("E_PENDING") end
        return self:apply_resolve(a)
    end
    if a.type == "concede" then return self:apply_concede(a) end
    if s.phase == PHASE.MULLIGAN then
        if a.type ~= "mulligan" then return self:fail("E_PHASE") end
        return self:apply_mulligan(a)
    end
    if s.phase ~= PHASE.PLAYER_ACTIONS then return self:fail("E_PHASE") end
    if a.type == "timeout" then
        local loser = s.active
        s.result.result = loser == 0 and RESULT.WIN_B or RESULT.WIN_A
        s.result.reason = REASON.TIMEOUT
        s.result.winner = other(loser)
        s.phase = PHASE.MATCH_FINISHED
        return true
    end
    local reducer = REDUCERS[a.type]
    if reducer then return reducer(self, a) end
    return self:fail(a.type == "resolve" and "E_PENDING" or "E_PHASE")
end

-- A rejected action leaves the state untouched: a backup is taken first, unless this is a search copy
-- (`self.scratch`), which is thrown away instead.
function E:apply_action(a)
    self.last_error = ""
    if self:is_terminal() then return self:fail("E_FINISHED") end
    local backup = not self.scratch and E.deepCopy(self.state) or nil
    local keepCounts = a.type == "resolve"
    local lastCount, lastExcess = self.last_effect_count, self.last_excess
    self:resetTransient()
    if keepCounts then
        self.last_effect_count, self.last_excess = lastCount, lastExcess
    else
        self.last_effect_count, self.last_excess = 0, 0
    end
    self.state.loop_steps = 0
    self.events = {} -- the observer log of this action, for the board UI
    if not self:dispatch(a) then
        local err = self.last_error
        if backup then self.state = backup end
        self.last_error = err
        return false
    end
    if not self:finish_resolution() then
        if backup then self.state = backup end
        local s = self.state
        s.result.result, s.result.reason, s.result.winner = RESULT.DRAW, REASON.ERRORED, 0
        s.phase = PHASE.MATCH_FINISHED
        self.last_error = "E_LOOP"
        return false
    end
    self.state.v = self.state.v + 1
    return true
end

function E:current_player()
    local s = self.state
    if self:is_terminal() then return -1 end
    if s.phase == PHASE.MULLIGAN then
        if not s.mulligan_answered[1] then return 0 end
        if not s.mulligan_answered[2] then return 1 end
        return 0
    end
    if s.pending.active then return s.pending.seat end
    return s.active
end

-- 1-based index into legal_moves() / enumerate_specs().
function E:apply_move(index)
    local specs = self:enumerate_specs()
    local sp = specs[index]
    if not sp then return self:fail("E_STALE") end
    return self:apply_action(sp.action)
end

function E:end_reason()
    return self:is_terminal() and D.REASON_NAME[self.state.result.reason] or ""
end
