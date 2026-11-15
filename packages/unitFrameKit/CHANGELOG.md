# Changelog

## 0.1.1 — 2026-11-15

- Fixed: Blizzard's `PetFrame` and `FocusFrameToT` matched no pattern, so they ranked as another addon's frames, ahead of Blizzard's own, and answered every token naming their unit: `GetUnitFrame("party1")` answered `FocusFrameToT` before Blizzard's party frame while the focus targeted `party1`. Both are now listed as Blizzard's frames without a kind and answer, after every Blizzard kind, only for their own token (`pet`, and the focus's target) and only without `kinds`.
- Fixed: a frame Retail's `CanBeAccessedInContext` refuses was read like any other; a read that raised dropped the whole scan, so one such frame kept every frame out of the cache. Such a frame (or an unnamed frame whose parent is one) is now skipped, as are kept frames and nameplates refused at query time; a secret answer counts as a refusal.
- Implementation revision 2; a revision 1 copy upgrades in place.
- Documentation: every error message, the access check, the two Blizzard rows of the pattern table and the fifth rank band.
- 68 specs.

## 0.1.0 — 2026-11-15

- Added UnitFrameKit API generation 1, implementation revision 1: the unit frame shown for a unit, as recorded in `docs/ROADMAP.md` (unitFrameKit, core decision 16).
- `UnitFrameKit:GetUnitFrame(unit, options?)` and `GetUnitFrames(unit, options?)` with `kinds`, `priorities` and `ignore`; `GetNamePlate(unit)`; `Rescan`, `IsScanning`; `OnChange(callback)` with `(frame, unit, previousUnit)` and a connection (`Disconnect`, `IsConnected`); `GetKindPatterns(kind)`; `SetLimits` and `GetLimits` for `maxFrames` (512, up to 4096), `scanFramesPerStep` (400, up to 4000) and `maxListeners` (64, up to 512).
- Scans walk `EnumerateFrames` a slice per client frame, one second after roster, zone, combat, boss and pet events; queries rank the caller's patterns, other addons' frames (ElvUI, Cell, Grid2 and Shadowed Unit Frames, each checked in its own source), frames without a kind, then Blizzard's.
- 65 specs, and a client suite, `tests/client/MoltenCodesTest_UnitFrameKit`, not yet run in a client.
