#!/usr/bin/env python3
"""Engine/ must run headless (LuaJIT tests, lockstep replays), so it may not touch WoW globals.

    python3 tools/lint_engine.py

Reads LuaJIT's bytecode listing for every Engine/ file and fails on any global read or write
outside the allowlist below.
"""
import glob
import os
import re
import subprocess
import sys

from common import REPO

ALLOWED = {
    "TavernCards_NS", "bit", "math", "string", "table", "coroutine",
    "pairs", "ipairs", "next", "select", "type", "tostring", "tonumber", "setmetatable", "getmetatable",
    "rawget", "rawset", "rawequal", "error", "assert", "pcall", "xpcall", "unpack",
}

GLOBAL = re.compile(r"\b(GGET|GSET)\b.*;\s*\"([^\"]+)\"")


def main():
    bad = []
    files = sorted(glob.glob(os.path.join(REPO, "Engine", "**", "*.lua"), recursive=True))
    for path in files:
        listing = subprocess.run(["luajit", "-bl", path], capture_output=True, text=True)
        if listing.returncode != 0:
            bad.append("%s: %s" % (path, listing.stderr.strip()))
            continue
        for line in listing.stdout.splitlines():
            m = GLOBAL.search(line)
            if m and m.group(2) not in ALLOWED:
                bad.append("%s: %s %s" % (os.path.relpath(path, REPO), m.group(1), m.group(2)))
    for b in sorted(set(bad)):
        print(b)
    print("lint_engine: %d file(s), %s" % (len(files), "ok" if not bad else "%d problem(s)" % len(set(bad))))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
