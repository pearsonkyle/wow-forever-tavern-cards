# Tavern Cards

[![CI](https://github.com/pearsonkyle/wow-forever-tavern-cards/actions/workflows/ci.yml/badge.svg)](https://github.com/pearsonkyle/wow-forever-tavern-cards/actions/workflows/ci.yml)

A collectible card game inside **WoW: Forever** (Interface 16001). Every quest you finish earns a card;
build decks, play the house at the tavern table, and duel your friends, all without leaving the game.

The rules engine is a Lua port of the `mod-tavern-sim` engine from the jankcraft server project and is
checked move by move against the C++ original: all 3,001 playable cards have been swept through that
comparison with zero divergences.

![The tavern table](docs/screenshots/match.jpg)

## Features

- **Collect by playing WoW**: one card per quest (class-themed, mapped from the quest database), your
  completed quests paid out on first login, plus practice-match rewards. Duplicates past 2 (1 for
  Legendaries) turn into dust automatically.
- **The card book**: browse and filter your collection, craft with dust (Alt + Right-click) and
  disenchant (Ctrl + Right-click), build any number of decks, share decks as codes or chat links.
- **The tavern table**: practice against the house at four difficulties, or **duel a friend** who has
  the addon: lockstep play with commit-reveal deck/seed exchange, desync detection, resume after
  `/reload`. Animated board: targeting arrow, flying cards, hit flashes, world-map play mats.
- **Social**: a tavern chat channel per faction, card and deck links in chat, who's-online presence.
- **Readable**: every keyword explained in a side tooltip; quest origin in the ledger.

| | |
|---|---|
| ![Collection](docs/screenshots/collection.jpg) | ![Deck builder](docs/screenshots/deck-builder.jpg) |
| ![Ledger](docs/screenshots/ledger.jpg) | ![Quest reward](docs/screenshots/quest-reward-toast.jpg) |

## Install

1. Download `TavernCards-<version>.zip` from [Releases](../../releases).
2. Extract it into `World of Warcraft/_forever_/Interface/AddOns/` (you get an `AddOns/TavernCards` folder).
3. Restart the game. Open the book with `/tc` or the minimap button.

Useful commands: `/tc play` (back to your match), `/tc duel Name`, `/tc channel on|off`, `/tc who`,
`/tc sound`, `/tc collection`, `/tc help`.

## Development

This folder is both the addon (WoW loads only the files listed in `TavernCards.toc`) and its repo.

| Path | What |
|---|---|
| `Core/` | Bootstrap: namespace, SavedVariables, events, client capability probe, slash commands |
| `Engine/` | Rules engine (headless: no WoW API, enforced by `tools/lint_engine.py`) and the AI |
| `Collection/` | Collection, dust economy, decks and deck codes |
| `UI/` | Window, card book, board, match controller, tooltips, toasts, minimap |
| `Net/`, `Social/` | Duels (lockstep P2P), chat channel, presence, chat links |
| `Sources/` | Where cards come from (quests) |
| `Data/`, `Engine/Data/` | Generated card data, quest map and icons (committed) |
| `tests/` | LuaJIT test suite, coverage, C++ parity replay, card sweep |
| `fixtures/traces/` | Recorded C++ reference matches (xz) replayed by CI |
| `tools/` | Data export, icon catalog, authoring overlay, lint, packaging |

### Running the checks (what CI runs)

Needs only `luajit`, `xz` and `python3`:

```sh
python3 tools/lint_addon.py                        # toc ↔ files, syntax, no stray globals
python3 tools/lint_engine.py                       # the engine stays headless
luajit tests/run.lua                               # all suites (or: luajit tests/run.lua duel)
luajit tests/trace.lua fixtures/traces/*.jsonl.xz  # Lua vs the C++ engine on recorded matches
luajit tests/coverage.lua --report coverage.md     # line coverage (CI enforces minimums)
bash tools/package.sh                              # dist/TavernCards-<version>.zip
```

The test suite runs the whole addon in a mocked client (login, every tab, a practice match), plays full
duels between two simulated clients, and replays the C++ reference traces.

### Working with the C++ engine (maintainers)

Regenerating data, recording new reference traces and the full card sweep need a jankcraft checkout
(`JANKCRAFT`, default `~/Programs/misc/wow/jankcraft`; it is only ever read):

```sh
bash tools/trace/build.sh            # build tavern-trace against jankcraft's engine
python3 tools/export_data.py         # Data/Cards.lua + Engine/Data/Programs.lua
python3 tests/sweep.py 6 4           # every playable card through the C++/Lua comparison
python3 tools/make_fixtures.py       # refresh fixtures/traces (CI's parity check)
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Licence

The addon's code is [MIT](LICENSE). Card names and text are Blizzard's (see Credits).

## Credits

Card data originates from [HearthstoneJSON](https://hearthstonejson.com) via the jankcraft project.
Card names and text are the property of Blizzard Entertainment; World of Warcraft art is Blizzard's and
is used from the game client at run time (nothing is redistributed). This is a non-commercial fan project
and is not affiliated with or endorsed by Blizzard Entertainment. Bundled libraries (`Libs/`) keep their
own licences.
