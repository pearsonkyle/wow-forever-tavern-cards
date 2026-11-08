local T = {}

T.reference_vector = function(TC)
    local ok, err = TC.Rng.selfTest()
    assert(ok, err)
end

T.int_below_bounds = function(TC)
    local r = TC.Rng.new(42)
    for _ = 1, 2000 do
        local v = r:intBelow(7)
        assert(v >= 0 and v < 7 and v == math.floor(v))
    end
    assert(r:intBelow(1) == 0 and r:intBelow(0) == 0)
end

T.save_restore_continues_stream = function(TC)
    local a = TC.Rng.new(99)
    for _ = 1, 5 do a:next() end
    local b = TC.Rng.restore(a:saveState())
    for _ = 1, 20 do
        assert(a:next() == b:next())
    end
end

T.large_seed_halves = function(TC)
    -- A seed above 2^32 given as a number and as halves must agree.
    local a = TC.Rng.new(0x123456789)
    local b = TC.Rng.new(0x1, 0x23456789)
    for _ = 1, 8 do
        assert(a:next() == b:next())
    end
end

return T
