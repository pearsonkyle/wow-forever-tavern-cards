#!/usr/bin/env python3
"""Describe every card's picture with a local LLM (tools/cache/icon_subjects.json), the input to
tools/icons/catalog.py assign, and score the curated vocabulary (tools/icons/vocab.txt) for each card.

    python3 tools/match_icons.py                 # describe what's not cached yet
    python3 tools/match_icons.py --write-only    # just recompute the vocabulary picks
    LLM_URL=http://host:1234/v1 python3 tools/match_icons.py

Answers are cached in tools/cache/icons.json (card id -> icon name). Only names from the vocabulary are
accepted; anything else is left to the addon's own rules (UI/Art.lua). In game, /tc icons reports any
vocabulary icon the client doesn't have.
"""
import concurrent.futures
import json
import os
import re
import sys
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LLM_URL = os.environ.get("LLM_URL", "http://localhost:1234/v1")
CACHE = os.path.join(REPO, "tools", "cache", "icon_subjects.json")
BATCH = 25
WORKERS = 4

RACES = ["beast", "undead", "elemental", "mechanical", "dragon", "demon", "pirate", "murloc", "draenei", "naga",
         "totem", "quilboar", "all"]
CARD_RE = re.compile(r'^C\("([^"]+)","((?:[^"\\]|\\.)*)","(\w+)","(\w+)","(\w+)","(\w*)",(-?\d+),(-?\d+),(-?\d+),(-?\d+),(\d+),(\d+),(\d+),(-?\d+),"((?:[^"\\]|\\.)*)"')


def load_vocab():
    vocab = []
    with open(os.path.join(REPO, "tools", "icons", "vocab.txt")) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            name, desc = line.split("|", 1)
            vocab.append((name.strip(), desc.strip()))
    return vocab


def load_cards():
    cards = []
    with open(os.path.join(REPO, "Data", "Cards.lua")) as f:
        for line in f:
            m = CARD_RE.match(line)
            if not m:
                continue
            cid, name, ctype, family, rarity, school = m.group(1, 2, 3, 4, 5, 6)
            races = int(m.group(12))
            text = m.group(15).replace("\\n", " ")
            text = re.sub(r"<[^>]+>|\[x\]|[$#@]", "", text)
            tribes = [r for i, r in enumerate(RACES) if races & (1 << i)]
            cards.append({"id": cid, "name": name, "type": ctype, "class": family, "tribe": "/".join(tribes),
                          "flags": int(m.group(13)),
                          "school": school, "text": text[:90]})
    return cards


STOP = set("a an the of and or with in on its his her their to from for at by small large big tiny giant "
           "holding wearing who that is are card picture shows man woman person creature figure glowing dark armored "
           "powerful mighty wild fierce massive huge little young old evil angry crazed brave swift strange magical "
           "mysterious beast monster".split())


def words(text):
    out = []
    for w in re.findall(r"[a-z']+", text.lower()):
        w = w.strip("'")
        if len(w) < 3 or w in STOP:
            continue
        out.append(w[:-1] if w.endswith("s") and len(w) > 4 else w)
    return out


NAME_SKIP = ("ability", "spell", "pet", "hunter", "achievement", "character", "boss", "misc", "inv", "mount", "weapon",
             "warrior", "rogue", "druid", "racial", "head", "male", "female", "primal")


# (description words, words from the icon's file name). Description words count fully, file-name words half.
def icon_words(name, desc):
    parts = re.findall(r"[A-Z]?[a-z]+|[A-Z]+(?![a-z])", name)
    return set(words(desc)), set(words(" ".join(p for p in parts if p.lower() not in NAME_SKIP)))


