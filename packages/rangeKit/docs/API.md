# RangeKit API

RangeKit API generation **1** estimates the distance from the player to a unit in whole yards, and whether the unit is within a given distance, from the player's own spells and the client's interact distances.

Implementation revision: **2** (package version 0.1.1).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
RangeKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local RangeKit = MoltenCodes.Registries[2]:Get("rangeKit", 1)
```

RangeKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame` | the event frame for the rebuild events | No rebuild on events; the frame is made at the first query once `CreateFrame` exists. |
| `C_EventUtils.IsEventValid` | which rebuild events to register | Every rebuild event is registered. |
| `UnitClass` | the player's candidate spells | No spell checkers; interact checkers only. |
| `C_SpellBook.IsSpellInSpellBook`, `C_Spell.GetSpellInfo`, `Enum.SpellBookSpellBank` | which candidates the player has, and their reach | No spell checkers. |
| `C_Spell.IsSpellInRange` | the spell checks | Every spell check answers no. |
| `CheckInteractDistance` | the interact checks | No interact checkers. |
| `UnitExists` | `GetRange`, `IsInRange` | Every unit counts as missing: `nil`. |
| `UnitCanAttack`, `UnitCanAssist`, `UnitIsDeadOrGhost`, `UnitIsUnit` | choosing the list for a unit | The answer counts as no. |
| `InCombatLockdown` | the combat rule | Never in combat. |
| `issecretvalue` | every check, every value the client answers | Nothing is treated as secret. |
| `geterrorhandler` | listener failures | They are printed. |

Every call above is in the generated client documentation of Retail 12.1.5, Mists of Pandaria Classic 5.5.4 and Classic Era 1.15.9, except `UnitIsDeadOrGhost`, which Blizzard's own `CompactUnitFrame.lua` calls on Classic Era. `IsPlayerSpell` and `IsSpellKnown` are only deprecation fallbacks over `C_SpellBook` on every flavour and are not used.

## Public surface

