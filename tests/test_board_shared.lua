-- SPDX-License-Identifier: GPL-3.0-or-later
-- Copyright (C) 2026 Kyle Pearson. Part of Tavern Cards (https://github.com/pearsonkyle/wow-forever-tavern-cards).
--
-- The board files share functions through a private table (Board._P). A name read as P.x but never set
-- with "P.x = ..." is nil at run time, and often only on a path the smoke test doesn't click (a hover).
local T = {}

T.every_shared_board_name_is_exported = function()
    local used, exported = {}, {}
    local pipe = io.popen("ls UI/Board/*.lua")
    for file in pipe:lines() do
        local src = io.open(file):read("*a")
        for name in src:gmatch("%f[%w_]P%.([%a_][%w_]*)") do used[name] = file end
        for name in src:gmatch("\nP%.([%a_][%w_]*)%s*=") do exported[name] = true end
    end
    pipe:close()
    for name, file in pairs(used) do
        assert(exported[name], ("%s reads P.%s, which no board file exports"):format(file, name))
    end
end

return T
