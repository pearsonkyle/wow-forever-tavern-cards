"""Read Questie's baked Forever database (QuestieDB_Forever.toc) at build time.

Questie (GPL) ships its data as TOC metadata: `## X-<Entity>-<id>-<field>: base64(CBOR)`, a Scalar row
under `-S`, and an `IDS` header (base64(deflate(CBOR))). We only read it to derive the quest -> card
map; none of Questie's data is shipped in the addon.

    from questie import QuestieDB
    db = QuestieDB.load()          # downloads + caches the release bundle on first use
    db.quests[2]["name"]
"""
import base64
import os
import re
import struct
import urllib.request
import zipfile
import zlib

from common import CACHE

BUNDLE = "https://github.com/Questie/Questie/releases/download/bundle/v12.6.3%2Bv1.0.12/Questie-v12.6.3%2Bv1.0.12.zip"
TOC = "QuestieDB/QuestieDB_Forever.toc"

QUEST_FIELDS = {
    1: "name", 2: "startedBy", 3: "finishedBy", 4: "requiredLevel", 5: "questLevel", 6: "requiredRaces",
    7: "requiredClasses", 8: "objectivesText", 10: "objectives", 12: "preQuestGroup", 13: "preQuestSingle",
    17: "zoneOrSort", 18: "requiredSkill", 22: "nextQuestInChain", 23: "questFlags", 24: "specialFlags",
    25: "parentQuest", 32: "requiredMaxLevel",
}


def cbor_decode(data):
    value, _ = _cbor(data, 0)
    return value


def _cbor(b, i):
    ib = b[i]
    major, info = ib >> 5, ib & 31
    i += 1
    if major == 7:
        if info == 20:
            return False, i
        if info == 21:
            return True, i
        if info in (22, 23):
            return None, i
        if info == 25:
            return _half(struct.unpack(">H", b[i:i + 2])[0]), i + 2
        if info == 26:
            return struct.unpack(">f", b[i:i + 4])[0], i + 4
        if info == 27:
            return struct.unpack(">d", b[i:i + 8])[0], i + 8
        raise ValueError("cbor simple %d" % info)
    if info < 24:
        n = info
    elif info == 24:
        n, i = b[i], i + 1
    elif info == 25:
        n, i = struct.unpack(">H", b[i:i + 2])[0], i + 2
    elif info == 26:
        n, i = struct.unpack(">I", b[i:i + 4])[0], i + 4
    elif info == 27:
        n, i = struct.unpack(">Q", b[i:i + 8])[0], i + 8
    else:
        raise ValueError("cbor indefinite length unsupported")
    if major == 0:
        return n, i
    if major == 1:
        return -1 - n, i
    if major == 2:  # Lua strings are encoded as byte strings
        return b[i:i + n].decode("utf-8", "replace"), i + n
    if major == 3:
        return b[i:i + n].decode("utf-8", "replace"), i + n
    if major == 4:
        out = []
        for _ in range(n):
            v, i = _cbor(b, i)
            out.append(v)
        return out, i
    if major == 5:
        out = {}
        for _ in range(n):
            k, i = _cbor(b, i)
            v, i = _cbor(b, i)
            out[k] = v
        return out, i
    if major == 6:
        return _cbor(b, i)  # tags carry no meaning we need
    raise ValueError("cbor major %d" % major)


def _half(h):
    exp, frac = (h >> 10) & 0x1F, h & 0x3FF
    val = frac * 2 ** -24 if exp == 0 else (float("inf") if exp == 31 else (1 + frac / 1024) * 2 ** (exp - 15))
    return -val if h & 0x8000 else val


def _inflate(data):
    for wbits in (15, -15, 31):  # zlib, raw deflate, gzip: C_EncodingUtil's methods
        try:
            return zlib.decompress(data, wbits)
        except zlib.error:
            pass
    raise ValueError("unknown compression")


def at(v, i):
    """1-based element i of a Lua array that may have been encoded as a list or an int-keyed map."""
    if isinstance(v, list):
        return v[i - 1] if 0 < i <= len(v) else None
    if isinstance(v, dict):
        return v.get(i)
    return None


def lua_list(v):
    """Lua-encoded CBOR arrays sometimes arrive as int-keyed maps; normalize to a 1-based list."""
    if isinstance(v, dict):
        return [v[k] for k in sorted(k for k in v if isinstance(k, int))]
    return v or []


class QuestieDB:
    def __init__(self, meta):
        self.meta = meta
        self.quests = self._entity("Quest-", QUEST_FIELDS)
        self.npcs = self._entity("Npc-", {1: "name", 4: "minLevel", 5: "maxLevel", 6: "rank", 9: "zoneID",
                                          12: "factionID", 13: "friendlyToFaction", 14: "subName", 15: "npcFlags"})

    @classmethod
    def load(cls):
        folder = os.path.join(CACHE, "questie")
        toc = os.path.join(folder, TOC)
        if not os.path.exists(toc):
            os.makedirs(folder, exist_ok=True)
            archive = os.path.join(folder, "questie.zip")
            if not os.path.exists(archive):
                print("downloading Questie bundle ...")
                urllib.request.urlretrieve(BUNDLE, archive)
            with zipfile.ZipFile(archive) as z:
                z.extract(TOC, folder)
        meta = {}
        line = re.compile(r"^## (X-[^:]+): (.*)$")
        with open(toc, encoding="utf-8") as f:
            for raw in f:
                m = line.match(raw.rstrip("\n"))
                if m:
                    meta[m.group(1)] = m.group(2)
        return cls(meta)

    def _stored(self, key):
        value = self.meta.get(key)
        if value is None or not value.startswith("~"):
            return value
        m = re.match(r"^~(\d+)~$", value)  # chunk header: the parts follow as key-1..key-n
        if not m:
            return value
        return "".join(self.meta[key + "-%d" % i] for i in range(1, int(m.group(1)) + 1))

    def _entity(self, prefix, fields):
        ids_raw = self._stored("X-" + prefix + "IDS")
        ids = lua_list(cbor_decode(_inflate(base64.b64decode(ids_raw))))
        out = {}
        for eid in ids:
            row = self._stored("X-%s%d-S" % (prefix, eid))
            scalars = cbor_decode(base64.b64decode(row)) if row else {}
            if isinstance(scalars, list):
                scalars = {i + 1: v for i, v in enumerate(scalars)}
            rec = {"id": eid}
            for idx, name in fields.items():
                stored = self._stored("X-%s%d-%d" % (prefix, eid, idx))
                if stored is not None:
                    rec[name] = cbor_decode(base64.b64decode(stored))
                elif idx in scalars:
                    rec[name] = scalars[idx]
            out[eid] = rec
        return out
