# Changelog

## 0.1.0 — 2026-11-15

- Added LauncherKit API generation 1, implementation revision 1: minimap buttons for BrokerKit objects, as recorded in `docs/ROADMAP.md` (package M).
- `LauncherKit:Register(objectName, storage)` puts the object's icon on the minimap's edge, round or following `GetMinimapShape`, with its state in LibDBIcon's field names (`minimapPos`, `hide`, `lock`) in a table or a function returning one; `LauncherKit:Get`; `LauncherKit:AddToCompartment` for Retail's addon compartment (`nil, "unavailable"` elsewhere, `nil, "already"` the second time); `SetLimits` and `GetLimits` for `maxLaunchers` (64, up to 256).
- A launcher: `Show`, `Hide`, `IsShown`, `Lock`, `Unlock`, `IsLocked`, `Refresh`, `GetButton`. Dragging saves the angle when it stops; a locked button does not move. Clicks, tooltips and icon changes come from the object; a callback that raises is reported.
- 39 specs, and a client suite, `tests/client/MoltenCodesTest_LauncherKit`, not yet run in a client.
