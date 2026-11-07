-- Ledger tab: where every card came from, newest first.

local TC = TavernCards_NS
local Art = TC.Art

local function parchment(parent)
    local bg = parent:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    bg:SetTexture("Interface\\QuestFrame\\QuestBG")
    bg:SetTexCoord(0, 0.6, 0, 0.75)
    return bg
end

local function buildLedger(parent)
    local panel = CreateFrame("Frame", nil, parent)
    parchment(panel)

    local header = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    header:SetPoint("TOPLEFT", 28, -22)
    header:SetText("Card Ledger")
    header:SetTextColor(0.25, 0.15, 0.05)
    local sub = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    sub:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    sub:SetTextColor(0.3, 0.2, 0.1)

    local box = CreateFrame("Frame", nil, panel, "WowScrollBoxList")
    box:SetPoint("TOPLEFT", 24, -74)
    box:SetPoint("BOTTOMRIGHT", -44, 24)
    local scrollBar = CreateFrame("EventFrame", nil, panel, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", box, "TOPRIGHT", 8, 0)
    scrollBar:SetPoint("BOTTOMLEFT", box, "BOTTOMRIGHT", 8, 0)

    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(24)
    -- Element templates must be real XML templates; BackdropTemplate gives a plain Frame row.
    view:SetElementInitializer("BackdropTemplate", function(row, e)
        if not row.icon then
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(20, 20)
            row.icon:SetPoint("LEFT", 2, 0)
            row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
            row.name:SetWidth(230)
            row.name:SetJustifyH("LEFT")
            row.source = row:CreateFontString(nil, "OVERLAY", "GameFontBlack")
            row.source:SetPoint("LEFT", row.name, "RIGHT", 8, 0)
            row.source:SetPoint("RIGHT", -120, 0)
            row.source:SetJustifyH("LEFT")
            row.when = row:CreateFontString(nil, "OVERLAY", "GameFontBlackSmall")
            row.when:SetPoint("RIGHT", -6, 0)
            row.hl = row:CreateTexture(nil, "HIGHLIGHT")
            row.hl:SetAllPoints()
            row.hl:SetTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            row.hl:SetBlendMode("ADD")
            row:EnableMouse(true)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                TC:CardTooltip(self.id)
                local q = TC.Collection:EntryQuest(self.entry)
                if q then
                    TC.Quests:AddTooltipLines(GameTooltip, q)
                end
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row:SetScript("OnMouseUp", function(self) TC:ShowCard(self.id) end)
        end
        row.id = e.c
        row.icon:SetTexture(Art:Icon(e.c))
        row.name:SetText(Art:ColoredName(e.c))
        row.entry = e
        row.source:SetText(TC.Collection:EntrySource(e) .. (e.d and ("  |cff3060a0(+%d dust)|r"):format(e.d) or ""))
        row.when:SetText(e.t and date("%b %d %H:%M", e.t) or "")
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, scrollBar, view)

    function panel:Refresh()
        local provider = CreateDataProvider()
        local ledger = TC.db.ledger
        for i = #ledger, 1, -1 do
            if TC.Cards[ledger[i].c] then
                provider:Insert(ledger[i])
            end
        end
        box:SetDataProvider(provider)
        local owned, total = TC.Collection:Stats()
        sub:SetText(("%d of %d cards collected  -  %d dust"):format(owned, total, TC.db.dust))
    end
    return panel
end

TC:RegisterPanel("ledger", "Ledger", buildLedger)
