-- Minimap button. LibDataBroker + LibDBIcon when they work (so minimap button bags can collect it);
-- otherwise a hand-made button on the minimap ring, dragged around the edge like any other.
--   Left-click:  open / close the card book
--   Shift-click: the Play tab
--   Right-click: menu

local TC = TavernCards_NS

local ICON = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01"
local Minimap_ = {}
TC.MinimapButton = Minimap_

local function menu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        TC:ToggleWindow()
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Tavern Cards")
        root:CreateButton("Card Collection", function() TC:ShowWindow("collection") end)
        root:CreateButton("Decks", function() TC:ShowWindow("decks") end)
        root:CreateButton("Play", function() TC:ShowWindow("play") end)
        root:CreateButton("Card Ledger", function() TC:ShowWindow("ledger") end)
        root:CreateDivider()
        root:CreateCheckbox("Sounds", function() return not TC.db.settings.mute end, function()
            TC.db.settings.mute = not TC.db.settings.mute
        end)
        root:CreateButton("Hide minimap button", function()
            Minimap_:SetHidden(true)
            TC:Print("Minimap button hidden. |cffffffff/tc minimap|r brings it back.")
        end)
    end)
end

local function onClick(owner, button)
    if button == "RightButton" then
        menu(owner)
    elseif IsShiftKeyDown() then
        if TC.Match:Active() then TC.Board:Open() else TC:ShowWindow("play") end
    else
        TC:ToggleWindow()
    end
end

local function tooltip(tip)
    local collected, total, _, basics = TC.Collection:Stats()
    tip:AddLine("Tavern Cards", 1, 0.82, 0)
    tip:AddDoubleLine("Collected", ("%d / %d"):format(collected, total), 1, 1, 1, 1, 1, 1)
    tip:AddLine(("plus %d Basic cards everyone starts with"):format(basics), 0.6, 0.6, 0.6)
    tip:AddDoubleLine("Dust", tostring(TC.db.dust), 1, 1, 1, 0.6, 0.8, 1)
    tip:AddLine(" ")
    tip:AddLine("|cffffffffClick|r to open your card book", 0.7, 0.7, 0.7)
    tip:AddLine("|cffffffffShift-click|r to play", 0.7, 0.7, 0.7)
    tip:AddLine("|cffffffffRight-click|r for options", 0.7, 0.7, 0.7)
end

-- ---- LibDBIcon path ----------------------------------------------------------------------------

local function libButton()
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    return DBIcon and DBIcon.GetMinimapButton and DBIcon:GetMinimapButton("TavernCards")
end

local function registerLib()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then
        return false, "libraries not loaded"
    end
    local launcher = LDB:GetDataObjectByName("TavernCards") or LDB:NewDataObject("TavernCards", {
        type = "launcher",
        text = "Tavern Cards",
        icon = ICON,
        OnClick = onClick,
        OnTooltipShow = tooltip,
    })
    if not DBIcon:IsRegistered("TavernCards") then
        -- The .toc's AddonCompartmentFunc already provides the compartment entry.
        DBIcon:Register("TavernCards", launcher, TC.db.settings.minimap)
    end
    local b = libButton()
    if not b then
        return false, "LibDBIcon made no button"
    end
    return true
end

-- ---- hand-made fallback ------------------------------------------------------------------------

local own

local function placeOwn()
    local angle = math.rad(TC.db.settings.minimap.angle or 200)
    local radius = (Minimap:GetWidth() / 2) + 10
    own:ClearAllPoints()
    own:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function buildOwn()
    own = CreateFrame("Button", "TavernCardsMinimapButton", Minimap)
    own:SetSize(31, 31)
    own:SetFrameStrata("MEDIUM")
    own:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    own:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    own:RegisterForDrag("LeftButton")
    own:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local bg = own:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetPoint("TOPLEFT", 7, -5)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    local icon = own:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexture(ICON)
    local mask = own:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(icon)
    icon:AddMaskTexture(mask)
    local border = own:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    own:SetScript("OnClick", onClick)
    own:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        tooltip(GameTooltip)
        GameTooltip:Show()
    end)
    own:SetScript("OnLeave", function() GameTooltip:Hide() end)
    own:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()
            local cx, cy = GetCursorPosition()
            TC.db.settings.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
            placeOwn()
        end)
    end)
    own:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    placeOwn()
end

-- ---- public ------------------------------------------------------------------------------------

function Minimap_:Setup()
    local ok, result, why = true, false, "built-in button requested"
    if not TC.db.settings.minimap.forceOwn then
        ok, result, why = pcall(registerLib)
    end
    self.libOk = ok and result
    self.libWhy = not ok and tostring(result) or why
    local b = libButton()
    -- Use our own button when the library failed, or made a button nobody can see.
    if not self.libOk or not b or not b:GetParent() or b:GetWidth() == 0 then
        if b then b:Hide() end
        if not own then buildOwn() end
        self.mode = "own"
    else
        self.mode = "lib"
    end
    self:SetHidden(TC.db.settings.minimap.hide)
end

function Minimap_:SetHidden(hidden)
    TC.db.settings.minimap.hide = hidden and true or false
    if self.mode == "lib" then
        local DBIcon = LibStub("LibDBIcon-1.0", true)
        if hidden then DBIcon:Hide("TavernCards") else DBIcon:Show("TavernCards") end
    elseif own then
        own:SetShown(not hidden)
    end
end

function Minimap_:Report()
    local b = self.mode == "lib" and libButton() or own
    TC:Print("minimap button: mode %s%s, %s", tostring(self.mode),
        self.libWhy and (" (library: " .. self.libWhy .. ")") or "",
        b and ("shown=%s visible=%s size=%dx%d parent=%s"):format(tostring(b:IsShown()), tostring(b:IsVisible()),
            b:GetWidth(), b:GetHeight(), b:GetParent() and (b:GetParent():GetName() or "?") or "none") or "no button")
end

TC:On("PLAYER_LOGIN", function()
    Minimap_:Setup()
end)
