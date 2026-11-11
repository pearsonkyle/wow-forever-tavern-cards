-- "Card earned" toast, built like the game's own achievement alert (same atlases, layout and
-- animations), with a plain backdrop fallback should an atlas be missing. Toasts queue: a burst of
-- grants shows one after another, and a batch (the first-login journey) is a single toast.

local TC = TavernCards_NS
local Art = TC.Art

local Toast = {}
TC.Toast = Toast

local HOLD = 4.5
local queue = {}
local frame

local function atlas(tex, name)
    if TC.Compat:HasAtlas(name) then
        tex:SetAtlas(name, true)
        return true
    end
end

local function alpha(group, from, to, duration, order, delay)
    local a = group:CreateAnimation("Alpha")
    a:SetFromAlpha(from)
    a:SetToAlpha(to)
    a:SetDuration(duration)
    a:SetOrder(order or 1)
    if delay then
        a:SetStartDelay(delay)
    end
    return a
end

local function build()
    local t = CreateFrame("Button", "TavernCardsToast", UIParent, not TC.Compat:HasAtlas("ui-achievement-guild-background") and "BackdropTemplate" or nil)
    t:SetSize(300, 101)
    t:SetPoint("TOP", 0, -140)
    t:SetFrameStrata("FULLSCREEN_DIALOG")
    t:Hide()

    t.bg = t:CreateTexture(nil, "BACKGROUND")
    t.bg:SetPoint("CENTER")
    if not atlas(t.bg, "ui-achievement-guild-background") then
        t:SetBackdrop({ bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
            edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Gold-Border", edgeSize = 24,
            insets = { left = 6, right = 6, top = 6, bottom = 6 } })
    end

    t.banner = t:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    t.banner:SetPoint("TOPLEFT", 50, -13)
    t.banner:SetPoint("TOPRIGHT", -50, -13)
    t.banner:SetText("Tavern Cards")

    t.line = t:CreateFontString(nil, "ARTWORK", "GameFontBlackTiny")
    t.line:SetSize(200, 12)
    t.line:SetPoint("TOP", 0, -38)

    t.name = t:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    t.name:SetSize(160, 36)
    t.name:SetPoint("TOP", t.line, "BOTTOM")
    t.name:SetJustifyH("CENTER")
    t.name:SetJustifyV("MIDDLE")
    if t.name.SetMaxLines then
        t.name:SetMaxLines(2)
    end

    -- Card icon in the achievement icon frame.
    local icon = CreateFrame("Frame", nil, t)
    icon:SetSize(78, 75)
    icon:SetPoint("TOPLEFT", 0, -25)
    t.icon = icon:CreateTexture(nil, "ARTWORK")
    t.icon:SetSize(48, 48)
    t.icon:SetPoint("CENTER", -1, -2)
    t.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    local iconFrame = icon:CreateTexture(nil, "OVERLAY")
    atlas(iconFrame, "ui-achievement-guild-iconframe")
    iconFrame:SetPoint("CENTER")

    -- The shield carries the mana cost, like a crystal.
    local shield = CreateFrame("Frame", nil, t)
    shield:SetSize(64, 64)
    shield:SetPoint("TOPRIGHT", -12, -25)
    local shieldTex = shield:CreateTexture(nil, "BACKGROUND")
    atlas(shieldTex, "ui-achievement-shield-1")
    shieldTex:SetPoint("TOPRIGHT", 1, -6)
    t.cost = shield:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t.cost:SetPoint("CENTER", 2, -2)
    t.cost:SetTextColor(0.55, 0.8, 1)

    local glow = t:CreateTexture(nil, "OVERLAY")
    atlas(glow, "ui-achievement-guild-glow")
    glow:SetBlendMode("ADD")
    glow:SetPoint("CENTER")
    glow:SetAlpha(0)
    local glowAnim = glow:CreateAnimationGroup()
    alpha(glowAnim, 0, 1, 0.2, 1)
    alpha(glowAnim, 1, 0, 0.5, 2)
    t.glowAnim = glowAnim

    local shine = t:CreateTexture(nil, "OVERLAY")
    atlas(shine, "ui-achievement-guild-shine")
    shine:SetBlendMode("ADD")
    shine:SetPoint("BOTTOMLEFT", 0, 16)
    shine:SetAlpha(0)
    local shineAnim = shine:CreateAnimationGroup()
    alpha(shineAnim, 0, 1, 0.2, 1)
    local move = shineAnim:CreateAnimation("Translation")
    move:SetOffset(240, 0)
    move:SetDuration(0.85)
    move:SetOrder(2)
    alpha(shineAnim, 1, 0, 0.5, 2, 0.35)
    t.shineAnim = shineAnim

    t.intro = t:CreateAnimationGroup()
    alpha(t.intro, 0, 1, 0.2, 1)
    t.outro = t:CreateAnimationGroup()
    alpha(t.outro, 1, 0, 1.2, 1)
    t.outro:SetScript("OnFinished", function()
        t:Hide()
        Toast:Next()
    end)

    t:SetScript("OnUpdate", function(self, elapsed)
        if self:IsMouseOver() then
            return
        end
        self.left = self.left - elapsed
        if self.left <= 0 and not self.outro:IsPlaying() then
            self.outro:Play()
        end
    end)
    t:SetScript("OnEnter", function(self)
        self.outro:Stop()
        self:SetAlpha(1)
        Toast:ShowTooltip(self)
    end)
    t:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    t:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    t:SetScript("OnClick", function(self, button)
        GameTooltip:Hide()
        self.outro:Stop()
        self:Hide()
        local entry = self.entry
        if button == "LeftButton" and entry then
            TC:Safe("toast click", function()
                if entry.id then
                    TC:ShowCard(entry.id)
                else
                    TC:ShowCollected()
                end
            end)
        end
        Toast:Next()
    end)
    return t
