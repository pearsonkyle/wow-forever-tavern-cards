#!/usr/bin/env python3
"""Measure the authoring factory, block by block.

Nothing here is a claim: attempted/accepted counts come from the block report, latencies and modes
from raw.jsonl, and the coverage history from the transaction that applied a block. `--gaps` groups
the rejected cards by the first effect verb so the next block (or the IR v2 backlog) is chosen from
the measured tail, not from a hunch.

Usage:
  python3 tools/author_report.py --data data
  python3 tools/author_report.py --data data --gaps --limit 20
  python3 tools/author_report.py --data data --json
"""
from __future__ import annotations

import argparse
import json
import os
import re
import statistics
import sys
from collections import Counter
from pathlib import Path

# TavernCards: these tools are copied from jankcraft (read-only there). They run against our overlay: a
# copy of jankcraft's data plus our authored cards (tools/authoring/overlay.py init), with jankcraft's
# prebuilt tavern-sim linked in, so jankcraft itself is never written to.
ROOT = Path(os.environ.get("TC_SIM_ROOT", Path(__file__).resolve().parents[1] / "cache" / "sim"))
VERBS = ("deal", "restore", "draw", "summon", "give", "gain", "destroy", "freeze", "silence",
         "discard", "shuffle", "transform", "set", "swap", "add", "discover", "equip", "return")
VERB_RE = re.compile(r"\b(" + "|".join(VERBS) + r")\b", re.I)


def load_json(path: Path, default=None):
    if not path.exists():
        return default
    with path.open() as handle:
        return json.load(handle)


def block_rows(blocks_dir: Path) -> list[dict]:
    rows = []
    for directory in sorted(path for path in blocks_dir.iterdir() if path.is_dir()):
        manifest = load_json(directory / "manifest.json")
        report = load_json(directory / "report.json")
        if manifest is None or report is None:
            continue
        latencies = []
        modes = Counter()
        raw = directory / "raw.jsonl"
        if raw.exists():
            for line in raw.read_text().splitlines():
                if not line.strip():
                    continue
                record = json.loads(line)
                reply = record.get("reply", {})
                if isinstance(reply.get("latencyMs"), int):
                    latencies.append(reply["latencyMs"])
                modes[reply.get("mode", "?")] += 1
        accepted = sum(1 for row in report if row.get("accepted"))
        rows.append({
            "block": manifest.get("block", directory.name),
            "attempted": len(report),
            "accepted": accepted,
            "rejected": len(report) - accepted,
            "unsupported": manifest.get("counts", {}).get("unsupported", 0),
            "meanLatencyMs": int(statistics.mean(latencies)) if latencies else 0,
            "p95LatencyMs": sorted(latencies)[int(len(latencies) * 0.95)] if latencies else 0,
            "modes": dict(modes),
            "model": manifest.get("model", ""),
            "paths": [row.get("id") for row in report if not row.get("accepted")],
        })
    return rows


def gaps(rows: list[dict], limit: int) -> list[tuple[str, int, list[str]]]:
    buckets: dict[str, list[str]] = {}
    for row in rows:
        for card_id in row["paths"]:
            # The id is all the report carries; the text lives in the queue.
            buckets.setdefault("rejected", []).append(card_id)
    return [("rejected", len(buckets.get("rejected", [])), buckets.get("rejected", [])[:limit])]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=ROOT / "data")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--gaps", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    data = args.data if args.data.is_absolute() else ROOT / args.data
    blocks = block_rows(data / "authoring" / "blocks")
    history = []
    history_path = data / "authoring" / "coverage-history.jsonl"
    if history_path.exists():
        for line in history_path.read_text().splitlines():
            if line.strip():
                history.append(json.loads(line))

    if args.json:
        print(json.dumps({"blocks": blocks, "history": history}, indent=2))
        return 0

    print("| block | model | attempted | accepted | rejected | unsupported | mean ms | p95 ms | modes |")
    print("|---|---|---:|---:|---:|---:|---:|---:|---|")
    for row in blocks:
        print(f"| {row['block']} | {row['model']} | {row['attempted']} | {row['accepted']} | "
              f"{row['rejected']} | {row['unsupported']} | {row['meanLatencyMs']} | "
              f"{row['p95LatencyMs']} | {row['modes']} |")
    attempted = sum(row["attempted"] for row in blocks)
    accepted = sum(row["accepted"] for row in blocks)
    print(f"\ntotal: {accepted}/{attempted} accepted "
          f"({100 * accepted / attempted:.1f}%)" if attempted else "\ntotal: no blocks")
    if history:
        latest = history[-1]
        print(f"coverage: admission {latest['admission']}/{latest['manifest']} "
              f"(+{latest['cardsAdded']} this block), fingerprint {latest['fingerprint'][:12]}")
    if args.gaps:
        print("\nrejected cards (group by the queue text, not by the id):")
        queue_path = data / "authoring" / "queue.jsonl"
        texts = {}
        if queue_path.exists():
            for line in queue_path.read_text().splitlines():
                row = json.loads(line)
                texts[row["id"]] = row.get("text", "")
        counts: Counter[str] = Counter()
        examples: dict[str, list[str]] = {}
        for row in blocks:
            for card_id in row["paths"]:
                text = texts.get(card_id, "")
                match = VERB_RE.search(text)
                key = match.group(1).lower() if match else "(no verb)"
                counts[key] += 1
                examples.setdefault(key, []).append(card_id)
        for key, count in counts.most_common(args.limit):
            print(f"  {count:5d}  {key:12s}  {', '.join(examples[key][:5])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
