-- Keyword glossary: what Overload, Battlecry, Spell Damage... mean, for tooltips. A card's text is scanned
-- for each keyword (case-sensitive, whole words) and the matches are explained under it.

local TC = TavernCards_NS

local Keywords = {}
TC.Keywords = Keywords

-- Order is the order lines appear in a tooltip.
local GLOSSARY = {
    { "Battlecry", "Does something when you play it from your hand." },
    { "Deathrattle", "Does something when it dies." },
    { "Taunt", "Enemies must attack minions with Taunt first." },
    { "Charge", "Can attack the turn it is played." },
    { "Rush", "Can attack minions (not heroes) the turn it is played." },
    { "Divine Shield", "The first damage it takes is ignored; then the shield breaks." },
    { "Windfury", "Can attack twice each turn." },
    { "Mega-Windfury", "Can attack four times each turn." },
    { "Lifesteal", "Damage it deals also heals your hero." },
    { "Stealth", "Can't be attacked or targeted until it attacks." },
    { "Poisonous", "Destroys any minion it damages." },
    { "Freeze", "A Frozen character misses its next attack." },
    { "Frozen", "Misses its next attack." },
    { "Reborn", "The first time it dies, it returns with 1 Health." },
    { "Elusive", "Can't be targeted by spells or Hero Powers." },
    { "Immune", "Takes no damage." },
    { "Spell Damage", "Your spells deal that much extra damage while it is in play." },
    { "Overload", "Locks that many of your mana crystals next turn: you will have less mana to spend." },
    { "Combo", "A bonus if you already played another card this turn." },
    { "Secret", "Hidden until your opponent does the thing that triggers it, on their turn." },
    { "Silence", "Removes all card text, buffs and enchantments from a minion." },
    { "Discover", "Choose one of three cards to add to your hand." },
    { "Choose One", "Pick one of two effects when you play it." },
    { "Adapt", "Choose one of three bonuses for the minion." },
    { "Echo", "Repeatable this turn: a copy returns to your hand until the turn ends." },
    { "Magnetic", "Play it to the left of a Mech to merge them into one." },
    { "Lackey", "A 1-mana minion with a small Battlecry." },
    { "Twinspell", "Cast it twice: the first cast leaves a copy in your hand." },
    { "Tradeable", "Spend 1 mana to shuffle it into your deck and draw a new card." },
    { "Dormant", "Asleep: it can't attack or be attacked until it wakes." },
    { "Recruit", "Summon a minion from your deck." },
    { "Inspire", "Does something each time you use your Hero Power." },
    { "Outcast", "A bonus if it is the leftmost or rightmost card in your hand." },
    { "Overkill", "A bonus when it deals more damage than needed to kill." },
    { "Frenzy", "The first time it survives damage, it does something." },
    { "Spellburst", "The first time you cast a spell after it's played, it does something." },
    { "Corrupt", "Upgrades in your hand when you play a card that costs more." },
    { "Honorable Kill", "A bonus when it deals exactly enough damage to kill." },
    { "Overheal", "A bonus when you heal a character past its full Health." },
    { "Kindred", "A bonus if you played a card of the same type or tribe last turn." },
    { "Finale", "A bonus if it spends your last mana." },
    { "Quickdraw", "A bonus if you play it the turn you drew it." },
    { "Forge", "Spend 2 mana while it is in your hand to upgrade it." },
    { "Infuse", "Upgrades in your hand after enough of your minions die." },
    { "Excavate", "Dig up a treasure; each Excavate finds better ones." },
    { "Dredge", "Look at the bottom three cards of your deck and put one on top." },
    { "Manathirst", "A bonus if you have that many mana crystals." },
    { "Miniaturize", "Also adds a 1-mana mini copy to your hand." },
    { "Colossal", "Comes with extra appendage minions." },
    { "Titan", "Uses one of three abilities each turn instead of attacking." },
    { "Starship", "Build it from pieces, then launch it for a cost." },
    { "Corpse", "Death Knight resource: each friendly minion that dies leaves one." },
    { "Invoke", "Powers up Galakrond." },
    { "Location", "Use it once per turn; it has a limited number of uses." },
    { "The Coin", "Gain 1 mana crystal this turn only." },
}

local function hasWord(text, word)
    local start = 1
    while true do
        local s, e = text:find(word, start, true)
        if not s then return false end
        local before = s > 1 and text:sub(s - 1, s - 1) or " "
        local after = text:sub(e + 1, e + 1)
        if not before:match("[%a]") and not after:match("[%a]") then return true end
        start = e + 1
    end
end

-- { {keyword, explanation}, ... } for a card's text (and its keyword bits).
function Keywords:For(id)
    local card = TC.Cards[id]
    if not card then return {} end
    local text = (card.shown or card.text or ""):gsub("<[^>]+>", "")
    if card.type == "LOCATION" then text = text .. " Location" end
    if id == "TAVERN_COIN" or card.name == "The Coin" then text = text .. " The Coin" end
    local out = {}
    for _, entry in ipairs(GLOSSARY) do
        if hasWord(text, entry[1]) then out[#out + 1] = entry end
    end
    return out
end

-- Adds the glossary lines for a card to GameTooltip (blank line first).
function Keywords:AddLines(tip, id)
    local list = self:For(id)
    if #list == 0 then return end
    tip:AddLine(" ")
    for _, entry in ipairs(list) do
        tip:AddLine(("|cffffd100%s:|r %s"):format(entry[1], entry[2]), 0.75, 0.75, 0.75, true)
    end
end

function Keywords:Explain(word)
    for _, entry in ipairs(GLOSSARY) do
        if entry[1] == word then return entry[2] end
    end
end