end

function Toast:ShowTooltip(owner)
    local e = owner.entry
    GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
    if e.notice then
        GameTooltip:SetText(e.label, 1, 0.82, 0)
        GameTooltip:AddLine(e.name, 1, 1, 1)
    elseif e.id then
        TC:CardTooltip(e.id)
        if e.quest then
            TC.Quests:AddTooltipLines(GameTooltip, e.quest)
        elseif e.source then
            GameTooltip:AddLine(e.source, 0.6, 0.6, 0.6)
        end
        if e.dust and e.dust > 0 then
            GameTooltip:AddLine(("Already at the deck limit: +%d dust"):format(e.dust), 0.7, 0.85, 1)
        end
    else
        GameTooltip:SetText(e.label, 1, 0.82, 0)
        GameTooltip:AddLine(("%d cards added to your collection."):format(e.count), 1, 1, 1)
    end
    GameTooltip:AddLine("Click to open your collection.", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local SOUNDS = { FREE = "IG_QUEST_LIST_COMPLETE", COMMON = "IG_QUEST_LIST_COMPLETE", RARE = "UI_EPICLOOT_TOAST",
    EPIC = "UI_EPICLOOT_TOAST", LEGENDARY = "UI_LEGENDARY_LOOT_TOAST" }

function Toast:Next()
    if frame and frame:IsShown() then
        return
    end
    local e = table.remove(queue, 1)
    if not e then
        return
    end
    frame = frame or build()
    frame.entry = e
    if e.notice then
        frame.line:SetText(e.label)
        frame.name:SetText("|cffffffff" .. e.name .. "|r")
        frame.icon:SetTexture(e.icon or "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
        frame.cost:SetText("")
        Art:Play("UI_LEGENDARY_LOOT_TOAST")
    elseif e.id then
        local card = TC.Cards[e.id]
        frame.line:SetText(e.result == "dust" and "Duplicate Card" or e.result == "copy" and "Second Copy" or "Card Earned")
        frame.name:SetText(Art:ColoredName(e.id))
        frame.icon:SetTexture(Art:Icon(e.id))
        frame.cost:SetText(card.cost)
        Art:Play(SOUNDS[card.rarity] or SOUNDS.COMMON)
    else
        frame.line:SetText(e.label)
        frame.name:SetText(("|cffffffff%d cards|r"):format(e.count))
        frame.icon:SetTexture("Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01")
        frame.cost:SetText(e.count > 99 and "!" or e.count)
        Art:Play("UI_EPICLOOT_TOAST")
    end
    frame.left = HOLD
    frame.outro:Stop()
    frame:SetAlpha(1)
    frame:Show()
    frame.intro:Play()
    frame.glowAnim:Play()
    frame.shineAnim:Play()
end

-- A toast that isn't a card: an unlocked deck class.
function Toast:Notice(label, name, icon)
    queue[#queue + 1] = { notice = true, label = label, name = name, icon = icon }
    self:Next()
end

function Toast:Preview(id)
    queue[#queue + 1] = { id = id, source = "Preview (not added)", result = "new" }
    self:Next()
end

TC.Collection:Subscribe(function(event, p)
    if event == "card" then
        queue[#queue + 1] = { id = p.id, source = p.source, result = p.result, dust = p.dust, quest = p.quest }
    elseif event == "batch" then
        queue[#queue + 1] = { label = p.label, count = #p.cards }
    else
        return
    end
    Toast:Next()
end)

-- Shared card tooltip (the card book, the hand, the board, chat links), one fact per line:
--   Name (in its rarity colour)
--   Minion - Beast               Hunter
--   4 Mana       3 Attack, 2 Health
--   rules text (its own line breaks kept)
--   keyword glossary (Overload: ...)
--   owned copies (card book only)
local TRIBES = { { 0x1000, "All" }, { 0x01, "Beast" }, { 0x02, "Undead" }, { 0x04, "Elemental" }, { 0x08, "Mech" },
    { 0x10, "Dragon" }, { 0x20, "Demon" }, { 0x40, "Pirate" }, { 0x80, "Murloc" }, { 0x100, "Draenei" },
    { 0x200, "Naga" }, { 0x400, "Totem" }, { 0x800, "Quilboar" } }
local TYPE_WORD = { MINION = "Minion", SPELL = "Spell", WEAPON = "Weapon", LOCATION = "Location", HERO = "Hero",
    HERO_POWER = "Hero Power" }

function TC:TribeText(races)
    if not races or races == 0 then return nil end
    if bit.band(races, 0x1000) ~= 0 then return "All tribes" end
    local out = {}
    for _, t in ipairs(TRIBES) do
        if bit.band(races, t[1]) ~= 0 then out[#out + 1] = t[2] end
    end
    return #out > 0 and table.concat(out, ", ") or nil
end

function TC:CardTooltip(id, inGame)
    local card = TC.Cards[id]
    if not card then
        return
    end
    local tip = GameTooltip
    local r, g, b = Art:RarityColor(card.rarity)
    tip:SetText(card.name, r, g, b)
    -- (No rarity word: the name's colour already says it.)

    local kind = TYPE_WORD[card.type] or card.type
    local tribe = TC:TribeText(card.races)
    if tribe then kind = kind .. " - " .. tribe end
    if card.school and card.school ~= "" then kind = kind .. " - " .. card.school:sub(1, 1):upper() .. card.school:sub(2) end
    local family, cr, cg, cb = "Neutral", 0.8, 0.8, 0.8
    if card.family ~= "NEUTRAL" then
        family = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[card.family]) or card.family
        local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[card.family]
        if c then cr, cg, cb = c.r, c.g, c.b end
    end
    tip:AddDoubleLine(kind, family, 0.9, 0.9, 0.9, cr, cg, cb)

    local stats
    if card.type == "MINION" then
        stats = ("%d Attack, %d Health"):format(card.attack, card.health)
    elseif card.type == "WEAPON" then
        stats = ("%d Attack, %d Durability"):format(card.attack, card.durability)
    elseif card.type == "LOCATION" then
        stats = ("%d uses"):format(card.health)
    end
    tip:AddDoubleLine(("|cff4da6ff%d Mana|r"):format(card.cost), stats or " ", 1, 1, 1, 1, 1, 1)

    local text = Art:RulesText(id, true)
    if text ~= "" then
        tip:AddLine(" ")
        for line in (text .. "\n"):gmatch("(.-)\n") do
            if line:match("%S") then tip:AddLine(line, 1, 0.82, 0, true) end
        end
    end
    -- Keyword explanations go in their own window beside this one (UI/Keywords.lua).
    if TC.Keywords then TC.Keywords:Queue(tip, id) end

    if inGame then
        return
    end
    tip:AddLine(" ")
    local have = TC.Collection:Count(id)
    if TC.Collection:IsBasic(id) then
        tip:AddLine("Basic card: everyone has 2 copies.", 0.6, 0.6, 0.6)
    else
        tip:AddLine(("Owned: %d / %d"):format(have, TC.Collection:Cap(id)), 0.6, 0.6, 0.6)
    end
    if TC.EngineReady and not TC.PlayableNow[id] then
        tip:AddLine("Playable in a later update.", 0.5, 0.5, 0.5)
    end
end
