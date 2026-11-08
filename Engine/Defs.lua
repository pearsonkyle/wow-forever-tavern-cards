-- Engine constants and card definitions: a port of the reference engine's tc/card.h and tc/state.h enums, and
-- of the CardDef the reference loader builds from catalogue + programs.
--
-- Every numeric value here is the reference enum's, because snapshots compare field by field and filters
-- store "enum + 1" (familyFilter, schoolFilter, type_filter ...).

local TC = TavernCards_NS
local bit = bit
local band, bor = bit.band, bit.bor

local D = {}
TC.EngineDefs = D

D.ZONE = { DECK = 0, HAND = 1, BOARD = 2, GRAVEYARD = 3, SETASIDE = 4, SECRET = 5, WEAPON = 6, HERO = 7, HEROPOWER = 8 }
D.PHASE = { MULLIGAN = 0, START_TURN = 1, PLAYER_ACTIONS = 2, END_TURN_RESOLUTION = 3, MATCH_FINISHED = 4 }
D.RESULT = { ONGOING = 0, WIN_A = 1, WIN_B = 2, DRAW = 3 }
D.REASON = { NONE = 0, LIFE = 1, FATIGUE = 2, CONCEDE = 3, TIMEOUT = 4, TURN_LIMIT = 5, ABANDONED = 6, DRAW = 7,
    LOOP = 8, ERRORED = 9 }
D.REASON_NAME = { [0] = "", "life", "fatigue", "concede", "timeout", "turn_limit", "abandoned", "draw", "loop", "errored" }

D.FAMILY = { WARRIOR = 0, PALADIN = 1, HUNTER = 2, ROGUE = 3, PRIEST = 4, DEATHKNIGHT = 5, SHAMAN = 6, MAGE = 7,
    WARLOCK = 8, DRUID = 9, DEMONHUNTER = 10, NEUTRAL = 11 }
D.RARITY = { FREE = 0, COMMON = 1, RARE = 2, EPIC = 3, LEGENDARY = 4 }
D.SCHOOL = { [""] = 0, arcane = 1, fire = 2, frost = 3, holy = 4, nature = 5, shadow = 6, fel = 7 }
D.CARDTYPE = { MINION = 0, SPELL = 1, WEAPON = 2, LOCATION = 3, HERO = 4, HERO_POWER = 5 }

local KEYWORD_NAMES = { "taunt", "charge", "rush", "divine_shield", "windfury", "lifesteal", "stealth", "poisonous",
    "freeze", "reborn", "elusive", "spell_damage", "battlecry", "deathrattle", "cant_attack", "immune",
    "immune_while_attacking", "miniaturize" }
D.KW = {}
for i, name in ipairs(KEYWORD_NAMES) do
    D.KW[name] = bit.lshift(1, i - 1)
end
local KW = D.KW
KW.NONE = 0
KW.TAUNT, KW.CHARGE, KW.RUSH, KW.DIVINE_SHIELD = KW.taunt, KW.charge, KW.rush, KW.divine_shield
KW.WINDFURY, KW.LIFESTEAL, KW.STEALTH, KW.POISONOUS = KW.windfury, KW.lifesteal, KW.stealth, KW.poisonous
KW.FREEZE, KW.REBORN, KW.ELUSIVE, KW.SPELL_DAMAGE = KW.freeze, KW.reborn, KW.elusive, KW.spell_damage
KW.BATTLECRY, KW.DEATHRATTLE, KW.CANT_ATTACK, KW.IMMUNE = KW.battlecry, KW.deathrattle, KW.cant_attack, KW.immune
KW.IMMUNE_ATTACKING, KW.MINIATURIZE = KW.immune_while_attacking, KW.miniaturize

local RACE_NAMES = { "beast", "undead", "elemental", "mechanical", "dragon", "demon", "pirate", "murloc", "draenei",
    "naga", "totem", "quilboar", "all" }
D.RACE = { NONE = 0 }
for i, name in ipairs(RACE_NAMES) do
    D.RACE[name] = bit.lshift(1, i - 1)
end
D.RACE.ALL = D.RACE.all

function D.hasRace(races, race)
    if band(races, D.RACE.ALL) ~= 0 then
        return true
    end
    return band(races, race) ~= 0
end

