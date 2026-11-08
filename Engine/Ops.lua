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

local function keywordFilterOk(fx, d)
    return fx.keywordFilterBits == 0 or band(d.keywords, fx.keywordFilterBits) == fx.keywordFilterBits
end

local OPS = {}

function E:apply_op(rawFx, target, source, controller)
    local outer = self.effect_source
    self.effect_source = source
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
    self:create_entity(d, me.owner, ZONE.DECK, at)
end

OPS.SHUFFLE_SELF = function(self, fx, target, source)
    local me = self:ent(source)
    if not me then return end
    local size = #self:deck_ids(me.owner)
    local at = size == 0 and 0 or self.state.rng:intBelow(size + 1)
    self:relocate(source, ZONE.DECK, at)
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
    local multiplier = p.herald_count < 2 and 1 or (p.herald_count < 4 and 2 or 4)
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
    local function reduce(id)
        local d = self:def_of(id)
        if d and zoneFilterOk(fx, d) then
            local t = self:ent(id)
            if t then t.cost_delta = t.cost_delta - fx.amount end
        end
    end
    if fx.buffHand and fx.buffRandom then
        local pool = {}
        for _, id in ipairs(self:hand_ids(controller)) do
            local d = self:def_of(id)
            if d and zoneFilterOk(fx, d) then pool[#pool + 1] = id end
        end
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
    self:deal_damage(target, amount, source, fx.spell, fx.excessToHero)
end

OPS.BUFF_NAMED = function(self, fx, target, source, controller, src)
    local name = fx.tokenDisplay
    if not fx.namedAnywhere and name ~= "" and name:sub(-1) == "s" then name = name:sub(1, -2) end
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
        if d and d.name == name then
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
    for _ = 1, fx.amount do self:draw_card(controller, unpack(args)) end
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
    if created ~= 0 and fx.summonAttacks ~= 0 then
        self:summon_attacks(created, fx.summonAttacks)
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
        local value = self:scaled_effect(fx, controller, source).amount
        self:apply_buff(target, value, fx.statsBoth and value or 0, fx.keywordBits, fx.temporary, srcCard(src),
            fx.durationTurns)
        return
    end
    self:apply_buff(target, fx.amount, fx.amount2, fx.keywordBits, fx.temporary, srcCard(src), fx.durationTurns)
    if fx.diesEndOfTurn then
        self:apply_buff(target, 0, 0, 0, false, "EOT_DESTROY")
    end
end

OPS.GAIN_ARMOR = function(self, fx, target)
    local t = self:ent(target)
    if t then self:gain_armor(t, fx.amount) end
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
end

OPS.GRANT_ABILITY = function(self, fx, target, source)
    if target == 0 then return end
    local grantee = self.state.entities[target]
    if not grantee or grantee.flags.silenced then return end
    local giver = self:def_of(source)
    if not giver then return end
    grantee.granted[#grantee.granted + 1] = { card_id = giver.id, index = self.effect_index }
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
    local picked = 0
    if fx.amount2 == 3 then
        local pool = {}
        for _, cid in ipairs(D.all()) do
            local cand = def(cid)
            if poolCard(cand) and PLAYABLE_TYPE[cand.type] and admits(cand) then pool[#pool + 1] = cid end
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
    local castDef, castEntity = self:def_of(picked), self:ent(picked)
    if not castDef or not castEntity then return end
    local caster = castEntity.controller
    if castDef.secret then
        local p = self:player(caster)
        if #p.secrets >= 5 then
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
    local legal = self:card_choose_targets(castDef, "ON_PLAY", caster, picked)
    if fx.forOpponent then
        local enemies = {}
        for _, id in ipairs(legal) do
            local t = self:ent(id)
            if t and t.controller ~= caster then enemies[#enemies + 1] = id end
        end
        if #enemies > 0 then legal = enemies end
    end
    if #legal > 0 then chosenTarget = legal[s.rng:intBelow(#legal) + 1] end
    self:run_effects(picked, "ON_PLAY", chosenTarget, picked)
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
    gain(self:player(controller))
    if fx.bothPlayers then gain(self:player(other(controller))) end
end

OPS.GO_DORMANT = function(self, fx, target)
    local t = self:ent(target)
    if not t or t.zone ~= ZONE.BOARD then return end
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
    local n = max(1, fx["repeat"])
    local pos = self.summon_pos
    self.summon_pos = pos < 0 and -1 or pos + n
    local madeIds = {}
    for k = 0, n - 1 do
        local made = self:summon_token(d.id, controller, pos < 0 and -1 or pos + k, false)
        if made == 0 then break end
        madeIds[#madeIds + 1] = made
    end
    local asItIs = copyOf.zone == ZONE.BOARD and not copyOf.flags.dead and copyOf.health > 0 and not fx.freshCopy
    for _, madeId in ipairs(madeIds) do
        local made = self:ent(madeId)
        if made then
            if fx.amount < 0 or fx.amount2 < 0 then
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
                    self:ready_if_charged(made)
                end
            elseif asItIs then
                made.attack = copyOf.attack
                made.max_health = copyOf.max_health
                made.health = copyOf.health
                made.keywords = copyOf.keywords
                made.spell_damage = copyOf.spell_damage
                made.flags.divine_shield = copyOf.flags.divine_shield
                self:ready_if_charged(made)
            end
        end
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
        attack, health = scaled.amount, scaled.amount
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
    local guard = 0
    while #self:hand_ids(controller) < fx.amount and guard < 10 do
        guard = guard + 1
        self:draw_card(controller, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, fx.schoolFilter,
            fx.keywordFilterBits)
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

OPS.RESURRECT = function(self, fx, target, source, controller)
    local s = self.state
    local dead = {}
    for id = 1, s.next_entity_id - 1 do
        local e = s.entities[id]
        if e.zone == ZONE.GRAVEYARD and e.owner == controller and e.flags.dead then
            local d = self:def_of(id)
            if d and d.type == "MINION" then dead[#dead + 1] = id end
        end
    end
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
        for i, id in ipairs(dead) do
            if id == picked then table.remove(dead, i) break end
        end
        local pos = self.summon_pos
        self.summon_pos = nextSummonPos(pos)
        if self:summon_token(self:def_of(picked).id, controller, pos, false) == 0 then break end
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

OPS.TRIGGER_DEATHRATTLE = function(self, fx, target)
    local t = self:ent(target)
    if not t or t.zone ~= ZONE.BOARD or t.flags.silenced then return end
    if not self:def_of(target) or not self:has_deathrattle(target) then return end
    self.summon_pos = -1
    local outerFar = self.far_right_summons
    self.far_right_summons = true
    local grants = {}
    for i, g in ipairs(t.granted) do grants[i] = g end
    self:run_effects(target, "DEATHRATTLE", 0, target)
    for _, g in ipairs(grants) do
        if self.aborted then break end
        local giver = def(g.card_id)
        local gfx = giver and g.index >= 0 and giver.effects[g.index + 1]
        if gfx then
            self:run_effect_list(gfx.followUp, target, "DEATHRATTLE", 0, target, nil)
        end
    end
    self.far_right_summons = outerFar
    self.summon_pos = -1
end

OPS.REFRESH_MANA = function(self, fx, target, source, controller)
    local p = self:player(controller)
    p.mana = min(p.max_mana, p.mana + fx.amount)
end

OPS.TRANSFORM = function(self, fx, target, source, controller)
    local s = self.state
    local t = self:ent(target)
    if not t or (t.zone ~= ZONE.BOARD and t.zone ~= ZONE.HAND and t.zone ~= ZONE.DECK) then return end
    local into
    local absolutePool = fx.token == "" and (fx.costMin ~= 0 or fx.costMax ~= 0 or fx.raceFilterBits ~= 0
        or fx.type_filter ~= 0 or fx.familyFilter ~= 0 or fx.schoolFilter ~= 0 or fx.keywordFilterBits ~= 0
        or fx.rarityFilter ~= 0)
    if fx.token == "" and (fx.fromHand or fx.fromDeck) then
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
    self:ready_if_charged(t)
end

OPS.SHUFFLE = function(self, fx, target, source, controller)
    local s = self.state
    local owner = fx.target.side == "ENEMY_HERO" and other(controller) or controller
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
    local d
    if fx.token ~= "" then
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
    if shuffled and shuffling then shuffled.drawn_from = shuffling.id end
    local size = #self:deck_ids(owner)
    local at = size == 0 and 0 or s.rng:intBelow(size)
    self:relocate(id, ZONE.DECK, at)
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

OPS.ADD_TO_HAND = function(self, fx, target, source, controller)
    local s = self.state
    local recipient = fx.forOpponent and other(controller) or controller
    local me = self:player(recipient)
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
    local theirs = self:player(other(controller)).hero_class
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
                ok = not excluded and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                    fx.rarityFilter, fx.schoolFilter)
            end
            if ok and keywordFilterOk(fx, cand) then pool[#pool + 1] = cid end
        end
    end
    if #pool > 0 then
        local d = def(pool[s.rng:intBelow(#pool) + 1])
        if d then
            local id = self:create_entity(d, recipient, ZONE.HAND, -1)
            if #self:hand_ids(recipient) > 10 then
                self:relocate(id, ZONE.GRAVEYARD, -1)
            else
                self.drawn_this_effect[#self.drawn_this_effect + 1] = id
            end
        end
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
    elseif fx.fromDeck then
        local seen = {}
        for _, id in ipairs(self:deck_ids(controller)) do
            local cand = self:def_of(id)
            if cand and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                fx.rarityFilter, fx.schoolFilter) and keywordFilterOk(fx, cand) and not seen[cand.id] then
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
                    and not (fx.chooseOneOnly and #cand.choices == 0)
                    and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax, fx.raceFilterBits, 0,
                        fx.rarityFilter, fx.schoolFilter)
                    and keywordFilterOk(fx, cand) then
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
    for _, id in ipairs(fx.fromHand and self:hand_ids(controller) or self:deck_ids(controller)) do
        local cand = self:def_of(id)
        if cand and cand.type == "MINION" and cardMatches(cand, fx.type_filter, fx.costMin, fx.costMax,
            fx.raceFilterBits, 0, fx.rarityFilter, fx.schoolFilter) and keywordFilterOk(fx, cand) then
            pool[#pool + 1] = id
        end
    end
    local want = fx["repeat"] > 1 and fx["repeat"] or 1
    local pos = self.summon_pos
    self.summon_pos = pos < 0 and -1 or pos + want
    for k = 0, want - 1 do
        if #pool == 0 then break end
        local picked = s.rng:intBelow(#pool) + 1
        local id = pool[picked]
        table.remove(pool, picked)
        if self:summon_existing(id, controller, pos < 0 and -1 or pos + k) == 0 then break end
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
        self:summon_token(chosen, controller, at, false)
        self.summon_pos = nextSummonPos(at)
        return
    end
    local costMin, costMax = fx.costMin, fx.costMax
    if fx.valueSource ~= "NONE" and fx.valueSource ~= "" then
        local scaled = self:scaled_effect(fx, controller, source)
        costMin, costMax = scaled.costMin, scaled.costMax
    end
    for _, cid in ipairs(D.all()) do
        local cand = def(cid)
        if poolCard(cand) and cand.type == "MINION" and cand.health > 0
            and cardMatches(cand, 0, costMin, costMax, fx.raceFilterBits, 0, fx.rarityFilter, 0, fx.zeroCost)
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
end

OPS.FORCE_ATTACK = function(self, fx, target, source, controller, src)
    if fx.amount2 == 1 then
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
                    self:resolve_attack(attacker, pool[self.state.rng:intBelow(#pool) + 1])
                end
            end
        end
        return
    end
    if src and src.zone == ZONE.BOARD and self:ent(target) then
        self:resolve_attack(src.id, target)
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
end

OPS.DISCARD = function(self, fx, target, source, controller)
    local t = self:ent(target)
    if t and t.zone == ZONE.HAND then self:discard_card(t.id, controller) end
end

OPS.GIVE_KEYWORD = function(self, fx, target, source, controller, src)
    self:apply_buff(target, 0, 0, fx.keywordBits, fx.temporary, srcCard(src), fx.durationTurns)
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
    if fx.target.kind == "PREVIOUS" and target ~= 0 then
        local card = self:ent(target)
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
        p.next_card_cost_delta = p.next_card_cost_delta + fx.amount
        p.next_card_cost_filter = fx.type_filter
        p.next_card_cost_school = fx.schoolFilter
        p.next_card_cost_race = fx.raceFilterBits
        p.next_card_cost_keyword = fx.keywordFilterBits
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
        local matches = {}
        for _, id in ipairs(self:hand_ids(seat)) do
            local d = self:def_of(id)
            if d and E.costFilterMatches(fx.type_filter, d)
                and not (fx.schoolFilter ~= 0 and (d.type ~= "SPELL" or d.schoolNum + 1 ~= fx.schoolFilter))
                and keywordFilterOk(fx, d)
                and not (fx.raceFilterBits ~= 0 and not hasRace(d.races, fx.raceFilterBits))
                and not (fx.excludeRaceBits ~= 0 and hasRace(d.races, fx.excludeRaceBits))
                and not (fx.otherClass and (d.familyNum == p.hero_class or d.family == "NEUTRAL")) then
                matches[#matches + 1] = id
            end
        end
        if fx.oneInHand and #matches > 0 then
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
