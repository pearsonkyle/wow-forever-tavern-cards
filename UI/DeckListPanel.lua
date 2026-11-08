-- Decks tab: every deck as a tile (class, name, count, ready or what is missing). Click to edit,
-- right-click for Duplicate / Delete; New Deck asks for a class.

local TC = TavernCards_NS
local Art = TC.Art
local Decks = TC.Decks

local TILE_H = 58

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
    TC:BookPages(panel)

    local header = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    local L = TC:BookLayout()
    header:SetPoint("TOPLEFT", L.left, L.top)
    header:SetText("Your Decks")
    header:SetTextColor(0.25, 0.15, 0.05)
    local sub = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetTextColor(0.3, 0.2, 0.1)
    sub:SetWidth(L.width)
    sub:SetJustifyH("LEFT")
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
        -- Down the left page (the mouse wheel scrolls); the right page previews the selected deck.
        t:SetSize(L.width + 20, TILE_H)
        t:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
        t:SetBackdropColor(0.1, 0.07, 0.04, 0.85)
        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetSize(40, 40)
        t.icon:SetPoint("LEFT", 9, 0)
        t.name = t:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        t.name:SetPoint("TOPLEFT", t.icon, "TOPRIGHT", 10, -2)
        t.name:SetPoint("RIGHT", -44, 0)
        t.name:SetJustifyH("LEFT")
        t.info = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t.info:SetPoint("BOTTOMLEFT", t.icon, "BOTTOMRIGHT", 10, 2)
        t.info:SetPoint("RIGHT", -44, 0)
        -- The deck's card back, small, at the tile's right end (right-click > Card back... to change).
        t.back = TC.CardBacks:Create(t, 30, 44)
        t.back:SetPoint("RIGHT", -8, 0)
        t.info:SetJustifyH("LEFT")
        t:SetHighlightTexture("Interface\\Buttons\\UI-Listbox-Highlight2", "ADD")
        t:GetHighlightTexture():SetAlpha(0.35)
        t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        t:SetScript("OnClick", function(self, button)
            local deck = Decks:Get(self.deckId)
            if not deck then return end
            if button == "LeftButton" then
                if panel.selected == deck.id then
                    TC:EditDeck(deck)   -- a second click edits it
                else
                    panel.selected = deck.id
                    panel:Refresh()
                end
                return
            end
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle(deck.name)
                root:CreateButton("Edit", function() TC:EditDeck(deck) end)
                if Decks:IsReady(deck) then
                    root:CreateButton("Play", function() TC:ShowWindow("play", deck.id) end)
                end
                root:CreateButton("Card back...", function()
                    TC.CardBacks:Choose(deck, function() panel:Refresh() end)
                end)
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
            GameTooltip:AddLine("Click to preview, click again to edit; right-click for more.", 0.5, 0.5, 0.5)
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        tiles[i] = t
        return t
    end

    -- ---- the right page: the selected deck ---------------------------------------------------------
    local preview = CreateFrame("Frame", nil, panel)
    preview:SetPoint("TOPLEFT", L.right, L.top)
    preview:SetSize(L.width + 10, select(2, TC:PageSize()) - 40)
    preview.back = TC.CardBacks:Create(preview, 96, 142)
    preview.back:SetPoint("TOPLEFT", 0, -4)
    preview.backBtn = CreateFrame("Button", nil, preview)
    preview.backBtn:SetAllPoints(preview.back)
    preview.backBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Card back: " .. TC.CardBacks:Name(preview.back.backId), 1, 0.82, 0)
        GameTooltip:AddLine("Click to choose another. Your opponents see it during matches.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    preview.backBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    preview.name = preview:CreateFontString(nil, "OVERLAY", "QuestFont_Large")
    preview.name:SetPoint("TOPLEFT", preview.back, "TOPRIGHT", 14, -2)
    preview.name:SetPoint("RIGHT", 0, 0)
    preview.name:SetJustifyH("LEFT")
    preview.name:SetTextColor(0.25, 0.15, 0.05)
    preview.info = preview:CreateFontString(nil, "OVERLAY", "QuestFontNormalSmall")
    preview.info:SetPoint("TOPLEFT", preview.name, "BOTTOMLEFT", 0, -4)
    preview.info:SetPoint("RIGHT", 0, 0)
    preview.info:SetJustifyH("LEFT")
    preview.info:SetTextColor(0.3, 0.2, 0.1)
    preview.bars = {}
    for c = 0, 7 do
        local bar = preview:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(0.2, 0.35, 0.75, 0.85)
        bar:SetWidth(14)
        bar:SetPoint("BOTTOMLEFT", preview.back, "BOTTOMRIGHT", 14 + c * 20, 14)
        local label = preview:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
        label:SetPoint("TOP", bar, "BOTTOM", 0, -1)
        label:SetText(c == 7 and "7+" or c)
        bar.label = label
        preview.bars[c] = bar
    end
    preview.list = preview:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
    preview.list:SetPoint("TOPLEFT", preview.back, "BOTTOMLEFT", 0, -14)
    preview.list:SetWidth(L.width)
    preview.list:SetJustifyH("LEFT")
    preview.list:SetJustifyV("TOP")
    preview.list:SetSpacing(2)
    local function previewButton(label, x, fn)
        local b = CreateFrame("Button", nil, preview, "UIPanelButtonTemplate")
        b:SetSize(96, 24)
        b:SetText(label)
        b:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", L.right + x, 30)
        b:SetScript("OnClick", fn)
        return b
    end
    local function selectedDeck() return panel.selected and Decks:Get(panel.selected) end
    preview.edit = previewButton("Edit", 0, function() local d = selectedDeck() if d then TC:EditDeck(d) end end)
    preview.play = previewButton("Play", 104, function() local d = selectedDeck() if d then TC:ShowWindow("play", d.id) end end)
    preview.backChoose = previewButton("Card back", 208, function()
        local d = selectedDeck()
        if d then TC.CardBacks:Choose(d, function() panel:Refresh() end) end
    end)
    preview.backBtn:SetScript("OnClick", function() preview.backChoose:Click() end)

    local function showPreview(deck)
        preview:SetShown(deck ~= nil)
        if not deck then return end
        preview.back:SetBack(deck.back or TC.CardBacks.DEFAULT)
        preview.name:SetText(deck.name)
        local problems = Decks:Problems(deck)
        preview.info:SetText(className(deck.class) .. "  -  " .. (#problems == 0 and "|cff1a6010Ready to play|r"
            or ("|cff902010" .. table.concat(problems, "; ") .. "|r")))
        local curve, top = Decks:Curve(deck), 1
        for c = 0, 7 do top = math.max(top, curve[c]) end
        for c = 0, 7 do preview.bars[c]:SetHeight(math.max(1, 60 * curve[c] / top)) end
        local lines = {}
        for _, id in ipairs(Decks:CardList(deck)) do
            local last = lines[#lines]
            if last and last.id == id then last.n = last.n + 1 else lines[#lines + 1] = { id = id, n = 1 } end
        end
        local text = {}
        for i, l in ipairs(lines) do
            if i > 16 then
                text[#text + 1] = ("... and %d more"):format(#lines - 16)
                break
            end
            text[#text + 1] = ("%d  %s%s"):format(TC.Cards[l.id].cost, TC.Art:InkName(l.id), l.n > 1 and ("  x" .. l.n) or "")
        end
        preview.list:SetText(#text > 0 and table.concat(text, "\n") or "No cards yet: click Edit to build it.")
        preview.play:SetEnabled(#problems == 0)
    end

    local offset = 0
    local perPage = math.max(1, math.floor((select(2, TC:PageSize()) - 130) / (TILE_H + 10)))
    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(self, delta)
        offset = math.max(0, math.min(#Decks:All() - perPage, offset - delta))
        self:Refresh()
    end)

    function panel:Refresh()
        local all = Decks:All()
        if not (self.selected and Decks:Get(self.selected)) then
            self.selected = all[1] and all[1].id
        end
        offset = math.max(0, math.min(offset, #all - perPage))
        for i, deck in ipairs(all) do
            local t = tile(i)
            local row = i - 1 - offset
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", L.left - 10, L.top - 56 - row * (TILE_H + 10))
            t:SetShown(row >= 0 and row < perPage)
            t.deckId = deck.id
            t:SetBackdropBorderColor(1, 0.82, 0, deck.id == self.selected and 1 or 0.35)
            setClassIcon(t.icon, deck.class)
            t.name:SetText(deck.name)
            t.back:SetBack(deck.back or TC.CardBacks.DEFAULT)
            local problems = Decks:Problems(deck)
            if #problems == 0 then
                t.info:SetText("|cff40ff40Ready|r  -  " .. className(deck.class))
            else
                t.info:SetText("|cffaaaaaa" .. problems[1] .. "|r")
            end
        end
        showPreview(self.selected and Decks:Get(self.selected))
        for i = #all + 1, #tiles do
            tiles[i]:Hide()
        end
        empty:SetShown(#all == 0)
    end
    return panel
end

TC:RegisterPanel("decks", "Decks", build)
