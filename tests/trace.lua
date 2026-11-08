-- Replays tavern-trace recordings through the Lua engine and stops at the first divergence.
--
--   luajit tests/trace.lua FILE.jsonl[.xz] [more ...]
--
-- See tests/replay.lua. Exit 1 on a divergence.

package.path = "./?.lua;./tests/?.lua;" .. package.path
local replay = require("tests.replay")

TavernCards_NS = {}
local toc = io.open("TavernCards.toc"):read("*a")
for line in toc:gmatch("[^\r\n]+") do
    local path = line:match("^(Engine[\\/].-%.lua)%s*$") or line:match("^(Data[\\/].-%.lua)%s*$")
    if path then dofile((path:gsub("\\", "/"))) end
end
local TC = TavernCards_NS

local verbose = os.getenv("TRACE_VERBOSE")
local matches, steps = 0, 0
for _, file in ipairs(arg) do
    local ok, err, m, s = replay.file(TC, file, verbose)
    matches, steps = matches + m, steps + s
    if not ok then
        print(err)
        os.exit(1)
    end
end
print(("trace: %d match(es), %d step(s), no divergence"):format(matches, steps))