# Card -> best vocabulary icon by word overlap: the card name counts most, then the LLM's description of the
# picture, then the tribe. Males by default for "character" icons unless the words say woman/female.
def pick(card, subject, vocab):
    name_w, subj_w = words(card["name"]), words(subject)
    extra = words(card["tribe"]) + ([card["school"]] if card["school"] else [])
    female = bool(re.search(r"\b(woman|female|girl|lady|queen|priestess|sister|she|her)\b", subject.lower() + " " + card["name"].lower()))
    best, best_score = None, 0
    for name, desc in vocab:
        dw, nw = icon_words(name, desc)

        def hit(w):
            return 1 if w in dw else (0.5 if w in nw else 0)
        score = 3 * sum(hit(w) for w in name_w) + 2 * sum(hit(w) for w in subj_w) + 3 * sum(hit(w) for w in extra)
        if score == 0:
            continue
        if card["type"] == "SPELL" and not name.startswith(("Spell_", "Ability_", "INV_Misc_", "INV_Elemental", "Achievement_Boss")):
            score -= 1
        if card["type"] == "MINION" and name.startswith("Spell_") and not ("Summon" in name or "Elemental" in name or "Totem" in name or "Haunting" in name or "Raise" in name or "Animate" in name or "Wisp" in name or "Faerie" in name):
            score -= 1
        if name.endswith("_Female") and not female:
            score -= 0.5
        if name.endswith("_Male") and female:
            score -= 0.5
        if score > best_score:
            best, best_score = name, score
    return best


def ask(system, user):
    body = json.dumps({
        "model": os.environ.get("LLM_MODEL", "gemma4-31b-imatrix-mtp"),
        "temperature": 0,
        "max_tokens": 2000,
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }).encode()
    req = urllib.request.Request(LLM_URL + "/chat/completions", data=body, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=180) as r:
        return json.load(r)["choices"][0]["message"]["content"]


def main():
    vocab = load_vocab()
    described = {}
    if os.path.exists(CACHE):
        with open(CACHE) as f:
            described = json.load(f)
    cards = load_cards()

    if "--write-only" not in sys.argv:
        todo = [c for c in cards if c["id"] not in described]
        print("cards: %d, described: %d, to describe: %d" % (len(cards), len(described), len(todo)), flush=True)
        system = (
            "For each numbered fantasy card (World of Warcraft themed), say in 3-8 plain words what its picture "
            "shows: the creature, person or object. Use the card name first. WoW lore: a snapjaw is a turtle, a "
            "crocolisk a crocodile, a yeti a furry ape, a kobold a rat-like miner, a gnoll a hyena-man, a grunt an "
            "orc warrior, a murloc a fish-man, a naga a snake-woman, a wisp a tiny spirit light. For people give "
            "race and role (human knight, goblin engineer). For spells, the visible effect. "
            "Answer exactly one line per card, in order: <number>. <words>")

        def work(batch):
            lines = ["%d. %s (%s %s%s%s) %s" % (i + 1, c["name"], c["class"].lower(), c["type"].lower(),
                                                ", " + c["tribe"] if c["tribe"] else "",
                                                ", " + c["school"] if c["school"] else "", c["text"][:60])
                     for i, c in enumerate(batch)]
            try:
                out = ask(system, "\n".join(lines))
            except Exception as e:  # noqa: BLE001
                return batch, {}, str(e)
            found = dict((int(n), w.strip()) for n, w in re.findall(r"^\s*(\d+)[.)]\s*(.+?)\s*$", out or "", re.M))
            return batch, {batch[n - 1]["id"]: w for n, w in found.items() if 1 <= n <= len(batch)}, None

        batches = [todo[i:i + BATCH] for i in range(0, len(todo), BATCH)]
        done = 0
        with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
            for batch, answer, err in pool.map(work, batches):
                done += 1
                if err:
                    print("batch %d failed: %s" % (done, err), flush=True)
                    continue
                described.update(answer)
                print("batch %d/%d: %d/%d described" % (done, len(batches), len(answer), len(batch)), flush=True)
                os.makedirs(os.path.dirname(CACHE), exist_ok=True)
                with open(CACHE, "w") as f:
                    json.dump(described, f, indent=0, sort_keys=True)

    picks = {c["id"]: pick(c, described.get(c["id"], ""), vocab) for c in cards}
    picks = {k: v for k, v in picks.items() if v}

    # Data/Icons.lua is written by tools/icons/catalog.py assign (which also uses these picks as a bonus).
    with open(os.path.join(REPO, "tools", "cache", "vocab_picks.json"), "w") as f:
        json.dump(picks, f, indent=0, sort_keys=True)
    print("described %d cards; vocabulary picks for %d -> tools/cache/vocab_picks.json" % (len(described), len(picks)))


if __name__ == "__main__":
    main()
