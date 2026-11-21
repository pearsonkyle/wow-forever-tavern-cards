-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Board layout: build() creates the table's frame tree and places every element.

local TC = TavernCards_NS
local Board = TC.Board
local P, S = Board._P, Board._S
local Art = TC.Art
local CardWidget = TC.CardWidget
local H, HAND_SCALE, HUGE_FONT, SLOT_H, W = P.H, P.HAND_SCALE, P.HUGE_FONT, P.SLOT_H, P.W

-- ---- building the frame ------------------------------------------------------------------------

local function build()
    local f = CreateFrame("Frame", "TavernCardsBoard", UIParent, "BackdropTemplate")
    S.frame = f
    f:SetSize(W, H)
    f:SetPoint("CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    -- Moved by dragging its background, like the card book; where it stands is kept (Board:SavePlacement).
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        Board:SavePlacement()
    end)
    f:Hide()
    tinsert(UISpecialFrames, "TavernCardsBoard")
    -- The window's gold border round the table, on its own layer above the table art.
    f.edge = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.edge:SetAllPoints()
    f.edge:SetFrameLevel(f:GetFrameLevel() + 1)
    f.edge:EnableMouse(false)
    -- A size grip in the corner, as on the game's resizable windows: drag to scale the table, its top-left corner
    -- staying put; never past what fits on screen. Options > Tavern table size has Fit to screen.
    local grip = CreateFrame("Button", nil, f)
    f.grip = grip
    grip:SetSize(18, 18)
    grip:SetPoint("BOTTOMRIGHT", -7, 7)
    grip:SetFrameLevel(f:GetFrameLevel() + 30)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local scale = f:GetScale()
        local left, top = f:GetLeft(), f:GetTop()
        if not left then return end
        left, top = left * scale, top * scale   -- UIParent units
        local ui = UIParent:GetEffectiveScale()
        self:SetScript("OnUpdate", function()
            local cx = GetCursorPosition() / ui
            local s = math.max(0.4, math.min(Board:FitScale(), (cx - left) / W))
            f:SetScale(s)
            f:ClearAllPoints()
            f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left / s, top / s)
        end)
    end)
    grip:SetScript("OnMouseUp", function(self)
        if not self:GetScript("OnUpdate") then return end
        self:SetScript("OnUpdate", nil)
        if TC.db then TC.db.settings.tableScale = f:GetScale() end
        Board:SavePlacement()
        Board:FitScreen()
    end)
    grip:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:SetText("Resize the table", 1, 0.82, 0)
        GameTooltip:AddLine("Drag to make it bigger or smaller. Drag the table itself to move it.", 1, 1, 1, true)
        GameTooltip:AddLine("Options > AddOns > Tavern Cards: Fit to screen.", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.edge:SetBackdrop({ edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 32 })

    -- The table: wooden planks with a stone play surface inlaid where the minions stand, ringed in brass
    -- (Textures/board_table). A painting the player picked (Board:SetTable) tints the wood only; the
    -- zone's map (Board:SetMat) shows faintly in the stone, as if drawn on it.
    local layout = TC.TexLayout
    f.board = f:CreateTexture(nil, "BACKGROUND", nil, 0)
    f.board:SetPoint("TOPLEFT", 6, -6)
    f.board:SetPoint("BOTTOMRIGHT", -6, 6)
    f.board:SetTexture(Art:Tex("board_table"))   -- drawn to fill the texture: no texture coordinates
    f.tableArt = f:CreateTexture(nil, "BACKGROUND", nil, 1)
    f.tableArt:SetAllPoints(f.board)
    local woodOnly = f:CreateMaskTexture()
    -- (A mask ignores texture coordinates, which is why the board textures fill theirs.)
    woodOnly:SetTexture(Art:Tex("board_wood_mask"), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    woodOnly:SetAllPoints(f.board)
    f.tableArt:AddMaskTexture(woodOnly)
    f.tableArt:Hide()
    f.tableSoft = {}
    -- Darker edges, so the controls at the sides read over a painting.
    f.tableEdge = f:CreateTexture(nil, "BACKGROUND", nil, 4)
    f.tableEdge:SetPoint("TOPLEFT", 0, 0)
    f.tableEdge:SetPoint("BOTTOMRIGHT", f, "BOTTOMLEFT", 220, 0)
    f.tableEdge:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.tableEdge:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0.35), CreateColor(0, 0, 0, 0))
    f.tableEdge:Hide()
    f.tableEdgeR = f:CreateTexture(nil, "BACKGROUND", nil, 4)
    f.tableEdgeR:SetPoint("TOPRIGHT", 0, 0)
    f.tableEdgeR:SetPoint("BOTTOMRIGHT", 0, 0)
    f.tableEdgeR:SetWidth(220)
    f.tableEdgeR:SetTexture("Interface\\Buttons\\WHITE8x8")
    f.tableEdgeR:SetGradient("HORIZONTAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.35))
    f.tableEdgeR:Hide()
    local top = f:CreateTexture(nil, "BACKGROUND", nil, 3)
    top:SetAllPoints()
    top:SetColorTexture(1, 1, 1, 1)
    top:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0))
    f.wash = top
    -- The play mat: the stone surface's rectangle; a world map shows in it (Board:SetMat).
    local sx0, sy0, sx1, sy1 = unpack(layout.surface)
    local mat = CreateFrame("Frame", nil, f)
    mat:SetPoint("TOPLEFT", sx0 * W, -sy0 * H)
    mat:SetSize((sx1 - sx0) * W, (sy1 - sy0) * H)
    mat:SetFrameLevel(f:GetFrameLevel())
    if mat.SetClipsChildren then mat:SetClipsChildren(true) end
    local matW = (sx1 - sx0) * W
    local tile = matW / 4
    mat.grid = CreateFrame("Frame", nil, mat)
    mat.grid:SetFrameLevel(f:GetFrameLevel())
    mat.grid:SetSize(matW, tile * 3)
    mat.grid:SetPoint("CENTER", mat, "CENTER", 0, 0)
    mat.tiles = {}
    for i = 1, 12 do
        local t = mat.grid:CreateTexture(nil, "BACKGROUND", nil, 1)
        t:SetSize(tile, tile)
        t:SetPoint("TOPLEFT", ((i - 1) % 4) * tile, -math.floor((i - 1) / 4) * tile)
        mat.tiles[i] = t
    end
    -- A warm wash over the map so it sits in the stone rather than on it (Board:SetMat sets its strength).
    local felt = mat.grid:CreateTexture(nil, "BORDER")
    felt:SetAllPoints(mat)
    felt:SetColorTexture(1, 1, 1, 1)
    felt:SetGradient("VERTICAL", CreateColor(0.6, 0.5, 0.36, 0), CreateColor(0.6, 0.5, 0.36, 0))
    f.felt = felt
    f.mat = mat
    -- The brass seam between the two sides.
    local seam = mat.grid:CreateTexture(nil, "ARTWORK")
    seam:SetPoint("LEFT", mat, "LEFT", 8, 0)
    seam:SetPoint("RIGHT", mat, "RIGHT", -8, 0)
    seam:SetHeight(16)
    seam:SetTexture(Art:Tex("board_seam"))
    seam:SetAlpha(0.85)

    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOPLEFT", 26, -20)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -8, -8)
    close:SetScript("OnClick", function() f:Hide() end)
    -- Sound on/off, right on the table.
    f.sound = CreateFrame("Button", nil, f)
    f.sound:SetSize(22, 22)
    f.sound:SetPoint("RIGHT", close, "LEFT", -4, 0)
    f.sound.icon = f.sound:CreateTexture(nil, "ARTWORK")
    f.sound.icon:SetAllPoints()
    f.sound:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local function soundIcon()
        local muted = TC.db.settings.mute
        f.sound.icon:SetTexture(Art:SafeIcon(muted and "Spell_Shadow_SoulLeech_3" or "Spell_Holy_Silence"))
        f.sound.icon:SetDesaturated(muted and true or false)
    end
    f.sound:SetScript("OnClick", function()
        TC.db.settings.mute = not TC.db.settings.mute
        soundIcon()
    end)
    f.sound:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText(TC.db.settings.mute and "Sounds off" or "Sounds on", 1, 0.82, 0)
        GameTooltip:AddLine("Click to turn the card game's sounds " .. (TC.db.settings.mute and "on." or "off."), 1, 1, 1)
        GameTooltip:Show()
    end)
    f.sound:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.sound:SetScript("OnShow", soundIcon)
    soundIcon()
    f.concede = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.concede:SetSize(90, 22)
    f.concede:SetPoint("RIGHT", f.sound, "LEFT", -6, 0)
    f.concede:SetText("Concede")
    f.concede:SetScript("OnClick", function() Board:Concede() end)
    -- Back to the Play tab; the match waits (Return to Table brings you back).
    f.leave = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.leave:SetSize(80, 22)
    f.leave:SetPoint("RIGHT", f.concede, "LEFT", -6, 0)
    f.leave:SetText("Return")
    f.leave:SetScript("OnClick", function()
        f:Hide()
        TC:ShowWindow("play")
    end)
    f.leave:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Return to the Play tab", 1, 0.82, 0)
        GameTooltip:AddLine("The match waits for you: Return to Table picks it up again.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.leave:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- Opponent (top).
    f.oppHand = CreateFrame("Frame", nil, f)
    f.oppHand:SetSize(400, 48)
    f.oppHand:SetPoint("TOP", 0, -26)
    f.oppHand.backs = {}
    -- Each side's deck: a pile of its card backs with the cards left.
    f.piles = {}
    for side = 0, 1 do
        local pile = P.cardBack(f, 42, 60)
        pile:SetPoint("TOPRIGHT", f, "TOPRIGHT", -150, side == 1 and -96 or -446)
        pile.count = pile:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
        pile.count:SetPoint("BOTTOM", 0, 4)
        pile.count:SetShadowOffset(1, -1)
        pile.shadow = pile:CreateTexture(nil, "BACKGROUND", nil, -1)
        pile.shadow:SetPoint("TOPLEFT", 3, -3)
        pile.shadow:SetPoint("BOTTOMRIGHT", 5, -5)
        pile.shadow:SetColorTexture(0, 0, 0, 0.5)
        pile:EnableMouse(true)
        pile:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(side == 0 and "Your deck" or "Opponent's deck", 1, 0.82, 0)
            GameTooltip:AddLine(("%s cards left. Card back: %s."):format(self.count:GetText() or "?",
                TC.CardBacks:Name(self.backId)), 1, 1, 1, true)
            GameTooltip:Show()
        end)
        pile:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.piles[side] = pile
    end
    for i = 1, 10 do
        local back = P.cardBack(f.oppHand)
        f.oppHand.backs[i] = back
    end
    f.heroes = { [0] = P.heroWidget(f, 0), [1] = P.heroWidget(f, 1) }
    f.heroes[1]:SetPoint("TOP", 0, -84)
    f.heroes[0]:SetPoint("TOP", 0, -432)
    f.powers, f.weapons, f.mana = {}, {}, {}
    for seat = 0, 1 do
        local hero = f.heroes[seat]
        f.powers[seat] = P.powerButton(f)
        f.powers[seat]:SetPoint("LEFT", hero, "RIGHT", 22, -8)
        f.weapons[seat] = P.weaponWidget(f)
        f.weapons[seat]:SetPoint("RIGHT", hero, "LEFT", -22, -8)
        f.mana[seat] = P.manaBar(f)
        f.mana[seat]:SetPoint("LEFT", f.powers[seat], "RIGHT", 18, 0)
    end
    f.powers[0]:SetScript("OnClick", function(_, button)
        if button == "RightButton" then return Board:Cancel() end
        TC:Safe("hero power", Board.ClickPower, Board)
    end)

    f.rows = { [0] = {}, [1] = {} }
    for seat = 0, 1 do
        for i = 1, 7 do
            f.rows[seat][i] = P.minionWidget(f)
        end
    end
    -- Gaps between your minions, shown while placing one.
    f.gaps = {}
    for i = 1, 8 do
        local g = CreateFrame("Button", nil, f)
        g:SetSize(18, SLOT_H)
        local t = g:CreateTexture(nil, "OVERLAY")
        t:SetAllPoints()
        t:SetColorTexture(1, 0.85, 0.2, 0.55)
        g:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
        g:GetHighlightTexture():SetVertexColor(1, 0.9, 0.4, 0.6)
        g:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        g:SetScript("OnClick", function(self, button)
            if button == "RightButton" then return Board:Cancel() end
            TC:Safe("place", Board.ClickGap, Board, self.position)
        end)
        g:Hide()
        f.gaps[i] = g
    end

    -- Your hand (bottom), slightly smaller cards.
    f.hand = CreateFrame("Frame", nil, f)
    f.hand:SetScale(HAND_SCALE)
    f.hand:SetSize(760 / HAND_SCALE, CardWidget.HEIGHT)
    f.hand:SetPoint("BOTTOM", 0, 26)
    f.hand.cards = {}
    for i = 1, 10 do
        local w = CardWidget:CreateGame(f.hand)
        P.addBorderGlow(w)
        -- Hovered cards lift above their neighbours so the whole card can be read.
        w.onEnter = function(self)
            self.hovered = true
            if not self.baseX then return end
            P.glideTo(self, P.placeHand, self.baseX, 40)
            self:SetFrameLevel(f.hand:GetFrameLevel() + 60)
        end
        w.onLeave = function(self)
            self.hovered = false
            if not self.baseX then return end
            P.glideTo(self, P.placeHand, self.baseX, self.baseY or 0)
            self:SetFrameLevel(self.baseLevel or f.hand:GetFrameLevel())
        end
        w.onClick = function(self, button)
            if button == "RightButton" then return Board:Cancel() end
            TC:Safe("hand click", Board.ClickHand, Board, self.entity, self)
        end
        f.hand.cards[i] = w
    end

    -- Log (left) and turn controls (right).
    -- The match log: our own little panel (newest at the bottom, mouse wheel scrolls back).
    local log = CreateFrame("Frame", nil, f, "BackdropTemplate")
    log:SetPoint("TOPLEFT", 16, -184)
    log:SetSize(152, 236)
    log:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    log:SetBackdropColor(0.05, 0.03, 0.02, 0.75)
    log:SetBackdropBorderColor(0.6, 0.5, 0.3, 0.8)
    log.lines, log.entries, log.offset = {}, {}, 0
    local LOG_LINES = 13
    local VERB = { play = "played", attack = "attacked with", hero_power = "used", end_turn = "ended the turn",
        trade = "traded", forge = "forged", launch = "launched" }

    -- Hovering a line shows the card that was played (or attacked with) exactly as hovering the card does,
    -- full text and keywords, with who did it and at whom underneath. Hero powers and turn ends get a
    -- short description.
    local function lineEnter(row)
        local e = row.entry
        if not e then return end
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        local info = e.info
        local card = info and info.card and TC.Cards[info.card]
        if card then
            TC:CardTooltip(info.card, true)
            GameTooltip:AddLine(" ")
        elseif info and info.power then
            GameTooltip:SetText(info.power, 1, 0.82, 0)
            if info.powerText then GameTooltip:AddLine(info.powerText, 1, 1, 1, true) end
            GameTooltip:AddLine(" ")
        else
            GameTooltip:SetText("Match log", 1, 0.82, 0)
        end
        if info then
            local who = info.mine and "|cff60ff60You|r" or "|cffff7050Your opponent|r"
            local what = card and (" %s |cffffd100%s|r"):format(VERB[info.action] or info.action or "", card.name)
                or (info.power and " used the hero power") or ""
            if not card and info.action == "play" and not info.mine then what = " played a Secret" end
            if info.action == "end_turn" then what = " ended the turn" end
            GameTooltip:AddLine(("Turn %d: %s%s"):format(info.turn or 0, who, what), 1, 1, 1, true)
            if info.target then GameTooltip:AddLine(("Target: |cffffffff%s|r"):format(info.target), 1, 0.6, 0.4) end
        else
            GameTooltip:AddLine(e.text, 1, 1, 1, true)
        end
        GameTooltip:Show()
    end

    local function lineLeave()
        GameTooltip:Hide()
    end

    for i = 1, LOG_LINES do
        local row = CreateFrame("Button", nil, log)
        row:SetSize(140, 17)
        row:SetPoint("BOTTOMLEFT", 6, 5 + (i - 1) * 17)
        row:SetHighlightTexture("Interface\\Buttons\\WHITE8x8", "ADD")
        row:GetHighlightTexture():SetVertexColor(1, 0.85, 0.4, 0.15)
        row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.text:SetPoint("LEFT", 2, 0)
        row.text:SetWidth(136)
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(false)
        row:SetScript("OnEnter", lineEnter)
        row:SetScript("OnLeave", lineLeave)
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) log:Scroll(delta) end)
        log.lines[i] = row
    end
    function log:Render()
        local n = #self.entries
        for i = 1, LOG_LINES do
            local e = self.entries[n - self.offset - i + 1]
            local row = self.lines[i]
            row.entry = e
            row.text:SetText(e and e.shown or "")
            row:SetShown(e ~= nil)
        end
    end
    function log:Scroll(delta)
        self.offset = math.max(0, math.min(#self.entries - LOG_LINES, self.offset + delta))
        self:Render()
    end
    function log:Clear()
        wipe(self.entries)
        self.offset = 0
        self:Render()
    end
    -- info: what happened (UI/Match.lua logInfo), for the hover; lines restored after a reload have none.
    function log:AddMessage(line, info)
        line = tostring(line)
        local shown = line:gsub("^You: ", "|cff60ff60You:|r "):gsub("^Opponent: ", "|cffff7050Them:|r ")
        self.entries[#self.entries + 1] = { text = line, shown = shown, info = type(info) == "table" and info or nil }
        self.offset = 0
        self:Render()
    end
    log:EnableMouseWheel(true)
    log:SetScript("OnMouseWheel", function(self, delta) self:Scroll(delta) end)
    f.log = log
    local logTitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    logTitle:SetPoint("BOTTOMLEFT", log, "TOPLEFT", 4, 4)
    logTitle:SetText("Match log")

    -- End turn: a stone button (Textures/button_end_turn rows: ready, hover, waiting, your-turn glow).
    f.endTurn = CreateFrame("Button", nil, f)
    f.endTurn:SetSize(140, 36)
    f.endTurn:SetPoint("RIGHT", -28, 35)
    local function row(t, r)
        t:SetTexture(Art:Tex("button_end_turn"))
        t:SetTexCoord(0, 1, (r - 1) / 4, r / 4)
        return t
    end
    f.endTurn:SetNormalTexture(row(f.endTurn:CreateTexture(), 1))
    f.endTurn:SetHighlightTexture(row(f.endTurn:CreateTexture(), 2))
    f.endTurn:GetHighlightTexture():SetBlendMode("ADD")
    f.endTurn:GetHighlightTexture():SetAlpha(0.5)
    f.endTurn:SetDisabledTexture(row(f.endTurn:CreateTexture(), 3))
    f.endTurn:SetPushedTexture(row(f.endTurn:CreateTexture(), 2))
    f.endTurn:SetNormalFontObject("GameFontHighlightLarge")
    f.endTurn:SetDisabledFontObject("GameFontDisableLarge")
    f.endTurn:SetText("End Turn")
    f.endTurn:SetScript("OnClick", function() TC:Safe("end turn", Board.ClickEndTurn, Board) end)
    f.endGlow = P.addGlow(f.endTurn, 1.4)
    f.launch = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.launch:SetSize(140, 24)
    f.launch:SetPoint("BOTTOM", f.endTurn, "TOP", 0, 8)
    f.launch:SetText("Launch Starship")
    f.launch:SetScript("OnClick", function(self) Board:Launch(self.index) end)
    f.launch:Hide()
    f.claim = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.claim:SetSize(140, 24)
    f.claim:SetPoint("TOP", f.endTurn, "BOTTOM", 0, -52)
    f.claim:SetText("Claim Win")
    f.claim:SetScript("OnClick", function()
        TC:Confirm("Your opponent hasn't answered for a while. Claim the win?", function() TC.Duel:ClaimWin() end)
    end)
    f.claim:Hide()

    -- Escape cancels a half-made move before it closes the table.
    f:EnableKeyboard(true)
    f:SetPropagateKeyboardInput(true)
    f:SetScript("OnKeyDown", function(self, key)
        if InCombatLockdown and InCombatLockdown() then return end
        if key == "ESCAPE" and S.sel then
            Board:Cancel()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.status:SetPoint("TOP", f.endTurn, "BOTTOM", 0, -10)
    f.status:SetWidth(170)
    f.hint = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.hint:SetPoint("BOTTOM", f.heroes[0], "TOP", 0, 128)

    -- The card the opponent just played, shown for a moment.
    f.showcase = CardWidget:CreateGame(f)
    f.showcase:SetPoint("TOPRIGHT", -40, -60)
    f.showcase:Hide()
    f.showcaseLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    f.showcaseLabel:SetPoint("BOTTOM", f.showcase, "TOP", 0, 4)

    -- Turn banner and the end-of-match banner.
    f.banner = f:CreateFontString(nil, "OVERLAY", HUGE_FONT)
    f.banner:SetPoint("CENTER", 0, 40)
    f.banner:SetTextColor(1, 0.82, 0)
    f.banner:SetShadowOffset(3, -3)
    f.banner:Hide()

    f.over = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.over:SetFrameLevel(f:GetFrameLevel() + 50)
    f.over:SetPoint("CENTER", 0, 20)
    f.over:SetSize(420, 190)
    f.over:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    f.over:EnableMouse(true)
    f.over.text = f.over:CreateFontString(nil, "OVERLAY", HUGE_FONT)
    f.over.text:SetPoint("TOP", 0, -26)
    f.over.reason = f.over:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.over.reason:SetPoint("TOP", f.over.text, "BOTTOM", 0, -10)
    f.over.reward = f.over:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.over.reward:SetPoint("TOP", f.over.reason, "BOTTOM", 0, -8)
    local leave = CreateFrame("Button", nil, f.over, "UIPanelButtonTemplate")
    leave:SetSize(130, 26)
    leave:SetPoint("BOTTOMRIGHT", f.over, "BOTTOM", -6, 20)
    leave:SetText("Leave Table")
    leave:SetScript("OnClick", function()
        f:Hide()
        TC:ShowWindow("play")
    end)
    local again = CreateFrame("Button", nil, f.over, "UIPanelButtonTemplate")
    again:SetSize(130, 26)
    again:SetPoint("BOTTOMLEFT", f.over, "BOTTOM", 6, 20)
    again:SetText("Rematch")
    again:SetScript("OnClick", function() TC:Safe("rematch", Board.Rematch, Board) end)
    f.over:Hide()

    f.choice = P.buildChoice()
    P.buildArrow(f)

    local bannerTime = 0
    f:SetScript("OnUpdate", function(_, elapsed)
        P.updateFloats(elapsed)
        P.updateGhosts(elapsed)
        P.updateEffects(elapsed)
        P.updateFlyers(elapsed)
        P.updateGliders(elapsed)
        P.updateArrow()
        local pulse = 0.6 + 0.4 * math.sin(GetTime() * 5)
        for _, g in ipairs(P.allGlows) do
            if g:IsShown() then g:SetAlpha(pulse) end
        end
        if f.banner:IsShown() then
            bannerTime = bannerTime + elapsed
            if bannerTime > 1.6 then
                f.banner:Hide()
            else
                f.banner:SetAlpha(bannerTime < 1 and 1 or (1.6 - bannerTime) / 0.6)
            end
        else
            bannerTime = 0
        end
        if f.showcaseUntil and GetTime() > f.showcaseUntil then
            f.showcaseUntil = nil
            f.showcase:Hide()
            f.showcaseLabel:SetText("")
        end
        Board:StatusTick()
    end)
    f:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then Board:Cancel() end
    end)
    f:SetScript("OnShow", function() Art:Play("IG_MAINMENU_OPEN") Board:Refresh() end)
    f:SetScript("OnHide", function()
        Art:StopSounds()   -- nothing the table started outlives it
        P.finishEffects()
        Board:Cancel(true)
        GameTooltip:Hide()
    end)
end

-- Shared with the other board files.
P.build = build
