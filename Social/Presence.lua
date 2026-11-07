-- Who else has Tavern Cards, with no server: a hidden chat channel (not shown in any chat window) where
-- every player with the addon says hello every few minutes, by addon message. A custom channel reaches
-- one realm and faction, and WoW: Forever's servers are many connected realms, so the hello also goes to
-- the group and the guild (both cross-realm). The same pattern as BestiarioTCG's Presence.lua.
--
--   H:version:collected:wins   hello
--   W                          who is online? (answered by whisper, after a random wait, rate-limited)
--
-- This is the groundwork for challenges between players: the Play tab lists who is online.

local TC = TavernCards_NS

local Presence = {}
TC.Presence = Presence

local PREFIX = "TCHello"
local HIDDEN = "TavernCardsPresence"
local HELLO_EVERY = 300
local ONLINE_FOR = 660
local WHO_GAP, ANSWER_GAP, GROUP_GAP = 60, 60, 8

local online = {}   -- [full name] = { at, version, collected, wins }
local listeners = {}

function Presence:Subscribe(fn)
    listeners[#listeners + 1] = fn
end

local function changed()
    for _, fn in ipairs(listeners) do TC:Safe("presence", fn) end
end

local function me()
    local name, realm = UnitFullName("player")
    if not name then return nil end
    realm = realm and realm ~= "" and realm or (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
    return realm ~= "" and (name .. "-" .. realm) or name
end

local function full(name)
    if not name or TC.Chat.IsSecret(name) then return nil end
    if name:find("-", 1, true) then return name end
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    return realm and (name .. "-" .. realm) or name
end

local function hello()
    local owned = TC.Collection:Stats()
    local stats = TC.db.stats or {}
    return ("H:%s:%d:%d"):format(TC.VERSION, owned or 0, stats.won or 0)
end

local function send(text, chatType, target)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, chatType, target)
end

local function hiddenNumber()
    if not GetChannelName then return nil end
    local ok, num = pcall(GetChannelName, HIDDEN)
    if ok and type(num) == "number" and num > 0 then return num end
end

local function hideHidden()
    local remove = (ChatFrameUtil and ChatFrameUtil.RemoveChannel) or ChatFrame_RemoveChannel
    if not remove then return end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local cf = _G["ChatFrame" .. i]
        if cf then pcall(remove, cf, HIDDEN) end
    end
end

local function joinedNumber()
    local num = hiddenNumber()
    if not num then
        local join = JoinTemporaryChannel or JoinChannelByName
        if join then pcall(join, HIDDEN) end
        num = hiddenNumber()
    end
    hideHidden()
    return num
end

function Presence:Hello()
    if TC.Chat.Busy() then return end
    local text = hello()
    local num = joinedNumber()
    if num then send(text, "CHANNEL", num) end
    if IsInGuild and IsInGuild() then send(text, "GUILD") end
    self:GroupHello()
end

local lastGroup = -GROUP_GAP
function Presence:GroupHello()
    local chan = IsInRaid and IsInRaid() and "RAID" or (IsInGroup and IsInGroup() and "PARTY") or nil
    if IsInGroup and LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then chan = "INSTANCE_CHAT" end
    if not chan or GetTime() - lastGroup < GROUP_GAP then return end
    lastGroup = GetTime()
    send(hello(), chan)
end

local lastWho = -WHO_GAP
function Presence:AskWho()
    if GetTime() - lastWho < WHO_GAP or TC.Chat.Busy() then return false end
    local num = joinedNumber()
    if not num then return false end
    lastWho = GetTime()
    send("W", "CHANNEL", num)
    return true
end

local answered = {}
local function answer(sender)
    local t = GetTime()
    if answered[sender] and t - answered[sender] < ANSWER_GAP then return end
    answered[sender] = t
    C_Timer.After(1 + math.random() * 5, function()
        if not TC.Chat.Busy() then send(hello(), "WHISPER", sender) end
    end)
end

-- Players heard lately, freshest first: { name, ago, version, collected, wins }.
function Presence:Online()
    local list, t = {}, GetTime()
    local self_ = me()
    for name, e in pairs(online) do
        if t - e.at > ONLINE_FOR then
            online[name] = nil
        elseif name ~= self_ then
            list[#list + 1] = { name = name, ago = t - e.at, version = e.version, collected = e.collected, wins = e.wins }
        end
    end
    table.sort(list, function(a, b) return a.ago < b.ago end)
    return list
end

TC:On("CHAT_MSG_ADDON", function(prefix, text, _, sender)
    if prefix ~= PREFIX or TC.Chat.IsSecret(text) or TC.Chat.IsSecret(sender) then return end
    local name = full(sender)
    if not name or name == me() then return end
    if text == "W" then
        answer(name)
        return
    end
    local version, collected, wins = text:match("^H:([^:]*):(%d*):(%d*)")
    if version then
        local isNew = not online[name]
        online[name] = { at = GetTime(), version = version:sub(1, 16), collected = tonumber(collected) or 0,
            wins = tonumber(wins) or 0 }
        if isNew then changed() end
    end
end)

TC:On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    end
    -- After the visible channel (Channel.lua joins at 10 s), so channel numbers stay put.
    C_Timer.After(20, function()
        TC:Safe("presence", Presence.Hello, Presence)
        if C_Timer.NewTicker then
            C_Timer.NewTicker(HELLO_EVERY, function() TC:Safe("presence", Presence.Hello, Presence) end)
        end
    end)
end)

TC:On("GROUP_ROSTER_UPDATE", function()
    C_Timer.After(2, function() TC:Safe("presence", Presence.GroupHello, Presence) end)
end)
