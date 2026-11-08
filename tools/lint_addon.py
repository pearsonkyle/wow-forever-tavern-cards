#!/usr/bin/env python3
"""Static checks for the addon (CI): the .toc and the files agree, every file compiles, and no file
writes an unexpected global or reads an unknown lowercase one (almost always a typo or a local used
before it's defined; WoW's own API is Capitalized).

    python3 tools/lint_addon.py
"""
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ADDON_DIRS = ("Core", "Engine", "Collection", "UI", "Sources", "Social", "Net", "Data")

# Globals the addon is meant to create.
ALLOWED_WRITES = {"TavernCards_NS", "TavernCards", "SLASH_TAVERNCARDS1", "SLASH_TAVERNCARDS2",
                  "TavernCards_OnAddonCompartmentClick"}
# Lowercase globals that exist in WoW's Lua (and LuaJIT).
LUA_GLOBALS = set("""assert bit collectgarbage coroutine date debugprofilestop debugstack error geterrorhandler
getmetatable hooksecurefunc ipairs issecretvalue math next os pairs pcall print rawequal rawget rawset select
setmetatable string strsplit strtrim table time tinsert tonumber tostring type unpack wipe xpcall jit""".split())


def toc_files():
    files = []
    with open(os.path.join(REPO, "TavernCards.toc")) as f:
        for line in f:
            line = line.strip()
            if line.endswith(".lua") and not line.startswith("#"):
                files.append(line.replace("\\", "/"))
    return files


def main():
    errors = []
    listed = toc_files()
    for path in listed:
        if not os.path.exists(os.path.join(REPO, path)):
            errors.append("toc lists a missing file: " + path)
    on_disk = set()
    for d in ADDON_DIRS:
        for root, _, names in os.walk(os.path.join(REPO, d)):
            for n in names:
                if n.endswith(".lua"):
                    on_disk.add(os.path.relpath(os.path.join(root, n), REPO))
    for path in sorted(on_disk - set(listed)):
        errors.append("not in the toc (WoW won't load it): " + path)

    for path in listed:
        if path.startswith("Libs/") or path.startswith("Data/") or "/Data/" in path:
            continue
        r = subprocess.run(["luajit", "-bl", os.path.join(REPO, path)], capture_output=True, text=True,
                           errors="replace")
        if r.returncode != 0:
            errors.append("does not compile: %s: %s" % (path, r.stderr.strip()))
            continue
        for op, name in re.findall(r'\b(GSET|GGET)\b.*?"([^"]+)"', r.stdout):
            if op == "GSET" and name not in ALLOWED_WRITES and not name.startswith("TavernCards"):
                errors.append("%s writes the global %r (make it local, or add it to ALLOWED_WRITES)" % (path, name))
            elif op == "GGET" and name[:1].islower() and name not in LUA_GLOBALS:
                errors.append("%s reads an unknown lowercase global %r (a typo, or a local used before it exists?)"
                              % (path, name))
    for e in errors:
        print("lint: " + e)
    print("lint_addon: %d file(s) checked, %d problem(s)" % (len(listed), len(errors)))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
