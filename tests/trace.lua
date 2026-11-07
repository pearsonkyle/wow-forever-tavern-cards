-- Replays tavern-trace recordings through the Lua engine and stops at the first divergence.
--
--   luajit tests/trace.lua FILE.jsonl [more.jsonl ...]
--
-- Every match: same decks and seed; then per step the legal moves must match the C++ list and, after
-- applying the recorded index, the full state must match the C++ snapshot. Exit 1 on a divergence.

package.path = "./?.lua;./tests/?.lua;" .. package.path
local json = require("tests.json")
local compare = require("tests.compare")

TavernCards_NS = {}
local toc = io.open("TavernCards.toc"):read("*a")
for line in toc:gmatch("[^\r\n]+") do
    local path = line:match("^(Engine[\\/].-%.lua)%s*$") or line:match("^(Data[\\/].-%.lua)%s*$")
    if path then dofile((path:gsub("\\", "/"))) end
end
local TC = TavernCards_NS
local E = TC.Engine

local verbose = os.getenv("TRACE_VERBOSE")
local matches, steps = 0, 0

local function describe(engine, cppState)
    local lines = {}
    for seat = 0, 1 do
        local p = engine.state.players[seat + 1]
        local board = {}
        for _, id in ipairs(engine:board_ids(seat)) do
            local e = engine:ent(id)
            board[#board + 1] = ("%d:%s %d/%d"):format(id, e.card_id, e.attack, e.health)
        end
        local hero = engine:hero_of(seat)
        lines[#lines + 1] = ("  seat %d hero %d/%d mana %d/%d board %s"):format(seat, hero.health, hero.armor, p.mana,
            p.max_mana, table.concat(board, ", "))
    end
    return table.concat(lines, "\n")
end

local function fail(file, where, detail, engine)
    print(("DIVERGENCE %s %s\n  %s"):format(file, where, detail))
    if engine then print(describe(engine)) end
    os.exit(1)
end

for _, file in ipairs(arg) do
    local engine, lastMoves
    local lineNo = 0
    for line in io.lines(file) do
        lineNo = lineNo + 1
        local rec = json.decode(line)
        if rec.t == "match" then
            matches = matches + 1
            engine = E.create(rec.decks[1], rec.decks[2], rec.seed)
            if not engine then fail(file, "match " .. rec.seed, "E.create refused the decks") end
            engine:set_class(0, rec.families[1])
            engine:set_class(1, rec.families[2])
            engine:set_hero_power(0, E.heroPowerFor(rec.families[1]))
            engine:set_hero_power(1, E.heroPowerFor(rec.families[2]))
            if rec.state then
                local d = compare.state(rec.state, engine)
                if d then fail(file, "seed " .. rec.seed .. " setup", d, engine) end
            end
            if verbose then print("match seed " .. rec.seed) end
        elseif rec.t == "step" then
            steps = steps + 1
            local where = ("line %d ply %d"):format(lineNo, rec.ply)
            local moves = engine:legal_moves()
            local d = compare.moves(rec.moves, moves)
            if d then fail(file, where, d, engine) end
            local chosen = rec.moves[rec.chosen + 1]
            if verbose then print(where .. " " .. chosen.desc) end
            local ok, err = pcall(engine.apply_move, engine, rec.chosen + 1)
            if not ok then fail(file, where .. " applying '" .. chosen.desc .. "'", "Lua error: " .. tostring(err), engine) end
            if not err then
                fail(file, where .. " applying '" .. chosen.desc .. "'", "Lua refused: " .. tostring(engine.last_error), engine)
            end
            if rec.state then
                d = compare.state(rec.state, engine)
                if d then fail(file, where .. " after '" .. chosen.desc .. "'", d, engine) end
            end
        elseif rec.t == "end" then
            if engine:end_reason() ~= rec.reason then
                fail(file, "end", "reason cpp=" .. rec.reason .. " lua=" .. engine:end_reason(), engine)
            end
        end
    end
end
print(("trace: %d match(es), %d step(s), no divergence"):format(matches, steps))
