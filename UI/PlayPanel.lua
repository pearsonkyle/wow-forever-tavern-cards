-- Play tab: pick one of your decks (or borrow a house deck), an opponent and a difficulty, and sit down
-- at the tavern table against the AI. A match in progress can be resumed or conceded from here.

local TC = TavernCards_NS
local Decks, Match = TC.Decks, TC.Match

local DIFFICULTIES = {
    { key = "novice", label = "Novice", title = "Apprentice", blurb = "Learning the rules; often passes the turn early." },
    { key = "regular", label = "Regular", title = "Tavern Regular", blurb = "Plays sensibly and trades well." },
    { key = "skilled", label = "Skilled", title = "Card Shark", blurb = "Looks a few moves ahead." },
    { key = "expert", label = "Expert", title = "Grand Champion", blurb = "Thinks hard about every move." },
}
local OPPONENT_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

-- The menu dropdowns show the selected radio's text; ours is set explicitly (the house deck has no radio
-- until the menu is built).
local function setDropText(drop, text)
    if drop.OverrideText then
        drop:OverrideText(text)
    elseif drop.Text then
        drop.Text:SetText(text)
    end
end

local function difficulty(key)
    for _, d in ipairs(DIFFICULTIES) do
        if d.key == key then return d end
    end
    return DIFFICULTIES[2]
end

local function settings()
    TC.char.play = TC.char.play or { deck = nil, opponent = "random", difficulty = "regular" }
    return TC.char.play
end

-- The chosen deck: a saved deck, or a house deck ("house:CLASS") built for you.
local function chosenDeck()
    local choice = settings().deck
    if type(choice) == "string" and choice:find("^house:") then
        local class = choice:sub(7)
        local hi = math.floor(time() % 2147483647)
        local cards = TC.AI.buildDeck(class, hi, 977, function(id) return TC.PlayableNow[id] end)
        if not cards then return nil end
        local deck = { id = choice, class = class, name = className(class) .. " House Deck", cards = {} }
        for _, id in ipairs(cards) do deck.cards[id] = (deck.cards[id] or 0) + 1 end
        return deck, true
    end
    local deck = choice and Decks:Get(choice)
    if not deck then
        -- Default: the first ready deck.
        for _, d in ipairs(Decks:All()) do
            if Decks:IsReady(d) then return d end
        end
    end
    return deck
end

