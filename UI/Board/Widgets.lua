-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Board widgets: hero portraits and class badges, glows, minion/hero/power/weapon/mana
-- widgets and card backs. They draw what they are given; Controller decides what that is.

local TC = TavernCards_NS
local Board = TC.Board
local P, S = Board._P, Board._S
local D = TC.EngineDefs
local Art = TC.Art
local KW = D.KW
local band = bit.band
local SLOT_H, SLOT_W, gem = P.SLOT_H, P.SLOT_W, P.gem

local function className(class)
    return (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
end

-- Hero portraits. You: your character's portrait. A friend you duel: theirs while they're in your group
-- or targeted. The house: a character portrait that fits its class. Every hero wears a class badge.
local HOUSE_FACE = { WARRIOR = "Orc_Male", PALADIN = "Human_Male", HUNTER = "Nightelf_Female", ROGUE = "Undead_Male",
    PRIEST = "Human_Female", SHAMAN = "Tauren_Male", MAGE = "Gnome_Male", WARLOCK = "Undead_Female",
    DRUID = "Nightelf_Male", DEATHKNIGHT = "Human_Male", DEMONHUNTER = "Bloodelf_Male" }
local CLASS_BADGE = { WARRIOR = "Ability_Warrior_BattleShout", PALADIN = "Spell_Holy_HolyBolt",
    HUNTER = "INV_Weapon_Bow_07", ROGUE = "Ability_Stealth", PRIEST = "Spell_Holy_PowerWordShield",
    SHAMAN = "Spell_Nature_BloodLust", MAGE = "Spell_Frost_FrostBolt02", WARLOCK = "Spell_Shadow_DeathCoil",
    DRUID = "Ability_Druid_CatForm", DEATHKNIGHT = "Spell_Deathknight_ClassIcon",
    DEMONHUNTER = "Ability_DemonHunter_SpecDPS" }

-- The unit token for a player name, when the client has one (group, raid, target).
local function unitForName(name)
    if not name or not UnitName then return nil end
    local want = (Ambiguate and Ambiguate(name, "none") or name):lower()
    local units = { "target" }
    for i = 1, 4 do units[#units + 1] = "party" .. i end
    for i = 1, 40 do units[#units + 1] = "raid" .. i end
    for _, unit in ipairs(units) do
        local n, realm = UnitName(unit)
        if n then
            local full = (realm and realm ~= "") and (n .. "-" .. realm) or n
            if full:lower() == want or n:lower() == want then return unit end
        end
    end
end

local setClassIcon

local function setHeroPortrait(b, class, unit, house)
    local tex = b.portrait
    if unit and SetPortraitTexture and UnitExists and UnitExists(unit) then
        SetPortraitTexture(tex, unit)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    else
        local face = HOUSE_FACE[class] and Art:IconIfExists("Achievement_Character_" .. HOUSE_FACE[class])
        if face then
            tex:SetTexture(face)
            tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        else
            setClassIcon(tex, class)
        end
    end
    -- 3D on top when available: the unit, else (the house) the innkeeper chosen for this match. A friend
    -- out of sight keeps their class portrait: an innkeeper would be the wrong face for them.
    local shown
    local function back() tex:SetAlpha(1) end
    if unit and UnitExists and UnitExists(unit) then
        shown = TC.Models:Show(b.model, "unit", unit, 0.85, 1, nil, back)
    elseif house then
        local hd = TC.HouseDisplays and TC.HouseDisplays[house]
        shown = TC.Models:Show(b.model, hd and "display" or "npc", hd or house, 0.85, 1, nil, back)
    else
        TC.Models:Hide(b.model)
    end
    tex:SetAlpha(shown and TC.Models:ArtAlpha(1) or 1)
    local badge = CLASS_BADGE[class] and Art:IconIfExists(CLASS_BADGE[class])
    b.badge:SetShown(badge ~= nil)
    if badge then b.badge.icon:SetTexture(badge) end
    b.badge.class = class
end

function setClassIcon(tex, class)
    local square = Art:SquareClassIcon(class)
    if square then
        tex:SetTexture(square)
        tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        return
    end
    local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class]
    if coords then
        tex:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CHARACTERCREATE-CLASSES")
        tex:SetTexCoord(unpack(coords))
    else
        tex:SetTexture(Art:SafeIcon("INV_Misc_Ticket_Tarot_Stack_01"))
        tex:SetTexCoord(0, 1, 0, 1)
    end
end

local allGlows = {}
-- A soft additive glow behind or around a widget: the radial glow by default, or another of our
-- textures (the oval token glow for minions). Same interface for every glow: SetVertexColor, Show, Hide,
-- SetAlpha (the board pulses them).
local function addGlow(f, scale, tex, scaleY)
    local g = f:CreateTexture(nil, "OVERLAY", nil, 7)
    allGlows[#allGlows + 1] = g
    g:SetTexture(Art:Tex(tex or "glow"))
    g:SetBlendMode("ADD")
    g:SetPoint("CENTER")
    g:SetSize(f:GetWidth() * (scale or 1.75), f:GetHeight() * (scaleY or scale or 1.75))
    g:Hide()
    f.glow = g
    return g
end

-- The outline of a whole card (the hand): a bright line on the card's own rounded edge and a soft halo
-- outside it (Textures/card_glow), above the card's frame.
local function addBorderGlow(f)
    local holder = CreateFrame("Frame", nil, f)
    holder:SetAllPoints(f)
    holder:SetFrameLevel(f:GetFrameLevel() + 6)
    holder:EnableMouse(false)
    local m = TC.TexLayout.card.glow
    local w, h = f:GetWidth(), f:GetHeight()
    local g = holder:CreateTexture(nil, "OVERLAY")
    g:SetTexture(Art:Tex("card_glow"))
    g:SetBlendMode("ADD")
    g:SetPoint("TOPLEFT", f, "TOPLEFT", -m[1] * w, m[2] * h)
    g:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", m[1] * w, -m[2] * h)
    g:Hide()
    allGlows[#allGlows + 1] = g
    f.glow = g
    return g
end

-- "green" = can act, "gold" = selected, "red" = a target of the move being made.
local GLOW_COLORS = { green = { 0.2, 1, 0.2 }, gold = { 1, 0.85, 0.1 }, red = { 1, 0.25, 0.15 } }
-- The creature sound of a minion (Data/Sounds.lua): which = 1 aggro, 2 attack, 3 wound, 4 death.
local function creatureSound(e, which)
    if not e or not TC.DisplaySounds then return nil end
    local disp = (TC.CardDisplays and TC.CardDisplays[e.card_id]) or (TC.CardModelDisplays and TC.CardModelDisplays[e.card_id])
    local kit = disp and TC.DisplaySounds[disp]
    return kit and kit[which] ~= 0 and kit[which] or nil
end

local function setGlow(f, color)
    -- A creature that may be the target of the move being made, or that you picked to make it, stands ready.
    if f.model then TC.Models:Stance(f.model, (color == "red" or color == "gold") and "ready" or nil) end
    if not f.glow then return end
    local c = color and GLOW_COLORS[color]
    if c then
        f.glow:SetVertexColor(c[1], c[2], c[3])
        f.glow:Show()
    else
        f.glow:Hide()
    end
end

-- A portrait clipped to a shape (Textures/mask_<shape>), with a white flash of the same shape over it.
local function maskedPortrait(b, shape, inset)
    local t = b:CreateTexture(nil, "ARTWORK")
    t:SetPoint("TOPLEFT", inset or 0, -(inset or 0))
    t:SetPoint("BOTTOMRIGHT", -(inset or 0), inset or 0)
    t:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local mask = b:CreateMaskTexture()
    mask:SetTexture(Art:Tex("mask_" .. shape), "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(t)
    t:AddMaskTexture(mask)
    local f = b:CreateTexture(nil, "OVERLAY", nil, 6)
    f:SetAllPoints(t)
    f:SetTexture(Art:Tex("mask_" .. shape))
    f:SetBlendMode("ADD")
    f:SetAlpha(0)
    b.flash = f
    return t
end

-- A frame texture on its own child frame, above a widget's 3D model (a model can't be masked, so the frame
-- covers its edges). outset: how far it reaches past the widget.
local function frameOver(b, tex, outset, level)
    local f = CreateFrame("Frame", nil, b)
    f:SetPoint("TOPLEFT", -outset, outset)
    f:SetPoint("BOTTOMRIGHT", outset, -outset)
    f:SetFrameLevel(b:GetFrameLevel() + (level or 2))
    f:EnableMouse(false)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    f.tex:SetTexture(Art:Tex(tex))
    return f
end

-- ---- widgets -----------------------------------------------------------------------------------

local function onEntityClick(self, button)
    if button == "RightButton" then
        Board:Cancel()
    elseif self.entity then
        TC:Safe("board click", Board.ClickEntity, Board, self.entity)
    end
end

local function overlay(parent, layer, cell, w, h, sub)
    local t = parent:CreateTexture(nil, layer, nil, sub)
    t:SetSize(w, h)
    t:SetPoint("CENTER")
    Art:Cell(t, "overlays", cell)
    t:Hide()
    return t
end

-- What a minion has, as a column of small round game icons down its left side (then its right): Taunt first, so a
-- wall is seen at a glance, then its other keywords, its Deathrattle and an ongoing effect ("whenever...",
-- auras). The tooltip names them all. Classic-era icons the client surely has, each with a second choice.
local KEYWORD_ICONS = {
    { "taunt", "Ability_Defend", "INV_Shield_06" },
    { "divine", "Spell_Holy_DivineIntervention", "Spell_Holy_SealOfProtection" },
    { "stealth", "Ability_Stealth", "Ability_Ambush" },
    { "immune", "Spell_Holy_SealOfProtection", "Spell_Holy_DivineIntervention" },
    { "charge", "Ability_Warrior_Charge", "Ability_Rogue_Sprint" },
    { "rush", "Ability_Rogue_Sprint", "Ability_Warrior_Charge" },
    { "windfury", "Spell_Nature_Cyclone", "Spell_Nature_Windfury" },
    { "lifesteal", "Spell_Shadow_LifeDrain02", "Spell_Shadow_LifeDrain" },
    { "poisonous", "Ability_PoisonSting", "Ability_Rogue_DualWeild" },
    { "reborn", "Spell_Nature_Reincarnation", "Spell_Holy_Resurrection" },
    { "elusive", "Spell_Nature_Invisibilty", "Spell_Magic_LesserInvisibilty" },
    { "spell_damage", "Spell_Holy_MagicalSentry", "Spell_Fire_SoulBurn" },
    { "deathrattle", "INV_Misc_Bone_HumanSkull_01", "Spell_Shadow_RaiseDead" },
    { "trigger", "Spell_Nature_LightningShield", "Spell_Nature_Lightning" },
}
local KEYWORD_BIT = { taunt = KW.TAUNT, charge = KW.CHARGE, rush = KW.RUSH, windfury = KW.WINDFURY,
    lifesteal = KW.LIFESTEAL, poisonous = KW.POISONOUS, reborn = KW.REBORN, elusive = KW.ELUSIVE,
    spell_damage = KW.SPELL_DAMAGE, deathrattle = KW.DEATHRATTLE, immune = KW.IMMUNE }
-- Triggers that don't act while the minion stands on the board (they ran as it came, or run elsewhere).
local ONE_OFF = { ON_PLAY = true, BATTLECRY = true, DEATHRATTLE = true, CORRUPT = true, FORGED = true,
    CAST_WHEN_DRAWN = true, IN_HAND_TURN_START = true, START_OF_GAME = true, WHEN_AWAKENS = true }
local ICON_SIZE, ICON_STEP, ICON_COLUMN = 19, 20, 4   -- four down the left side, the rest down the right

local function keywordIcon(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(ICON_SIZE, ICON_SIZE)
    f:EnableMouse(false)   -- clicks and hovers go to the minion (its tooltip lists every keyword)
    f.icon = maskedPortrait(f, "round", 1)
    f.rim = f:CreateTexture(nil, "OVERLAY")
    f.rim:SetPoint("TOPLEFT", -2, 2)
    f.rim:SetPoint("BOTTOMRIGHT", 2, -2)
    f.rim:SetTexture(Art:Tex("hero_power"))
    f:Hide()
    return f
end

-- The icons a minion shows now, in KEYWORD_ICONS order (none while Silenced).
local function minionKeywords(e, d)
    local out = {}
    if e.flags.silenced then return out end
    local ongoing = false
    for _, fx in ipairs(d and d.effects or {}) do
        if not ONE_OFF[fx.trigger] and (fx.inHand or 0) == 0 then ongoing = true break end
    end
    for _, row in ipairs(KEYWORD_ICONS) do
        local key = row[1]
        local on
        if key == "divine" then on = e.flags.divine_shield
        elseif key == "stealth" then on = e.flags.stealth
        elseif key == "trigger" then on = ongoing
        else on = band(e.keywords, KEYWORD_BIT[key]) ~= 0 end
        if on then out[#out + 1] = row end
    end
    return out
end

-- A minion on the board: its portrait in a narrow rounded-square frame, attack and health gems, and
-- overlays for taunt, divine shield, frozen, stealth, silence and sleep. Square because a 3D model can only
-- be clipped to a rectangle: the frame's window is exactly the model's rectangle, so nothing spills out.
local RIM = 4   -- the frame's width (tools/textures/build.py TOKEN_RIM)

local function minionWidget(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(SLOT_W, SLOT_H)
    local base = b:GetFrameLevel()
    -- Taunt: a stone shield behind the token.
    b.taunt = overlay(b, "BACKGROUND", "taunt", SLOT_W * 1.42, SLOT_H * 1.3)
    b.art = b:CreateTexture(nil, "ARTWORK")
    b.art:SetPoint("TOPLEFT", RIM, -RIM)
    b.art:SetPoint("BOTTOMRIGHT", -RIM, RIM)
    -- Crop the square icon to the window's taller shape instead of stretching it.
    local crop = (1 - (SLOT_W - 2 * RIM) / (SLOT_H - 2 * RIM)) / 2
    b.art:SetTexCoord(0.07 + crop, 0.93 - crop, 0.07, 0.93)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")   -- read by tooltips; the token shows no name
    b.name:Hide()
    -- The creature in 3D over its (dimmed) icon, in exactly the window.
    b.model = TC.Models:Create(b)
    b.model:SetAllPoints(b.art)
    b.model:SetFrameLevel(base + 1)
    b.ring = frameOver(b, "token_frame", 0)
    b.wings = b.ring:CreateTexture(nil, "ARTWORK", nil, 1)
    b.wings:SetTexture(Art:Tex("token_wings"))
    b.wings:SetSize(SLOT_W, SLOT_H * 0.39)
    b.wings:SetPoint("BOTTOM", b, "TOP", 0, -SLOT_H * 0.06)
    b.top = CreateFrame("Frame", nil, b)
    b.top:SetAllPoints()
    b.top:SetFrameLevel(base + 3)
    b.frozenIce = overlay(b.top, "ARTWORK", "frozen", SLOT_W * 1.1, SLOT_H * 1.05)
    b.stealth = overlay(b.top, "ARTWORK", "stealth", SLOT_W, SLOT_H, 1)
    b.shield = overlay(b.top, "OVERLAY", "divine", SLOT_W * 1.3, SLOT_H * 1.25)
    b.shield:SetBlendMode("ADD")
    b.silence = overlay(b.top, "OVERLAY", "silence", 30, 30, 1)
    b.sleep = overlay(b.top, "OVERLAY", "sleep", 34, 34, 2)
    b.sleep:ClearAllPoints()
    b.sleep:SetPoint("TOPRIGHT", 6, 4)
    b.badge = overlay(b.top, "OVERLAY", "deathrattle", 24, 24, 3)
    b.badge:ClearAllPoints()
    b.badge:SetPoint("BOTTOM", 0, -4)
    b.keywords = {}
    for i = 1, ICON_COLUMN * 2 - 1 do
        local f = keywordIcon(b)
        f:SetFrameLevel(base + 5)
        local right = i > ICON_COLUMN
        local row = right and (i - ICON_COLUMN) or i
        -- Down the left edge from the top; down the right edge below the sleep mark.
        f:SetPoint("TOP", b, right and "TOPRIGHT" or "TOPLEFT", right and 2 or -2, -(right and 30 or 6) - (row - 1) * ICON_STEP)
        b.keywords[i] = f
    end
    b.attack = gem(b, 30, "attack")
    b.attack:SetPoint("BOTTOMLEFT", -7, -5)
    b.attack:SetFrameLevel(base + 4)
    b.health = gem(b, 30, "health")
    b.health:SetPoint("BOTTOMRIGHT", 7, -5)
    b.health:SetFrameLevel(base + 4)
    b.status = b.top:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    b.status:SetPoint("CENTER", b.art, "CENTER")
    b.status:SetShadowOffset(2, -2)
    -- Hits flash the window, above the model.
    b.flash = b.top:CreateTexture(nil, "OVERLAY", nil, 6)
    b.flash:SetAllPoints(b.art)
    b.flash:SetColorTexture(1, 1, 1, 1)
    b.flash:SetBlendMode("ADD")
    b.flash:SetAlpha(0)
    addGlow(b, (SLOT_W + 40) / SLOT_W, "token_glow", (SLOT_H + 40) / SLOT_H)   -- a 20px halo round the frame
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) Board.hover = self.entity P.entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil P.hideZoom() GameTooltip:Hide() end)
    return b
end

-- What a minion shows, from the engine's entity (e) and its card definition (d, from Controller).
local function setMinion(b, e, d)
    if P.fading[b] and b.fadeEntity ~= e.id then
        -- The row shifted mid-fade: this slot now shows another minion, which is already there.
        P.fading[b] = nil
    end
    local card = TC.Cards[e.card_id]
    b.entity = e.id
    b.art:SetTexture(Art:Icon(e.card_id))
    -- A prop (item or object), a creature by its model, or a creature.
    local prop = TC.CardProps and TC.CardProps[e.card_id]
    -- By model whenever it's known (needs only the client's files; a creature id needs the server to know it).
    b.model.weapons = TC.CardWeapons and TC.CardWeapons[e.card_id]   -- legendaries hold their weapons
    local disp = not prop and ((TC.CardDisplays and TC.CardDisplays[e.card_id])
        or (TC.CardModelDisplays and TC.CardModelDisplays[e.card_id]))
    local kind = prop and prop[1] or (disp and "display" or "npc")
    local npc = prop and prop[2] or disp or (TC.CardModels and TC.CardModels[e.card_id])
    if npc and card and card.type ~= "LOCATION" and TC.Models:Show(b.model, kind, npc, prop and 0 or 0.6, 1.05, nil,
        function() b.art:SetAlpha(1) end, prop and prop[3]) then
        b.art:SetAlpha(TC.Models:ArtAlpha(0.3))
    else
        TC.Models:Hide(b.model)
        b.art:SetAlpha(1)
    end
    b.name:SetText(card and card.name or (d and d.name) or e.card_id)
    local legendary = card and card.rarity == "LEGENDARY" or false
    b.wings:SetShown(legendary)
    b.ring.tex:SetTexture(Art:Tex(legendary and "token_frame_legendary" or "token_frame"))
    for _, t in ipairs({ b.frozenIce, b.stealth, b.silence, b.sleep, b.badge }) do t:Hide() end
    if card and card.type == "LOCATION" then
        -- Locations: uses left instead of attack/health, and a marker once used this turn.
        b.attack:Hide()
        b.health:Show()
        b.health.text:SetText(e.durability)
        b.health.text:SetTextColor(1, 1, 1)
        b.taunt:Hide()
        b.shield:Hide()
        for _, f in ipairs(b.keywords) do f:Hide() end
        b.baseAlpha = 1
        if not P.fading[b] then b:SetAlpha(1) end
        b.art:SetVertexColor(e.flags.has_attacked and 0.5 or 1, e.flags.has_attacked and 0.5 or 1, e.flags.has_attacked and 0.5 or 1)
        b.status:SetText(e.flags.has_attacked and "|cffccccccUsed|r" or "")
        b:Show()
        return
    end
    b.attack:Show()
    b.attack.text:SetText(e.attack)
    b.health.text:SetText(e.health)
    local baseAttack = card and card.attack or e.attack
    if e.attack > baseAttack then b.attack.text:SetTextColor(0.3, 1, 0.3) else b.attack.text:SetTextColor(1, 1, 1) end
    if e.health < e.max_health then
        b.health.text:SetTextColor(1, 0.3, 0.3)
    elseif card and e.max_health > card.health then
        b.health.text:SetTextColor(0.3, 1, 0.3)
    else
        b.health.text:SetTextColor(1, 1, 1)
    end
    local silenced = e.flags.silenced
    b.taunt:SetShown(band(e.keywords, KW.TAUNT) ~= 0 and not silenced)
    b.shield:SetShown(e.flags.divine_shield)
    b.stealth:SetShown(e.flags.stealth and true or false)
    b.silence:SetShown(silenced and true or false)
    -- One icon per ability (the single overlay badge it replaces showed only the first).
    local shown = minionKeywords(e, d)
    for i, f in ipairs(b.keywords) do
        local row = shown[i]
        if row then
            f.icon:SetTexture(Art:SafeIcon(row[2], Art:IconIfExists(row[3])))
            f:Show()
        else
            f:Hide()
        end
    end
    b.baseAlpha = e.flags.stealth and 0.75 or 1
    if not P.fading[b] then b:SetAlpha(b.baseAlpha) end
    b.status:SetText("")
    if e.flags.frozen then
        b.art:SetVertexColor(0.7, 0.88, 1)
        b.frozenIce:Show()
    elseif e.flags.dormant_turns > 0 then
        b.art:SetVertexColor(0.6, 0.6, 0.6)
        b.status:SetText("Dormant")
    elseif b.sleeping then
        b.art:SetVertexColor(1, 1, 1)
        b.sleep:Show()
    else
        b.art:SetVertexColor(1, 1, 1)
    end
    b:Show()
end

local HERO_PAD = TC.TexLayout.heroFrame.pad

local function heroWidget(parent, seat)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(84, 84)
    local base = b:GetFrameLevel()
    b.portrait = maskedPortrait(b, "arch")
    -- The hero in 3D (your character, a grouped friend, the house's innkeeper) over the flat portrait.
    b.model = TC.Models:Create(b)
    b.model:SetPoint("TOPLEFT", 4, -10)
    b.model:SetPoint("BOTTOMRIGHT", -4, 0)
    b.model:SetFrameLevel(base + 1)
    b.frame = frameOver(b, "hero_frame", HERO_PAD)
    b.flash:SetParent(b.frame)
    b.frozen = overlay(b.frame, "OVERLAY", "frozen", 96, 96)
    b.badge = CreateFrame("Frame", nil, b)
    b.badge:SetSize(24, 24)
    b.badge:SetPoint("TOPLEFT", -10, 10)
    b.badge:SetFrameLevel(base + 4)
    b.badge.icon = maskedPortrait(b.badge, "round", 2)
    b.badge.rim = b.badge:CreateTexture(nil, "OVERLAY")
    b.badge.rim:SetPoint("TOPLEFT", -3, 3)
    b.badge.rim:SetPoint("BOTTOMRIGHT", 3, -3)
    b.badge.rim:SetTexture(Art:Tex("hero_power"))
    b.badge:EnableMouse(true)
    b.badge:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[self.class]) or self.class or "", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    b.badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
    b.attack = gem(b, 34, "attack")
    b.attack:SetPoint("BOTTOMLEFT", -14, -10)
    b.health = gem(b, 34, "health")
    b.health:SetPoint("BOTTOMRIGHT", 14, -10)
    b.armor = gem(b, 30, "armor")
    b.armor:SetPoint("BOTTOM", b.health, "TOP", 0, -2)
    for _, g in ipairs({ b.attack, b.health, b.armor }) do g:SetFrameLevel(base + 3) end
    b.secrets = b.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    b.secrets:SetPoint("TOP", 0, 2)
    b.secrets:SetTextColor(0.8, 0.45, 1)
    b.name = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.name:SetPoint("RIGHT", b, "LEFT", -100, 0)
    b.deck = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.deck:SetPoint("TOPRIGHT", b.name, "BOTTOMRIGHT", 0, -4)
    b.quest = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    b.quest:SetPoint("TOPRIGHT", b.deck, "BOTTOMRIGHT", 0, -3)
    b.quest:SetTextColor(1, 0.82, 0.3)
    addGlow(b, 1.9)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnClick", onEntityClick)
    b:SetScript("OnEnter", function(self) Board.hover = self.entity P.entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() Board.hover = nil P.hideZoom() GameTooltip:Hide() end)
    return b
end

-- A round, framed icon button: the hero power, the weapon, the class badge.
local function roundButton(parent, size, tint)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b.icon = maskedPortrait(b, "round", 1)
    b.ring = b:CreateTexture(nil, "OVERLAY", nil, 1)   -- a thin ring: most of the art shows
    b.ring:SetPoint("TOPLEFT", -2, 2)
    b.ring:SetPoint("BOTTOMRIGHT", 2, -2)
    b.ring:SetTexture(Art:Tex("hero_power"))
    if tint then b.ring:SetVertexColor(tint[1], tint[2], tint[3]) end
    return b
end

local function powerButton(parent)
    local b = roundButton(parent, 52)
    b.cost = gem(b, 26, "mana")
    b.cost:SetPoint("TOP", 0, 12)
    addGlow(b, 1.9)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:SetScript("OnEnter", function(self)
        if not self.power then return end
        local info = self.info or {}
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(info.name or "Hero Power", 1, 0.82, 0)
        GameTooltip:AddLine(("%d Mana Hero Power"):format(self.costNow or 2), 1, 1, 1)
        GameTooltip:AddLine(info.text or "", 1, 0.82, 0, true)
        if info.imbues and info.imbues > 0 then
            GameTooltip:AddLine(("Imbued %d time%s."):format(info.imbues, info.imbues == 1 and "" or "s"), 0.6, 0.9, 0.6)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

local function weaponWidget(parent)
    local b = roundButton(parent, 52, { 0.72, 0.74, 0.8 })   -- an iron ring
    b.attack = gem(b, 26, "attack")
    b.attack:SetPoint("BOTTOMLEFT", -8, -6)
    b.durability = gem(b, 26, "durability")
    b.durability:SetPoint("BOTTOMRIGHT", 8, -6)
    b:SetScript("OnEnter", function(self) P.entityTooltip(self, self.entity) end)
    b:SetScript("OnLeave", function() P.hideZoom() GameTooltip:Hide() end)
    return b
end

-- Mana crystals: Textures/mana_crystal cells (full, empty, locked by Overload, locked next turn).
local CRYSTAL = { full = 0, empty = 1, locked = 2, next = 3 }

local function setCrystal(t, look)
    local i = CRYSTAL[look]
    t:SetTexCoord(i / 4, (i + 1) / 4, 0, 1)
end

local function manaBar(parent)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(250, 42)
    f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.text:SetPoint("BOTTOMLEFT", 0, 4)
    f.text:SetShadowOffset(1, -1)
    f.crystals = {}
    for i = 1, 10 do
        local t = f:CreateTexture(nil, "ARTWORK")
        t:SetSize(21, 21)
        t:SetPoint("BOTTOMLEFT", 48 + (i - 1) * 20, 3)
        t:SetTexture(Art:Tex("mana_crystal"))
        f.crystals[i] = t
    end
    f:EnableMouse(true)
    f:SetScript("OnEnter", function(self)
        local p = self.player
        if not p then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Mana", 0.3, 0.65, 1)
        GameTooltip:AddLine(("%d of %d crystals available."):format(p.mana, p.max_mana), 1, 1, 1)
        GameTooltip:AddLine("You gain a crystal each turn (up to 10), refilled at the start of your turn.", 0.75, 0.75, 0.75, true)
        if p.overload_locked > 0 then
            GameTooltip:AddLine(("|cffff6040%d locked by Overload|r this turn."):format(p.overload_locked), 1, 1, 1, true)
        end
        if p.overload_next > 0 then
            GameTooltip:AddLine(("|cffff6040%d will be locked next turn|r (Overload)."):format(p.overload_next), 1, 1, 1, true)
        end
        GameTooltip:AddLine("|cffffd100Overload:|r " .. (TC.Keywords:Explain("Overload") or ""), 0.75, 0.75, 0.75, true)
        GameTooltip:Show()
    end)
    f:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return f
end

local function setMana(f, p)
    f.player = p
    local overload = p.overload_locked
    f.text:SetText(("|cff66aaff%d|r/%d"):format(p.mana, p.max_mana))
    for i = 1, 10 do
        local t = f.crystals[i]
        if i > math.max(p.max_mana, p.mana) then
            -- Crystals still to come: next turn's overload shows in the next slots.
            t:SetShown(i <= p.max_mana + p.overload_next and i <= 10)
            setCrystal(t, "next")
            t:SetAlpha(0.6)
        else
            t:Show()
            t:SetAlpha(1)
            if i > p.max_mana - overload and i > p.mana then
                setCrystal(t, "locked")
            elseif i > p.mana then
                setCrystal(t, "empty")
            else
                setCrystal(t, "full")
            end
        end
    end
end

local function cardBack(parent, w, h)
    return TC.CardBacks:Create(parent, w or 34, h or 48)
end

-- Shared with the other board files.
P.addBorderGlow = addBorderGlow
P.addGlow = addGlow
P.allGlows = allGlows
P.cardBack = cardBack
P.className = className
P.creatureSound = creatureSound
P.heroWidget = heroWidget
P.manaBar = manaBar
P.minionWidget = minionWidget
P.powerButton = powerButton
P.setGlow = setGlow
P.setHeroPortrait = setHeroPortrait
P.setMana = setMana
P.setMinion = setMinion
P.unitForName = unitForName
P.weaponWidget = weaponWidget
