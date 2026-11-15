# RangeKit

RangeKit estimates how far a unit is from the player, in whole yards, and whether it is within a given distance: what LibRangeCheck-3.0 gives unit frames, nameplates and range displays.

```lua
local RangeKit = MoltenCodes.Registries[2]:Get("rangeKit", 1)

local minRange, maxRange = RangeKit:GetRange("target")
if not minRange then
  -- no estimate: the unit does not exist, or nothing can check it
elseif not maxRange then
  print("target is over " .. minRange .. " yards away")
else
  print("target is " .. minRange .. " to " .. maxRange .. " yards away")
end

if RangeKit:IsInRange("party1", 40) then
  -- party1 is within 40 yards
end

-- Stored checker descriptions go stale when the player's spells change.
local connection = RangeKit:OnCheckersChanged(function()
  MyAddon:RefreshRangeText()
end)
```

What each piece promises:

- **Checks the client already answers.** The client has no distance query for an arbitrary unit, so the estimate brackets the distance with yes-or-no checks: the player's own spells (`C_Spell.IsSpellInRange`, their reach read from `C_Spell.GetSpellInfo`) and the interact distances of `CheckInteractDistance` (7 and 28 yards).
- **One list for every flavour.** A short built-in list per class names candidate spells; only those the player's spellbook reports are used, so a spell a flavour or a character lacks simply drops out. Nothing about ranges is hard-coded.
- **Combat-safe.** The client refuses `CheckInteractDistance` from addon code in combat for units the player cannot attack. RangeKit skips those checks for such units in combat, on every flavour, and answers from spells alone.
- **Secret values respected.** A unit, distance or kind that is a secret value is refused at the caller; a client answer that is secret counts as no answer.
- **Nothing per frame.** No timer and no `OnUpdate`. A `GetRange` call makes at most a handful of range checks (a binary search over a short sorted list) and allocates nothing. The lists are rebuilt when the spellbook, talents or pet change.
- **Bounded.** At most 32 change listeners, up to 256 with `RangeKit:SetLimits({ maxListeners = n })`.

Non-goals: item-based checks, race-specific interact distances, `UnitInRange` (group members only, one 40-yard answer, secret on Retail), `UnitDistanceSquared`, a result cache (callers throttle), handing out checker functions, action-bar range.

### Moving from LibRangeCheck-3.0

| LibRangeCheck-3.0 | RangeKit |
|---|---|
| `rc:GetRange(unit)` | `RangeKit:GetRange(unit)`: the same `minRange, maxRange` shape, `maxRange` `nil` beyond the longest check. |
| `rc:GetRange(unit, checkVisible)` | Not carried over: test `UnitIsVisible(unit)` first if you need it. |
| `rc:GetRange(unit, nil, noItems)` | Not needed: RangeKit never uses items. |
| `rc:GetRange(unit, nil, nil, maxCacheAge)` | Not carried over: there is no cache; call less often instead. |
| `rc:GetFriendMaxChecker(range)`, `GetHarmMaxChecker`, `GetSmartMaxChecker` and the rest of the `Get*Checker` family | `RangeKit:IsInRange(unit, range)`: `true`, `false`, or `nil` when the estimate cannot decide. |
| `rc:GetFriendCheckers()` and the other iterators | `RangeKit:DescribeCheckers(kind)`: a fresh array of `{ range, minRange, source }`. |
| `rc.RegisterCallback(self, rc.CHECKERS_CHANGED, func)` | `local connection = RangeKit:OnCheckersChanged(func)`; `connection:Disconnect()`. |
| `rc.MeleeRange` | No equivalent: melee spells are left out, because melee reach depends on both units' combat reach. |
| Item checkers (`FriendItems`, `HarmItems`) | Not carried over: the same combat refusal, item data the server must send first, and long per-flavour lists. |

The estimates differ in detail: RangeKit has no item checks and no race overrides, so its brackets are wider between the spell ranges.

See [`docs/API.md`](docs/API.md) for the complete contract, the candidate spell table and its source.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\rangeKit\RangeKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `rangeKit/RangeKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

RangeKit makes one event frame at load and builds its lists at the first query.
