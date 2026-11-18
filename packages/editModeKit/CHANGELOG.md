# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that itself raises (an error-display addon with a bug) made the failure EditModeKit was reporting raise again into whatever the client was running. `reportError` now calls the handler through `pcall` and prints the failure when the handler is missing or raises.
- `isSecret`, `reportError` and `validateFacade` are now the shared helper blocks (`tooling/shared/lua/`, kept in step by `python3 -m tooling.shared.sync`). The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 3; an embedded revision 2 is upgraded in place, its state kept.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the raising error handler, the facade message, the upgrade over the committed revision 2 file in `tests/fixtures/EditModeKit-revision2.lua`) and `Conformance_spec.lua` (the repository's conformance suite; pending: limits (its unknown-limit refusal does not name the key) and arguments (no secret refusal says "secret"), see the spec).

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
