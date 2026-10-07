# Shogun 2 engine notes

What we learned building Veteran Upgrades, mostly the hard way. Confirmed in game (Steam version,
Linux/Proton) unless marked otherwise.

## Packs and data
- **Pack index must be sorted.** The game builds its folder tree from the pack index assuming CA's
  sorted order; an unsorted index (e.g. `db\x` listed after `text\y`) crashes at launch.
- Separately named DB table files **merge** with vanilla (`db\units_tables\my_file`); no need to
  copy the whole vanilla table.
- A `.loc` file with a vanilla name replaces the vanilla one, so include the vanilla rows.
- `unique_index` of new unit records: free slots inside the vanilla range work.

## Effects and abilities
- Effect bundles with `unit_record` bonus effects work per unit type: `accuracy_mod`,
  `melee_attack_mod`, `melee_defence_mod`, `armour_mod`, `morale`, `scares_men`, `cost_mod`.
- `range_mod` per unit record does nothing; at unit class/category scope it crashes the game at load.
- `reload` per unit record does nothing (vanilla only uses it at unit class scope).
- Abilities are a hard-coded engine list: copies of ability records with new keys are ignored.
  Vanilla abilities attached via `unit_to_unit_abilities_junctions` work. Abilities with
  `requires_effect_enabling` need an enabling effect, which is per (faction, ability).
- So per-unit-type abilities = **unit record copies** with the abilities attached, and
  recruitment switched to the right copy.

## Recruitment locks
- `add_restricted_unit_record(unit)` is **global** (all factions).
- `add_event_restricted_unit_record_for_faction(unit, faction)` locks for one faction;
  `remove_event_restricted_unit_record_for_faction(unit, faction)` unlocks. Both only queue the
  change: it takes effect at the next turn change.
- Calling them from `LoadingGame` crashes (it fires mid model-load). `NewCampaignStarted` is fine,
  and locks set there are active from turn 1.
- Toggling the global restriction applies queued locks at once, but the next character selection
  then crashes.

## Script functions (argument order verified in game)
Arguments in the DLL's Lua bindings are read last-first, so orders read from disassembly come out
reversed.
- `grant_unit(settlement_key, unit_key)`, e.g. `"settlement:jap_satsuma:kagoshima"`; spawns beside the settlement.
- `create_force(faction, "unit,unit", x, y, id, true)`: spawns a stack without a general anywhere.
- `CampaignUI.DisbandUnit(unit_ptr)`, `CampaignUI.CanDisbandUnit(unit_ptr)`.
- Unit pointers: `UIComponent(card):InterfaceFunction("ItemAddress")` on army unit cards;
  `CampaignUI.InitialiseUnitDetails(unit_ptr)` gives `UnitRecord.Key`, `Experience`, `Men`, and
  `CharacterPtr` (only on the general's card).
- `CampaignUI.RetrieveFactionMilitaryForceLists(faction, true)`: armies with `Address`
  (character pointer), `PosX`, `PosY`, `Name`.
- `CampaignUI.RetrieveContainedEntitiesFromCharacter(char, target)`: `Units[i].Address`. The second
  argument must be a character or garrison (the army's own general works); nil crashes.
- `award_experience_level(lookup, level)` sets the level of a whole army, not one unit.
- `conditions.FactionKeyIsLocal` is false for every faction during `NewCampaignStarted`.
- `save_named_value` is only known to work with numbers and booleans.

## Lua and UI rules
- The campaign `scripting.lua` main chunk allows at most **200 local variables** (Lua 5.1). Code
  appended to vanilla's script must run inside its own function or the whole script fails to load
  (no intro, wrong camera).
- In event handlers, **do almost nothing for events that aren't yours.** Walking a clicked
  component's parents, or querying its state, in `ComponentLClickUp` left later handlers for the
  same click with a null component and crashed the game (`conditions.IsComponentType`, the
  advisor's `CharacterIsLocalCampaign`). Changing the UI during the click (hiding the panel the
  clicked button is in) did the same. Record the click and act from
  `add_time_trigger(name, 0.01)` / `TimeTrigger`.
- Walking the whole UI tree, even from a time trigger, crashed the next event handler.
- `UIComponent:Find(i)` with `i >= ChildCount()` crashes the game.
- Recruitment cards (`s2_LandRecruitmentCardGroup` children) answer `Id()` / `CurrentState()` with
  Lua functions; touching them was followed by crashes, so locked units can't be hidden.
- `Component.CreateFromLayout("data/ui/frontend ui/popup_skill_tree", ...)` works in campaign;
  `SetTooltipText(text, true)` sets the tooltip for all states; `ShaderTechniqueSet("normal_t0" |
  "set_greyscale_t0", true)`.
- The campaign UI is rebuilt after every battle (`UICreated` again): drop all component references.
