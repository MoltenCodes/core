# Changelog

## 0.1.1 — 2026-11-15

- Fixed `LauncherKit:SetLimits` taking `maxLaunchers` through the limits table's metatable. The check loop read the table's own fields with `pairs`, but the value was then read with a plain index, so a table whose `__index` answered `maxLaunchers` set a limit that was never checked, past the ceiling of 256 included, and the next load refused the state as corrupted. The value is now read with `rawget`, like the check. Implementation revision 2; a revision 1 state is upgraded in place.
- The client suite's secret test no longer calls `Register` as a tail call, which in Lua 5.1 drops the frame the error is reported at, so the message would have had no file and line to find; its `GetMinimapShape` probe is called protected.
- `docs/API.md`: every argument error message of `Register`, `Get` and `SetLimits`; the AddonCompartment entry table and the callback signature Blizzard calls, with its source; a drag that never moved writes nothing.
- 41 specs.

## 0.1.0 — 2026-11-15

- Added LauncherKit API generation 1, implementation revision 1: minimap buttons for BrokerKit objects, as recorded in `docs/ROADMAP.md` (package M).
- `LauncherKit:Register(objectName, storage)` puts the object's icon on the minimap's edge, round or following `GetMinimapShape`, with its state in LibDBIcon's field names (`minimapPos`, `hide`, `lock`) in a table or a function returning one; `LauncherKit:Get`; `LauncherKit:AddToCompartment` for Retail's addon compartment (`nil, "unavailable"` elsewhere, `nil, "already"` the second time); `SetLimits` and `GetLimits` for `maxLaunchers` (64, up to 256).
- A launcher: `Show`, `Hide`, `IsShown`, `Lock`, `Unlock`, `IsLocked`, `Refresh`, `GetButton`. Dragging saves the angle when it stops; a locked button does not move. Clicks, tooltips and icon changes come from the object; a callback that raises is reported.
- 39 specs, and a client suite, `tests/client/MoltenCodesTest_LauncherKit`, not yet run in a client.
