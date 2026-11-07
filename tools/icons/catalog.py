#!/usr/bin/env python3
"""The game's icon catalog: every icon name, its picture, a caption, and a CLIP embedding; then a unique
icon for every card.

    python3 tools/icons/catalog.py list        # icon names from the community listfile -> cache/icons/names.txt
    python3 tools/icons/catalog.py download    # pictures from Wowhead's icon CDN -> cache/icons/img/<name>.jpg
    python3 tools/icons/catalog.py embed       # CLIP image embeddings -> cache/icons/clip.npz
    python3 tools/icons/catalog.py caption     # vision-LLM captions -> cache/icons/captions.jsonl (resumable)
    python3 tools/icons/catalog.py assign      # cards -> unique icons (CLIP text vs image) -> Data/Icons.lua

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
    names = set()
    with open(raw, newline="", encoding="utf-8", errors="replace") as f:
        for row in csv.reader(f, delimiter=";"):
            if len(row) < 2:
                continue
            path = row[1].lower()
            if path.startswith("interface/icons/") and path.endswith(".blp"):
                name = path[len("interface/icons/"):-4]
                if "/" not in name and not SKIP.search(name):
                    names.add(name)
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


def cmd_assign():
    """Each card gets the icon whose picture best matches the card (CLIP), no icon used twice.

    The text for a card is the LLM's description of its picture (or its name), prefixed for CLIP.
    Pairs are taken greedily, best first, from each card's 60 nearest icons: a card whose best icons are
    already taken falls to its next best. Tokens and cards sharing a name share an icon."""
    import numpy as np
    import torch
    z = np.load(os.path.join(CACHE, "clip.npz"), allow_pickle=True)
    icon_names = z["names"].tolist()
    vecs = z["vecs"].astype("float32")
    missing = set()
    mpath = os.path.join(HERE, "missing.txt")
    if os.path.exists(mpath):
        with open(mpath) as f:
            missing = {line.strip().lower() for line in f if line.strip()}
    keep = [i for i, n in enumerate(icon_names) if n not in missing]
    icon_names = [icon_names[i] for i in keep]
    vecs = vecs[keep]

    subjects = {}
    sp = os.path.join(REPO, "tools", "cache", "icon_subjects.json")
    if os.path.exists(sp):
        with open(sp) as f:
            subjects = json.load(f)
    cards = load_cards()
    # One icon per distinct name (a token and the card that makes it look alike).
    by_name = {}
    for c in cards:
        by_name.setdefault(c["name"].lower(), []).append(c)
    groups = list(by_name.values())
    texts = []
    for group in groups:
        c = group[0]
        subj = subjects.get(c["id"], "")
        subj = subj.split(":", 1)[1].strip() if ":" in subj else subj
        kind = {"SPELL": "a spell icon", "WEAPON": "a weapon icon", "LOCATION": "a place icon"}.get(c["type"], "a portrait icon")
        texts.append("%s of %s, %s" % (kind, subj or c["name"], c["name"]))

    model, _, tokenizer, device = clip_model()
    tv = []
    with torch.no_grad():
        for i in range(0, len(texts), 256):
            t = model.encode_text(tokenizer(texts[i:i + 256]).to(device))
            tv.append((t / t.norm(dim=-1, keepdim=True)).cpu().numpy())
    tv = np.concatenate(tv).astype("float32")
    sims = tv @ vecs.T
    k = 60
    top = np.argpartition(-sims, k, axis=1)[:, :k]
    pairs = []
    for gi in range(len(groups)):
        for j in top[gi]:
            pairs.append((float(sims[gi, j]), gi, int(j)))
    pairs.sort(reverse=True)
    used, pick = set(), {}
    for score, gi, j in pairs:
        if gi in pick or j in used:
            continue
        pick[gi] = (icon_names[j], score)
        used.add(j)

    assigned = {}
    for gi, group in enumerate(groups):
        if gi in pick:
            for c in group:
                assigned[c["id"]] = pick[gi][0]
    with open(os.path.join(CACHE, "assigned.json"), "w") as f:
        json.dump({c["id"]: {"icon": assigned.get(c["id"]), "text": texts[gi]}
                   for gi, group in enumerate(groups) for c in group}, f, indent=0)

    lines = ["-- GENERATED by tools/icons/catalog.py assign: a unique game icon per card, picked by CLIP from",
             "-- the card's described picture. Do not edit.",
             "local TC = TavernCards_NS",
             "TC.CardIcons = {"]
    for c in cards:
        if c["id"] in assigned:
            lines.append('  ["%s"]="%s",' % (c["id"], assigned[c["id"]]))
    lines.append("}")
    with open(os.path.join(REPO, "Data", "Icons.lua"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print("assigned %d cards to %d distinct icons" % (len(assigned), len(set(assigned.values()))))


if __name__ == "__main__":
    {"list": cmd_list, "download": cmd_download, "embed": cmd_embed, "caption": cmd_caption,
     "assign": cmd_assign}[sys.argv[1]]()
