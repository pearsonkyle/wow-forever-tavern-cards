#!/usr/bin/env bash
# Everything that must pass before a commit:  bash tests/check.sh
set -euo pipefail
cd "$(dirname "$0")/.."

python3 tools/lint_engine.py
for f in $(git ls-files '*.lua' 2>/dev/null || find . -name '*.lua'); do
  luajit -bl "$f" > /dev/null
done
luajit tests/run.lua

# Regenerated data must match what is committed (skipped when the engine is not available).
if [ -x tools/trace/tavern-trace ]; then
  python3 tools/export_data.py > /dev/null
  python3 tools/wave_plan.py > /dev/null
  git diff --quiet -- Data/Cards.lua Data/Wave.lua Engine/Data || { echo "check: generated data is stale; commit the regenerated files"; exit 1; }
fi
echo "check: ok"
