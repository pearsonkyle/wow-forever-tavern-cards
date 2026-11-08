-- SHA-256 in plain Lua 5.1 with the bit library: the commitments of the duel handshake (Net/Duel.lua).
-- Headless (tests/test_duel.lua checks the standard test vectors).

local TC = TavernCards_NS
local band, bor, bxor, bnot, rshift, lshift = bit.band, bit.bor, bit.bxor, bit.bnot, bit.rshift, bit.lshift
local MOD = 4294967296

local K = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

local function u(x)
    return x % MOD
end

local function rotr(x, n)
    return bor(rshift(x, n), lshift(x, 32 - n))
end

local function preprocess(msg)
    local len = #msg
    local extra = 64 - ((len + 9) % 64)
    if extra == 64 then extra = 0 end
    local bits = len * 8
    local tail = {}
    for i = 7, 0, -1 do
        tail[#tail + 1] = string.char(math.floor(bits / 2 ^ (i * 8)) % 256)
    end
    return msg .. "\128" .. string.rep("\0", extra) .. table.concat(tail)
end

local function digestBlock(msg, i, H)
    local w = {}
    for j = 0, 15 do
        local a, b, c, d = msg:byte(i + j * 4, i + j * 4 + 3)
        w[j] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for j = 16, 63 do
        local v15, v2 = w[j - 15], w[j - 2]
        local s0 = bxor(rotr(v15, 7), rotr(v15, 18), rshift(v15, 3))
        local s1 = bxor(rotr(v2, 17), rotr(v2, 19), rshift(v2, 10))
        w[j] = u(w[j - 16] + s0 + w[j - 7] + s1)
    end
    local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]
    for j = 0, 63 do
        local S1 = bxor(rotr(e, 6), rotr(e, 11), rotr(e, 25))
        local ch = bxor(band(e, f), band(bnot(e), g))
        local t1 = u(h + u(S1) + u(ch) + K[j + 1] + w[j])
        local S0 = bxor(rotr(a, 2), rotr(a, 13), rotr(a, 22))
        local maj = bxor(band(a, b), band(a, c), band(b, c))
        local t2 = u(u(S0) + u(maj))
        h, g, f, e, d, c, b, a = g, f, e, u(d + t1), c, b, a, u(t1 + t2)
    end
    H[1], H[2], H[3], H[4] = u(H[1] + a), u(H[2] + b), u(H[3] + c), u(H[4] + d)
    H[5], H[6], H[7], H[8] = u(H[5] + e), u(H[6] + f), u(H[7] + g), u(H[8] + h)
end

-- Lower-case hex digest of a string.
function TC.Sha256(msg)
    msg = preprocess(msg)
    local H = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 }
    for i = 1, #msg, 64 do
        digestBlock(msg, i, H)
    end
    local out = {}
    for i = 1, 8 do out[i] = string.format("%08x", u(H[i])) end
    return table.concat(out)
end
