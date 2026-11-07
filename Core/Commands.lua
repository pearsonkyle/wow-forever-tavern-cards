local TC = TavernCards_NS

local HELP = {
    "/tc        - open the card book (also: minimap button)",
    "/tc status - card data and engine build",
    "/tc minimap - show or hide the minimap button (reports its state)",
    "/tc probe  - report which UI templates, atlases, events and APIs this client has",
    "/tc rng    - run the RNG self-test (must match the reference engine)",
    "/tc collection - collection progress and dust",
    "/tc preview [cardId] - show a card toast without granting anything",
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
