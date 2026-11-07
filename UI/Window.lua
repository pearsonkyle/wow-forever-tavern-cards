-- The card book: a native portrait window with bottom tabs, sized around the spellbook page art.
--   TC:ToggleWindow()          TC:ShowWindow("collection" | "decks" | "play" | "ledger")
-- Panels register with TC:RegisterPanel(key, title, builder); builder(parent) returns a frame
-- that may define :Refresh().

local TC = TavernCards_NS
local Art = TC.Art

local PAGE_HEIGHT = 470
local TOOLBAR = 64   -- title bar + toolbar above the pages
local FOOTER = 42    -- paging + progress under the pages

local panels, order = {}, {}
local window

function TC:RegisterPanel(key, title, builder)
    panels[key] = { key = key, title = title, builder = builder }
    order[#order + 1] = key
end

-- The page art decides the book's proportions; fall back to a sensible ratio if it is missing.
function TC:PageSize()
    local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("spellbook-Page-Left-C60")
    local width = PAGE_HEIGHT * 0.78
    if info and info.height and info.height > 0 then
        width = math.floor(info.width * PAGE_HEIGHT / info.height + 0.5)
        width = math.max(340, math.min(width, 460))
    end
    return width, PAGE_HEIGHT
end

local function createFrame()
    local f
    for _, template in ipairs({ "PortraitFrameTemplate", "ButtonFrameTemplate" }) do
        local ok, frame = pcall(CreateFrame, "Frame", "TavernCardsFrame", UIParent, template)
        if ok and frame then
            f = frame
            break
        end
    end
    if not f then
        f = CreateFrame("Frame", "TavernCardsFrame", UIParent, "BackdropTemplate")
        f:SetBackdrop({ bgFile = "Interface\\FrameGeneral\\UI-Background-Rock",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 256, edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", -3, -3)
        f.CloseButton = close
    end
    if ButtonFrameTemplate_HidePortrait and f.Inset then
        -- ButtonFrameTemplate: keep its inset hidden, the pages are our inset.
        f.Inset:Hide()
    end
    return f
end

local function setTitle(f, text)
    if f.SetTitle then
        f:SetTitle(text)
    elseif f.TitleContainer and f.TitleContainer.TitleText then
        f.TitleContainer.TitleText:SetText(text)
    elseif f.TitleText then
        f.TitleText:SetText(text)
    end
end

local function setPortrait(f, texture)
    local portrait = (f.PortraitContainer and f.PortraitContainer.portrait) or f.portrait
    if not portrait then
        return
    end
    portrait:SetTexture(texture)
    if not f.tcPortraitMask then
        local mask = f:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(portrait)
        portrait:AddMaskTexture(mask)
        f.tcPortraitMask = mask
    end
end

local function selectTab(key)
    window.active = key
    for i, k in ipairs(order) do
        local tab = window.tabs[i]
        local selected = k == key
        if PanelTemplates_SelectTab and PanelTemplates_DeselectTab then
            if selected then PanelTemplates_SelectTab(tab) else PanelTemplates_DeselectTab(tab) end
        end
        local panel = panels[k]
        if selected and not panel.frame then
            panel.frame = panel.builder(window.content)
            panel.frame:SetAllPoints(window.content)
        end
        if panel.frame then
            panel.frame:SetShown(selected)
        end
    end
    setTitle(window, "Tavern Cards - " .. panels[key].title)
    local frame = panels[key].frame
    if frame and frame.Refresh then
        frame:Refresh()
    end
end

local function build()
    local pageW, pageH = TC:PageSize()
    local f = createFrame()
    window = f
    f:SetSize(pageW * 2 + 28, pageH + TOOLBAR + FOOTER + 30)
    f:SetPoint("CENTER", 0, 20)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    setPortrait(f, "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
    tinsert(UISpecialFrames, "TavernCardsFrame")
    -- HideUIPanel is blocked in combat; a plain Hide is always allowed for our frame.
    if f.CloseButton then
        f.CloseButton:SetScript("OnClick", function() f:Hide() end)
    end
    f:SetScript("OnShow", function() Art:Play("IG_SPELLBOOK_OPEN") end)
    f:SetScript("OnHide", function() Art:Play("IG_SPELLBOOK_CLOSE") end)

    f.content = CreateFrame("Frame", nil, f)
    f.content:SetPoint("TOPLEFT", 12, -30)
    f.content:SetPoint("BOTTOMRIGHT", -12, 10)

    f.tabs = {}
    for i, key in ipairs(order) do
        local ok, tab = pcall(CreateFrame, "Button", "TavernCardsFrameTab" .. i, f, "PanelTabButtonTemplate")
        if not ok then
            tab = CreateFrame("Button", "TavernCardsFrameTab" .. i, f, "UIPanelButtonTemplate")
            tab:SetSize(110, 24)
        end
        tab:SetID(i)
        tab:SetText(panels[key].title)
        if PanelTemplates_TabResize then
            pcall(PanelTemplates_TabResize, tab, 0)
        end
        if i == 1 then
            tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
        else
            tab:SetPoint("TOPLEFT", f.tabs[i - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function()
            Art:Play("IG_CHARACTER_INFO_TAB")
            selectTab(key)
        end)
        f.tabs[i] = tab
    end
    if PanelTemplates_SetNumTabs then
        PanelTemplates_SetNumTabs(f, #order)
    end
    return f
end

function TC:ShowWindow(key)
    if not window then
        build()
    end
    window:Show()
    selectTab(panels[key] and key or window.active or order[1])
end

function TC:ToggleWindow()
    if window and window:IsShown() then
        window:Hide()
    else
        self:ShowWindow(window and window.active or order[1])
    end
end

function TC:RefreshWindow()
    if window and window:IsShown() and window.active then
        local frame = panels[window.active].frame
        if frame and frame.Refresh then
            frame:Refresh()
        end
    end
end

-- Toasts and links open the book on a card.
function TC:ShowCard(id)
    self:ShowWindow("collection")
    local frame = panels.collection and panels.collection.frame
    if frame and frame.FocusCard then
        frame:FocusCard(id)
    end
end

TC.Collection:Subscribe(function()
    TC:RefreshWindow()
end)
