local T = {}

local function setup(TC)
    time = time or os.time
    geterrorhandler = geterrorhandler or function() return error end
    TC.db = { collection = {}, dust = 0, ledger = {} }
    TC.char = { granted = {} }
    dofile("Collection/Collection.lua")
    return TC.Collection
end

T.copies_cap_then_dust = function(TC)
    local C = setup(TC)
    local events = {}
    C:Subscribe(function(e, p) events[#events + 1] = p end)
    assert(C:AddCard("EX1_556", "test") == "new")      -- Harvest Golem (COMMON)
    assert(C:AddCard("EX1_556", "test") == "copy")
    local result, dust = C:AddCard("EX1_556", "test")
    assert(result == "dust" and dust == 5, "a third COMMON copy is 5 dust")
    assert(C:Count("EX1_556") == 2)
    assert(#events == 3 and #TC.db.ledger == 3)
end

T.legendary_cap_is_one = function(TC)
    local C = setup(TC)
    assert(C:AddCard("NEW1_040", "test") == "new")      -- Hogger
    local result, dust = C:AddCard("NEW1_040", "test")
    assert(result == "dust" and dust == 400 and TC.db.dust == 400)
end

T.basic_cards_are_always_owned = function(TC)
    local C = setup(TC)
    assert(C:Count("CS2_142") == 2, "Kobold Geomancer is a Basic card")
    assert(C:AddCard("CS2_142", "test") == "dust")
    assert(C:Disenchant("CS2_142") == false)
end

T.decks_follow_the_rules = function(TC)
    local C = setup(TC)
    TC.db.decks = {}
    TC.PlayableNow = { CS2_142 = true }
    LOCALIZED_CLASS_NAMES_MALE = nil
    dofile("Collection/Decks.lua")
    local D = TC.Decks
    local deck = D:Create("MAGE")
    assert(D:Add(deck, "CS2_029") and D:Add(deck, "CS2_029"), "two Fireballs")
    assert(select(2, D:Add(deck, "CS2_029")) == "copies")
    assert(select(2, D:Add(deck, "CS2_032_NOPE")) == "class")
    assert(select(2, D:Add(deck, "EX1_116")) == "owned", "Leeroy is not owned")
    assert(select(2, D:Add(deck, "CS2_101")) == "class", "a Paladin card in a Mage deck")
    assert(D:Count(deck) == 2 and #D:Problems(deck) == 2, "size and unplayable")
    D:Remove(deck, "CS2_029")
    assert(D:Count(deck) == 1)
end

T.grant_pays_once_per_source = function(TC)
    local C = setup(TC)
    assert(C:Grant("q:176", "NEW1_040", "Quest") == "new")
    assert(C:Grant("q:176", "NEW1_040", "Quest") == nil)
    assert(C:Count("NEW1_040") == 1)
end

T.craft_and_disenchant = function(TC)
    local C = setup(TC)
    TC.db.dust = 100
    assert(C:Craft("EX1_116") == false, "Leeroy costs 1600")
    TC.db.dust = 1600
    assert(C:Craft("EX1_116") == true and TC.db.dust == 0 and C:Count("EX1_116") == 1)
    assert(C:Craft("EX1_116") == false, "cannot craft past the cap")
    assert(C:Disenchant("EX1_116") == true and TC.db.dust == 400 and C:Count("EX1_116") == 0)
end

return T
