# launcherKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## launcherKit

**launcherKit** — facade `LauncherKit` (the minimap launcher)

1. Package `launcherKit`, facade `LauncherKit`, API generation 1.
2. Purpose: a minimap button for a BrokerKit object, what LibDBIcon-1.0
   gives every addon with a LibDataBroker launcher: the object's icon on the
   edge of the minimap, dragged around it (a round minimap, or the shape
   `GetMinimapShape` reports when an addon makes it square), its `OnClick`
   on a click, its `OnTooltipShow` in `GameTooltip` on hover, its icon
   following the object's `icon` attribute. Position, hidden and locked
   state live in a table the addon gives (a SettingsKit view or any table),
   in LibDBIcon's field names (`minimapPos`, `hide`, `lock`), so a saved
   LibDBIcon table keeps working. On Retail the same object can also be put
   in Blizzard's AddonCompartment (the addons drop-down by the minimap,
   `AddonCompartmentFrame:RegisterAddon`), which exists only there (checked
   in Blizzard's source on `live`, `classic` and `classic_era`, 2026-11-15)
   and has no way to remove an entry. Non-goals: adopting or driving other
   addons' LibDBIcon buttons, a broker display bar, changing the minimap.
3. Dependencies: registry API 2 and brokerKit API 1, both required (a
   launcher shows a BrokerKit object); SignalKit comes with BrokerKit. Host
   requirement: `Minimap`, `CreateFrame`, `GameTooltip`.
4. Surface: `LauncherKit:Register(objectName, storage)` → launcher (the
   `options` argument was dropped while building: nothing needed one); `launcher:Show()`, `Hide()`, `IsShown()`, `Lock()`,
   `Unlock()`, `IsLocked()`, `Refresh()` (read the storage again, after a
   profile switch), `GetButton()` (its icon texture is `button.icon`); `LauncherKit:Get(objectName)`;
   `LauncherKit:AddToCompartment(objectName)` → `true`, or `nil` and
   `"unavailable"` (no AddonCompartment) or `"already"`;
   `SetLimits{ maxLaunchers }` / `GetLimits()`.
5. Ownership: one button frame per launcher, created at `Register` and kept
   for the session, because the client never frees a frame; a launcher
   follows its object until logout. The storage stays the addon's:
   LauncherKit writes only the three fields, and only on a drag, `Show`,
   `Hide`, `Lock` or `Unlock`. A compartment entry is the client's until
   logout.
6. Performance and memory: nothing runs per frame except while a button is
   dragged; an icon change is one BrokerKit signal. `maxLaunchers` defaults
   to 64 with a ceiling of 256 and no `UNBOUNDED` (each is a frame for the
   session).
7. Tests: stand-ins for `Minimap`, `GameTooltip`, the cursor and
   `AddonCompartmentFrame`; placement at an angle on a round minimap and on
   every `GetMinimapShape` shape, dragging that saves `minimapPos`, a
   locked button that does not move, `hide` honoured at `Register` and
   written by `Show`/`Hide`, `Refresh` after the storage changed, clicks and
   tooltips through the object's callbacks with one that raises reported,
   the icon following the object, a LibDBIcon-shaped table read as it is,
   the compartment `"unavailable"` and `"already"`, limits and the ceiling,
   secret values, upgrade, manifest, error levels. A client suite on Retail:
   a button on the real minimap, shown, hidden and moved, its tooltip filled
   and hidden again, and a compartment entry.
8. Docs: README (with the migration from LibDBIcon), API.md, CHANGELOG,
   tests/README; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   39 specs; the client suite (`tests/client/MoltenCodesTest_LauncherKit`)
   is written and has not been run in a client. Ticked once it has.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2
   (`SetLimits` read `maxLaunchers` through the table's metatable), 41
   specs.

