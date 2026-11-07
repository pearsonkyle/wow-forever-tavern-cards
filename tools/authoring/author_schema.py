#!/usr/bin/env python3
"""Generate the authoring vocabulary, key sets and the constrained-decoding JSON Schema.

The schema is derived from the C++ vocabulary and the same key table `author-verify` enforces, so a
new op/trigger/condition cannot appear in one place and not the other. `--check` is the drift gate:
it compares the generated files with the committed ones and exits non-zero when they differ.

Usage:
  python3 tools/author_schema.py --data data
  python3 tools/author_schema.py --data data --check
  python3 tools/author_schema.py --data data --print-hash
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
SIM = Path(os.environ.get("TAVERN_SIM", ROOT / "build-local" / "tavern-sim"))


def run_json(args: list[str]) -> dict:
    result = subprocess.run([str(SIM), *args, "--data", str(ROOT / "data")],
                            cwd=ROOT, text=True, capture_output=True, check=True)
    return json.loads(result.stdout)


def integer(minimum: int = 0, maximum: int = 100) -> dict:
    return {"type": "integer", "minimum": minimum, "maximum": maximum}


def build_schema(vocab: dict, keys: dict) -> dict:
    effect_properties = {
        "trigger": {"enum": vocab["triggers"]},
        "op": {"enum": vocab["ops"]},
        "target": {
            "type": "object",
            "additionalProperties": False,
            "properties": {
                "kind": {"enum": vocab["targetKinds"]},
                "side": {"enum": vocab["targetSides"]},
            },
            "required": ["kind", "side"],
        },
        "amount": integer(0, 100),
        "amount2": integer(0, 100),
        "type_filter": integer(0, 4),
        "discoverCostDelta": integer(-10, 10),
        "heroPowerShort": {"type": "boolean"},
        "heroPowerDelta": {"type": "boolean"},
        "buffHand": {"type": "boolean"},
        "buffDeck": {"type": "boolean"},
        "buffBoard": {"type": "boolean"},
        "buffRandom": {"type": "boolean"},
        "buffAll": {"type": "boolean"},
        "valueSource": {"enum": vocab["valueSources"]},
        "token": {"type": "string"},
        "tokenDisplay": {"type": "string"},
        "tokens": {"type": "array", "items": {"type": "string"}, "maxItems": 8},
        "keyword": {"type": "string"},
        "spell": {"type": "boolean"},
        "summonNamed": {"type": "boolean"},
        "implicitTarget": {"type": "boolean"},
        "fromDeck": {"type": "boolean"},
        "tokenUnnamed": {"type": "boolean"},
        "namedAnywhere": {"type": "boolean"},
        "prompt": {"type": "boolean"},
        "additional": {"type": "boolean"},
        "excessToHero": {"type": "boolean"},
        "classPool": {"type": "integer"},
        "conditionTrails": {"type": "boolean"},
        "delayed": {"type": "boolean"},
        "costOverride": {"type": "integer"},
        "repeatLess": {"type": "boolean"},
        "darkGift": {"type": "boolean"},
        "freshCopy": {"type": "boolean"},
        "whileAttacking": {"type": "boolean"},
        "statsFromHeroGains": {"type": "boolean"},
        "repeatPerCount": {"type": "boolean"},
        "improved": {"type": "boolean"},
        "doubleSpellDamage": {"type": "boolean"},
        "requiresPrevious": {"type": "boolean"},
        "printOnly": {"type": "boolean"},
        "silent": {"type": "boolean"},
        "summonAttacks": integer(0, 4),
        "diesEndOfTurn": {"type": "boolean"},
        "toOwnHand": {"type": "boolean"},
        "staysInHand": {"type": "boolean"},
        "wording": {"type": "string"},
        "subjectName": {"type": "string"},
        "sourcePhrase": {"type": "string"},
        "costCountName": {"type": "string"},
        "stuffed": {"type": "boolean"},
        "discoverSummon": {"type": "boolean"},
        "discoverTakeAll": {"type": "boolean"},
        "secretOnly": {"type": "boolean"},
        "chooseOneOnly": {"type": "boolean"},
        "statsFromSource": {"type": "boolean"},
        "statsBoth": {"type": "boolean"},
        "previousPlural": {"type": "boolean"},
        "fromHand": {"type": "boolean"},
        "extra": {"type": "boolean"},
        "oneInHand": {"type": "boolean"},
        "subjectSide": {"type": "integer"},
        "otherClass": {"type": "boolean"},
        "zeroCost": {"type": "boolean"},
        "targetAttackMin": integer(0, 100),
        "targetAttackMax": integer(0, 100),
        "targetHealthMin": integer(0, 100),
        "targetHealthMax": integer(0, 100),
        "condition": {"enum": [row["name"] for row in vocab["conditions"]]},
        "conditionRace": {"enum": [""] + vocab["races"]},
        "conditionSchool": {"enum": [""] + vocab["schools"]},
        "conditionKeyword": {"enum": [""] + vocab["keywords"]},
        "costCount": {"enum": vocab["costCounts"]},
        "costCountRace": {"enum": [""] + vocab["races"]},
        "conditionAmount": integer(0, 100),
        "conditionType": integer(0, 4),
        "amountSource": {"enum": vocab["costCounts"]},
        "amountSourceRace": {"enum": [""] + vocab["races"]},
        "countSelector": {"type": "boolean"},
        "countSide": {"enum": vocab["targetSides"]},
        "countZone": {"enum": ["BOARD", "HAND", "DECK", "GRAVEYARD"]},
        "countType": integer(0, 4),
        "countRace": {"enum": [""] + vocab["races"]},
        "countKeyword": {"enum": [""] + vocab["keywords"]},
        "countDamagedOnly": {"type": "boolean"},
        "countExcludeSource": {"type": "boolean"},
        "repeat": integer(1, 10),
        "split": {"type": "boolean"},
        "setVerb": {"type": "boolean"},
        "damageRange": {"type": "boolean"},
        "forOpponent": {"type": "boolean"},
        "takeVerb": {"type": "boolean"},
        "costMin": integer(0, 10),
        "costMax": integer(0, 10),
        "familyFilter": integer(0, 12),
        "rarityFilter": integer(0, 5),
        "schoolFilter": integer(0, 7),
        "corpseCost": integer(0, 20),
        "corpseMax": integer(0, 20),
        "excludeSource": {"type": "boolean"},
        "damagedOnly": {"type": "boolean"},
        "undamagedOnly": {"type": "boolean"},
        "bothPlayers": {"type": "boolean"},
        "temporary": {"type": "boolean"},
        "durationTurns": integer(0, 10),
        "subjectType": integer(0, 4),
        "subjectSchool": {"enum": [""] + vocab["schools"]},
        "subjectCost": integer(0, 10),
        "subjectHealth": integer(0, 100),
        "subjectAttackMax": integer(0, 100),
        "subjectAttackMin": integer(0, 100),
        "subjectRace": {"enum": [""] + vocab["races"]},
        "subjectKeyword": {"enum": [""] + vocab["keywords"]},
        "keywordFilter": {"enum": [""] + vocab["keywords"]},
        "raceFilter": {"enum": [""] + vocab["races"]},
        "excludeRace": {"enum": [""] + vocab["races"]},
        "followUp": {"type": "array", "maxItems": 3, "items": {"type": "object"}},
        "replacement": {"type": "array", "maxItems": 3, "items": {"type": "object"}},
        "followUpCondition": {"enum": ["NONE", "IF_DIES", "IF_SURVIVES"]},
    }
    assert set(effect_properties) == set(keys["effect"]), (
        "author_schema: the schema and author-keys disagree: "
        f"{sorted(set(effect_properties) ^ set(keys['effect']))}"
    )
    effect = {
        "type": "object",
        "additionalProperties": False,
        "properties": effect_properties,
        "required": ["trigger", "op"],
    }
    program_properties = {
        "implemented": {"const": True},
        "unsupported": {"type": "string", "maxLength": 400},
        "effects": {"type": "array", "minItems": 0, "maxItems": 6, "items": effect},
        "choices": {
            "type": "array",
            "maxItems": 4,
            "items": {"type": "array", "minItems": 1, "maxItems": 4, "items": effect},
        },
        "keywords": {"type": "array", "items": {"enum": vocab["keywords"]}, "maxItems": 8},
        "spellDamage": integer(0, 10),
        "overload": integer(0, 10),
        "cantAttack": {"type": "boolean"},
        "secret": {"type": "boolean"},
        "dormantTurns": integer(0, 10),
        "tradeable": {"type": "boolean"},
        "starshipPiece": {"type": "boolean"},
        "bonusEffects": integer(0, 4),
        "bonusEffectsReroll": {"type": "boolean"},
        "colossal": integer(0, 10),
        "magnetic": {"type": "boolean"},
        "echo": {"type": "boolean"},
        "prepare": {"type": "boolean"},
        "twinspell": {"type": "boolean"},
        "paysWith": integer(0, 2),
        "allMinionTypes": {"type": "boolean"},
        "swapInHand": {"type": "boolean"},
        "numbered": {"type": "boolean"},
        "handTurns": integer(0, 10),
        "sandwich": {"type": "string"},
        "castsWhenDrawn": {"type": "boolean"},
        "titanAbilities": {"type": "array", "items": {"type": "string"}},
    }
    assert set(program_properties) == set(keys["program"]), (
        "author_schema: the schema and author-keys disagree: "
        f"{sorted(set(program_properties) ^ set(keys['program']))}"
    )
    return {
        "$schema": "https://json-schema.org/draft/2020-12/schema",
        "title": "authoring_v0",
        "type": "object",
        "additionalProperties": False,
        "properties": program_properties,
        "required": ["implemented"],
    }


def canonical(value: dict) -> str:
    return json.dumps(value, sort_keys=True, indent=2) + "\n"


def write_if_changed(path: Path, text: str) -> bool:
    if path.exists() and path.read_text() == text:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "data")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--print-hash", action="store_true")
    args = parser.parse_args()

    data = args.data if args.data.is_absolute() else ROOT / args.data
    vocab = run_json(["vocabulary"])
    keys = run_json(["author-keys"])
    schema = build_schema(vocab, keys)

    files = {
        data / "authoring" / "vocab.json": canonical(vocab),
        data / "authoring" / "keys.json": canonical(keys),
        data / "authoring" / "schema" / "authoring-v0.json": canonical(schema),
    }
    if args.print_hash:
        print(hashlib.sha256(files[data / "authoring" / "schema" / "authoring-v0.json"]
                             .encode()).hexdigest())
        return 0

    if args.check:
        drift = [str(path) for path, text in files.items()
                 if not path.exists() or path.read_text() != text]
        if drift:
            print("author_schema: drift in " + ", ".join(drift), file=sys.stderr)
            return 1
        print("author_schema: ok (vocab, keys and schema are current)")
        return 0

    changed = [str(path) for path, text in files.items() if write_if_changed(path, text)]
    print(f"author_schema: wrote {len(files)} file(s)"
          + (f" ({len(changed)} changed)" if changed else " (no changes)"))
    print(f"author_schema: schema sha256 "
          f"{hashlib.sha256(files[data / 'authoring' / 'schema' / 'authoring-v0.json'].encode()).hexdigest()}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
