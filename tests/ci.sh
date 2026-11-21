#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# What GitHub CI runs (.github/workflows/ci.yml), on your own machine: lint, tests, the gated line coverage and
# the package. Needs python3, luajit, xz and zip. About 8 minutes, nearly all of it coverage (the line hook
# runs with the JIT off); --quick skips coverage (about 30 seconds).
#   bash tests/ci.sh [--quick]
# Keep the coverage minimums in step with ci.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
# Lowest CPU priority for this script and everything it starts: the game (or anything else) comes first.
renice -n 19 $$ >/dev/null 2>&1 || true
step() { printf '\n== %s\n' "$1"; }

step "Lint"
if [ -f tests/lint.py ]; then python3 tests/lint.py; else python3 tools/lint_addon.py && python3 tools/lint_engine.py; fi

step "Tests"
luajit tests/run.lua

if [ "${1:-}" != "--quick" ]; then
  step "Coverage (gated)"
  luajit tests/coverage.lua --report /tmp/tavern-coverage.md \
    --min-total 76 --min Engine=78 --min Collection=87 --min Net=80 --min UI=72
  grep -E "^\*\*Total" /tmp/tavern-coverage.md || true
fi

step "Package"
if [ -f .github/package.sh ]; then bash .github/package.sh ci-local; else bash tools/package.sh ci-local; fi

printf '\nci: ok\n'
