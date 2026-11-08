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
local chosenDeck

-- The deck the Play tab has selected (duels use it too).
function TC:ChosenDeck()
    return chosenDeck()
end

function chosenDeck(choice)
    if choice == nil then choice = settings().deck end
    if type(choice) == "string" and choice:find("^house:") then
        local class = choice:sub(7)
        local hi = math.floor(time() % 2147483647)
        local cards = TC.AI.buildDeck(class, hi, math.random(4294967295), function(id) return TC.PlayableNow[id] end)
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

-- Starts a practice match from a setup { deck = deck id or "house:CLASS", opponent = class or "random",
-- difficulty }: the Play tab's Play button and the board's Rematch (a house deck is shuffled anew, a random
-- opponent drawn again).
function TC:StartPractice(setup)
    local deck = chosenDeck(setup.deck)
    if not deck then
        TC:Print("That deck is gone; pick another in the Play tab.")
        return false
    end
    if not Decks:IsReady(deck) and not tostring(deck.id):find("^house:") then
        TC:Print("That deck isn't ready: %s.", table.concat(Decks:Problems(deck), "; "))
        return false
    end
    local oppClass = setup.opponent
    if oppClass == "random" or not oppClass then
        oppClass = OPPONENT_CLASSES[math.random(#OPPONENT_CLASSES)]
    end
    local d = difficulty(setup.difficulty)
    local opponent = { name = d.title, class = oppClass, profile = d.key }
    if not Match:StartPractice(deck, opponent, { deck = setup.deck, opponent = setup.opponent, difficulty = d.key }) then
        return false
    end
    TC.Board:Open()
    return true
end

local function build(parent)
    local panel = CreateFrame("Frame", nil, parent)
    TC:BookPages(panel)

    local L = TC:BookLayout()
    local header = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    header:SetPoint("TOPLEFT", L.left, L.top)
    header:SetText("The Tavern Table")
    header:SetTextColor(0.25, 0.15, 0.05)
    local sub = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetWidth(L.width)
    sub:SetJustifyH("LEFT")
    sub:SetTextColor(0.3, 0.2, 0.1)
    sub:SetText("Practice against the house, or duel a friend.")

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
        local classes = {}
        if TC.EngineDefs.FAMILY[myClass] and myClass ~= "NEUTRAL" then classes[1] = myClass end
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
    start:SetText("Play")
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
            local st = settings()
            local deck = chosenDeck()
            if not deck then return end
            if TC:StartPractice({ deck = st.deck or deck.id, opponent = st.opponent, difficulty = st.difficulty }) then
                parent:GetParent():Hide()
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
    help:SetPoint("TOPLEFT", panel, "TOPLEFT", L.right, L.top)
    help:SetWidth(L.width)
    help:SetJustifyH("LEFT")
    help:SetSpacing(3)
    help:SetTextColor(0.25, 0.15, 0.05)
    help:SetText(table.concat({
        "|cff5a3a10How to play|r",
        "Click a card to play it; minions ask where to stand, and targets glow red. Click a glowing minion, then an enemy, to attack. Right-click cancels.",
        "",
        "|cff5a3a10Winnings|r",
        ("Each of your first %d wins a day pays dust: %d / %d / %d / %d by difficulty. The day's first win also brings a card."):format(
            Match.PAID_WINS_PER_DAY, Match.WIN_DUST.novice, Match.WIN_DUST.regular, Match.WIN_DUST.skilled, Match.WIN_DUST.expert),
    }, "\n"))

    local historyTitle = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    historyTitle:SetPoint("TOPLEFT", help, "BOTTOMLEFT", 0, -16)
    historyTitle:SetText("|cff5a3a10Recent matches|r")
    local history = panel:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
    history:SetPoint("TOPLEFT", historyTitle, "BOTTOMLEFT", 0, -6)
    history:SetWidth(L.width)
    history:SetJustifyH("LEFT")
    history:SetSpacing(2)

    -- Duel a friend: anyone with the addon in your group (any realm) or on your realm.
    local duelTitle = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    duelTitle:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", L.right, 118)
    duelTitle:SetText("|cff5a3a10Duel a friend|r")
    local duelBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    duelBtn:SetSize(150, 24)
    duelBtn:SetPoint("TOPLEFT", duelTitle, "BOTTOMLEFT", 0, -6)
    duelBtn:SetText("Challenge...")
    local cancelBtn = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    cancelBtn:SetSize(90, 24)
    cancelBtn:SetPoint("LEFT", duelBtn, "RIGHT", 6, 0)
    cancelBtn:SetText(CANCEL or "Cancel")
    cancelBtn:SetScript("OnClick", function() TC.Duel:Cancel() end)

    local function groupNames()
        local out = {}
        if not (IsInGroup and IsInGroup()) then return out end
        local raid = IsInRaid and IsInRaid()
        local n = raid and GetNumGroupMembers() or GetNumSubgroupMembers()
        for i = 1, n do
            local name, realm = UnitName(raid and ("raid" .. i) or ("party" .. i))
            if name and not UnitIsUnit(raid and ("raid" .. i) or ("party" .. i), "player") then
                out[#out + 1] = (realm and realm ~= "") and (name .. "-" .. realm) or name
            end
        end
        return out
    end

    duelBtn:SetScript("OnClick", function(self)
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Challenge to a duel")
            local any = false
            if UnitIsPlayer and UnitIsPlayer("target") and not UnitIsUnit("target", "player") then
                local name, realm = UnitName("target")
                local fullName = (realm and realm ~= "") and (name .. "-" .. realm) or name
                root:CreateButton("Your target: " .. name, function() TC.Duel:Challenge(fullName) end)
                any = true
            end
            local seen = {}
            for _, name in ipairs(groupNames()) do
                seen[TC.Duel.FullName(name):lower()] = true
                root:CreateButton("Group: " .. name, function() TC.Duel:Challenge(name) end)
                any = true
            end
            for _, p in ipairs(TC.Presence:Online()) do
                if not seen[p.name:lower()] then
                    local short = Ambiguate and Ambiguate(p.name, "short") or p.name
                    root:CreateButton(("%s |cff999999(%d cards)|r"):format(short, p.collected or 0), function() TC.Duel:Challenge(p.name) end)
                    any = true
                end
            end
            if not any then root:CreateTitle("|cff999999Nobody with Tavern Cards found yet.|r") end
            root:CreateDivider()
            root:CreateButton("Ask who is around", function()
                if TC.Presence:AskWho() then TC:Print("Asking the tavern who is around...") end
                C_Timer.After(7, function() if panel:IsVisible() then panel:Refresh() end end)
            end)
        end)
    end)
    duelBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Duel a friend", 1, 0.82, 0)
        GameTooltip:AddLine("Challenge your target, someone in your group, or a Tavern Cards player online. You play the deck chosen on the left.", 1, 1, 1, true)
        GameTooltip:AddLine("Players on other realms must be in your group (that's how WoW: Forever lets addons talk across realms).", 0.7, 0.7, 0.7, true)
        GameTooltip:AddLine("Also: /tc duel Name", 0.5, 0.75, 1)
        GameTooltip:Show()
    end)
    duelBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local onlineText = panel:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    onlineText:SetPoint("TOPLEFT", duelBtn, "BOTTOMLEFT", 0, -8)
    onlineText:SetWidth(L.width)
    onlineText:SetJustifyH("LEFT")
    onlineText:SetTextColor(0.25, 0.15, 0.05)
    TC.Presence:Subscribe(function() if panel:IsVisible() then panel:Refresh() end end)
    TC.Duel:Subscribe(function() if panel:IsVisible() then panel:Refresh() end end)

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
        local daily = TC.db.daily
        local wins = daily and daily.day == date("%Y-%m-%d") and daily.wins or 0
        lines[#lines + 1] = wins < Match.PAID_WINS_PER_DAY
            and ("Paid wins left today: %d of %d%s."):format(Match.PAID_WINS_PER_DAY - wins, Match.PAID_WINS_PER_DAY,
                wins == 0 and " (the first also brings a card)" or "")
            or "Today's winnings are collected; wins still count for your record."
        matchInfo:SetText(table.concat(lines, "\n"))

        local rows = {}
        for i, h in ipairs(Match:History()) do
            if i > 8 then break end
            local word = h.result == "win" and "|cff1a6010Won|r" or h.result == "loss" and "|cff902010Lost|r" or "Drew"
            local extra = h.dust and ("  +%d dust"):format(h.dust) or ""
            if h.card and TC.Cards[h.card] then extra = extra .. ", " .. TC.Art:InkName(h.card) end
            rows[#rows + 1] = ("%s vs %s (%s), %d turns%s"):format(word, h.opponent and h.opponent.name or "?",
                className(h.opponent and h.opponent.class or ""), h.turns or 0, extra)
        end
        history:SetText(#rows > 0 and table.concat(rows, "\n") or "No matches yet.")

        local pend = TC.Duel:Pending()
        duelBtn:SetEnabled(not active and not pend)
        cancelBtn:SetShown(pend ~= nil)
        local n = #TC.Presence:Online()
        local chan = TC.Channel:Number()
        if pend then
            local who = Ambiguate and Ambiguate(pend.peer, "short") or pend.peer
            onlineText:SetText(pend.role == "challenger" and ("|cff1a4a80Waiting for %s to answer...|r"):format(who)
                or ("|cff1a4a80Setting up the duel with %s...|r"):format(who))
            return
        end
        onlineText:SetText(("|cff5a3a10Tavern players online:|r %d%s"):format(n,
            chan and ("\nChat with them in channel |cff1a4a80/%d|r."):format(chan) or "\n|cffaaaaaa/tc channel on to join the tavern chat.|r"))
    end

    Match:Subscribe(function(what)
        if (what == "end" or what == "load") and panel:IsVisible() then panel:Refresh() end
    end)
    return panel
end

TC:RegisterPanel("play", "Play", build)
