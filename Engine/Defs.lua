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

D.ZONE = { DECK = 0, HAND = 1, BOARD = 2, GRAVEYARD = 3, SETASIDE = 4, SECRET = 5, WEAPON = 6, HERO = 7, HEROPOWER = 8,
    QUEST = 9 }
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
    -- run waves 2026-11-10..19 (EffectSpec): every new field defaults to 0 / false / "" in the reference.
    discoverSummonSpelled = false, delayEnd = false, delayTurns = 0, inHand = 0, remainingHealth = 0,
    healthOnly = false, targetName = "", nameFamily = false, historyType = 0, historyClass = 0, historyTrait = 0,
    historyCost = 0, historyPaid = 0, historySchool = 0, historyOther = false, historyBare = false,
    historyBoth = false, remember = false, origin = 0, firstEachTurn = 0, fromGraveyard = false, discoverCast = 0,
    fromHistory = 0, historyPick = 0, replay = 0, historyTarget = 0, castOnSelf = false, castStrict = false,
    costCap = 0, copyDeathrattle = 0, distinct = 0, diedWhen = 0, copyFrom = 0, discoverCopy = false,
    deckPosition = 0, deckCount = 0, attackJoin = 0, attackThenDies = false, frozenOnly = false,
    attackBelowSource = false, subjectCostMin = 0, subjectCostMax = 0, questKind = 0, questNext = "",
    sourcePhrase = "", wording = "",
    -- Run-time only (never loaded): a stat pair resolved into amount / amount2, an exact Cost bound for a random summon.
    pairValue = false, resolvedCost = -1,
    -- Derived at load (bits for the string fields).
    keywordBits = 0, keywordFilterBits = 0, subjectKeywordBits = 0, conditionKeywordBits = 0, countKeywordBits = 0,
    raceFilterBits = 0, conditionRaceBits = 0, subjectRaceBits = 0, excludeRaceBits = 0, countRaceBits = 0,
    costCountRaceBits = 0, amountSourceRaceBits = 0, subjectSchoolNum = 0, conditionSchoolNum = 0,
    subjectTraitNum = 0, traitFilterNum = 0, pickCostNum = 0, questGoalNum = 0,
}

-- SubjectTrait by its serialized name (loader.cpp kTraits), the reference's int values.
local TRAITS = { "secret", "overload", "combo", "outcast", "echo", "neutral", "otherClass", "battlecryOrCombo",
    "handEdge", "handLeft", "handRight", "libram", "frenzy", "colossal", "magnetic", "quickdraw", "oddAttack",
    "hasType", "multiType" }
D.TRAIT = {}
for i, name in ipairs(TRAITS) do D.TRAIT[name] = i end
D.TRAIT_NUM = {}
for i, name in ipairs(TRAITS) do D.TRAIT_NUM[name:upper()] = i end   -- SECRET = 1, ..., MULTITYPE = 19
-- QuestGoal by name (card.h quest_goal_name), 1-based like the reference.
local QUEST_GOALS = { "PLAY_CARD", "PLAY_MINION", "SUMMON_MINION", "CAST_SPELL", "SPELL_ON_MINION", "DRAW", "DISCARD",
    "HERO_POWER", "HERO_ATTACK", "SPEND_MANA", "RESTORE_HEALTH", "TAKE_DAMAGE", "GAIN_ATTACK", "SPEND_CORPSES",
    "DEAL_DAMAGE", "SPELL_DAMAGE", "SURVIVE_TURNS", "NO_DAMAGE_TURN", "UNSPENT_MANA", "FULL_BOARD", "TURNS_IN_ROW",
    "FILL_THEN_EMPTY", "DISCOVER", "SHUFFLE" }
