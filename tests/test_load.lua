-- The whole addon, as the client loads it: every file in .toc order inside a permissive mock of the WoW
-- API, then the login events, then every tab, a deck, a practice match on the board, and a few slash
-- commands. Catches load-order mistakes, nil globals and errors on paths the unit tests don't take.
local T = {}

local mock
local registry = setmetatable({}, { __mode = "k" })
local METHODS = {
    GetWidth = function() return 100 end, GetHeight = function() return 100 end,
    GetLeft = function() return 0 end, GetBottom = function() return 0 end, GetRight = function() return 100 end,
    GetTop = function() return 100 end, GetCenter = function() return 50, 50 end,
    GetEffectiveScale = function() return 1 end, GetScale = function() return 1 end,
    GetFrameLevel = function() return 1 end, GetStringHeight = function() return 12 end,
    GetStringWidth = function() return 40 end, GetText = function() return "" end, GetID = function() return 1 end,
    GetSize = function() return 100, 100 end, GetNumPoints = function() return 0 end,
    IsShown = function(self) return rawget(self, "_shown") ~= false end,
    IsVisible = function(self) return rawget(self, "_shown") ~= false end,
    Show = function(self)
        local was = rawget(self, "_shown") ~= false
        rawset(self, "_shown", true)
        local s = registry[self]
        if not was and s and s.OnShow then s.OnShow(self) end
    end,
    Hide = function(self)
        local was = rawget(self, "_shown") ~= false
        rawset(self, "_shown", false)
        local s = registry[self]
        if was and s and s.OnHide then s.OnHide(self) end
    end,
    SetShown = function(self, on) if on then self:Show() else self:Hide() end end,
    SetScript = function(self, name, fn)
        registry[self] = registry[self] or {}
        registry[self][name] = fn
    end,
    HookScript = function(self, name, fn)
        registry[self] = registry[self] or {}
        local old = registry[self][name]
        registry[self][name] = function(...) if old then old(...) end fn(...) end
    end,
    GetScript = function(self, name) return registry[self] and registry[self][name] end,
    RegisterEvent = function(self, event) rawset(self, "_events", rawget(self, "_events") or {}) self._events[event] = true end,
    GetHighlightTexture = function() return mock() end,
    GetFontString = function() return mock() end,
    CreateFontString = function() return mock() end, CreateTexture = function() return mock() end,
    CreateMaskTexture = function() return mock() end, CreateLine = function() return mock() end,
    CreateAnimationGroup = function() return mock() end, CreateAnimation = function() return mock() end,
}
-- Unknown Capitalized members are "callable mocks": callable as a method (no-op) and indexable as a
-- child frame (f.Inset:Hide()), cached so a child keeps its state.
local callable
mock = function(name)
    local children = {}
    local o = setmetatable({}, { __index = function(_, k)
        if METHODS[k] then return METHODS[k] end
        if type(k) == "string" and k:match("^%u") then
            children[k] = children[k] or callable()
            return children[k]
        end
        return nil
    end })
    if name then _G[name] = o end
    return o
end

callable = function()
    local o = mock()
    return setmetatable(o, { __index = getmetatable(o).__index, __call = function() end })
end

local frames = {}
local function fire(event, ...)
    for _, f in ipairs(frames) do
        local s = registry[f]
        if s and s.OnEvent and rawget(f, "_events") and f._events[event] then s.OnEvent(f, event, ...) end
    end
end

local function apiTable()
    -- Any unknown member of a C_* namespace is a no-op function.
    return setmetatable({}, { __index = function() return function() end end })
end

