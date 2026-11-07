#!/usr/bin/env python3
"""The game's icon catalog: every icon name, its picture, a caption, and a CLIP embedding; then a unique
icon for every card.

    python3 tools/icons/catalog.py list        # icon names from the community listfile -> cache/icons/names.txt
    python3 tools/icons/catalog.py download    # pictures from Wowhead's icon CDN -> cache/icons/img/<name>.jpg
    python3 tools/icons/catalog.py embed       # CLIP image embeddings -> cache/icons/clip.npz
    python3 tools/icons/catalog.py caption     # vision-LLM captions -> cache/icons/captions.jsonl (resumable)
    python3 tools/icons/catalog.py assign      # cards -> unique icons (CLIP text vs image) -> Data/Icons.lua
    python3 tools/icons/catalog.py import-missing   # icons the game reported missing -> tools/icons/missing.txt

Everything is cached under tools/cache/icons and resumable. Card subjects (what a card's picture should
show) come from tools/match_icons.py (tools/cache/icon_subjects.json). In game, /tc icons checks the
assigned icons exist in the client and records any missing ones in TavernCardsDB.missingIcons; put them
in tools/icons/missing.txt and re-run assign to avoid them.
"""
import base64
import concurrent.futures
import csv
import io
import json
import os
import re
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CACHE = os.path.join(REPO, "tools", "cache", "icons")
IMG = os.path.join(CACHE, "img")
NAMES = os.path.join(CACHE, "names.txt")
LISTFILE_URL = "https://github.com/wowdev/wow-listfile/releases/latest/download/community-listfile.csv"
CDN = "https://wow.zamimg.com/images/wow/icons/large/%s.jpg"
VISION_URL = os.environ.get("VISION_URL", "http://192.168.1.68:1234/v1")
VISION_MODEL = os.environ.get("VISION_MODEL", "gemma4-31b-imatrix-mtp")

# Icons that never make good card art (UI chrome, zones, mounts gear sets...). Matched on lower-case names.
SKIP = re.compile(r"^(achievement_(zone|dungeon|arena|bg|guild|featsofstrength|pvp|reputation|quests|general|level|"
                  r"faction|leader|doublerainbow|halloween|worldevent|win|raid|challengemode|garrison|legionpvp)|"
                  r"ui_|garrison_|trade_archaeology|inv_misc_questionmark|temp|pvpcurrency|"
                  r"inv_(chest|pants|boots|bracer|belt|shoulder|helm|glove|gauntlets_[0-9]{2}[0-9]|cape|shirt|tabard)|"
                  r"inv_misc_desecrated|spell_misc_emotion|achievement_transmog|mail_|inv_relics_totemof|"
                  r"inv_jewelry_ring|inv_jewelcrafting_gem|inv_misc_gem_|inv_enchant_formula|inv_scroll_0[0-9]|"
                  r"inv_misc_note|inv_inscription|inv_letter|inv_crate|inv_box)")


def ensure_dirs():
    os.makedirs(IMG, exist_ok=True)


def cmd_list():
    ensure_dirs()
    raw = os.path.join(CACHE, "listfile.csv")
    if not os.path.exists(raw):
        print("downloading listfile...", flush=True)
        urllib.request.urlretrieve(LISTFILE_URL, raw)
    names, fdid = set(), {}
    with open(raw, newline="", encoding="utf-8", errors="replace") as f:
        for row in csv.reader(f, delimiter=";"):
            if len(row) < 2:
                continue
            path = row[1].lower()
            if path.startswith("interface/icons/") and path.endswith(".blp"):
                name = path[len("interface/icons/"):-4]
                if "/" not in name and not SKIP.search(name):
                    names.add(name)
                    fdid[name] = int(row[0])
    # File ids grow with each expansion: low ids are the old icons the Classic+ client surely has.
    with open(os.path.join(CACHE, "fdid.json"), "w") as f:
        json.dump(fdid, f)
    with open(NAMES, "w") as f:
        f.write("\n".join(sorted(names)) + "\n")
    print("%d icon names -> %s" % (len(names), NAMES))


def names():
    with open(NAMES) as f:
        return [n.strip() for n in f if n.strip()]


