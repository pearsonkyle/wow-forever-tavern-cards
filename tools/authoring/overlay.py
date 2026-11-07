#!/usr/bin/env python3
"""Our card-authoring overlay on top of jankcraft's data (which stays read-only).

    python3 tools/authoring/overlay.py init    # tools/cache/sim/data = jankcraft data + our authored programs
    python3 tools/authoring/overlay.py save    # our additions (vs jankcraft) -> tools/authoring/overlay.json
    python3 tools/authoring/overlay.py status  # playable counts: jankcraft vs overlay

The authoring loop (copied from jankcraft into tools/authoring/, rooted at tools/cache/sim):
    python3 tools/authoring/author_llm.py --block <name> --limit 40 --url <LLM>/v1/chat/completions --model <m>
    python3 tools/authoring/author_apply.py --block tools/cache/sim/data/authoring/blocks/<name> --apply
Every candidate is checked by jankcraft's own `tavern-sim author-verify` (run, never modified), and a
block only lands if the data still compiles, verifies and coverage doesn't regress. Then `save` records
the additions here, `tools/export_data.py` (TC_DATA=overlay) regenerates the addon's data, and
`tests/fuzz.sh` replays the C++ engine against the Lua port on the new cards.
"""
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
JANKCRAFT = os.environ.get("JANKCRAFT", os.path.expanduser("~/Programs/misc/wow/jankcraft"))
UPSTREAM = os.path.join(JANKCRAFT, "server", "modules", "mod-tavern-sim")
SIM_ROOT = os.path.join(REPO, "tools", "cache", "sim")
DATA = os.path.join(SIM_ROOT, "data")
SAVED = os.path.join(HERE, "overlay.json")
SIM = os.path.join(UPSTREAM, "build-local", "tavern-sim")


def load(path):
    with open(path) as f:
        return json.load(f)


def run(*args):
    return subprocess.run([SIM, *args], cwd=SIM_ROOT, text=True, capture_output=True)


def cmd_init():
    if os.path.exists(DATA):
        shutil.rmtree(DATA)
    shutil.copytree(os.path.join(UPSTREAM, "data"), DATA)
    os.makedirs(os.path.join(SIM_ROOT, "build-local"), exist_ok=True)
    link = os.path.join(SIM_ROOT, "build-local", "tavern-sim")
    if os.path.lexists(link):
        os.remove(link)
    os.symlink(SIM, link)
    if os.path.exists(SAVED):
        saved = load(SAVED)
        authored = load(os.path.join(DATA, "authored.json"))
        authored["programs"].update(saved.get("programs", {}))
        with open(os.path.join(DATA, "authored.json"), "w") as f:
            json.dump(authored, f, sort_keys=True, indent=2)
        for command in (["compile", "--data", DATA], ["verify-data", "--data", DATA, "--update-baselines"]):
            r = run(*command)
            if r.returncode != 0:
                sys.exit("%s failed:\n%s" % (command[0], (r.stderr or r.stdout)[-2000:]))
        print("overlay: %d authored programs re-applied" % len(saved.get("programs", {})))
    cmd_status()


def cmd_save():
    upstream = load(os.path.join(UPSTREAM, "data", "authored.json"))["programs"]
    ours = load(os.path.join(DATA, "authored.json"))["programs"]
    added = {k: v for k, v in ours.items() if upstream.get(k) != v}
    with open(SAVED, "w") as f:
        json.dump({"programs": added}, f, sort_keys=True, indent=1)
    print("saved %d authored programs -> %s" % (len(added), SAVED))


def cmd_status():
    up = len(load(os.path.join(UPSTREAM, "data", "playable.json"))["ids"])
    ov = len(load(os.path.join(DATA, "playable.json"))["ids"]) if os.path.exists(DATA) else 0
    print("playable: jankcraft %d, overlay %d (+%d)" % (up, ov, ov - up))


if __name__ == "__main__":
    {"init": cmd_init, "save": cmd_save, "status": cmd_status}[sys.argv[1]]()
