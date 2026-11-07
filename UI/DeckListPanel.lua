-- Decks tab: every deck as a tile (class, name, count, ready or what is missing). Click to edit,
-- right-click for Duplicate / Delete; New Deck asks for a class.

local TC = TavernCards_NS
local Art = TC.Art
local Decks = TC.Decks

local TILE_W, TILE_H = 250, 58
local COLS = 3

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

local function setClassIcon(tex, class)
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        tex:SetTexCoord(unpack(coords))
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
        tex:SetTexCoord(0, 1, 0, 1)
    end
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
    header:SetText("Your Decks")
    header:SetTextColor(0.25, 0.15, 0.05)
    local sub = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetTextColor(0.3, 0.2, 0.1)
    sub:SetText("30 cards from one class and Neutral. Basic cards are yours from the start.")

    local _, myClass = UnitClass("player")
    local newDeck = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    newDeck:SetPoint("TOPRIGHT", -30, -24)
    newDeck:SetWidth(160)
    if newDeck.SetDefaultText then
        newDeck:SetDefaultText("New Deck")
    end
    newDeck:SetupMenu(function(_, root)
        root:CreateTitle("Choose a class")
        local classes = { myClass }
        for _, c in ipairs(Decks.CLASSES) do
            if c ~= myClass then classes[#classes + 1] = c end
        end
        for _, class in ipairs(classes) do
            root:CreateButton(className(class), function()
                local deck = Decks:Create(class)
                TC:EditDeck(deck)
            end)
        end
    end)

    local import = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    import:SetSize(110, 24)
    import:SetPoint("RIGHT", newDeck, "LEFT", -8, 0)
    import:SetText("Import Deck")
    import:SetScript("OnClick", function()
        TC:Prompt("Paste a Tavern Cards deck code (Ctrl+V):", "", function(text)
            local name = text:match("%[Tavern Deck: ([^%]]+)%]")
            local code = text:match("(TCD%d%.%u+%.[%w%+/]+)") or text
            local deck, why = Decks:Import(code, name)
            if deck then
                TC:Print("Deck \"%s\" imported.", deck.name)
                panel:Refresh()
            else
                TC:Print(Decks.IMPORT_ERRORS[why] or "That deck can't be imported.")
            end
        end, "Import")
    end)

    local tiles = {}
    local empty = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Large")
    empty:SetPoint("CENTER", 0, 20)
    empty:SetTextColor(0.3, 0.2, 0.1)
    empty:SetText("No decks yet. Use New Deck to build one.")

    local function tile(i)
        if tiles[i] then return tiles[i] end
        local t = CreateFrame("Button", nil, panel, "BackdropTemplate")
        t:SetSize(TILE_W, TILE_H)
        local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
        t:SetPoint("TOPLEFT", 40 + col * (TILE_W + 14), -86 - row * (TILE_H + 10))
        t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        t:SetBackdropColor(0.1, 0.07, 0.04, 0.85)
        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetSize(40, 40)
        t.icon:SetPoint("LEFT", 9, 0)
        t.name = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 10, -2)
        t.name:SetPoint("RIGHT", -10, 0)
        t.name:SetJustifyH("LEFT")
        t.info = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t.info:SetPoint("BOTTOMLEFT", t.icon, "BOTTOMRIGHT", 10, 2)
        t.info:SetPoint("RIGHT", -10, 0)
        t.info:SetJustifyH("LEFT")
        t:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        t:GetHighlightTexture():SetAlpha(0.35)
        t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        t:SetScript("OnClick", function(self, button)
            local deck = Decks:Get(self.deckId)
            if not deck then return end
            if button == "LeftButton" then
                TC:EditDeck(deck)
                return
            end
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle(deck.name)
                root:CreateButton("Edit", function() TC:EditDeck(deck) end)
                if Decks:IsReady(deck) then
                    root:CreateButton("Play", function() TC:ShowWindow("play", deck.id) end)
                end
                root:CreateButton("Duplicate", function() Decks:Duplicate(deck.id); panel:Refresh() end)
                root:CreateDivider()
                root:CreateButton("Link in chat", function() TC.Chat:Insert(TC.Chat:DeckText(deck)) end)
                local show = root:CreateButton("Share in the tavern channel", function() TC.Channel:Say(TC.Chat:DeckText(deck)) end)
                show:SetEnabled(TC.Channel:Number() ~= nil)
                root:CreateButton("Copy deck code", function()
                    TC:Prompt(("Deck code for \"%s\" (Ctrl+C to copy):"):format(deck.name), Decks:Encode(deck))
                end)
                root:CreateDivider()
                local del = root:CreateButton("|cffff4040Delete|r", function()
                    TC:Confirm(("Delete the deck \"%s\"?"):format(deck.name), function()
                        Decks:Delete(deck.id)
                        panel:Refresh()
                    end)
                end)
            end)
        end)
        t:SetScript("OnEnter", function(self)
            local deck = Decks:Get(self.deckId)
            if not deck then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(deck.name, 1, 0.82, 0)
            GameTooltip:AddLine(className(deck.class), 1, 1, 1)
            for _, p in ipairs(Decks:Problems(deck)) do
                GameTooltip:AddLine(p, 1, 0.4, 0.3)
            end
            GameTooltip:AddLine("Click to edit, right-click to play, share or copy its code.", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tiles[i] = t
        return t
    end

    function panel:Refresh()
        local all = Decks:All()
        for i, deck in ipairs(all) do
            local t = tile(i)
            t.deckId = deck.id
            setClassIcon(t.icon, deck.class)
            t.name:SetText(deck.name)
            local problems = Decks:Problems(deck)
            if #problems == 0 then
                t.info:SetText("|cff40ff40Ready|r  -  " .. className(deck.class))
            else
                t.info:SetText("|cffaaaaaa" .. problems[1] .. "|r")
            end
            t:Show()
        end
        for i = #all + 1, #tiles do
            tiles[i]:Hide()
        end
        empty:SetShown(#all == 0)
    end
    return panel
end

TC:RegisterPanel("decks", "Decks", build)
