-- Line coverage for the headless test suite, with no dependencies (LuaJIT only):
--   luajit tests/coverage.lua [--min-total N] [--min Engine=N ...] [--report FILE]
--
-- Executable lines come from the compiled bytecode (jit.util: every instruction's source line, through
-- every nested function), hit lines from a debug line hook while tests/run.lua runs. Files counted:
-- everything the addon ships except generated data (Data/, Engine/Data/) and the bundled Libs/.
-- Exits non-zero when the tests fail or a minimum isn't met (CI gate).

local jutil = require("jit.util")
jit.off()   -- the line hook only sees interpreted code

local args = { ... }
local minTotal, minDir, reportPath = 0, {}, nil
local i = 1
while i <= #args do
    if args[i] == "--min-total" then
        minTotal = tonumber(args[i + 1]); i = i + 2
    elseif args[i] == "--min" then
        local dir, pct = args[i + 1]:match("^(.-)=(%d+%.?%d*)$")
        minDir[dir] = tonumber(pct); i = i + 2
    elseif args[i] == "--report" then
        reportPath = args[i + 1]; i = i + 2
    else
        error("unknown argument " .. args[i])
    end
end

-- The shipped Lua files, from the .toc.
local files = {}
for line in io.open("TavernCards.toc"):read("*a"):gmatch("[^\r\n]+") do
    local path = line:match("^([%w\\_%-/]+%.lua)%s*$")
    if path then
        path = path:gsub("\\", "/")
        if not path:match("^Data/") and not path:match("^Engine/Data/") and not path:match("^Libs/") then
            files[#files + 1] = path
        end
    end
end

-- Every line that holds an instruction, through nested functions.
local function executable(path)
    local lines = {}
    local fn = assert(loadfile(path))
    local function walk(f)
        local info = jutil.funcinfo(f)
        for pc = 1, (info.bytecodes or 0) - 1 do
            local at = jutil.funcinfo(f, pc)
            if at and at.currentline and at.currentline > 0 then lines[at.currentline] = true end
        end
        local k = -1
        while true do
            local child = jutil.funck(f, k)
            if child == nil then break end
            if type(child) == "proto" then walk(child) end
            k = k - 1
        end
    end
    walk(fn)
    -- A function's first line (its header) has no instruction of its own in the caller's sense.
    return lines
end

local hits = {}
local function hook(_, line)
    local src = debug.getinfo(2, "S").source
    if src:sub(1, 1) == "@" then
        local p = src:sub(2):gsub("^%./", "")
        local t = hits[p]
        if not t then t = {}; hits[p] = t end
        t[line] = true
    end
end

-- Run the suite under the hook; capture its exit status instead of exiting.
local status = 0
local realExit = os.exit
os.exit = function(code) status = code == true and 0 or (code or 0) error("__exit__") end
arg = {}   -- tests/run.lua reads arg[1] as a test filter

-- The parity replay spends most of its time decoding and comparing recorded states: test harness, not
-- addon code. The hook is switched off inside those, which makes the run several times faster.
package.path = "./?.lua;./tests/?.lua;" .. package.path
local function unhooked(t, name)
    local f = t[name]
    t[name] = function(...)
        debug.sethook()
        local r = { f(...) }
        debug.sethook(hook, "l")
        return unpack(r)
    end
end
local json, compare = require("tests.json"), require("tests.compare")
unhooked(json, "decode")
for name, f in pairs(compare) do
    if type(f) == "function" then unhooked(compare, name) end
end
debug.sethook(hook, "l")
local ok, err = pcall(dofile, "tests/run.lua")
debug.sethook()
os.exit = realExit
if not ok and not tostring(err):find("__exit__") then
    print("coverage: test run crashed: " .. tostring(err))
    status = 1
end

local total, covered = 0, 0
local byDir = {}
local rows = {}
for _, path in ipairs(files) do
    local ex = executable(path)
    local n, c = 0, 0
    local h = hits[path] or {}
    for line in pairs(ex) do
        n = n + 1
        if h[line] then c = c + 1 end
    end
    total, covered = total + n, covered + c
    local dir = path:match("^([^/]+)/") or "."
    byDir[dir] = byDir[dir] or { 0, 0 }
    byDir[dir][1], byDir[dir][2] = byDir[dir][1] + n, byDir[dir][2] + c
    rows[#rows + 1] = { path, n, c }
end

local function pct(c, n) return n > 0 and 100 * c / n or 100 end
local out = {}
out[#out + 1] = "| File | Lines | Covered | % |"
out[#out + 1] = "|---|---:|---:|---:|"
table.sort(rows, function(a, b) return a[1] < b[1] end)
for _, r in ipairs(rows) do
    out[#out + 1] = ("| %s | %d | %d | %.1f |"):format(r[1], r[2], r[3], pct(r[3], r[2]))
end
out[#out + 1] = ""
out[#out + 1] = "| Folder | % |"
out[#out + 1] = "|---|---:|"
local dirs = {}
for dir in pairs(byDir) do dirs[#dirs + 1] = dir end
table.sort(dirs)
for _, dir in ipairs(dirs) do
    out[#out + 1] = ("| %s | %.1f |"):format(dir, pct(byDir[dir][2], byDir[dir][1]))
end
out[#out + 1] = ""
out[#out + 1] = ("**Total: %.1f%%** (%d of %d lines)"):format(pct(covered, total), covered, total)
local text = table.concat(out, "\n")
print(text)
if reportPath then
    local f = assert(io.open(reportPath, "w"))
    f:write(text, "\n")
    f:close()
end

local failed = status ~= 0
if pct(covered, total) < minTotal then
    print(("coverage: total %.1f%% is below the minimum %.1f%%"):format(pct(covered, total), minTotal))
    failed = true
end
for dir, min in pairs(minDir) do
    local d = byDir[dir]
    if not d or pct(d[2], d[1]) < min then
        print(("coverage: %s %.1f%% is below the minimum %.1f%%"):format(dir, d and pct(d[2], d[1]) or 0, min))
        failed = true
    end
end
os.exit(failed and 1 or 0)
