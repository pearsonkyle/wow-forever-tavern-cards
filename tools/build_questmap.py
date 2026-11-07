#!/usr/bin/env python3
"""Assign a card to every WoW Forever quest, once per class.

    python3 tools/build_questmap.py            # writes Data/QuestMap.lua and prints a coverage report

Every class gets its own map over its class cards plus neutrals, so whatever quest a character turns in,
the card is one they can put in a deck. Within one faction's quests a card is handed out at most as
many times as a deck may hold it (2, or 1 for a legendary); only when a class runs out of room does a
quest repeat a card (the duplicate becomes dust in game).

Scoring, per quest x card:
  rarity  from the quest's content: level band, dungeon (epic), raid (legendary)
  cost    cards near the quest's level band (level / 6)
  theme   the quest's creatures share the card's tribe (murlocs, dragons ...), and much more when the
          card's name appears in the quest or in its creatures' names (Hogger, Onyxia ...)
Quest data: Questie's Forever database (tools/questie.py), read at build time only.
"""
import collections
import json
import os
import re
import zlib

from common import CACHE, REPO, load_runtime, lua_string, write
from questie import QuestieDB, at, lua_list

CLASSES = {  # Questie requiredClasses bit -> card family (= UnitClass token)
    0: "WARRIOR", 1: "PALADIN", 2: "HUNTER", 3: "ROGUE", 4: "PRIEST", 6: "SHAMAN", 7: "MAGE", 8: "WARLOCK",
    10: "DRUID",
}
ALLIANCE, HORDE = 1 | 4 | 8 | 64, 2 | 16 | 32 | 128
RARITIES = ["FREE", "COMMON", "RARE", "EPIC", "LEGENDARY"]
RACE_BITS = ["beast", "undead", "elemental", "mechanical", "dragon", "demon", "pirate", "murloc", "draenei",
             "naga", "totem", "quilboar"]

TRIBE_WORDS = {
    "beast": "wolf wolves boar bear spider raptor crocolisk gorilla panther tiger lion hyena vulture buzzard owl "
             "bat scorpid basilisk kodo plainstrider stag crab turtle worg serpent snake crawler lurker prowler "
             "stalker cat strider thunder lizard wyvern hippogryph silithid moth",
    "undead": "undead skeleton skeletal zombie ghoul scourge ghost banshee lich plague abomination wight risen "
              "rotting forsaken? haunt wraith spectral",
    "elemental": "elemental lava magma flame fire elementals tempest earthen water spirit infernal living",
    "mechanical": "mechanical mechano robot golem shredder harvest reaper mech gnomeregan steam tank",
    "dragon": "dragon whelp drake dragonkin wyrm dragonflight onyxia nefarian brood",
    "demon": "demon imp felguard satyr succubus voidwalker felhound doomguard infernal legion fel demonic",
    "pirate": "pirate bloodsail buccaneer swashbuckler corsair captain",
    "murloc": "murloc murlocs mrgl",
    "naga": "naga siren myrmidon",
    "totem": "totem",
    "quilboar": "quilboar razormane bristleback razorfen",
}
STOP = set("the and with from that this your their into have will them were what when where which must card "
           "minion minions spell battlecry deathrattle summon damage health attack enemy friendly random "
           "lord lady king queen chief elder master great guardian warrior mage priest rogue hunter druid "
           "shaman warlock paladin bring kill slay return speak find collect".split())
COMMON = set("rage power fate echoes book war blood shadow light dark fire storm stone iron gold silver "
             "black white water earth wind frost death life soul heart mind spirit night ancient sacred "
             "captain hunter keeper watcher guard champion defender servant agent".split())
RAIDS = {"Molten Core", "Onyxia's Lair", "Blackwing Lair", "Zul'Gurub", "Ruins of Ahn'Qiraj", "Temple of Ahn'Qiraj",
         "Naxxramas", "Karazhan", "Hyjal Summit", "Serpentshire Cavern"}


def words(text):
    return [w for w in re.findall(r"[a-z']+", (text or "").lower().replace("'s", "")) if len(w) >= 4]