local function build(parent)
    local panel = CreateFrame("Frame", nil, parent)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    bg:SetTexture("Interface\\QuestFrame\\QuestBG")
    bg:SetTexCoord(0, 0.6, 0, 0.75)

    local header = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    header:SetPoint("TOPLEFT", 58, -22)
    header:SetText("The Tavern Table")
    header:SetTextColor(0.25, 0.15, 0.05)
    local sub = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetTextColor(0.3, 0.2, 0.1)
    sub:SetText("Practice against the house. Duels with innkeepers and other players are coming.")

    local function label(text, anchor, y)
        local fs = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
        fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y)
        fs:SetText(text)
        fs:SetTextColor(0.25, 0.15, 0.05)
        return fs
    end

    -- Deck.
    local deckLabel = label("Your deck", sub, -26)
    local deckDrop = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    deckDrop:SetPoint("TOPLEFT", deckLabel, "BOTTOMLEFT", -2, -6)
    deckDrop:SetWidth(280)
    deckDrop:SetupMenu(function(_, root)
        local decks = Decks:All()
        if #decks > 0 then root:CreateTitle("Your decks") end
        for _, deck in ipairs(decks) do
            local ready = Decks:IsReady(deck)
            local text = ("%s |cff999999(%s)|r%s"):format(deck.name, className(deck.class), ready and "" or " |cffff5555- not ready|r")
            root:CreateRadio(text, function() return settings().deck == deck.id end, function()
                settings().deck = deck.id
                panel:Refresh()
            end)
        end
        root:CreateTitle("Borrow a house deck")
        local _, myClass = UnitClass("player")
        local classes = { myClass }
        for _, c in ipairs(OPPONENT_CLASSES) do
            if c ~= myClass then classes[#classes + 1] = c end
        end
        for _, class in ipairs(classes) do
            local key = "house:" .. class
            root:CreateRadio(className(class) .. " House Deck", function() return settings().deck == key end, function()
                settings().deck = key
                panel:Refresh()
            end)
        end
    end)
    local deckInfo = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    deckInfo:SetPoint("TOPLEFT", deckDrop, "BOTTOMLEFT", 2, -6)
    deckInfo:SetWidth(300)
    deckInfo:SetJustifyH("LEFT")
    local editDeck = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    editDeck:SetSize(90, 22)
    editDeck:SetPoint("LEFT", deckDrop, "RIGHT", 8, 0)
    editDeck:SetText(EDIT or "Edit")
    editDeck:SetScript("OnClick", function()
        local deck, house = chosenDeck()
        if deck and not house then TC:EditDeck(deck) end
    end)

    -- Opponent.
    local oppLabel = label("Opponent", deckInfo, -22)
    local oppDrop = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    oppDrop:SetPoint("TOPLEFT", oppLabel, "BOTTOMLEFT", -2, -6)
    oppDrop:SetWidth(200)
    oppDrop:SetupMenu(function(_, root)
        root:CreateRadio("Random class", function() return settings().opponent == "random" end, function()
            settings().opponent = "random"
            panel:Refresh()
        end)
        for _, class in ipairs(OPPONENT_CLASSES) do
            root:CreateRadio(className(class), function() return settings().opponent == class end, function()
                settings().opponent = class
                panel:Refresh()
            end)
        end
    end)

    local diffLabel = label("Difficulty", oppDrop, -14)
    diffLabel:SetPoint("TOPLEFT", oppDrop, "BOTTOMLEFT", 2, -14)
    local diffDrop = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    diffDrop:SetPoint("TOPLEFT", diffLabel, "BOTTOMLEFT", -2, -6)
    diffDrop:SetWidth(200)
    diffDrop:SetupMenu(function(_, root)
        for _, d in ipairs(DIFFICULTIES) do
            root:CreateRadio(d.label, function() return settings().difficulty == d.key end, function()
                settings().difficulty = d.key
                panel:Refresh()
            end)
        end
    end)
    local diffInfo = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    diffInfo:SetPoint("TOPLEFT", diffDrop, "BOTTOMLEFT", 2, -6)
    diffInfo:SetWidth(300)
    diffInfo:SetJustifyH("LEFT")
    diffInfo:SetTextColor(0.3, 0.2, 0.1)

    -- Start / resume.
    local start = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    start:SetSize(160, 30)
    start:SetPoint("TOPLEFT", diffInfo, "BOTTOMLEFT", 0, -24)
    start:SetText("Sit Down")
    local resume = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    resume:SetSize(160, 30)
    resume:SetPoint("TOPLEFT", diffInfo, "BOTTOMLEFT", 0, -24)
    resume:SetText("Return to Table")
    local concede = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    concede:SetSize(100, 30)
    concede:SetPoint("LEFT", resume, "RIGHT", 8, 0)
    concede:SetText("Concede")

    start:SetScript("OnClick", function()
        TC:Safe("start match", function()
            local deck = chosenDeck()
            if not deck then return end
            local s = settings()
            local oppClass = s.opponent
            if oppClass == "random" or not oppClass then
                oppClass = OPPONENT_CLASSES[math.random(#OPPONENT_CLASSES)]
            end
            local d = difficulty(s.difficulty)
            local opponent = { name = d.title, class = oppClass, profile = d.key }
            if Match:StartPractice(deck, opponent) then
                parent:GetParent():Hide()
                TC.Board:Open()
            end
        end)
    end)
    resume:SetScript("OnClick", function()
        parent:GetParent():Hide()
        TC.Board:Open()
    end)
    concede:SetScript("OnClick", function()
        TC:Confirm("Concede the match in progress?", function()
            Match:Concede()
            panel:Refresh()
        end)
    end)

    local matchInfo = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    matchInfo:SetPoint("TOPLEFT", start, "BOTTOMLEFT", 0, -14)
    matchInfo:SetWidth(420)
    matchInfo:SetJustifyH("LEFT")
    matchInfo:SetTextColor(0.3, 0.2, 0.1)

    -- Right page: how to play.
    local pageW = TC:PageSize()
    local help = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    help:SetPoint("TOPLEFT", panel, "TOP", 24, -80)
    help:SetWidth(pageW - 70)
    help:SetJustifyH("LEFT")
    help:SetSpacing(3)
    help:SetTextColor(0.25, 0.15, 0.05)
    help:SetText(table.concat({
        "|cff5a3a10How to play|r",
        "",
        "Each turn you gain a mana crystal (up to 10). Spend mana to play cards from your hand.",
        "",
        "Click a card to play it. Minions ask where to stand, and spells and battlecries ask for a target: legal targets glow red.",
        "",
        "Click one of your glowing minions, then an enemy, to attack. Taunt minions must be attacked first.",
        "",
        "Click your hero power beside your portrait once per turn.",
        "",
        "Right-click anywhere to cancel. Reduce the enemy hero to 0 health to win.",
        "",
        "Matches are saved as you play: close the table, or even log out, and pick up where you left off.",
    }, "\n"))

    function panel:Open(deckId)
        if deckId then settings().deck = deckId end
    end

    function panel:Refresh()
        local s = settings()
        local deck, house = chosenDeck()
        if deck and not house and s.deck ~= deck.id then s.deck = deck.id end
        local ready = true
        if not deck then
            setDropText(deckDrop, "Choose a deck")
            deckInfo:SetText("|cff802010You have no decks yet. Build one in the Decks tab, or borrow a house deck.|r")
            ready = false
        else
            setDropText(deckDrop, ("%s (%s)"):format(deck.name, className(deck.class)))
            if house then
                deckInfo:SetText("|cff3a2a10A deck of the house's cards, shuffled fresh each game. Wins still count.|r")
            else
                local problems = Decks:Problems(deck)
                if #problems == 0 then
                    deckInfo:SetText("|cff1a5a10Ready to play.|r")
                else
                    ready = false
                    deckInfo:SetText("|cff802010" .. table.concat(problems, "; ") .. ".|r")
                end
            end
        end
        editDeck:SetShown(deck ~= nil and not house)
        setDropText(oppDrop, s.opponent == "random" and "Random class" or className(s.opponent))
        local d = difficulty(s.difficulty)
        setDropText(diffDrop, d.label)
        diffInfo:SetText(d.blurb)

        local active = Match:Active()
        start:SetShown(not active)
        start:SetEnabled(ready)
        resume:SetShown(active)
        concede:SetShown(active)

        local lines = {}
        local record = Match:Record()
        if active and record then
            lines[#lines + 1] = ("Match in progress: %s vs %s (%s)."):format(record.deckName or "your deck",
                record.opponent.name, className(record.opponent.class))
        end
        local stats = TC.db.stats or {}
        if (stats.played or 0) > 0 then
            lines[#lines + 1] = ("Record: %d won of %d played."):format(stats.won or 0, stats.played)
        end
        local last = TC.char.lastMatch
        if last and not active then
            local word = last.result == "win" and "|cff1a5a10won|r" or last.result == "loss" and "|cff802010lost|r" or "drew"
            lines[#lines + 1] = ("Last match: you %s against the %s."):format(word,
                last.opponent and last.opponent.name or "house")
        end
        matchInfo:SetText(table.concat(lines, "\n"))
    end

    Match:Subscribe(function(what)
        if (what == "end" or what == "load") and panel:IsVisible() then panel:Refresh() end
    end)
    return panel
end

TC:RegisterPanel("play", "Play", build)
