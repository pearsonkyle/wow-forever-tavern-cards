#!/usr/bin/env python3
"""Committed C++ reference traces, so CI checks the Lua engine against the C++ one without jankcraft.

    python3 tools/make_fixtures.py          # rewrites fixtures/traces/*.jsonl.xz

One sweep pool per class (both seats that class, its own and neutral cards) plus full-pool and Classic
matches, recorded by tools/trace/tavern-trace and xz-compressed (full state per step compresses ~500x).
tests/test_parity.lua replays every file. Regenerate after the card data or the engine changes.
"""
import glob
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "tests"))
import sweep  # noqa: E402

OUT = os.path.join(REPO, "fixtures", "traces")


def record(name, args):
    path = os.path.join(OUT, name + ".jsonl")
    with open(path, "w") as f:
        subprocess.check_call([sweep.TRACE, "--data", sweep.DATA] + args, stdout=f)
    subprocess.check_call(["xz", "-9", "-f", path])
    print(name, os.path.getsize(path + ".xz") // 1024, "KB")


def main():
    os.makedirs(OUT, exist_ok=True)
    for old in glob.glob(os.path.join(OUT, "*.xz")):
        os.remove(old)
    cards, playable = sweep.load_cards()
    seen = set()
    pool_dir = os.path.join(REPO, "tools", "cache", "fixture-pools")
    os.makedirs(pool_dir, exist_ok=True)
    for family, pool in sweep.pools(cards, playable):
        if not family or family in seen:
            continue
        seen.add(family)
        pool_path = os.path.join(pool_dir, family + ".txt")
        with open(pool_path, "w") as f:
            f.write("\n".join(pool) + "\n")
        record("class-" + family.lower(), ["--pool", pool_path, "--family", family, "--seed", "31000", "--matches", "2"])
    pools = os.path.join(REPO, "tools", "cache", "pools")
    record("full-pool", ["--pool", os.path.join(pools, "all.txt"), "--seed", "32000", "--matches", "6"])
    record("classic", ["--pool", os.path.join(pools, "classic.txt"), "--seed", "33000", "--matches", "4"])


if __name__ == "__main__":
    main()
