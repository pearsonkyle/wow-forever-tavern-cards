-- The Lua engine against the C++ reference engine, on the committed traces (fixtures/traces, recorded
-- by tools/make_fixtures.py with jankcraft's engine): every legal-move list and every state must match.
package.path = "./?.lua;./tests/?.lua;" .. package.path
local replay = require("tests.replay")

local T = {}

T.committed_traces_match_the_cpp_engine = function(TC)
    local files = {}
    local pipe = io.popen("ls fixtures/traces/*.jsonl.xz 2>/dev/null")
    for f in pipe:lines() do files[#files + 1] = f end
    pipe:close()
    assert(#files > 0, "no fixtures/traces/*.jsonl.xz")
    local matches, steps = 0, 0
    for _, file in ipairs(files) do
        local ok, err, m, s = replay.file(TC, file)
        assert(ok, err)
        matches, steps = matches + m, steps + s
    end
    assert(matches >= 30 and steps >= 3000, ("only %d matches / %d steps replayed"):format(matches, steps))
end

return T
