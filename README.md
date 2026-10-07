# Veteran Upgrades for Total War: Shogun 2

Brings the multiplayer veteran upgrade trees into the campaign. Your clan earns points by fighting
battles and spends them on upgrades for any unit type, using the multiplayer skill-tree screen:
repeatable stat upgrades, passive traits and battlefield abilities. Covers Sengoku Jidai, Rise of the
Samurai and Fall of the Samurai.

- **Clan points:** 1 per battle your units fight in, win or lose.
- **Stats** (Melee Attack, Melee Defence, Armour, Morale, Accuracy) can be bought up to 10 times;
  each pick costs more, and stronger stats cost more.
- **Abilities** (Inspire Unit, Hold Firm, Banzai, Rapid Volley, Increased Range, ...) per unit type,
  in any combination.
- **Retrain** existing units to give them new abilities (one army, or all armies at once).
- **AI clans** earn points the same way and buy stat upgrades.

Players: get it from the Steam Workshop (link TBD). Start a new campaign after enabling it.

## How it works

The engine can't change one unit's abilities, and copies of ability records are ignored in battle.
So every ability combination of a unit type is its own **unit record copy** with those abilities
attached. When you buy abilities, the mod switches your clan's recruitment to the matching copy
(per-faction recruitment locks), and Retrain replaces existing units with it. Stat upgrades are
effect bundles applied to your faction, covering the originals and all copies.

[`docs/ENGINE_NOTES.md`](docs/ENGINE_NOTES.md) lists what we learned about the engine, including
the things that crash it.

## Repository

| Path | What |
|---|---|
| `veteran_upgrades/build.py` | Generates the whole mod from the game's own data |
| `veteran_upgrades/vu.lua` | Campaign script: points, panel UI, recruitment, retraining, AI |
| `tools_*.py` | Pack reader/writer, DB table codec (RPFM schema), `.loc` codec, reference checker |
| `tools/release.py` | Build + test + `dist/` (pack, Workshop thumbnail, description) |
| `tools/vu_ui_audit.py` | Leftover-tooltip report from a debug build's log |
| `tests/` | Mock campaign engine and scenarios, run with `tests/run_tests.py` |

Nothing from the game is included. The build reads your own copy of the game and writes the mod pack.

## Building

Needs Python 3.10+, a Steam install of Shogun 2 (with Fall of the Samurai for that campaign), and
RPFM's Shogun 2 schema.

1. `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`
2. Get the schema: install [RPFM](https://github.com/Frodo45127/rpfm), let it download its schemas,
   then point `RPFM_SCHEMA` at `schema_sho2.ron` (or copy it to `./schemas/`).
3. If the game isn't in a default Steam location, set `SHOGUN2_DATA` to its `data` folder.
4. `.venv/bin/python tools/release.py` builds `veteran_upgrades/veteran_upgrades.pack`, runs the
   tests and fills `dist/`. Add `--install` to copy the pack and thumbnail into the game.

To use a local build, add `mod "veteran_upgrades.pack";` to `user.script.txt` (UTF-16, in
`%APPDATA%\The Creative Assembly\Shogun2\scripts\`).

### Debug builds

`VU_DEBUG=1 .venv/bin/python veteran_upgrades/build.py` logs every view of the panel with its texts
and tooltips to `vu_log.txt` in the game folder; `tools/vu_ui_audit.py` reports leftovers from it.
The mod always writes a short `vu_log.txt` (purchases, battles, errors).

## Testing

`tests/run_tests.py` runs the generated scripts against a mock of the campaign scripting API
(`tests/mock_engine.lua`): the full flows on Sengoku and a smoke test on every campaign. It can't
catch engine crashes, so changes still need a play test, ideally with `PROTON_LOG=1` / a debugger
for native crashes.

## License

MIT, see [LICENSE](LICENSE). Total War: Shogun 2 is © SEGA / The Creative Assembly; this project
contains none of its files.
