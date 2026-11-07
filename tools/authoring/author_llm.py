#!/usr/bin/env python3
"""The gated local-LLM authoring loop.

One card per request, constrained to the authoring schema, verified by `tavern-sim author-verify`
after every round, with the verifier's exact reason fed back for at most three attempts. The model
only ever writes candidate data under `data/authoring/blocks/<block>/`; it never edits committed
data. Promotion is a separate, reviewed command (`author_apply.py`).

Usage:
  python3 tools/author_llm.py --block battlecry-damage-01 --limit 10
  python3 tools/author_llm.py --block pilot-01 --ids SCH_705,GIL_635 --dry-run
  python3 tools/author_llm.py --block test-01 --fake /tmp/canned.json --limit 3
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
SIM = Path(os.environ.get("TAVERN_SIM", ROOT / "build-local" / "tavern-sim"))
DEFAULT_URL = os.environ.get("TAVERN_AUTHOR_LLM_URL", "http://127.0.0.1:1234/v1/chat/completions")
DEFAULT_MODEL = os.environ.get("TAVERN_AUTHOR_LLM_MODEL", "gemma4-e4b")
DEFAULT_TIMEOUT = int(os.environ.get("TAVERN_AUTHOR_LLM_TIMEOUT", "120"))

OP_NOTES = {
    "DAMAGE": "deal N damage",
    "HEAL": "restore N health",
    "DRAW": "draw N cards",
    "SUMMON": "summon a token",
    "BUFF": "give +N/+N or a keyword",
    "GAIN_ARMOR": "gain N armor",
    "GAIN_MANA": "gain N temporary mana",
    "GAIN_MANA_CRYSTAL": "gain an empty/permanent mana crystal",
    "DESTROY": "destroy",
    "GIVE_KEYWORD": "give a keyword",
    "SILENCE": "silence",
    "FREEZE": "freeze (use GIVE_KEYWORD with keyword freeze)",
    "DISCARD": "discard a card",
    "SHUFFLE": "shuffle a card into a deck",
    "TRANSFORM": "transform a minion",
    "SET_STATS": "set attack/health",
    "SET_ATTACK": "set attack",
    "SET_HEALTH": "set health",
    "SWAP_STATS": "swap attack and health",
    "ADD_TO_HAND": "add a card to hand",
    "SUMMON_RANDOM": "summon a random filtered minion",
    "SUMMON_FROM_DECK": "summon from deck",
    "CARD_COST": "change a card's cost",
    "TAKE_CONTROL": "take control",
}

SYSTEM = """You translate printed card text into a compact program for a deterministic card simulator.

Rules:
- Output exactly one JSON object and nothing else.
- The object is a program for the card named in the user message.
- Set "implemented": true.
- Put the card's effects in printed order in "effects". Group effects with the same "trigger"
  together. Each effect has a "trigger" and an "op"; every other field is optional and defaults to
  zero/false/empty, so emit only the fields that carry meaning.
- Use only the vocabulary below. Do not invent ops, triggers, conditions, fields or card ids.
- A target is {"kind": ..., "side": ...}. The kind is one of CHOOSE, ALL, RANDOM, SELF, ADJACENT,
  TRIGGER_SOURCE, PREVIOUS, LOWEST_HEALTH, HIGHEST_ATTACK. Never write "MINION" or "CHARACTER"
  as a kind: "a minion" is kind CHOOSE with side ANY_MINION; "all minions" is kind ALL with side
  ANY_MINION; "a random minion" is kind RANDOM with side ANY_MINION. The side names whose:
  ENEMY_MINION, FRIENDLY_MINION, ANY_MINION, ENEMY_HERO, YOUR_HERO, ANY_CHARACTER,
  FRIENDLY_HAND, YOUR_WEAPON, and so on.
- SUMMON, SUMMON_RANDOM, ADD_TO_HAND, DRAW, GAIN_ARMOR, GAIN_MANA, GAIN_MANA_CRYSTAL and the
  other targetless ops take NO target; omit it. In particular, "add ... to your hand" is
  ADD_TO_HAND, not SUMMON. "Summon" is SUMMON. A token's keyword (Taunt, Rush) goes in
  effect.keyword, not in condition and not in the top-level keywords.
- Top-level keywords are only the card's own keyword line (Taunt, Rush, Divine Shield, ...).
  Never put battlecry, deathrattle, combo, outcast or inspire there; those are triggers or
  conditions.
- repeat is the count in the text ("two 1/1 Rams" is repeat 2). amount is the number the effect
  uses (damage, heal, draw, armor).
- amount / amount2 are the numbers printed in the text. spell is true only when the text prints a
  $N damage/heal value. repeat is the count ("twice" or "summon two" is 2); split is only for
  "randomly split". "Set ... stats to N" is SET_STATS with amount N and amount2 N; "to N/M" uses
  N and M. If a later clause refers to the object an earlier clause touched ("give it Taunt"),
  use target.kind PREVIOUS and side ANY_CHARACTER; the printer prints "it".
- A Secret card sets "secret": true. The effect trigger is the event after "Secret:": after the opponent
  plays a minion is AFTER_OPPONENT_PLAY_CARD with "subjectType": 1; after the opponent casts a spell is
  AFTER_OPPONENT_CAST_SPELL; when a minion you control is attacked is WHEN_YOUR_MINION_ATTACKED; when
  your hero is attacked is WHEN_YOUR_HERO_ATTACKED. Use target kind TRIGGER_SOURCE for "it".
- An "X and <condition>: Y instead" card is one base effect X with a "replacement" array
  containing Y; Y carries the condition (COMBO, HEALTH_AT_MOST N, CONTROL_RACE, ...). The printer
  emits "X and combo: Y instead". Set "implicitTarget": true when Y omits the target.
- A "for each <selector>" clause is a count selector: set "countSelector": true and the
  countSide/countZone/countType/countRace/countKeyword/countDamagedOnly/countExcludeSource
  fields. "amount" is the per-count number. Example: "Gain +1/+1 for each damaged minion."
  {"trigger":"BATTLECRY","op":"BUFF","amount":1,"amount2":1,"target":{"kind":"SELF","side":"ANY_MINION"},"countSelector":true,"countSide":"ANY_MINION","countZone":"BOARD","countType":1,"countDamagedOnly":true}
- A "manathirst (N): ..." clause is a second effect with "condition": "MANATHIRST" and
  "conditionAmount": N. Keep the base effect as the first effect.
- If the printed text has Overload: (N), set the program's "overload": N. Tradeable -> "tradeable": true.
  Prepare -> "prepare": true. Reborn -> "keywords": ["reborn"]. Finale -> the effect's "condition": "FINALE".
- A nested "if it dies" / "if it survives" clause goes in the parent effect's "followUp" array
  (normal effect objects) with "followUpCondition": "IF_DIES" or "IF_SURVIVES". Follow-up
  effects use the same trigger; a follow-up that refers to the parent target uses
  "target": {"kind": "PREVIOUS", "side": "ANY_CHARACTER"}.
- A passive "Your ... have ..." card uses trigger AURA. For a named minion type, use BUFF_NAMED
  with tokenDisplay set to the printed name and target side FRIENDLY_MINIONS; for a generic
  "your minions", use BUFF or GIVE_KEYWORD with target ALL/FRIENDLY_MINIONS.
- A "Choose One - X; or Y" card uses "choices": [[the effects for X], [the effects for Y]] and
  "effects" repeats the first option. Each option is a normal effect list. The printer prints
  "choose one - ...". If a later option reuses the chosen target and omits the target phrase
  ("or $1 damage"), set implicitTarget true so the printer does not add it.
- A printed condition goes in "condition", with conditionRace / conditionAmount / conditionType /
  conditionSchool / conditionKeyword when that predicate takes it. The trigger for a Combo,
  Outcast, Kindred, Finale, Manathirst, Infuse or Quickdraw card is still BATTLECRY (or ON_PLAY)
  with the condition set.
- Filters narrow a target or a pool: type_filter (1 MINION, 2 SPELL, 3 WEAPON, 4 LOCATION),
  raceFilter, keywordFilter, costMin/costMax, rarityFilter (1..5), familyFilter (1..12),
  schoolFilter (1..7), targetAttackMin/Max, targetHealthMin/Max, damagedOnly, undamagedOnly,
  excludeSource ("another"), excludeRace ("except <tribe>").
- token is an existing card id for SUMMON/EQUIP/SHUFFLE/TRANSFORM/ADD_TO_HAND/RAISE_CORPSES;
  use one of the token hints when they are provided. tokenDisplay is what the text prints when the
  token's catalogue name is not printed: for a statted token use "<attack>/<health> <name in the
  text>" (for example "1/1 ram" or "2/4 grunt"). ADD_TO_HAND without tokenDisplay prints the
  catalogue name, which usually does not match the card text. For multiple tokens use "tokens": [ids].
- keyword is a comma-separated list of keyword names for GIVE_KEYWORD/BUFF/SUMMON/TRANSFORM.
- bothPlayers is for "each player" on DRAW/GAIN_MANA/GAIN_MANA_CRYSTAL. temporary is "this turn".
  durationTurns is "lasts N turns". setVerb is "set ... to". damageRange is "deal N to M".
- If a clause cannot be expressed with this vocabulary, output {"unsupported": "<the clause>"}.
  Never approximate, never drop a clause, and never output prose.

The program is printed back by a deterministic printer and compared with the card's canonical text.
A program that does not print the text is rejected. Worked examples:
  "Deal $1 damage to a minion. If it dies, draw a card."
  {"implemented":true,"effects":[{"trigger":"ON_PLAY","op":"DAMAGE","amount":1,"spell":true,"target":{"kind":"CHOOSE","side":"ANY_MINION"},"followUp":[{"trigger":"ON_PLAY","op":"DRAW","amount":1}],"followUpCondition":"IF_DIES"}]}
  "Your Silver Hand Recruits have +2 Attack and Taunt."
  {"implemented":true,"effects":[{"trigger":"AURA","op":"BUFF_NAMED","tokenDisplay":"Silver Hand Recruit","amount":2,"keyword":"taunt","target":{"kind":"ALL","side":"FRIENDLY_MINIONS"}}]}
  "Choose One - Deal $3 damage to a minion; or $1 damage and draw a card."
  {"implemented":true,"effects":[{"trigger":"ON_PLAY","op":"DAMAGE","amount":3,"spell":true,"target":{"kind":"CHOOSE","side":"ANY_MINION"}}],"choices":[[{"trigger":"ON_PLAY","op":"DAMAGE","amount":3,"spell":true,"target":{"kind":"CHOOSE","side":"ANY_MINION"}}],[{"trigger":"ON_PLAY","op":"DAMAGE","amount":1,"spell":true,"implicitTarget":true,"target":{"kind":"CHOOSE","side":"ANY_MINION"}},{"trigger":"ON_PLAY","op":"DRAW","amount":1}]]}
  "Battlecry: Add a 1/1 Spark with Rush to your hand."
  {"implemented":true,"effects":[{"trigger":"BATTLECRY","op":"ADD_TO_HAND","token":"BOT_102t","repeat":1,"keyword":"rush"}]}
  "Battlecry: Add two 2/4 Grunts with Taunt to your hand."
  {"implemented":true,"effects":[{"trigger":"BATTLECRY","op":"ADD_TO_HAND","token":"AV_323t","repeat":2,"keyword":"taunt"}]}
  "Deal $3 damage to a minion."
  {"implemented":true,"effects":[{"trigger":"ON_PLAY","op":"DAMAGE","amount":3,"spell":true,"target":{"kind":"CHOOSE","side":"ANY_MINION"}}]}

