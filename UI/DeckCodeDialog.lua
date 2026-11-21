-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Importing a deck code: paste it (or click a deck link in chat) and see the deck before it is saved: its class,
-- its cards, which of them you own, and where to earn or craft the rest.
--   TC.DeckCode:Open([text [, name]])     text: a code or a chat line holding one
--   TC.DeckCode:Preview(text)             the same, as data (no UI): what the dialog shows

local TC = TavernCards_NS
local DeckCode = {}
TC.DeckCode = DeckCode

local RARITY_ORDER = { FREE = 0, COMMON = 1, RARE = 2, EPIC = 3, LEGENDARY = 4 }
local ROWS = 15

-- Where a missing card comes from on this character: the quest, boss, achievement or level that pays it, else its
-- crafting price.
local function sourceText(id)
    local quest = TC.Quests and TC.Quests.SourceFor and TC.Quests:SourceFor(id)
    if quest then
        local info = TC.Quests:Info(quest)
        return "Quest: " .. (info and info.name or ("#" .. quest))
    end
    local key = TC.Rewards and TC.Rewards.SourceFor and TC.Rewards:SourceFor(id)
    if key then return TC.Rewards:Describe(key) end
    local card = TC.Cards[id]
    local price = card and TC.Collection.CRAFT[card.rarity]
    return price and price > 0 and ("Craft for %d dust"):format(price) or nil
end

