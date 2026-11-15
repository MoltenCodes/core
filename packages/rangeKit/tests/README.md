# RangeKit Tests

The RangeKit suite covers:

- checker lists: each kind built only from the spells the spellbook reports, sorted and rounded, the first checker of a range kept (a spell before an interact checker), melee spells left out, a minimum-range spell joined with a closer spell, joined with an interact checker and skipped in combat, or left out without one, a minimum not below the range, a class without candidates;
- estimates: brackets at both ends and between checkers, at most three checks for four checkers, each unit kind picking its list (attackable, friendly, dead friendly, dead hostile, neutral, a pet), a missing unit, interact checks skipped in combat for a unit the player cannot attack and kept for an attackable one, `IsInRange` true, false and undecided, legacy `0` answers;
- rebuilds and listeners: a rebuild on every event, listeners called only on a change (a change of a minimum range alone included), the pet event of another unit ignored, a raising listener reported and the others still run, a failure printed without an error handler, disconnecting once and during a notification, `maxListeners` refusing and kept when lowered;
- a host lacking calls: events the client calls invalid not registered, `CreateFrame` appearing after load, no spell calls, no `CheckInteractDistance`, no `UnitExists`, no relation or combat calls;
- arguments: every argument and receiver failure reported at the caller's line;
- secret values: secret units, yards, kinds, callbacks, limits and receivers refused; secret range answers, unit existence, relations, combat, class, spellbook, spell bank, spell description, ranges and event validity treated as no answer;
- Registry publication, a duplicate embedded load keeping listeners and the event frame, yielding to a newer revision, an in-place upgrade where the event frame, listeners, lists and the limit run the new code, an upgrade from a revision 1 copy, refusals of state holding an invalid limit or lists, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/RangeKitTestEnv.lua` provides a small world the client calls answer from: the player's class (`SetClass`), a spellbook (`Learn`, `Forget`, `DefineSpell` for a spell's reach or a fixed answer), units at a distance with a relation (`PlaceUnit`, `RemoveUnit`), combat (`SetCombat`), a count of range checks (`CheckCount`), `Sources` (a kind's checker sources), the secret probe, `LoadRevision` and `NewPackageAtRevision` (a fresh world with the working file loaded as an older revision).

| Spec | Covers |
|---|---|
| `Range_spec.lua` | lists, estimates, the combat rule, rebuilds, listeners, a host lacking calls |
| `Arguments_spec.lua` | argument and receiver errors at the caller's line |
| `SecretValues_spec.lua` | secret arguments refused, secret client answers ignored |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