D.QUEST_GOAL = {}
for i, name in ipairs(QUEST_GOALS) do D.QUEST_GOAL[name] = i end
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
    -- The reference loader turns these names into ints (loader.cpp): traits, "highest"/"lowest", quest goals.
    fx.subjectTraitNum = fx.subjectTrait and D.TRAIT[fx.subjectTrait] or 0
    fx.traitFilterNum = fx.traitFilter and D.TRAIT[fx.traitFilter] or 0
    fx.pickCostNum = fx.pickCost == "highest" and 1 or fx.pickCost == "lowest" and 2 or 0
    fx.questGoalNum = fx.questGoal and D.QUEST_GOAL[fx.questGoal] or 0
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
    d.summons_when_drawn, d.summons_for_opponent = r.summonsWhenDrawn or false, r.summonsForOpponent or false
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

-- The designer families by name, lowercase (engine.cpp designer_families): the cards the game's own data tags as
-- one family. The word alone over- and under-reaches (Imp Master is no Imp; Vulgar Homunculus is).
local DESIGNER_FAMILIES = {
    ["imp"] = { ["backpiggy imp"] = true, ["baritone imp"] = true, ["blood imp"] = true, ["bloodbound imp"] = true, ["demonizer"] = true, ["desk imp"] = true, ["devious imp"] = true, ["doubling imp"] = true, ["draconic imp"] = true, ["dread imp"] = true, ["envoy rustwix"] = true, ["felblaze imp"] = true, ["fiddlefire imp"] = true, ["fiend"] = true, ["fiery imp"] = true, ["flame imp"] = true, ["frostbitten imp"] = true, ["grandmother imp"] = true, ["icky imp"] = true, ["imp"] = true, ["imp familiar"] = true, ["imp gang boss"] = true, ["imp gang stooge"] = true, ["imp-formant"] = true, ["imp-oster"] = true, ["impcaster"] = true, ["impfernal!"] = true, ["impish aid"] = true, ["imploc"] = true, ["imployee of the month"] = true, ["imprisoned homunculus"] = true, ["imprisoned scrap imp"] = true, ["jumbo imp"] = true, ["killmox, the banished one"] = true, ["malchezaar's imp"] = true, ["mischievous imp"] = true, ["monstrous imp"] = true, ["nether imp"] = true, ["opera soloist"] = true, ["orchestral imp"] = true, ["piggyback imp"] = true, ["ring matron"] = true, ["rusted devil"] = true, ["sacrificial imp"] = true, ["sewer imp"] = true, ["sneaky devil"] = true, ["street trickster"] = true, ["tiny knight of evil"] = true, ["unlicensed apothecary"] = true, ["vulgar homunculus"] = true, ["witchwood imp"] = true, ["worthless imp"] = true, ["wretched queen"] = true },
    ["lackey"] = { ["draconic lackey"] = true, ["ethereal lackey"] = true, ["faceless lackey"] = true, ["goblin lackey"] = true, ["kobold lackey"] = true, ["titanic lackey"] = true, ["witchy lackey"] = true },
    ["libram"] = { ["libram of clarity"] = true, ["libram of compassion"] = true, ["libram of divinity"] = true, ["libram of faith"] = true, ["libram of holiness"] = true, ["libram of hope"] = true, ["libram of judgment"] = true, ["libram of justice"] = true, ["libram of wisdom"] = true },
    ["protoss"] = { ["archon"] = true, ["blink"] = true, ["carrier"] = true, ["chrono boost"] = true, ["colossus"] = true, ["construct pylons"] = true, ["dark templar"] = true, ["hallucination"] = true, ["high templar"] = true, ["immortal"] = true, ["interceptor"] = true, ["mothership"] = true, ["photon cannon"] = true, ["resonance coil"] = true, ["sentry"] = true, ["shield battery"] = true, ["void ray"] = true, ["warp gate"] = true, ["zealot"] = true },
    ["si:7"] = { ["si:7 agent"] = true, ["si:7 assassin"] = true, ["si:7 extortion"] = true, ["si:7 infiltrator"] = true, ["si:7 informant"] = true, ["si:7 operative"] = true, ["si:7 scout"] = true, ["si:7 skulker"] = true, ["si:7 slayer"] = true, ["si:7 smuggler"] = true, ["si:7 supplier"] = true },
    ["spy gizmo"] = { ["fizzflash distractor"] = true, ["hidden gyroblade"] = true, ["noggen-fog generator"] = true, ["spy-o-matic"] = true, ["undercover mole"] = true },
    ["terran"] = { ["banshee"] = true, ["battlecruiser"] = true, ["concussive shells"] = true, ["ghost"] = true, ["hellbat"] = true, ["hellion"] = true, ["liberator"] = true, ["lift off"] = true, ["lock on"] = true, ["marine"] = true, ["medivac"] = true, ["missile pod"] = true, ["raven"] = true, ["salvage the bunker"] = true, ["scv"] = true, ["siege tank"] = true, ["siege tank, deployed"] = true, ["starport"] = true, ["thor"] = true, ["thor, explosive payload"] = true, ["ultra-capacitor"] = true, ["viking"] = true, ["yamato cannon"] = true },
    ["treant"] = { ["blood treant"] = true, ["felwood treant"] = true, ["fleeing treant"] = true, ["mana treant"] = true, ["tranquil treant"] = true, ["treant"] = true, ["treant of life"] = true, ["treant totem"] = true, ["twisted treant"] = true },
    ["whelp"] = { ["accelerated whelp"] = true, ["amber whelp"] = true, ["big ol' whelp"] = true, ["black whelp"] = true, ["blackwing experiment"] = true, ["carrier whelp"] = true, ["clay whelp"] = true, ["emberscarred whelp"] = true, ["emerald whelp"] = true, ["giftwrapped whelp"] = true, ["happy whelp"] = true, ["juvenile thorignir"] = true, ["mechanical whelp"] = true, ["nightscale whelp"] = true, ["onyxian whelp"] = true, ["plagued hatchling"] = true, ["restless whelp"] = true, ["splish-splash whelp"] = true, ["starlight whelp"] = true, ["twilight whelp"] = true, ["wee whelp"] = true, ["whelp"] = true, ["whelp of the bronze"] = true, ["whelp of the infinite"] = true, ["whelpagazzor"] = true, ["winterspring whelp"] = true },
    ["zerg"] = { ["baneling"] = true, ["baneling barrage"] = true, ["consume"] = true, ["creep tumor"] = true, ["evolution chamber"] = true, ["hive queen"] = true, ["hydralisk"] = true, ["infestor"] = true, ["larva"] = true, ["lurker"] = true, ["mutalisk"] = true, ["nydus worm"] = true, ["roach"] = true, ["spawning pool"] = true, ["spine crawler"] = true, ["ultralisk"] = true, ["ultralisk cavern"] = true, ["viper"] = true, ["zergling"] = true },
}

