-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Board controller: the only part of the board that talks to the engine and TC.Match. It reads the
-- state into the widgets, narrows legal moves as you click, and plays the match's feedback.

local TC = TavernCards_NS
local Board = TC.Board
local P, S = Board._P, Board._S
local D = TC.EngineDefs
local Art = TC.Art
local Match = TC.Match
local CardWidget = TC.CardWidget
local ZONE = D.ZONE
local PHASE = D.PHASE
local KW = D.KW
local band = bit.band
local H, HAND_SCALE, KEYWORD_LABELS, ME, OPP, POWER_ICONS, SLOT_GAP, SLOT_W, W, engine, sideOf, widgets = P.H, P.HAND_SCALE, P.KEYWORD_LABELS, P.ME, P.OPP, P.POWER_ICONS, P.SLOT_GAP, P.SLOT_W, P.W, P.engine, P.sideOf, P.widgets

-- ---- tooltips ----------------------------------------------------------------------------------

local function entityTooltip(owner, id)
    local eng = engine()
    local e = eng and eng:ent(id)
    if not e then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if e.zone == ZONE.HERO then
        local p = eng:player(e.owner)
        local record = Match:Record()
        local name = e.owner == ME() and (UnitName("player") or "You")
            or (record and record.opponent and record.opponent.name) or "Opponent"
        GameTooltip:SetText(name, 1, 0.82, 0)
        GameTooltip:AddLine(("Health %d / %d"):format(e.health, e.max_health), 1, 1, 1)
        if e.armor > 0 then
            GameTooltip:AddLine(("Armor %d"):format(e.armor), 0.8, 0.8, 0.8)
            GameTooltip:AddLine("  Armor soaks up damage before Health.", 0.6, 0.6, 0.6, true)
        end
        if e.attack > 0 then
            GameTooltip:AddLine(("Attack %d"):format(e.attack), 1, 1, 1)
            local w = eng:ent(p.weapon_id)
            local wcard = w and w.zone == ZONE.WEAPON and TC.Cards[w.card_id]
            GameTooltip:AddLine(wcard and ("  From your weapon, %s (%d uses left)."):format(wcard.name, w.durability)
                or "  A temporary boost: the hero can attack this turn; it wears off when the turn ends.", 0.6, 0.6, 0.6, true)
            if e.owner == ME() then
                GameTooltip:AddLine("  Click your hero, then an enemy, to attack.", 0.5, 0.75, 1, true)
            end
        end
        GameTooltip:AddLine(("Deck %d  ·  Hand %d"):format(#eng:deck_ids(e.owner), #eng:hand_ids(e.owner)), 0.7, 0.7, 0.7)
        for _, q in ipairs(Match.QuestInfo(eng, e.owner)) do
            GameTooltip:AddLine(("Quest: %s  %d / %d"):format(q.name, math.min(q.progress, q.goal), q.goal), 1, 0.82, 0.3)
            if q.stages > 1 then
                GameTooltip:AddLine(("  Stage %d of %d"):format(q.stage, q.stages), 0.7, 0.7, 0.7)
            end
            GameTooltip:AddLine("  " .. Art:RulesText(q.card), 0.85, 0.85, 0.85, true)
        end
        if #p.secrets > 0 then
            GameTooltip:AddLine(("%d secret(s) in play"):format(#p.secrets), 0.8, 0.4, 1)
            if e.owner == ME() then
                for _, sid in ipairs(p.secrets) do
                    local se = eng:ent(sid)
                    local card = se and TC.Cards[se.card_id]
                    if card then GameTooltip:AddLine("  " .. card.name, 0.85, 0.6, 1) end
                end
            end
        end
    else
        TC:CardTooltip(e.card_id, true)
        local card = TC.Cards[e.card_id]
        if e.zone == ZONE.BOARD and card and card.type ~= "LOCATION" then
            GameTooltip:AddLine(" ")
            local atk = e.attack > card.attack and ("|cff40ff40%d Attack|r"):format(e.attack) or ("%d Attack"):format(e.attack)
            local hp = e.health < e.max_health and ("|cffff5050%d|r of %d Health"):format(e.health, e.max_health)
                or (e.max_health > card.health and ("|cff40ff40%d Health|r"):format(e.health) or ("%d Health"):format(e.health))
            GameTooltip:AddLine("On the board: " .. atk .. ", " .. hp, 1, 1, 1)
            if e.flags.exhausted and e.owner == ME() and not e.flags.frozen then
                GameTooltip:AddLine("Can't attack until your next turn.", 0.6, 0.6, 0.6)
            end
        elseif e.zone == ZONE.BOARD then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("%d uses left%s"):format(e.durability, e.flags.has_attacked and ", used this turn" or ""), 1, 1, 1)
        elseif e.zone == ZONE.WEAPON then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(("Equipped: %d Attack, %d uses left"):format(e.attack, e.durability), 1, 1, 1)
        end
    end
    local words = {}
    for _, kw in ipairs(KEYWORD_LABELS) do
        if band(e.keywords, kw[1]) ~= 0 and not (kw[1] == KW.DIVINE_SHIELD or kw[1] == KW.STEALTH) then
            words[#words + 1] = kw[2]
        end
    end
    if e.flags.divine_shield then words[#words + 1] = "Divine Shield" end
    if e.flags.stealth then words[#words + 1] = "Stealth" end
    if e.flags.immune then words[#words + 1] = "Immune" end
    if e.flags.frozen then words[#words + 1] = "|cff66ccffFrozen|r" end
    if e.flags.silenced then words[#words + 1] = "|cff999999Silenced|r" end
    if e.flags.dormant_turns > 0 then words[#words + 1] = ("Dormant (%d)"):format(e.flags.dormant_turns) end
    if #words > 0 then
        GameTooltip:AddLine(table.concat(words, ", "), 0.5, 1, 0.5, true)
    end
    GameTooltip:Show()
end

-- ---- the choice dialog (discover, adapt, dredge, choose one, mulligan) -------------------------

local function buildChoice()
    local c = CreateFrame("Frame", nil, S.frame, "BackdropTemplate")
    c:SetFrameLevel(S.frame:GetFrameLevel() + 40)
    c:SetPoint("CENTER", 0, 10)
    c:SetSize(620, 260)
    c:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", tile = true, tileSize = 32, edgeSize = 24,
        insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    c:EnableMouse(true)
    c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.title:SetPoint("TOP", 0, -16)
    c.cards = {}
    for i = 1, 10 do
        local w = CardWidget:CreateGame(c)
        -- Above everything on the card (a 3D portrait included), so the replace mark always shows.
        w.markFrame = CreateFrame("Frame", nil, w)
        w.markFrame:SetAllPoints()
        w.markFrame:SetFrameLevel(w:GetFrameLevel() + 6)
        w.mark = w.markFrame:CreateTexture(nil, "OVERLAY", nil, 7)
        w.mark:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        w.mark:SetSize(40, 40)
        w.mark:SetPoint("CENTER", 0, 10)
        w.mark:Hide()
        c.cards[i] = w
    end
    c.buttons = {}
    for i = 1, 9 do
        local b = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
        b:SetSize(170, 28)
        c.buttons[i] = b
    end
    c.confirm = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.confirm:SetSize(140, 26)
    c.confirm:SetPoint("BOTTOM", 0, 16)
    c:Hide()
    return c
end

-- options: { {card = id} or {label = text}, ... }; pick(i) is called with the option index.
function Board:ShowChoice(title, options, pick, multi, confirmText, onConfirm)
    local c = S.frame.choice
    c.title:SetText(title)
    -- A title over more lines makes room for itself (the cards move down).
    local extra = select(2, title:gsub("\n", "")) * 20
    for _, w in ipairs(c.cards) do w:Hide() w.mark:Hide() end
    for _, b in ipairs(c.buttons) do b:Hide() end
    c.confirm:Hide()
    local cardsShown = options[1] and options[1].card
    local n = #options
    if cardsShown then
        local step = 112
        local perRow = n > 5 and math.ceil(n / 2) or n
        local rows = math.ceil(n / perRow)
        for i, opt in ipairs(options) do
            local w = c.cards[i]
            if w then
                local row, col = math.floor((i - 1) / perRow), (i - 1) % perRow
                local inRow = math.min(perRow, n - row * perRow)
                w:ClearAllPoints()
                w:SetPoint("CENTER", c, "CENTER", -(inRow - 1) * step / 2 + col * step, (rows - 1) * 75 - row * 150 - extra / 2)
                w.costNow = nil
                w:SetCard(opt.card)
                w.onClick = function(_, button)
                    if button == "LeftButton" then pick(i, w) end
                end
            end
        end
        c:SetSize(math.max(360, perRow * step + 40), 250 + (rows - 1) * 150 + extra)
    else
        for i, opt in ipairs(options) do
            local b = c.buttons[i]
            if b then
                b:ClearAllPoints()
                local col, row = (i - 1) % 3, math.floor((i - 1) / 3)
                local cols = math.min(n, 3)
                b:SetPoint("TOP", c, "TOP", (col - (cols - 1) / 2) * 180, -56 - row * 36)
                b:SetText(opt.label)
                b:SetScript("OnClick", function() pick(i, b) end)
                b:Show()
            end
        end
        c:SetSize(math.max(360, math.min(n, 3) * 180 + 40), 90 + math.ceil(n / 3) * 36 + 20)
    end
    if onConfirm then
        c.confirm:SetText(confirmText or OKAY or "Okay")
        c.confirm:SetScript("OnClick", onConfirm)
        c.confirm:Show()
        c:SetHeight(c:GetHeight() + 30)
    end
    c:Show()
end

function Board:HideChoice()
    if S.frame and S.frame.choice then S.frame.choice:Hide() end
end

local function myDecisionNow()
    local eng = engine()
    return eng and not eng:is_terminal() and eng:current_player() == ME() and not Match.thinking
end

-- ---- reading the state -------------------------------------------------------------------------

local function myDecision()
    local eng = engine()
    return eng and not eng:is_terminal() and eng:current_player() == ME() and not Match.thinking
end

local function movesWhere(test)
    local out = {}
    for i, m in ipairs(S.moves) do
        if test(m) then out[#out + 1] = { index = i, move = m } end
    end
    return out
end

-- The two sides' card backs (kept with the match): yours from your deck, the house's at random.
local function backOf(seat)
    local record = Match:Record()
    local backs = record and record.backs
    return backs and backs[seat + 1] or TC.CardBacks.DEFAULT
end

local function layoutRow(side)
    local eng = engine()
    local ids = eng:board_ids(side == 0 and ME() or OPP())
    local row = S.frame.rows[side]
    local n = #ids
    local total = n * SLOT_W + math.max(0, n - 1) * SLOT_GAP
    local y = side == 1 and -186 or -310
    for i = 1, 7 do
        local b = row[i]
        local id = ids[i]
        if id then
            local x = -total / 2 + (i - 1) * (SLOT_W + SLOT_GAP)
            local from = b.entity ~= id and P.lastBoard[id] or nil
            if b.entity ~= id and not from then b.gx = nil end   -- a newcomer appears in place
            P.glideTo(b, P.placeBoard, x, y, from)
            P.lastBoard[id] = { x, y }
            local e = eng:ent(id)
            -- Asleep: played this turn and can't attack yet (no Charge or Rush).
            b.sleeping = e.owner == eng.state.active and e.flags.exhausted and e.flags.attacks_this_turn == 0
                and e.flags.just_played_turn == eng.state.turn
            P.setMinion(b, e, eng:def_of(id))
            widgets[id] = b
        else
            b.entity = nil
            b:Hide()
        end
    end
    return ids, total, y
end

local function refreshHero(side)
    local seat = side == 0 and ME() or OPP()
    local eng = engine()
    local s = eng.state
    local p = eng:player(seat)
    local hero = eng:hero_of(seat)
    local b = S.frame.heroes[side]
    local record = Match:Record()
    local classes = record and record.classes or Match.lastClasses or {}
    local unit
    if seat == ME() then
        unit = "player"
    elseif record and record.kind == "duel" and record.opponent then
        unit = P.unitForName(record.opponent.name)
    end
    P.setHeroPortrait(b, classes[seat + 1], unit, seat ~= ME() and Match:HouseModel())
    if hero then
        b.entity = hero.id
        widgets[hero.id] = b
        b.health.text:SetText(hero.health)
        local hurt = hero.health < hero.max_health
        b.health.text:SetTextColor(1, hurt and 0.4 or 1, hurt and 0.4 or 1)
        b.armor:SetShown(hero.armor > 0)
        b.armor.text:SetText(hero.armor)
        b.attack:SetShown(hero.attack > 0)
        b.attack.text:SetText(hero.attack)
        b.frozen:SetShown(hero.flags.frozen)
    end
    b.secrets:SetText(#p.secrets > 0 and string.rep("?", #p.secrets) or "")
    local name = seat == ME() and (UnitName("player") or "You")
        or (record and record.opponent and Ambiguate and Ambiguate(record.opponent.name, "short") or record and record.opponent and record.opponent.name) or "Opponent"
    b.name:SetText(name .. "  |cffaaaaaa" .. P.className(classes[seat + 1] or "") .. "|r")
    b.deck:SetText(("Deck %d   Fatigue %d"):format(#eng:deck_ids(seat), p.fatigue))
    local quests = Match.QuestInfo(eng, seat)
    b.quest:SetText(#quests > 0 and ("Quest: %s %d/%d"):format(quests[1].name, math.min(quests[1].progress, quests[1].goal),
        quests[1].goal) or "")
    local pile = S.frame.piles[side]
    local left = #eng:deck_ids(seat)
    if pile.backId ~= backOf(seat) then pile:SetBack(backOf(seat)) end
    pile.count:SetText(left)
    pile:SetAlpha(left > 0 and 1 or 0.35)

    local power = S.frame.powers[side]
    power.power = p.hero_power_id
    power.info = Match.PowerInfo(eng, seat)
    power.costNow = eng:hero_power_cost(seat)
    power.cost.text:SetText(power.costNow)
    power.icon:SetTexture(power.info.card and Art:Icon(power.info.card)
        or Art:SafeIcon(POWER_ICONS[p.hero_power_id] or "INV_Misc_QuestionMark"))
    local used = hero and (hero.flags.hero_power_used or p.hero_power_uses >= 1) and s.active == seat
    power.icon:SetDesaturated(used and true or false)
    power:SetShown(p.hero_power_id ~= 0)

    local wpn = S.frame.weapons[side]
    local w = p.weapon_id ~= 0 and eng:ent(p.weapon_id)
    if w and w.zone == ZONE.WEAPON then
        wpn.entity = w.id
        widgets[w.id] = wpn
        wpn.icon:SetTexture(Art:Icon(w.card_id))
        wpn.attack.text:SetText(w.attack)
        wpn.durability.text:SetText(w.durability)
        wpn:Show()
    else
        wpn.entity = nil
        wpn:Hide()
    end
    P.setMana(S.frame.mana[side], p)
end

local HAND_ARC, HAND_LIFT, HAND_TOP = 14, 40, 60   -- arc height, hover lift, hovered card's frame level

local function refreshHand()
    local eng = engine()
    local ids = eng:hand_ids(ME())
    local n = #ids
    local cw = CardWidget.WIDTH
    local avail = 760 / HAND_SCALE
    local step = n > 1 and math.min(cw + 6, (avail - cw) / (n - 1)) or 0
    local total = (n - 1) * step + cw
    for i = 1, 10 do
        local w = S.frame.hand.cards[i]
        local id = ids[i]
        if id then
            local e = eng:ent(id)
            local x = -total / 2 + (i - 1) * step
            -- The hand lies on an arc: the middle cards sit higher. (Frames can't be rotated in WoW, so the
            -- fan is the arc alone.)
            local t = n > 1 and ((i - 1) / (n - 1)) * 2 - 1 or 0
            local arc = HAND_ARC * (1 - t * t)
            local from
            if w.entity ~= id then
                -- Another card moved into this slot: start where that card was, or (a new card) below.
                from = P.lastHand[id] or { x + 40, -CardWidget.HEIGHT }
            end
            w.entity = id
            w.costNow = eng:card_cost(ME(), id)
            w.baseX, w.baseY = x, arc
            -- A card uses five frame levels (portrait, model, frame, gems, markers): space them so a card's
            -- gems never draw over the next card.
            w.baseLevel = S.frame.hand:GetFrameLevel() + i * 5
            P.glideTo(w, P.placeHand, x, w.hovered and HAND_LIFT or arc, from)
            P.lastHand[id] = { x, arc }
            w:SetFrameLevel(w.hovered and (S.frame.hand:GetFrameLevel() + HAND_TOP) or w.baseLevel)
            w:SetCard(e.card_id)
            widgets[id] = w
        else
            w.entity = nil
            w:Hide()
        end
    end
    local backs = S.frame.oppHand.backs
    local m = #eng:hand_ids(OPP())
    local oppBack = backOf(OPP())
    for i = 1, 10 do
        local back = backs[i]
        if back.backId ~= oppBack then back:SetBack(oppBack) end
        if i <= m then
            local t = m > 1 and ((i - 1) / (m - 1)) * 2 - 1 or 0
            back:ClearAllPoints()
            back:SetPoint("TOPLEFT", S.frame.oppHand, "TOP", -(m * 30) / 2 + (i - 1) * 30, -6 * (1 - t * t) + 6)
            back:SetFrameLevel(S.frame.oppHand:GetFrameLevel() + i * 3)
            back:Show()
        else
            back:Hide()
        end
    end
end

-- Glows: what you can do now, or (mid-move) what the move can still become.
local function refreshGlows()
    for _, w in pairs(widgets) do P.setGlow(w) end
    P.setGlow(S.frame.powers[0])
    for _, g in ipairs(S.frame.gaps) do g:Hide() end
    if not myDecision() then return end
    local eng = engine()
    if S.sel then
        if S.sel.source and widgets[S.sel.source] then P.setGlow(widgets[S.sel.source], "gold") end
        if S.sel.step == "target" or S.sel.step == "position" then
            for _, x in ipairs(S.sel.list) do
                local t = x.move.raw.target
                if t and t ~= 0 and widgets[t] and (S.sel.step == "target" or x.move.raw.position == -1) then
                    P.setGlow(widgets[t], "red")
                end
            end
        end
        if S.sel.step == "position" then
            local ids = eng:board_ids(ME())
            local n = #ids
            local total = n * SLOT_W + math.max(0, n - 1) * SLOT_GAP
            local seen = {}
            for _, x in ipairs(S.sel.list) do
                local pos = x.move.raw.position
                if pos and pos >= 0 and not seen[pos] then
                    seen[pos] = true
                    local g = S.frame.gaps[pos + 1]
                    g.position = pos
                    g:ClearAllPoints()
                    g:SetPoint("TOP", S.frame, "TOP", -total / 2 + pos * (SLOT_W + SLOT_GAP) - SLOT_GAP / 2, -310)
                    g:Show()
                end
            end
        end
        return
    end
    local canAct = {}
    for _, m in ipairs(S.moves) do
        if m.raw.entity and m.raw.entity ~= 0 and m.action ~= "mulligan" then canAct[m.raw.entity] = true end
        if m.action == "hero_power" then P.setGlow(S.frame.powers[0], "green") end
    end
    for id in pairs(canAct) do
        if widgets[id] then P.setGlow(widgets[id], "green") end
    end
    local onlyEnd = true
    for _, m in ipairs(S.moves) do
        if m.action ~= "end_turn" and m.action ~= "concede" then onlyEnd = false break end
    end
    P.setGlow(S.frame.endTurn, onlyEnd and "gold" or nil)
end

function Board:Refresh()
    if not S.frame or not S.frame:IsShown() then return end
    local eng = engine()
    wipe(widgets)
    if not eng then
        S.frame:Hide()
        return
    end
    local s = eng.state
    local record = Match:Record()
    local opp = record and record.opponent
    local oppName = opp and opp.name or Match.lastOpponent or "Practice"
    if Ambiguate then oppName = Ambiguate(oppName, "short") end
    S.frame.title:SetText(((record and record.kind == "duel") and "Duel with %s" or "Tavern Table — %s"):format(oppName))
    layoutRow(1)
    layoutRow(0)
    refreshHero(0)
    refreshHero(1)
    refreshHand()

    S.moves = myDecision() and eng:legal_moves() or {}
    if S.sel and #S.moves == 0 then S.sel = nil end
    local mine = myDecision()
    if eng:is_terminal() then
        S.frame.endTurn:SetText("Game Over")
        S.frame.endTurn:Disable()
        S.frame.status:SetText("")
    elseif mine and s.phase == PHASE.PLAYER_ACTIONS and not s.pending.active then
        S.frame.endTurn:SetText("End Turn")
        S.frame.endTurn:Enable()
        S.frame.status:SetText(("|cff40ff40Your turn|r  (turn %d)"):format(math.floor((s.turn + 1) / 2)))
    else
        S.frame.endTurn:SetText(eng:current_player() == OPP() and "Enemy Turn" or "Your Turn")
        S.frame.endTurn:Disable()
        if not Match.thinking then
            S.frame.status:SetText(eng:current_player() == OPP()
                and (Match:IsDuel() and "|cffff6040Waiting for your opponent...|r" or "|cffff6040Enemy turn|r") or "")
        end
    end
    local launch
    for i, m in ipairs(S.moves) do
        if m.action == "launch" then launch = i end
    end
    S.frame.launch.index = launch
    S.frame.launch:SetShown(launch ~= nil and not S.sel)
    S.frame.concede:SetEnabled(not eng:is_terminal())
    S.frame.hint:SetText(S.sel and S.sel.hint or "")
    refreshGlows()

    -- Decisions that need a dialog: the opening hand, then any pending choice.
    if mine and s.phase == PHASE.MULLIGAN then
        self:ShowMulligan()
    elseif mine and s.pending.active and s.pending.seat == ME() then
        self:ShowPending()
    elseif S.sel and S.sel.step == "choice" then
        -- stays open
    else
        self:HideChoice()
    end
    if eng:is_terminal() and Match.result then
        self:ShowGameOver()
    else
        S.frame.over:Hide()
    end
end

-- ---- decisions ---------------------------------------------------------------------------------

-- Cards marked to replace survive refreshes (they are keyed by the match, so a new match starts clean).
local mulliganMarks = { match = nil, replace = {} }

function Board:ShowMulligan()
    local eng = engine()
    local ids = eng:mulligan_ids(ME())
    local record = Match:Record()
    local key = record and record.started
    if mulliganMarks.match ~= key then
        mulliganMarks.match, mulliganMarks.replace = key, {}
    end
    local replace = mulliganMarks.replace
    local options = {}
    for i, id in ipairs(ids) do options[i] = { card = eng:ent(id).card_id } end
    self:ShowChoice("Your opening hand\nClick the cards you want to replace", options, function(i, w)
        replace[i] = not replace[i]
        w.mark:SetShown(replace[i])
    end, true, "Keep", function()
        local want = {}
        for i = 1, #ids do
            if replace[i] then want[#want + 1] = i - 1 end
        end
        for index, m in ipairs(S.moves) do
            if m.action == "mulligan" then
                local got = m.raw.replace
                local same = #got == #want
                for k = 1, #want do
                    if got[k] ~= want[k] then same = false end
                end
                if same then
                    self:HideChoice()
                    mulliganMarks.replace = {}
                    Match:PlayerApply(index)
                    return
                end
            end
        end
    end)
    for i in ipairs(ids) do
        S.frame.choice.cards[i].mark:SetShown(replace[i] and true or false)
    end
end

function Board:ShowPending()
    local eng = engine()
    local pending = eng.state.pending
    local options = {}
    local title = "Choose one"
    if #pending.card_options > 0 then
        for i, id in ipairs(pending.card_options) do options[i] = { card = id } end
        title = pending.kind == "hand_action" and "Choose a card from your hand" or "Discover a card"
    elseif pending.kind == "adapt" then
        for i, which in ipairs(pending.options) do options[i] = { label = TC.Engine.ADAPT_LABELS[which] or tostring(which) } end
        title = "Adapt"
    elseif pending.kind == "dredge" then
        for i, id in ipairs(pending.options) do
            local e = eng:ent(id)
            options[i] = { card = e and e.card_id }
        end
        title = "Dredge: put one on top of your deck"
    else
        for i in ipairs(pending.options) do options[i] = { label = "Option " .. i } end
    end
    self:ShowChoice(title, options, function(i)
        for index, m in ipairs(S.moves) do
            if m.action == "resolve" and m.raw.choice == i - 1 then
                self:HideChoice()
                Match:PlayerApply(index)
                return
            end
        end
    end)
end

function Board:Cancel(silent)
    if not S.sel then return end
    S.sel = nil
    if S.frame then
        self:HideChoice()
        if not silent then self:Refresh() end
    end
end

local function apply(index)
    S.sel = nil
    Board:HideChoice()
    Match:PlayerApply(index)
end

-- Narrows the half-made move one step: option, then board slot, then target.
function Board:Advance()
    local list = S.sel.list
    if #list == 0 then
        return self:Cancel()
    end
    local choices, nChoices = {}, 0
    for _, x in ipairs(list) do
        local c = x.move.raw.choice or 0
        if (x.move.action == "play" or x.move.action == "activate") and not choices[c] then
            choices[c] = x.move.desc:match("%[(.-)%]") or x.move.desc:match(": (.-) on ") or x.move.desc:match(": (.+)$")
                or ("Option " .. (c + 1))
            nChoices = nChoices + 1
        end
    end
    if nChoices > 1 then
        S.sel.step = "choice"
        local options, keys = {}, {}
        for c, label in pairs(choices) do keys[#keys + 1] = c end
        table.sort(keys)
        for i, c in ipairs(keys) do options[i] = { label = choices[c] } end
        self:ShowChoice("Choose one", options, function(i)
            local keep = {}
            for _, x in ipairs(list) do
                if (x.move.raw.choice or 0) == keys[i] then keep[#keep + 1] = x end
            end
            self:HideChoice()
            S.sel.list = keep
            self:Advance()
        end)
        self:Refresh()
        return
    end
    local positions, nPos, hosts = {}, 0, false
    for _, x in ipairs(list) do
        local p = x.move.raw.position
        if x.move.action == "play" and p and p >= 0 and not positions[p] then
            positions[p] = true
            nPos = nPos + 1
        elseif x.move.action == "play" and p == -1 and (x.move.raw.target or 0) ~= 0 then
            hosts = true
        end
    end
    if (nPos > 1 or (nPos >= 1 and hosts)) and not S.sel.placed then
        S.sel.step = "position"
        S.sel.hint = hosts and "Choose where to place it, or a Mech to magnetize to" or "Choose where to place it"
        self:Refresh()
        return
    end
    local targets = {}
    local anyTarget = false
    for _, x in ipairs(list) do
        local t = x.move.raw.target or 0
        if t ~= 0 then
            targets[t] = true
            anyTarget = true
        end
    end
    if anyTarget and not S.sel.targeted then
        S.sel.step = "target"
        S.sel.hint = list[1].move.action == "attack" and "Choose a target to attack" or "Choose a target"
        self:Refresh()
        return
    end
    apply(list[1].index)
end

function Board:Begin(list, source, power)
    S.sel = { list = list, source = source, power = power }
    Art:Play("IG_ABILITY_ICON_DROP")
    self:Advance()
end

local HAND_ACTIONS = { play = true, trade = true, forge = true, prepare = true }
local ACTION_LABEL = { play = "Play", trade = "Trade (1 mana, draw a card)", forge = "Forge (2 mana)",
    prepare = "Prepare (1 mana)" }

function Board:ClickHand(id, widget)
    if not myDecision() then return end
    if S.sel then
        if S.sel.step == "target" then return self:ClickEntity(id) end
        self:Cancel(true)
    end
    local byAction, kinds = {}, {}
    for _, x in ipairs(movesWhere(function(m) return HAND_ACTIONS[m.action] and m.raw.entity == id end)) do
        if not byAction[x.move.action] then
            byAction[x.move.action] = {}
            kinds[#kinds + 1] = x.move.action
        end
        table.insert(byAction[x.move.action], x)
    end
    if #kinds == 0 then
        local eng = engine()
        local cost = eng:card_cost(ME(), id)
        UIErrorsFrame:AddMessage(cost > eng:player(ME()).mana and "Not enough mana." or "You can't play that now.", 1, 0.1, 0.1)
        return
    end
    if #kinds == 1 and kinds[1] == "play" then
        return self:Begin(byAction.play, id)
    end
    if MenuUtil and MenuUtil.CreateContextMenu then
        MenuUtil.CreateContextMenu(widget, function(_, root)
            for _, kind in ipairs(kinds) do
                root:CreateButton(ACTION_LABEL[kind] or kind, function() self:Begin(byAction[kind], id) end)
            end
        end)
    else
        self:Begin(byAction[kinds[1]], id)
    end
end

function Board:ClickEntity(id)
    if not myDecision() then return end
    if S.sel and (S.sel.step == "target" or S.sel.step == "position") then
        local keep = {}
        for _, x in ipairs(S.sel.list) do
            if x.move.raw.target == id and (S.sel.step == "target" or x.move.raw.position == -1) then
                keep[#keep + 1] = x
            end
        end
        if #keep > 0 then
            S.sel.list = keep
            S.sel.placed, S.sel.targeted = true, true
            return self:Advance()
        end
        if S.sel.step == "target" then
            UIErrorsFrame:AddMessage("Invalid target.", 1, 0.1, 0.1)
            return
        end
    end
    if S.sel then self:Cancel(true) end
    local list = movesWhere(function(m)
        return (m.action == "attack" or m.action == "activate") and m.raw.entity == id
    end)
    if #list > 0 then
        return self:Begin(list, id)
    end
    local e = engine():ent(id)
    if e and e.owner == ME() and e.zone == ZONE.BOARD then
        local why = e.flags.frozen and "That minion is frozen." or e.flags.exhausted and "That minion can't attack yet."
            or "That minion can't attack."
        UIErrorsFrame:AddMessage(why, 1, 0.1, 0.1)
    end
    self:Refresh()
end

function Board:ClickGap(position)
    if not S.sel then return end
    local keep = {}
    for _, x in ipairs(S.sel.list) do
        if x.move.raw.position == position then keep[#keep + 1] = x end
    end
    S.sel.list = keep
    S.sel.placed = true
    self:Advance()
end

function Board:ClickPower()
    if not myDecision() then return end
    if S.sel then self:Cancel(true) end
    local list = movesWhere(function(m) return m.action == "hero_power" end)
    if #list == 0 then
        UIErrorsFrame:AddMessage("You can't use your hero power now.", 1, 0.1, 0.1)
        return
    end
    self:Begin(list, nil, true)
end

function Board:ClickEndTurn()
    if not myDecision() then return end
    S.sel = nil
    for index, m in ipairs(S.moves) do
        if m.action == "end_turn" then
            Art:Sfx("select")
            Match:PlayerApply(index)
            return
        end
    end
end

-- ---- buttons that act on the match (wired in Layout) ----------------------------------------------

function Board:Concede()
    TC:Confirm("Concede this match?", function() Match:Concede() end)
end

-- The special "launch" move (a Starship): index is the legal move to play.
function Board:Launch(index)
    if index and P.myDecisionNow() then Match:PlayerApply(index) end
end

-- Every frame: the status line while the opponent thinks, and a duel opponent gone quiet.
function Board:StatusTick()
    local f = S.frame
    if Match.thinking then
        f.status:SetText("Opponent is thinking" .. string.rep(".", math.floor(GetTime() * 2) % 4))
    elseif TC.Duel and Match:IsDuel() then
        local quiet = TC.Duel:Silence()
        if quiet > TC.Duel.SILENT_WARN then
            local left = math.ceil(TC.Duel.SILENT_CLAIM - quiet)
            f.status:SetText(left > 0 and ("|cffff6040No word from your opponent.|r\nYou can claim the win in %ds."):format(left)
                or "|cffff6040Your opponent seems to have left.|r")
        end
        f.claim:SetShown(quiet >= TC.Duel.SILENT_CLAIM)
    else
        f.claim:Hide()
    end
end

-- ---- match feedback ----------------------------------------------------------------------------

function Board:ShowGameOver()
    local over = S.frame.over
    local result = Match.result
    if result == "win" then
        over.text:SetText("|cffffd100Victory!|r")
    elseif result == "loss" then
        over.text:SetText("|cffcc3333Defeat|r")
    else
        over.text:SetText("Draw")
    end
    local reasons = { life = "", fatigue = "Out of cards.", concede = "Conceded.", turn_limit = "Turn limit reached.",
        loop = "The rules got stuck in a loop.", errored = "The match ended in an error." }
    over.reason:SetText(reasons[Match.reason or ""] or "")
    local reward = Match.reward
    local parts = {}
    if reward and reward.dust then
        parts[#parts + 1] = ("|TInterface\\Icons\\INV_Enchant_DustArcane:14:14|t +%d dust"):format(reward.dust)
    end
    if reward and reward.card then parts[#parts + 1] = "and " .. Art:ColoredName(reward.card) end
    if reward and not reward.dust and not reward.card then parts[#parts + 1] = "|cffaaaaaaToday's winnings are already collected.|r" end
    over.reward:SetText(table.concat(parts, "  "))
    over:Show()
end

function Board:Rematch()
    S.frame.over:Hide()
    local last = TC.char.lastMatch
    if last and last.opponent and last.opponent.duel and TC.Duel then
        -- A duel rematch is a new challenge to the same player.
        S.frame:Hide()
        TC.Duel:Challenge(last.opponent.name)
        return
    end
    local setup = Match.lastSetup or (last and last.setup)
    if not setup or not TC:StartPractice(setup) then
        S.frame:Hide()
        TC:ShowWindow("play")
    end
end

local function showBanner(text)
    S.frame.banner:SetText(text)
    S.frame.banner:SetAlpha(1)
    S.frame.banner:Show()
end

local function onMatch(what, seat, move)
    if what == "log" then
        if S.frame then S.frame.log:AddMessage(seat, move) end   -- (what, line, info) for "log"
        return
    end
    if not S.frame then return end
    if what == "load" then
        S.sel = nil
        P.finishEffects()
        local rec = Match:Record()
        -- Matches from before the painted table kept their painting as the mat: it is the table now.
        if rec and type(rec.mat) == "number" then rec.mat = nil end   -- map art Forever lacks
    if rec and type(rec.mat) == "string" and rec.mat:find("^paint:") then
            rec.table, rec.mat = rec.mat:sub(7), nil
        end
        if rec and not rec.mat then rec.mat = Board.PickMat() end
        if rec and rec.table == nil then rec.table = Board.PickTable() end
        Board:SetMat(rec and rec.mat)
        Board:SetTable(rec and rec.table)
        wipe(P.lastHand)
        wipe(P.lastBoard)
        S.frame.log:Clear()
        local record = Match:Record()
        for _, line in ipairs(record and record.log or {}) do S.frame.log:AddMessage(line) end
        S.frame.over:Hide()
        Board:Refresh()
        return
    end
    if what == "move" and S.frame:IsShown() then
        local eng = engine()
        local before = P.positions()
        S.sel = nil
        Board:Refresh()
        local after = P.positions()
        local turnStarted
        -- The played card flies from the hand (yours, or the opponent's card backs) to where it lands.
        local flownTo
        if move and move.action == "play" and move.raw.entity then
            local e = eng:ent(move.raw.entity)
            local d = e and eng:def_of(e.id)
            if e and not (seat == OPP() and d and d.secret) then
                local from = before[e.id]
                if seat == OPP() then
                    local ox, oy = P.frameXY(S.frame.oppHand)
                    from = ox and { ox, oy }
                end
                local to = after[e.id] or { W / 2, H / 2 + 20 }
                if from then
                    P.flyCard(e.card_id, from, to)
                    flownTo = e.id
                    Art:Sfx("play")
                end
            end
        end
        for _, ev in ipairs(eng.events or {}) do
            local at = after[ev.subject] or before[ev.subject]
            if ev.kind == "ATTACK_DECLARED" then
                local a, b = before[ev.subject] or after[ev.subject], before[ev.source] or after[ev.source]
                local e = eng:ent(ev.subject)
                if a and b and e then
                    local tex
                    if e.zone == ZONE.HERO then
                        local w = eng:ent(eng:player(e.owner).weapon_id)
                        tex = w and Art:Icon(w.card_id) or Art:SafeIcon("INV_Sword_04")
                    else
                        tex = Art:Icon(e.card_id)
                    end
                    P.lunge(a, b, tex)
                    if not (e.zone ~= ZONE.HERO and Art:PlayKit(P.creatureSound(e, 2))) then Art:Sfx("attack") end
                    local aw = widgets[ev.subject]
                    if aw and aw.model then TC.Models:Animate(aw.model, "attack") end
                end
            elseif ev.kind == "DAMAGED" and at then
                P.floatText(at[1], at[2], "-" .. ev.amount, 1, 0.2, 0.15)
                P.flash(widgets[ev.subject], 1, 0.15, 0.1)
                local hit = widgets[ev.subject]
                if hit and hit.model then TC.Models:Animate(hit.model, "hit") end
                local hurt = eng:ent(ev.subject)
                local woundKit = hurt and hurt.zone ~= ZONE.HERO and P.creatureSound(hurt, 3)
                if hit and hit.place then
                    -- A short shake on the minion that took the hit.
                    hit.shake = 0.3
                    P.gliders[hit] = true
                end
                if not Art:PlayKit(woundKit) then Art:Sfx("hit") end
            elseif ev.kind == "SUMMONED" and widgets[ev.subject] then
                Art:PlayKit(P.creatureSound(eng:ent(ev.subject), 1))
                P.fadeIn(widgets[ev.subject], flownTo == ev.subject and P.FLY * 0.8 or 0)
                -- A legendary arrives with a roar.
                local w, e = widgets[ev.subject], eng:ent(ev.subject)
                local card = e and TC.Cards[e.card_id]
                if w.model and card and card.rarity == "LEGENDARY" then
                    C_Timer.After(0.5, function() TC.Models:Animate(w.model, "roar") end)
                end
            elseif ev.kind == "PLAYED" then
                -- A spell: its cast sound, then its impact (the WoW spell it's named after, else its school's).
                local e = eng:ent(ev.subject)
                local snd = e and TC.CardSpellSounds and TC.CardSpellSounds[e.card_id]
                if snd then
                    Art:PlayKit(snd[1])
                    C_Timer.After(0.45, function() Art:PlayKit(snd[2]) end)
                end
            elseif ev.kind == "HERO_POWER_USED" then
                P.flash(S.frame.powers[sideOf(ev.seat)], 1, 0.85, 0.3, 0.6)
                TC.Models:Animate(S.frame.heroes[sideOf(ev.seat)].model, "cast")
                Art:Sfx("power")
            elseif ev.kind == "DAMAGE_PREVENTED" and at then
                P.floatText(at[1], at[2], "Blocked", 1, 0.9, 0.4)
                local w = widgets[ev.subject]
                if w and w.model then TC.Models:Animate(w.model, "block") end
            elseif ev.kind == "DIED" and at then
                P.floatText(at[1], at[2] - 24, "Died", 0.7, 0.7, 0.7)
                local dead = eng:ent(ev.subject)
                Art:PlayKit(P.creatureSound(dead, 4))
                if dead and not after[ev.subject] then
                    P.lunge(at, at, Art:Icon(dead.card_id), "die")
                    Art:Sfx("death")
                end
            elseif ev.kind == "TURN_STARTED" then
                turnStarted = ev.seat
            end
        end
        if seat == OPP() and move and move.action == "play" and move.raw.entity then
            local e = eng:ent(move.raw.entity)
            local d = e and eng:def_of(e.id)
            if d and d.secret then
                S.frame.showcase:Hide()
                S.frame.showcaseLabel:SetText("Opponent played a |cffcc66ffSecret|r")
                S.frame.showcaseUntil = GetTime() + 2.2
            elseif e then
                S.frame.showcase.costNow = nil
                S.frame.showcase:SetCard(e.card_id)
                S.frame.showcaseLabel:SetText("Opponent played")
                S.frame.showcaseUntil = GetTime() + 2.2
            end
        end
        if turnStarted == ME() and not eng:is_terminal() then
            showBanner("Your Turn")
            Art:Sfx("turn")
        end
        return
    end
    if what == "end" then
        Art:Sfx(Match.result == "win" and "win" or "lose")
        Board:Refresh()
    end
end

Match:Subscribe(onMatch)

-- Shared with the other board files.
P.buildChoice = buildChoice
P.entityTooltip = entityTooltip
P.myDecisionNow = myDecisionNow
