local TC = TavernCards_NS

local HELP = {
    "/tc status - card data and engine build",
    "/tc probe  - report which UI templates, atlases, events and APIs this client has",
    "/tc rng    - run the RNG self-test (must match the reference engine)",
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

SLASH_TAVERNCARDS1 = "/tc"
SLASH_TAVERNCARDS2 = "/tavern"
SlashCmdList.TAVERNCARDS = function(msg)
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()
    if commands[cmd] then
        commands[cmd](rest)
    else
        TC:Print("v%s", TC.VERSION)
        for _, line in ipairs(HELP) do
            DEFAULT_CHAT_FRAME:AddMessage("  " .. line)
        end
    end
end