The examples below show the compact form.
"""


def load_json(path: Path) -> dict:
    with path.open() as handle:
        return json.load(handle)


def dump_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def compact_effect(effect: dict) -> dict:
    out: dict = {}
    for key, value in effect.items():
        if key == "target":
            if value:
                out["target"] = value
            continue
        if key == "repeat" and value == 1:
            continue
        if key == "buffAll" and value is True:
            continue
        if value in (None, "", 0, False, [], {}):
            continue
        out[key] = value
    return out


def compact_program(program: dict) -> dict:
    out: dict = {"implemented": True}
    for key, value in program.items():
        if key in ("implemented", "program"):
            continue
        if key == "effects":
            out["effects"] = [compact_effect(effect) for effect in value]
        elif key == "choices":
            out["choices"] = [[compact_effect(effect) for effect in option] for option in value]
        elif value not in (None, "", 0, False, [], {}):
            out[key] = value
    if "effects" not in out and "choices" not in out:
        out["effects"] = []
    return out


def vocabulary_text(vocab: dict) -> str:
    conditions = ", ".join(
        row["name"] + ("/amount" if row["takesAmount"] else "") +
        ("/race" if row["takesRace"] else "")
        for row in vocab["conditions"]
    )
    return (
        "OPS: " + ", ".join(vocab["ops"]) + "\n"
        "TRIGGERS: " + ", ".join(vocab["triggers"]) + "\n"
        "TARGET KINDS: " + ", ".join(vocab["targetKinds"]) + "\n"
        "TARGET SIDES: " + ", ".join(vocab["targetSides"]) + "\n"
        "CONDITIONS: " + conditions + "\n"
        "COST COUNTS: " + ", ".join(vocab["costCounts"]) + "\n"
        "VALUE SOURCES: " + ", ".join(vocab["valueSources"]) + "\n"
        "KEYWORDS: " + ", ".join(vocab["keywords"]) + "\n"
        "RACES: " + ", ".join(vocab["races"]) + "\n"
        "TYPES: " + ", ".join(vocab["types"]) + "\n"
        "FAMILIES: " + ", ".join(vocab["families"]) + "\n"
        "RARITIES: " + ", ".join(vocab["rarities"]) + "\n"
        "SCHOOLS: " + ", ".join(vocab["schools"]) + "\n"
        "OP NOTES: " + "; ".join(f"{name}={note}" for name, note in OP_NOTES.items()) + "\n"
    )


def examples_text(example_ids: list[str], programs: dict, catalogue: dict) -> str:
    chunks = []
    for card_id in example_ids:
        program = programs.get(card_id)
        card = catalogue.get(card_id)
        if not program or not card:
            continue
        chunks.append(
            f"TEXT: {card.get('text', '').replace(chr(10), ' ').strip()}\n"
            f"PROGRAM: {json.dumps(compact_program(program), sort_keys=True)}"
        )
    return "\n\n".join(chunks)


def build_messages(system: str, examples: str, row: dict, feedback: str = "") -> list[dict]:
    user = (
        f"card_id: {row['id']}\n"
        f"name: {row['name']}\n"
        f"type: {row['type']}\n"
        f"cost: {row['cost']}\n"
        f"attack: {row['attack']}\n"
        f"health: {row['health']}\n"
        f"family: {row['family']}\n"
        f"text: {row['text']}\n"
        f"compiler refusal: {row.get('refusal', '')}\n"
        f"likely op: {', '.join(row.get('hints', []))}\n"
    )
    hints = row.get("tokenHints") or []
    if hints:
        user += "token hints (existing card ids): " + ", ".join(
            f"{hint['id']}={hint['name']} {hint['attack']}/{hint['health']}" for hint in hints
        ) + "\n"
    if examples:
        user += "\nExamples of admitted cards in the compact form:\n" + examples + "\n"
    if feedback:
        user += "\nYour previous program was rejected. Fix it.\n" + feedback + "\n"
    user += "\nReturn one program object for this card."
    return [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ]


def http_json(url: str, body: dict, timeout: int) -> tuple[int, str]:
    request = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={"content-type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()
    except urllib.error.URLError as error:
        return 0, str(error)


def model_call(url: str, model: str, messages: list[dict], schema: dict, seed: int,
               timeout: int) -> dict:
    base = {"model": model, "messages": messages, "temperature": 0, "max_tokens": 1800,
            "seed": seed}
    started = time.time()
    status, text = http_json(url, {**base, "response_format": {
        "type": "json_schema",
        "json_schema": {"name": "authoring_v0", "schema": schema, "strict": True},
    }}, timeout)
    mode = "response_format"
    if status == 400:
        # vLLM also accepts the guided_json extension directly; keep both paths and record which one
        # answered, because a server upgrade can remove one of them.
        status, text = http_json(url, {**base, "guided_json": schema}, timeout)
        mode = "guided_json"
    latency_ms = int((time.time() - started) * 1000)
    if status != 200:
        return {"error": f"HTTP {status}: {text[:400]}", "latencyMs": latency_ms, "mode": mode}
    try:
        reply = json.loads(text)
        message = reply["choices"][0]["message"]
        content = message.get("content") or ""
        reasoning = message.get("reasoning_content") or ""
        usage = reply.get("usage", {})
    except (KeyError, IndexError, ValueError) as error:
        return {"error": f"malformed reply: {error}", "latencyMs": latency_ms, "mode": mode,
                "raw": text[:400]}
    return {"content": content, "reasoning": reasoning, "usage": usage,
            "latencyMs": latency_ms, "mode": mode}


def parse_program(content: str, card_id: str) -> dict:
    text = content.strip()
    if text.startswith("```"):
        text = text.strip("`")
        if text.startswith("json"):
            text = text[4:]
    start = text.find("{")
    end = text.rfind("}")
    if start < 0 or end < start:
        raise ValueError("reply has no JSON object")
    parsed = json.loads(text[start:end + 1])
    if "programs" in parsed and isinstance(parsed["programs"], dict):
        parsed = parsed["programs"].get(card_id, parsed)
    if "program" in parsed and isinstance(parsed["program"], dict):
        parsed = parsed["program"]
    if not isinstance(parsed, dict):
        raise ValueError("reply is not an object")
    return parsed


TARGETLESS_OPS = {
    "SUMMON", "SUMMON_RANDOM", "SUMMON_FROM_DECK", "SUMMON_COPY", "DRAW", "GAIN_ARMOR",
    "GAIN_MANA", "GAIN_MANA_CRYSTAL", "REFRESH_MANA", "GAIN_CORPSES", "RAISE_CORPSES",
    "DISCARD_HAND", "DREDGE", "DISCOVER", "ADD_TO_HAND", "SHUFFLE", "CLEAVE",
    "CANT_ATTACK_HEROES", "HERO_POWER_DAMAGE", "CARD_COST", "HERO_POWER_COST",
}
KIND_ALIASES = {
    "MINION": "CHOOSE", "CHARACTER": "CHOOSE", "TARGET": "CHOOSE",
    "ALL_MINIONS": "ALL", "EVERY_MINION": "ALL", "EVERYTHING": "ALL",
    "RANDOM_MINION": "RANDOM", "ONE_RANDOM": "RANDOM",
    "SELF_MINION": "SELF", "THIS": "SELF",
}
SIDE_ALIASES = {
    "YOUR_MINION": "FRIENDLY_MINION", "YOUR_MINIONS": "FRIENDLY_MINIONS",
    "FRIENDLY": "FRIENDLY_MINION", "MINION": "ANY_MINION", "ANY": "ANY_CHARACTER",
    "ENEMY": "ENEMY_MINION", "ENEMIES": "ENEMY_MINIONS", "SELF": "ANY_CHARACTER",
    "YOUR_CHARACTER": "FRIENDLY_CHARACTER", "ENEMY_CHARACTER": "ENEMY_CHARACTER",
}
TRIGGER_WORDS = {
    "battlecry", "deathrattle", "inspire", "combo", "outcast", "spellburst",
    "honorable kill", "frenzy", "overkill", "forged", "quickdraw", "infuse",
    "manathirst", "finale", "start of game",
}


def normalize_candidate(program: dict) -> tuple[dict, list[str]]:
    """Repair only deterministic vocabulary aliases, never semantics.

    The model frequently uses the printed noun ("MINION") where the IR uses a selector
    ("CHOOSE"), or puts a target on an op that ignores one. Those are spelling/placement
    mistakes with one correct answer, so they are normalized and logged; anything that
    changes meaning (a condition, an amount, an op) is left for the verifier and the retry.
    """
    notes: list[str] = []
    program.setdefault("implemented", True)
    effects = program.get("effects")
    if isinstance(effects, dict):
        program["effects"] = [effects]
        notes.append("wrapped a single effect object in effects[]")
        effects = program["effects"]
    if isinstance(effects, list):
        for index, effect in enumerate(effects):
            if not isinstance(effect, dict):
                continue
            op = effect.get("op")
            if op in TARGETLESS_OPS and "target" in effect:
                effect.pop("target")
                notes.append(f"effects[{index}]: removed target on {op} (the op ignores it)")
            target = effect.get("target")
            if isinstance(target, dict):
                kind = target.get("kind")
                if kind in KIND_ALIASES:
                    target["kind"] = KIND_ALIASES[kind]
                    notes.append(f"effects[{index}]: target.kind {kind} -> {target['kind']}")
                side = target.get("side")
                if side in SIDE_ALIASES:
                    target["side"] = SIDE_ALIASES[side]
                    notes.append(f"effects[{index}]: target.side {side} -> {target['side']}")
                if target.get("kind") not in {
                    "CHOOSE", "ALL", "RANDOM", "SELF", "ADJACENT", "TRIGGER_SOURCE",
                    "PREVIOUS", "LOWEST_HEALTH", "HIGHEST_ATTACK",
                }:
                    effect.pop("target", None)
                    notes.append(f"effects[{index}]: removed an invalid target kind")
    keywords = program.get("keywords")
    if isinstance(keywords, list):
        kept = [word for word in keywords if str(word).lower() not in TRIGGER_WORDS]
        if kept != keywords:
            notes.append("removed trigger/condition words from top-level keywords")
            program["keywords"] = kept
    return program, notes


def choice_options(text: str) -> list[str]:
    lowered = text.lower()
    marker = "choose 1 - "
    if marker not in lowered:
        return []
    body = lowered.split(marker, 1)[1]
    return [part.strip() for part in body.split(", or ")]


def pick_choice_token(option: str, hints: list[dict]) -> dict | None:
    stats = re.search(r"(\d+)\s*/\s*(\d+)", option)
    words = set(re.findall(r"[a-z]+", option))
    best = None
    best_score = 0
    for hint in hints:
        hp = hint.get("durability") or hint.get("health") or 0
        score = 0
        if stats and (hint.get("attack", 0), hp) == (int(stats.group(1)), int(stats.group(2))):
            score += 3
        name_words = set(re.findall(r"[a-z]+", (hint.get("name") or "").lower()))
        score += 2 * len(name_words & words)
        if score > best_score:
            best, best_score = hint, score
    return best if best_score >= 3 else None


def normalize_choice_tokens(program: dict, row: dict) -> dict:
    options = choice_options(row.get("text") or "")
    hints = row.get("tokenHints") or []
    choices = program.get("choices") or []
    if not options or not hints or not choices:
        return program
    for index, option in enumerate(choices):
        if index >= len(options):
            break
        option_text = options[index]
        for effect in option:
            if not isinstance(effect, dict):
                continue
            if effect.get("op") not in ("SUMMON", "ADD_TO_HAND", "SHUFFLE", "TRANSFORM", "EQUIP"):
                continue
            hint = pick_choice_token(option_text, hints)
            if hint is None:
                continue
            effect["token"] = hint["id"]
            display = token_display_from_text(option_text)
            if display:
                effect["tokenDisplay"] = display
            keyword = keyword_from_text(option_text)
            if keyword:
                effect["keyword"] = keyword
    return program


def normalize_from_text(program: dict, row: dict, vocab: dict) -> dict:
    """Correct the two presentation facts the printed text fixes for a sequence."""
    lowered = (row.get("text") or "").lower()
    lowered = lowered.replace("youve", "you've").replace("youre", "you're")
    if row.get("secret"):
        program["secret"] = True
    effects = program.get("effects") or []
    condition_rules = (
        (r"your opponent has (\d+) or less health", "OPPONENT_HEALTH_AT_MOST", True),
        (r"an enemy is frozen", "ENEMY_MINION_FROZEN", False),
        (r"only minion on the battlefield", "ONLY_MINION", False),
        (r"a minion died this turn", "MINION_DIED_THIS_TURN", False),
        (r"you have spell damage", "HAS_SPELL_DAMAGE", False),
        (r"control a minion with (\d+) or more health", "CONTROL_MINION_HEALTH_AT_LEAST", True),
        (r"control a minion with (\d+) or more attack", "CONTROL_MINION_ATTACK_AT_LEAST", True),
        (r"played a (\w+) spell this turn", "PLAYED_SCHOOL_THIS_TURN", "school"),
        (r"control no other minions", "CONTROL_NO_OTHER_MINIONS", False),
        (r"an enemy minion has taunt", "ENEMY_MINION_TAUNT", False),
    )
    for effect in effects:
        if not isinstance(effect, dict):
            continue
        if effect.get("op") == "DAMAGE":
            damage = re.search(r"deal \$?(\d+)", lowered)
            if damage:
                effect["amount"] = int(damage.group(1))
            if "$" not in (row.get("text") or ""):
                effect["spell"] = False
        for pattern, name, takes_amount in condition_rules:
            match = re.search(pattern, lowered)
            if not match:
                continue
            effect["condition"] = name
            effect.pop("conditionRace", None)
            effect.pop("conditionType", None)
            effect.pop("conditionKeyword", None)
            effect.pop("conditionSchool", None)
            if takes_amount == "school":
                effect["conditionSchool"] = match.group(1)
                effect.pop("conditionAmount", None)
            elif takes_amount:
                effect["conditionAmount"] = int(match.group(1))
            else:
                effect.pop("conditionAmount", None)
            if effect.get("op") == "DRAW" and re.search(r"draw(?: \d+)? cards?", lowered):
                effect.pop("type_filter", None)
                effect.pop("keywordFilter", None)
                effect.pop("raceFilter", None)
            break
        if effect.get("op") in ("BUFF", "GIVE_KEYWORD") and "gain " in lowered:
            effect["target"] = {"kind": "SELF", "side": "ANY_MINION"}
        if "give a minion" in lowered and effect.get("op") in ("BUFF", "GIVE_KEYWORD"):
            effect["target"] = {"kind": "CHOOSE", "side": "ANY_MINION"}
        if effect.get("op") == "DESTROY" and not effect.get("target"):
            effect["target"] = {"kind": "CHOOSE", "side": "ANY_MINION"}
        if effect.get("op") == "DRAW":
            effect.pop("target", None)
            match = re.search(r"draw (\d+) cards?", lowered)
            if match:
                effect["amount"] = int(match.group(1))
        if "conditionSelector" in effect:
            effect["countSelector"] = effect.pop("conditionSelector")
        if effect.get("trigger") == "BATTLECRY" and not any(
                word in lowered for word in ("battlecry", "combo", "finale")):
            effect["trigger"] = "ON_PLAY"
        if effect.get("countSelector"):
            effect.pop("amountSource", None)
            effect.pop("amountSourceRace", None)
        if effect.get("op") == "BUFF":
            attack = re.search(r"gain \+(\d+) attack", lowered)
            health = re.search(r"gain \+(\d+) health", lowered)
            pair = re.search(r"\+(\d+)/\+(\d+)", lowered)
            if pair:
                effect["amount"], effect["amount2"] = int(pair.group(1)), int(pair.group(2))
            elif attack:
                effect["amount"], effect["amount2"] = int(attack.group(1)), 0
            elif health:
                effect["amount"], effect["amount2"] = 0, int(health.group(1))
            if row.get("type") == "SPELL" and attack:
                effect["target"] = {"kind": "SELF", "side": "YOUR_HERO"}
        if "for each" in lowered and ("this game" in lowered or "this turn" in lowered):
            source = ""
            race = ""
            if "this game" in lowered:
                if "friendly minion that died" in lowered: source = "GAME_FRIENDLY_MINIONS_DIED"
                elif "minion that died" in lowered: source = "GAME_MINIONS_DIED"
                elif "minion you've summoned" in lowered: source = "GAME_MINIONS_SUMMONED"
                elif "spell you've cast" in lowered: source = "GAME_SPELLS_CAST"
                elif "card you've played" in lowered: source = "GAME_CARDS_PLAYED"
                elif "card you've drawn" in lowered: source = "GAME_CARDS_DRAWN"
                elif "hero power" in lowered: source = "GAME_HERO_POWER_USES"
                elif "overloaded" in lowered: source = "GAME_MANA_OVERLOADED"
                elif "card you've discarded" in lowered: source = "GAME_CARDS_DISCARDED"
                elif "weapon you've equipped" in lowered: source = "GAME_WEAPONS_EQUIPPED"
                elif "secret that has triggered" in lowered: source = "GAME_SECRETS_TRIGGERED"
                elif "secret you've played" in lowered: source = "GAME_SECRETS_PLAYED"
                elif "you've played this game" in lowered:
                    source = "GAME_MINIONS_OF_RACE"
                    for name in vocab["races"]:
                        if name in lowered:
                            race = name
                            break
            else:
                if "other card you've played" in lowered: source = "OTHER_CARDS_PLAYED_THIS_TURN"
                elif "minion that died" in lowered: source = "MINIONS_DIED_THIS_TURN"
                elif "other card you've played" in lowered: source = "OTHER_CARDS_PLAYED_THIS_TURN"
                elif "card you've played" in lowered: source = "CARDS_PLAYED_THIS_TURN"
                elif "damage your hero has taken" in lowered: source = "HERO_DAMAGE_TAKEN_THIS_TURN"
                elif "combo card played this turn" in lowered: source = "COMBO_CARDS_PLAYED_THIS_TURN"
                elif "spell you've cast" in lowered: source = "SPELLS_CAST_THIS_TURN"
                elif "card you've drawn" in lowered: source = "CARDS_DRAWN_THIS_TURN"
            if source:
                condition_words = ("if ", "combo", "finale", "outcast", "manathirst", "spellburst", "while ")
                if not any(word in lowered for word in condition_words):
                    effect.pop("condition", None)
                    effect.pop("conditionAmount", None)
                    effect.pop("conditionRace", None)
                    effect.pop("conditionType", None)
                    effect.pop("conditionSchool", None)
                    effect.pop("conditionKeyword", None)
                effect["amountSource"] = source
                for key in list(effect):
                    if key == "countSelector" or key.startswith("count"):
                        effect.pop(key, None)
                if race:
                    effect["amountSourceRace"] = race
        if "for each" in lowered and "countSelector" not in effect and not effect.get("amountSource"):
            tail = lowered.split("for each", 1)[1]
            clause = re.split(r"[.,;]", tail, 1)[0]
            zone = "BOARD"
            if "in your hand" in clause:
                zone = "HAND"
            elif "in your deck" in clause:
                zone = "DECK"
            elif "in your graveyard" in clause:
                zone = "GRAVEYARD"
            side = "ANY_MINION"
            if zone in ("HAND", "DECK"):
                side = "FRIENDLY_HAND"
            elif "enemy" in clause or "opponent" in clause:
                side = "ENEMY_MINIONS"
            elif any(word in clause for word in ("other", "your ", "you control", "friendly", "of your")):
                side = "FRIENDLY_MINIONS"
            count_type = 0
            if "spell" in clause:
                count_type = 2
            elif "weapon" in clause:
                count_type = 3
            elif "minion" in clause or any(race in clause for race in vocab["races"]):
                count_type = 1
            elif "card" in clause:
                count_type = 0
            effect["countSelector"] = True
            effect["countSide"] = side
            effect["countZone"] = zone
            effect["countType"] = count_type
            effect.pop("countRace", None)
            effect.pop("countKeyword", None)
            for race in vocab["races"]:
                if race in clause:
                    effect["countRace"] = race
                    break
            for keyword in ("deathrattle", "battlecry", "taunt", "rush", "charge", "poisonous"):
                if keyword in clause:
                    effect["countKeyword"] = keyword
                    break
            if "damaged" in clause:
                effect["countDamagedOnly"] = True
            if "other" in clause:
                effect["countExcludeSource"] = True
        if "finale:" in lowered and effect.get("trigger") == "BATTLECRY" and \
                effect.get("condition") in (None, "", "NONE"):
            effect["condition"] = "FINALE"
        if effect.get("op") == "SWAP_STATS":
            if "minion you control" in lowered:
                effect["target"] = {"kind": "CHOOSE", "side": "FRIENDLY_MINION"}
            elif "another minion" in lowered:
                effect["target"] = {"kind": "CHOOSE", "side": "ANY_OTHER_MINION"}
        if effect.get("op") == "GIVE_KEYWORD" and "freeze this" in lowered:
            effect["target"] = {"kind": "SELF", "side": "ANY_CHARACTER"}
        if effect.get("op") in ("SET_HEALTH", "SET_ATTACK") and "hero" in lowered:
            effect.pop("type_filter", None)
            effect["target"] = {"kind": "SELF", "side": "YOUR_HERO"}
        if effect.get("op") == "SUMMON" and effect.get("keyword"):
            display = str(effect.get("tokenDisplay") or "").lower()
            spoken = str(effect["keyword"]).replace("_", " ")
            if spoken and spoken in display:
                effect.pop("keyword", None)
        if effect.pop("secret", None):
            program["secret"] = True
        condition = effect.get("condition")
        if isinstance(condition, dict):
            if condition.get("secret"):
                program["secret"] = True
            effect.pop("condition", None)
    def fix(effect, index):
        if not isinstance(effect, dict):
            return
        if effect.get("op") == "SET_STATS" and effect.get("amount2", 0) == 0 and effect.get("amount", 0) > 0:
            effect["amount2"] = effect["amount"]
        target = effect.get("target")
        if (isinstance(target, dict) and target.get("kind") == "CHOOSE" and index > 0
                and "give it" in lowered and effect.get("op") in ("GIVE_KEYWORD", "BUFF")):
            target["kind"] = "PREVIOUS"
            target["side"] = "ANY_CHARACTER"

    if "damage to an enemy" in lowered and "enemy minion" not in lowered:
        for effect in effects:
            if isinstance(effect, dict) and effect.get("op") == "DAMAGE" and \
                    isinstance(effect.get("target"), dict):
                effect["target"]["side"] = "ENEMY_CHARACTER"
    if "damage to a minion" in lowered and "damage to a minion you control" not in lowered:
        for effect in effects:
            if isinstance(effect, dict) and effect.get("op") == "DAMAGE" and                     isinstance(effect.get("target"), dict) and                     effect["target"].get("kind") == "CHOOSE":
                effect["target"]["side"] = "ANY_MINION"
    for index, effect in enumerate(effects):
        fix(effect, index)
    for option in program.get("choices") or []:
        for index, effect in enumerate(option):
            fix(effect, index)

    # The model often omits the nested condition or reuses PREVIOUS for a clause that names a new
    # target. Infer both from the printed clause; the printer proof still decides admission.
    follow_clause = ""
    if "if it dies," in lowered:
        follow_clause = lowered.split("if it dies,", 1)[1]
    elif "if it survives," in lowered:
        follow_clause = lowered.split("if it survives,", 1)[1]
    for effect in effects:
        if not isinstance(effect, dict) or not effect.get("followUp"):
            continue
        if effect.get("followUpCondition") in (None, "", "NONE"):
            if "if it dies" in lowered:
                effect["followUpCondition"] = "IF_DIES"
            elif "if it survives" in lowered:
                effect["followUpCondition"] = "IF_SURVIVES"
        for child in effect["followUp"]:
            if not isinstance(child, dict):
                continue
            if effect.get("trigger"):
                child["trigger"] = effect["trigger"]
            target = child.get("target")
            if not isinstance(target, dict):
                continue
            if "enemy hero" in follow_clause:
                target["kind"] = "SELF"
                target["side"] = "ENEMY_HERO"
            elif "your hero" in follow_clause:
                target["kind"] = "SELF"
                target["side"] = "YOUR_HERO"
    return normalize_choice_tokens(program, row)


def validate_candidate(program: dict, keys: dict, vocab: dict) -> list[str]:
    problems: list[str] = []
    if not isinstance(program, dict):
        return ["the program must be an object"]
    if program.get("implemented") is not True:
        problems.append("implemented must be true")
    for key in program:
        if key not in keys["program"]:
            problems.append(f"unknown program field '{key}'")
    effects = program.get("effects")
    if effects is not None and not isinstance(effects, list):
        problems.append("effects must be an array")
        return problems
    triggers = set(vocab["triggers"])
    ops = set(vocab["ops"])
    kinds = set(vocab["targetKinds"])
    sides = set(vocab["targetSides"])
    conditions = {row["name"] for row in vocab["conditions"]}
    def check_list(effects_in, prefix):
        for index, effect in enumerate(effects_in or []):
            if not isinstance(effect, dict):
                problems.append(f"{prefix}[{index}] must be an object")
                continue
            for key in effect:
                if key not in keys["effect"]:
                    problems.append(f"{prefix}[{index}]: unknown field '{key}'")
            if effect.get("trigger") not in triggers:
                problems.append(f"{prefix}[{index}].trigger must be one of {sorted(triggers)}")
            if effect.get("op") not in ops:
                problems.append(f"{prefix}[{index}].op must be one of {sorted(ops)}")
            target = effect.get("target")
            if target is not None:
                if not isinstance(target, dict):
                    problems.append(f"{prefix}[{index}].target must be an object")
                else:
                    if target.get("kind") not in kinds:
                        problems.append(f"{prefix}[{index}].target.kind must be one of {sorted(kinds)}")
                    if target.get("side") not in sides:
                        problems.append(f"{prefix}[{index}].target.side must be one of {sorted(sides)}")
            follow = effect.get("followUp")
            if follow is not None:
                if not isinstance(follow, list):
                    problems.append(f"{prefix}[{index}].followUp must be an array")
                else:
                    check_list(follow, f"{prefix}[{index}].followUp")
            follow_condition = effect.get("followUpCondition")
            if follow_condition not in (None, "", "NONE", "IF_DIES", "IF_SURVIVES"):
                problems.append(f"{prefix}[{index}].followUpCondition is unknown")
            condition = effect.get("condition")
            if condition is not None:
                if not isinstance(condition, str):
                    problems.append(f"{prefix}[{index}].condition must be a string name")
                elif condition not in conditions:
                    problems.append(f"{prefix}[{index}].condition must be a condition name, not {condition!r}")

    check_list(effects, "effects")
    for option_index, option in enumerate(program.get("choices") or []):
        check_list(option, f"choices[{option_index}]")
    return problems

    # Unreachable legacy loop retained for reference below.
    for index, effect in enumerate(effects or []):
        if not isinstance(effect, dict):
            problems.append(f"effects[{index}] must be an object")
            continue
        for key in effect:
            if key not in keys["effect"]:
                problems.append(f"effects[{index}]: unknown field '{key}'")
        if effect.get("trigger") not in triggers:
            problems.append(f"effects[{index}].trigger must be one of {sorted(triggers)}")
        if effect.get("op") not in ops:
            problems.append(f"effects[{index}].op must be one of {sorted(ops)}")
        target = effect.get("target")
        if target is not None:
            if not isinstance(target, dict):
                problems.append(f"effects[{index}].target must be an object")
            else:
                if target.get("kind") not in kinds:
                    problems.append(f"effects[{index}].target.kind must be one of {sorted(kinds)}")
                if target.get("side") not in sides:
                    problems.append(f"effects[{index}].target.side must be one of {sorted(sides)}")
        condition = effect.get("condition")
        if condition is not None and condition not in conditions:
            problems.append(f"effects[{index}].condition must be a condition name, not {condition!r}")
    return problems


TOKEN_TOOL_OPS = {"ADD_TO_HAND", "SUMMON"}


def token_op(row: dict) -> str:
    hints = set(row.get("hints") or [])
    if not row.get("tokenHints"):
        return ""
    if "ADD_TO_HAND" in hints:
        return "ADD_TO_HAND"
    if "SUMMON" in hints:
        return "SUMMON"
    return ""


def token_display_from_text(text: str) -> str:
    """The printer's token_display for a statted noun: '2 1/1 Rams' -> '1/1 ram'."""
    import re
    match = re.search(r"(\d+)\s*/\s*(\d+)\s+([A-Za-z' ]+?)(?:\s+(?:that|with|and)\b|[,.]|$)", text)
    if not match:
        return ""
    noun = match.group(3).lower()
    if noun.endswith("ies"):
        noun = noun[:-3] + "y"
    elif noun.endswith("ves"):
        noun = noun[:-3] + "f"
    elif noun.endswith("s") and not noun.endswith("ss"):
        noun = noun[:-1]
    return f"{match.group(1)}/{match.group(2)} {noun}"


