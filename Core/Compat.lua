-- What this client actually has. Forever is a Retail engine running Classic content, and other
-- addons show that templates, atlases, events and APIs differ from both, so the UI asks Compat
-- instead of assuming. Results are cached per session and written to TavernCardsDB.probe so they
-- can be read from the SavedVariables file outside the game.

local TC = TavernCards_NS

local Compat = { templates = {}, atlases = {}, apis = {}, events = {}, files = {} }
TC.Compat = Compat

local TEMPLATES = {
    "PortraitFrameTemplate", "ButtonFrameTemplate", "BasicFrameTemplateWithInset", "InsetFrameTemplate",
    "UIPanelButtonTemplate", "UIPanelCloseButton", "PanelTabButtonTemplate", "SearchBoxTemplate",
    "WowStyle1DropdownTemplate", "WowScrollBoxList", "MinimalScrollBar", "UIPanelScrollFrameTemplate",
    "PagingControlsHorizontalTemplate", "GameTooltipTemplate", "UICheckButtonTemplate",
}

local ATLASES = {
    "spellbook-Page-Left-C60", "spellbook-Page-Right-C60", "spellbook-Tab-Frame-C60",
    "ui-achievement-guild-background", "ui-achievement-guild-iconframe", "ui-achievement-guild-glow",
    "ui-achievement-guild-shine", "Professions-skillbar-bg", "Professions-skillbar-frame",
    "communities-guildbanner-background", "common-dropdown-bg", "collections-newglow",
    "UI-HUD-ActionBar-IconFrame", "RedButton-Exit",
}

local FILES = {
    "Interface\\QuestFrame\\QuestBG",
    "Interface\\AchievementFrame\\UI-Achievement-Parchment-Horizontal-Desaturated",
    "Interface\\FrameGeneral\\UI-Background-Rock",
    "Interface\\DialogFrame\\UI-DialogBox-Gold-Border",
    "Interface\\CharacterFrame\\TempPortraitAlphaMask",
    "Interface\\Icons\\INV_Misc_Ticket_Tarot_Stack_01",
}

local EVENTS = {
    "QUEST_TURNED_IN", "PLAYER_LEVEL_UP", "ENCOUNTER_END", "BOSS_KILL", "ACHIEVEMENT_EARNED",
    "SKILL_LINES_CHANGED", "LOOT_OPENED", "UPDATE_FACTION", "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE",
    "PLAYER_REGEN_DISABLED", "QUEST_LOG_CRITERIA_UPDATE",
}

local function resolve(path)
    local node = _G
    for part in path:gmatch("[^%.]+") do
        if type(node) ~= "table" then
            return nil
        end
        node = node[part]
    end
    return node
end

local APIS = {
    "C_QuestLog.GetAllCompletedQuestIDs", "GetQuestsCompleted", "C_QuestLog.IsQuestFlaggedCompleted",
    "GetAchievementInfo", "C_AchievementInfo", "IsFishingLoot", "issecretvalue",
    "C_ChatInfo.SendAddonMessage", "C_ChatInfo.RegisterAddonMessagePrefix", "CreateScrollBoxListGridView",
    "ScrollUtil.InitScrollBoxListWithScrollBar", "MenuUtil.CreateContextMenu", "DoesTemplateExist",
    "SetPortraitToTexture", "C_Texture.GetAtlasInfo", "GetFileIDFromPath", "RaidNotice_AddMessage",
    "C_Item.GetItemQualityColor", "GetItemQualityColor", "ITEM_QUALITY_COLORS", "PlaySoundFile",
    "debugprofilestop", "C_Timer.NewTicker", "SOUNDKIT",
}

local function templateExists(name)
    if DoesTemplateExist then
        return DoesTemplateExist(name) and true or false
    end
    local ok = pcall(CreateFrame, "Frame", nil, nil, name)
    return ok
end

local function atlasExists(name)
    return C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(name) ~= nil or false
end

local function fileExists(path)
    if GetFileIDFromPath then
        return GetFileIDFromPath(path) ~= nil
    end
    return nil -- unknown
end

function Compat:Probe()
    for _, name in ipairs(TEMPLATES) do
        self.templates[name] = templateExists(name)
    end
    for _, name in ipairs(ATLASES) do
        self.atlases[name] = atlasExists(name)
    end
    for _, path in ipairs(FILES) do
        self.files[path] = fileExists(path)
    end
    for _, path in ipairs(APIS) do
        self.apis[path] = resolve(path) ~= nil
    end

    local probe = CreateFrame("Frame")
    for _, event in ipairs(EVENTS) do
        local ok = pcall(probe.RegisterEvent, probe, event)
        self.events[event] = ok
        if ok then
            probe:UnregisterEvent(event)
        end
    end

    local tex = probe:CreateTexture()
    self.apis["Texture:SetVertexOffset"] = type(tex.SetVertexOffset) == "function"
    local group = probe:CreateAnimationGroup()
    self.apis["AnimationGroup:SetLooping"] = type(group.SetLooping) == "function"
    self.apis["Animation:FlipBook"] = pcall(group.CreateAnimation, group, "FlipBook")

    local rngOk, rngErr = TC.Rng.selfTest()
    self.apis["Rng.selfTest"] = rngOk

    if TC.db then
        local build, _, _, toc = GetBuildInfo()
        TC.db.probe = {
            build = build, toc = toc, time = time(),
            templates = self.templates, atlases = self.atlases, files = self.files,
            apis = self.apis, events = self.events, rngError = rngErr,
        }
    end
    self.done = true
end

function Compat:HasTemplate(name)
    return self.templates[name] == true
end

function Compat:HasAtlas(name)
    if self.atlases[name] == nil then
        self.atlases[name] = atlasExists(name)
    end
    return self.atlases[name]
end

function Compat:Report()
    local function section(title, map)
        local yes, no = {}, {}
        for k, v in pairs(map) do
            table.insert(v and yes or no, k)
        end
        table.sort(yes)
        table.sort(no)
        TC:Print("|cffffd100%s|r: %d ok, missing: %s", title, #yes, #no > 0 and ("|cffff6060" .. table.concat(no, ", ") .. "|r") or "none")
    end
    section("Templates", self.templates)
    section("Atlases", self.atlases)
    section("Files", self.files)
    section("APIs", self.apis)
    section("Events", self.events)
end
