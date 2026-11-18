# LauncherKit Tests

The LauncherKit suite covers:

- launchers: a button on the minimap at the default angle with the object's icon; a LibDBIcon-shaped table (`minimapPos`, `hide`, `lock`) read as it is; placement on a round minimap, a `SQUARE` one, a `CORNER-TOPLEFT` one in a square and a round quarter, and round for an unknown shape, an answer that is not a string and a `GetMinimapShape` that raises; a drag that follows the cursor and saves the angle only when it stops; a locked button that does not move; `Show` and `Hide` saving `hide`, and `Refresh` reading the table again; a storage function read and written at every use across two profiles; a storage function that raises or returns no table, and a write the table refuses, each reported; the icon following `icon`, `iconCoords` and the vertex colour, and not an unrelated attribute; `OnClick` and `OnTooltipShow` in `GameTooltip`, and `OnEnter`/`OnLeave` without it; callbacks that raise reported; the tooltip hidden while dragging; argument refusals creating nothing, a duplicate refused, a host without `Minimap`, `Get`'s argument, every receiver, and the hidden metatable;
- the compartment: `"unavailable"` without `AddonCompartmentFrame` or its `RegisterAddon`, the label or name and the icon registered once with `"already"` after, the click with the mouse button and a missing input table, the tooltip on hover, an `OnClick` that raises reported, and an unknown object refused;
- the limit: defaults, constants and fresh tables, `maxLaunchers` refusing at the caller and lowered without removing launchers, the ceiling accepted, invalid values and fields refused without changing it, and a value only the limits table's metatable answers ignored;
- secret values: a secret object name, storage, limits table, limit key and value, and receiver refused at the caller; secret saved fields read as absent; a storage function's secret answer reported; a secret cursor position ignored while dragging;
- `error` levels: every argument failure of every method reports the caller's own line;
- Registry publication, a duplicate embedded load keeping launchers, yielding to a newer revision, an in-place upgrade keeping launchers, the compartment and the limit while a button, its BrokerKit connection and a compartment entry made before the upgrade run the new code, a revision 1 copy upgraded in place to this revision, a refusal of state holding an invalid limit, missing Registry or BrokerKit, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/LauncherKitTestEnv.lua` provides `UIParent`, a 140 x 140 `Minimap` at a known centre, a `GameTooltip` that records its owner, lines and shown state, `GetCursorPosition` answering `SetCursor`, a stand-in for Retail's `AddonCompartmentFrame` (`InstallCompartment`), `Offset` (a button's offset from the minimap's centre), `Run` (a button's script), `TakeReportedValues`, the secret probe and `LoadRevision`. `Reset` removes every global it installs.

The shared helper specs load the Kit with the secret probe already installed (through `package.preload`), raise from the host error handler, and load the committed revision 2 file (`fixtures/LauncherKit-revision2.lua`) before the current one.

| Spec | Covers |
|---|---|
| `SharedHelpers_spec.lua` | the shared `isSecret`, `reportError` and `validateFacade` blocks, the upgrade from revision 2 |
| `Conformance_spec.lua` | the repository conformance suite (`tests/support/KitConformance.lua`) |
| `Launcher_spec.lua` | `Register`, placement, dragging, storage, icon, scripts |
| `Compartment_spec.lua` | `AddToCompartment` |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `maxLaunchers` |
| `SecretValues_spec.lua` | secret arguments, saved fields and cursor positions |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
