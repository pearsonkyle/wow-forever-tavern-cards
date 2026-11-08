-- Options > AddOns > Tavern Cards: every setting and command in one page (the same ones as /tc).
-- Built with the game's Settings API (a canvas page), or the older InterfaceOptions where that's all
-- the client has. TC:OpenSettings() opens it (minimap right-click > Settings, /tc settings).

local TC = TavernCards_NS

local category, panel

local function heading(parent, text, anchor, y)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    fs:SetPoint("TOPLEFT", anchor, anchor == parent and "TOPLEFT" or "BOTTOMLEFT", anchor == parent and 16 or 0, y)
    fs:SetText(text)
    return fs
end

local function checkbox(parent, label, tip, get, set)
    local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    cb:SetSize(26, 26)
    cb.label = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    cb.label:SetPoint("LEFT", cb, "RIGHT", 4, 1)
    cb.label:SetText(label)
    cb:SetScript("OnClick", function(self)
        TC:Safe("settings", set, self:GetChecked() and true or false)
        TC.Art:Play(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
    end)
    cb:SetScript("OnShow", function(self) self:SetChecked(get()) end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 0.82, 0)
        GameTooltip:AddLine(tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cb:SetChecked(get())
    return cb
end

local function button(parent, label, tip, fn, width)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width or 170, 24)
    b:SetText(label)
    b:SetScript("OnClick", function() TC:Safe("settings", fn) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 0.82, 0)
        GameTooltip:AddLine(tip, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function command(name, arg)
    return function() TC.Commands[name](arg or "") end
end

local function build()
    local p = CreateFrame("Frame")
    p.name = "Tavern Cards"

    local title = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightHuge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Tavern Cards")
    local version = p:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    version:SetPoint("LEFT", title, "RIGHT", 10, -2)
    version:SetText("v" .. tostring(TC.VERSION))
    local blurb = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
    blurb:SetText("Collect cards from your quests, build decks, play the house or duel your friends.")

    -- Settings.
    local h1 = heading(p, "Settings", blurb, -18)
    local s = TC.db.settings
    local sound = checkbox(p, "Sound effects", "Card plays, attacks, hits and the turn chime.",
        function() return not s.mute end, function(on) s.mute = not on end)
    sound:SetPoint("TOPLEFT", h1, "BOTTOMLEFT", -2, -8)
    local models = checkbox(p, "3D creatures and heroes",
        "Creatures on the battlefield, your character as your hero, and named creatures on card faces. Turn off on slower machines.",
        function() return not s.noModels end, function(on) s.noModels = not on end)
    models:SetPoint("TOPLEFT", sound, "BOTTOMLEFT", 0, -4)
    local minimap = checkbox(p, "Minimap button", "The tarot-cards button on the minimap (left-click: card book).",
        function() return not s.minimap.hide end, function(on) TC.MinimapButton:SetHidden(not on) end)
    minimap:SetPoint("TOPLEFT", models, "BOTTOMLEFT", 0, -4)
    local channel = checkbox(p, "Tavern chat channel",
        "A chat channel for everyone with Tavern Cards on your faction: talk, find opponents, share cards and decks.",
        function() return not s.noChannel end,
        function(on) TC.Channel:Command(on and "on" or "off") end)
    channel:SetPoint("TOPLEFT", minimap, "BOTTOMLEFT", 0, -4)

    -- Card book size.
    local sizeLabel = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    sizeLabel:SetPoint("TOPLEFT", channel, "BOTTOMLEFT", 4, -12)
    local function showSize()
        sizeLabel:SetText(("Card book size: %d%%"):format(math.floor(TC:BookScale() * 100 + 0.5)))
    end
    local function step(dir)
        local cur, list = TC:BookScale(), TC.BOOK_SCALES
        local best = 1
        for i, v in ipairs(list) do
            if math.abs(v - cur) < math.abs(list[best] - cur) then best = i end
        end
        TC:SetBookScale(list[math.max(1, math.min(#list, best + dir))])
        showSize()
    end
    local smaller = button(p, "Smaller", "Shrink the card book window.", function() step(-1) end, 80)
    smaller:SetPoint("LEFT", sizeLabel, "LEFT", 200, 0)
    local bigger = button(p, "Bigger", "Enlarge the card book window: cards, text and pages.", function() step(1) end, 80)
    bigger:SetPoint("LEFT", smaller, "RIGHT", 6, 0)
    p:HookScript("OnShow", showSize)
    showSize()

    -- Play.
    local h2 = heading(p, "Play", channel, -18)
    h2:SetPoint("TOPLEFT", sizeLabel, "BOTTOMLEFT", -2, -20)
    local col1 = {
        button(p, "Open the card book", "Your collection, decks, the Play tab and the ledger.  (/tc)",
            function() TC:ShowWindow("collection") end),
        button(p, "Return to my match", "Back to the tavern table.  (/tc play)", command("play")),
        button(p, "Duel my target", "Challenge the player you have targeted, with your Play-tab deck.  (/tc duel Name)",
            command("duel")),
        button(p, "Who's online", "Other Tavern Cards players heard from lately.  (/tc who)", command("who")),
    }
    local col2 = {
        button(p, "Collection summary", "Cards collected, copies and dust, and your latest cards.  (/tc collection)",
            command("collection")),
        button(p, "Check card icons", "How many card icons this client has.  (/tc icons)", command("icons")),
        button(p, "Play mat info", "Which map the play mat uses where you stand.  (/tc mat)", command("mat")),
        button(p, "Reset collection...", "Start your whole collection over (asks first).  (/tc reset)", function()
            TC:Confirm("Wipe your whole card collection, dust and ledger? Every character earns its quest cards again on its next login.",
                function() TC.Commands.reset("confirm") end, nil, "Reset", CANCEL or "Cancel")
        end),
    }
    for i, b in ipairs(col1) do
        b:SetPoint("TOPLEFT", h2, "BOTTOMLEFT", 0, -10 - (i - 1) * 30)
    end
    for i, b in ipairs(col2) do
        b:SetPoint("LEFT", col1[i], "RIGHT", 12, 0)
    end

    -- Commands.
    local h3 = heading(p, "Slash commands", col1[#col1], -18)
    local help = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    help:SetPoint("TOPLEFT", h3, "BOTTOMLEFT", 0, -8)
    help:SetWidth(560)
    help:SetJustifyH("LEFT")
    help:SetSpacing(2)
    local lines = {}
    for _, line in ipairs(TC.CommandHelp or {}) do lines[#lines + 1] = line end
    help:SetText(table.concat(lines, "\n"))
    return p
end

local function register()
    if category or not TC.db then return end
    panel = build()
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
        category = panel
    end
end

function TC:OpenSettings()
    register()
    if Settings and Settings.OpenToCategory and category and category.GetID then
        Settings.OpenToCategory(category:GetID())
    elseif InterfaceOptionsFrame_OpenToCategory and panel then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
    end
end

TC:On("PLAYER_LOGIN", function() TC:Safe("settings page", register) end)
