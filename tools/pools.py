#!/usr/bin/env python3
"""Card pools for tavern-trace --pool: the cards a reference trace may put in decks.

    python3 tools/pools.py      # writes tools/cache/pools/{vanilla,classic,basic,all}.txt

vanilla  minions with no effects at all (stats and keywords only)
basic    the Basic (FREE) set
classic  the Classic set plus Basic (wave 1)
all      every playable card
"""
import os

from common import CACHE, load_runtime

CLASSIC_PREFIXES = ("CS2_", "EX1_", "NEW1_", "DS1_", "CS1_")


def main():
    cards, programs_doc, playable = load_runtime()
    by_id = {c["id"]: c for c in cards}
    programs = programs_doc["programs"]
    pools = {
        "vanilla": [c for c in playable if by_id[c]["type"] == "MINION" and not programs.get(c, {}).get("effects")
                    and not programs.get(c, {}).get("choices")],
        "basic": [c for c in playable if by_id[c]["rarity"] == "FREE"],
        "classic": [c for c in playable if c.startswith(CLASSIC_PREFIXES) or by_id[c]["rarity"] == "FREE"],
        "all": list(playable),
    }
    folder = os.path.join(CACHE, "pools")
    os.makedirs(folder, exist_ok=True)
    for name, ids in pools.items():
        with open(os.path.join(folder, name + ".txt"), "w") as f:
            f.write("\n".join(sorted(ids)) + "\n")
        print("%-8s %4d cards" % (name, len(ids)))


if __name__ == "__main__":
    main()
