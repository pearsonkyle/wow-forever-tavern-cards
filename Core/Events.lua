-- One event frame for the addon. Handlers register with TC:On(event, fn).
--
-- Forever dropped some Classic events, and registering an unknown one throws, so registration is
-- pcall'd and failures are remembered for the probe report.

local TC = TavernCards_NS

local frame = CreateFrame("Frame")
local handlers = {}
TC.missingEvents = {}

function TC:On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if not pcall(frame.RegisterEvent, frame, event) then
            TC.missingEvents[event] = true
        end
    end
    table.insert(handlers[event], fn)
end

-- Errors are kept (last 20, in TavernCardsDB.errors) as well as reported, because the default
-- error display is off for most players and a silent failure is otherwise invisible.
function TC:ReportError(where, err)
    local db = _G.TavernCardsDB
    if type(db) == "table" then
        db.errors = db.errors or {}
        table.insert(db.errors, { t = time(), where = where, err = tostring(err), stack = debugstack and debugstack(2, 6, 0) })
        while #db.errors > 20 do
            table.remove(db.errors, 1)
        end
    end
    geterrorhandler()(err)
end

local function traceback(e)
    return tostring(e) .. "\n" .. (debugstack and debugstack(2, 8, 0) or "")
end

-- Runs fn(...) and records any error, for UI scripts (clicks, menus) outside the event dispatcher.
function TC:Safe(where, fn, ...)
    local n, args = select("#", ...), { ... }
    local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, traceback)
    if not ok then
        TC:ReportError(where, err)
    end
    return ok
end

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then
        return
    end
    local n, args = select("#", ...), { ... }
    for i = 1, #list do
        local fn = list[i]
        local ok, err = xpcall(function() return fn(unpack(args, 1, n)) end, traceback)
        if not ok then
            TC:ReportError(event, err)
        end
    end
end)

TC:On("ADDON_LOADED", function(name)
    if name ~= TC.ADDON then
        return
    end
    TC:BindSavedVariables()
    TC:OnLoadedEngineCheck()
    if TC.OnLoaded then
        TC:OnLoaded()
    end
end)

TC:On("PLAYER_LOGIN", function()
    if TC.Compat then
        TC.Compat:Probe()
    end
    if TC.OnLogin then
        TC:OnLogin()
    end
end)
