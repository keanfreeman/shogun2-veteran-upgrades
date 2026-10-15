# Changelog

## 1.2.0 (2026-10-15)
- Multiplayer campaigns: every player's upgrades now stick. Up to 1.1.0 a purchase changed only the
  buyer's game, the game resynced from the host at the end of the turn, and a guest's upgrades
  vanished. Purchases are now sent to every player (in the names of a few of the buyer's units) and
  take effect for everyone when the buyer ends the turn; the names are put back at the next turn.
  Each clan has its own points, from its own battles.
- Multiplayer campaigns saved with 1.1.0 or older: the upgrades in the save can't be assigned to a
  player, so they are refunded as points to every player.
- Single-player saves are unchanged.
- Debug builds in multiplayer: 100 points for every human clan per session.

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
