# Changelog

## 0.1.0 — 2026-11-15

- Added EditModeKit API generation 1, implementation revision 1: Edit Mode integration, as recorded in `docs/ROADMAP.md` (package M).
- `EditModeKit:Register(frame, storage, options?)` with `label`; `EditModeKit:IsEditing`, `EditModeKit:GetLayoutName`; `SetLimits` and `GetLimits` for `maxRegistrations` (64, up to 256).
- A registration: `Unregister`, `Refresh`, `GetFrame`. Each frame gets an overlay shown while Edit Mode is open that drags it; its centre offset from `UIParent`'s centre is saved per Edit Mode layout and put back on `EDIT_MODE_LAYOUTS_UPDATED`. Moves of protected frames in combat wait for `PLAYER_REGEN_ENABLED`.
- 28 specs, and a client suite, `tests/client/MoltenCodesTest_EditModeKit`, not yet run in a client.
