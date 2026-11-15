# Changelog

## 0.1.0 — 2026-11-15

- Added UnitFrameKit API generation 1, implementation revision 1: the unit frame shown for a unit, as recorded in `docs/ROADMAP.md` (unitFrameKit, core decision 16).
- `UnitFrameKit:GetUnitFrame(unit, options?)` and `GetUnitFrames(unit, options?)` with `kinds`, `priorities` and `ignore`; `GetNamePlate(unit)`; `Rescan`, `IsScanning`; `OnChange(callback)` with `(frame, unit, previousUnit)` and a connection (`Disconnect`, `IsConnected`); `GetKindPatterns(kind)`; `SetLimits` and `GetLimits` for `maxFrames` (512, up to 4096), `scanFramesPerStep` (400, up to 4000) and `maxListeners` (64, up to 512).
- Scans walk `EnumerateFrames` a slice per client frame, one second after roster, zone, combat, boss and pet events; queries rank the caller's patterns, other addons' frames (ElvUI, Cell, Grid2 and Shadowed Unit Frames, each checked in its own source), frames without a kind, then Blizzard's.
- 65 specs, and a client suite, `tests/client/MoltenCodesTest_UnitFrameKit`, not yet run in a client.
