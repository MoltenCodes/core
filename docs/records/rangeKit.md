# rangeKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## rangeKit

**rangeKit** — facade `RangeKit`

1. Package `rangeKit`, facade `RangeKit`, API generation 1, version 0.1.0,
   implementation revision 1.
2. Purpose: an estimate of how far a unit is from the player, in whole
   yards, and whether it is within a given distance: what
   LibRangeCheck-3.0 gives unit frames, nameplates and range displays. The
   client has no distance query for arbitrary units, so the estimate comes
   from yes-or-no checks of known reach, sorted by range: the player's own
   spells (`C_Spell.IsSpellInRange`, their reach read from
   `C_Spell.GetSpellInfo` `minRange`/`maxRange`, never hard-coded) and the
   interact distances of `CheckInteractDistance` (index 3, 7 yards, and
   index 4, 28 yards, as warcraft.wiki.gg documents them). A small built-in
   list per class names candidate spell IDs in four kinds, `harm`, `friend`,
   `resurrect` and `pet`; only those `C_SpellBook.IsSpellInSpellBook` reports
   are used, so one list serves every flavour and a spell missing from a
   flavour simply drops out. The unit's kind picks the list: attackable
   (`UnitCanAttack`), dead and assistable (`resurrect`), the pet (`pet`, then
   `friend`), assistable (`friend`), anything else interact distances only.
   A spell with a minimum range counts as in range when the client says so
   or when a checker at or below that minimum says the unit is closer;
   without such a checker it is left out. Spells whose `maxRange` is 0
   (melee) are left out, since melee reach depends on both units' combat
   reach, which the client does not expose. The checkers are rebuilt when
   the spellbook or talents change, and listeners hear when the lists
   change. The client refuses `CheckInteractDistance` from addon code in
   combat for units the player cannot attack (protected by the 10.2.0
   hotfix of 2023-11-16, enemy units allowed again by the hotfix of
   2023-12-11); the Kit skips interact checkers for such units while
   `InCombatLockdown()` is true, on every flavour. Non-goals: item-based
   checkers (`C_Item.IsItemInRange`: the same combat refusal, item data that
   must be requested from the server, and large per-flavour item lists),
   race-specific interact distances, `UnitInRange` (group members only, a
   single 40-yard answer, and secret on Retail), `UnitDistanceSquared`,
   a result cache (a call is a handful of client checks; callers throttle),
   handing out checker functions, and action-bar range
   (`C_ActionBar.IsActionInRange`).
3. Dependencies: registry API 2 only. EventKit is not used: one event frame
   of the package's own listens to a few events, as EditModeKit does. Host
   requirement: `CreateFrame`, `UnitClass`, `UnitExists`, `UnitCanAttack`,
   `UnitCanAssist`, `UnitIsDeadOrGhost`, `InCombatLockdown`,
   `C_Spell.GetSpellInfo`, `C_Spell.IsSpellInRange`,
   `C_SpellBook.IsSpellInSpellBook` and `Enum.SpellBookSpellBank`, all
   present on Retail 12.1.5, Mists of Pandaria Classic 5.5.4 and Classic Era
   1.15.9 (apiKit's generated tables of the 2026-11-14 captures;
   `UnitIsDeadOrGhost` is not in the Classic generated docs but Blizzard's
   own `CompactUnitFrame.lua` on `classic_era` calls it). Without them
   `GetRange` and `IsInRange` answer `nil`. `CheckInteractDistance` is
   optional (no interact checkers without it). The rebuild events are
   registered only when `C_EventUtils.IsEventValid` accepts them:
   `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE`, `PLAYER_TALENT_UPDATE`,
   `CHARACTER_POINTS_CHANGED` (all four in the generated docs of all three
   flavours) and `UNIT_PET` for the player (pet spells).
   `LEARNED_SPELL_IN_TAB` is not in any of the three captures and is not
   used.
4. Surface: `RangeKit:GetRange(unit)` → `minRange, maxRange` in yards
   (`nil, nil` when the unit does not exist or no checker answers;
   `maxRange` `nil` when the unit is beyond the longest checker; `0` as
   `minRange` when the shortest checker says in range);
   `RangeKit:IsInRange(unit, yards)` → `true` when `maxRange <= yards`,
   `false` when `minRange >= yards`, `nil` when the estimate cannot decide;
   `RangeKit:DescribeCheckers(kind)` → a fresh array of
   `{ range, minRange, source }` (`source` such as `"spell:589"` or
   `"interact:4"`) for `"harm"`, `"friend"`, `"resurrect"`, `"pet"` or
   `"interact"`; `RangeKit:OnCheckersChanged(callback)` → connection
   (`connection:Disconnect()`, `connection:IsConnected()`), called with no
   arguments after a rebuild that changed any list;
   `SetLimits{ maxListeners }` / `GetLimits()`. A unit token that is not a
   string, or a secret value, raises at the caller; a client answer that is
   a secret value counts as no answer.
