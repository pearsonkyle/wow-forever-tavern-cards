-- The tavern channel: a normal chat channel for everyone with Tavern Cards, one per faction
-- (TavernCardsA / TavernCardsH), shown in the main chat window. To talk shop, find opponents, and show
-- off cards and decks (shares become links for players with the addon, Social/Chat.lua).
--
-- Joined a few seconds after logging in, so General and Trade keep their numbers. Leaving it by hand
-- (/leave) is remembered: the addon doesn't join again until /tc channel on. (BestiarioTCG's design.)

local TC = TavernCards_NS

local Channel = {}
TC.Channel = Channel

local NAMES = { Alliance = "TavernCardsA", Horde = "TavernCardsH" }
local JOIN_DELAY = 10

local inWorld, enteredAt, leaving = false, 0, false

function Channel:Name()
    if not UnitFactionGroup then return nil end
    local ok, faction = pcall(UnitFactionGroup, "player")
    if not ok or TC.Chat.IsSecret(faction) then return nil end
    return NAMES[faction]
end

local function isOurs(name)
    if type(name) ~= "string" or TC.Chat.IsSecret(name) then return false end
    name = name:gsub("^%d+%.%s*", ""):lower()
    for _, n in pairs(NAMES) do
        if name == n:lower() then return true end
    end
    return false
end
Channel.IsOurs = isOurs

-- The channel's number while joined, else nil.
function Channel:Number()
    local name = self:Name()
    if not name or not GetChannelName then return nil end
    local ok, num = pcall(GetChannelName, name)
    if ok and type(num) == "number" and num > 0 then return num end
end

local function settings()
    return TC.db.settings
end

function Channel:Enabled()
    return not settings().noChannel
end

function Channel:Join()
    local name = self:Name()
    if not name or not self:Enabled() or self:Number() then return end
    local frameId = (DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.GetID and DEFAULT_CHAT_FRAME:GetID()) or 1
    local join = JoinPermanentChannel or JoinChannelByName
    if join then pcall(join, name, nil, frameId, false) end
    local add = (ChatFrameUtil and ChatFrameUtil.AddChannel) or ChatFrame_AddChannel
    if add and DEFAULT_CHAT_FRAME then pcall(add, DEFAULT_CHAT_FRAME, name) end
    if not settings().channelTold then
        settings().channelTold = true
        TC:Print("You joined the tavern channel |cffffd100%s|r: chat with other card players there. |cffffffff/tc channel off|r leaves it for good.", name)
    end
end

function Channel:Leave()
    local name = self:Name()
    settings().noChannel = true
    if name and LeaveChannelByName and self:Number() then
        leaving = true
        pcall(LeaveChannelByName, name)
        C_Timer.After(3, function() leaving = false end)
    end
end

-- Puts text in the chat box addressed to the channel (Forever: the player presses Enter).
function Channel:Say(text)
    local num = self:Number()
    if not num then return false end
    return TC.Chat:Insert(text, "/" .. num)
end

-- /tc channel [on | off]
function Channel:Command(arg)
    arg = (arg or ""):lower()
    if arg == "off" then
        self:Leave()
        TC:Print("Left the tavern channel. |cffffffff/tc channel on|r to join again.")
    elseif arg == "on" then
        settings().noChannel = nil
        self:Join()
        TC:Print("Tavern channel: %s.", self:Name() or "?")
    else
        local num = self:Number()
        if num then
            TC:Print("You are in the tavern channel |cffffd100%d. %s|r. Type |cffffffff/%d|r to talk there.", num, self:Name(), num)
        else
            TC:Print("You are not in the tavern channel. |cffffffff/tc channel on|r to join.")
        end
    end
end

TC:On("PLAYER_ENTERING_WORLD", function()
    inWorld, enteredAt = true, GetTime()
    C_Timer.After(JOIN_DELAY, function() TC:Safe("channel join", Channel.Join, Channel) end)
end)
TC:On("PLAYER_LEAVING_WORLD", function() inWorld = false end)
TC:On("CHAT_MSG_CHANNEL_NOTICE", function(notice, ...)
    -- Left by hand (/leave, the chat menu): remember it.
    local base = select(8, ...)
    if TC.Chat.IsSecret(notice) or notice ~= "YOU_LEFT" or leaving or not inWorld or GetTime() - enteredAt < 30 then
        return
    end
    if isOurs(base) and not settings().noChannel then
        settings().noChannel = true
        TC:Print("You left the tavern channel; it won't be joined again. |cffffffff/tc channel on|r to come back.")
    end
end)
