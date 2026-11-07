-- Chat plumbing shared by the tavern channel, card links and deck codes.
--
-- WoW: Forever blocks addons from sending chat messages (ADDON_ACTION_BLOCKED, even from a click), so
-- anything we "say" is put into the chat box and the player presses Enter. Addon messages (hidden) are
-- allowed and are what Presence.lua uses.
--
-- Shares are plain text everyone can read: "[Tavern Card: Hogger]" and "[Tavern Deck: Name] TCD1.MAGE.xxxx".
-- For players with the addon a chat filter turns them into colored, clickable links.
--
-- Chat filters: while the game marks chat data as secret (combat, instances, encounters) an addon filter
-- taints Blizzard's chat code, so the filters are only registered outside of those (BestiarioTCG 1.26.1).

local TC = TavernCards_NS

local Chat = {}
TC.Chat = Chat

local LINK = "TavernCards"

function Chat.IsSecret(v)
    return issecretvalue and issecretvalue(v) or false
end

-- ---- filters, registered only while chat is not locked down -----------------------------------

local filters, on = {}, false

local function filterApi()
    local add = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
    local remove = (ChatFrameUtil and ChatFrameUtil.RemoveMessageEventFilter) or ChatFrame_RemoveMessageEventFilter
    return add, remove
end

local function lockedDown()
    if C_ChatInfo and C_ChatInfo.InChatMessagingLockdown then
        local ok, v = pcall(C_ChatInfo.InChatMessagingLockdown)
        if ok and v then return true end
    end
    if InCombatLockdown and InCombatLockdown() then return true end
    if IsInInstance then
        local ok, inside = pcall(IsInInstance)
        if ok and inside then return true end
    end
    return false
end
Chat.Busy = lockedDown

local function setFilters(want)
    if want == on then return end
    local add, remove = filterApi()
    local fn = want and add or remove
    if not fn then return end
    for _, f in ipairs(filters) do
        pcall(fn, f[1], f[2])
    end
    on = want
end

function Chat:AddFilter(event, fn)
    filters[#filters + 1] = { event, fn }
    if on then
        local add = filterApi()
        if add then pcall(add, event, fn) end
    end
end

for _, ev in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "PLAYER_REGEN_ENABLED", "ENCOUNTER_END" }) do
    TC:On(ev, function() setFilters(not lockedDown()) end)
end
for _, ev in ipairs({ "PLAYER_REGEN_DISABLED", "ENCOUNTER_START" }) do
    TC:On(ev, function() setFilters(false) end)
end

-- ---- putting text into the chat box ------------------------------------------------------------