5. Ownership: the checker lists belong to the Kit, built at the first query
   and rebuilt (and compared) on each rebuild event; nothing is kept per
   unit. A connection belongs to its caller until `Disconnect`; a listener
   that raises is reported through `geterrorhandler()` and the others still
   run. An upgraded revision takes over the event frame and the listeners
   through the stable closures in `_state`.
6. Performance and memory: nothing runs per frame and no timer runs.
   `GetRange` makes `UnitExists`, `UnitCanAttack`, `UnitCanAssist`,
   `UnitIsDeadOrGhost` and `InCombatLockdown` calls plus a binary search of
   the sorted list (at most four range checks for 16 entries, a `nil`
   answer counted as out of range) and allocates nothing. A rebuild walks
   the class's candidate list (at most 16 spells per kind) once. Each kind
   holds at most 16 checkers plus the two interact entries; duplicate
   ranges keep the first. `maxListeners` defaults to 32 with a ceiling of
   256 and no `UNBOUNDED`.
7. Tests: stand-ins for the spell, spellbook, unit and interact functions,
   `InCombatLockdown` and the events; lists built per kind from known spells
   only and sorted, ranges rounded, a duplicate range dropped, melee spells
   left out, a minimum-range spell joined with a closer checker and left out
   without one; `GetRange` brackets at both ends and between checkers, each
   unit kind picking its list, a dead friendly unit, a missing unit;
   interact checkers skipped in combat for a non-attackable unit and kept for
   an attackable one; `IsInRange` true, false and undecided; rebuild on each
   event with listeners called only on a change, a raising listener
   isolated, disconnecting; missing host functions; limits and ceilings;
   secret arguments and secret client answers; upgrade; manifest; error
   levels. A client suite on Retail: the player's target bracketed by
   `GetRange` while walking away, and the lists rebuilt after a talent
   change.
8. Docs: README (with the migration table from LibRangeCheck-3.0:
   `GetRange`, the `Get*Checker` family to `IsInRange`, `CHECKERS_CHANGED`
   to `OnCheckersChanged`, what is not carried over: items, `checkVisible`,
   `noItems`, `maxCacheAge`), API.md (the per-class candidate list with its
   source, the combat rule, the yard values), CHANGELOG, tests/README;
   EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 16, 0.1.0, revision
   1, 41 specs; the client suite (`tests/client/MoltenCodesTest_RangeKit`)
   is written and has not been run in a client. Deviations from the points
   above: a spell with a minimum range is joined with a checker, without a
   minimum of its own, whose range lies from that minimum up to the spell's
   range (a checker below the minimum would leave a gap); the pet list holds
   the pet spells and the friend spells together; at equal range a spell is
   kept over an interact checker, since it stays usable in combat; no cap on
   checkers in code, because the built-in data holds at most four spells per
   kind; without the spell functions RangeKit still answers from interact
   checks (`nil` only without `UnitExists`); the event frame is made at
   load, or at the first query when `CreateFrame` appears later.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 43 specs
   (a change of a spell's minimum range alone now notifies listeners).

Candidate spell IDs (the built-in list; reach is read from the client).
Taken from LibRangeCheck-3.0 minor 39 (MIT), which the Kit's code does not
copy; spells absent from a flavour or from the player's spellbook drop out:

| Class | `harm` | `friend` | `resurrect` | `pet` |
|---|---|---|---|---|
| Death Knight | 49576, 47541 | | 61999 | |
| Demon Hunter | 185123, 183752 | | | |
| Druid | 5176, 8921, 339, 33786 | 8936, 774, 5185 | 50769, 20484 | |
| Evoker | 362969 | 361469, 355913 | 361227 | |
| Hunter | 75, 466930, 2764 | | | 136 |
| Mage | 133, 116, 118, 5019 | 1459, 475 | | |
| Monk | 117952, 115546, 115078 | 116670, 115450 | 115178 | |
| Paladin | 20271, 62124, 853, 20473 | 19750, 635, 85673 | 7328 | |
| Priest | 589, 585, 8092, 5019 | 2061, 2050, 17, 527 | 2006 | |
| Rogue | 2094, 921, 185565, 2764 | | | |
| Shaman | 403, 188196, 370, 8042 | 331, 8004, 546 | 2008 | |
| Warlock | 686, 5782, 172, 5019 | 5697 | 20707 | 755 |
| Warrior | 355, 100, 5246, 2764 | | | |