def dungeon_zones():
    path = os.path.join(CACHE, "questie", "QuestieDB", "support", "Forever", "Zones", "dungeons.lua")
    dungeons, raids = set(), set()
    if not os.path.exists(path):
        import zipfile
        with zipfile.ZipFile(os.path.join(CACHE, "questie", "questie.zip")) as z:
            z.extract("QuestieDB/support/Forever/Zones/dungeons.lua", os.path.join(CACHE, "questie"))
    for m in re.finditer(r'\[(\d+)\]\s*=\s*\{"([^"]+)",(nil|\{[^}]*\})', open(path, encoding="utf-8").read()):
        ids = [int(m.group(1))] + ([int(x) for x in re.findall(r"\d+", m.group(3))] if m.group(3) != "nil" else [])
        (raids if m.group(2) in RAIDS else dungeons).update(ids)
    return dungeons, raids


def stable(*parts):
    return zlib.crc32(":".join(map(str, parts)).encode())


def main():
    cards, _, playable = load_runtime()
    by_id = {c["id"]: c for c in cards}
    db = QuestieDB.load()
    dungeons, raids = dungeon_zones()
    tribe_lookup = {w: tribe for tribe, ws in TRIBE_WORDS.items() for w in ws.split()}

    # ---- quests ---------------------------------------------------------------------------------
    quests = []
    for q in db.quests.values():
        if (q.get("specialFlags") or 0) & 1:
            continue  # repeatable: no card (it would pay forever)
        races = (q.get("requiredRaces") or 0) & 0xFFFFFFFF
        views = [v for v, mask in (("A", ALLIANCE), ("H", HORDE)) if races == 0 or races & mask]
        if not views:
            continue
        level = q.get("questLevel") or 0
        if level <= 0:
            level = q.get("requiredLevel") or 30
        zone = q.get("zoneOrSort") or 0
        kind = "raid" if zone in raids else "dungeon" if zone in dungeons else "normal"
        text = [q.get("name") or ""] + lua_list(q.get("objectivesText"))
        for entry in lua_list(at(q.get("objectives"), 1)):  # creature objectives: {npcId, text, ...}
            npc = db.npcs.get(at(entry, 1))
            if npc:
                text.append(npc.get("name") or "")
        for npc_id in lua_list(at(q.get("startedBy"), 1)):  # quest givers: {npcs, objects, items}
            npc = db.npcs.get(npc_id)
            if npc:
                text.append(npc.get("name") or "")
        ws = set(w for t in text for w in words(t))
        raw = " " + " ".join(re.sub(r"[^a-z' ]", " ", t.lower()) for t in text) + " "
        quests.append({
            "raw": raw,
            "id": q["id"], "level": max(1, min(60, level)), "kind": kind, "views": views,
            "classes": q.get("requiredClasses") or 0, "words": ws,
            "tribes": {tribe_lookup[w] for w in ws if w in tribe_lookup},
        })
    quests.sort(key=lambda q: q["id"])

    # Forever ships one copy of some quests per starting zone ("Camping 101: Cooking" x7) and flags
    # them all complete together. Copies sharing name, category/zone and level are one quest: the
    # lowest id is canonical, and only it is assigned a card.
    canon, seen = {}, {}
    for q in quests:
        raw = db.quests[q["id"]]
        key = ((raw.get("name") or "").strip().lower(), raw.get("zoneOrSort") or 0, q["level"])
        if key[0] and key in seen:
            canon[q["id"]] = seen[key]
        else:
            seen[key] = q["id"]
    quests = [q for q in quests if q["id"] not in canon]
    print("quest copies folded into their canonical quest:", len(canon))

    # ---- cards ----------------------------------------------------------------------------------
    pool = []
    for cid in playable:
        c = by_id[cid]
        if c["family"] in ("DEATHKNIGHT", "DEMONHUNTER"):
            continue  # no Forever class plays these; they come from packs
        name_words = set(words(c["name"])) - STOP
        head = re.sub(r"[^a-z' ]", " ", c["name"].split(",")[0].lower()).strip()
        pool.append({
            "head": head if len(head) >= 5 else None,
            "id": cid, "family": c["family"], "rarity": RARITIES.index(c["rarity"]), "cost": c["cost"],
            "tribes": {RACE_BITS[b] for b in range(len(RACE_BITS)) if c["races"] >> b & 1},
            "words": name_words, "cap": 1 if c["rarity"] == "LEGENDARY" else 2,
        })

    # A shared word only means something when it is rare on both sides ("hogger", not "rage").
    quest_df = collections.Counter(w for q in quests for w in q["words"])
    card_df = collections.Counter(w for c in pool for w in c["words"])
    for c in pool:
        c["words"] = {w for w in c["words"] if card_df[w] <= 2 and 0 < quest_df[w] <= 12 and w not in COMMON}
        # A one-word name ("Archmage", "Charge") is only a match when it is a rare proper name of a minion.
        if c["head"] and " " not in c["head"]:
            if by_id[c["id"]]["type"] != "MINION" or quest_df[c["head"]] > 6 or c["head"] in COMMON:
                c["head"] = None

    def target_rarity(q):
        if q["kind"] == "raid":
            return 4
        if q["kind"] == "dungeon":
            return 3
        return 1 if q["level"] < 20 else 2 if q["level"] < 45 else 3 if q["level"] >= 58 and q["classes"] else 2

    def score(q, c):
        s = 0
        tr = target_rarity(q)
        r = c["rarity"] if c["rarity"] > 0 else 1  # FREE plays like COMMON
        s += 30 if r == tr else 10 if abs(r - tr) == 1 else -20 * abs(r - tr)
        s -= 3 * abs(c["cost"] - min(10, round(q["level"] / 6)))
        if q["tribes"] & c["tribes"]:
            s += 25
        if c["head"] and (" " + c["head"] + " ") in q["raw"]:
            s += 200  # an exact name beats rarity and cost: Hogger belongs to the Hogger quest
        elif q["words"] & c["words"]:
            s += 20
        return s

    report = collections.Counter()
    maps = {}
    examples = []
    for bit, family in CLASSES.items():
        cls_quests = [q for q in quests if not q["classes"] or q["classes"] >> bit & 1]
        cls_cards = [c for c in pool if c["family"] in (family, "NEUTRAL")]
        word_index = collections.defaultdict(list)
        for c in cls_cards:
            for w in c["words"]:
                word_index[w].append(c)
        used = {(c["id"], v): 0 for c in cls_cards for v in "AH"}

        def has_room(c, q):
            return all(used[(c["id"], v)] < c["cap"] for v in q["views"])

        # Themed and rarer quests choose first, so the obvious matches are not used up by filler.
        def priority(q):
            named = any(c["head"] and (" " + c["head"] + " ") in q["raw"] for c in cls_cards) or \
                any(w in word_index for w in q["words"])
            return (0 if named else 1, {"raid": 0, "dungeon": 1, "normal": 2}[q["kind"]],
                    0 if q["classes"] else 1, -q["level"], q["id"])

        out = {}
        for q in sorted(cls_quests, key=priority):
            candidates = [c for c in cls_cards if has_room(c, q)]
            if not candidates:
                candidates = cls_cards
                report["over capacity"] += 1
            best = max(candidates, key=lambda c: (score(q, c) + (8 if c["family"] == family else 0),
                                                  stable(q["id"], c["id"], family)))
            for v in q["views"]:
                used[(best["id"], v)] += 1
            out[q["id"]] = best["id"]
            if best["head"] and (" " + best["head"] + " ") in q["raw"]:
                report["name match"] += 1
                if family == "WARRIOR" and len(examples) < 25:
                    examples.append("%s -> %s" % (db.quests[q["id"]]["name"], by_id[best["id"]]["name"]))
            elif q["words"] & best["words"]:
                report["word match"] += 1
            elif q["tribes"] & best["tribes"]:
                report["tribe match"] += 1
        maps[family] = out
        dist = collections.Counter(by_id[cid]["rarity"] for cid in out.values())
        distinct = len(set(out.values()))
        print("%-8s %4d quests -> %4d distinct cards (%d in pool)  %s" % (
            family, len(out), distinct, len(cls_cards), dict(sorted(dist.items()))))

    print("matches:", dict(report))
    print("examples (Warrior):\n  " + "\n  ".join(examples))

    # ---- Data/QuestMap.lua ----------------------------------------------------------------------
    lines = [
        "-- GENERATED by tools/build_questmap.py from Questie's Forever quest database. Do not edit.",
        "-- questID -> card id, per class. Only the player's class is kept after load.",
        "local TC = TavernCards_NS",
        "TC.QuestMap = {}",
        "-- Copies of one quest (per starting zone) -> the canonical id that pays.",
        "TC.QuestCanon = {",
    ]
    row = []
    for qid in sorted(canon):
        row.append("[%d]=%d" % (qid, canon[qid]))
        if len(row) == 16:
            lines.append(",".join(row) + ",")
            row = []
    if row:
        lines.append(",".join(row) + ",")
    lines.append("}")
    for family in CLASSES.values():
        lines.append("TC.QuestMap.%s = (function() return {" % family)
        row = []
        for qid in sorted(maps[family]):
            row.append("[%d]=%s" % (qid, lua_string(maps[family][qid])))
            if len(row) == 12:
                lines.append(",".join(row) + ",")
                row = []
        if row:
            lines.append(",".join(row) + ",")
        lines.append("} end)()")
    write("Data/QuestMap.lua", "\n".join(lines) + "\n")
    write_quest_info(db)


