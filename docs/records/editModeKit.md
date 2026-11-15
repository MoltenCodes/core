# editModeKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## editModeKit

**editModeKit** — facade `EditModeKit`

1. Package `editModeKit`, facade `EditModeKit`, API generation 1.
2. Purpose: an addon's frames take part in Blizzard's Edit Mode, what
   LibEditMode gives addons on Retail: while Edit Mode is open, each
   registered frame shows a labelled selection overlay that drags the frame,
   and its position is saved per Edit Mode layout and put back when the
   player switches layout. Edit Mode, its `EventRegistry` events
   (`EditMode.Enter`, `EditMode.Exit`), `C_EditMode` and the event
   `EDIT_MODE_LAYOUTS_UPDATED` exist on Retail, Mists of Pandaria Classic
   and Classic Era alike (Blizzard's `Blizzard_EditMode`, branches `live`,
   `classic` and `classic_era`, read 2026-11-15). Non-goals: Blizzard's
   own Edit Mode systems and settings dialog, snapping and grids, frame
   settings other than the position.
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `UIParent`, `EventRegistry`; `EditModeManagerFrame` for the active
   layout's name (`"default"` without it).
4. Surface: `EditModeKit:Register(frame, storage, options?)` → registration
   (`label` on the overlay); `registration:Unregister()`, `Refresh()`,
   `GetFrame()`; `EditModeKit:IsEditing()`, `EditModeKit:GetLayoutName()`;
   `SetLimits{ maxRegistrations }` / `GetLimits()`. The storage is a table,
   or a function returning one, holding `{ x, y }` per layout name: the
   frame's centre offset from `UIParent`'s centre.
5. Ownership: a registration lives until `Unregister`; its overlay goes
   back to a pool. A position change of a protected frame in combat waits
   for `PLAYER_REGEN_ENABLED`.
6. Performance and memory: nothing runs per frame; the work happens when
   Edit Mode opens or closes, a layout changes or a drag ends. One callback
   owner for the session. `maxRegistrations` defaults to 64 with a ceiling
   of 256 (each holds an overlay frame), no `UNBOUNDED`.
7. Tests: stand-ins for `EventRegistry`, `EditModeManagerFrame` and the
   layouts event; overlays shown and hidden with Edit Mode, dragging that
   saves the centre offset per layout, positions put back on a layout
   switch and on `Refresh`, a frame with no saved position left where it
   is, a storage function, protected frames in combat waiting, unregistering,
   limits, secret values, upgrade, manifest, error levels. A client suite on
   Retail: a frame registered, its overlay shown in Edit Mode, its position
   saved and restored.
8. Docs: README (with the migration from LibEditMode), API.md, CHANGELOG,
   tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 28 specs; the client suite (`tests/client/MoltenCodesTest_EditModeKit`)
   is written and has not been run in a client. Overlays given back by
   `Unregister` are kept on a free list of the state rather than a PoolKit
   pool, so the dependency stays registry only.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 32 specs
   (a drag under way ends at `Unregister` and at Edit Mode's exit; the
   user-placed flag is cleared after `StartMoving`).

