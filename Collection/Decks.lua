-- Decks: account-wide, any number, each bound to a class.
--
-- Rules from the reference engine (tc/ai/deck.cpp, TcEngine::build_match): exactly 30 cards, at most 2 copies
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
    local missing, unplayable, illegal = 0, 0, 0
    for id, count in pairs(deck.cards) do
        if not self:AllowsCard(deck, id) or count > TC.Collection:Cap(id) then
            illegal = illegal + count
        end
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
    if illegal > 0 then
        problems[#problems + 1] = ("%d card(s) not allowed in this deck"):format(illegal)
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

-- ---- deck codes --------------------------------------------------------------------------------
-- "TCD1.MAGE.<4 chars per copy>": each card is a 24-bit hash of its id in base64, so codes survive
-- data rebuilds that reorder cards (tests/test_decks.lua checks the hashes never collide).

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function hash24(id)
    local h = 7
    for i = 1, #id do
        h = (h * 131 + id:byte(i)) % 16777213
    end
    return h
end
Decks.Hash24 = hash24

local function enc4(n)
    local out = {}
    for i = 4, 1, -1 do
        local d = n % 64
        out[i] = B64:sub(d + 1, d + 1)
        n = math.floor(n / 64)
    end
    return table.concat(out)
end

local byHash
local function cardForHash(h)
    if not byHash then
        byHash = {}
        for _, id in ipairs(TC.CardOrder) do
            if bit.band(TC.Cards[id].flags, 1) ~= 0 then
                byHash[hash24(id)] = id
            end
        end
    end
    return byHash[h]
end

function Decks:Encode(deck)
    local parts = {}
    for _, id in ipairs(self:CardList(deck)) do
        parts[#parts + 1] = enc4(hash24(id))
    end
    return ("TCD1.%s.%s"):format(deck.class, table.concat(parts))
end

-- A deck table (not saved) from a code, or nil, why.
function Decks:Decode(code)
    if type(code) ~= "string" then return nil, "format" end
    local class, body = code:gsub("%s", ""):gsub("%.$", ""):match("^TCD1%.(%u+)%.([%w%+/]*)$")
    if not class or #body % 4 ~= 0 then return nil, "format" end
    local valid = false
    for _, c in ipairs(self.CLASSES) do
        if c == class then valid = true end
    end
    if not valid then return nil, "class" end
    if #body / 4 > self.SIZE then return nil, "size" end
    local deck = { class = class, cards = {} }
    for i = 1, #body, 4 do
        local n = 0
        for k = i, i + 3 do
            n = n * 64 + (B64:find(body:sub(k, k), 1, true) - 1)
        end
        local id = cardForHash(n)
        if not id then return nil, "unknown" end
        if not self:AllowsCard(deck, id) then return nil, "illegal" end
        deck.cards[id] = (deck.cards[id] or 0) + 1
        if deck.cards[id] > TC.Collection:Cap(id) then return nil, "illegal" end
    end
    return deck
end

function Decks:OwnedCount(deck)
    local n = 0
    for id, count in pairs(deck.cards) do
        n = n + math.min(count, TC.Collection:Count(id))
    end
    return n
end

-- Saves a decoded deck as a new deck of yours (cards you don't own yet show as missing).
function Decks:Import(code, name)
    local parsed, why = self:Decode(code)
    if not parsed then return nil, why end
    local deck = self:Create(parsed.class, name and name ~= "" and name or nil)
    deck.cards = parsed.cards
    return deck
end

local IMPORT_ERRORS = { format = "That is not a Tavern Cards deck code.", class = "That deck code names an unknown class.",
    unknown = "That deck has cards this version of Tavern Cards doesn't know.",
    size = "That deck code has more than 30 cards.",
    illegal = "That deck breaks the deck rules (cards of another class, or too many copies)." }
Decks.IMPORT_ERRORS = IMPORT_ERRORS

-- A deck link was clicked in chat: confirm, then import and open it.
function Decks:OfferImport(code, name)
    local parsed, why = self:Decode(code)
    if not parsed then
        TC:Print(IMPORT_ERRORS[why] or "That deck can't be imported.")
        return
    end
    local cls = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[parsed.class]) or parsed.class
    TC:Confirm(("Copy the %s deck \"%s\" into your decks?\nYou own %d of its %d cards."):format(cls, name or "", self:OwnedCount(parsed),
        self:Count(parsed)), function()
        local deck = self:Import(code, name)
        if deck then
            TC:Print("Deck \"%s\" added. Missing cards can be crafted with dust.", deck.name)
            TC:ShowWindow("decks")
        end
    end, nil, "Copy deck", CANCEL or "Cancel")
end
