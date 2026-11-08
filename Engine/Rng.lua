-- Seeded RNG: a bit-exact port of the reference engine's simcore::Rng (xoshiro128** with a splitmix64 seeder).
--
-- The draw sequence decides every match, and both lockstep peers and the reference engine must agree
-- on it, so nothing here may depend on the host's number formatting or library internals. Lua 5.1
-- numbers are doubles (exact to 2^53): 32-bit products are split into 16-bit halves, and the
-- 64-bit splitmix arithmetic runs on four 16-bit limbs.
--
-- Headless: only `bit`, `math` and `table` are used (WoW and LuaJIT both provide LuaBitOp's `bit`).

local TC = TavernCards_NS or {}
TavernCards_NS = TC

local bit = bit
local band, bxor, bor, lshift, rshift = bit.band, bit.bxor, bit.bor, bit.lshift, bit.rshift
local floor = math.floor

local TWO32 = 4294967296

-- LuaBitOp returns signed 32-bit results; fold them back to [0, 2^32).
local function u32(x)
    return x % TWO32
end

local function rotl(x, k)
    return u32(bor(lshift(x, k), rshift(x, 32 - k)))
end

-- (a * b) mod 2^32 for a, b in [0, 2^32), without losing bits in a double.
local function mul32(a, b)
    local blo = b % 65536
    local bhi = (b - blo) / 65536
    return (a * blo + ((a * bhi) % 65536) * 65536) % TWO32
end

---------------------------------------------------------------------------------------------------
-- 64-bit helpers on {l0, l1, l2, l3} 16-bit limbs, least significant first.

local function u64_from(hi, lo)
    return { lo % 65536, floor(lo / 65536), hi % 65536, floor(hi / 65536) }
end

local function u64_lo32(x)
    return x[1] + x[2] * 65536
end

local function u64_add(a, b)
    local out, carry = {}, 0
    for i = 1, 4 do
        local s = a[i] + b[i] + carry
        out[i] = s % 65536
        carry = floor(s / 65536)
    end
    return out
end

local function u64_mul(a, b)
    local out = { 0, 0, 0, 0 }
    for i = 1, 4 do
        local carry = 0
        for j = 1, 5 - i do
            local k = i + j - 1
            local s = out[k] + a[i] * b[j] + carry
            out[k] = s % 65536
            carry = floor(s / 65536)
        end
    end
    return out
end

local function u64_xor_shr(x, n)
    -- x ^ (x >> n), for 0 < n < 64
    local hi = x[3] + x[4] * 65536
    local lo = x[1] + x[2] * 65536
    local shi, slo
    if n >= 32 then
        shi, slo = 0, rshift(hi, n - 32) % TWO32
    else
        shi = rshift(hi, n) % TWO32
        slo = u32(bor(rshift(lo, n), lshift(hi, 32 - n)))
    end
    return u64_from(u32(bxor(hi, shi)), u32(bxor(lo, slo)))
end

local GOLDEN = u64_from(0x9E3779B9, 0x7F4A7C15)
local MIX1 = u64_from(0xBF58476D, 0x1CE4E5B9)
local MIX2 = u64_from(0x94D049BB, 0x133111EB)

---------------------------------------------------------------------------------------------------

local Rng = {}
Rng.__index = Rng

-- `seed` may be a number below 2^53, or pass `seedHi, seedLo` as two 32-bit halves.
function Rng.new(seed, seedLo)
    local hi, lo
    if seedLo ~= nil then
        hi, lo = seed, seedLo
    else
        lo = seed % TWO32
        hi = (seed - lo) / TWO32
    end
    local self = setmetatable({ seedHi = hi, seedLo = lo, s = { 0, 0, 0, 0 } }, Rng)

    local x = u64_from(hi, lo)
    for i = 1, 4 do
        x = u64_add(x, GOLDEN)
        local z = u64_mul(u64_xor_shr(x, 30), MIX1)
        z = u64_mul(u64_xor_shr(z, 27), MIX2)
        z = u64_xor_shr(z, 31)
        self.s[i] = u64_lo32(z)
    end
    local s = self.s
    if s[1] == 0 and s[2] == 0 and s[3] == 0 and s[4] == 0 then
        s[1] = 0x9E3779B9
    end
    return self
end

function Rng:next()
    local s = self.s
    local result = mul32(rotl(mul32(s[2], 5), 7), 9)
    local t = u32(lshift(s[2], 9))

    s[3] = u32(bxor(s[3], s[1]))
    s[4] = u32(bxor(s[4], s[2]))
    s[2] = u32(bxor(s[2], s[3]))
    s[1] = u32(bxor(s[1], s[4]))
    s[3] = u32(bxor(s[3], t))
    s[4] = rotl(s[4], 11)

    return result
end

-- [0, 1) with 24 bits, exactly as the reference.
function Rng:nextDouble()
    return floor(self:next() / 256) / 16777216
end

-- [0, bound); bound <= 1 returns 0. Rejection sampling keeps every value equally likely.
function Rng:intBelow(bound)
    if bound <= 1 then
        return 0
    end
    local limit = TWO32 - (TWO32 % bound)
    local r = self:next()
    while r >= limit do
        r = self:next()
    end
    return r % bound
end

-- Inclusive [lo, hi].
function Rng:intRange(lo, hi)
    if hi <= lo then
        return lo
    end
    return lo + self:intBelow(hi - lo + 1)
end

-- Fisher-Yates, backwards, consuming draws in the reference order (0-based j mapped to 1-based slots).
function Rng:shuffle(items)
    for i = #items, 2, -1 do
        local j = self:intBelow(i) + 1
        items[i], items[j] = items[j], items[i]
    end
    return items
end

function Rng:pick(items)
    return items[self:intBelow(#items) + 1]
end

function Rng:saveState()
    local s = self.s
    return { seedHi = self.seedHi, seedLo = self.seedLo, s = { s[1], s[2], s[3], s[4] } }
end

function Rng.restore(state)
    local self = setmetatable({ seedHi = state.seedHi, seedLo = state.seedLo, s = {} }, Rng)
    for i = 1, 4 do
        self.s[i] = state.s[i]
    end
    return self
end

-- simcore::rng_reference_vector(): the first eight draws for seed 1 and for seed 0x5EED.
Rng.REFERENCE = {
    264704485, 1194741267, 1678852802, 535420451, 3471461366, 2588997986, 4171330986, 2629103435,
    1428441837, 800393357, 2860745380, 247893271, 3085711047, 3904610978, 3353987658, 2044335947,
}

function Rng.selfTest()
    local got = {}
    for _, seed in ipairs({ 1, 0x5EED }) do
        local r = Rng.new(seed)
        for _ = 1, 8 do
            got[#got + 1] = r:next()
        end
    end
    for i = 1, #Rng.REFERENCE do
        if got[i] ~= Rng.REFERENCE[i] then
            return false, ("draw %d: got %s, want %s"):format(i, tostring(got[i]), tostring(Rng.REFERENCE[i]))
        end
    end
    return true
end

TC.Rng = Rng
return Rng
