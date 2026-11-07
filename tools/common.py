"""Shared paths and loaders for the build tools.

Card data comes from jankcraft's engine as loaded at runtime (tools/trace/tavern-trace --dump-*),
never from the raw JSON files, so the Lua port sees exactly what the C++ engine executes.
"""
import json
import os
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JANKCRAFT = os.environ.get("JANKCRAFT", os.path.expanduser("~/Programs/misc/wow/jankcraft"))
MODULE = os.path.join(JANKCRAFT, "server", "modules", "mod-tavern-sim")
DATA = os.path.join(MODULE, "data")
CACHE = os.path.join(REPO, "tools", "cache")
TRACE = os.path.join(REPO, "tools", "trace", "tavern-trace")

# Engine keyword bits (src/tc/card.h enum Keyword).
KEYWORD_BITS = {
    "taunt": 1 << 0, "charge": 1 << 1, "rush": 1 << 2, "divine_shield": 1 << 3, "windfury": 1 << 4,
    "lifesteal": 1 << 5, "stealth": 1 << 6, "poisonous": 1 << 7, "freeze": 1 << 8, "reborn": 1 << 9,
    "elusive": 1 << 10, "spell_damage": 1 << 11, "battlecry": 1 << 12, "deathrattle": 1 << 13,
    "cant_attack": 1 << 14, "immune": 1 << 15, "immune_attacking": 1 << 16, "miniaturize": 1 << 17,
}

# Print-only effect fields: they shape the card text, not what the engine does.
WORDING_FIELDS = {
    "wording", "sourcePhrase", "tokenDisplay", "explodesWording", "resummonNoun", "previousPlural",
    "setVerb", "takeVerb", "repeatPrinted", "tokenUnnamed",
}

# Effect fields that are plain values (a number, a card id) rather than a capability.
VALUE_FIELDS = {"amount", "amount2", "token", "tokens", "repeat", "conditionAmount", "costMin", "costMax"}

DEFAULTS = {"repeat": 1}


def is_default(field, value):
    if field in DEFAULTS:
        return value == DEFAULTS[field]
    return value in (False, 0, "", None, [], {})


def ensure_dumps(force=False):
    """Refresh tools/cache/runtime_{cards,programs}.json from the engine when missing or stale."""
    os.makedirs(CACHE, exist_ok=True)
    cards = os.path.join(CACHE, "runtime_cards.json")
    programs = os.path.join(CACHE, "runtime_programs.json")
    sources = [os.path.join(DATA, "catalogue.json"), os.path.join(DATA, "programs.json")]
    stale = force or not all(os.path.exists(p) for p in (cards, programs)) or any(
        os.path.getmtime(s) > os.path.getmtime(cards) for s in sources
    )
    if stale:
        if not os.path.exists(TRACE):
            sys.exit("tavern-trace is not built: bash tools/trace/build.sh")
        subprocess.check_call([TRACE, "--data", DATA, "--dump-programs", programs, "--dump-cards", cards])
    return cards, programs


def load_runtime():
    cards_path, programs_path = ensure_dumps()
    with open(cards_path) as f:
        cards = json.load(f)
    with open(programs_path) as f:
        programs = json.load(f)
    with open(os.path.join(DATA, "playable.json")) as f:
        playable = json.load(f)["ids"]
    return cards, programs, playable


def lua_string(s):
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif o < 32:
            out.append("\\%03d" % o)
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def lua_value(v, indent=""):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return lua_string(v)
    if v is None:
        return "nil"
    if isinstance(v, list):
        return "{" + ",".join(lua_value(x, indent) for x in v) + "}"
    if isinstance(v, dict):
        parts = []
        for k in sorted(v):
            key = k if k.isidentifier() and k not in LUA_KEYWORDS else "[" + lua_string(k) + "]"
            parts.append(key + "=" + lua_value(v[k], indent))
        return "{" + ",".join(parts) + "}"
    raise TypeError(type(v))


LUA_KEYWORDS = {
    "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in", "local",
    "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
}


def write(path, text):
    full = os.path.join(REPO, path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w", newline="\n") as f:
        f.write(text)
    print("wrote %s (%d KB)" % (path, len(text.encode()) // 1024))
