# Changelog

## 0.1.0 — 2026-11-15

- Added RangeKit API generation 1, implementation revision 1: unit range estimates, as recorded in `docs/ROADMAP.md` (rangeKit, core decision 16).
- `RangeKit:GetRange(unit)` brackets the distance in yards from the player's own spells (`C_Spell.IsSpellInRange`, reach from `C_Spell.GetSpellInfo`) and `CheckInteractDistance` (7 and 28 yards); `RangeKit:IsInRange(unit, yards)`; `RangeKit:DescribeCheckers(kind)` for `harm`, `friend`, `resurrect`, `pet` and `interact`.
- A built-in candidate list per class (spell IDs from LibRangeCheck-3.0, MIT; no code), filtered by `C_SpellBook.IsSpellInSpellBook`; minimum-range spells joined with a closer checker; melee spells left out.
- In combat, interact checks are skipped for units the player cannot attack, on every flavour.
- `RangeKit:OnCheckersChanged(callback)` with `Disconnect` and `IsConnected`, called after a rebuild on `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE`, `PLAYER_TALENT_UPDATE`, `CHARACTER_POINTS_CHANGED` or the player's `UNIT_PET` changed a list; `SetLimits` and `GetLimits` for `maxListeners` (32, up to 256).
- 41 specs, and a client suite, `tests/client/MoltenCodesTest_RangeKit`, not yet run in a client.