def quest_sorts():
    """Questie's quest category enum (negative zoneOrSort) -> display name."""
    path = os.path.join(CACHE, "questie", "QuestieDB", "src", "corrections", "enum", "quests.lua")
    if not os.path.exists(path):
        import zipfile
        with zipfile.ZipFile(os.path.join(CACHE, "questie", "questie.zip")) as z:
            z.extract("QuestieDB/src/corrections/enum/quests.lua", os.path.join(CACHE, "questie"))
    sorts = {}
    for key, value in re.findall(r"^\s*([A-Z_]+)\s*=\s*(-\d+),", open(path, encoding="utf-8").read(), re.M):
        sorts[int(value)] = key.replace("_", " ").title().replace("'S", "'s")
    return sorts


def write_quest_info(db):
    """Data/QuestInfo.lua: what the ledger and toasts say about a quest, without the game's quest cache.
    One tab-separated string per quest: name, level, zone (area id or category), giver, giver's zone."""
    lines = [
        "-- GENERATED by tools/build_questmap.py from Questie's Forever quest database. Do not edit.",
        "-- [questID] = name \\t level \\t zoneOrSort \\t giver phrase \\t giver area id",
        "local TC = TavernCards_NS",
        "TC.QuestSorts = {",
    ]
    for value, name in sorted(quest_sorts().items()):
        lines.append("[%d]=%s," % (value, lua_string(name)))
    lines.append("}")
    lines.append("TC.QuestInfo = (function() return {")
    row = []
    for qid in sorted(db.quests):
        q = db.quests[qid]
        # Who or what starts the quest, as a phrase: "From Marshal McBride", "From Wanted Poster",
        # "Starts from Sharptalon's Claw"; failing that, who it is turned in to.
        giver, giver_zone = "", 0
        started = q.get("startedBy")
        for npc_id in lua_list(at(started, 1)):
            npc = db.npcs.get(npc_id)
            if npc and npc.get("name"):
                giver, giver_zone = "From " + npc["name"], npc.get("zoneID") or 0
                break
        if not giver:
            for obj_id in lua_list(at(started, 2)):
                name = db.name_of("Object-", obj_id)
                if name:
                    giver = "From " + name
                    break
        if not giver:
            for item_id in lua_list(at(started, 3)):
                name = db.name_of("Item-", item_id)
                if name:
                    giver = "Starts from " + name
                    break
        if not giver:
            for npc_id in lua_list(at(q.get("finishedBy"), 1)):
                npc = db.npcs.get(npc_id)
                if npc and npc.get("name"):
                    giver, giver_zone = "Turn in to " + npc["name"], npc.get("zoneID") or 0
                    break
        fields = [q.get("name") or "", str(q.get("questLevel") or q.get("requiredLevel") or 0),
                  str(q.get("zoneOrSort") or 0), giver, str(giver_zone)]
        row.append("[%d]=%s" % (qid, lua_string("\t".join(f.replace("\t", " ") for f in fields))))
        if len(row) == 8:
            lines.append(",".join(row) + ",")
            row = []
    if row:
        lines.append(",".join(row) + ",")
    lines.append("} end)()")
    write("Data/QuestInfo.lua", "\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
