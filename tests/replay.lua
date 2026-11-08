-- Replays tavern-trace recordings (C++ engine) through the Lua engine: same decks and seed, then per
-- step the legal moves must match the C++ list and, after the recorded move, the full state must match
-- the C++ snapshot. Used by tests/trace.lua (CLI) and tests/test_parity.lua (the committed fixtures).
--   local replay = require("tests.replay")
--   local ok, err, matches, steps = replay.file(TC, "x.jsonl" or "x.jsonl.xz")

local json = require("tests.json")
local compare = require("tests.compare")

local M = {}

local function describe(engine)
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

local function lines(file)
    if file:match("%.xz$") then
        local pipe = assert(io.popen("xz -dc '" .. file .. "'"))
        return pipe:lines(), pipe
    end
    return io.lines(file)
end

function M.file(TC, file, verbose)
    local E = TC.Engine
    local engine
    local lineNo, matches, steps = 0, 0, 0
    local iter, pipe = lines(file)
    local function fail(where, detail)
        if pipe then pipe:close() end
        return false, ("DIVERGENCE %s %s\n  %s\n%s"):format(file, where, detail, engine and describe(engine) or ""),
            matches, steps
    end
    for line in iter do
        lineNo = lineNo + 1
        local rec = json.decode(line)
        if rec.t == "match" then
            matches = matches + 1
            engine = E.create(rec.decks[1], rec.decks[2], rec.seed)
            if not engine then return fail("match " .. rec.seed, "E.create refused the decks") end
            engine:set_class(0, rec.families[1])
            engine:set_class(1, rec.families[2])
            engine:set_hero_power(0, E.heroPowerFor(rec.families[1]))
            engine:set_hero_power(1, E.heroPowerFor(rec.families[2]))
            if rec.state then
                local d = compare.state(rec.state, engine)
                if d then return fail("seed " .. rec.seed .. " setup", d) end
            end
            if verbose then print("match seed " .. rec.seed) end
        elseif rec.t == "step" then
            steps = steps + 1
            local where = ("line %d ply %d"):format(lineNo, rec.ply)
            local d = compare.moves(rec.moves, engine:legal_moves())
            if d then return fail(where, d) end
            local chosen = rec.moves[rec.chosen + 1]
            if verbose then print(where .. " " .. chosen.desc) end
            local ok, err = pcall(engine.apply_move, engine, rec.chosen + 1)
            if not ok then return fail(where .. " applying '" .. chosen.desc .. "'", "Lua error: " .. tostring(err)) end
            if not err then
                return fail(where .. " applying '" .. chosen.desc .. "'", "Lua refused: " .. tostring(engine.last_error))
            end
            if rec.state then
                d = compare.state(rec.state, engine)
                if d then return fail(where .. " after '" .. chosen.desc .. "'", d) end
            end
        elseif rec.t == "end" then
            if engine:end_reason() ~= rec.reason then
                return fail("end", "reason cpp=" .. rec.reason .. " lua=" .. engine:end_reason())
            end
        end
    end
    if pipe then pipe:close() end
    return true, nil, matches, steps
end

return M