def keyword_from_text(text: str) -> str:
    import re
    lowered = text.lower()
    for keyword in ["divine shield", "taunt", "rush", "charge", "lifesteal", "poisonous",
                    "windfury", "stealth", "reborn", "freeze"]:
        if re.search(r"\b(with|and|has|have|gain)\s+" + re.escape(keyword), lowered):
            return keyword.replace(" ", "_")
    return ""


def condition_properties(vocab: dict) -> dict:
    return {
        "condition": {"type": "string",
                      "enum": [row["name"] for row in vocab["conditions"]],
                      "description": "The printed condition, or NONE."},
        "condition_race": {"type": "string", "enum": [""] + list(vocab["races"])},
        "condition_amount": {"type": "integer", "minimum": 0, "maximum": 20},
        "condition_type": {"type": "integer", "minimum": 0, "maximum": 4},
        "condition_keyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
        "condition_school": {"type": "string", "enum": [""] + list(vocab["schools"])},
    }


def filter_properties(vocab: dict) -> dict:
    return {
        "type_filter": {"type": "integer", "minimum": 0, "maximum": 4,
                        "description": "1 minion, 2 spell, 3 weapon, 4 location; 0 any."},
        "keyword_filter": {"type": "string", "enum": [""] + list(vocab["keywords"])},
        "race_filter": {"type": "string", "enum": [""] + list(vocab["races"])},
        "cost_min": {"type": "integer", "minimum": 0, "maximum": 10},
        "cost_max": {"type": "integer", "minimum": 0, "maximum": 10},
        "rarity_filter": {"type": "integer", "minimum": 0, "maximum": 5},
        "family_filter": {"type": "integer", "minimum": 0, "maximum": 12},
        "school_filter": {"type": "integer", "minimum": 0, "maximum": 7},
        "damaged_only": {"type": "boolean"},
        "undamaged_only": {"type": "boolean"},
        "exclude_source": {"type": "boolean"},
        "from_deck": {"type": "boolean"},
    }


