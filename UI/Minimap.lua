-- Minimap button through LibDataBroker + LibDBIcon, so it also works in minimap button bags.
--   Left-click:  open / close the card book
--   Shift-click: the Play tab
--   Right-click: menu

local TC = TavernCards_NS

local ICON = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01"

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
            TC.db.settings.minimap.hide = true
            LibStub("LibDBIcon-1.0"):Hide("TavernCards")
            TC:Print("Minimap button hidden. |cffffffff/tc minimap|r brings it back.")
        end)
    end)
end

function TC:SetupMinimap()
    local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
    local DBIcon = LibStub and LibStub("LibDBIcon-1.0", true)
    if not (LDB and DBIcon) then
        return
    end
    local launcher = LDB:NewDataObject("TavernCards", {
        type = "launcher",
        text = "Tavern Cards",
        icon = ICON,
        OnClick = function(owner, button)
            if button == "RightButton" then
                menu(owner)
            elseif IsShiftKeyDown() then
                TC:ShowWindow("play")
            else
                TC:ToggleWindow()
            end
        end,
        OnTooltipShow = function(tip)
            local owned, total = TC.Collection:Stats()
            tip:AddLine("Tavern Cards", 1, 0.82, 0)
            tip:AddDoubleLine("Collected", ("%d / %d"):format(owned, total), 1, 1, 1, 1, 1, 1)
            tip:AddDoubleLine("Dust", tostring(TC.db.dust), 1, 1, 1, 0.6, 0.8, 1)
            tip:AddLine(" ")
            tip:AddLine("|cffffffffClick|r to open your card book", 0.7, 0.7, 0.7)
            tip:AddLine("|cffffffffShift-click|r to play", 0.7, 0.7, 0.7)
            tip:AddLine("|cffffffffRight-click|r for options", 0.7, 0.7, 0.7)
        end,
    })
    -- The .toc's AddonCompartmentFunc already provides the compartment entry, so no LibDBIcon one.
    DBIcon:Register("TavernCards", launcher, TC.db.settings.minimap)
end

TC:On("PLAYER_LOGIN", function()
    TC:SetupMinimap()
end)
