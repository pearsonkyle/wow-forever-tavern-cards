-- Decks: account-wide, any number, each bound to a class.
--
-- Rules from jankcraft (tc/ai/deck.cpp, TcEngine::build_match): exactly 30 cards, at most 2 copies
-- of a card (1 of a legendary), from the deck's class and Neutral. To play, every card must also be
-- owned in that many copies and be one the rules engine can play.

local TC = TavernCards_NS

local Decks = {}
TC.Decks = Decks

Decks.SIZE = 30
Decks.CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
    "DEATHKNIGHT", "DEMONHUNTER" }

local function list()
    TC.db.decks = TC.db.decks or {}
    return TC.db.decks
end

function Decks:All()
    return list()
end

function Decks:Get(deckId)
    for _, deck in ipairs(list()) do
        if deck.id == deckId then
            return deck
        end
    end
end

function Decks:Create(class, name)
    local decks = list()
    TC.db.nextDeckId = (TC.db.nextDeckId or 0) + 1
    local cls = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
    local deck = { id = TC.db.nextDeckId, class = class, name = name or ("Custom " .. cls), cards = {} }
    decks[#decks + 1] = deck
    return deck
end

function Decks:Delete(deckId)
    local decks = list()
    for i, deck in ipairs(decks) do
        if deck.id == deckId then
            table.remove(decks, i)
            return true
        end
    end
end

function Decks:Duplicate(deckId)
    local src = self:Get(deckId)
    if not src then return end
    local copy = self:Create(src.class, src.name .. " (copy)")
    for id, n in pairs(src.cards) do
        copy.cards[id] = n
    end
    return copy
end

function Decks:Count(deck)
    local n = 0
    for _, c in pairs(deck.cards) do
        n = n + c
    end
    return n
end

function Decks:AllowsCard(deck, id)
    local card = TC.Cards[id]
    return card ~= nil and bit.band(card.flags, 8) ~= 0 and (card.family == deck.class or card.family == "NEUTRAL")
end

-- Adds one copy; returns true, or false and why ("full", "class", "copies", "owned").
function Decks:Add(deck, id)
    if not self:AllowsCard(deck, id) then
        return false, "class"
    end
    if self:Count(deck) >= self.SIZE then
        return false, "full"
    end
    local have = deck.cards[id] or 0
    if have >= TC.Collection:Cap(id) then
        return false, "copies"
    end
    if have >= TC.Collection:Count(id) then
        return false, "owned"
    end
    deck.cards[id] = have + 1
    return true
end

function Decks:Remove(deck, id)
    local have = deck.cards[id]
    if not have then return false end
    deck.cards[id] = have > 1 and have - 1 or nil
    return true
end

-- Problems that stop a deck from being played, as short sentences (empty when ready).
function Decks:Problems(deck)
    local problems = {}
    local n = self:Count(deck)
    if n ~= self.SIZE then
        problems[#problems + 1] = ("%d / %d cards"):format(n, self.SIZE)
    end
    local missing, unplayable = 0, 0
    for id, count in pairs(deck.cards) do
        if TC.Collection:Count(id) < count then
            missing = missing + (count - TC.Collection:Count(id))
        end
        if not TC.PlayableNow[id] then
            unplayable = unplayable + count
        end
    end
    if missing > 0 then
        problems[#problems + 1] = ("%d card(s) you don't own"):format(missing)
    end
    if unplayable > 0 then
        problems[#problems + 1] = ("%d card(s) not playable yet"):format(unplayable)
    end
    return problems
end

function Decks:IsReady(deck)
    return #self:Problems(deck) == 0
end

-- The 30 ids in a stable order (cost, then name, then id): what the engine receives.
function Decks:CardList(deck)
    local ids = {}
    for id, count in pairs(deck.cards) do
        for _ = 1, count do
            ids[#ids + 1] = id
        end
    end
    table.sort(ids, function(a, b)
        local x, y = TC.Cards[a], TC.Cards[b]
        if x.cost ~= y.cost then return x.cost < y.cost end
        if x.name ~= y.name then return x.name < y.name end
        return a < b
    end)
    return ids
end

-- Mana curve buckets 0..7 (7 = 7+).
function Decks:Curve(deck)
    local curve = { [0] = 0, 0, 0, 0, 0, 0, 0, 0 }
    for id, count in pairs(deck.cards) do
        local c = math.min(7, TC.Cards[id].cost)
        curve[c] = curve[c] + count
    end
    return curve
end

-- Fills the deck to 30 with owned, playable cards, favoring a sensible curve (stable choice).
function Decks:Fill(deck)
    local want = { [0] = 1, 4, 6, 6, 5, 4, 2, 2 }
    local curve = self:Curve(deck)
    local candidates = {}
    for _, id in ipairs(TC.CardOrder) do
        if self:AllowsCard(deck, id) and (TC.PlayableNow[id] or not TC.EngineReady) and TC.Collection:Count(id) > 0 then
            candidates[#candidates + 1] = id
        end
    end
    local added = true
    while self:Count(deck) < self.SIZE and added do
        added = false
        table.sort(candidates, function(a, b)
            local ca, cb = math.min(7, TC.Cards[a].cost), math.min(7, TC.Cards[b].cost)
            local na, nb = (want[ca] or 0) - curve[ca], (want[cb] or 0) - curve[cb]
            if na ~= nb then return na > nb end
            local fa, fb = TC.Cards[a].family == deck.class, TC.Cards[b].family == deck.class
            if fa ~= fb then return fa end
            return a < b
        end)
        for _, id in ipairs(candidates) do
            if self:Add(deck, id) then
                local c = math.min(7, TC.Cards[id].cost)
                curve[c] = curve[c] + 1
                added = true
                break
            end
        end
    end
    return self:Count(deck)
end