def apply_condition(effect: dict, args: dict) -> None:
    condition = str(args.get("condition") or "")
    if not condition or condition == "NONE":
        return
    effect["condition"] = condition
    for key, field in (("condition_race", "conditionRace"),
                       ("condition_amount", "conditionAmount"),
                       ("condition_type", "conditionType"),
                       ("condition_keyword", "conditionKeyword"),
                       ("condition_school", "conditionSchool")):
        value = args.get(key)
        if value not in (None, "", 0):
            effect[field] = value


def apply_text_filters(effect: dict, row: dict, vocab: dict) -> None:
    text = (row.get("text") or "").lower()
    if not effect.get("type_filter"):
        for word, value in (("minion", 1), ("spell", 2), ("weapon", 3), ("location", 4)):
            if word in text:
                effect["type_filter"] = value
                break
    if not effect.get("keywordFilter"):
        for keyword in vocab["keywords"]:
            spoken = keyword.replace("_", " ")
            if ("with " + spoken) in text or (spoken + " minion") in text or                     (spoken + " cards") in text:
                effect["keywordFilter"] = keyword
                break
    if effect.get("op") in ("DISCOVER", "ADD_TO_HAND") and not effect.get("familyFilter"):
        for index, family in enumerate(vocab["families"]):
            if family.lower() in text:
                effect["familyFilter"] = index + 1
                break
    if not effect.get("raceFilter"):
        for race in vocab["races"]:
            if (race + "s") in text or (race + " minion") in text:
                effect["raceFilter"] = race
                break
        if "mechs" in text:
            effect["raceFilter"] = "mechanical"
    if not effect.get("costMax"):
        match = re.search(r"\b(\d+)-cost\b", text)
        if match:
            effect["costMin"] = int(match.group(1))
            effect["costMax"] = int(match.group(1))
    if not effect.get("costMax"):
        match = re.search(r"costs? (\d+) or less", text)
        if match:
            effect["costMax"] = int(match.group(1))
    if not effect.get("costMin"):
        match = re.search(r"costs? (\d+) or more", text)
        if match:
            effect["costMin"] = int(match.group(1))


def apply_filters(effect: dict, args: dict) -> None:
    for key, field in (("type_filter", "type_filter"),
                       ("keyword_filter", "keywordFilter"),
                       ("race_filter", "raceFilter"),
                       ("cost_min", "costMin"),
                       ("cost_max", "costMax"),
                       ("rarity_filter", "rarityFilter"),
                       ("family_filter", "familyFilter"),
                       ("school_filter", "schoolFilter"),
                       ("damaged_only", "damagedOnly"),
                       ("undamaged_only", "undamagedOnly"),
                       ("exclude_source", "excludeSource"),
                       ("from_deck", "fromDeck")):
        value = args.get(key)
        if value not in (None, "", 0):
            effect[field] = value


def build_token_tool(row: dict, op: str, vocab: dict) -> dict:
    hints = row.get("tokenHints") or []
    ids = [hint["id"] for hint in hints]
    hint_text = "; ".join(
        f"{hint['id']}={hint['name']} {hint['attack']}/{hint['health']}"
        + ((" " + ",".join(hint.get("keywords") or [])) if hint.get("keywords") else "")
        for hint in hints
    )
    parameters = {
        "type": "object",
        "additionalProperties": False,
        "properties": {
            "token": {
                "type": "string",
                **({"enum": ids} if ids else {}),
                "description": "The token card id. Prefer the card's own token; hints: " + hint_text,
            },
            "repeat": {
                "type": "integer",
                "enum": [1, 2, 3, 4, 5],
                "description": "How many copies the text adds/summons.",
            },
            "keyword": {
                "type": "string",
                "enum": [""] + list(vocab["keywords"]),
                "description": "The token's printed keyword, or empty. Do not invent one.",
            },
            "token_display": {
                "type": "string",
                "description": "For a named token with no stats, the exact printed phrase including "
                               "its article, e.g. 'the first seal'. Omit for a statted token.",
            },
            "trigger": {
                "type": "string",
                "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"],
                "description": "The printed trigger prefix.",
            },
        },
        "required": ["token", "repeat", "keyword", "trigger"],
    }
    parameters["properties"].update(condition_properties(vocab))
    parameters["properties"].update(filter_properties(vocab))
    parameters["properties"].update(follow_up_properties(row, vocab))
    return {"type": "function", "function": {
        "name": "author_" + op.lower(),
        "description": (
            "Author one " + op + " effect for this card. The printer derives token_display from the "
            "card text; do not send it. Use the token hint that matches the printed noun and stats. "
            "The keyword is the token's printed keyword (rush, taunt, ...) or empty."
        ),
        "parameters": parameters,
    }}


def build_tool_messages(row: dict, op: str, tool: dict, feedback: str = "") -> list[dict]:
    hints = row.get("tokenHints") or []
    system = (
        "You author exactly one card program by calling the tool. "
        "Call author_" + op.lower() + " exactly once. "
        "Use the token hint whose name and stats match the printed card text. "
        "Do not send a token_display; the assembler derives the printed stats and noun from the card text. "
        "The keyword is the token's printed keyword, or empty. For a named token with no stats, set "
        "token_display to the exact printed phrase including its article ('the first seal'). "
        "If the card has an 'if it dies' or 'if it survives' clause, set followUpOp/"
        "followUpCondition and the child fields; the child is not a second independent effect. "
        "For a Discover followed by 'give it ...', set thenOp/thenAttack/thenHealth/thenKeyword; "
        "this is a separate second effect targeting the discovered card. "
        "If the text starts with Outcast: or Combo:, set condition OUTCAST or COMBO; a minion uses "
        "trigger BATTLECRY and a spell uses ON_PLAY. If it starts Battlecry: If ..., set the condition "
        "and its race/amount/type/keyword argument. "
        "Never add a target: these ops take none. "
        "If the text has an 'if it dies' or 'if it survives' clause, set followUpOp, "
        "followUpCondition and the follow-up fields for that child effect."
    )
    user = (
        f"card_id: {row['id']}\n"
        f"name: {row['name']}\n"
        f"text: {row['text']}\n"
        f"compiler refusal: {row.get('refusal', '')}\n"
        "token hints: " + "; ".join(
            f"{hint['id']}={hint['name']} {hint['attack']}/{hint['health']}"
            + ((" " + ",".join(hint.get("keywords") or [])) if hint.get("keywords") else "")
            for hint in hints
        ) + "\n"
    )
    if feedback:
        user += "\nYour previous attempt was rejected. Fix it.\n" + feedback + "\n"
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def model_tool_call(url: str, model: str, messages: list[dict], tool: dict, seed: int,
                    timeout: int) -> dict:
    body = {
        "model": model,
        "messages": messages,
        "tools": [tool],
        "tool_choice": {"type": "function", "function": {"name": tool["function"]["name"]}},
        "temperature": 0,
        "max_tokens": 800,
        "seed": seed,
    }
    started = time.time()
    status, text = http_json(url, body, timeout)
    # llama.cpp rejects the OpenAI object form of tool_choice but accepts "required"; retry once
    # with that spelling so one client works against both the vLLM and llama.cpp deployments.
    if status == 400 and "tool_choice" in text:
        body["tool_choice"] = "required"
        status, text = http_json(url, body, timeout)
    latency_ms = int((time.time() - started) * 1000)
    if status != 200:
        return {"error": f"HTTP {status}: {text[:400]}", "latencyMs": latency_ms, "mode": "tool"}
    try:
        reply = json.loads(text)
        message = reply["choices"][0]["message"]
        usage = reply.get("usage", {})
    except (KeyError, IndexError, ValueError) as error:
        return {"error": f"malformed reply: {error}", "latencyMs": latency_ms, "mode": "tool",
                "raw": text[:400]}
    return {"tool_calls": message.get("tool_calls") or [], "content": message.get("content") or "",
            "reasoning": message.get("reasoning_content") or "", "usage": usage,
            "latencyMs": latency_ms, "mode": "tool"}


def parse_tool_arguments(reply: dict) -> dict:
    calls = reply.get("tool_calls") or []
    if calls:
        arguments = calls[0]["function"].get("arguments", "")
    else:
        arguments = reply.get("content", "")
    if isinstance(arguments, dict):
        return arguments
    return json.loads(arguments)


def assemble_token_program(row: dict, op: str, args: dict) -> dict:
    token = str(args.get("token") or "")
    if not token:
        raise ValueError("the tool call did not name a token")
    try:
        repeat = int(args.get("repeat", 1))
    except (TypeError, ValueError):
        repeat = 1
    repeat = max(1, min(5, repeat))
    trigger = str(args.get("trigger") or "")
    lowered = row["text"].lower()
    if trigger not in {"BATTLECRY", "DEATHRATTLE", "ON_PLAY"}:
        trigger = ""
    # The trigger is a property of the printed text, not a guess: a spell resolves on play and a
    # card with no Battlecry/Deathrattle prefix cannot carry that trigger. This fixes the common
    # "BATTLECRY" default on a spell without weakening a real trigger.
    if ("outcast" in lowered or "combo" in lowered) and trigger in ("", "BATTLECRY", "ON_PLAY"):
        trigger = "BATTLECRY" if row.get("type") == "MINION" else "ON_PLAY"
    if trigger == "BATTLECRY" and "battlecry" not in lowered:
        trigger = "DEATHRATTLE" if "deathrattle" in lowered else "ON_PLAY"
    elif trigger == "DEATHRATTLE" and "deathrattle" not in lowered:
        trigger = "BATTLECRY" if "battlecry" in lowered else "ON_PLAY"
    elif not trigger:
        if "deathrattle" in lowered:
            trigger = "DEATHRATTLE"
        elif "battlecry" in lowered:
            trigger = "BATTLECRY"
        else:
            trigger = "ON_PLAY"
    effect = {"trigger": trigger, "op": op, "token": token, "repeat": repeat}
    display = str(args.get("token_display") or "") or token_display_from_text(row["text"])
    if not display:
        # A named token with no stats: take the printed phrase, article included, so the printer
        # does not add a second article ("add a the first seal").
        named = re.search(r"\badd (a|an|the) ([a-z0-9' ]+?)(?: to (?:your|each player's|their) hand|\.|$)",
                          row["text"].lower())
        if named:
            display = (named.group(1) + " " + named.group(2)).strip()
    if display:
        effect["tokenDisplay"] = display
    keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
    if not keyword:
        keyword = keyword_from_text(row["text"])
    if keyword:
        lowered_text = row["text"].lower()
        leading = lowered_text.split(" . ")[0].strip()
        after_add = lowered_text[lowered_text.find("add"):] if "add" in lowered_text else lowered_text
        spoken = keyword.replace("_", " ")
        # A card's own keyword line ("Taunt. Deathrattle: ...") is not the token's keyword. Keep
        # the argument only when the add/summon clause itself prints "with <keyword>".
        if keyword in leading and ("with " + spoken) not in after_add:
            keyword = ""
    if keyword:
        effect["keyword"] = keyword
    apply_condition(effect, args)
    apply_filters(effect, args)
    return {"implemented": True, "effects": [effect]}


FAMILY_OPS = ("ADD_TO_HAND", "SUMMON", "SUMMON_FROM_DECK", "EQUIP", "DISCOVER", "SHUFFLE",
              "TRANSFORM", "COPY", "AURA", "COST_AURA", "COST_REDUCE", "DAMAGE", "HEAL",
              "DRAW", "GAIN_ARMOR", "TRIGGER",
              "BUFF", "GIVE_KEYWORD", "DESTROY", "SET_STATS", "SET_ATTACK", "SET_HEALTH",
              "SWAP_STATS")
