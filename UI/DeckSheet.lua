-- The deck list written on the book's right page while a deck is edited: name, count, mana curve,
-- the cards (click one to take it out), and Done / Auto-fill.

local TC = TavernCards_NS
local Art = TC.Art
local Decks = TC.Decks

local DeckSheet = {}
TC.DeckSheet = DeckSheet

local INK = { 0.22, 0.14, 0.06 }

function DeckSheet:Create(page, onDone)
    local sheet = CreateFrame("Frame", nil, page)
    sheet:SetPoint("TOPLEFT", 34, -26)
    sheet:SetPoint("BOTTOMRIGHT", -30, 22)

    sheet.classIcon = sheet:CreateTexture(nil, "ARTWORK")
    sheet.classIcon:SetSize(28, 28)
    sheet.classIcon:SetPoint("TOPLEFT", 0, 0)

    local name = CreateFrame("EditBox", nil, sheet, "InputBoxTemplate")
    name:SetSize(170, 22)
    name:SetPoint("LEFT", sheet.classIcon, "RIGHT", 12, 0)
    name:SetAutoFocus(false)
    name:SetMaxLetters(32)
    name:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    name:SetScript("OnEscapePressed", function(self)
        self:SetText(sheet.deck and sheet.deck.name or "")
        self:ClearFocus()
    end)
    name:SetScript("OnEditFocusLost", function(self)
        local text = strtrim(self:GetText() or "")
        if sheet.deck and text ~= "" then
            sheet.deck.name = text
        end
    end)
    sheet.nameBox = name

    sheet.count = sheet:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    sheet.count:SetPoint("TOPRIGHT", 0, -4)

    -- Mana curve: eight little columns, 0 .. 7+.
    sheet.bars = {}
    for c = 0, 7 do
        local bar = sheet:CreateTexture(nil, "ARTWORK")
        bar:SetColorTexture(0.2, 0.42, 0.85, 0.85)
        bar:SetWidth(16)
        bar:SetPoint("BOTTOMLEFT", sheet, "TOPLEFT", 4 + c * 22, -88)
        local label = sheet:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
        label:SetPoint("TOP", bar, "BOTTOM", 0, -2)
        label:SetText(c == 7 and "7+" or c)
        sheet.bars[c] = bar
    end

    sheet.problems = sheet:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
    sheet.problems:SetPoint("TOPLEFT", 190, -50)
    sheet.problems:SetPoint("RIGHT", 0, 0)
    sheet.problems:SetJustifyH("LEFT")
    sheet.problems:SetJustifyV("TOP")

    local box = CreateFrame("Frame", nil, sheet, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 0, -112)
    box:SetPoint("BOTTOMRIGHT", -16, 34)
    local scrollBar = CreateFrame("EventFrame", nil, sheet, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", box, "TOPRIGHT", 4, 0)
    scrollBar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 4, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(21)
    view:SetElementInitializer("BackdropTemplate", function(row, data)
        if not row.name then
            row:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
            row.cost = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            row.cost:SetPoint("LEFT", 4, 0)
            row.cost:SetWidth(18)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(17, 17)
            row.icon:SetPoint("LEFT", 26, 0)
            row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
            row.name:SetPoint("RIGHT", -28, 0)
            row.name:SetJustifyH("LEFT")
            row.n = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.n:SetPoint("RIGHT", -6, 0)
            row.hl = row:CreateTexture(nil, "HIGHLIGHT")
            row.hl:SetAllPoints()
            row.hl:SetColorTexture(1, 1, 1, 0.12)
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                TC:CardTooltip(self.id)
                GameTooltip:AddLine("Click to remove one copy.", 0.5, 0.75, 1)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:SetScript("OnMouseUp", function(self)
                if sheet.deck and Decks:Remove(sheet.deck, self.id) then
                    Art:Play("IG_MAINMENU_OPTION_CHECKBOX_OFF")
                    sheet:Refresh()
                    if sheet.onChange then sheet.onChange() end
                end
            end)
        end
        local card = TC.Cards[data.id]
        row.id = data.id
        local r, g, b = Art:RarityColor(card.rarity)
        row:SetBackdropColor(r * 0.25, g * 0.25, b * 0.25, 0.85)
        row.cost:SetText(card.cost)
        row.icon:SetTexture(Art:Icon(data.id))
        row.name:SetText(card.name)
        row.name:SetTextColor(r, g, b)
        row.n:SetText(card.rarity == "LEGENDARY" and "|cffff8000*|r" or (data.n > 1 and data.n or ""))
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, scrollBar, view)
    sheet.box = box

    local done = CreateFrame("Button", nil, sheet, "UIPanelButtonTemplate")
    done:SetSize(96, 24)
    done:SetPoint("BOTTOMRIGHT", 0, 0)
    done:SetText(DONE or "Done")
    done:SetScript("OnClick", function()
        name:ClearFocus()
        onDone()
    end)
    local fill = CreateFrame("Button", nil, sheet, "UIPanelButtonTemplate")
    fill:SetSize(96, 24)
    fill:SetPoint("RIGHT", done, "LEFT", -8, 0)
    fill:SetText("Auto-fill")
    fill:SetScript("OnClick", function()
        if not sheet.deck then return end
        local before = Decks:Count(sheet.deck)
        local after = Decks:Fill(sheet.deck)
        if after == before then
            UIErrorsFrame:AddMessage("No more playable cards you own fit this deck.", 1, 0.1, 0.1)
        end
        sheet:Refresh()
        if sheet.onChange then sheet.onChange() end
    end)
    fill:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Auto-fill")
        GameTooltip:AddLine("Complete the deck with playable cards you own, following a sensible mana curve.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    fill:SetScript("OnLeave", function() GameTooltip:Hide() end)

    function sheet:SetDeck(deck)
        self.deck = deck
        local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[deck.class]
        if coords then
            self.classIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
            self.classIcon:SetTexCoord(unpack(coords))
        else
            self.classIcon:SetTexture(Art:Icon(TC.CardOrder[1]))
        end
        name:SetText(deck.name)
        self:Refresh()
    end

    function sheet:Refresh()
        local deck = self.deck
        if not deck then return end
        local n = Decks:Count(deck)
        self.count:SetText(("%d / %d"):format(n, Decks.SIZE))
        self.count:SetTextColor(n == Decks.SIZE and 0.1 or 0.55, n == Decks.SIZE and 0.45 or 0.08, 0.05)
        local curve, top = Decks:Curve(deck), 1
        for c = 0, 7 do top = math.max(top, curve[c]) end
        for c = 0, 7 do
            self.bars[c]:SetHeight(math.max(1, 40 * curve[c] / top))
            self.bars[c]:SetAlpha(curve[c] > 0 and 1 or 0.25)
        end
        local problems = Decks:Problems(deck)
        if #problems == 0 then
            self.problems:SetText("|cff1a6610Ready to play|r")
        else
            self.problems:SetText(table.concat(problems, "\n"))
            self.problems:SetTextColor(INK[1], INK[2], INK[3])
        end
        local provider = CreateDataProvider()
        local seen = {}
        for _, id in ipairs(Decks:CardList(deck)) do
            if not seen[id] then
                seen[id] = true
                provider:Insert({ id = id, n = deck.cards[id] })
            end
        end
        self.box:SetDataProvider(provider, ScrollBoxConstants and ScrollBoxConstants.RetainScrollPosition)
    end

    return sheet
end
