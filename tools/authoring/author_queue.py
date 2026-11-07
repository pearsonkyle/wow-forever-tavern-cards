#!/usr/bin/env python3
"""Build the deterministic authoring queue from the cards the compiler still refuses.

The queue is the work list, not a guess: the refusal comes from `tavern-sim compile
--refusals-all --no-write`, the metadata from the pinned catalogue, and the tier from the same
classifier `coverage_plan.py` uses. A card is eligible for the flat-IR factory only when its clauses
use mechanics the engine already has; a card that needs a new subsystem is routed to the mechanics
backlog instead of being handed to the model.

Usage:
  python3 tools/author_queue.py --data data --out data/authoring/queue.jsonl
  python3 tools/author_queue.py --data data --refusals /tmp/refusals.tsv --limit 50
  python3 tools/author_queue.py --self-test --data data
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import coverage_plan as cp  # noqa: E402  (the same tier classifier the report uses)

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
SIM = Path(os.environ.get("TAVERN_SIM", ROOT / "build-local" / "tavern-sim"))

# Mechanics the flat IR cannot express, plus the composition words that usually mean the card needs
# the IR v2 continuation/replacement layer. This is deliberately conservative: a false exclusion is
# a card that waits for the next block, a false inclusion is a wasted model call.
UNSUPPORTED_MARKERS = (

    "after this ", "after a friendly", "aura", "quest",
    "sidequest", "randomly split",
    "this game", "last turn", "next turn", "dormant", "infuse",
    "corrupt", "forge", "quickdraw", "frenzy", "overkill", "colossal",
    "titan", "excavate", "dredge", "starship", "miniaturize", "gigantify", "magnetic",
    "echo", "twinspell", "honorable kill", "start of game",
)

VERBS = (
    "deal", "restore", "draw", "summon", "give", "gain", "destroy", "freeze", "silence",
    "discard", "shuffle", "transform", "set", "swap", "add", "discover", "equip", "return",
    "have", "cost", "reduce", "copy",
)
VERB_RE = re.compile(r"\b(" + "|".join(VERBS) + r")\b", re.I)
VERB_OPS = {
    "deal": ["DAMAGE"], "restore": ["HEAL"], "draw": ["DRAW"], "summon": ["SUMMON"],
    "give": ["BUFF", "GIVE_KEYWORD"], "gain": ["GAIN_ARMOR", "GAIN_MANA", "BUFF"],
    "destroy": ["DESTROY"], "freeze": ["GIVE_KEYWORD"], "silence": ["SILENCE"],
    "discard": ["DISCARD"], "shuffle": ["SHUFFLE"], "transform": ["TRANSFORM"],
    "set": ["SET_STATS", "SET_ATTACK", "SET_HEALTH"], "swap": ["SWAP_STATS"],
    "add": ["ADD_TO_HAND"], "discover": ["DISCOVER"], "equip": ["EQUIP"],
    "return": ["RETURN_TO_HAND"],
    "copy": ["COPY"],
    "have": ["BUFF", "GIVE_KEYWORD"],
    "cost": ["CARD_COST"],
}
TOKEN_VERBS = {"summon", "add", "equip", "transform", "shuffle", "raise"}
# Mechanics the flat engine and the printer already support; they must not be excluded just
# because the source catalogue tags them "modern".
SUPPORTED_MODERN = {"OUTCAST", "COMBO", "CHOOSE_ONE", "FINALE", "SPELLBURST", "MANATHIRST"}
TOKEN_RE = re.compile(r"[a-z']+")
STOPWORDS = {
    "a", "an", "the", "to", "of", "and", "or", "for", "your", "you", "its", "it", "this",
    "that", "with", "all", "each", "other", "friendly", "enemy", "if", "then", "do", "get",
}


def load_json(path: Path):
    with path.open() as handle:
        return json.load(handle)


def canonical_texts(data: Path) -> dict[str, str]:
    result = subprocess.run(
        [str(SIM), "canonical", "--data", str(data), "--all"],
        cwd=ROOT, text=True, capture_output=True, check=True,
    )
    out: dict[str, str] = {}
    for line in result.stdout.splitlines():
        card_id, _, text = line.partition("\t")
        out[card_id] = text
    return out


def refusals(data: Path, path: Path | None) -> dict[str, str]:
    if path is None:
        result = subprocess.run(
            [str(SIM), "compile", "--data", str(data), "--refusals-all", "--no-write"],
            cwd=ROOT, text=True, capture_output=True, check=True,
        )
        text = result.stdout
    else:
        text = path.read_text()
    out: dict[str, str] = {}
    for line in text.splitlines():
        if "\t" not in line:
            continue
        card_id, _, clause = line.partition("\t")
        if card_id.startswith("compile:"):
            continue
        out[card_id] = clause
    return out


def tokens(text: str) -> set[str]:
    return {word for word in TOKEN_RE.findall(text.lower()) if word not in STOPWORDS and len(word) > 2}


def build_index(admitted: dict[str, dict], catalogue: dict[str, dict]):
    by_verb: dict[str, list[str]] = {}
    by_type: dict[str, list[str]] = {}
    for card_id in admitted:
        card = catalogue.get(card_id)
        if card is None:
            continue
        text = (card.get("text") or "").replace("\n", " ")
        verb = first_verb(text)
        if verb:
            by_verb.setdefault(verb, []).append(card_id)
        by_type.setdefault(card.get("type", ""), []).append(card_id)
    return by_verb, by_type


def first_verb(text: str) -> str:
    match = VERB_RE.search(text)
    return match.group(1).lower() if match else ""


def examples_for(text: str, card_type: str, admitted: dict[str, dict], catalogue: dict[str, dict],
                 by_verb: dict[str, list[str]], by_type: dict[str, list[str]]) -> list[str]:
    verb = first_verb(text)
    pool = list(dict.fromkeys(by_verb.get(verb, []) + by_type.get(card_type, [])))
    target = tokens(text)
    scored = []
    for card_id in pool:
        other = (catalogue.get(card_id, {}).get("text") or "").replace("\n", " ")
        other_tokens = tokens(other)
        if not other_tokens or not target:
            continue
        score = len(target & other_tokens) / len(target | other_tokens)
        if first_verb(other) == verb:
            score += 0.15
        scored.append((score, card_id))
    scored.sort(key=lambda pair: (-pair[0], pair[1]))
    return [card_id for _, card_id in scored[:3]]


def build_token_index(cards: dict[str, dict]) -> tuple[dict[str, list[dict]], dict[tuple[int, int], list[dict]]]:
    index: dict[str, list[dict]] = {}
    by_stats: dict[tuple[int, int], list[dict]] = {}
    for token_id, token in cards.items():
        if token.get("collectible"):
            continue
        entry = {
            "id": token_id,
            "name": token.get("name", ""),
            "attack": token.get("attack", 0),
            "health": token.get("health", 0),
            "durability": token.get("durability", 0),
            "races": token.get("races", []),
            "keywords": token.get("keywords", []),
            "type": token.get("type", ""),
        }
        for word in set(re.findall(r"[a-z]+", (token.get("name") or "").lower())):
            index.setdefault(word, []).append(entry)
        stats_pair = (entry["attack"],
                      entry["durability"] if entry["type"] == "WEAPON" else entry["health"])
        if stats_pair[0] or stats_pair[1]:
            by_stats.setdefault(stats_pair, []).append(entry)
    return index, by_stats


def token_hints(text: str, verb: str, card: dict, index: dict[str, list[dict]],
                by_stats: dict[tuple[int, int], list[dict]]) -> list[dict]:
    if verb not in TOKEN_VERBS:
        return []
    text_words = set(re.findall(r"[a-z]+", text.lower()))
    text_words |= {word[:-1] for word in list(text_words) if word.endswith("s")}
    name_words = set(re.findall(r"[a-z]+", (card.get("name") or "").lower()))
    candidates: dict[str, dict] = {}
    for word in text_words:
        for entry in index.get(word, []):
            candidates[entry["id"]] = entry
        if word.endswith("s"):
            for entry in index.get(word[:-1], []):
                candidates[entry["id"]] = entry
    stats = re.search(r"\b(\d+)\s*/\s*(\d+)\b", text)
    stat_pair = (int(stats.group(1)), int(stats.group(2))) if stats else None
    if stat_pair:
        for entry in by_stats.get(stat_pair, []):
            candidates[entry["id"]] = entry
    lowered = text.lower()
    if verb == "equip":
        candidates = {key: entry for key, entry in candidates.items() if entry["type"] == "WEAPON"}
    found = []
    for entry in candidates.values():
        token_words = set(re.findall(r"[a-z]+", entry["name"].lower()))
        hp = entry["durability"] if entry["type"] == "WEAPON" else entry["health"]
        score = 0
        if entry["id"].startswith(card.get("id", "") + "t") or entry["id"] == card.get("id", "") + "t":
            score += 5
        score += 4 * len(token_words & name_words)
        score += 2 * len(token_words & text_words)
        if stat_pair and (entry["attack"], hp) == stat_pair:
            score += 3
        if any(keyword.lower() in lowered for keyword in entry.get("keywords", [])):
            score += 2
        if entry.get("type") == "MINION":
            score += 1
        found.append((score, entry))
    found.sort(key=lambda pair: (-pair[0], pair[1]["name"], pair[1]["id"]))
    return [entry for _, entry in found[:8]]


def eligibility(card: dict, raw: dict, text: str, tags: set[str]) -> tuple[bool, str]:
    if card.get("type") not in ("MINION", "SPELL", "WEAPON"):
        return False, "card type is not playable by the flat engine"
    if card.get("cost", 0) > 10:
        return False, "cost is above the engine cap"
    if len(text) > 160:
        return False, "text is longer than the phase-1 budget"
    if text.count(" . ") + 1 > 3:
        return False, "more than three clauses"
    if (tags & cp.MODERN) - SUPPORTED_MODERN:
        return False, "modern mechanic tag"
    lowered = text.lower()
    for marker in UNSUPPORTED_MARKERS:
        if marker in lowered:
            return False, f"contains '{marker}'"
    if not first_verb(text):
        return False, "no known effect verb"
    return True, ""


def build(data: Path, refusals_path: Path | None, limit: int | None) -> list[dict]:
    catalogue = load_json(data / "catalogue.json")
    cards = {card["id"]: card for card in catalogue["cards"]}
    raw = {card["id"]: card for card in load_json(data / "catalogue.raw.json")}
    admitted = load_json(data / "programs.json")["programs"]
    refused = refusals(data, refusals_path)
    canonical = canonical_texts(data)
    token_index, tokens_by_stats = build_token_index(cards)
    by_verb, by_type = build_index(admitted, cards)

    rows = []
    for card_id, card in cards.items():
        if not card.get("collectible") or card_id in admitted:
            continue
        text = canonical.get(card_id) or cp_repr_text(card.get("text") or "")
        mechanics = set(raw.get(card_id, {}).get("mechanics") or [])
        tier = cp.complexity(card, mechanics)
        ok, why = eligibility(card, raw.get(card_id, {}), text, mechanics)
        rows.append({
            "id": card_id,
            "name": card.get("name", ""),
            "type": card.get("type", ""),
            "cost": card.get("cost", 0),
            "attack": card.get("attack", 0),
            "health": card.get("health", 0),
            "family": card.get("family", ""),
            "races": card.get("races", []),
            "rarity": card.get("rarity", ""),
            "set": raw.get(card_id, {}).get("set", ""),
            "text": text,
            "rawText": (card.get("text") or "").replace("\n", " "),
            "refusal": refused.get(card_id, ""),
            "tier": tier,
            "modernTags": sorted(mechanics & cp.MODERN),
            "hints": (["CARD_COST"] if "cost" in text else ["SET_HEALTH"])
                     if first_verb(text) == "reduce" else VERB_OPS.get(first_verb(text), []),
            "secret": text.lower().startswith("secret:"),
            "tokenHints": token_hints(text, first_verb(text), card, token_index, tokens_by_stats),
            "eligible": ok,
            "why": why,
            "exampleIds": examples_for(text, card.get("type", ""), admitted, cards, by_verb, by_type),
        })

    rows.sort(key=lambda row: (not row["eligible"], row["tier"], row["id"]))
    if limit is not None:
        rows = rows[:limit]
    return rows


def cp_repr_text(text: str) -> str:
    # The compiler canonicalises before comparing; the queue carries the same spelling the prompt
    # and the printer proof use, so the model is not asked to translate punctuation first.
    return " ".join(text.replace("\n", " ").split())


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "data")
    parser.add_argument("--refusals", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "data" / "authoring" / "queue.jsonl")
    parser.add_argument("--limit", type=int)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    data = args.data if args.data.is_absolute() else ROOT / args.data
    if not (data / "catalogue.json").exists():
        print(f"author_queue: no catalogue at {data}", file=sys.stderr)
        return 2

    rows = build(data, args.refusals, args.limit)
    if args.self_test:
        again = build(data, args.refusals, args.limit)
        if rows != again:
            print("author_queue: NOT deterministic", file=sys.stderr)
            return 1
        if any(row["id"] in load_json(data / "programs.json")["programs"] for row in rows):
            print("author_queue: an admitted card leaked into the queue", file=sys.stderr)
            return 1
        print(f"author_queue: self-test ok ({len(rows)} rows)")
        return 0

    args.out.parent.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256()
    with args.out.open("w") as handle:
        for row in rows:
            line = json.dumps(row, sort_keys=True, separators=(",", ":"))
            handle.write(line + "\n")
            digest.update(line.encode() + b"\n")
    (args.out.parent / "queue.sha256").write_text(digest.hexdigest() + "\n")

    eligible = sum(1 for row in rows if row["eligible"])
    print(f"author_queue: {len(rows)} refused, {eligible} eligible, "
          f"{len(rows) - eligible} routed to the mechanics backlog")
    print(f"author_queue: {args.out} sha256 {digest.hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