-- card_named (card.h): a name, case-blind and blind to a leading "The"; with family, every card whose name holds the word.
local function cardNamed(cardName, name, family)
    local have, want = cardName:lower(), name:lower()
    if want == "" then return false end
    if not family then
        local function bare(v) return v:sub(1, 4) == "the " and v:sub(5) or v end
        return bare(have) == bare(want)
    end
    local at = 1
    while true do
        local i = have:find(want, at, true)
        if not i then return false end
        local j = i + #want
        local starts = i == 1 or not have:sub(i - 1, i - 1):match("%w")
        local ends = j > #have or not have:sub(j, j):match("%w")
        if starts and ends then return true end
        at = i + 1
    end
end
D.cardNamed = cardNamed

-- card_is_named (engine.cpp): a family name asks the designer family first ("Imps" finds "imp").
function D.cardIsNamed(d, name, family)
    if family then
        local key = name:lower()
        local members = DESIGNER_FAMILIES[key]
        if not members and #key > 1 and key:sub(-1) == "s" then members = DESIGNER_FAMILIES[key:sub(1, -2)] end
        if members then return members[d.name:lower()] == true end
    end
    return cardNamed(d.name, name, family)
end

function D.isDesignerFamily(name)
    return DESIGNER_FAMILIES[name:lower()] ~= nil
end

D.COIN_ID = "TAVERN_COIN"
