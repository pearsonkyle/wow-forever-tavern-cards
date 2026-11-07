#!/usr/bin/env bash
# Differential fuzz: tavern-trace (C++) vs the Lua engine, batch by batch, stopping at the first divergence.
#   bash tests/fuzz.sh [pool=all] [batches=4] [first_seed=1000] [per_batch=50]
set -euo pipefail
cd "$(dirname "$0")/.."
pool="${1:-all}"; batches="${2:-4}"; seed="${3:-1000}"; per="${4:-50}"
data="${JANKCRAFT:-$HOME/Programs/misc/wow/jankcraft}/server/modules/mod-tavern-sim/data"
mkdir -p tools/cache/traces
for ((b = 0; b < batches; b++)); do
  s=$((seed + b * per))
  out="tools/cache/traces/fuzz-$pool-$s.jsonl"
  ./tools/trace/tavern-trace --data "$data" --pool "tools/cache/pools/$pool.txt" --seed "$s" --matches "$per" > "$out"
  if ! luajit tests/trace.lua "$out"; then
    echo "fuzz: divergence in $out (kept)"; exit 1
  fi
  rm -f "$out"
done
echo "fuzz: $((batches * per)) $pool matches from seed $seed, no divergence"
