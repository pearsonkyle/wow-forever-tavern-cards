-- A small yes/no dialog. Not StaticPopup: addon use of the shared StaticPopup frames taints them on
-- Forever (seen breaking the gamepad UI), so this is our own frame in the same style.
--   TC:Confirm(text, onAccept [, onDecline [, acceptText [, declineText [, timeout]]]])

local TC = TavernCards_NS

local dialog

local function build()
    local d = CreateFrame("Frame", "TavernCardsConfirm", UIParent, "BackdropTemplate")
    d:SetSize(320, 110)
    d:SetPoint("TOP", 0, -180)
    d:SetFrameStrata("DIALOG")
    d:SetToplevel(true)
    d:EnableMouse(true)
    d:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    d.text = d:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    d.text:SetPoint("TOP", 0, -22)
    d.text:SetWidth(280)
    d.yes = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.yes:SetSize(110, 24)
    d.yes:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -6, 18)
    d.no = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.no:SetSize(110, 24)
    d.no:SetPoint("BOTTOMLEFT", d, "BOTTOM", 6, 18)
    d.yes:SetScript("OnClick", function()
        d:Hide()
        if d.onAccept then TC:Safe("confirm", d.onAccept) end
    end)
    d.no:SetScript("OnClick", function()
        d:Hide()
        if d.onDecline then TC:Safe("confirm", d.onDecline) end
    end)
    d:SetScript("OnUpdate", function(self, elapsed)
        if self.left then
            self.left = self.left - elapsed
            if self.left <= 0 then
                self.left = nil
                self.no:Click()
            end
        end
    end)
    tinsert(UISpecialFrames, "TavernCardsConfirm")
    d:Hide()
    return d
end

function TC:Confirm(text, onAccept, onDecline, acceptText, declineText, timeout)
    dialog = dialog or build()
    dialog.text:SetText(text)
    dialog.onAccept, dialog.onDecline = onAccept, onDecline
    dialog.yes:SetText(acceptText or YES or "Yes")
    dialog.no:SetText(declineText or NO or "No")
    dialog.left = timeout
    dialog:SetHeight(math.max(110, dialog.text:GetStringHeight() + 80))
    dialog:Show()
    TC.Art:Play("IG_MAINMENU_OPEN")
end