local function setup()
    local clock = 100
    local timers = {}
    local G = {
        CreateFrame = function(_, name)
            local f = mock(name)
            frames[#frames + 1] = f
            return f
        end,
        UIParent = mock(), GameTooltip = mock("GameTooltip"), UIErrorsFrame = mock(), DEFAULT_CHAT_FRAME = mock(),
        ChatFrame1 = mock(), Minimap = mock(), ItemRefTooltip = mock(),
        UISpecialFrames = {}, CLASS_ICON_TCOORDS = { MAGE = { 0, 1, 0, 1 }, WARRIOR = { 0, 1, 0, 1 } },
        LOCALIZED_CLASS_NAMES_MALE = { MAGE = "Mage", WARRIOR = "Warrior" }, RAID_CLASS_COLORS = {},
        ITEM_QUALITY_COLORS = {}, SOUNDKIT = { READY_CHECK = 1 }, NUM_CHAT_WINDOWS = 1, CHAT_FRAMES = {},
        GetTime = function() return clock end, time = os.time, date = os.date,
        debugprofilestop = function() return clock * 1000 end, debugstack = function() return "" end,
        geterrorhandler = function() return error end, issecretvalue = function() return false end,
        wipe = function(t) for k in pairs(t) do t[k] = nil end return t end, tinsert = table.insert,
        hooksecurefunc = function() end, PlaySound = function() end, GetFileIDFromPath = function() return 1 end,
        UnitName = function() return "Tester", nil end, UnitFullName = function() return "Tester", "Realm" end,
        UnitClass = function() return "Mage", "MAGE" end, UnitFactionGroup = function() return "Alliance" end,
        UnitLevel = function() return 20 end, UnitIsPlayer = function() return false end,
        UnitIsUnit = function() return false end, InCombatLockdown = function() return false end,
        IsInGroup = function() return false end, IsInRaid = function() return false end, IsInGuild = function() return false end,
        IsInInstance = function() return false end, GetNormalizedRealmName = function() return "Realm" end,
        GetChannelName = function() return 0 end, GetNumGroupMembers = function() return 0 end,
        GetNumSubgroupMembers = function() return 0 end, IsModifiedClick = function() return false end,
        IsShiftKeyDown = function() return false end, Ambiguate = function(n) return n end,
        CreateColor = function() return {} end, CreateDataProvider = function()
            return setmetatable({ items = {} }, { __index = function(t, k)
                if k == "Insert" then return function(self, x) self.items[#self.items + 1] = x end end
                if k == "GetSize" then return function(self) return #self.items end end
                return function() end
            end })
        end,
        C_Timer = { After = function(d, fn) timers[#timers + 1] = { clock + d, fn } end,
            NewTicker = function() return mock() end },
        C_ChatInfo = apiTable(), C_QuestLog = { GetAllCompletedQuestIDs = function() return { 783, 7 } end },
        C_Map = apiTable(), C_Texture = apiTable(), C_AddOns = apiTable(), C_Item = apiTable(),
        Enum = {}, MenuUtil = { CreateContextMenu = function() end },
        ScrollUtil = apiTable(), CreateScrollBoxListLinearView = function() return mock() end,
        PanelTemplates_SetNumTabs = function() end, PanelTemplates_SelectTab = function() end,
        PanelTemplates_DeselectTab = function() end, PanelTemplates_TabResize = function() end,
        strsplit = function(sep, str, n)
            local out = {}
            for part in (str .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = part end
            return unpack(out)
        end,
        strtrim = function(x) return (x:gsub("^%s+", ""):gsub("%s+$", "")) end,
        SlashCmdList = {}, EventRegistry = mock(), ChatFrameUtil = apiTable(), ScrollingMessageFrame = mock(), YES = "Yes", NO = "No", OKAY = "Okay", CANCEL = "Cancel", CLOSE = "Close",
    }
    for k, v in pairs(G) do _G[k] = v end
    -- Any other WoW API function (Capitalized, not a CONSTANT) is a harmless no-op returning nothing.
    setmetatable(_G, { __index = function(_, k)
        if type(k) == "string" and k:match("^%u") and k:match("%l") and not k:match("^Lib") and not k:match("^TavernCards") then
            local v = callable()
            rawset(_G, k, v)
            return v
        end
    end })
    TavernCards_NS = nil
    return function(seconds)
        clock = clock + (seconds or 0.1)
        table.sort(timers, function(a, b) return a[1] < b[1] end)
        while timers[1] and timers[1][1] <= clock do
            local t = table.remove(timers, 1)
            t[2]()
        end
        for _, f in ipairs(frames) do
            local s = registry[f]
            if s and s.OnUpdate and rawget(f, "_shown") ~= false then s.OnUpdate(f, 0.1) end
        end
    end
end

local function loadAll()
    local toc = io.open("TavernCards.toc"):read("*a")
    local args = { "TavernCards", {} }
    for line in toc:gmatch("[^\r\n]+") do
        local path = line:match("^([%w\\_%-]+%.lua)%s*$")
        if path then
            local chunk = assert(loadfile((path:gsub("\\", "/"))))
            chunk(args[1], args[2])
        end
    end
    return TavernCards_NS
end

T.whole_addon_loads_and_runs = function()
    local tick = setup()
    local TC = loadAll()
    _G.TavernCardsDB, _G.TavernCardsCharDB = nil, nil
    fire("ADDON_LOADED", "TavernCards")
    fire("PLAYER_LOGIN")
    fire("PLAYER_ENTERING_WORLD", true, false)
    for _ = 1, 40 do tick(1) end
    assert(TC.db and TC.char, "SavedVariables bound")

    -- Every tab, the card book on a card, a deck in the editor.
    for _, key in ipairs({ "collection", "decks", "play", "ledger" }) do TC:ShowWindow(key) end
    TC:ShowCard("CS2_119")
    local deck = TC.Decks:Create("MAGE", "Test")
    TC.Decks:Fill(deck)
    TC:EditDeck(deck)
    TC:ShowWindow("decks")

    -- A practice match on the board, a few turns through the AI.
    assert(TC:StartPractice({ deck = "house:MAGE", opponent = "WARRIOR", difficulty = "novice" }))
    assert(TC.Board:IsShown())
    local rng = TC.Rng.new(3)
    for _ = 1, 400 do
        local eng = TC.Match:Engine()
        if not TC.Match:Active() then break end
        if eng:current_player() == 0 and not TC.Match.thinking then
            TC.Match:PlayerApply(TC.AI.choose(eng, "novice", rng))
        end
        tick(0.5)
    end
    TC.Match:Concede()
    tick(1)

    -- Slash commands.
    for _, cmd in ipairs({ "", "status", "collection", "who", "channel", "icons", "sound", "sound", "models", "models", "mat", "settings", "help", "play" }) do
        SlashCmdList.TAVERNCARDS(cmd)
    end
    setmetatable(_G, nil)
    assert(#(TavernCardsDB.errors or {}) == 0, "errors recorded: " .. tostring(TavernCardsDB.errors and TavernCardsDB.errors[1] and TavernCardsDB.errors[1].err))
end

return T
