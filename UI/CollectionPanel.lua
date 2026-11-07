-- Collection tab: a two-page binder on the spellbook page art, 3x3 cards a page, with a toolbar
-- (search, Filter menu, mana-cost gems, dust) and a footer (paging, collected progress).

local TC = TavernCards_NS
local Art = TC.Art
local CardWidget = TC.CardWidget

local COLS, ROWS = 3, 3
local PER_PAGE = COLS * ROWS
local GAP_X, GAP_Y = 12, 12
local TOOLBAR_H = 34

local CLASS_ORDER = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID",
    "DEATHKNIGHT", "DEMONHUNTER" }
local RARITIES = { "FREE", "COMMON", "RARE", "EPIC", "LEGENDARY" }
local RARITY_LABEL = { FREE = "Basic", COMMON = "Common", RARE = "Rare", EPIC = "Epic", LEGENDARY = "Legendary" }

local function className(family)
    if family == "NEUTRAL" then
        return "Neutral"
    end
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[family]) or family
end

local function build(parent)
    local panel = CreateFrame("Frame", nil, parent)
    local _, myClass = UnitClass("player")
    local filter = {
        text = "", class = "mine", owned = "all", cost = nil, playable = false,
        rarity = { FREE = true, COMMON = true, RARE = true, EPIC = true, LEGENDARY = true },
    }
    local list, page = {}, 1
    local editing           -- the deck being edited, if any: left page cards, right page the deck
    local function perSpread()
        return editing and PER_PAGE or PER_PAGE * 2
    end

    -- ---- pages ---------------------------------------------------------------------------------
    local pageW, pageH = TC:PageSize()
    local pages = {}
    for i, atlasName in ipairs({ "spellbook-Page-Left-C60", "spellbook-Page-Right-C60" }) do
        local p = CreateFrame("Frame", nil, panel)
        p:SetSize(pageW, pageH)
        p:SetPoint("TOPLEFT", 2 + (i - 1) * pageW, -TOOLBAR_H - 4)
        p.bg = p:CreateTexture(nil, "BACKGROUND")
        p.bg:SetAllPoints()
        if TC.Compat:HasAtlas(atlasName) then
            p.bg:SetAtlas(atlasName)
        else
            p.bg:SetTexture("Interface\\QuestFrame\\QuestBG")
            p.bg:SetTexCoord(0, 0.6, 0, 0.75)
        end
        pages[i] = p
    end

    local gridW = COLS * CardWidget.WIDTH + (COLS - 1) * GAP_X
    local gridH = ROWS * CardWidget.HEIGHT + (ROWS - 1) * GAP_Y
    local scale = math.min(1, (pageW - 64) / gridW, (pageH - 56) / gridH)
    local widgets, grids = {}, {}
    for i, p in ipairs(pages) do
        local grid = CreateFrame("Frame", nil, p)
        grids[i] = grid
        grid:SetSize(gridW, gridH)
        grid:SetScale(scale)
        -- Lean each grid away from the book's spine.
        grid:SetPoint("CENTER", (i == 1 and -6 or 6) / scale, -4 / scale)
        for n = 1, PER_PAGE do
            local w = CardWidget:Create(grid)
            local col, row = (n - 1) % COLS, math.floor((n - 1) / COLS)
            w:SetPoint("TOPLEFT", col * (CardWidget.WIDTH + GAP_X), -row * (CardWidget.HEIGHT + GAP_Y))
            w.onLeftClick = function(id) panel:CardClicked(id) end
            widgets[#widgets + 1] = w
        end
    end

    -- ---- toolbar -------------------------------------------------------------------------------
    local search = CreateFrame("EditBox", nil, panel, "SearchBoxTemplate")
    search:SetSize(170, 20)
    search:SetPoint("TOPLEFT", 58, -6)  -- clear of the window portrait
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        filter.text = (self:GetText() or ""):lower()
        page = 1
        panel:Refresh()
    end)

    local filterButton
    local ok = pcall(function()
        filterButton = CreateFrame("DropdownButton", nil, panel, "WowStyle1FilterDropdownTemplate")
    end)
    if not ok or not filterButton then
        filterButton = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    end
    filterButton:SetPoint("LEFT", search, "RIGHT", 10, 0)
    if filterButton.SetText then
        filterButton:SetText(FILTER or "Filter")
    end
    local function changed()
        page = 1
        panel:Refresh()
    end
    filterButton:SetupMenu(function(_, root)
        local classMenu = root:CreateButton(CLASS or "Class")
        classMenu:CreateRadio(className(myClass) .. " + Neutral", function() return filter.class == "mine" end,
            function() filter.class = "mine"; changed() end)
        classMenu:CreateRadio(ALL_CLASSES or "All Classes", function() return filter.class == "all" end,
            function() filter.class = "all"; changed() end)
        classMenu:CreateRadio("Neutral", function() return filter.class == "NEUTRAL" end,
            function() filter.class = "NEUTRAL"; changed() end)
        for _, family in ipairs(CLASS_ORDER) do
            classMenu:CreateRadio(className(family), function() return filter.class == family end,
                function() filter.class = family; changed() end)
        end

        local rarityMenu = root:CreateButton(RARITY or "Rarity")
        for _, rarity in ipairs(RARITIES) do
            local r, g, b = Art:RarityColor(rarity)
            local label = ("|cff%02x%02x%02x%s|r"):format(r * 255, g * 255, b * 255, RARITY_LABEL[rarity])
            rarityMenu:CreateCheckbox(label, function() return filter.rarity[rarity] end,
                function() filter.rarity[rarity] = not filter.rarity[rarity]; changed() end)
        end

        root:CreateDivider()
        root:CreateRadio("All cards", function() return filter.owned == "all" end,
            function() filter.owned = "all"; changed() end)
        root:CreateRadio(COLLECTED or "Collected", function() return filter.owned == "owned" end,
            function() filter.owned = "owned"; changed() end)
        root:CreateRadio(NOT_COLLECTED or "Not Collected", function() return filter.owned == "missing" end,
            function() filter.owned = "missing"; changed() end)
        if TC.EngineReady then
            root:CreateDivider()
            root:CreateCheckbox("Playable now only", function() return filter.playable end,
                function() filter.playable = not filter.playable; changed() end)
        end
    end)

    -- Mana-cost gems: 0..6 and 7+; click again to clear.
    local gems = {}
    for cost = 0, 7 do
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(22, 22)
        if cost == 0 then
            b:SetPoint("LEFT", filterButton, "RIGHT", 18, 0)
        else
            b:SetPoint("LEFT", gems[cost - 1], "RIGHT", 3, 0)
        end
        b.disc = b:CreateTexture(nil, "ARTWORK")
        b.disc:SetAllPoints()
        b.disc:SetColorTexture(0.15, 0.4, 0.95, 1)
        local mask = b:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(b.disc)
        b.disc:AddMaskTexture(mask)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("CENTER")
        b.text:SetText(cost == 7 and "7+" or cost)
        b:SetScript("OnClick", function()
            filter.cost = filter.cost ~= cost and cost or nil
            Art:Play("IG_MAINMENU_OPTION_CHECKBOX_ON")
            changed()
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            GameTooltip:SetText(cost == 7 and "Cost 7 or more" or ("Cost " .. cost))
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        gems[cost] = b
    end

    local dust = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    dust:SetPoint("TOPRIGHT", -14, -9)

    -- ---- footer --------------------------------------------------------------------------------
    local footerY = -TOOLBAR_H - 4 - pageH - 6
    local pageText = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    pageText:SetPoint("TOPRIGHT", -80, footerY - 6)

    local function pageButton(dir)
        local b = CreateFrame("Button", nil, panel)
        b:SetSize(32, 32)
        local base = dir < 0 and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage-" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage-"
        b:SetNormalTexture(base .. "Up")
        b:SetPushedTexture(base .. "Down")
        b:SetDisabledTexture(base .. "Disabled")
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b:SetScript("OnClick", function()
            panel:TurnPage(dir)
        end)
        return b
    end
    local prev, nextB = pageButton(-1), pageButton(1)
    nextB:SetPoint("TOPRIGHT", -14, footerY)
    prev:SetPoint("RIGHT", nextB, "LEFT", -4, 0)

    local bar = CreateFrame("StatusBar", nil, panel)
    bar:SetSize(260, 14)
    bar:SetPoint("TOPLEFT", 24, footerY - 8)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetStatusBarColor(0.95, 0.75, 0.2)
    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(0, 0, 0, 0.55)
    if TC.Compat:HasAtlas("Professions-skillbar-frame") then
        bar.border = bar:CreateTexture(nil, "OVERLAY")
        bar.border:SetAtlas("Professions-skillbar-frame")
        bar.border:SetPoint("TOPLEFT", -6, 5)
        bar.border:SetPoint("BOTTOMRIGHT", 6, -5)
    end
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("CENTER", 0, 1)

    panel:EnableMouseWheel(true)
    panel:SetScript("OnMouseWheel", function(_, delta)
        panel:TurnPage(delta > 0 and -1 or 1)
    end)

    -- ---- data ----------------------------------------------------------------------------------
    local classRank = { [myClass] = 0, NEUTRAL = 1 }
    for i, family in ipairs(CLASS_ORDER) do
        classRank[family] = classRank[family] or (i + 1)
    end

    local function passes(id, card)
        if bit.band(card.flags, 8) == 0 then
            return false
        end
        if editing then
            if card.family ~= editing.class and card.family ~= "NEUTRAL" then return false end
        elseif filter.class == "mine" then
            if card.family ~= myClass and card.family ~= "NEUTRAL" then return false end
        elseif filter.class ~= "all" and card.family ~= filter.class then
            return false
        end
        if not filter.rarity[card.rarity] then return false end
        if filter.cost and (filter.cost == 7 and card.cost < 7 or filter.cost < 7 and card.cost ~= filter.cost) then
            return false
        end
        local have = TC.Collection:Count(id)
        if filter.owned == "owned" and have == 0 or filter.owned == "missing" and have > 0 then return false end
        if filter.playable and TC.EngineReady and not TC.PlayableNow[id] then return false end
        if filter.text ~= "" then
            local hay = (card.name .. " " .. (card.text or "")):lower()
            if not hay:find(filter.text, 1, true) then return false end
        end
        return true
    end

    local function rebuild()
        wipe(list)
        local owned = 0
        for _, id in ipairs(TC.CardOrder) do
            local card = TC.Cards[id]
            if passes(id, card) then
                list[#list + 1] = id
                if TC.Collection:Count(id) > 0 then
                    owned = owned + 1
                end
            end
        end
        table.sort(list, function(a, b)
            local x, y = TC.Cards[a], TC.Cards[b]
            local rx, ry = classRank[x.family] or 99, classRank[y.family] or 99
            if rx ~= ry then return rx < ry end
            if x.cost ~= y.cost then return x.cost < y.cost end
            if x.name ~= y.name then return x.name < y.name end
            return a < b
        end)
        return owned
    end

    function panel:Pages()
        return math.max(1, math.ceil(#list / perSpread()))
    end

    function panel:TurnPage(dir)
        local target = math.max(1, math.min(self:Pages(), page + dir))
        if target ~= page then
            page = target
            Art:Play("IG_ABILITY_PAGE_TURN")
            self:Draw()
        end
    end

    function panel:Draw()
        local first = (page - 1) * perSpread()
        for i, w in ipairs(widgets) do
            w:SetCard(i <= perSpread() and list[first + i] or nil)
        end
        pageText:SetText(("Page %d / %d"):format(page, self:Pages()))
        prev:SetEnabled(page > 1)
        nextB:SetEnabled(page < self:Pages())
        for cost, b in pairs(gems) do
            local on = filter.cost == cost
            b.disc:SetVertexColor(on and 1 or 0.55, on and 1 or 0.55, on and 1 or 0.55)
            b.text:SetTextColor(on and 1 or 0.8, on and 0.95 or 0.8, on and 0.6 or 0.8)
        end
    end

    function panel:Refresh()
        rebuild()
        page = math.min(page, self:Pages())
        -- The same account-wide number as the minimap and the ledger, whatever the filter shows.
        local collected, total = TC.Collection:Stats()
        bar:SetMinMaxValues(0, math.max(1, total))
        bar:SetValue(collected)
        bar.text:SetText(TC.Collection:ProgressText())
        dust:SetText(("|TInterface\\Icons\\INV_Enchant_DustArcane:14:14|t %d"):format(TC.db.dust))
        self:Draw()
    end

    -- ---- deck editing --------------------------------------------------------------------------
    local sheet
    local MESSAGES = {
        full = "The deck already has 30 cards.", copies = "No more copies of that card fit in a deck.",
        owned = "You don't own another copy of that card.", class = "That card belongs to another class.",
    }

    function panel:CardClicked(id)
        if not editing then
            return
        end
        local ok, why = TC.Decks:Add(editing, id)
        if ok then
            Art:Play("IG_MAINMENU_OPTION_CHECKBOX_ON")
            sheet:Refresh()
        else
            UIErrorsFrame:AddMessage(MESSAGES[why] or why, 1, 0.1, 0.1)
        end
    end

    function panel:EditDeck(deck)
        editing = deck
        if not sheet then
            sheet = TC.DeckSheet:Create(pages[2], function() panel:StopEditing() end)
        end
        grids[2]:Hide()
        sheet:Show()
        sheet:SetDeck(deck)
        page = 1
        self:Refresh()
    end

    function panel:StopEditing()
        editing = nil
        if sheet then sheet:Hide() end
        grids[2]:Show()
        page = 1
        self:Refresh()
        TC:ShowWindow("decks")
    end

    function panel:Editing()
        return editing
    end

    function panel:ShowOwned()
        filter.owned, filter.cost, filter.playable = "owned", nil, false
        for r in pairs(filter.rarity) do filter.rarity[r] = true end
        page = 1
        if search:GetText() ~= "" then
            search:SetText("")  -- OnTextChanged refreshes
        else
            self:Refresh()
        end
    end

    function panel:FocusCard(id)
        local card = TC.Cards[id]
        if not card then return end
        filter.class, filter.owned, filter.cost, filter.playable = "all", "all", nil, false
        for r in pairs(filter.rarity) do filter.rarity[r] = true end
        search:SetText(card.name)
        filter.text = card.name:lower()
        rebuild()  -- also when the box already held this name (no OnTextChanged then)
        for i, other in ipairs(list) do
            if other == id then
                page = math.floor((i - 1) / perSpread()) + 1
                break
            end
        end
        self:Refresh()
    end

    return panel
end

TC:RegisterPanel("collection", COLLECTION or "Collection", build)
