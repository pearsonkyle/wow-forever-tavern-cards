-- Play tab (placeholder until the board lands).

local TC = TavernCards_NS

local function build(parent)
    local panel = CreateFrame("Frame", nil, parent)
    local bg = panel:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)
    bg:SetTexture("Interface\\QuestFrame\\QuestBG")
    bg:SetTexCoord(0, 0.6, 0, 0.75)
    local header = panel:CreateFontString(nil, "OVERLAY", "QuestFont_Huge")
    header:SetPoint("TOP", 0, -60)
    header:SetText("The Tavern Table")
    header:SetTextColor(0.25, 0.15, 0.05)
    local body = panel:CreateFontString(nil, "OVERLAY", "QuestFont")
    body:SetPoint("TOP", header, "BOTTOM", 0, -16)
    body:SetWidth(460)
    body:SetTextColor(0.3, 0.2, 0.1)
    body:SetText("Challenge innkeepers, battlemasters and stable masters across Azeroth, practice against the house, or play a friend in your party.\n\nThe rules engine is being built. Until then, build your decks: every quest adds to your collection.")
    return panel
end

TC:RegisterPanel("play", "Play", build)
