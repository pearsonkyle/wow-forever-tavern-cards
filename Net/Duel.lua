-- Duels between players: a handshake that agrees on decks and a fair seed, then lockstep play.
--
-- Both clients run the same deterministic engine. Nothing but move numbers travels: whoever decides
-- sends the index of the legal move they took, the other side applies the same move and compares a
-- fingerprint of the resulting state (Match.StateHash); any difference voids the match (desync).
--
-- Handshake (the challenger is seat 0):
--   CH id proto rules class      challenge
--   AC id class | DE id why      accept / decline (busy, version, declined)
--   CM id commit                 sha256(nonce .. deckcode), from both sides
--   RV id nonce deckcode         reveal, once both commitments are in; each side checks the other's
-- The seed is sha256(challenger nonce .. accepter nonce): neither side can pick it, and the decks are
-- fixed before either nonce is known.
-- Play:
--   MV id n index hash           move number n (0-based) was legal-move `index`, state after = hash
--   AK id n                      "I have moves up to n"; unacknowledged moves are resent every few seconds
--   SY id n                      "I have n moves": the other side resends what's missing
--   CC id                        conceded       PI id n / PO id n   keep-alive with move counts
--   AB id why                    abandon (bad deck, desync)
--
-- Transport: addon messages on the TCDuel prefix: to the party/raid when the opponent is in your group
-- (that reaches WoW: Forever's connected realms), else a whisper (same realm only).

local TC = TavernCards_NS
local Match = TC.Match

local Duel = {}
TC.Duel = Duel

local PREFIX = "TCDuel"
local PROTO = "1"
local CHALLENGE_TIMEOUT = 35
local PING_EVERY, SILENT_WARN, SILENT_CLAIM = 20, 75, 180

local pending          -- the handshake in progress: { id, peer, role, state, nonce, code, commit, peerCommit, ... }
local lastHeard = 0
local listeners = {}

function Duel:Subscribe(fn)
    listeners[#listeners + 1] = fn
end

local function notify(...)
    for _, fn in ipairs(listeners) do TC:Safe("duel listener", fn, ...) end
end

-- ---- names and routes --------------------------------------------------------------------------

local function realm()
    return (GetNormalizedRealmName and GetNormalizedRealmName()) or ""
end

function Duel.FullName(name)
    if not name or TC.Chat.IsSecret(name) then return nil end
    name = name:gsub("%s", "")
    if name:find("-", 1, true) then return name end
    local r = realm()
    return r ~= "" and (name .. "-" .. r) or name
end
local full = Duel.FullName

function Duel.Me()
    local name, r = UnitFullName("player")
    if not name then return nil end
    return name .. "-" .. ((r and r ~= "") and r or realm())
end

local function same(a, b)
    return a and b and full(a):lower() == full(b):lower()
end

-- In my group? Then the group channel reaches them on any realm.
local function groupChannel(name)
    if not (IsInGroup and IsInGroup()) then return nil end
    local raid = IsInRaid and IsInRaid()
    local n = raid and GetNumGroupMembers() or (GetNumSubgroupMembers and GetNumSubgroupMembers() or 0)
    for i = 1, n do
        local unit = raid and ("raid" .. i) or ("party" .. i)
        local uname, urealm = UnitName(unit)
        if uname and same(urealm and urealm ~= "" and (uname .. "-" .. urealm) or uname, name) then
            return raid and "RAID" or "PARTY"
        end
    end
end
Duel.GroupChannel = groupChannel

-- ---- sending: a small queue, so a burst (a resync) doesn't hit the throttle -----------------------

local queue, sending = {}, false
Duel.transport = function(text, chatType, target)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, chatType, target)
    -- Older clients return nothing/true; newer an Enum.SendAddonMessageResult (0 = success).
    return ok and (result == nil or result == true or result == 0)
end

local function pump()
    local item = queue[1]
    if not item then
        sending = false
        return
    end
    local chan = groupChannel(item.to)
    local ok = Duel.transport(item.text, chan or "WHISPER", not chan and item.to or nil)
    if ok or item.tries >= 5 then
        table.remove(queue, 1)
    else
        item.tries = item.tries + 1
    end
    C_Timer.After(ok and 0.12 or 1, pump)
end

local function send(to, ...)
    queue[#queue + 1] = { to = to, text = table.concat({ ... }, "\t"), tries = 0 }
    if not sending then
        sending = true
        pump()
    end
end
Duel.Send = send

-- ---- handshake ---------------------------------------------------------------------------------

local function nonce()
    local parts = {}
    for i = 1, 4 do parts[i] = ("%08x"):format(math.random(0, 0x7fffffff)) end
    return table.concat(parts) .. ("%x"):format(math.floor(GetTime() * 1000) % 0x7fffffff)
end

local function newId()
    return ("%x%04x"):format(time() % 0xffffff, math.random(0, 0xffff))
end

function Duel:Busy()
    return pending ~= nil or Match:Active()
end

function Duel:Pending()
    return pending
end

-- The deck you'd play: the Play tab's choice (TC:ChosenDeck in UI/PlayPanel.lua).
local function myDeck()
    local deck = TC.ChosenDeck and TC:ChosenDeck()
    if not deck then return nil, "Choose a deck in the Play tab first." end
    if not tostring(deck.id):find("^house:") and not TC.Decks:IsReady(deck) then
        return nil, ("Your deck isn't ready: %s."):format(table.concat(TC.Decks:Problems(deck), "; "))
    end
    return deck
end

function Duel:Challenge(target)
    target = full(target)
    if not target then return TC:Print("Challenge whom? Target a player or type /tc duel Name.") end
    if same(target, Duel.Me()) then return TC:Print("You can't duel yourself.") end
    if self:Busy() then return TC:Print("Finish your current match or challenge first.") end
    if InCombatLockdown and InCombatLockdown() then return TC:Print("Not in combat.") end
    local deck, why = myDeck()
    if not deck then return TC:Print(why) end
    pending = { id = newId(), peer = target, role = "challenger", state = "sent", deck = deck, t = GetTime() }
    send(target, "CH", pending.id, PROTO, TC.RULES_VERSION or "?", deck.class, deck.back or "")
    TC:Print("Challenge sent to %s. Waiting for an answer...%s", Ambiguate and Ambiguate(target, "short") or target,
        groupChannel(target) and "" or " (not in your group: this only reaches players on your realm; invite them to a party to duel across realms)")
    notify("pending")
    C_Timer.After(CHALLENGE_TIMEOUT, function()
        if pending and pending.state == "sent" and pending.peer == target then
            TC:Print("%s didn't answer the challenge.", target)
            pending = nil
            notify("pending")
        end
    end)
end

local function cancel(why, tell)
    if pending and tell then send(pending.peer, "DE", pending.id, why or "cancelled") end
    pending = nil
    notify("pending")
end

function Duel:Cancel()
    cancel("cancelled", true)
end

local function sendCommit()
    pending.nonce = nonce()
    pending.code = TC.Decks:Encode(pending.deck)
    pending.commit = TC.Sha256(pending.nonce .. pending.code)
    send(pending.peer, "CM", pending.id, pending.commit)
    pending.state = "committed"
end

local function maybeReveal()
    if pending and pending.commit and pending.peerCommit and not pending.revealed then
        pending.revealed = true
        send(pending.peer, "RV", pending.id, pending.nonce, pending.code)
    end
end

local function deckFromCode(code)
    local parsed = TC.Decks:Decode(code)
    if not parsed or TC.Decks:Count(parsed) ~= 30 then return nil end
    return parsed, TC.Decks:CardList(parsed)
end

local function maybeStart()
    if not (pending and pending.peerNonce and pending.revealed) then return end
    local mine = { TC.Decks:CardList(pending.deck), pending.deck.class }
    local theirs = { pending.peerCards, pending.peerClass }
    local challenger = pending.role == "challenger"
    local a, b = challenger and mine or theirs, challenger and theirs or mine
    local seedHex = TC.Sha256((challenger and pending.nonce or pending.peerNonce) .. (challenger and pending.peerNonce or pending.nonce))
    local record = {
        matchId = pending.id, seed = { tonumber(seedHex:sub(1, 8), 16), tonumber(seedHex:sub(9, 16), 16) },
        decks = { a[1], b[1] }, classes = { a[2], b[2] }, mySeat = challenger and 0 or 1,
        opponent = { name = pending.peer, class = pending.peerClass, duel = true }, deckName = pending.deck.name,
        backs = challenger and { pending.deck.back, pending.peerBack } or { pending.peerBack, pending.deck.back },
    }
    for i = 1, 2 do
        local b = record.backs[i]
        if not (TC.CardBacks and type(b) == "string" and TC.CardBacks:Valid(b)) then
            record.backs[i] = TC.CardBacks and TC.CardBacks.DEFAULT or "tavern"
        end
    end
    local peer = pending.peer
    pending = nil
    notify("pending")
    lastHeard = GetTime()
    if Match:StartDuel(record) then
        TC:Print("Duel with %s begins!", Ambiguate and Ambiguate(peer, "short") or peer)
        if TC.Board then TC.Board:Open() end
    else
        send(peer, "AB", record.matchId, "deck")
        TC:Print("The duel couldn't start: a deck was refused.")
    end
end

local function incomingChallenge(sender, id, proto, rules, class)
    if proto ~= PROTO or rules ~= (TC.RULES_VERSION or "?") then
        send(sender, "DE", id, "version")
        TC:Print("%s challenged you, but your Tavern Cards versions differ. Both of you should update.", sender)
        return
    end
    if Duel:Busy() or (InCombatLockdown and InCombatLockdown()) then
        send(sender, "DE", id, "busy")
        return
    end
    local deck, why = myDeck()
    local short = Ambiguate and Ambiguate(sender, "short") or sender
    local cls = (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class]) or class
    pending = { id = id, peer = sender, role = "accepter", state = "asked", t = GetTime(), peerClass = class }
    notify("pending")
    if TC.Art then TC.Art:Play("READY_CHECK") end
    local text = ("%s challenges you to a Tavern Cards duel (%s deck).\n\n%s"):format(short, cls or "?",
        deck and ("You'll play: |cffffd100%s|r"):format(deck.name) or ("|cffff6060" .. why .. "|r"))
    TC:Confirm(text, function()
        if not pending or pending.id ~= id then return end
        local d, reason = myDeck()
        if not d then
            TC:Print(reason)
            cancel("nodeck", true)
            return
        end
        pending.deck = d
        pending.state = "accepted"
        send(sender, "AC", id, d.class, d.back or "")
        sendCommit()
        maybeReveal()
    end, function()
        if pending and pending.id == id then cancel("declined", true) end
    end, "Accept", "Decline", 30)
end

-- ---- playing -----------------------------------------------------------------------------------

local handlers_AK

-- Sent moves wait for the opponent's AK; until then they are resent (a lost message, a /reload).
local unacked = {}   -- [n] = { matchId, peer, index, hash, tries }
local RESEND_AFTER, RESEND_TRIES = 3, 20

local function retry(n)
    local u = unacked[n]
    if not u then return end
    if u.tries >= RESEND_TRIES then
        unacked[n] = nil
        return
    end
    u.tries = u.tries + 1
    send(u.peer, "MV", u.matchId, tostring(n), tostring(u.index), u.hash or "")
    C_Timer.After(RESEND_AFTER, function() retry(n) end)
end

function Duel:SendMove(matchId, n, index, hash)
    local record = Match:Record()
    local peer = record and record.opponent and record.opponent.name or self.lastPeer
    if not peer or not matchId then return end
    unacked[n] = { matchId = matchId, peer = peer, index = index, hash = hash, tries = 0 }
    retry(n)
end

handlers_AK = function(sender, id, n)
    n = tonumber(n) or -1
    for k, u in pairs(unacked) do
        if u.matchId == id and k <= n then unacked[k] = nil end
    end
end

function Duel:SendConcede()
    local record = Match:Record()
    if record and record.kind == "duel" then send(record.opponent.name, "CC", record.matchId) end
end

-- The record of a duel that just ended (it's no longer Match:Record()): a final move can still go out.
function Duel:MatchEnded(record)
    if record then self.lastPeer, self.lastMatchId = record.opponent.name, record.matchId end
end

local function resend(record, from)
    for n = from, #record.moves - 1 do
        send(record.opponent.name, "MV", record.matchId, tostring(n), tostring(record.moves[n + 1]), "")
    end
end

local function void(record, why)
    TC:Print("The duel was voided: %s.", why)
    send(record.opponent.name, "AB", record.matchId, why)
    Match:EndLocally(Match.mySeat or 0, TC.EngineDefs.REASON.ABANDONED)
end

local function onMove(record, n, index, hash)
    local have = #record.moves
    if n < have then                                  -- a move we already have (a resend): say so again
        send(record.opponent.name, "AK", record.matchId, tostring(have - 1))
        return
    end
    if n > have then                                  -- we missed some: ask for them
        send(record.opponent.name, "SY", record.matchId, tostring(have))
        return
    end
    local engine = Match:Engine()
    if engine:current_player() == (Match.mySeat or 0) then
        -- It's our decision by our state; the peer is ahead of us or confused.
        return void(record, "the two games disagree on whose turn it is")
    end
    if not Match:Apply(index) then
        return void(record, "a move from the opponent was illegal here")
    end
    if hash and hash ~= "" and Match:Engine() and Match.StateHash(Match:Engine()) ~= hash then
        return void(record, "the two games drifted apart (desync)")
    end
    send(record.opponent.name, "AK", record.matchId, tostring(n))
end

-- ---- receiving ---------------------------------------------------------------------------------

local handlers = {}

function handlers.CH(sender, id, proto, rules, class, back)
    incomingChallenge(sender, id, proto, rules, class)
    if pending and pending.id == id then pending.peerBack = back end
end

function handlers.AC(sender, id, class, back)
    if not (pending and pending.id == id and same(pending.peer, sender) and pending.state == "sent") then return end
    pending.peerClass, pending.peerBack = class, back
    pending.state = "accepted"
    sendCommit()
    maybeReveal()
end

function handlers.DE(sender, id, why)
    if not (pending and pending.id == id and same(pending.peer, sender)) then return end
    local msg = { busy = "%s is busy right now.", version = "%s has a different version of Tavern Cards.",
        declined = "%s declined your challenge.", nodeck = "%s has no deck ready.", cancelled = "%s cancelled the duel." }
    TC:Print(msg[why] or "%s can't duel right now.", Ambiguate and Ambiguate(sender, "short") or sender)
    pending = nil
    notify("pending")
end

function handlers.CM(sender, id, commit)
    if not (pending and pending.id == id and same(pending.peer, sender)) then return end
    pending.peerCommit = commit
    maybeReveal()
end

function handlers.RV(sender, id, peerNonce, code)
    if not (pending and pending.id == id and same(pending.peer, sender) and pending.peerCommit) then return end
    if TC.Sha256(peerNonce .. code) ~= pending.peerCommit then
        send(sender, "AB", id, "commit")
        TC:Print("The duel was cancelled: the opponent's deck didn't match their commitment.")
        pending = nil
        return notify("pending")
    end
    local parsed, cards = deckFromCode(code)
    if not parsed then
        send(sender, "AB", id, "deck")
        TC:Print("The duel was cancelled: the opponent's deck isn't a legal 30-card deck for this version.")
        pending = nil
        return notify("pending")
    end
    pending.peerNonce, pending.peerCards, pending.peerClass = peerNonce, cards, parsed.class
    maybeStart()
end

local function inMatch(sender, id)
    local record = Match:Record()
    if record and record.kind == "duel" and record.matchId == id and same(record.opponent.name, sender) then
        lastHeard = GetTime()
        return record
    end
end

function handlers.MV(sender, id, n, index, hash)
    local record = inMatch(sender, id)
    if record then
        onMove(record, tonumber(n) or -1, tonumber(index) or 0, hash)
    elseif id == Duel.lastMatchId and same(sender, Duel.lastPeer) then
        -- The match already ended here (we made the last move): just acknowledge the resend.
        send(sender, "AK", id, tostring(n))
    end
end

function handlers.AK(sender, id, n)
    handlers_AK(sender, id, n)
end

function handlers.SY(sender, id, n)
    local record = inMatch(sender, id)
    if record then resend(record, tonumber(n) or 0) end
end

function handlers.CC(sender, id)
    local record = inMatch(sender, id)
    if record then
        TC:Print("%s conceded.", Ambiguate and Ambiguate(sender, "short") or sender)
        Match:EndLocally(1 - (Match.mySeat or 0), TC.EngineDefs.REASON.CONCEDE)
    end
end

function handlers.AB(sender, id, why)
    if pending and pending.id == id and same(pending.peer, sender) then
        TC:Print("The duel was cancelled (%s).", why or "?")
        pending = nil
        return notify("pending")
    end
    local record = inMatch(sender, id)
    if record then
        TC:Print("The duel was voided by the opponent (%s).", why or "?")
        Match:EndLocally(Match.mySeat or 0, TC.EngineDefs.REASON.ABANDONED)
    end
end

function handlers.PI(sender, id, n)
    local record = inMatch(sender, id)
    if not record then return end
    send(sender, "PO", id, tostring(#record.moves))
    n = tonumber(n) or 0
    if n < #record.moves then resend(record, n) end
end

function handlers.PO(sender, id, n)
    local record = inMatch(sender, id)
    if record and (tonumber(n) or 0) < #record.moves then resend(record, tonumber(n)) end
end

function Duel:Receive(text, sender)
    if type(text) ~= "string" or TC.Chat.IsSecret(text) then return end
    sender = full(sender)
    if not sender or same(sender, Duel.Me()) then return end
    local parts = {}
    for part in (text .. "\t"):gmatch("([^\t]*)\t") do parts[#parts + 1] = part end
    local fn = handlers[parts[1]]
    if fn and #parts <= 8 then
        fn(sender, unpack(parts, 2))
    end
end

-- Seconds since the opponent was last heard from (0 when it's not their move).
function Duel:Silence()
    local record = Match:Record()
    if not (record and record.kind == "duel" and Match:Active()) then return 0 end
    if Match:Engine():current_player() == (Match.mySeat or 0) then return 0 end
    return GetTime() - lastHeard
end

-- The opponent vanished: after SILENT_CLAIM seconds you may claim the win.
function Duel:ClaimWin()
    if self:Silence() < SILENT_CLAIM then return false end
    local record = Match:Record()
    send(record.opponent.name, "AB", record.matchId, "timeout")
    Match:EndLocally(1 - (Match.mySeat or 0), TC.EngineDefs.REASON.ABANDONED)
    return true
end
Duel.SILENT_WARN, Duel.SILENT_CLAIM = SILENT_WARN, SILENT_CLAIM

TC:On("CHAT_MSG_ADDON", function(prefix, text, _, sender)
    if prefix == PREFIX then Duel:Receive(text, sender) end
end)

TC:On("PLAYER_LOGIN", function()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
    end
    lastHeard = GetTime()
    -- Keep-alive and catch-up while a duel runs (also right after a /reload: SY asks for missed moves).
    C_Timer.After(5, function()
        local record = Match:Record()
        if record and record.kind == "duel" then send(record.opponent.name, "SY", record.matchId, tostring(#record.moves)) end
    end)
    if C_Timer.NewTicker then
        C_Timer.NewTicker(PING_EVERY, function()
            local record = Match:Record()
            if record and record.kind == "duel" and Match:Active() then
                send(record.opponent.name, "PI", record.matchId, tostring(#record.moves))
            end
        end)
    end
end)
