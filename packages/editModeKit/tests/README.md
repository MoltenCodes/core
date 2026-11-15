# EditModeKit Tests

The EditModeKit suite covers:

- Edit Mode: the labelled overlay over its frame, 20 levels above, shown only while Edit Mode is open, also for a frame registered while it is; a drag saving the centre offset under the active layout; each layout's position put back on a layout switch, a layout without one leaving the frame alone; positions put back at `Register` and on `Refresh` in the frame's scale; a storage function, one that raises and one that returns no table, reported; a protected frame in combat kept in place and moved when combat ends; unregistering once and the overlay reused; the `"default"` layout without the client's manager; `maxRegistrations`;
- arguments and secrets: every argument failure reported at the caller's line, secret frames, storage, options, limits and receivers refused, secret names, layouts, positions, scales and combat answers ignored, a manager that raises, a storage table that refuses the write, stray drags, and a host without `CreateFrame`, `UIParent` or `EventRegistry`;
- Registry publication, a duplicate embedded load keeping frames, yielding to a newer revision, an in-place upgrade where callbacks, events, drags and the limit run the new code, Edit Mode already open at the first listen, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/EditModeKitTestEnv.lua` provides `UIParent` (1920 x 1080), stand-ins for `EventRegistry` and `EditModeManagerFrame` with `EnterEditMode`, `ExitEditMode` and `SwitchLayout`, `SetCombat` and `EndCombat`, `FrameAt` (a frame on the screen), `Run` (a frame's script), the secret probe and `LoadRevision`. Specs reach a registration's overlay through its record.

| Spec | Covers |
|---|---|
| `EditMode_spec.lua` | overlays, drags, layouts, storage, combat, unregistering, the limit |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, failures, a missing host |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
