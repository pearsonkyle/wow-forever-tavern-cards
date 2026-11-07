# Tavern Cards

A WoW Forever (Interface 16001) addon: collect cards by questing and adventuring, build decks, and play a
tavern card game against NPCs and other players. The rules engine is a Lua port of the `mod-tavern-sim`
engine from the jankcraft server project, checked step by step against the C++ original.

This folder is both the addon (WoW loads only the files listed in `TavernCards.toc`) and its development repo.

## In game

- `/tc status` card data and engine build
- `/tc probe` which UI templates, atlases, events and APIs this client has (also saved to `TavernCardsDB.probe`)
- `/tc rng` RNG self-test against the reference engine

## Layout

| Path | What |
|---|---|
| `Core/` | Addon bootstrap: namespace, SavedVariables, events, client capability probe, slash commands |
| `Engine/` | Rules engine. Must run headless: no WoW API (enforced by `tools/lint_engine.py`) |
| `Data/`, `Engine/Data/` | Generated card data (committed; regenerate with the tools below) |
| `tools/trace/` | `tavern-trace`, built against jankcraft's C++ engine: records reference matches and dumps runtime card data |
| `tools/*.py` | Data export, wave planning, engine lint |
| `tests/` | LuaJIT test runner and suites |

## Development

Requires `luajit`, `python3`, a C++20 compiler, and a jankcraft checkout (`JANKCRAFT`, default
`~/Programs/misc/wow/jankcraft`; it is only read, never modified).

```sh
bash tools/trace/build.sh            # build tavern-trace against jankcraft's engine
python3 tools/export_data.py         # Data/Cards.lua + Engine/Data/Programs.lua from the engine as loaded
python3 tools/wave_plan.py --target classic   # what the Lua engine can play, and what to port next
bash tests/check.sh                  # lint + syntax + tests + generated-data freshness
```

Reference traces for the port:

```sh
tools/trace/tavern-trace --data $JANKCRAFT/server/modules/mod-tavern-sim/data --seed 7 --matches 10 > /tmp/ref.jsonl
```

Each line is a match header (seed, decks), a step (legal moves, chosen index, full state), or the result.

## Credits

Card data originates from [HearthstoneJSON](https://hearthstonejson.com) via the jankcraft project.
Card names and text are the property of Blizzard Entertainment. This is a non-commercial fan project.