TARGET_OPS = {"DAMAGE", "HEAL", "BUFF", "GIVE_KEYWORD", "DESTROY", "SET_STATS", "SET_ATTACK",
              "SET_HEALTH", "SWAP_STATS"}
NUMERIC_OPS = {"DAMAGE", "HEAL", "DRAW", "GAIN_ARMOR", "SET_ATTACK", "SET_HEALTH"}
KEYWORD_WORDS = ("taunt", "divine shield", "rush", "charge", "lifesteal", "poisonous",
                 "windfury", "stealth", "reborn", "freeze", "immune")


def choose_op(row: dict) -> str:
    hints = set(row.get("hints") or [])
    text = (row.get("text") or "").lower()
    if row.get("secret"):
        return "SECRET"
    if " if " in text:
        clause = text.split(" if ", 1)[1]
        if "," in clause:
            clause = clause.split(",", 1)[1]
        for word, op in (("draw", "DRAW"), ("deal", "DAMAGE"), ("restore", "HEAL"),
                         ("summon", "SUMMON"), ("destroy", "DESTROY"), ("gain", "BUFF"),
                         ("give", "GIVE_KEYWORD")):
            if word in clause:
                return op
    if "instead" in text:
        return ""   # IR v2 replacement; free-form
    if "for each" in text:
        return ""   # IR v2 count selector; free-form
    if "manathirst" in text:
        return ""   # two-clause condition; free-form
    if any(marker in text for marker in ("whenever ", "at the end of", "at the start of", "spellburst")):
        return "TRIGGER"
    if text.startswith("after ") or re.match(r"^[a-z ,]+ \. after ", text):
        return "TRIGGER"
    if "choose 1" in text or "choose one" in text:
        return ""   # card-level choices use the free-form path
    if row.get("secret") or "secret:" in text:
        return ""   # secrets are free-form
    if any(marker in text for marker in ("overload", "tradeable", "finale", "prepare", "reborn")):
        return ""   # card attributes are free-form
    if " have " in text:
        return "AURA"
    if "CARD_COST" in hints:
        if "reduce the cost" in text or ("next " in text and "cost" in text):
            return "COST_REDUCE"
        return "COST_AURA"
    if "ADD_TO_HAND" in hints and row.get("tokenHints"):
        return "ADD_TO_HAND"
    if "SUMMON" in hints and "from your deck" in text:
        return "SUMMON_FROM_DECK"
    if "SUMMON" in hints and row.get("tokenHints"):
        return "SUMMON"
    if "EQUIP" in hints:
        return "EQUIP"
    if "DISCOVER" in hints:
        return "DISCOVER"
    for op in ("SHUFFLE", "TRANSFORM", "COPY"):
        if op in hints:
            return op
    for op in ("DAMAGE", "HEAL", "DRAW", "DESTROY"):
        if op in hints:
            return op
    if "GAIN_ARMOR" in hints and "armor" in text:
        return "GAIN_ARMOR"
    if "GIVE_KEYWORD" in hints and any(word in text for word in KEYWORD_WORDS):
        return "GIVE_KEYWORD"
    if "SET_HEALTH" in hints and "health" in text and "stats" not in text:
        return "SET_HEALTH"
    if "SET_ATTACK" in hints and "attack" in text and "stats" not in text:
        return "SET_ATTACK"
    if "SET_STATS" in hints:
        return "SET_STATS"
    if "SWAP_STATS" in hints:
        return "SWAP_STATS"
    if "BUFF" in hints:
        return "BUFF"
    return ""


def family_trigger(row: dict, args: dict) -> str:
    trigger = str(args.get("trigger") or "")
    lowered = (row.get("text") or "").lower()
    if trigger not in {"BATTLECRY", "DEATHRATTLE", "ON_PLAY"}:
        trigger = ""
    if ("outcast" in lowered or "combo" in lowered) and trigger in ("", "BATTLECRY", "ON_PLAY"):
        trigger = "BATTLECRY" if row.get("type") == "MINION" else "ON_PLAY"
    if trigger == "BATTLECRY" and "battlecry" not in lowered:
        trigger = "DEATHRATTLE" if "deathrattle" in lowered else "ON_PLAY"
    elif trigger == "DEATHRATTLE" and "deathrattle" not in lowered:
        trigger = "BATTLECRY" if "battlecry" in lowered else "ON_PLAY"
    elif not trigger:
        if "deathrattle" in lowered:
            trigger = "DEATHRATTLE"
        elif "battlecry" in lowered:
            trigger = "BATTLECRY"
        else:
            trigger = "ON_PLAY"
    return trigger


def family_target(args: dict) -> dict:
    kind = str(args.get("target_kind") or "")
    side = str(args.get("target_side") or "")
    kind = KIND_ALIASES.get(kind, kind)
    side = SIDE_ALIASES.get(side, side)
    if kind not in {"CHOOSE", "ALL", "RANDOM", "SELF", "ADJACENT", "TRIGGER_SOURCE",
                    "PREVIOUS", "LOWEST_HEALTH", "HIGHEST_ATTACK"}:
        return {}
    if side not in {"ANY_CHARACTER", "ANY_MINION", "ANY_OTHER_CHARACTER", "ANY_OTHER_MINION",
                    "ENEMY_CHARACTER", "ENEMY_MINION", "ENEMY_MINIONS", "FRIENDLY_CHARACTER",
                    "FRIENDLY_MINION", "FRIENDLY_MINIONS", "YOUR_HERO", "ENEMY_HERO",
                    "FRIENDLY_HAND_MINIONS", "FRIENDLY_HAND", "YOUR_WEAPON"}:
        return {}
    return {"kind": kind, "side": side}


def follow_up_properties(row: dict, vocab: dict) -> dict:
    ids = [hint["id"] for hint in row.get("tokenHints", [])]
    return {
        "followUpOp": {"type": "string",
                       "enum": ["NONE", "DAMAGE", "DRAW", "HEAL", "GAIN_ARMOR", "SUMMON",
                                "ADD_TO_HAND", "GIVE_KEYWORD", "BUFF"]},
        "followUpCondition": {"type": "string", "enum": ["NONE", "IF_DIES", "IF_SURVIVES"]},
        "followUpAmount": {"type": "integer", "minimum": 0, "maximum": 100},
        "followUpAttack": {"type": "integer", "minimum": 0, "maximum": 20},
        "followUpHealth": {"type": "integer", "minimum": 0, "maximum": 20},
        "followUpToken": {"type": "string", **({"enum": ids} if ids else {})},
        "followUpTokenDisplay": {"type": "string"},
        "followUpKeyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
        "followUpTargetKind": {"type": "string", "enum": vocab["targetKinds"]},
        "followUpTargetSide": {"type": "string", "enum": vocab["targetSides"]},
        "followUpTemporary": {"type": "boolean"},
        "followUpFromDeck": {"type": "boolean"},
    }


def attach_follow_up(effect: dict, args: dict, row: dict, vocab: dict) -> dict:
    op = str(args.get("followUpOp") or "NONE")
    lowered = (row.get("text") or "").lower()
    if op == "NONE":
        # The printed clause is authoritative; infer the common child shapes when the tool call
        # omitted the follow-up fields. The printer proof still decides admission.
        if "if it dies," in lowered or "if it survives," in lowered:
            clause = (lowered.split("if it dies,", 1)[1] if "if it dies," in lowered
                      else lowered.split("if it survives,", 1)[1])
            if "draw" in clause:
                op = "DRAW"
            elif "summon" in clause:
                op = "SUMMON"
            elif clause.strip().startswith("add "):
                op = "ADD_TO_HAND"
            elif "restore" in clause:
                op = "HEAL"
            elif "gain" in clause and "armor" in clause:
                op = "GAIN_ARMOR"
            elif "deal" in clause:
                op = "DAMAGE"
            elif "give" in clause:
                op = "BUFF" if re.search(r"\+\d", clause) else "GIVE_KEYWORD"
        if op == "NONE":
            return effect
    clause = ""
    if "if it dies," in lowered:
        clause = lowered.split("if it dies,", 1)[1]
    elif "if it survives," in lowered:
        clause = lowered.split("if it survives,", 1)[1]
    child = {"trigger": effect.get("trigger", "ON_PLAY"), "op": op}
    if op in ("DAMAGE", "HEAL", "DRAW", "GAIN_ARMOR"):
        amount = int(args.get("followUpAmount", 0))
        if op == "DRAW" and not amount:
            match = re.search(r"draw (\d+)", clause)
            amount = int(match.group(1)) if match else 1
        elif op == "HEAL" and not amount:
            match = re.search(r"restore (\d+)", clause)
            amount = int(match.group(1)) if match else 0
        elif op == "DAMAGE" and not amount:
            match = re.search(r"deal \$?(\d+)", clause)
            amount = int(match.group(1)) if match else 0
        elif op == "GAIN_ARMOR" and not amount:
            match = re.search(r"gain (\d+) armor", clause)
            amount = int(match.group(1)) if match else 0
        child["amount"] = amount
        if op in ("DAMAGE", "HEAL"):
            child["spell"] = "$" in clause or "$" in lowered
    elif op == "SUMMON":
        token = str(args.get("followUpToken") or "")
        if not token:
            hint = pick_choice_token(clause, row.get("tokenHints") or [])
            if hint is None and "another" in clause and effect.get("token"):
                token = effect["token"]
            elif hint is not None:
                token = hint["id"]
        if token:
            child["token"] = token
        display = str(args.get("followUpTokenDisplay") or "").strip()
        if not display:
            display = token_display_from_text(clause)
            if not display and "another" in clause:
                display = effect.get("tokenDisplay", "")
        if display:
            child["tokenDisplay"] = display
        keyword = str(args.get("followUpKeyword") or "").strip().lower().replace(" ", "_")
        if not keyword:
            keyword = keyword_from_text(clause)
        if not keyword:
            for candidate in ("taunt", "rush", "charge", "windfury", "lifesteal", "poisonous",
                              "divine_shield", "freeze"):
                spoken = candidate.replace("_", " ")
                if spoken in clause or (candidate == "freeze" and "freezes" in clause):
                    keyword = candidate
                    break
        if keyword:
            child["keyword"] = keyword
        if args.get("followUpFromDeck"):
            child["fromDeck"] = True
    elif op == "ADD_TO_HAND":
        token = str(args.get("followUpToken") or "")
        if not token:
            hint = pick_choice_token(clause, row.get("tokenHints") or [])
            if hint is not None:
                token = hint["id"]
        if token:
            child["token"] = token
        display = str(args.get("followUpTokenDisplay") or "").strip()
        if not display:
            display = token_display_from_text(clause)
        if display:
            child["tokenDisplay"] = display
    elif op == "GIVE_KEYWORD":
        keyword = str(args.get("followUpKeyword") or "").strip().lower().replace(" ", "_")
        if not keyword:
            keyword = keyword_from_text(clause)
        if keyword:
            child["keyword"] = keyword
    elif op == "BUFF":
        child["amount"] = int(args.get("followUpAttack", 0))
        child["amount2"] = int(args.get("followUpHealth", 0))
        stats = re.search(r"\+(\d+)(?:/\+(\d+))?", clause)
        if stats and not (child["amount"] or child["amount2"]):
            child["amount"] = int(stats.group(1))
            child["amount2"] = int(stats.group(2)) if stats.group(2) else 0
        keyword = str(args.get("followUpKeyword") or "").strip().lower().replace(" ", "_")
        if keyword:
            child["keyword"] = keyword
        if args.get("followUpTemporary") or "this turn" in clause:
            child["temporary"] = True
    kind = str(args.get("followUpTargetKind") or "")
    side = str(args.get("followUpTargetSide") or "")
    if kind and side:
        child["target"] = {"kind": kind, "side": side}
    elif "enemy hero" in clause:
        child["target"] = {"kind": "SELF", "side": "ENEMY_HERO"}
    elif "your hero" in clause:
        child["target"] = {"kind": "SELF", "side": "YOUR_HERO"}
    elif "random minion you control" in clause:
        child["target"] = {"kind": "RANDOM", "side": "FRIENDLY_MINION"}
    elif "give it" in clause or ("restore" in clause and " it" in clause):
        child["target"] = {"kind": "PREVIOUS", "side": "ANY_CHARACTER"}
    condition = str(args.get("followUpCondition") or "NONE")
    if condition == "NONE":
        if "if it dies" in lowered:
            condition = "IF_DIES"
        elif "if it survives" in lowered:
            condition = "IF_SURVIVES"
    effect["followUp"] = [child]
    effect["followUpCondition"] = condition
    return effect


def then_properties(vocab: dict) -> dict:
    return {
        "thenOp": {"type": "string",
                   "enum": ["NONE", "BUFF", "GIVE_KEYWORD", "DAMAGE", "HEAL", "DRAW"]},
        "thenAttack": {"type": "integer", "minimum": 0, "maximum": 20},
        "thenHealth": {"type": "integer", "minimum": 0, "maximum": 20},
        "thenAmount": {"type": "integer", "minimum": 0, "maximum": 100},
        "thenKeyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
    }


