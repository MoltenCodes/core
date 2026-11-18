# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that itself raises (an error-display addon with a bug) made the failure RangeKit was reporting raise again into whatever the client was running. `reportError` now calls the handler through `pcall` and prints the failure when the handler is missing or raises.
- `isSecret`, `reportError` and `validateFacade` are now the shared helper blocks (`tooling/shared/lua/`, kept in step by `python3 -m tooling.shared.sync`). The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 3; an embedded revision 2 is upgraded in place, its state kept.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the raising error handler, the facade message, the upgrade over the committed revision 2 file in `tests/fixtures/RangeKit-revision2.lua`) and `Conformance_spec.lua` (the repository's conformance suite; pending: limits (its unknown-limit refusal does not name the key) and arguments, see the spec).

## 0.1.1 — 2026-11-15

- Fixed: a rebuild in which only a spell's minimum range changed (a talent that changes a spell's reach, the same spell, the same range) replaced the lists without calling the `OnCheckersChanged` listeners, so `DescribeCheckers` answered differently with no notification. The comparison now covers each checker's minimum range as well as its range and source. Implementation revision 2; a revision 1 copy upgrades in place.
- Documentation: `IsInRange` decides at every checker range only for the list it searches; in combat, for a unit the player cannot attack, the interact ranges are not searched. The candidate spell IDs were compared with LibRangeCheck-3.0 minor 39.
- 43 specs.

## 0.1.0 — 2026-11-15

- Added RangeKit API generation 1, implementation revision 1: unit range estimates, as recorded in `docs/ROADMAP.md` (rangeKit, core decision 16).
- `RangeKit:GetRange(unit)` brackets the distance in yards from the player's own spells (`C_Spell.IsSpellInRange`, reach from `C_Spell.GetSpellInfo`) and `CheckInteractDistance` (7 and 28 yards); `RangeKit:IsInRange(unit, yards)`; `RangeKit:DescribeCheckers(kind)` for `harm`, `friend`, `resurrect`, `pet` and `interact`.
- A built-in candidate list per class (spell IDs from LibRangeCheck-3.0, MIT; no code), filtered by `C_SpellBook.IsSpellInSpellBook`; minimum-range spells joined with a closer checker; melee spells left out.
- In combat, interact checks are skipped for units the player cannot attack, on every flavour.
- `RangeKit:OnCheckersChanged(callback)` with `Disconnect` and `IsConnected`, called after a rebuild on `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE`, `PLAYER_TALENT_UPDATE`, `CHARACTER_POINTS_CHANGED` or the player's `UNIT_PET` changed a list; `SetLimits` and `GetLimits` for `maxListeners` (32, up to 256).
- 41 specs, and a client suite, `tests/client/MoltenCodesTest_RangeKit`, not yet run in a client.