-- What a pasted text holds: { code, name, deck, why (an IMPORT_ERRORS key), owned, total, missingDust, rows }.
function DeckCode:Preview(text)
    text = text or ""
    local out = { name = text:match("%[Tavern Deck: ([^%]]+)%]"), rows = {} }
    out.code = text:match("(TCD%d%.%u+%.[%w%+/]+)") or text:gsub("%s", "")
    if out.code == "" then return out end
    local deck, why = TC.Decks:Decode(out.code)
    if deck and not TC.Decks:IsUnlocked(deck.class) then why = "locked" end
    out.deck, out.why = deck, why
    if not deck then return out end
    out.total, out.owned, out.missingDust = TC.Decks:Count(deck), TC.Decks:OwnedCount(deck), 0
    for id, n in pairs(deck.cards) do
        local card = TC.Cards[id]
        local have = math.min(n, TC.Collection:Count(id))
        local row = { id = id, n = n, have = have, card = card }
        if have < n then
            row.source = sourceText(id)
            out.missingDust = out.missingDust + (n - have) * (TC.Collection.CRAFT[card.rarity] or 0)
        end
        out.rows[#out.rows + 1] = row
    end
    table.sort(out.rows, function(a, b)
        if a.card.cost ~= b.card.cost then return a.card.cost < b.card.cost end
        if a.card.name ~= b.card.name then return a.card.name < b.card.name end
        return a.id < b.id
    end)
    return out
end

local dialog

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

local function build()
    local d = CreateFrame("Frame", "TavernCardsDeckCode", UIParent, "BackdropTemplate")
    d:SetSize(520, 520)
    d:SetPoint("CENTER", 0, 40)
    d:SetFrameStrata("DIALOG")
    d:SetToplevel(true)
    d:SetClampedToScreen(true)
    d:EnableMouse(true)
    d:SetMovable(true)
    d:RegisterForDrag("LeftButton")
    d:SetScript("OnDragStart", d.StartMoving)
    d:SetScript("OnDragStop", d.StopMovingOrSizing)
    d:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 } })
    d.title = d:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    d.title:SetPoint("TOP", 0, -20)
    d.title:SetText("Import a Deck")
    d.hint = d:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    d.hint:SetPoint("TOP", d.title, "BOTTOM", 0, -6)
    d.hint:SetText("Paste a Tavern Cards deck code (Ctrl+V), or a chat line with one.")

    d.code = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.code:SetSize(440, 22)
    d.code:SetPoint("TOP", d.hint, "BOTTOM", 0, -10)
    d.code:SetAutoFocus(true)
    d.code:SetMaxLetters(600)
    d.code:SetScript("OnTextChanged", function() DeckCode:Update() end)
    d.code:SetScript("OnEscapePressed", function() d:Hide() end)

    local nameLabel = d:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    nameLabel:SetPoint("TOPLEFT", 40, -96)
    nameLabel:SetText("Deck name:")
    d.name = CreateFrame("EditBox", nil, d, "InputBoxTemplate")
    d.name:SetSize(250, 20)
    d.name:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
    d.name:SetAutoFocus(false)
    d.name:SetMaxLetters(40)
    d.name:SetScript("OnEscapePressed", function() d:Hide() end)

    d.status = d:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    d.status:SetPoint("TOPLEFT", 36, -122)
    d.status:SetPoint("RIGHT", -36, 0)
    d.status:SetJustifyH("LEFT")

    -- The card list: cost, name (rarity colour), copies and ownership; missing ones say where to get them.
    d.rows = {}
    for i = 1, ROWS do
        local r = CreateFrame("Button", nil, d)
        r:SetSize(448, 20)
        r:SetPoint("TOPLEFT", 36, -146 - (i - 1) * 21)
        r.cost = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        r.cost:SetPoint("LEFT", 0, 0)
        r.cost:SetWidth(20)
        r.name = r:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        r.name:SetPoint("LEFT", 26, 0)
        r.name:SetWidth(200)
        r.name:SetJustifyH("LEFT")
        r.where = r:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        r.where:SetPoint("LEFT", 232, 0)
        r.where:SetPoint("RIGHT", 0, 0)
        r.where:SetJustifyH("LEFT")
        r:SetScript("OnEnter", function(self)
            if not self.id then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            TC:CardTooltip(self.id, true)
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        d.rows[i] = r
    end
    d:EnableMouseWheel(true)
    d:SetScript("OnMouseWheel", function(_, delta)
        d.offset = math.max(0, math.min((d.preview and #d.preview.rows or 0) - ROWS, (d.offset or 0) - delta))
        DeckCode:Draw()
    end)

    d.import = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.import:SetSize(130, 24)
    d.import:SetPoint("BOTTOMRIGHT", d, "BOTTOM", -6, 18)
    d.import:SetText("Import Deck")
    d.import:SetScript("OnClick", function()
        local p = d.preview
        if not (p and p.deck and not p.why) then return end
        local deck, why = TC.Decks:Import(p.code, d.name:GetText())
        if not deck then
            TC:Print(TC.Decks.IMPORT_ERRORS[why] or "That deck can't be imported.")
            return
        end
        d:Hide()
        TC:Print("Deck \"%s\" imported. Missing cards can be crafted with dust.", deck.name)
        TC:ShowWindow("decks")
        if d.onImport then TC:Safe("deck import", d.onImport, deck) end
    end)
    d.cancel = CreateFrame("Button", nil, d, "UIPanelButtonTemplate")
    d.cancel:SetSize(130, 24)
    d.cancel:SetPoint("BOTTOMLEFT", d, "BOTTOM", 6, 18)
    d.cancel:SetText(CANCEL or "Cancel")
    d.cancel:SetScript("OnClick", function() d:Hide() end)
    tinsert(UISpecialFrames, "TavernCardsDeckCode")
    d:Hide()
    return d
end

function DeckCode:Update()
    local d = dialog
    local p = self:Preview(d.code:GetText())
    d.preview, d.offset = p, 0
    if p.name and d.name:GetText() == "" then d.name:SetText(p.name) end
    if p.code == "" then
        d.status:SetText("")
        d.status:SetTextColor(1, 0.82, 0)
    elseif not p.deck or p.why then
        d.status:SetText(TC.Decks.IMPORT_ERRORS[p.why] or "That deck can't be imported.")
        d.status:SetTextColor(1, 0.3, 0.3)
    else
        local missing = p.total - p.owned
        d.status:SetText(("%s deck, %d cards. You own %d%s."):format(className(p.deck.class), p.total, p.owned,
            missing > 0 and (" (%d missing; crafting them all: %d dust, you have %d)"):format(missing, p.missingDust, TC.db.dust or 0) or ""))
        d.status:SetTextColor(1, 0.82, 0)
    end
    d.import:SetEnabled(p.deck ~= nil and not p.why)
    self:Draw()
end

function DeckCode:Draw()
    local d = dialog
    local rows = d.preview and d.preview.rows or {}
    for i, r in ipairs(d.rows) do
        local row = rows[(d.offset or 0) + i]
        r.id = row and row.id
        if row then
            local c = row.card
            local cr, cg, cb = TC.Art:RarityColor(c.rarity)
            r.cost:SetText(c.cost)
            r.name:SetText(("%s%s"):format(c.name, row.n > 1 and ("  x" .. row.n) or ""))
            r.name:SetTextColor(cr, cg, cb)
            if row.have >= row.n then
                r.where:SetText("|cff40c040Owned|r")
            else
                r.where:SetText(("|cffff7070Missing %d|r  %s"):format(row.n - row.have, row.source or ""))
            end
            r:Show()
        else
            r:Hide()
        end
    end
end

-- Opens the dialog, pre-filled with a code (a deck link's) or empty for pasting. onImport(deck) after a save.
function DeckCode:Open(text, name, onImport)
    dialog = dialog or build()
    dialog.onImport = onImport
    dialog.name:SetText(name or "")
    dialog.code:SetText(text or "")
    dialog:Show()
    self:Update()
    dialog.code:SetFocus()
    TC.Art:Play("IG_MAINMENU_OPEN")
end