def cmd_download():
    ensure_dirs()
    todo = [n for n in names() if not os.path.exists(os.path.join(IMG, n + ".jpg"))
            and not os.path.exists(os.path.join(IMG, n + ".none"))]
    print("%d to download" % len(todo), flush=True)

    def get(n):
        try:
            with urllib.request.urlopen(CDN % n, timeout=30) as r:
                data = r.read()
            with open(os.path.join(IMG, n + ".jpg"), "wb") as f:
                f.write(data)
            return True
        except Exception:  # noqa: BLE001 - a 404 means Wowhead has no picture: remember it
            open(os.path.join(IMG, n + ".none"), "w").close()
            return False

    done = ok = 0
    with concurrent.futures.ThreadPoolExecutor(24) as pool:
        for good in pool.map(get, todo):
            done += 1
            ok += good
            if done % 1000 == 0:
                print("%d/%d (%d ok)" % (done, len(todo), ok), flush=True)
    print("downloaded %d of %d" % (ok, len(todo)))


def have_images():
    return [n for n in names() if os.path.exists(os.path.join(IMG, n + ".jpg"))]


def clip_model():
    import open_clip
    import torch
    device = "mps" if torch.backends.mps.is_available() else "cpu"
    model, _, preprocess = open_clip.create_model_and_transforms("ViT-B-32", pretrained="laion2b_s34b_b79k", device=device)
    tokenizer = open_clip.get_tokenizer("ViT-B-32")
    model.eval()
    return model, preprocess, tokenizer, device