def build_then_effect(effect: dict, args: dict, row: dict, vocab: dict) -> dict | None:
    op = str(args.get("thenOp") or "NONE")
    lowered = (row.get("text") or "").lower()
    if op == "NONE":
        if "discover" in lowered and "give it +" in lowered:
            op = "BUFF"
        elif "discover" in lowered and "give it " in lowered:
            op = "GIVE_KEYWORD"
        else:
            return None
    child = {"trigger": effect.get("trigger", "ON_PLAY"), "op": op}
    if op == "BUFF":
        attack = int(args.get("thenAttack", 0))
        health = int(args.get("thenHealth", 0))
        if not (attack or health):
            match = re.search(r"give it \+(\d+)(?:/\+(\d+))?", lowered)
            if match:
                attack = int(match.group(1))
                health = int(match.group(2)) if match.group(2) else 0
        child["amount"] = attack
        child["amount2"] = health
        keyword = str(args.get("thenKeyword") or "").strip().lower().replace(" ", "_")
        if keyword:
            child["keyword"] = keyword
        child["target"] = {"kind": "PREVIOUS", "side": "ANY_CHARACTER"}
    elif op == "GIVE_KEYWORD":
        keyword = str(args.get("thenKeyword") or "").strip().lower().replace(" ", "_")
        if not keyword:
            keyword = keyword_from_text(lowered)
        if keyword:
            child["keyword"] = keyword
        child["target"] = {"kind": "PREVIOUS", "side": "ANY_CHARACTER"}
    elif op in ("DAMAGE", "HEAL", "DRAW"):
        child["amount"] = int(args.get("thenAmount", 0))
        if op in ("DAMAGE", "HEAL"):
            child["spell"] = "$" in lowered
    return child


def build_family_tool(row: dict, op: str, vocab: dict) -> dict:
    if op in TOKEN_TOOL_OPS:
        return build_token_tool(row, op, vocab)
    if op == "TRIGGER":
        ids = [hint["id"] for hint in row.get("tokenHints", [])]
        params = {
            "trigger": {"type": "string", "enum": [
                "START_TURN", "END_TURN", "AFTER_CAST_SPELL", "AFTER_FRIENDLY_MINION_DIES",
                "AFTER_PLAY_MINION", "AFTER_SUMMON_MINION", "AFTER_PLAY_CARD",
                "AFTER_OPPONENT_PLAY_CARD", "WHEN_YOUR_MINION_ATTACKED",
                "WHEN_YOUR_HERO_ATTACKED", "WHEN_ENEMY_MINION_ATTACKS", "AFTER_HERO_ATTACK",
                "SPELLBURST"]},
            "op": {"type": "string", "enum": ["DAMAGE", "DRAW", "SUMMON", "BUFF",
                                               "GIVE_KEYWORD", "DESTROY", "HEAL",
                                               "ADD_TO_HAND", "GAIN_ARMOR", "SILENCE"]},
            "amount": {"type": "integer", "minimum": 0, "maximum": 100},
            "amount2": {"type": "integer", "minimum": 0, "maximum": 100},
            "token": {"type": "string", **({"enum": ids} if ids else {})},
            "token_display": {"type": "string"},
            "keyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "target_kind": {"type": "string", "enum": vocab["targetKinds"]},
            "target_side": {"type": "string", "enum": vocab["targetSides"]},
            "durationTurns": {"type": "integer", "minimum": 0, "maximum": 10},
        }
        return {"type": "function", "function": {
            "name": "author_trigger",
            "description": "Author one event-triggered ability (at end/start of turn, whenever...).",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params, "required": ["trigger", "op"]},
        }}
    if op == "SECRET":
        ids = [hint["id"] for hint in row.get("tokenHints", [])]
        params = {
            "trigger": {"type": "string", "enum": [
                "AFTER_OPPONENT_PLAY_CARD", "AFTER_OPPONENT_CAST_SPELL",
                "WHEN_YOUR_MINION_ATTACKED", "WHEN_YOUR_HERO_ATTACKED",
                "WHEN_ENEMY_MINION_ATTACKS", "AFTER_FRIENDLY_MINION_DIES",
                "AFTER_HERO_POWER", "AFTER_SELF_ATTACK"]},
            "subject_type": {"type": "integer", "enum": [0, 1],
                             "description": "1 when the text says the opponent plays a minion."},
            "op": {"type": "string", "enum": ["DAMAGE", "DRAW", "SUMMON", "BUFF",
                                               "GIVE_KEYWORD", "DESTROY", "SET_STATS",
                                               "SET_HEALTH"]},
            "amount": {"type": "integer", "minimum": 0, "maximum": 100},
            "amount2": {"type": "integer", "minimum": 0, "maximum": 100},
            "token": {"type": "string", **({"enum": ids} if ids else {})},
            "token_display": {"type": "string"},
            "keyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "target_kind": {"type": "string", "enum": vocab["targetKinds"]},
            "target_side": {"type": "string", "enum": vocab["targetSides"]},
        }
        return {"type": "function", "function": {
            "name": "author_secret",
            "description": "Author one Secret: the event trigger and the effect.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params,
                           "required": ["trigger", "op"]},
        }}
    if op == "COST_REDUCE":
        params = {
            "amount": {"type": "integer", "minimum": -10, "maximum": 10},
            "amount2": {"type": "integer", "enum": [0, 4]},
            "type_filter": {"type": "integer", "minimum": 0, "maximum": 4},
            "keyword_filter": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "race_filter": {"type": "string", "enum": [""] + list(vocab["races"])},
            "school_filter": {"type": "integer", "minimum": 0, "maximum": 7},
        }
        return {"type": "function", "function": {
            "name": "author_cost_reduce",
            "description": "Reduce the cost of the hand/next card(s).",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params, "required": ["amount", "amount2"]},
        }}
    if op == "COST_AURA":
        params = {
            "amount": {"type": "integer", "minimum": -10, "maximum": 10,
                       "description": "Negative for 'less', positive for 'more'."},
            "type_filter": {"type": "integer", "minimum": 0, "maximum": 4,
                            "description": "1 minion, 2 spell, 3 weapon; 0 any."},
            "keyword_filter": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "race_filter": {"type": "string", "enum": [""] + list(vocab["races"])},
            "school_filter": {"type": "integer", "minimum": 0, "maximum": 7},
            "other_class": {"type": "boolean"},
            "target_side": {"type": "string",
                            "enum": ["YOUR_HERO", "ENEMY_HERO", "ANY_CHARACTER"]},
        }
        return {"type": "function", "function": {
            "name": "author_cost_aura",
            "description": "Author a persistent cost modifier for your cards.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params, "required": ["amount"]},
        }}
    if op == "AURA":
        params = {
            "target_kind": {"type": "string", "enum": ["ALL", "ADJACENT"]},
            "target_side": {"type": "string",
                            "enum": ["FRIENDLY_MINIONS", "ENEMY_MINIONS", "ANY_MINION"]},
            "race_filter": {"type": "string", "enum": [""] + list(vocab["races"])},
            "exclude_source": {"type": "boolean"},
            "keyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "attack": {"type": "integer", "minimum": 0, "maximum": 10, "default": 0,
                       "description": "Attack change; 0 for a keyword-only aura."},
            "health": {"type": "integer", "minimum": 0, "maximum": 10, "default": 0,
                       "description": "Health change; 0 for an attack-only or keyword aura."},
            "token_display": {"type": "string",
                              "description": "For a named minion type, the printed name; omit otherwise."},
        }
        return {"type": "function", "function": {
            "name": "author_aura",
            "description": "Author one passive AURA: your/all/adjacent minions have stats or a keyword.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params,
                           "required": ["target_kind", "target_side", "keyword"]},
        }}
    if op == "SHUFFLE":
        ids = [hint["id"] for hint in row.get("tokenHints", [])]
        params = {
            "token": {"type": "string", **({"enum": ids} if ids else {})},
            "repeat": {"type": "integer", "enum": list(range(1, 11))},
            "target_side": {"type": "string", "enum": ["YOUR_HERO", "ENEMY_HERO"]},
            "trigger": {"type": "string", "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"]},
        }
        params.update(condition_properties(vocab))
        return {"type": "function", "function": {
            "name": "author_shuffle",
            "description": "Shuffle copies of the named token into a deck.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params,
                           "required": ["token", "repeat", "target_side", "trigger"]},
        }}
    if op == "TRANSFORM":
        ids = [hint["id"] for hint in row.get("tokenHints", [])]
        params = {
            "token": {"type": "string", **({"enum": ids} if ids else {})},
            "keyword": {"type": "string", "enum": [""] + list(vocab["keywords"])},
            "target_kind": {"type": "string", "enum": vocab["targetKinds"]},
            "target_side": {"type": "string", "enum": vocab["targetSides"]},
            "trigger": {"type": "string", "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"]},
        }
        params.update(condition_properties(vocab))
        return {"type": "function", "function": {
            "name": "author_transform",
            "description": "Transform a minion into a token, optionally with a keyword.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params,
                           "required": ["token", "keyword", "target_kind", "target_side", "trigger"]},
        }}
    if op == "COPY":
        params = {
            "target_kind": {"type": "string", "enum": vocab["targetKinds"]},
            "target_side": {"type": "string", "enum": vocab["targetSides"]},
            "trigger": {"type": "string", "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"]},
        }
        params.update(condition_properties(vocab))
        return {"type": "function", "function": {
            "name": "author_copy",
            "description": "Copy a target.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params,
                           "required": ["target_kind", "target_side", "trigger"]},
        }}
    if op == "EQUIP":
        ids = [hint["id"] for hint in row.get("tokenHints", []) if hint.get("type") == "WEAPON"]
        params = {
            "token": {"type": "string", **({"enum": ids} if ids else {}),
                      "description": "The weapon token id from the hints."},
            "trigger": {"type": "string", "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"]},
        }
        params.update(condition_properties(vocab))
        return {"type": "function", "function": {
            "name": "author_equip",
            "description": "Author one EQUIP effect. Use the weapon hint whose stats match the text.",
            "parameters": {"type": "object", "additionalProperties": False,
                           "properties": params, "required": ["token", "trigger"]},
        }}
    properties: dict = {
        "trigger": {"type": "string",
                    "enum": ["BATTLECRY", "DEATHRATTLE", "ON_PLAY"],
                    "description": "The printed trigger prefix."},
    }
    required = ["trigger"]
    if op in NUMERIC_OPS:
        properties["amount"] = {"type": "integer", "minimum": 0, "maximum": 20,
                                "description": "The number the text prints."}
        required.append("amount")
    if op in {"DAMAGE", "HEAL"}:
        properties["spell"] = {"type": "boolean",
                               "description": "True when the text prints $N (spell damage applies)."}
        required.append("spell")
    if op in {"BUFF"}:
        properties["attack"] = {"type": "integer", "minimum": -5, "maximum": 20,
                                "description": "The attack change, e.g. +2 -> 2."}
        properties["health"] = {"type": "integer", "minimum": -5, "maximum": 20,
                                "description": "The health change, e.g. +3 -> 3."}
        required.extend(["attack", "health"])
    if op == "SET_STATS":
        properties["attack"] = {"type": "integer", "minimum": 0, "maximum": 20}
        properties["health"] = {"type": "integer", "minimum": 0, "maximum": 20}
        required.extend(["attack", "health"])
    if op in ("SET_ATTACK", "SET_HEALTH"):
        properties["amount"] = {"type": "integer", "minimum": 0, "maximum": 100}
        required.append("amount")
    if op in {"BUFF", "GIVE_KEYWORD"}:
        properties["keyword"] = {"type": "string",
                                 "enum": [""] + list(vocab["keywords"]),
                                 "description": "The printed keyword, or empty."}
        if op == "GIVE_KEYWORD":
            required.append("keyword")
    if op == "SUMMON_FROM_DECK":
        properties["repeat"] = {"type": "integer", "enum": list(range(1, 11)),
                                "description": "How many minions to summon."}
        required.append("repeat")
    elif op in {"DAMAGE", "HEAL", "BUFF"}:
        properties["repeat"] = {"type": "integer", "enum": [1, 2, 3, 4, 5],
                                "description": "How many times the effect applies."}
        required.append("repeat")
    if op in TARGET_OPS:
        properties["target_kind"] = {"type": "string", "enum": vocab["targetKinds"],
                                     "description": "CHOOSE for a chosen target, ALL for all/each, RANDOM for random, SELF for a self-buff."}
        properties["target_side"] = {"type": "string", "enum": vocab["targetSides"],
                                     "description": "Whose target: ANY_MINION, ENEMY_MINION, YOUR_HERO, ..."}
        required.extend(["target_kind", "target_side"])
    properties.update(condition_properties(vocab))
    properties.update(filter_properties(vocab))
    properties.update(follow_up_properties(row, vocab))
    properties.update(then_properties(vocab))
    return {"type": "function", "function": {
        "name": "author_" + op.lower(),
        "description": f"Author one {op} effect for this card, exactly once. Use only the printed text.",
        "parameters": {"type": "object", "additionalProperties": False,
                       "properties": properties, "required": required},
    }}


def build_family_messages(row: dict, op: str, tool: dict, feedback: str = "") -> list[dict]:
    if op in TOKEN_TOOL_OPS:
        return build_tool_messages(row, op, tool, feedback)
    system = (
        "You author exactly one card program by calling the tool. "
        f"Call author_{op.lower()} exactly once. "
        "Use only what the card text says. For a spell or a card with no Battlecry/Deathrattle "
        "prefix, trigger is ON_PLAY. target_kind is CHOOSE for 'a minion', ALL for 'all/each', "
        "RANDOM for 'random', SELF for a self-directed effect. target_side names whose. "
        "spell is true only when the text prints $N. If the text starts with Outcast: or Combo:, set "
        "condition OUTCAST or COMBO; a minion uses trigger BATTLECRY and a spell uses ON_PLAY. If it "
        "starts Battlecry: If ..., set the condition and its argument. If the text qualifies the "
        "pool or target ('deathrattle minions', 'a spell', 'a Beast', 'a damaged minion'), set "
        "type_filter (1 minion, 2 spell), keyword_filter, race_filter, cost_min/cost_max, "
        "damaged_only, exclude_source, and from_deck when the text says 'from your deck'. Do not "
        "invent an amount or a keyword."
    )
    user = (
        f"card_id: {row['id']}\n"
        f"name: {row['name']}\n"
        f"type: {row['type']}\n"
        f"text: {row['text']}\n"
        f"compiler refusal: {row.get('refusal', '')}\n"
        f"likely op: {op}\n"
    )
    if feedback:
        user += "\nYour previous attempt was rejected. Fix it.\n" + feedback + "\n"
    return [{"role": "system", "content": system}, {"role": "user", "content": user}]


