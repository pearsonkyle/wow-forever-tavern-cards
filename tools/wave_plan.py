#!/usr/bin/env python3
"""Which cards can the Lua engine play yet, and what to port next.

    python3 tools/wave_plan.py                 # report + write Data/Wave.lua
    python3 tools/wave_plan.py --target classic   # what the Classic set still needs
    python3 tools/wave_plan.py --pool FILE      # also write the playable ids (for tavern-trace --pool)

A card is playable when every capability it uses is listed in tools/implemented.json. Capabilities
are named like `op:DAMAGE`, `trigger:BATTLECRY`, `cond:COMBO`, `side:ENEMY_MINIONS`, `kw:taunt`,
`flag:secret`, `mod:discoverSummon`. A card also needs everything the cards it creates need.
"""
import collections
import json
import os
import sys

from common import KEYWORD_BITS, REPO, VALUE_FIELDS, WORDING_FIELDS, is_default, load_runtime, write

CLASSIC_PREFIXES = ("CS2_", "EX1_", "NEW1_", "DS1_", "CS1_")
PROGRAM_FLAGS_SKIP = {"effects", "choices", "program", "implemented", "displayText", "approximate", "keywords",
                      "madeOnly"}
ENUM_FIELDS = {
    "op": "op", "trigger": "trigger", "condition": "cond", "amountSource": "amountSource", "costCount": "costCount",
    "valueSource": "valueSource", "followUpCondition": "followUp",
}


def effect_reqs(effect, out):
    for field, value in effect.items():
        if field in WORDING_FIELDS or field in VALUE_FIELDS:
            continue
        if field in ("followUp", "replacement"):
            out.add("mod:" + field)
            for sub in value:
                effect_reqs(sub, out)
        elif field == "target":
            out.add("target:" + value["kind"])
            out.add("side:" + value["side"])
        elif field in ENUM_FIELDS:
            if value not in ("", "NONE"):
                out.add(ENUM_FIELDS[field] + ":" + value)
        elif field == "keyword":
            if value:
                out.add("kw:" + value)
        elif not is_default(field, value):
            out.add("mod:" + field)


def card_reqs(card, program):
    out = set()
    for name, bit in KEYWORD_BITS.items():
        if card["keywords"] & bit and name not in ("battlecry", "deathrattle"):  # text markers only
            out.add("kw:" + name)
    out.add("type:" + card["type"])
    if program:
        for key, value in program.items():
            if key in PROGRAM_FLAGS_SKIP or is_default(key, value):
                continue
            out.add("flag:" + key)
        for effect in program.get("effects", []):
            effect_reqs(effect, out)
        for option in program.get("choices", []):
            out.add("flag:choices")
            for effect in option:
                effect_reqs(effect, out)
    return out


def main():
    args = sys.argv[1:]
    cards, programs_doc, playable = load_runtime()
    programs = programs_doc["programs"]
    by_id = {c["id"]: c for c in cards}

    with open(os.path.join(REPO, "tools", "implemented.json")) as f:
        implemented = set(json.load(f)["capabilities"])

    own = {cid: card_reqs(by_id[cid], programs.get(cid)) for cid in by_id
           if by_id[cid]["implemented"] or cid in programs}

    # Cards an effect creates by id (tokens, discover lists...) contribute their own needs.
    refs = collections.defaultdict(set)
    for cid, prog in programs.items():
        stack = list(prog.get("effects", [])) + [e for o in prog.get("choices", []) for e in o]
        while stack:
            e = stack.pop()
            for key in ("token", "deckCostToken"):
                if e.get(key) in by_id:
                    refs[cid].add(e[key])
            for t in e.get("tokens", []):
                if t in by_id:
                    refs[cid].add(t)
            stack.extend(e.get("followUp", []))
            stack.extend(e.get("replacement", []))

    full = {}

    def needs(cid, seen=()):
        if cid in full:
            return full[cid]
        total = set(own.get(cid) or card_reqs(by_id[cid], None))
        for ref in refs.get(cid, ()):
            if ref not in seen:
                total |= needs(ref, seen + (cid,))
        full[cid] = total
        return total

    for cid in playable:
        needs(cid)

    if "*" in implemented:
        implemented = set().union(*full.values())
    ready = sorted(cid for cid in playable if full[cid] <= implemented)
    print("playable now: %d of %d (capabilities implemented: %d)" % (len(ready), len(playable), len(implemented)))

    target = playable
    if "--target" in args and args[args.index("--target") + 1] == "classic":
        target = [cid for cid in playable if cid.startswith(CLASSIC_PREFIXES)]
        union = set().union(*(full[c] for c in target))
        missing = sorted(union - implemented)
        print("classic set: %d cards, %d capabilities, %d missing:" % (len(target), len(union), len(missing)))
        for kind, group in collections.Counter(m.split(":")[0] for m in missing).most_common():
            print("  %-12s %s" % (kind, ", ".join(m.split(":", 1)[1] for m in missing if m.startswith(kind + ":"))))

    # Next best: capabilities ranked by how many target cards become playable with that one more.
    blockers = collections.Counter()
    unlock = collections.Counter()
    for cid in target:
        miss = full[cid] - implemented
        for m in miss:
            blockers[m] += 1
        if len(miss) == 1:
            unlock[next(iter(miss))] += 1
    print("\nnext capabilities (cards unlocked alone / cards blocked):")
    for cap, n in sorted(blockers.items(), key=lambda kv: (-unlock[kv[0]], -kv[1]))[:25]:
        print("  %-40s %4d / %4d" % (cap, unlock[cap], n))

    lines = ["-- GENERATED by tools/wave_plan.py. Cards the Lua engine can play with this build.",
             "local TC = TavernCards_NS",
             "TC.PlayableNow = {"]
    lines += ['  ["%s"]=true,' % cid for cid in ready]
    lines.append("}")
    write("Data/Wave.lua", "\n".join(lines) + "\n")

    if "--pool" in args:
        path = args[args.index("--pool") + 1]
        with open(path, "w") as f:
            f.write("\n".join(ready) + "\n")
        print("wrote", path)


if __name__ == "__main__":
    main()
