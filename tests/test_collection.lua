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

T.stats_count_distinct_earned_cards_only = function(TC)
    local C = setup(TC)
    local collected, total, copies, basics = C:Stats()
    assert(collected == 0 and copies == 0, "basic cards are not 'collected'")
    assert(basics > 100 and total > 2000)
    C:AddCard("EX1_556", "test")
    C:AddCard("EX1_556", "test")
    C:AddCard("EX1_556", "test")  -- third copy: dust
    C:AddCard("NEW1_040", "test")
    collected, _, copies = C:Stats()
    assert(collected == 2 and copies == 3, ("%d %d"):format(collected, copies))
    assert(C:ProgressText():find("^2 / %d+ cards collected$"))
end
T.craft_and_disenchant_one_copy_at_a_time = function(TC)
    local C = setup(TC)
    TC.db.dust = 1000
    assert(C:AddCard("EX1_556", "test") == "new")               -- own 1 of 2
    local ok = C:Craft("EX1_556")
    assert(ok and C:Count("EX1_556") == 2 and TC.db.dust == 960, "craft the second copy")
    local ok2, why = C:Craft("EX1_556")
    assert(not ok2 and why == "cap", "no third copy")
    assert(C:Disenchant("EX1_556") and C:Count("EX1_556") == 1 and TC.db.dust == 965)
    assert(C:Disenchant("EX1_556") and C:Count("EX1_556") == 0)
    assert(not C:Disenchant("EX1_556"), "nothing left to disenchant")
    TC.db.dust = 10
    local ok3, why3 = C:Craft("EX1_556")
    assert(not ok3 and why3 == "dust")
    local basic
    for id, card in pairs(TC.Cards) do
        if card.rarity == "FREE" and bit.band(card.flags, 8) ~= 0 then basic = id break end
    end
    assert(not C:Disenchant(basic), "basic cards stay")
    assert(TC.db.ledger[#TC.db.ledger].s ~= nil)
end
return T