def assemble_family_program(row: dict, op: str, args: dict, vocab: dict) -> dict:
    if op in TOKEN_TOOL_OPS:
        program = assemble_token_program(row, op, args)
        program["effects"][0] = attach_follow_up(program["effects"][0], args, row, vocab)
        return program
    lowered = (row.get("text") or "").lower()

    if op == "TRIGGER":
        trigger = str(args.get("trigger") or "")
        if "at the end of" in lowered:
            trigger = "END_TURN"
        elif "at the start of" in lowered:
            trigger = "START_TURN"
        elif "spellburst" in lowered:
            trigger = "SPELLBURST"
        elif "whenever you cast a spell" in lowered:
            trigger = "AFTER_CAST_SPELL"
        elif "whenever a minion you control dies" in lowered or "whenever a friendly minion dies" in lowered:
            trigger = "AFTER_FRIENDLY_MINION_DIES"
        elif "after your opponent casts" in lowered:
            trigger = "AFTER_OPPONENT_CAST_SPELL"
        elif "after your opponent plays" in lowered:
            trigger = "AFTER_OPPONENT_PLAY_CARD"
        elif "after your hero attacks" in lowered:
            trigger = "AFTER_HERO_ATTACK"
        elif "after you summon" in lowered:
            trigger = "AFTER_SUMMON_MINION"
        elif "after you play" in lowered:
            trigger = "AFTER_PLAY_CARD"
        elif "after you cast" in lowered:
            trigger = "AFTER_CAST_SPELL"
        elif "after you draw" in lowered:
            trigger = "AFTER_DRAW"
        elif "after this attacks" in lowered:
            trigger = "AFTER_SELF_ATTACK"
        op = str(args.get("op") or "DAMAGE")
        if "silence it" in lowered:
            op = "SILENCE"
        if "add a card from another class" in lowered:
            op = "ADD_TO_HAND"
        effect = {"trigger": trigger or "END_TURN", "op": op}
        if op in ("DAMAGE", "DRAW", "HEAL", "GAIN_ARMOR"):
            effect["amount"] = int(args.get("amount", 0))
        if op == "DAMAGE":
            effect["spell"] = "$" in lowered
        if op == "ADD_TO_HAND" and "another class" in lowered:
            effect["otherClass"] = True
        if op in ("SUMMON", "ADD_TO_HAND"):
            token = str(args.get("token") or "")
            if not token:
                hint = pick_choice_token(lowered, row.get("tokenHints") or [])
                if hint is not None:
                    token = hint["id"]
                elif "another" in lowered:
                    token = row["id"]
                elif effect.get("token"):
                    token = effect["token"]
            if token:
                effect["token"] = token
            display = str(args.get("token_display") or "").strip()
            if not display:
                display = token_display_from_text(lowered)
            if not display and "another" in lowered:
                named = re.search(r"summon another ([a-z0-9' ]+)", lowered)
                if named:
                    display = "another " + named.group(1).strip()
            if display:
                effect["tokenDisplay"] = display
        if op in ("BUFF", "GIVE_KEYWORD"):
            keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
            if keyword:
                effect["keyword"] = keyword
            if op == "BUFF":
                amount = int(args.get("amount", 0))
                amount2 = int(args.get("amount2", 0))
                stats = re.search(r"\+(\d+)/\+(\d+)", lowered)
                if stats:
                    amount, amount2 = int(stats.group(1)), int(stats.group(2))
                if not amount:
                    match = re.search(r"\+(\d+) attack", lowered)
                    if match:
                        amount = int(match.group(1))
                if not amount2:
                    match = re.search(r"\+(\d+) health", lowered)
                    if match:
                        amount2 = int(match.group(1))
                effect["amount"] = amount
                effect["amount2"] = amount2
        kind = str(args.get("target_kind") or "")
        side = str(args.get("target_side") or "")
        if "give this minion" in lowered:
            effect["target"] = {"kind": "SELF", "side": "FRIENDLY_MINION"}
        elif "silence it" in lowered:
            effect["target"] = {"kind": "TRIGGER_SOURCE", "side": "ANY_CHARACTER"}
        elif "give it" in lowered or ("restore" in lowered and " to it" in lowered):
            effect["target"] = {"kind": "TRIGGER_SOURCE", "side": "ANY_CHARACTER"}
        elif kind and side:
            effect["target"] = {"kind": kind, "side": side}
        elif op in ("DAMAGE", "DESTROY", "GIVE_KEYWORD", "BUFF"):
            effect["target"] = {"kind": "RANDOM", "side": "ENEMY_CHARACTER"}
        if "add a card from another class" in lowered:
            effect.pop("token", None)
            effect.pop("tokenDisplay", None)
            effect["otherClass"] = True
        duration = int(args.get("durationTurns", 0))
        if duration > 0:
            effect["durationTurns"] = duration
        return {"implemented": True, "effects": [effect]}
    if op == "SECRET":
        secret_op = str(args.get("op") or "DAMAGE")
        effect = {"trigger": str(args.get("trigger") or "AFTER_OPPONENT_PLAY_CARD"),
                  "op": secret_op}
        subject_type = int(args.get("subject_type", 0))
        if subject_type:
            effect["subjectType"] = subject_type
        if secret_op in ("DAMAGE", "DRAW", "SET_STATS", "SET_HEALTH"):
            effect["amount"] = int(args.get("amount", 0))
        if secret_op == "SET_STATS":
            amount = int(args.get("amount", 0))
            amount2 = int(args.get("amount2", 0))
            if amount == 0 and amount2 == 0:
                match = re.search(r"stats to (\d+)", lowered)
                if match:
                    amount = amount2 = int(match.group(1))
            effect["amount"] = amount
            effect["amount2"] = amount2
        if secret_op == "DAMAGE":
            effect["spell"] = "$" in lowered
        if secret_op in ("SUMMON", "ADD_TO_HAND"):
            token = str(args.get("token") or "")
            if not token:
                hint = pick_choice_token(lowered, row.get("tokenHints") or [])
                if hint is not None:
                    token = hint["id"]
                elif "another" in lowered:
                    token = row["id"]
            if token:
                effect["token"] = token
            display = str(args.get("token_display") or "").strip()
            if not display:
                display = token_display_from_text(lowered)
            if not display and "another" in lowered:
                named = re.search(r"summon another ([a-z0-9' ]+)", lowered)
                if named:
                    display = "another " + named.group(1).strip()
            if display:
                effect["tokenDisplay"] = display
            keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
            if not keyword:
                keyword = keyword_from_text(lowered)
            if keyword:
                effect["keyword"] = keyword
        if secret_op in ("BUFF", "GIVE_KEYWORD"):
            keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
            if keyword:
                effect["keyword"] = keyword
            if secret_op == "BUFF":
                amount = int(args.get("amount", 0))
                amount2 = int(args.get("amount2", 0))
                stats = re.search(r"\+(\d+)/\+(\d+)", lowered)
                if stats:
                    amount, amount2 = int(stats.group(1)), int(stats.group(2))
                effect["amount"] = amount
                effect["amount2"] = amount2
        kind = str(args.get("target_kind") or "")
        side = str(args.get("target_side") or "")
        if "random enemy" in lowered:
            effect["target"] = {"kind": "RANDOM", "side": "ENEMY_CHARACTER"}
        elif "random minion you control" in lowered:
            effect["target"] = {"kind": "RANDOM", "side": "FRIENDLY_MINION"}
        elif "its stats" in lowered or "its health" in lowered or "to it" in lowered:
            effect["target"] = {"kind": "TRIGGER_SOURCE", "side": "ANY_CHARACTER"}
        elif kind and side:
            effect["target"] = {"kind": kind, "side": side}
        elif secret_op in ("DAMAGE", "SET_STATS", "SET_HEALTH", "DESTROY", "GIVE_KEYWORD",
                           "BUFF"):
            effect["target"] = {"kind": "TRIGGER_SOURCE", "side": "ANY_CHARACTER"}
        return {"implemented": True, "secret": True, "effects": [effect]}

    if op == "COST_REDUCE":
        amount = int(args.get("amount", 0))
        amount = -abs(amount) if ("reduce" in lowered or "less" in lowered) else abs(amount)
        amount2 = int(args.get("amount2", 4))
        if "in your hand" in lowered or "in hand" in lowered:
            amount2 = 4
        elif "next " in lowered:
            amount2 = 0
        effect = {"trigger": family_trigger(row, args), "op": "CARD_COST",
                  "amount": amount, "amount2": amount2,
                  "target": {"kind": "SELF", "side": "YOUR_HERO"}}
        apply_filters(effect, args)
        apply_text_filters(effect, row, vocab)
        return {"implemented": True, "effects": [effect]}
    if op == "COST_AURA":
        amount = int(args.get("amount", 0))
        if "less" in lowered:
            amount = -abs(amount)
        elif "more" in lowered:
            amount = abs(amount)
        side = str(args.get("target_side") or "YOUR_HERO")
        both_players = False
        if "all " in lowered:
            side = "ANY_CHARACTER"
            both_players = True
        elif "opponent" in lowered:
            side = "ENEMY_HERO"
        else:
            side = "YOUR_HERO"
        effect = {"trigger": "AURA", "op": "CARD_COST", "amount": amount, "amount2": 1,
                  "target": {"kind": "SELF", "side": side}}
        if both_players:
            effect["bothPlayers"] = True
        type_filter = 0
        if "spells" in lowered:
            type_filter = 2
        elif "minions" in lowered:
            type_filter = 1
        elif "weapons" in lowered:
            type_filter = 3
        if type_filter:
            effect["type_filter"] = type_filter
        keyword = str(args.get("keyword_filter") or args.get("condition_keyword") or "").strip().lower().replace(" ", "_")
        if not keyword:
            for candidate in vocab["keywords"]:
                spoken = candidate.replace("_", " ")
                if (spoken + " cards") in lowered:
                    keyword = candidate
                    break
        if keyword:
            effect["keywordFilter"] = keyword
        race = str(args.get("race_filter") or args.get("condition_race") or "").strip().lower()
        if not race:
            for candidate in vocab["races"]:
                if (candidate + "s") in lowered:
                    race = candidate
                    break
        if race:
            effect["raceFilter"] = race
        school = int(args.get("school_filter", 0))
        if school:
            effect["schoolFilter"] = school
        if args.get("other_class") or "another class" in lowered:
            effect["otherClass"] = True
        return {"implemented": True, "effects": [effect]}

    if op == "AURA":
        if "adjacent" in lowered:
            target = {"kind": "ADJACENT", "side": "FRIENDLY_MINIONS"}
        elif "all enemy" in lowered:
            target = {"kind": "ALL", "side": "ENEMY_MINIONS"}
        else:
            target = {"kind": "ALL", "side": "FRIENDLY_MINIONS"}
        keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
        if not keyword:
            keyword = keyword_from_text(row["text"])
        attack = max(0, min(10, int(args.get("attack", 0))))
        health = max(0, min(10, int(args.get("health", 0))))
        stats = re.search(r"\+(\d+)(?:\s*/\s*\+(\d+))?", lowered)
        if stats:
            first = int(stats.group(1))
            second = int(stats.group(2)) if stats.group(2) else 0
            if "health" in lowered and "attack" not in lowered:
                attack, health = 0, first
            else:
                attack, health = first, second
        elif keyword:
            attack, health = 0, 0
        token_display = str(args.get("token_display") or "").strip()
        effect = {"trigger": "AURA"}
        if token_display:
            effect.update({"op": "BUFF_NAMED", "tokenDisplay": token_display,
                           "amount": attack, "amount2": health})
        elif keyword and attack == 0 and health == 0:
            effect.update({"op": "GIVE_KEYWORD", "keyword": keyword})
        else:
            effect.update({"op": "BUFF", "amount": attack, "amount2": health})
            if keyword:
                effect["keyword"] = keyword
        effect["target"] = target
        if "other" in lowered:
            effect["excludeSource"] = True
        race = str(args.get("race_filter") or "").strip().lower()
        if not race:
            for candidate in vocab["races"]:
                if (candidate + "s") in lowered or (candidate + " minion") in lowered:
                    race = candidate
                    break
        if race:
            effect["raceFilter"] = race
        effect["type_filter"] = 1
        apply_condition(effect, args)
        return {"implemented": True, "effects": [effect]}

    if op == "DISCOVER":
        effect = {"trigger": family_trigger(row, args), "op": "DISCOVER", "amount": 3}
        apply_condition(effect, args)
        apply_filters(effect, args)
        apply_text_filters(effect, row, vocab)
        then = build_then_effect(effect, args, row, vocab)
        return {"implemented": True, "effects": [effect] + ([then] if then else [])}

    if op == "SHUFFLE":
        token = str(args.get("token") or "")
        if not token:
            raise ValueError("the tool call did not name a token")
        side = str(args.get("target_side") or "YOUR_HERO")
        effect = {"trigger": family_trigger(row, args), "op": "SHUFFLE", "token": token,
                  "repeat": max(1, min(10, int(args.get("repeat", 1)))),
                  "target": {"kind": "ALL", "side": side}}
        apply_condition(effect, args)
        return {"implemented": True, "effects": [effect]}

    if op == "TRANSFORM":
        token = str(args.get("token") or "")
        if not token:
            raise ValueError("the tool call did not name a token")
        effect = {"trigger": family_trigger(row, args), "op": "TRANSFORM", "token": token}
        keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
        if keyword:
            effect["keyword"] = keyword
        display = token_display_from_text(row["text"])
        if display:
            effect["tokenDisplay"] = display
        target = family_target(args)
        if target:
            effect["target"] = target
        apply_condition(effect, args)
        return {"implemented": True, "effects": [effect]}

    if op == "COPY":
        effect = {"trigger": family_trigger(row, args), "op": "COPY"}
        target = family_target(args)
        if target:
            effect["target"] = target
        apply_condition(effect, args)
        return {"implemented": True, "effects": [effect]}

    if op == "EQUIP":
        token = str(args.get("token") or "")
        if not token:
            raise ValueError("the tool call did not name a weapon token")
        effect = {"trigger": family_trigger(row, args), "op": "EQUIP", "token": token}
        display = token_display_from_text(row["text"])
        if display:
            effect["tokenDisplay"] = display
        apply_condition(effect, args)
        return {"implemented": True, "effects": [effect]}

    effect = {"trigger": family_trigger(row, args), "op": op}
    if op in NUMERIC_OPS:
        effect["amount"] = int(args.get("amount", 0))
    if op in {"DAMAGE", "HEAL"}:
        effect["spell"] = bool(args.get("spell", False)) or "$" in lowered
    if op == "SUMMON_FROM_DECK":
        effect["repeat"] = max(1, min(10, int(args.get("repeat", 1))))
    elif op in {"DAMAGE", "HEAL", "BUFF"}:
        effect["repeat"] = max(1, min(5, int(args.get("repeat", 1))))
    if op == "BUFF":
        effect["amount"] = int(args.get("attack", 0))
        effect["amount2"] = int(args.get("health", 0))
    if op == "SET_STATS":
        effect["amount"] = int(args.get("attack", 0))
        effect["amount2"] = int(args.get("health", 0))
    if op in ("SET_ATTACK", "SET_HEALTH", "SET_STATS"):
        effect["setVerb"] = True
    if op in {"BUFF", "GIVE_KEYWORD"}:
        keyword = str(args.get("keyword") or "").strip().lower().replace(" ", "_")
        if keyword:
            effect["keyword"] = keyword
    if op in TARGET_OPS:
        target = family_target(args)
        if target:
            side = str(target.get("side") or "")
            if (side.startswith("FRIENDLY") or side.startswith("ENEMY")) and not any(
                    word in lowered for word in ("friendly", "your", "enemy", "opponent")):
                target["side"] = "ANY_MINION" if "minion" in lowered else "ANY_CHARACTER"
            if target.get("kind") == "ALL" and "a minion" in lowered and \
                    "all " not in lowered and "each " not in lowered:
                target["kind"] = "CHOOSE"
            effect["target"] = target
    apply_condition(effect, args)
    apply_filters(effect, args)
    apply_text_filters(effect, row, vocab)
    if op in ("BUFF", "GIVE_KEYWORD"):
        if "other" in lowered:
            effect["excludeSource"] = True
        if "mechs" in lowered:
            effect["raceFilter"] = "mechanical"
        if op == "GIVE_KEYWORD" and not effect.get("keyword"):
            keyword = keyword_from_text(row["text"])
            if keyword:
                effect["keyword"] = keyword
    attach_follow_up(effect, args, row, vocab)
    return {"implemented": True, "effects": [effect]}


