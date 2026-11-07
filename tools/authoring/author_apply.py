#!/usr/bin/env python3
"""Promote a reviewed authoring block through the atomic data gate.

The transaction is deliberately all-or-nothing: back up authored.json, programs.json, both
baselines and provenance; merge; compile; verify-data; measure coverage; refuse a regression; write
the new floors and provenance; or restore every file and exit non-zero.

Usage:
  python3 tools/author_apply.py --data data --migrate --apply      # one-time provenance migration
  python3 tools/author_apply.py --data data --block data/authoring/blocks/<block> --apply
  python3 tools/author_apply.py --data data --block ... --dry-run
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
SIM = Path(os.environ.get("TAVERN_SIM", ROOT / "build-local" / "tavern-sim"))


def load_json(path: Path) -> dict:
    with path.open() as handle:
        return json.load(handle)


def dump_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n")
    temporary.replace(path)


def run(args: list[str], capture: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run([str(SIM), *args], cwd=ROOT, text=True,
                          capture_output=capture)


def admitted_ids(data: Path) -> set[str]:
    path = data / "programs.json"
    return set(load_json(path)["programs"]) if path.exists() else set()


def coverage(data: Path) -> dict:
    result = run(["coverage", "--data", str(data), "--json",
                  "--fingerprint", str(data / "programs.json"),
                  "--fingerprint", str(data / "authored.json")])
    if result.returncode != 0:
        raise RuntimeError(f"coverage failed: {result.stderr[:400]}")
    return json.loads(result.stdout)


def text_hash(text: str) -> str:
    import hashlib
    return hashlib.sha256(text.encode()).hexdigest()


def migrate(data: Path) -> int:
    authored_path = data / "authored.json"
    provenance_path = data / "authoring" / "provenance.json"
    if not authored_path.exists():
        print("author_apply: no authored.json")
        return 0
    authored = load_json(authored_path)["programs"]
    provenance = load_json(provenance_path) if provenance_path.exists() else {"entries": {}}
    catalogue = {card["id"]: card for card in load_json(data / "catalogue.json")["cards"]}
    added = 0
    for card_id in authored:
        if card_id in provenance["entries"]:
            continue
        card = catalogue.get(card_id, {})
        provenance["entries"][card_id] = {
            "origin": "hand-authored",
            "block": "",
            "model": "",
            "modelRoot": "",
            "serverVersion": "",
            "promptVersion": "",
            "schemaVersion": "",
            "attempts": 0,
            "acceptedAt": "",
            "reviewedBy": "pre-factory",
            "reviewedAt": "",
            "commit": "",
            "textHash": text_hash((card.get("text") or "").replace("\n", " ")),
            "gateReport": "",
        }
        added += 1
    dump_json(provenance_path, provenance)
    print(f"author_apply: migrated {added} hand-authored provenance entr"
          f"{'y' if added == 1 else 'ies'}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "data")
    parser.add_argument("--block", type=Path)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--migrate", action="store_true")
    parser.add_argument("--auto", action="store_true",
                        help="promote without a human when the gates and smoke pass")
    parser.add_argument("--reviewer", default="")
    parser.add_argument("--commit", default="")
    args = parser.parse_args()
    if args.auto:
        args.apply = True

    data = args.data if args.data.is_absolute() else ROOT / args.data
    if args.migrate:
        if not args.apply and not args.dry_run:
            print("author_apply: --migrate needs --apply or --dry-run", file=sys.stderr)
            return 2
        if args.dry_run:
            print("author_apply: dry-run migration")
            return 0
        return migrate(data)
    if args.block is None:
        print("author_apply: --block DIR is required", file=sys.stderr)
        return 2

    block_dir = args.block if args.block.is_absolute() else ROOT / args.block
    accepted_path = block_dir / "accepted.json"
    review_path = block_dir / "review.json"
    manifest_path = block_dir / "manifest.json"
    report_path = block_dir / "report.json"
    for path in (accepted_path, review_path, manifest_path):
        if not path.exists():
            print(f"author_apply: missing {path}", file=sys.stderr)
            return 2

    accepted = load_json(accepted_path)["programs"]
    review = load_json(review_path)
    manifest = load_json(manifest_path)

    if args.auto:
        # Owner policy: the automated gate set plus an execution smoke replaces per-block sign-off.
        # A smoke failure or skip still stops the block for a human.
        smoke = subprocess.run(
            [str(SIM), "author-smoke", "--data", str(data), "--candidates", str(accepted_path),
             "--ids", ",".join(sorted(accepted)), "--out", str(block_dir)],
            cwd=ROOT, text=True, capture_output=True,
        )
        if smoke.returncode != 0:
            print("author_apply: smoke failed; the block needs a human\n" + smoke.stdout + smoke.stderr,
                  file=sys.stderr)
            return 1
        commit = args.commit or subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], cwd=ROOT, text=True, capture_output=True
        ).stdout.strip()
        review = {"reviewed": True, "reviewer": "auto-gates",
                  "reviewedAt": datetime.now(timezone.utc).isoformat(), "commit": commit,
                  "exceptions": []}
        dump_json(review_path, review)
    if not accepted:
        print("author_apply: the block accepted no cards")
        return 1
    if not review.get("reviewed"):
        print("author_apply: review.json is not signed (reviewed: false)", file=sys.stderr)
        return 1
    if not review.get("reviewer"):
        print("author_apply: review.json has no reviewer", file=sys.stderr)
        return 1
    reviewer = args.reviewer or review.get("reviewer", "")
    commit = args.commit or review.get("commit", "")
    manifest_ids = {card["id"] for card in manifest.get("cards", [])}
    missing = sorted(set(accepted) - manifest_ids)
    if missing:
        print(f"author_apply: accepted cards not in the manifest: {missing}", file=sys.stderr)
        return 1
    if report_path.exists():
        report = {row["id"]: row for row in load_json(report_path) if isinstance(row, dict)}
        bad = [card_id for card_id in accepted
               if not report.get(card_id, {}).get("accepted")]
        if bad:
            print(f"author_apply: accepted cards that the report rejects: {bad}", file=sys.stderr)
            return 1

    authored_path = data / "authored.json"
    authored = load_json(authored_path) if authored_path.exists() else {"rulesVersion": "",
                                                                       "programs": {}}
    authored.setdefault("programs", {})
    duplicates = sorted(set(accepted) & set(authored["programs"]))
    if duplicates:
        print(f"author_apply: already authored: {duplicates}", file=sys.stderr)
        return 1

    before = admitted_ids(data)
    if args.dry_run:
        print(f"author_apply: would add {len(accepted)} card(s): {sorted(accepted)}")
        print(f"author_apply: admitted before {len(before)}")
        return 0
    if not args.apply:
        print("author_apply: --apply is required to write", file=sys.stderr)
        return 2

    backup = Path(tempfile.mkdtemp(prefix="author-apply-"))
    tracked = [authored_path, data / "programs.json", data / "coverage-baseline.json",
               data / "roundtrip-baseline.json", data / "authoring" / "provenance.json"]
    for path in tracked:
        if path.exists():
            shutil.copy2(path, backup / path.name)

    def restore() -> None:
        for path in tracked:
            saved = backup / path.name
            if saved.exists():
                shutil.copy2(saved, path)

    try:
        for card_id, program in accepted.items():
            program["implemented"] = True
            authored["programs"][card_id] = program
        dump_json(authored_path, authored)

        provenance_path = data / "authoring" / "provenance.json"
        provenance = load_json(provenance_path) if provenance_path.exists() else {"entries": {}}
        catalogue = {card["id"]: card for card in load_json(data / "catalogue.json")["cards"]}
        now = datetime.now(timezone.utc).isoformat()
        for card_id in accepted:
            card = catalogue.get(card_id, {})
            provenance.setdefault("entries", {})[card_id] = {
                "origin": "llm",
                "block": block_dir.name,
                "model": manifest.get("model", ""),
                "modelRoot": manifest.get("modelRoot", ""),
                "serverVersion": manifest.get("serverVersion", ""),
                "promptVersion": manifest.get("promptVersion", ""),
                "schemaVersion": manifest.get("schemaVersion", ""),
                "attempts": 0,
                "acceptedAt": now,
                "reviewedBy": reviewer,
                "reviewedAt": review.get("reviewedAt", ""),
                "commit": commit,
                "textHash": text_hash((card.get("text") or "").replace("\n", " ")),
                "gateReport": str(block_dir.relative_to(ROOT) / "report.json")
                if block_dir.is_relative_to(ROOT) else str(block_dir / "report.json"),
            }
        dump_json(provenance_path, provenance)

        for command in (["compile", "--data", str(data)],
                        ["verify-data", "--data", str(data)],
                        ["author-check", "--data", str(data)]):
            result = run(command)
            if result.returncode != 0:
                raise RuntimeError(f"{' '.join(command)} failed:\n{result.stdout}{result.stderr}")

        after = admitted_ids(data)
        if not before <= after:
            raise RuntimeError(f"admission regression: lost {sorted(before - after)}")
        added = sorted(after - before)
        missing = sorted(set(accepted) - set(added))
        if missing:
            raise RuntimeError(f"accepted cards did not reach admission: {missing}")
        # A printer/compiler change can admit additional deterministic cards in the same compile.
        # They are a superset, not a regression; record them but do not fail the block for them.
        side = sorted(set(added) - set(accepted))
        if side:
            print(f"author_apply: compiler also admitted {len(side)}: {' '.join(side)}")

        row = coverage(data)
        history = data / "authoring" / "coverage-history.jsonl"
        history.parent.mkdir(parents=True, exist_ok=True)
        with history.open("a") as handle:
            handle.write(json.dumps({
                "block": block_dir.name, "at": now, "admission": row["admission"],
                "manifest": row["manifest"], "fingerprint": row["fingerprint"],
                "cardsAdded": len(added),
            }, sort_keys=True) + "\n")

        result = run(["verify-data", "--data", str(data), "--update-baselines"])
        if result.returncode != 0:
            raise RuntimeError(f"baseline update failed:\n{result.stdout}{result.stderr}")

        dump_json(block_dir / "applied.json", {
            "block": block_dir.name,
            "appliedAt": now,
            "reviewer": reviewer,
            "commit": commit,
            "cards": sorted(accepted),
            "admissionBefore": len(before),
            "admissionAfter": len(after),
            "coverage": row,
            "fingerprint": row.get("fingerprint", ""),
        })
        print(f"author_apply: {block_dir.name}: +{len(added)} cards, "
              f"admission {len(before)} -> {len(after)}")
        return 0
    except Exception as error:  # noqa: BLE001 - the restore path must cover every failure
        restore()
        print(f"author_apply: FAILED, restored: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
