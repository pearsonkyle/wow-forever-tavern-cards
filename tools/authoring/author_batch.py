#!/usr/bin/env python3
"""Unattended batch author loop.

Scans refused cards, emits flat programs, merges them into authored.json, then compiles and
validates. Any newly added entry named in a validation problem is removed and the loop retries.
Existing authored entries are never touched.

Requires a built /tmp/tav (TAVERN_SIM) and the scanner binary (AUTHOR_SCAN).
"""

import json
import os
import subprocess
import sys
from pathlib import Path

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
DATA = ROOT / "data"
AUTHORED = DATA / "authored.json"
SIM = Path(os.environ.get("TAVERN_SIM", "/tmp/tav/tavern-sim"))
SCAN = Path(os.environ.get("AUTHOR_SCAN", "/tmp/author_scan"))


def run(*args, check=True):
    return subprocess.run(args, cwd=ROOT, text=True, capture_output=True, check=check)


def emit():
    if not SCAN.exists():
        raise SystemExit(f"scanner missing: {SCAN}")
    result = run(str(SCAN), "data", "--emit")
    entries = {}
    for line in result.stdout.splitlines():
        if not line.startswith("PROGRAM\t"):
            continue
        _, card_id, blob = line.split("\t", 2)
        entries[card_id] = json.loads(blob)
    return entries


def compile_and_validate():
    run(str(SIM), "compile", "--data", "data")
    result = run(str(SIM), "validate", "--data", "data", check=False)
    problems = set()
    for line in (result.stdout + result.stderr).splitlines():
        if ":" in line and not line.startswith("validate"):
            problems.add(line.split(":", 1)[0].strip())
    return result.returncode == 0, problems


def main():
    authored = json.loads(AUTHORED.read_text())
    added = []
    for card_id, program in emit().items():
        if card_id in authored["programs"]:
            continue
        program["implemented"] = True
        authored["programs"][card_id] = program
        added.append(card_id)
    if not added:
        print("author_batch: no new candidates")
        return 0

    for _ in range(4):
        AUTHORED.write_text(json.dumps(authored, indent=2) + "\n")
        ok, problems = compile_and_validate()
        if ok and not problems:
            print(f"author_batch: added {len(added)}: {' '.join(added)}")
            return 0
        bad = [card_id for card_id in added if card_id in problems]
        if not bad:
            print(f"author_batch: validation problems outside this batch: {sorted(problems)}")
            return 1
        for card_id in bad:
            authored["programs"].pop(card_id, None)
            added.remove(card_id)
        print(f"author_batch: dropped {len(bad)}: {' '.join(bad)}")
        if not added:
            AUTHORED.write_text(json.dumps(authored, indent=2) + "\n")
            print("author_batch: no candidates survived validation")
            return 0
    print("author_batch: too many validation retries")
    return 1


if __name__ == "__main__":
    sys.exit(main())
