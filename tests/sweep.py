#!/usr/bin/env python3
"""Card sweep: every playable card goes through the differential check (C++ engine vs the Lua port).

Random full-pool fuzzing rarely plays any given card, so this builds small pools instead: per class,
~12 class cards plus a rotating ~14 neutrals, so both decks are made of just those cards and almost all
of them get played. Each pool runs a few seeded matches in tavern-trace; tests/trace.lua replays them in
Lua and diffs every step. At the end: divergences (if any) and which cards were never played.

    python3 tests/sweep.py [matches_per_pool=4] [workers=4]
Report: tools/cache/sweep/report.json
"""
import collections
import concurrent.futures
import json
import os
import random
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(os.environ.get("JANKCRAFT", os.path.expanduser("~/Programs/misc/wow/jankcraft")),
                    "server", "modules", "mod-tavern-sim", "data")
OUT = os.path.join(REPO, "tools", "cache", "sweep")
TRACE = os.path.join(REPO, "tools", "trace", "tavern-trace")
SEED_BASE = int(os.environ.get("SWEEP_SEED", "5000"))
PREFER = []   # in --never mode: the cards being chased are played whenever legal


def load_cards():
    cards = {}
    pat = re.compile(r'^C\("([^"]+)","((?:[^"\\]|\\.)*)","(\w+)","(\w+)","(\w+)"')
    with open(os.path.join(REPO, "Data", "Cards.lua")) as f:
        for line in f:
            m = pat.match(line)
            if m:
                cards[m.group(1)] = {"name": m.group(2).replace('\\"', '"'), "type": m.group(3), "family": m.group(4), "rarity": m.group(5)}
    playable = []
    with open(os.path.join(REPO, "Data", "Wave.lua")) as f:
        for line in f:
            m = re.match(r'\s*\["([^"]+)"\]=true', line)
            if m:
                playable.append(m.group(1))
    return cards, playable


def capacity(cards, ids):
    return sum(1 if cards[c]["rarity"] == "LEGENDARY" else 2 for c in ids)


def pools(cards, playable, focus=None):
    """Pools of ~12 class cards plus neutrals until both copies make a 30-card deck with room to spare
    (Legendaries count once). `focus` (card ids) restricts the class/neutral cards being swept."""
    rng = random.Random(7)
    by_family = collections.defaultdict(list)
    for cid in playable:
        by_family[cards[cid]["family"]].append(cid)
    neutrals = by_family.pop("NEUTRAL", [])
    rng.shuffle(neutrals)
    targets = set(focus) if focus else None
    out, ni = [], 0

    def fill(chunk):
        nonlocal ni
        pool = list(chunk)
        while capacity(cards, pool) < 40:
            n = neutrals[ni % len(neutrals)]
            ni += 1
            if n not in pool:
                pool.append(n)
        return pool

    for family, ids in sorted(by_family.items()):
        ids = [c for c in ids if not targets or c in targets]
        rng.shuffle(ids)
        for i in range(0, len(ids), 12):
            out.append((family, fill(ids[i:i + 12])))
    rest = [n for n in neutrals if not targets or n in targets]
    for i in range(0, len(rest), 14):
        out.append((None, fill(rest[i:i + 14])))
    return out


NAMES_BY_FIRST = collections.defaultdict(list)


def index_names(cards):
    for c in cards.values():
        NAMES_BY_FIRST[c["name"].split(" ")[0]].append(c["name"])


def run(index, entry, matches):
    family, pool = entry
    os.makedirs(OUT, exist_ok=True)
    pool_path = os.path.join(OUT, "pool-%d.txt" % index)
    trace_path = os.path.join(OUT, "trace-%d.jsonl" % index)
    with open(pool_path, "w") as f:
        f.write("\n".join(pool) + "\n")
    with open(trace_path, "w") as f:
        r = subprocess.run([TRACE, "--data", DATA, "--pool", pool_path, "--seed", str(SEED_BASE + index * 17),
                            "--matches", str(matches)] + (["--family", family] if family else [])
                           + (["--prefer", "|".join(PREFER)] if PREFER else []),
                           stdout=f, stderr=subprocess.PIPE, text=True)
    if r.returncode != 0:
        return index, "trace failed: " + r.stderr[-300:], set()
    played = set()
    with open(trace_path) as f:
        for line in f:
            if '"t":"step"' not in line:
                continue
            step = json.loads(line)
            move = step["moves"][step["chosen"]] if step.get("chosen") is not None else None
            if move and move["action"] in ("play", "trade", "forge", "activate"):
                desc = re.sub(r" #[\d.]+$", "", move["desc"])
                verb, _, rest = desc.partition(" ")
                # The longest card name the description starts with ("Lay on Hands on enemy hero").
                best = None
                for n in NAMES_BY_FIRST.get(rest.split(" ")[0], ()):
                    if rest.startswith(n) and (best is None or len(n) > len(best)):
                        best = n
                if best:
                    played.add(best)
    r = subprocess.run(["luajit", "tests/trace.lua", trace_path], cwd=REPO, capture_output=True, text=True)
    ok = r.returncode == 0
    if ok:
        os.remove(trace_path)
    return index, None if ok else (r.stdout + r.stderr)[-1500:], played


def main():
    matches = int(sys.argv[1]) if len(sys.argv) > 1 else 4
    workers = int(sys.argv[2]) if len(sys.argv) > 2 else 4
    cards, playable = load_cards()
    index_names(cards)
    focus = None
    if len(sys.argv) > 3 and sys.argv[3] == "--never":
        # Re-sweep only the cards the last report never saw played (more matches, other seeds).
        with open(os.path.join(OUT, "report.json")) as f:
            focus = json.load(f)["neverPlayed"]
        PREFER.extend(sorted({cards[c]["name"] for c in focus}))
    batches = pools(cards, playable, focus)
    print("%d playable cards in %d pools, %d matches each" % (len(playable), len(batches), matches), flush=True)
    played, failures = set(), {}
    with concurrent.futures.ThreadPoolExecutor(workers) as ex:
        futures = [ex.submit(run, i, p, matches) for i, p in enumerate(batches)]
        for n, fut in enumerate(concurrent.futures.as_completed(futures), 1):
            i, err, names = fut.result()
            played |= names
            if err:
                failures[i] = err
                print("pool %d: DIVERGENCE\n%s" % (i, err), flush=True)
            if n % 20 == 0:
                print("%d/%d pools, %d divergent" % (n, len(batches), len(failures)), flush=True)
    swept = set(focus) if focus else set(playable)
    never = sorted(cid for cid in swept if cards[cid]["name"] not in played)
    report = {"cards": len(swept), "pools": len(batches), "matches": len(batches) * matches,
              "divergentPools": sorted(failures), "neverPlayed": never,
              "neverPlayedNames": [cards[c]["name"] for c in never]}
    with open(os.path.join(OUT, "report-never.json" if focus else "report.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("cards %d, played %d, never played %d, divergent pools %d" % (
        len(swept), len(swept) - len(never), len(never), len(failures)))


if __name__ == "__main__":
    main()
