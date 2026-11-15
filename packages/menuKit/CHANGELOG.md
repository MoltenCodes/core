# Changelog

## 0.1.1 — 2026-11-15

- Fixed (revision 2): the build read an entry's fields with plain indexing while the check read them with `rawget`, so a field an `__index` metatable supplied reached Blizzard unchecked. A submenu there escaped `maxEntries` and `maxDepth`, and an `onClick`, `disabled` or `tooltip` there skipped its type check. The build now reads every field with `rawget`, as the check does; such fields are ignored. Spec: `MenuKit limits builds only the entry fields it checked, not ones a metatable supplies`. An in-place upgrade from revision 1 keeps its dropdowns and extensions (spec in `Bootstrap_spec.lua`).
- Documented that `Menu.ModifyMenu` calls a new extension at once with the last menu generated under its tag, that a dropdown's menu function also runs when Blizzard shows the dropdown's selection, that a button without `onClick` leaves the menu open and a radio click closes it, and which small differences between the three clients' `Blizzard_Menu` exist (none in what MenuKit calls). The test stand-in's `Menu.ModifyMenu` now models the immediate call.
- Client suite: the secret test called `OpenContextMenu` as a tail call, which drops the caller's line from the error, so it could never find `MenuKitSuite.lua:`; the extension test counted the immediate `ModifyMenu` call from an earlier right click as the requested one. Both fixed.

## 0.1.0 — 2026-11-15

- Added MenuKit API generation 1, implementation revision 1: checked, bounded menus on Blizzard's Menu API, as recorded in `docs/ROADMAP.md` (package M).
- `MenuKit:OpenContextMenu(owner, menu)`, `MenuKit:SetupDropdown(dropdown, menu)`, `MenuKit:ExtendMenu(tag, menu)` returning an extension with `Remove()` and `IsActive()`, `MenuKit:CloseMenus()`, `SetLimits` and `GetLimits` (`maxEntries` 256, `maxDepth` 4, both openable with `UNBOUNDED`; `maxExtensions` 64, up to 1024).
- Entries of six kinds (`button`, `checkbox`, `radio`, `title`, `divider`, `spacer`) with `data`, `disabled`, `tooltip` and submenus, checked at the caller's line with the entry's path; a menu function is called, and an entry array read, each time the menu opens. Every callback runs protected and is reported when it raises.
- 45 specs, and a client suite, `tests/client/MoltenCodesTest_MenuKit`, not yet run in a client.
