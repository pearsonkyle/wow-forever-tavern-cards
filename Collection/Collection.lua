-- The collection and every way a card enters it.
--
-- Rules from jankcraft (tc/collection.h, tc/economy.h): a player keeps at most as many copies as a
-- deck may hold (2, or 1 of a legendary); any copy past that is disenchanted into dust on arrival.
-- The collection and dust are account-wide; "which sources already paid" is per character.

local TC = TavernCards_NS

local Collection = {}
TC.Collection = Collection

Collection.RARITY_ORDER = { FREE = 0, COMMON = 1, RARE = 2, EPIC = 3, LEGENDARY = 4 }
Collection.DISENCHANT = { FREE = 0, COMMON = 5, RARE = 20, EPIC = 100, LEGENDARY = 400 }
Collection.CRAFT = { FREE = 0, COMMON = 40, RARE = 100, EPIC = 400, LEGENDARY = 1600 }
local LEDGER_MAX = 500

local listeners = {}

-- fn(event, payload): "card" {id, source, dust}, "dust" {amount}, "batch" {cards, dust, label}
function Collection:Subscribe(fn)
    listeners[#listeners + 1] = fn
end

local function notify(event, payload)
    for i = 1, #listeners do
        local ok, err = pcall(listeners[i], event, payload)
        if not ok then
            geterrorhandler()(err)
        end
    end
end

function Collection:Cap(id)
    local card = TC.Cards[id]
    return card and card.rarity == "LEGENDARY" and 1 or 2
end

function Collection:Count(id)
    return TC.db.collection[id] or 0
end

function Collection:IsPlayable(id)
    local card = TC.Cards[id]
    return card ~= nil and bit.band(card.flags, 8) ~= 0
end

-- Adds one copy. Returns "new", "copy" (second copy) or "dust" plus the dust gained.
function Collection:AddCard(id, source, quiet, questID)
    local card = TC.Cards[id]
    if not card then
        return nil
    end
    local db = TC.db
    local have = db.collection[id] or 0
    local result, dust = "new", 0
    if have >= self:Cap(id) then
        result = "dust"
        dust = self.DISENCHANT[card.rarity] or 0
        db.dust = db.dust + dust
    else
        db.collection[id] = have + 1
        result = have == 0 and "new" or "copy"
        if db.unseen then
            db.unseen[id] = true
        end
    end

    local ledger = db.ledger
    ledger[#ledger + 1] = { t = time(), c = id, s = source, d = dust > 0 and dust or nil, q = questID }
    if #ledger > LEDGER_MAX then
        table.remove(ledger, 1)
    end

    if not quiet then
        notify("card", { id = id, source = source, result = result, dust = dust, quest = questID })
    end
    return result, dust
end

-- Pays a source once per character. `key` identifies the source ("q:176", "lvl:20").
function Collection:Grant(key, id, source, quiet, questID)
    local granted = TC.char.granted
    if granted[key] then
        return nil
    end
    granted[key] = time()
    return self:AddCard(id, source, quiet, questID)
end

-- A ledger entry's quest, also for entries saved before the quest id was recorded.
function Collection:EntryQuest(e)
    return e.q or tonumber((e.s or ""):match("^Quest: Quest #(%d+)$"))
end

-- What a ledger entry says about its source, with quest names resolved.
function Collection:EntrySource(e)
    local q = self:EntryQuest(e)
    if q and TC.Quests then
        return "Quest: " .. TC.Quests:Info(q).name
    end
    return e.s or ""
end

function Collection:HasGranted(key)
    return TC.char.granted[key] ~= nil
end

function Collection:NotifyBatch(cards, dust, label)
    notify("batch", { cards = cards, dust = dust, label = label })
end

function Collection:Disenchant(id)
    local have = self:Count(id)
    local card = TC.Cards[id]
    if have == 0 or not card then
        return false
    end
    TC.db.collection[id] = have > 1 and have - 1 or nil
    local dust = self.DISENCHANT[card.rarity] or 0
    TC.db.dust = TC.db.dust + dust
    notify("dust", { amount = dust, id = id })
    return true, dust
end

function Collection:Craft(id)
    local card = TC.Cards[id]
    if not card or not self:IsPlayable(id) or self:Count(id) >= self:Cap(id) then
        return false, "cap"
    end
    local cost = self.CRAFT[card.rarity] or 0
    if TC.db.dust < cost then
        return false, "dust"
    end
    TC.db.dust = TC.db.dust - cost
    TC.db.collection[id] = self:Count(id) + 1
    notify("card", { id = id, source = "Crafted", result = "new", dust = 0 })
    return true
end

function Collection:Stats()
    local owned, copies, total = 0, 0, 0
    for id, card in pairs(TC.Cards) do
        if bit.band(card.flags, 8) ~= 0 then
            total = total + 1
            local n = TC.db.collection[id]
            if n then
                owned = owned + 1
                copies = copies + n
            end
        end
    end
    return owned, total, copies
end
