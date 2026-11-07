-- Minimal JSON decoder for the test harness (tavern-trace output). Not loaded by the addon.
local json = {}

local function skip(s, i)
    local _, e = s:find("^[ \n\r\t]*", i)
    return e + 1
end

local decodeValue

local function decodeString(s, i)
    local out = {}
    i = i + 1
    while true do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local n = s:sub(i + 1, i + 1)
            local map = { n = "\n", t = "\t", r = "\r", b = "\b", f = "\f", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
            if n == "u" then
                local code = tonumber(s:sub(i + 2, i + 5), 16)
                if code < 128 then
                    out[#out + 1] = string.char(code)
                elseif code < 2048 then
                    out[#out + 1] = string.char(192 + math.floor(code / 64), 128 + code % 64)
                else
                    out[#out + 1] = string.char(224 + math.floor(code / 4096), 128 + math.floor(code / 64) % 64, 128 + code % 64)
                end
                i = i + 6
            else
                out[#out + 1] = map[n] or n
                i = i + 2
            end
        else
            local j = s:find('["\\]', i)
            out[#out + 1] = s:sub(i, j - 1)
            i = j
        end
    end
end

decodeValue = function(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "{" then
        local obj = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "}" then return obj, i + 1 end
        while true do
            local k
            k, i = decodeString(s, skip(s, i))
            i = skip(s, i) + 1 -- ':'
            obj[k], i = decodeValue(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            i = i + 1
            if d == "}" then return obj, i end
        end
    elseif c == "[" then
        local arr = {}
        i = skip(s, i + 1)
        if s:sub(i, i) == "]" then return arr, i + 1 end
        while true do
            arr[#arr + 1], i = decodeValue(s, i)
            i = skip(s, i)
            local d = s:sub(i, i)
            i = i + 1
            if d == "]" then return arr, i end
        end
    elseif c == '"' then
        return decodeString(s, i)
    elseif s:sub(i, i + 3) == "true" then
        return true, i + 4
    elseif s:sub(i, i + 4) == "false" then
        return false, i + 5
    elseif s:sub(i, i + 3) == "null" then
        return json.null, i + 4
    else
        local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        return tonumber(num), i + #num
    end
end

json.null = setmetatable({}, { __tostring = function() return "null" end })

function json.decode(s)
    local v = decodeValue(s, 1)
    return v
end

return json