| Member | Purpose |
|---|---|
| `GetRange(unit)` | `minRange, maxRange` in yards. |
| `IsInRange(unit, yards)` | `true`, `false`, or `nil` when the estimate cannot decide. |
| `DescribeCheckers(kind)` | A fresh array describing the checkers of `kind`, shortest first. |
| `OnCheckersChanged(callback)` | Call `callback()` after each rebuild that changed a list. Returns a connection. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxListeners`; `GetLimits` returns a fresh table. |
| `MAX_LISTENERS`, `LISTENERS_CEILING` | `32`, `256`. |
| `API`, `REVISION` | `1`, `2`. |

A connection:

| Method | Purpose |
|---|---|
| `Disconnect()` | Stop the listener: `true`, or `false` when it already was. |
| `IsConnected()` | Whether the listener is still connected. |

## `RangeKit:GetRange(unit)`

`unit` is a unit token string (`"target"`, `"party1"`, `"nameplate3"`). The answer:

| Answer | Meaning |
|---|---|
| `nil, nil` | The unit does not exist, or no checker applies to it (for instance in combat, a friendly unit and no friendly spell). |
| `0, max` | The shortest checker says the unit is within `max` yards. |
| `min, max` | The unit is farther than `min` and within `max` yards. |
| `min, nil` | The unit is farther than the longest checker, `min` yards. |

A check that gives no answer (an invalid target, a spell the client cannot check) counts as "out of range", as LibRangeCheck-3.0 does.

## `RangeKit:IsInRange(unit, yards)`

`yards` is a finite number of at least 0. The answer is `true` when the estimate's `maxRange` is at most `yards`, `false` when its `minRange` is at least `yards`, and `nil` otherwise, or when `GetRange` has no estimate. Asking for a distance a checker of the searched list answers for exactly always decides. Out of combat, and in combat for a unit the player can attack, that is every range `DescribeCheckers` lists; in combat for any other unit the interact ranges (7 and 28 yards) and spells joined to an interact checker are not searched, so asking for those distances may answer `nil`.

## Checkers

A checker answers yes or no for one range:

- a **spell** checker asks `C_Spell.IsSpellInRange(spellID, unit)`; its range is `C_Spell.GetSpellInfo(spellID).maxRange`, rounded to whole yards;
- an **interact** checker asks `CheckInteractDistance(unit, index)`: index 3 (Duel) for 7 yards and index 4 (Follow) for 28 yards, as warcraft.wiki.gg documents them. Race-specific distances are not used.

Each kind's list holds its spell checkers and the two interact checkers, sorted by range; of two checkers with the same range the first one stays, a spell before an interact checker. A spell whose `maxRange` is 0 (melee) is left out: its reach depends on both units' combat reach, which the client does not expose.

A spell with a minimum range (`minRange` above 0) says "out of range" for a unit too close. It is joined with a closer checker, one without a minimum range whose range lies from the spell's minimum to its range, and counts as "in range" when either says so. A closer spell checker is preferred; with only an interact checker the joined checker is skipped in combat on units the player cannot attack; with neither, the spell is left out. A spell whose minimum is not below its range is left out.

`GetRange` searches the list by halves: being in range of one checker means being in range of every longer one, so a list of six checkers, the longest the built-in data makes, takes at most three checks.

### Kinds and units

| Kind | Holds | Used for |
|---|---|---|
| `harm` | the class's `harm` spells | a unit the player can attack (`UnitCanAttack("player", unit)`) |
| `friend` | the class's `friend` spells | a unit the player can assist (`UnitCanAssist`) |
| `resurrect` | the class's `resurrect` spells | a dead or ghost unit the player can assist |
| `pet` | the class's `pet` spells and its `friend` spells | the player's pet (`"pet"`, or `UnitIsUnit(unit, "pet")`) |
| `interact` | the interact checkers only | any other unit, and a dead unit the player cannot assist |

Every kind also holds the two interact checkers.

### Candidate spells

The candidates per class are taken from LibRangeCheck-3.0 minor 39 (MIT, Copyright (c) 2023 The WoWUIDev Community, https://github.com/WeakAuras/LibRangeCheck-3.0), read on 2026-11-15; none of its code is used. A spell is used only when `C_SpellBook.IsSpellInSpellBook(spellID, Enum.SpellBookSpellBank.Player, true)` reports it, so IDs of every flavour sit side by side and the ones a character lacks drop out. The order within a kind decides which spell stays when two share a range.

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

On 2026-11-15 every ID above was compared with LibRangeCheck-3.0 minor 39, still the newest upstream minor that day; each one is in its lists for the same class and kind. They have not been checked against a second source (the public spell databases tried refuse automated reads). A wrong ID only removes one checker, because its reach comes from the client.

## `RangeKit:DescribeCheckers(kind)`

`kind` is `"harm"`, `"friend"`, `"resurrect"`, `"pet"` or `"interact"`. The answer is a fresh array of fresh tables, shortest first: `{ range = 30, source = "spell:5019" }`, `{ range = 25, minRange = 8, source = "spell:100" }`, `{ range = 28, source = "interact:4" }`. It lists every checker of the kind, including those the combat rule skips.

## Combat

The client refuses `CheckInteractDistance` (and `IsItemInRange`) from addon code in combat for units the player cannot attack: protected by the patch 10.2.0 hotfix of 2023-11-16, with enemy units allowed again by the hotfix of 2023-12-11 (warcraft.wiki.gg). Whether Mists of Pandaria Classic and Classic Era do the same is not documented, so on every flavour, while `InCombatLockdown()` answers `true` and the unit is not attackable, `GetRange` and `IsInRange` search the kind's checkers without the interact checks (and without spells joined to one). Spell checks are never restricted.

## Rebuilds and listeners

The lists are built at the first query and rebuilt on `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE`, `PLAYER_TALENT_UPDATE`, `CHARACTER_POINTS_CHANGED` and `UNIT_PET` for the player, each registered only when `C_EventUtils.IsEventValid` agrees (all five are in the generated documentation of the three promised flavours). `LEARNED_SPELL_IN_TAB` is in none of them and is not used.

A rebuild that changed any list (a checker added, removed or reordered, or a checker's range or minimum range changed), the first build included, calls every connected listener with no arguments, in connection order. A listener that raises is handed to `geterrorhandler()` and the others still run; one disconnected during the notification is not called. A rebuild that changed nothing calls nobody.

## Secret values

Every unit, distance, kind, callback, limit and receiver is checked with `issecretvalue` first and refused at the caller. A client answer that is a secret value counts as no answer: a secret `IsSpellInRange` or `CheckInteractDistance` answer as "out of range", a secret `UnitExists` as a missing unit, a secret relation or combat answer as no, and a secret class, spellbook answer, spell bank, spell description or range as an unusable spell. The Retail 12.1.5 documentation marks none of the range checks RangeKit uses as secret; it marks `UnitInRange`, which RangeKit does not use.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxListeners`, listeners connected at once | `32` | `RangeKit:SetLimits({ maxListeners = n })` | no | `256`: each holds a caller's closure for the session |

