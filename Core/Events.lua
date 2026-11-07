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

frame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then
        return
    end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            geterrorhandler()(err)
        end
    end
end)

TC:On("ADDON_LOADED", function(name)
    if name ~= TC.ADDON then
        return
    end
    TC:BindSavedVariables()
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
