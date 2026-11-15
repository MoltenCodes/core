# Changelog

## 0.1.1 — 2026-11-15

- Fixed: a drag still under way when its frame was unregistered, or when Edit Mode closed, never ended. `Unregister` forgot the overlay, so its `OnDragStop` found no registration, and closing Edit Mode hid the overlay; `StartMoving` acts on the frame itself, so the frame kept following the cursor. `Unregister` now stops the drag where the frame is without saving it, and closing Edit Mode ends it as `OnDragStop` does, saving the position under the active layout. Specs: `EditMode_spec.lua` ("ends a drag that is still under way when the frame is unregistered", "... when Edit Mode closes, saving where it ended"), `Bootstrap_spec.lua` ("upgrades revision 1 in place: a drag under way ends when its frame is unregistered").
- Fixed: a drag left the frame flagged as user-placed. `StartMoving` sets that flag (warcraft.wiki.gg, API `Frame:StartMoving`), and the client restores a named user-placed frame from its layout cache at the next login, over the position EditModeKit saved for the active Edit Mode layout. A drag now clears it with `SetUserPlaced(false)` when the frame has the method. Spec: `EditMode_spec.lua` ("keeps a dragged frame out of the client's layout cache").
- `docs/API.md` lists every error message.
- The README no longer says a drag of a protected frame in combat waits for the end of combat: it does not start, as `docs/API.md` says.
- Implementation revision 2. No state changed; the registrations, overlays and listeners of revision 1 are kept, and their scripts run the new code through the shared dispatch table. 32 specs.

## 0.1.0 — 2026-11-15

- Added EditModeKit API generation 1, implementation revision 1: Edit Mode integration, as recorded in `docs/ROADMAP.md` (package M).
- `EditModeKit:Register(frame, storage, options?)` with `label`; `EditModeKit:IsEditing`, `EditModeKit:GetLayoutName`; `SetLimits` and `GetLimits` for `maxRegistrations` (64, up to 256).
- A registration: `Unregister`, `Refresh`, `GetFrame`. Each frame gets an overlay shown while Edit Mode is open that drags it; its centre offset from `UIParent`'s centre is saved per Edit Mode layout and put back on `EDIT_MODE_LAYOUTS_UPDATED`. Moves of protected frames in combat wait for `PLAYER_REGEN_ENABLED`.
- 28 specs, and a client suite, `tests/client/MoltenCodesTest_EditModeKit`, not yet run in a client.
