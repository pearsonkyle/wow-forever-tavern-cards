-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- Board table art: the play mat (painted world maps) and the painted table around it.

local TC = TavernCards_NS
local Board = TC.Board
local P, S = Board._P, Board._S
local band = bit.band
local H, W = P.H, P.W

-- Play mats: the painted world maps (4x3 tiles of Interface\WorldMap\<zone>\<zone>N). The mat is the
-- map of the zone you're in when the match starts (kept with the match), else one of these at random.
local ZONE_MAPS = {
    ["Elwynn Forest"] = "Elwynn", ["Westfall"] = "Westfall", ["Duskwood"] = "Duskwood",
    ["Redridge Mountains"] = "Redridge", ["Stranglethorn Vale"] = "Stranglethorn", ["The Barrens"] = "Barrens",
    ["Durotar"] = "Durotar", ["Mulgore"] = "Mulgore", ["Ashenvale"] = "Ashenvale", ["Darkshore"] = "Darkshore",
    ["Teldrassil"] = "Teldrassil", ["Dun Morogh"] = "DunMorogh", ["Loch Modan"] = "LochModan", ["Wetlands"] = "Wetlands",
    ["Arathi Highlands"] = "Arathi", ["Hillsbrad Foothills"] = "Hilsbrad", ["Alterac Mountains"] = "Alterac",
    ["Tirisfal Glades"] = "Tirisfal", ["Silverpine Forest"] = "Silverpine", ["Tanaris"] = "Tanaris", ["Feralas"] = "Feralas",
    ["Desolace"] = "Desolace", ["Stonetalon Mountains"] = "StonetalonMountains", ["Thousand Needles"] = "ThousandNeedles",
    ["Dustwallow Marsh"] = "Dustwallow", ["Burning Steppes"] = "BurningSteppes", ["Searing Gorge"] = "SearingGorge",
    ["Badlands"] = "Badlands", ["Swamp of Sorrows"] = "SwampOfSorrows", ["Blasted Lands"] = "BlastedLands",
    ["Deadwind Pass"] = "DeadwindPass", ["Eastern Plaguelands"] = "EasternPlaguelands",
    ["Western Plaguelands"] = "WesternPlaguelands", ["Winterspring"] = "Winterspring", ["Felwood"] = "Felwood",
    ["Azshara"] = "Aszhara", ["Un'Goro Crater"] = "UngoroCrater", ["Silithus"] = "Silithus", ["Moonglade"] = "Moonglade",
    ["The Hinterlands"] = "Hinterlands", ["Ironforge"] = "Ironforge", ["Orgrimmar"] = "Ogrimmar",
    ["Thunder Bluff"] = "ThunderBluff", ["Undercity"] = "Undercity", ["Darnassus"] = "Darnassis",
}
local MAT_POOL = { "Elwynn", "Westfall", "Duskwood", "Barrens", "Durotar", "Mulgore", "Ashenvale", "DunMorogh",
    "Stranglethorn", "Tanaris", "Feralas", "Arathi", "Wetlands", "Tirisfal", "Hinterlands", "Winterspring", "Silithus" }

local function mapExists(zone)
    return not GetFileIDFromPath or GetFileIDFromPath(("Interface\\WorldMap\\%s\\%s1"):format(zone, zone)) ~= nil
end

-- Classic zone maps (uiMapIDs) for when the zone you're in has no map art: Elwynn, Westfall, Duskwood,
-- the Barrens, Durotar, Mulgore, Ashenvale, Dun Morogh, Stranglethorn, Tanaris, Feralas, Arathi,
-- Wetlands, Tirisfal, the Hinterlands, Winterspring, Silithus, Redridge, Loch Modan, Darkshore.
local CLASSIC_MAPS = { 1429, 1436, 1431, 1413, 1411, 1412, 1440, 1426, 1434, 1446, 1444, 1417, 1437, 1420, 1425,
    1452, 1451, 1433, 1432, 1439 }

-- A map's art in the client: its tile layout and the tile textures (file ids), or nil.
local function mapArt(mapID)
    if not (C_Map and C_Map.GetMapArtLayers and C_Map.GetMapArtLayerTextures) then return nil end
    local ok, layers = pcall(C_Map.GetMapArtLayers, mapID)
    local layer = ok and type(layers) == "table" and layers[1]
    if not layer or not layer.tileWidth or layer.tileWidth <= 0 or not layer.layerWidth then return nil end
    local ok2, tiles = pcall(C_Map.GetMapArtLayerTextures, mapID, 1)
    if not ok2 or type(tiles) ~= "table" or #tiles == 0 then return nil end
    return layer, tiles
end
Board.MapArt = mapArt

-- When the client offers no map art: the painting of the dungeon nearest to where you stand (the game's
-- loading screens), else a random one, as a wide crop.
local ZONE_PAINTINGS = {
    ["Durotar"] = "RagefireChasm", ["Orgrimmar"] = "RagefireChasm", ["The Barrens"] = "WailingCaverns",
    ["Westfall"] = "Deadmines", ["Elwynn Forest"] = "StormwindStockade", ["Stormwind City"] = "StormwindStockade",
    ["Silverpine Forest"] = "ShadowfangKeep", ["Ashenvale"] = "BlackfathomDeeps", ["Darkshore"] = "BlackfathomDeeps",
    ["Dun Morogh"] = "Gnomeregan", ["Ironforge"] = "Gnomeregan", ["Tirisfal Glades"] = "Monastery",
    ["Undercity"] = "Monastery", ["Badlands"] = "Uldaman", ["Loch Modan"] = "Uldaman", ["Tanaris"] = "ZulFarrak",
    ["Desolace"] = "Maraudon", ["Swamp of Sorrows"] = "SunkenTemple", ["Burning Steppes"] = "BlackrockDepths",
    ["Searing Gorge"] = "BlackrockDepths", ["Feralas"] = "DireMaul", ["Western Plaguelands"] = "Scholomance",
    ["Eastern Plaguelands"] = "Strathome", ["Stranglethorn Vale"] = "ZulGurub", ["Silithus"] = "AhnQiraj40man",
    ["Thousand Needles"] = "RazorfenDowns", ["Mulgore"] = "RazorfenKraul", ["Thunder Bluff"] = "RazorfenKraul",
    ["Winterspring"] = "Kalimdor", ["Moonglade"] = "Kalimdor", ["Teldrassil"] = "Kalimdor", ["Darnassus"] = "Kalimdor",
    ["Duskwood"] = "EasternKingdom", ["Redridge Mountains"] = "BlackrockSpire", ["Wetlands"] = "EasternKingdom",
}
local PAINTINGS = { "Deadmines", "WailingCaverns", "ShadowfangKeep", "Gnomeregan", "Monastery", "Uldaman", "ZulFarrak",
    "Maraudon", "SunkenTemple", "BlackrockDepths", "DireMaul", "Scholomance", "Strathome", "MoltenCore", "ZulGurub",
    "BlackwingLair", "AhnQiraj40man", "Naxxramas", "Kalimdor", "EasternKingdom" }

local function paintingExists(name)
    return not GetFileIDFromPath or GetFileIDFromPath("Interface\\Glues\\LoadingScreens\\LoadScreen" .. name) ~= nil
end

-- The mat for a new match: the map of where you stand (or the zone around your city/sub-zone), else a
-- random classic zone; the old world-map file paths as a last resort.
function Board.PickMat()
    -- WoW: Forever's client reports map art (tile file ids) for its zones but doesn't ship the files: the
    -- tiles draw nothing. The play field is felt over the painted table instead.
    if true then return nil end
    if C_Map and C_Map.GetBestMapForUnit then
        local id = C_Map.GetBestMapForUnit("player")
        for _ = 1, 4 do
            if not id then break end
            if mapArt(id) then return id end
            local info = C_Map.GetMapInfo and C_Map.GetMapInfo(id)
            id = info and info.parentMapID
        end
        for _ = 1, 8 do
            local id2 = CLASSIC_MAPS[math.random(#CLASSIC_MAPS)]
            if mapArt(id2) then return id2 end
        end
    end
    local here = GetRealZoneText and GetRealZoneText()
    local zone = here and ZONE_MAPS[here]
    if zone and mapExists(zone) then return zone end
end

-- The table painting for a new match: the Play tab's choice (TC.db.settings.tableArt: a painting file,
-- "plain", or automatic), automatic being the dungeon nearest to where you stand, else a random one.
function Board.PickTable()
    local choice = TC.db and TC.db.settings.tableArt
    if choice == "plain" then return false end
    if type(choice) == "string" and choice ~= "auto" and paintingExists(choice:gsub("^LoadScreen", "")) then
        return (choice:gsub("^LoadScreen", ""))
    end
    local here = GetRealZoneText and GetRealZoneText()
    local painting = here and ZONE_PAINTINGS[here]
    if painting and paintingExists(painting) then return painting end
    for _ = 1, 8 do
        local p = PAINTINGS[math.random(#PAINTINGS)]
        if paintingExists(p) then return p end
    end
    return false
end

-- painting: a loading-screen name ("Deadmines") or false (plain table).
function Board:SetTable(painting)
    if not S.frame then return end
    local ok = painting and paintingExists(painting)
    local layers = { S.frame.tableArt, unpack(S.frame.tableSoft) }
    if ok then
        -- Below the game logo the loading screens carry across their top, cropped to the board's shape
        -- (which also zooms it a little: softer).
        local w, h = W - 20, H - 20
        -- A true soft focus without ghosting: a patch of the painting (just under a third of its width)
        -- stretched over the whole board. The texture filter smooths it into the painting's colours and
        -- light, with no shapes to catch the eye.
        local wfrac = 0.42  -- smaller = blurrier, larger = more of the painting's detail
        local hfrac = wfrac * 4 / (3 * (w / h))
        local cx, cy = 0.5, 0.62
        S.frame.tableArt:SetTexture("Interface\\Glues\\LoadingScreens\\LoadScreen" .. painting)
        S.frame.tableArt:SetTexCoord(cx - wfrac / 2, cx + wfrac / 2, cy - hfrac / 2, cy + hfrac / 2)
        if S.frame.tableArt.SetDesaturation then pcall(S.frame.tableArt.SetDesaturation, S.frame.tableArt, 0.3) end
        S.frame.tableArt:SetVertexColor(0.95, 0.9, 0.85)
        S.frame.tableArt:SetAlpha(0.35)   -- over the wood only (masked): a painted table, the grain still showing
        S.frame.tableArt:Show()
        for _, t in ipairs(S.frame.tableSoft) do t:Hide() end
    else
        for _, t in ipairs(layers) do t:Hide() end
    end
    S.frame.tableEdge:SetShown(ok and true or false)
    S.frame.tableEdgeR:SetShown(ok and true or false)
    Board.tableShown = ok and painting or nil
    S.frame.wash:SetGradient("VERTICAL", CreateColor(0.06, 0.04, 0.03, ok and 0.18 or 0),
        CreateColor(0.1, 0.07, 0.04, ok and 0.12 or 0))
    self:SetMat(Board.matCurrent)
end

local function tileTexture(i)
    local tiles = S.frame.mat.tiles
    if not tiles[i] then
        tiles[i] = S.frame.mat.grid:CreateTexture(nil, "BACKGROUND", nil, 1)
    end
    return tiles[i]
end

-- mat: a uiMapID (map art from C_Map), a zone folder name (older clients), or nil/false (plain felt).
function Board:SetMat(mat)
    if not S.frame then return end
    for _, t in ipairs(S.frame.mat.tiles) do t:Hide() end
    if S.frame.mat.paint then S.frame.mat.paint:Hide() end
    local matW = S.frame.mat:GetWidth()
    if not matW or matW <= 0 then matW = (TC.TexLayout.surface[3] - TC.TexLayout.surface[1]) * W end
    local ok = false
    if type(mat) == "number" then
        local layer, tiles = mapArt(mat)
        if layer then
            local cols = math.max(1, math.ceil(layer.layerWidth / layer.tileWidth))
            local scale = matW / layer.layerWidth
            local tw, th = layer.tileWidth * scale, layer.tileHeight * scale
            S.frame.mat.grid:SetSize(matW, layer.layerHeight * scale)
            for i, fileID in ipairs(tiles) do
                local t = tileTexture(i)
                t:ClearAllPoints()
                t:SetSize(tw, th)
                t:SetPoint("TOPLEFT", ((i - 1) % cols) * tw, -math.floor((i - 1) / cols) * th)
                t:SetTexture(fileID)
                t:Show()
            end
            ok = true
        end
    elseif type(mat) == "string" and mat:find("^paint:") and paintingExists(mat:sub(7)) then
        -- A wide band across the middle of the 4:3 painting.
        local t = S.frame.mat.paint
        if not t then
            t = S.frame.mat.grid:CreateTexture(nil, "BACKGROUND", nil, 2)
            S.frame.mat.paint = t
        end
        local band = math.min(1, (4 / 3) * (S.frame.mat:GetHeight() or 244) / matW)
        S.frame.mat.grid:SetSize(matW, S.frame.mat:GetHeight() or 244)
        t:ClearAllPoints()
        t:SetAllPoints(S.frame.mat)
        t:SetTexture("Interface\\Glues\\LoadingScreens\\LoadScreen" .. mat:sub(7))
        t:SetTexCoord(0, 1, 0.5 - band / 2, 0.5 + band / 2)
        t:Show()
        ok = true
    elseif type(mat) == "string" and mapExists(mat) then
        local tile = matW / 4
        S.frame.mat.grid:SetSize(matW, tile * 3)
        for i = 1, 12 do
            local t = tileTexture(i)
            t:ClearAllPoints()
            t:SetSize(tile, tile)
            t:SetPoint("TOPLEFT", ((i - 1) % 4) * tile, -math.floor((i - 1) / 4) * tile)
            t:SetTexture(("Interface\\WorldMap\\%s\\%s%d"):format(mat, mat, i))
            t:Show()
        end
        ok = true
    end
    Board.matShown, Board.matCurrent = ok and mat or nil, mat
    -- The map is drawn faintly into the stone: half strength, under a warm wash; plain stone without one.
    for _, t in ipairs(S.frame.mat.tiles) do t:SetAlpha(0.5) end
    if S.frame.mat.paint then S.frame.mat.paint:SetAlpha(0.5) end
    local a = ok and 0.22 or 0
    S.frame.felt:SetGradient("VERTICAL", CreateColor(0.6, 0.5, 0.36, a), CreateColor(0.55, 0.45, 0.32, a))
end
