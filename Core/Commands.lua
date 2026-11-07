local TC = TavernCards_NS

local HELP = {
    "/tc        - open the card book (also: minimap button)",
    "/tc play   - return to your match, or open the Play tab",
    "/tc channel [on|off] - the tavern chat channel",
    "/tc who    - other Tavern Cards players online",
    "/tc status - card data and engine build",
    "/tc minimap - show or hide the minimap button (reports its state)",
    "/tc probe  - report which UI templates, atlases, events and APIs this client has",
    "/tc rng    - run the RNG self-test (must match the reference engine)",
    "/tc collection - collection progress and dust",
    "/tc preview [cardId] - show a card toast without granting anything",
    "/tc reset  - start the collection over (asks to confirm)",
}

local commands = {}

function commands.status()
    local total, playable, ready = #TC.CardOrder, 0, 0
    for id, card in pairs(TC.Cards) do
        if bit.band(card.flags, 8) ~= 0 then
            playable = playable + 1
            if TC.PlayableNow[id] then
                ready = ready + 1
            end
        end
    end
    TC:Print("v%s, rules %s: %d cards known, %d collectible, %d playable in this build.",
        TC.VERSION, TC.RULES_VERSION, total, playable, ready)
end

function commands.play()
    if TC.Match:Active() then
        TC.Board:Open()
    else
        TC:ShowWindow("play")
    end
end

function commands.channel(arg)
    TC.Channel:Command(arg)
end

function commands.who()
    local list = TC.Presence:Online()
    if TC.Presence:AskWho() then
        TC:Print("Asking the tavern who is around... try again in a few seconds for the full list.")
    end
    if #list == 0 then
        TC:Print("No other Tavern Cards players heard from yet.")
        return
    end
    TC:Print("%d Tavern Cards player(s) online:", #list)
    for i = 1, math.min(#list, 20) do
        local p = list[i]
        DEFAULT_CHAT_FRAME:AddMessage(("  %s  |cffaaaaaa%d cards, %d wins|r"):format(p.name, p.collected or 0, p.wins or 0))
    end
end

function commands.probe()
    TC.Compat:Probe()
    TC.Compat:Report()
    TC:Print("Saved to TavernCardsDB.probe (written on logout or /reload).")
end

function commands.rng()
    local ok, err = TC.Rng.selfTest()
    if ok then
        TC:Print("RNG self-test |cff40ff40ok|r (16 reference draws match).")
    else
        TC:Print("RNG self-test |cffff4040FAILED|r: %s", err)
    end
end

function commands.minimap(arg)
    local M = TC.MinimapButton
    if arg == "own" then
        -- Force the hand-made button (if the library one misbehaves).
        TC.db.settings.minimap.forceOwn = true
        TC:Print("Using the built-in minimap button after the next /reload.")
        return
    end
    M:SetHidden(not TC.db.settings.minimap.hide)
    TC:Print("Minimap button %s.", TC.db.settings.minimap.hide and "hidden" or "shown")
    M:Report()
end

function commands.collection()
    local owned, total, copies = TC.Collection:Stats()
    TC:Print("%d of %d cards collected (%d copies), %d dust.", owned, total, copies, TC.db.dust)
    local ledger = TC.db.ledger
    for i = math.max(1, #ledger - 4), #ledger do
        local e = ledger[i]
        DEFAULT_CHAT_FRAME:AddMessage(("  %s  %s"):format(TC.Art:ColoredName(e.c), TC.Collection:EntrySource(e)))
    end
end

function commands.reset(arg)
    if arg ~= "confirm" then
        TC:Print("This wipes your whole card collection, dust and ledger, and every character re-earns its completed quests on its next login. Type |cffffffff/tc reset confirm|r to do it.")
        return
    end
    TC:ResetCollection()
    TC:Print("Collection reset. |cffffffff/reload|r to re-run your journey.")
end

function commands.preview(id)
    if id == "" then
        id = TC.CardOrder[math.random(#TC.CardOrder)]
    end
    if not TC.Cards[id] then
        TC:Print("Unknown card id '%s'.", id)
        return
    end
    TC.Toast:Preview(id)
end

SLASH_TAVERNCARDS1 = "/tc"
SLASH_TAVERNCARDS2 = "/tavern"
SlashCmdList.TAVERNCARDS = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if cmd == "" then
        TC:ToggleWindow()
    elseif commands[cmd] then
        commands[cmd](rest)
    else
        TC:Print("v%s", TC.VERSION)
        for _, line in ipairs(HELP) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
        end
    end
end