def cmd_embed():
    import numpy as np
    import torch
    from PIL import Image
    out = os.path.join(CACHE, "clip.npz")
    have = {}
    if os.path.exists(out):
        z = np.load(out, allow_pickle=True)
        have = dict(zip(z["names"].tolist(), z["vecs"]))
    todo = [n for n in have_images() if n not in have]
    print("%d to embed (%d cached)" % (len(todo), len(have)), flush=True)
    if not todo:
        return
    model, preprocess, _, device = clip_model()
    batch = 256
    for i in range(0, len(todo), batch):
        chunk = todo[i:i + batch]
        imgs = []
        keep = []
        for n in chunk:
            try:
                imgs.append(preprocess(Image.open(os.path.join(IMG, n + ".jpg")).convert("RGB")))
                keep.append(n)
            except Exception:  # noqa: BLE001
                pass
        with torch.no_grad():
            v = model.encode_image(torch.stack(imgs).to(device))
            v = v / v.norm(dim=-1, keepdim=True)
        for n, vec in zip(keep, v.cpu().numpy().astype("float16")):
            have[n] = vec
        if (i // batch) % 10 == 0:
            print("%d/%d" % (i + len(chunk), len(todo)), flush=True)
            np.savez(out, names=np.array(list(have.keys())), vecs=np.stack(list(have.values())))
    np.savez(out, names=np.array(list(have.keys())), vecs=np.stack(list(have.values())))
    print("embedded %d icons" % len(have))


def cmd_caption():
    out = os.path.join(CACHE, "captions.jsonl")
    done = set()
    if os.path.exists(out):
        with open(out) as f:
            for line in f:
                try:
                    done.add(json.loads(line)["name"])
                except Exception:  # noqa: BLE001
                    pass
    todo = [n for n in have_images() if n not in done]
    print("%d to caption (%d done)" % (len(todo), len(done)), flush=True)
    per_request = 6

    def work(chunk):
        content = [{"type": "text", "text": (
            "These are %d World of Warcraft icons, in order. For each, write one line: '<number>. <caption>' "
            "where the caption names what it shows in 4-10 words (creature, person, object or effect, main "
            "colours). No other text." % len(chunk))}]
        for n in chunk:
            with open(os.path.join(IMG, n + ".jpg"), "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            content.append({"type": "image_url", "image_url": {"url": "data:image/jpeg;base64," + b64}})
        body = json.dumps({"model": VISION_MODEL, "temperature": 0, "max_tokens": 600,
                           "messages": [{"role": "user", "content": content}]}).encode()
        req = urllib.request.Request(VISION_URL + "/chat/completions", data=body,
                                     headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                text = json.load(r)["choices"][0]["message"]["content"] or ""
        except Exception as e:  # noqa: BLE001
            return chunk, {}, str(e)
        found = dict((int(k), v.strip()) for k, v in re.findall(r"^\s*(\d+)[.)]\s*(.+?)\s*$", text, re.M))
        return chunk, {chunk[k - 1]: v for k, v in found.items() if 1 <= k <= len(chunk)}, None

    chunks = [todo[i:i + per_request] for i in range(0, len(todo), per_request)]
    n = 0
    with open(out, "a") as f, concurrent.futures.ThreadPoolExecutor(2) as pool:
        for chunk, caps, err in pool.map(work, chunks):
            n += 1
            if err:
                print("chunk %d failed: %s" % (n, err), flush=True)
                continue
            for name, cap in caps.items():
                f.write(json.dumps({"name": name, "caption": cap}) + "\n")
            f.flush()
            if n % 50 == 0:
                print("%d/%d chunks" % (n, len(chunks)), flush=True)


def load_cards():
    sys.path.insert(0, os.path.join(REPO, "tools"))
    import match_icons
    return match_icons.load_cards()


# What an icon shows, in words: its file name (descriptive: ability_hunter_pet_turtle) plus its caption.
NAME_NOISE = {"inv", "misc", "ability", "spell", "achievement", "character", "icon", "trade", "hunter", "pet", "a", "b",
              "c", "d", "e", "1h", "2h", "01", "02", "03", "04", "05", "06", "07", "08", "09", "10", "11", "12"}


def icon_text(name, caption):
    words = [w for w in re.split(r"[_\-]+", name) if w and w not in NAME_NOISE and not w.isdigit()]
    words = [re.sub(r"\d+$", "", w) for w in words]
    return (" ".join(w for w in words if w) + ". " + (caption or "")).strip()


# Icons that fit each card type (a minion is a creature or person, a weapon a weapon...).
GEAR = r"inv_(sword|axe|mace|staff|knife|bow|polearm|weapon|waepon|shield|offhand|wand|firearm|glaive|thrown|hammer|spear|gun|rifle|crossbow)"
CLOTHES = (r"inv_(gauntlets|hand|leather|boot|pant|plate|cloth|mail|robe|armor|jewelry|ring|trinket|neck|chest|belt|bracer|"
           r"shoulder|helmet|helm|cape|shirt|fabric|ingot|ore|gem|jewelcrafting|enchant|alchemy|cooking|fishing|"
           r"archaeology|misc_food|drink|misc_herb|tailoring|leatherworking|blacksmithing|inscription|profession|"
           r"\d+_|1\d\d_)|inv\d+_|trade_")
WEARABLE = (r".*(cape|kilt|cloak|robe|mantle|helm|shoulder|bracer|belt|boot|glove|pant|shirt|tabard|ring_|necklace|"
            r"trinket|bracelet|chest|legs|wrist|waist|_feet|_hand_|gauntlet|bag_|_bag|_bags)")
TYPE_RULES = {
    "MINION": (None, re.compile(GEAR + "|" + CLOTHES + r"|inv_potion")),
    "SPELL": (None, re.compile(GEAR + "|" + CLOTHES)),
    "WEAPON": (re.compile(GEAR + r"|inv_gauntlets|inv_misc_weapon"), None),
    "LOCATION": (None, re.compile(GEAR + "|" + CLOTHES)),
}


def cmd_assign():
    """Each card gets a unique icon: text similarity between what the card's picture should show (the
    LLM's description, tools/match_icons.py) and what the icon shows (file name + caption), plus CLIP's
    image score, plus a bonus for the curated vocabulary pick; filtered by card type; no icon used twice
    (best pairs first). Cards sharing a name share an icon."""
    import numpy as np
    from sentence_transformers import SentenceTransformer
    sys.path.insert(0, os.path.join(REPO, "tools"))
    import match_icons

    z = np.load(os.path.join(CACHE, "clip.npz"), allow_pickle=True)
    all_names = z["names"].tolist()
    clip_vecs = z["vecs"].astype("float32")
    missing = set()
    mpath = os.path.join(HERE, "missing.txt")
    if os.path.exists(mpath):
        with open(mpath) as f:
            missing = {line.strip().lower() for line in f if line.strip()}
    fdid = {}
    fp = os.path.join(CACHE, "fdid.json")
    if os.path.exists(fp):
        with open(fp) as f:
            fdid = json.load(f)
    max_fdid = int(os.environ.get("MAX_FDID", "0") or 0)
    keep = [i for i, n in enumerate(all_names)
            if n not in missing and (not max_fdid or fdid.get(n, 0) <= max_fdid)]
    names_ = [all_names[i] for i in keep]
    clip_vecs = clip_vecs[keep]
    captions = {}
    cp = os.path.join(CACHE, "captions.jsonl")
    if os.path.exists(cp):
        with open(cp) as f:
            for line in f:
                try:
                    row = json.loads(line)
                    captions[row["name"]] = row["caption"]
                except Exception:  # noqa: BLE001
                    pass

    subjects = {}
    sp = os.path.join(REPO, "tools", "cache", "icon_subjects.json")
    if os.path.exists(sp):
        with open(sp) as f:
            subjects = json.load(f)
    vocab = match_icons.load_vocab()
    cards = match_icons.load_cards()
    by_name = {}
    for c in cards:
        by_name.setdefault(c["name"].lower(), []).append(c)
    groups = list(by_name.values())
    texts, curated = [], []
    for group in groups:
        c = group[0]
        subj = subjects.get(c["id"], "")
        subj = subj.split(":", 1)[1].strip() if ":" in subj else subj
        texts.append("%s. %s" % (c["name"], subj or c["tribe"] or c["type"].lower()))
        pick = match_icons.pick(c, subjects.get(c["id"], ""), vocab)
        curated.append(pick.lower() if pick else None)

    st = SentenceTransformer("all-MiniLM-L6-v2")
    card_vec = st.encode(texts, normalize_embeddings=True, batch_size=256, show_progress_bar=False)
    icon_vec = st.encode([icon_text(n, captions.get(n)) for n in names_], normalize_embeddings=True,
                         batch_size=256, show_progress_bar=False)
    text_sim = card_vec @ icon_vec.T

    model, _, tokenizer, device = clip_model()
    import torch
    with torch.no_grad():
        tv = []
        for i in range(0, len(texts), 256):
            t = model.encode_text(tokenizer(["an icon of " + x for x in texts[i:i + 256]]).to(device))
            tv.append((t / t.norm(dim=-1, keepdim=True)).cpu().numpy())
    clip_sim = np.concatenate(tv).astype("float32") @ clip_vecs.T
    # CLIP scores sit in a narrow band: standardize per card before mixing.
    clip_z = (clip_sim - clip_sim.mean(axis=1, keepdims=True)) / (clip_sim.std(axis=1, keepdims=True) + 1e-6)
    score = text_sim + 0.04 * clip_z
    # Newer icons (higher file ids) may be missing in WoW: Forever's client: prefer older ones a little.
    ids = np.array([fdid.get(n, 0) for n in names_])
    score -= np.where(ids > 1000000, 0.04, 0) + np.where(ids > 3000000, 0.04, 0)

    # Literal words: an icon whose file name says what the card is (boar, turtle, imp) gets a bonus per word.
    token_index = {}
    for j, n in enumerate(names_):
        for w in set(re.split(r"[_\-\d]+", n)):
            if len(w) >= 3 and w not in NAME_NOISE:
                token_index.setdefault(w, []).append(j)
    stop = {"the", "and", "with", "a", "an", "of", "small", "large", "giant", "glowing", "dark", "young", "old"}
    for gi in range(len(groups)):
        seen = set()
        name_words = set(re.findall(r"[a-z]+", groups[gi][0]["name"].lower()))
        for w in re.findall(r"[a-z]+", texts[gi].lower()):
            w = w[:-1] if w.endswith("s") and len(w) > 4 else w
            if len(w) < 3 or w in stop or w in seen:
                continue
            seen.add(w)
            # The card's own name counts double: "Murloc Raider" is a murloc whatever the picture says.
            bonus = 0.22 if w in name_words else 0.11
            for j in token_index.get(w, ()):
                score[gi, j] += bonus

    index = {n: j for j, n in enumerate(names_)}
    for gi, group in enumerate(groups):
        allow, deny = TYPE_RULES.get(group[0]["type"], (None, None))
        mask = np.ones(len(names_), dtype=bool)
        if allow is not None:
            mask &= np.array([bool(allow.match(n)) for n in names_])
        if deny is not None:
            mask &= ~np.array([bool(deny.match(n)) for n in names_])
        if group[0]["type"] != "WEAPON":
            mask &= ~np.array([bool(re.match(WEARABLE, n)) for n in names_])
        score[gi, ~mask] = -9
        if curated[gi] in index:
            score[gi, index[curated[gi]]] += 0.25

    # Who picks first when two cards want one icon: the classic sets players meet first, then other
    # collectible cards, then tokens.
    def priority(group):
        c = group[0]
        if c["id"].startswith(("CS1_", "CS2_", "CS3_", "EX1_", "NEW1_", "DS1_", "VAN_")):
            return 0.3
        return 0.1 if any(x["flags"] & 1 for x in group) else 0.0

    # Hand-picked first choices (tools/icons/overrides.txt) are kept out of everyone else's pool.
    overrides = {}
    op = os.path.join(HERE, "overrides.txt")
    if os.path.exists(op):
        with open(op) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "|" in line:
                    cid, icon = line.split("|", 1)
                    if icon.strip().lower() in index:
                        overrides[cid.strip()] = icon.strip().lower()
    for icon in overrides.values():
        score[:, index[icon]] = -9

    # Three rounds of greedy unique picks: a card's 1st, 2nd and 3rd choice (no icon reused across rounds).
    # The game takes, per card in this priority order, the first choice it has that no card took yet
    # (some icons may be missing in WoW: Forever's client).
    k = 80
    rounds = int(os.environ.get("ICON_ROUNDS", "3"))
    choices = {gi: [] for gi in range(len(groups))}
    used = set()
    for _ in range(rounds):
        top = np.argpartition(-score, k, axis=1)[:, :k]
        pairs = [(float(score[gi, j]) + priority(groups[gi]), gi, int(j)) for gi in range(len(groups))
                 for j in top[gi] if score[gi, j] > -1 and int(j) not in used]
        pairs.sort(reverse=True)
        taken = {}
        for sc, gi, j in pairs:
            if gi in taken or j in used:
                continue
            taken[gi] = (names_[j], sc)
            used.add(j)
        for gi, pick_ in taken.items():
            choices[gi].append(pick_)
        score[:, list(used)] = -9

    order = sorted(range(len(groups)), key=lambda gi: -(priority(groups[gi]) + (choices[gi][0][1] if choices[gi] else -9)))
    assigned, report = {}, {}
    for gi, group in enumerate(groups):
        names_pick = [n for n, _ in choices[gi]]
        forced = next((overrides[c["id"]] for c in group if c["id"] in overrides), None)
        if forced:
            names_pick = [forced] + names_pick[:2]
        for c in group:
            if names_pick:
                assigned[c["id"]] = names_pick
            report[c["id"]] = {"icon": names_pick[0] if names_pick else None, "alts": names_pick[1:],
                               "score": choices[gi][0][1] if choices[gi] else None, "text": texts[gi],
                               "caption": captions.get(names_pick[0]) if names_pick else None}
    with open(os.path.join(CACHE, "assigned.json"), "w") as f:
        json.dump(report, f, indent=0)

    lines = ["-- GENERATED by tools/icons/catalog.py assign: up to three ranked game icons per card (what the card",
             "-- shows, matched to icon names, captions and pictures), cards in pick order. UI/Art.lua resolves them",
             "-- in the client: first icon that exists and no earlier card took. Do not edit.",
             "local TC = TavernCards_NS",
             "TC.CardIconChoices = {"]
    emitted = set()
    for gi in order:
        for c in groups[gi]:
            if c["id"] in assigned and c["id"] not in emitted:
                emitted.add(c["id"])
                lines.append('  {"%s","%s"},' % (c["id"], '","'.join(assigned[c["id"]])))
    lines.append("}")
    with open(os.path.join(REPO, "Data", "Icons.lua"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("assigned %d cards to %d distinct first-choice icons (%d with 3 choices)" % (
        len(assigned), len({v[0] for v in assigned.values()}), sum(1 for v in assigned.values() if len(v) == 3)))


def cmd_import_missing():
    """Reads TavernCardsDB.missingIcons from the game's SavedVariables into tools/icons/missing.txt."""
    import glob
    wtf = os.path.join(REPO, "..", "..", "..", "WTF", "Account")
    found = set()
    for path in glob.glob(os.path.join(wtf, "*", "SavedVariables", "TavernCards.lua")):
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        m = re.search(r'\["missingIcons"\]\s*=\s*\{(.*?)\n\t\}', text, re.S)
        if m:
            found.update(n.lower() for n in re.findall(r'"([^"]+)"', m.group(1)))
    mpath = os.path.join(HERE, "missing.txt")
    old = set()
    if os.path.exists(mpath):
        with open(mpath) as f:
            old = {line.strip() for line in f if line.strip()}
    with open(mpath, "w") as f:
        f.write("\n".join(sorted(old | found)) + "\n")
    print("missing icons: %d known (+%d new)" % (len(old | found), len(found - old)))


if __name__ == "__main__":
    {"list": cmd_list, "download": cmd_download, "embed": cmd_embed, "caption": cmd_caption,
     "assign": cmd_assign, "import-missing": cmd_import_missing}[sys.argv[1]]()