-- Into the chat box being typed in (like shift-clicking an item), else a fresh one. `cmd` = "/2" etc.
function Chat:Insert(text, cmd)
    local active = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
        or (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
    if active and not cmd then
        active:Insert(text)
        return true
    end
    local open = (ChatFrameUtil and ChatFrameUtil.OpenChat) or ChatFrame_OpenChat
    if type(open) ~= "function" then return false end
    return (pcall(open, (cmd and (cmd .. " ") or "") .. text))
end

-- ---- card and deck shares ----------------------------------------------------------------------

-- Card names to ids, preferring collectible cards (tokens share names with them).
local byName
local function cardByName(name)
    if not byName then
        byName = {}
        for _, id in ipairs(TC.CardOrder) do
            local card = TC.Cards[id]
            local key = card.name:lower()
            local prev = byName[key]
            if not prev or (bit.band(card.flags, 1) ~= 0 and bit.band(TC.Cards[prev].flags, 1) == 0) then
                byName[key] = id
            end
        end
    end
    return byName[name:lower()]
end
Chat.CardByName = cardByName

function Chat:CardText(id)
    local card = TC.Cards[id]
    return card and ("[Tavern Card: " .. card.name .. "]") or nil
end

function Chat:DeckText(deck)
    local code = TC.Decks:Encode(deck)
    local name = deck.name:gsub("[%[%]|:]", ""):sub(1, 32)
    return ("[Tavern Deck: %s] %s"):format(name, code)
end

function Chat:InsertCard(id)
    local text = self:CardText(id)
    if text then self:Insert(text) end
end

local function cardLink(id)
    local card = TC.Cards[id]
    local r, g, b = TC.Art:RarityColor(card.rarity)
    return ("|cff%02x%02x%02x|Haddon:%s:card:%s|h[%s]|h|r"):format(r * 255, g * 255, b * 255, LINK, id, card.name)
end

local function deckLink(name, code)
    return ("|cffffd100|Haddon:%s:deck:%s:%s|h[Deck: %s]|h|r"):format(LINK, code, (name:gsub(":", " ")), name)
end

-- The message with every share turned into a link (nil when there is none).
function Chat.Linkify(msg)
    if type(msg) ~= "string" or Chat.IsSecret(msg) or not msg:find("[Tavern ", 1, true) then return nil end
    local changed = false
    local out = msg:gsub("%[Tavern Deck: ([^%]|]+)%] (TCD%d%.%u+%.[%w%+/]+)", function(name, code)
        changed = true
        return deckLink(name, code)
    end)
    out = out:gsub("%[Tavern Card: ([^%]|]+)%]", function(name)
        local id = cardByName(name)
        if not id then return nil end
        changed = true
        return cardLink(id)
    end)
    return changed and out or nil
end

local function filter(_, _, msg, ...)
    local out = Chat.Linkify(msg)
    if out then return false, out, ... end
    return false, msg, ...
end
for _, ev in ipairs({ "CHAT_MSG_CHANNEL", "CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
    "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_GUILD", "CHAT_MSG_OFFICER", "CHAT_MSG_WHISPER",
    "CHAT_MSG_WHISPER_INFORM", "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER", "CHAT_MSG_EMOTE" }) do
    Chat:AddFilter(ev, filter)
end

-- ---- clicking and hovering the links -----------------------------------------------------------

local function parse(link)
    if type(link) ~= "string" then return end
    local id = link:match("^addon:" .. LINK .. ":card:(.+)$")
    if id then return "card", id end
    local code, name = link:match("^addon:" .. LINK .. ":deck:([^:]+):(.*)$")
    if code then return "deck", code, name end
end

local lastClick = 0
local function onLink(link)
    local kind, a, b = parse(link)
    if not kind then return end
    -- Both hooks below can fire for one click.
    local now = GetTime()
    if now - lastClick < 0.2 then return end
    lastClick = now
    if kind == "card" then
        if IsModifiedClick and IsModifiedClick("CHATLINK") then
            Chat:InsertCard(a)
        elseif TC.Cards[a] then
            TC:ShowCard(a)
        end
    else
        TC:Safe("deck link", TC.Decks.OfferImport, TC.Decks, a, b)
    end
end

if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("SetItemRef", function(_, link) onLink(link) end, Chat)
end
if hooksecurefunc and SetItemRef then
    hooksecurefunc("SetItemRef", function(link) onLink(link) end)
end

-- Hover: the card's tooltip, like an item link.
local hooked = {}
local function hookChatFrames()
    local frames = {}
    for i = 1, (NUM_CHAT_WINDOWS or 10) do frames[#frames + 1] = _G["ChatFrame" .. i] end
    for _, name in ipairs(CHAT_FRAMES or {}) do frames[#frames + 1] = _G[name] end
    for _, cf in ipairs(frames) do
        if cf and not hooked[cf] and cf.HookScript then
            hooked[cf] = true
            cf:HookScript("OnHyperlinkEnter", function(self, link)
                local kind, a, b = parse(link)
                if kind == "card" and TC.Cards[a] then
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                    TC:CardTooltip(a)
                    GameTooltip:AddLine("Click to open it in your card book.", 0.5, 0.75, 1)
                    GameTooltip:Show()
                elseif kind == "deck" then
                    local deck = TC.Decks:Decode(a)
                    GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                    GameTooltip:SetText(b ~= "" and b or "Tavern Deck", 1, 0.82, 0)
                    if deck then
                        GameTooltip:AddLine((LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[deck.class]) or deck.class, 1, 1, 1)
                        GameTooltip:AddLine(("You own %d of its %d cards."):format(TC.Decks:OwnedCount(deck), TC.Decks:Count(deck)), 0.8, 0.8, 0.8)
                        GameTooltip:AddLine("Click to copy it into your decks.", 0.5, 0.75, 1)
                    else
                        GameTooltip:AddLine("This deck code is from another version of Tavern Cards.", 1, 0.4, 0.3, true)
                    end
                    GameTooltip:Show()
                end
            end)
            cf:HookScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
        end
    end
end
TC:On("PLAYER_LOGIN", function()
    hookChatFrames()
    -- Whisper windows popped out later get the hover tooltips too.
    if hooksecurefunc and FCF_OpenTemporaryWindow then
        hooksecurefunc("FCF_OpenTemporaryWindow", function() TC:Safe("chat hooks", hookChatFrames) end)
    end
end)