-- "taunt,divine_shield" or "rush, and windfury" -> bits (the loader's parse_effect).
local function keywordBits(list)
    if not list or list == "" then
        return 0
    end
    local bits = 0
    for item in (list .. ","):gmatch("([^,]*),") do
        item = item:gsub("^%s+", ""):gsub("%s+$", ""):gsub("^and%s+", "")
        if item ~= "" then
            bits = bor(bits, KW[item] or error("unknown keyword " .. item))
        end
    end
    return bits
end
D.keywordBits = keywordBits

local function raceBit(name)
    if not name or name == "" then
        return 0
    end
    return D.RACE[name] or error("unknown race " .. name)
end
D.raceBit = raceBit

-- ---- effects ------------------------------------------------------------------------------------

-- Every field an effect is read with, at its reference default. Programs.lua strips defaults, so reads fall
-- through to here.
local EFFECT_DEFAULTS = {
    trigger = "ON_PLAY", op = "", amount = 0, amount2 = 0, type_filter = 0, token = "", spell = false,
    ["repeat"] = 1, condition = "NONE", conditionAmount = 0, conditionType = 0, conditionTrails = false,
    costCount = "NONE", amountSource = "NONE", valueSource = "NONE", followUpCondition = "NONE",
    costMin = 0, costMax = 0, familyFilter = 0, rarityFilter = 0, schoolFilter = 0, excludeSource = false,
    damagedOnly = false, undamagedOnly = false, bothPlayers = false, temporary = false, durationTurns = 0,
    subjectType = 0, subjectSide = 0, subjectCost = 0, subjectHealth = 0, subjectAttackMax = 0,
    subjectAttackMin = 0, subjectName = "", targetAttackMin = 0, targetAttackMax = 0, targetHealthMin = 0,
    targetHealthMax = 0, split = false, fromDeck = false, fromHand = false, prompt = false, additional = false,
    requiresPrevious = false, printOnly = false, delayed = false, corpseCost = 0, corpseMax = 0, armorCost = 0,
    discardCostSchool = 0, deckCostToken = "", repeatLess = false, repeatPerCount = false, repeatPrinted = false,
    countSelector = false, countType = 0, improved = false, statsBoth = false, discoverTakeAll = false,
    doubleSpellDamage = false, whileAttacking = false, namedAnywhere = false, otherClass = false,
    buffHand = false, buffDeck = false, buffBoard = false, buffRandom = false, buffAll = true,
    forOpponent = false, summonAttacks = 0, costOverride = -1, implicitTarget = false, secretOnly = false,
    costCountName = "", tokenDisplay = "", transformPool = 0, classPool = 0, discoverCostDelta = 0,
    summonNamed = false, tokenUnnamed = false, oneInHand = false, excessToHero = false, stuffed = false,
    zeroCost = false, diesEndOfTurn = false, staysInHand = false, darkGift = false, freshCopy = false,
    statsFromSource = false, statsFromHeroGains = false, chooseOneOnly = false, extra = false,
    heroPowerShort = false, heroPowerDelta = false, toOwnHand = false, silent = false, damageRange = false,
    takeVerb = false, setVerb = false, discoverSummon = false, discoverGuessCopy = false, discoverChain = false,
    shuffleACopy = false, thenJoin = false, explodesWording = false, resummonNoun = false, previousPlural = false,
    bonusSpellDamage = 0, countSide = "", countZone = "", countKeyword = "", countRace = "",
    countDamagedOnly = false, countExcludeSource = false,
    -- Derived at load (bits for the string fields).
    keywordBits = 0, keywordFilterBits = 0, subjectKeywordBits = 0, conditionKeywordBits = 0, countKeywordBits = 0,
    raceFilterBits = 0, conditionRaceBits = 0, subjectRaceBits = 0, excludeRaceBits = 0, countRaceBits = 0,
    costCountRaceBits = 0, amountSourceRaceBits = 0, subjectSchoolNum = 0, conditionSchoolNum = 0,
}
local EFFECT_META = { __index = EFFECT_DEFAULTS }
local TARGET_DEFAULT = { kind = "ALL", side = "ANY_CHARACTER" }
D.EFFECT_DEFAULTS = EFFECT_DEFAULTS
D.EFFECT_META = EFFECT_META

local prepareList

local function prepareEffect(fx)
    if getmetatable(fx) == EFFECT_META then
        return fx
    end
    fx.target = fx.target or TARGET_DEFAULT
    fx.keywordBits = keywordBits(fx.keyword)
    fx.keywordFilterBits = keywordBits(fx.keywordFilter)
    fx.subjectKeywordBits = keywordBits(fx.subjectKeyword)
    fx.conditionKeywordBits = keywordBits(fx.conditionKeyword)
    fx.countKeywordBits = keywordBits(fx.countKeyword)
    fx.raceFilterBits = raceBit(fx.raceFilter)
    fx.conditionRaceBits = raceBit(fx.conditionRace)
    fx.subjectRaceBits = raceBit(fx.subjectRace)
    fx.excludeRaceBits = raceBit(fx.excludeRace)
    fx.countRaceBits = raceBit(fx.countRace)
    fx.costCountRaceBits = raceBit(fx.costCountRace)
    fx.amountSourceRaceBits = raceBit(fx.amountSourceRace)
    -- subject_school / condition_school are int(SpellSchool) + 1 in the reference (0 = none).
    fx.subjectSchoolNum = fx.subjectSchool and (D.SCHOOL[fx.subjectSchool] or 0) + 1 or 0
    fx.conditionSchoolNum = fx.conditionSchool and (D.SCHOOL[fx.conditionSchool] or 0) + 1 or 0
    fx.followUp = prepareList(fx.followUp)
    fx.replacement = prepareList(fx.replacement)
    return setmetatable(fx, EFFECT_META)
end

local EMPTY = {}
prepareList = function(list)
    if not list or #list == 0 then
        return EMPTY
    end
    for i = 1, #list do
        prepareEffect(list[i])
    end
    return list
end
D.prepareEffect = prepareEffect
D.EMPTY = EMPTY

-- A copy that can be modified (scaled_effect works on copies).
function D.copyEffect(fx)
    local out = {}
    for k, v in pairs(fx) do
        out[k] = v
    end
    return setmetatable(out, EFFECT_META)
end

-- ---- card definitions --------------------------------------------------------------------------

local defs = {}

-- The CardDef for an id, or nil. Built on first use from Data/Cards.lua + Engine/Data/Programs.lua.
function D.def(id)
    local d = defs[id]
    if d ~= nil then
        return d or nil
    end
    local card = TC.Cards[id]
    if not card then
        defs[id] = false
        return nil
    end
    local prog = TC.Programs[id] or EMPTY
    d = {
        id = id, name = card.name, type = card.type, typeNum = D.CARDTYPE[card.type] or 0,
        family = card.family, familyNum = D.FAMILY[card.family] or D.FAMILY.NEUTRAL,
        rarity = card.rarity, rarityNum = D.RARITY[card.rarity] or 0,
        school = card.school or "", schoolNum = D.SCHOOL[card.school or ""] or 0,
        cost = card.cost, attack = card.attack, health = card.health, durability = card.durability,
        keywords = card.keywords, races = card.races, spell_damage = card.spellDamage or 0,
        text = card.text or "",
        collectible = band(card.flags, 1) ~= 0, droppable = band(card.flags, 2) ~= 0,
        implemented = band(card.flags, 4) ~= 0, made_only = band(card.flags, 16) ~= 0,
        effects = prepareList(prog.effects),
        abilities = prog.abilities,                 -- grammar card: {kind, count} slices
        overload = prog.overload or 0, secret = prog.secret or false, cant_attack = prog.cantAttack or false,
        dormant_turns = prog.dormantTurns or 0, tradeable = prog.tradeable or false,
        magnetic = prog.magnetic or false, echo = prog.echo or false, twinspell = prog.twinspell or false,
        repeatable = prog.repeatable or false, prepare = prog.prepare or false, colossal = prog.colossal or 0,
        pays_with = prog.paysWith or 0, casts_when_drawn = prog.castsWhenDrawn or false,
        bonus_effects = prog.bonusEffects or 0, bonus_effects_reroll = prog.bonusEffectsReroll or false,
        swap_in_hand = prog.swapInHand or false, all_minion_types = prog.allMinionTypes or false,
        numbered = prog.numbered or false, hand_turns = prog.handTurns or 0, sandwich = prog.sandwich or "",
        titan_abilities = prog.titanAbilities or EMPTY, starship_piece = prog.starshipPiece or false,
        choices = EMPTY,
    }
    d.choice_labels = prog.choiceLabels or EMPTY
    if prog.choices then
        d.choices = {}
        for i, option in ipairs(prog.choices) do
            d.choices[i] = prepareList(option)
        end
    end
    -- Attributes the reference loader reads off printed reminders ("(3 Drinks left!)", "Doesn't leave a Corpse").
    local r = TC.CardReminders and TC.CardReminders[id] or EMPTY
    d.launch_upgrade, d.next_drink = r.launchUpgrade or "", r.nextDrink or ""
    d.held_spell_transform, d.held_spell_threshold = r.heldSpellTransform or "", r.heldSpellThreshold or 0
    d.repeat_next_school, d.spellburst_kept_by = r.repeatNextSchool or 0, r.spellburstKeptBy or 0
    d.leaves_no_corpse = r.leavesNoCorpse or false
    defs[id] = d
    return d
end

-- The engine's pool order: Catalogue::all() is id order, and so is TC.CardOrder (never re-sorted here).
function D.all()
    return TC.CardOrder
end

-- "Collectible AND implemented" and not made-only: what every random pool draws from (pool_card).
function D.poolCard(d)
    return d ~= nil and d.collectible and d.implemented and not d.made_only
end

D.COIN_ID = "TAVERN_COIN"
