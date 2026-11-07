-- A small yes/no dialog. Not StaticPopup: addon use of the shared StaticPopup frames taints them on
-- Forever (seen breaking the gamepad UI), so this is our own frame in the same style.
--   TC:Confirm(text, onAccept [, onDecline [, acceptText [, declineText [, timeout]]]])

local TC = TavernCards_NS

local dialog

local function build()
    local d = CreateFrame("Frame", "TavernCardsConfirm", UIParent, "BackdropTemplate")
    d:SetSize(320, 110)
    d:SetPoint("TOP", 0, -180)
    d:SetFrameStrata("FULLSCREEN_DIALOG")
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
    if dialog:IsShown() and dialog.onDecline then
        -- A new question replaces an open one: the old one counts as declined.
        local old = dialog.onDecline
        dialog.onDecline = nil
        TC:Safe("confirm", old)
    end
    dialog.text:SetText(text)
    dialog.onAccept, dialog.onDecline = onAccept, onDecline
    dialog.yes:SetText(acceptText or YES or "Yes")
    dialog.no:SetText(declineText or NO or "No")
    dialog.left = timeout
    dialog:SetHeight(math.max(110, dialog.text:GetStringHeight() + 80))
    dialog:Show()
    TC.Art:Play("IG_MAINMENU_OPEN")
end

-- A one-line text box in the same style: copying a deck code out (text given, select-all) or pasting one in.
--   TC:Prompt(title, text, onAccept(text) [, acceptText])     onAccept nil = copy only (a Close button)
local prompt

local function buildPrompt()
    local d = CreateFrame("Frame", "TavernCardsPrompt", UIParent, "BackdropTemplate")
    d:SetSize(420, 130)
    d:SetPoint("TOP", 0, -180)
    d:SetFrameStrata("FULLSCREEN_DIALOG")
    d:SetToplevel(true)
    d:EnableMouse(true)
    d:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    d.text = d:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    d.text:SetPoint("TOP", 0, -20)
    d.text:SetWidth(380)
    d.edit = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.edit:SetSize(360, 22)
    d.edit:SetPoint("TOP", d.text, "BOTTOM", 0, -10)
    d.edit:SetAutoFocus(true)
    d.edit:SetMaxLetters(400)
    d.yes = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.yes:SetSize(110, 24)
    d.yes:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -6, 16)
    d.no = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.no:SetSize(110, 24)
    d.no:SetPoint("BOTTOMLEFT", d, "BOTTOM", 6, 16)
    d.yes:SetScript("OnClick", function()
        d:Hide()
        if d.onAccept then TC:Safe("prompt", d.onAccept, d.edit:GetText()) end
    end)
    d.no:SetScript("OnClick", function() d:Hide() end)
    d.edit:SetScript("OnEnterPressed", function() d.yes:Click() end)
    d.edit:SetScript("OnEscapePressed", function() d:Hide() end)
    tinsert(UISpecialFrames, "TavernCardsPrompt")
    d:Hide()
    return d
end

function TC:Prompt(title, text, onAccept, acceptText)
    prompt = prompt or buildPrompt()
    prompt.text:SetText(title)
    prompt.onAccept = onAccept
    prompt.edit:SetText(text or "")
    if onAccept then
        prompt.yes:SetText(acceptText or OKAY or "Okay")
        prompt.yes:Show()
        prompt.no:SetText(CANCEL or "Cancel")
        prompt.no:ClearAllPoints()
        prompt.no:SetPoint("BOTTOMLEFT", prompt, "BOTTOM", 6, 16)
    else
        prompt.yes:Hide()
        prompt.no:SetText(CLOSE or "Close")
        prompt.no:ClearAllPoints()
        prompt.no:SetPoint("BOTTOM", 0, 16)
    end
    prompt:SetHeight(math.max(130, prompt.text:GetStringHeight() + 100))
    prompt:Show()
    prompt.edit:SetFocus()
    prompt.edit:HighlightText()
end
