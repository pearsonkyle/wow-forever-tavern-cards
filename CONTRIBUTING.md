# Contributing to Tavern Cards

Thanks for helping! A few ground rules keep the game fair and the rules correct.

## Before you open a pull request

Run what CI runs (needs `luajit`, `xz`, `python3`):

```sh
python3 tools/lint_addon.py
python3 tools/lint_engine.py
luajit tests/run.lua
luajit tests/coverage.lua --report coverage.md
```

CI must be green to merge: lint, the full test suite (including the C++ parity replay of
`fixtures/traces`), and line coverage at or above the minimums in `.github/workflows/ci.yml`.
New code comes with tests; a PR that lowers coverage below a minimum fails.

## The rules engine (`Engine/`)

- It is a port of jankcraft's C++ `mod-tavern-sim` engine, and **parity is the contract**: the same
  seed and moves must give the same state as the C++ engine, including the order of random draws.
  Don't "fix" a rule in Lua alone; rules change in the C++ engine first, then here, then the
  reference traces are re-recorded (`python3 tools/make_fixtures.py`, maintainers).
- No WoW API in `Engine/` (`tools/lint_engine.py`). Everything there must run under plain LuaJIT.

## The addon

- Every new `.lua` file goes in `TavernCards.toc` (the lint checks both ways).
- No new globals: use the `TavernCards_NS` namespace (`local TC = TavernCards_NS`).
- WoW: Forever quirks to respect:
  - Addons can't send chat messages: put text in the chat box instead.
  - Whispers don't cross connected realms; group channels do.
  - Chat data can be "secret" in instances and combat (`issecretvalue`).
  - Don't use `StaticPopup`; use `TC:Confirm`.
- Generated files (`Data/`, `Engine/Data/`) are produced by `tools/`; change the tool, not the output.

## Style

Match the code around you: short functions, comments that explain *why*, names that read well. Lua 5.1
(LuaJIT) only.

## Reporting bugs

Open an issue with what you did, what happened, and a screenshot if it's visual. `/tc probe` output
helps for client-specific problems; errors the addon caught are in `TavernCardsDB.errors`.
