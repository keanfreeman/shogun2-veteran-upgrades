# Changelog

## 1.1.0
- Compatibility with overhauls that replace the campaign scripts (e.g. Master of Strategy Sengoku):
  the mod no longer ships `scripting.lua`; its code is appended to `export_advice.lua` instead.
- Unit, effect and effect-bundle names ship as separate `vu_*.loc` files instead of full copies of
  the game's, so other mods' texts are no longer replaced.
- Unit copies use `unique_index` 31000+ (they collided with ten of MoSS's new units).
- Debug builds (`VU_DEBUG=1`): engine-call trace, `vu_skip.txt`, 100 points per session.

## 1.0.0 (2026-10-07)
First public release.
- Clan-wide veteran upgrades for every recruitable land unit type, built from the multiplayer
  skill trees; units without one borrow the tree of a unit of the same class.
- Sengoku Jidai, Rise of the Samurai and Fall of the Samurai.
- Clan points: 1 per battle fought; repeatable stat upgrades priced by value; abilities as unit
  copies with recruitment switching; Retrain one army or all armies; respec for 2 points.
- AI clans earn and spend points on stat upgrades.