Past the limit `OnCheckersChanged` raises at the caller: `RangeKit:OnCheckersChanged holds at most 32 listeners; raise maxListeners with RangeKit:SetLimits`. Lowering it keeps every connection and refuses the next. The limit is shared by every addon in the session. The checker lists need no limit: the built-in data gives each kind at most four spells besides the two interact checkers.

## Error behaviour

Argument errors raise at the caller's line. A secret value is refused with the same message as a wrong type, except for the limit value, which names it. The messages:

| Message | When |
|---|---|
| `RangeKit:<Method> must be called on the RangeKit facade; use RangeKit:<Method>(...)` | A method called with `.` or on another table. |
| `RangeKit:GetRange unit must be a unit token string` (and `RangeKit:IsInRange ...`) | `unit` is not a non-empty string, or is secret. |
| `RangeKit:IsInRange yards must be a finite number of at least 0` | `yards` is not a number, is NaN, negative, infinite or secret. |
| `RangeKit:DescribeCheckers kind must be harm, friend, resurrect, pet or interact` | Any other `kind`. |
| `RangeKit:OnCheckersChanged callback must be a function` | `callback` is not a function, or is secret. |
| `RangeKit:OnCheckersChanged holds at most <n> listeners; raise maxListeners with RangeKit:SetLimits` | `maxListeners` listeners are already connected. |
| `RangeKit:SetLimits limits must be a table` | `limits` is not a table. |
| `RangeKit:SetLimits limits holds an unknown field; it accepts maxListeners` | Any other key, or a secret key. |
| `RangeKit:SetLimits limits.maxListeners must not be a secret value` | A secret limit. |
| `RangeKit:SetLimits limits.maxListeners must be an integer from 1 to 256` | Any other limit value. |
| `RangeKit.Connection:Disconnect must be called on a RangeKit connection; use connection:Disconnect(...)` (and `IsConnected`) | A connection method called on anything but a connection handle. |

At load, `MoltenCodes RangeKit requires Registry API 2 to be loaded first`, `MoltenCodes RangeKit requires a valid Registry API 2 facade` and `MoltenCodes RangeKit package state is corrupted or incomplete` raise at the loading file. What the client calls (the events) never raises; a listener's error goes to `geterrorhandler()`.

## Performance

| Path | Cost |
|---|---|
| `GetRange`, `IsInRange` | At most six unit or combat queries and three range checks (a joined checker may ask twice); no allocation. |
| `DescribeCheckers` | One fresh table per checker and one for the array. |
| A rebuild event | One spellbook query and one spell description per candidate (at most 13, for a priest); a notification only on a change. |
| Idle | Nothing: no timer, no `OnUpdate`. |

## Embedded copies and upgrades

Several addons may embed RangeKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the lists, the listeners, the event frame and the limit. The event frame's script calls through a dispatch table in the shared state that every loading revision rewrites, so events reach the newest copy's code. The event frame is made once per session.

Revision 2 changed no state field: a revision 1 copy upgrades in place, and its lists, listeners, event frame and limit are kept. From then on a rebuild that changes only a checker's minimum range notifies the listeners (revision 1 compared only ranges and sources).
