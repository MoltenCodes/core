# MenuKit Tests

The MenuKit suite covers:

- menus: every kind of entry built into Blizzard's description in order, a checkbox and a radio reading and writing through their callbacks with the entry's data, a button's `onClick` with its data, submenus below a button (nested twice), `disabled` as a boolean and as a polled function with the data, tooltips, a menu function called at every opening with the owner, an entry array read again at every opening of a dropdown, callbacks that raise reported while the menu keeps working, a menu function that raises or returns a bad menu reported with the menu left empty, a failure while building reported, a context menu without an owner, `CloseMenus`, and every method refused without Blizzard's Menu API;
- entry checks: menus that are not arrays, entries that are not tables, unknown kinds, fields a kind does not take (a typo, a number key), required and optional texts, tooltips, `disabled`, `onClick`, `isSelected` and `setSelected`, the path of a problem in a submenu, an array inside itself refused and the same array twice accepted, the check in each public method, the owner, the dropdown and the tag, and the facade receiver;
- extensions: entries added after Blizzard's own on every opening of the tagged menu and only that one, the last menu generated under the tag filled at once by `ExtendMenu`, a menu function given the owner and Blizzard's context data, `Remove` once with no further calls, a handle that fails to unregister reported, `maxExtensions` refusing and a slot freed by `Remove`, and the extension receiver and its hidden metatable;
- the limits: defaults, constants and fresh tables, `maxEntries` counted across submenus and lifted with `UNBOUNDED`, `maxDepth` refusing the fifth menu and lifted with `UNBOUNDED`, a menu function's result checked against the limits when it opens, invalid values refused without changing any, the `maxExtensions` ceiling, and entry fields an `__index` metatable supplies ignored when the menu is built, so no unchecked submenu escapes the limits;
- secret values: a secret text, tooltip, kind, field name, entry, menu, owner, dropdown, tag, limits table, limit key and value, and receiver refused at the caller through an `issecretvalue` stub, and secret `data` handed to a callback untouched;
- `error` levels: every argument failure of every method reports the caller's own line;
- Registry publication, a duplicate embedded load keeping extensions, yielding to a newer revision, an in-place upgrade keeping the limits, the sentinel and the extensions while a dropdown and an extension set up before the upgrade run the new code, the same from a copy carrying revision 1, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependency.

`support/MenuKitTestEnv.lua` provides a stand-in for Blizzard_Menu (`InstallMenu`): descriptions that record what was added and can be clicked, `MenuUtil.CreateContextMenu`, dropdown buttons with `SetupMenu` (`NewDropdown`), `Menu.ModifyMenu` with handles, calling a new callback at once with the last menu filled under its tag as Blizzard does, and tagged menus opened as Blizzard opens them (`OpenTagged`), and `Menu.GetManager():CloseMenus()`; the secret probe, `TakeReportedValues` and `LoadRevision`. `Reset` removes `MenuUtil` and `Menu`.

| Spec | Covers |
|---|---|
| `Menus_spec.lua` | building, callbacks, dynamic menus, failures, `CloseMenus` |
| `Entries_spec.lua` | the entry checks and argument checks |
| `Extensions_spec.lua` | `ExtendMenu`, `Remove`, `IsActive`, `maxExtensions` |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, the three limits |
| `SecretValues_spec.lua` | secret arguments, entries and data |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependency |
