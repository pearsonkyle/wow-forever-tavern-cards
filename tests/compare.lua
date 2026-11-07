-- Compares a C++ snapshot (decoded snapshot_json) with a Lua engine state, field by field.
-- Returns nil when equal, or a "path: cpp=X lua=Y" string for the first difference.

local compare = {}

local function fmt(v)
    if type(v) == "table" then
        local parts = {}
        for i, x in ipairs(v) do parts[i] = tostring(x) end
        return "[" .. table.concat(parts, ",") .. "]"
    end
    return tostring(v)
end

local function same(a, b)
    if type(a) == "number" and type(b) == "boolean" then return (a ~= 0) == b end
    return a == b
end

-- Lua field name for a C++ JSON key, where they differ.
local PLAYER_RENAME = { play_tribes = "play_tribes_this_turn", play_schools = "play_schools_this_turn" }
local BUFF_RENAME = { fromAura = "from_aura", turnsRemaining = "turns_remaining" }

local function list(path, cpp, lua, fn)
    lua = lua or {}
    if #cpp ~= #lua then
        return path .. " length: cpp=" .. #cpp .. " lua=" .. #lua .. " cpp=" .. fmt(cpp) .. " lua=" .. fmt(lua)
    end
    for i = 1, #cpp do
        local d = fn(path .. "[" .. (i - 1) .. "]", cpp[i], lua[i])
        if d then return d end
    end
end

local function scalar(path, c, l)
    if not same(c, l) then
        return path .. ": cpp=" .. fmt(c) .. " lua=" .. fmt(l)
    end
end

local function object(path, cpp, lua, rename, special)
    for k, c in pairs(cpp) do
        local lk = (rename and rename[k]) or k
        local fn = special and special[k]
        local d
        if fn then
            d = fn(path .. "." .. k, c, lua[lk])
        elseif type(c) == "table" then
            d = list(path .. "." .. k, c, lua[lk], scalar)
        else
            d = scalar(path .. "." .. k, c, lua[lk])
        end
        if d then return d end
    end
end

local function pairsAsStrings(path, cpp, lua)
    -- delayed_effects: C++ "CARD:INDEX" strings; Lua {card, index} pairs.
    local converted = {}
    for i, entry in ipairs(lua or {}) do converted[i] = entry[1] .. ":" .. entry[2] end
    return list(path, cpp, converted, scalar)
end

local function mapAsStrings(path, cpp, lua)
    local converted = {}
    local keys = {}
    for k in pairs(lua or {}) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do converted[#converted + 1] = k .. ":" .. lua[k] end
    return list(path, cpp, converted, scalar)
end

local function entity(path, c, l)
    if not l then return path .. ": missing in lua" end
    return object(path, c, l, nil, {
        flags = function(p, cf, lf) return object(p, cf, lf) end,
        buffs = function(p, cb, lb)
            return list(p, cb, lb, function(bp, cbuff, lbuff)
                if not lbuff then return bp .. ": missing" end
                return object(bp, cbuff, lbuff, BUFF_RENAME)
            end)
        end,
        granted = function(p, cg, lg)
            local converted = {}
            for i, g in ipairs(lg or {}) do converted[i] = g.card_id .. ":" .. g.index end
            return list(p, cg, converted, scalar)
        end,
    })
end

local function player(path, c, l)
    return object(path, c, l, PLAYER_RENAME, {
        delayed_effects = pairsAsStrings,
        numbered_made = mapAsStrings,
    })
end

-- `cpp` is the decoded snapshot; `engine` the Lua engine.
function compare.state(cpp, engine)
    local s = engine.state
    local d
    for _, k in ipairs({ "active", "phase", "turn", "v", "next_entity_id", "next_play_order", "loop_steps" }) do
        d = scalar(k, cpp[k], s[k])
        if d then return d end
    end
    d = scalar("heroClassA", cpp.heroClassA, s.players[1].hero_class)
        or scalar("heroClassB", cpp.heroClassB, s.players[2].hero_class)
    if d then return d end
    d = list("mulligan_answered", cpp.mulligan_answered, { s.mulligan_answered[1] and 1 or 0,
        s.mulligan_answered[2] and 1 or 0 }, scalar)
    if d then return d end
    local words = {}
    for w in cpp.rng:match('"s":%[([%d,]+)%]'):gmatch("%d+") do words[#words + 1] = tonumber(w) end
    d = list("rng.s", words, s.rng.s, scalar)
    if d then return d end
    d = object("result", cpp.result, s.result)
    if d then return d end
    local pending = s.pending
    d = object("pending", cpp.pending, pending, {
        cards = "card_options", cost = "cost_delta", guessCopy = "guess_copy", index = "effect_index",
        eventSubject = "event_subject", previous = "previous_targets", fromDeck = "from_deck",
        thenOnPlay = "then_on_play", resumeSame = "resume_same", othersToHand = "others_to_hand",
        dark_gift = "dark_gift",
    }, {
        trigger = function(p, c, l)
            return scalar(p, c, TavernCards_NS.TriggerNumbers[l])
        end,
    })
    if d then return d end
    for i = 1, 2 do
        d = player("players[" .. (i - 1) .. "]", cpp.players[i], s.players[i])
        if d then return d end
    end
    d = list("persistent", cpp.persistent, s.persistent, function(p, c, l)
        if not l then return p .. ": missing" end
        return object(p, c, l, { turns = "turns_remaining" })
    end)
    if d then return d end
    for _, ce in ipairs(cpp.entities) do
        d = entity("entities[" .. ce.id .. " " .. ce.card_id .. "]", ce, s.entities[ce.id])
        if d then return d end
    end
    local n = 0
    for _ in pairs(s.entities) do n = n + 1 end
    if n ~= #cpp.entities then return "entity count: cpp=" .. #cpp.entities .. " lua=" .. n end
end

-- Moves: same count, and per move the same action, description, cards and payload.
function compare.moves(cppMoves, luaMoves)
    if #cppMoves ~= #luaMoves then
        local lines = {}
        for i = 1, math.max(#cppMoves, #luaMoves) do
            lines[#lines + 1] = ("  %d cpp=%s | lua=%s"):format(i - 1, cppMoves[i] and cppMoves[i].desc or "-",
                luaMoves[i] and luaMoves[i].desc or "-")
        end
        return "move count: cpp=" .. #cppMoves .. " lua=" .. #luaMoves .. "\n" .. table.concat(lines, "\n")
    end
    for i, cm in ipairs(cppMoves) do
        local lm = luaMoves[i]
        local d = scalar("move[" .. (i - 1) .. "].action", cm.action, lm.action)
            or scalar("move[" .. (i - 1) .. "].desc", cm.desc, lm.desc)
            or list("move[" .. (i - 1) .. "].cards", cm.cards, lm.cards, scalar)
            or object("move[" .. (i - 1) .. "].payload", cm.payload, lm.payload)
        if d then return d end
    end
end

return compare
