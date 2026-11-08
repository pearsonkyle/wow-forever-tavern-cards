-- Deck codes: every collectible card has its own 24-bit code, and a deck survives encode/decode.
local T = {}

local function setup(TC)
    time = os.time
    geterrorhandler = function() return error end
    TC.db = { collection = {}, dust = 0, ledger = {}, decks = {} }
    TC.char = { granted = {} }
    dofile("Collection/Collection.lua")
    dofile("Collection/Decks.lua")
    return TC.Decks
end

T.card_hashes_are_unique = function(TC)
    local Decks = setup(TC)
    local seen = {}
    for _, id in ipairs(TC.CardOrder) do
        if bit.band(TC.Cards[id].flags, 1) ~= 0 then
            local h = Decks.Hash24(id)
            assert(not seen[h], ("deck code collision: %s and %s"):format(id, tostring(seen[h])))
            seen[h] = id
        end
    end
end

T.code_round_trip = function(TC)
    local Decks = setup(TC)
    local deck = { class = "HUNTER", name = "x", cards = {} }
    for _, id in ipairs(TC.AI.buildDeck("HUNTER", 4, 4)) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
    local code = Decks:Encode(deck)
    assert(#code <= 140, "code too long for chat: " .. #code)
    local back = assert(Decks:Decode(code))
    assert(back.class == "HUNTER" and Decks:Count(back) == 30)
    for id, n in pairs(deck.cards) do assert(back.cards[id] == n, id) end
    assert(Decks:Decode("TCD1.HUNTER.abc") == nil)
    assert(select(2, Decks:Decode("TCD1.NOPE.AAAA")) == "class")
    local imported = assert(Decks:Import(code, "Imported"))
    assert(imported.name == "Imported" and #TC.db.decks == 1)
end

T.chat_links = function(TC)
    local Decks = setup(TC)
    C_Timer = { After = function() end }
    TC.On = function() end
    TC.Art = { RarityColor = function() return 1, 1, 1 end }
    dofile("Social/Chat.lua")
    local out = TC.Chat.Linkify("look [Tavern Card: Hogger] and [Tavern Card: Nobody At All]")
    assert(out and out:find("|Haddon:TavernCards:card:", 1, true) and out:find("[Tavern Card: Nobody At All]", 1, true))
    local deck = { class = "MAGE", name = "Burn", cards = {} }
    for _, id in ipairs(TC.AI.buildDeck("MAGE", 1, 1)) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
    local text = TC.Chat:DeckText(deck)
    local linked = TC.Chat.Linkify("gg " .. text)
    local code = linked:match("|Haddon:TavernCards:deck:([^:]+):Burn|h%[Deck: Burn%]|h")
    assert(code and Decks:Decode(code), linked)
    assert(TC.Chat.Linkify("nothing here") == nil)
end

return T