def verify(candidates: Path, out_dir: Path) -> list[dict]:
    result = subprocess.run(
        [str(SIM), "author-verify", "--data", str(ROOT / "data"),
         "--candidates", str(candidates), "--out", str(out_dir), "--json"],
        cwd=ROOT, text=True, capture_output=True,
    )
    report_path = out_dir / "report.json"
    if report_path.exists():
        return json.loads(report_path.read_text())
    raise RuntimeError(f"author-verify failed ({result.returncode}): {result.stderr[:400]}")


def review_packet(block: str, rows: list[dict], report: list[dict], manifest: dict) -> str:
    by_id = {row["id"]: row for row in rows}
    lines = [f"# Block {block}", "",
             f"model `{manifest['model']}` ({manifest['modelRoot']}); "
             f"prompt `{manifest['promptVersion'][:12]}` schema `{manifest['schemaVersion'][:12]}`",
             "", "| card | text | program | printed | gates |", "|---|---|---|---|---|"]
    for row in report:
        card = by_id.get(row["id"], {})
        gates = " ".join(name for name in ("keys", "matrix", "evidence", "order", "validate",
                                           "roundtrip") if row.get(name))
        lines.append(
            f"| {row['id']} {card.get('name', '')} | {card.get('text', '')} | "
            f"`{row.get('reason', '') or 'accepted'}` | {row.get('printed', '')} | {gates} |"
        )
    lines += ["", "Sign-off: edit `review.json` (`reviewed: true`, reviewer, date, commit) only "
              "after checking each accepted card against its printed text."]
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "data")
    parser.add_argument("--queue", type=Path, default=ROOT / "data" / "authoring" / "queue.jsonl")
    parser.add_argument("--block", required=True)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--limit", type=int)
    parser.add_argument("--ids", default="")
    parser.add_argument("--max-attempts", type=int, default=3)
    parser.add_argument("--url", default=DEFAULT_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--fake", type=Path, help="canned {card_id: program} map; no HTTP")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-cache", action="store_true")
    parser.add_argument("--no-tool-mode", action="store_true")
    args = parser.parse_args()

    data = args.data if args.data.is_absolute() else ROOT / args.data
    out_dir = args.out or (data / "authoring" / "blocks" / args.block)
    out_dir.mkdir(parents=True, exist_ok=True)
    cache_dir = data / "authoring" / "cache"
    cache_dir.mkdir(parents=True, exist_ok=True)

    vocab = load_json(data / "authoring" / "vocab.json")
    schema = load_json(data / "authoring" / "schema" / "authoring-v0.json")
    keys = load_json(data / "authoring" / "keys.json")
    schema_hash = sha256_text(json.dumps(schema, sort_keys=True))
    catalogue = {card["id"]: card for card in load_json(data / "catalogue.json")["cards"]}
    programs = load_json(data / "programs.json")["programs"]
    queue = [json.loads(line) for line in args.queue.read_text().splitlines() if line.strip()]

    wanted = {card_id.strip() for card_id in args.ids.split(",") if card_id.strip()}
    rows = [row for row in queue if row.get("eligible")]
    if wanted:
        rows = [row for row in rows if row["id"] in wanted]
    if args.limit is not None:
        rows = rows[:args.limit]
    if not rows:
        print("author_llm: no eligible cards selected", file=sys.stderr)
        return 2

    system = SYSTEM + "\nVOCABULARY:\n" + vocabulary_text(vocab)
    prompt_version = sha256_text(system)
    fake = load_json(args.fake) if args.fake else None
    if args.dry_run:
        examples = examples_text(rows[0].get("exampleIds", []), programs, catalogue)
        messages = build_messages(system, examples, rows[0])
        print(json.dumps(messages, indent=2)[:8000])
        return 0

    state = {row["id"]: {"row": row, "attempts": 0, "reason": "", "printed": "", "original": "",
                         "program": None, "last_program": None, "unsupported": False}
             for row in rows}
    raw_path = out_dir / "raw.jsonl"
    raw_path.write_text("")
    candidates_path = out_dir / "candidates.json"

    for attempt in range(1, args.max_attempts + 1):
        active = [item for item in state.values()
                  if not item["unsupported"] and item["program"] is None]
        if not active:
            break
        candidates: dict[str, dict] = {}
        for item in active:
            row = item["row"]
            feedback = ""
            if item["reason"]:
                feedback = (f"reason: {item['reason']}\n"
                            f"printed: {item['printed']}\n"
                            f"original: {item['original']}\n")
            tool_op = choose_op(row)
            use_tool = bool(tool_op) and fake is None and not args.no_tool_mode
            tool = None
            if use_tool:
                tool = build_family_tool(row, tool_op, vocab)
                messages = build_family_messages(row, tool_op, tool, feedback)
            else:
                examples = examples_text(row.get("exampleIds", []), programs, catalogue)
                messages = build_messages(system, examples, row, feedback)
            item["attempts"] = attempt
            seed = int(hashlib.sha256(f"{row['id']}:{attempt}".encode()).hexdigest()[:8], 16)
            mode = ("tool:" + tool_op) if use_tool else "authoring_v0"
            cache_key = sha256_text(json.dumps({
                "card": row["id"], "text": row["text"], "prompt": sha256_text(
                    json.dumps(messages, sort_keys=True)), "schema": schema_hash,
                "model": args.model, "attempt": attempt, "mode": mode,
            }, sort_keys=True))
            cache_path = cache_dir / (cache_key + ".json")
            if cache_path.exists() and not args.no_cache:
                reply = load_json(cache_path)
                reply["cached"] = True
            elif fake is not None:
                canned = fake.get(row["id"])
                if canned is None:
                    reply = {"error": "no canned program", "latencyMs": 0, "mode": "fake"}
                else:
                    reply = {"content": json.dumps(canned), "latencyMs": 0, "mode": "fake",
                             "usage": {}, "reasoning": ""}
            else:
                if use_tool:
                    reply = model_tool_call(args.url, args.model, messages, tool, seed, args.timeout)
                else:
                    reply = model_call(args.url, args.model, messages, schema, seed, args.timeout)
                if "error" not in reply:
                    cache_path.write_text(json.dumps(reply, sort_keys=True) + "\n")
            record = {"cardId": row["id"], "attempt": attempt, "model": args.model,
                      "mode": mode,
                      "promptHash": sha256_text(json.dumps(messages, sort_keys=True)),
                      "cacheKey": cache_key, "reply": reply}
            with raw_path.open("a") as handle:
                handle.write(json.dumps(record, sort_keys=True) + "\n")

            if "error" in reply:
                item["reason"] = reply["error"]
                continue
            try:
                if use_tool:
                    program = assemble_family_program(row, tool_op, parse_tool_arguments(reply), vocab)
                else:
                    program = parse_program(reply.get("content", ""), row["id"])
            except (ValueError, KeyError, json.JSONDecodeError) as error:
                item["reason"] = f"unparseable reply: {error}"
                print(f"author_llm: {row['id']}: {item['reason']}", file=sys.stderr)
                continue
            if "unsupported" in program:
                item["unsupported"] = True
                item["reason"] = "unsupported: " + str(program["unsupported"])
                continue
            program, normalizations = normalize_candidate(program)
            program = normalize_from_text(program, row, vocab)
            if normalizations:
                record["normalizations"] = normalizations
            problems = validate_candidate(program, keys, vocab)
            if problems:
                item["reason"] = "; ".join(problems[:6])
                print(f"author_llm: {row['id']}: {item['reason']}", file=sys.stderr)
                continue
            item["last_program"] = program
            candidates[row["id"]] = program

        if not candidates:
            continue
        dump_json(candidates_path, {"rulesVersion": "authoring", "programs": candidates})
        report = verify(candidates_path, out_dir)
        by_id = {row["id"]: row for row in report}
        for card_id, item in state.items():
            result = by_id.get(card_id)
            if result is None:
                continue
            if result.get("accepted"):
                item["program"] = candidates[card_id]
                item["reason"] = ""
            else:
                item["reason"] = result.get("reason", "rejected")
                item["printed"] = result.get("printed", "")
                item["original"] = result.get("original", "")

    # A final pass so accepted/rejected/report cover every card, including the unsupported ones.
    final_candidates = {card_id: (item["program"] or item["last_program"])
                        for card_id, item in state.items()
                        if item["program"] is not None or item["last_program"] is not None}
    dump_json(candidates_path, {"rulesVersion": "authoring", "programs": final_candidates})
    report = verify(candidates_path, out_dir)

    accepted = sum(1 for row in report if row.get("accepted"))
    rejected = len(state) - accepted
    model_root = ""
    server_version = ""
    if fake is None:
        try:
            with urllib.request.urlopen(args.url.replace("/chat/completions", "/models"),
                                        timeout=5) as response:
                models = json.loads(response.read().decode())
                if models.get("data"):
                    model_root = models["data"][0].get("root", "")
        except Exception:
            pass
        try:
            with urllib.request.urlopen(args.url.replace("/v1/chat/completions", "/version"),
                                        timeout=5) as response:
                server_version = json.loads(response.read().decode()).get("version", "")
        except Exception:
            pass
    manifest = {
        "block": args.block,
        "createdAt": datetime.now(timezone.utc).isoformat(),
        "model": args.model,
        "modelRoot": model_root,
        "serverVersion": server_version,
        "promptVersion": prompt_version,
        "schemaVersion": schema_hash,
        "cards": [{"id": row["id"], "textHash": sha256_text(row["text"])} for row in rows],
        "counts": {"attempted": len(state), "accepted": accepted, "rejected": rejected,
                   "unsupported": sum(1 for item in state.values() if item["unsupported"])},
        "command": " ".join(sys.argv),
    }
    dump_json(out_dir / "manifest.json", manifest)
    (out_dir / "review.md").write_text(review_packet(args.block, rows, report, manifest))
    dump_json(out_dir / "review.json", {"reviewed": False, "reviewer": "", "reviewedAt": "",
                                        "commit": "", "exceptions": []})

    print(f"author_llm: {args.block}: {accepted} accepted, {rejected} rejected, "
          f"{manifest['counts']['unsupported']} unsupported")
    return 0 if accepted > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
