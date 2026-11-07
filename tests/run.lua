-- Headless test runner (LuaJIT, run from the repo root):  luajit tests/run.lua [filter]
--
-- Loads Engine/ the way the .toc would, then runs every tests/test_*.lua whose name contains the
-- optional filter. A test file returns a table of name -> function; a failing assert fails it.

package.path = "./?.lua;" .. package.path

local filter = arg[1]

local function load_engine()
    TavernCards_NS = {}
    local toc = io.open("TavernCards.toc"):read("*a")
    for line in toc:gmatch("[^\r\n]+") do
        local path = line:match("^(Engine[\\/].-%.lua)%s*$") or line:match("^(Data[\\/].-%.lua)%s*$")
        if path then
            dofile((path:gsub("\\", "/")))
        end
    end
    return TavernCards_NS
end

local files = {}
local pipe = io.popen("ls tests/test_*.lua 2>/dev/null")
for f in pipe:lines() do
    if not filter or f:find(filter, 1, true) then
        files[#files + 1] = f
    end
end
pipe:close()

local passed, failed = 0, 0
for _, file in ipairs(files) do
    local TC = load_engine()
    local suite = dofile(file)
    local names = {}
    for name in pairs(suite) do
        names[#names + 1] = name
    end
    table.sort(names)
    for _, name in ipairs(names) do
        local ok, err = pcall(suite[name], TC)
        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print(("FAIL %s :: %s\n     %s"):format(file, name, tostring(err)))
        end
    end
end

print(("tests: %d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
