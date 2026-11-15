# Changelog

## 0.1.0 — 2026-11-15

- Added MenuKit API generation 1, implementation revision 1: checked, bounded menus on Blizzard's Menu API, as recorded in `docs/ROADMAP.md` (package M).
- `MenuKit:OpenContextMenu(owner, menu)`, `MenuKit:SetupDropdown(dropdown, menu)`, `MenuKit:ExtendMenu(tag, menu)` returning an extension with `Remove()` and `IsActive()`, `MenuKit:CloseMenus()`, `SetLimits` and `GetLimits` (`maxEntries` 256, `maxDepth` 4, both openable with `UNBOUNDED`; `maxExtensions` 64, up to 1024).
- Entries of six kinds (`button`, `checkbox`, `radio`, `title`, `divider`, `spacer`) with `data`, `disabled`, `tooltip` and submenus, checked at the caller's line with the entry's path; a menu function is called, and an entry array read, each time the menu opens. Every callback runs protected and is reported when it raises.
- 45 specs, and a client suite, `tests/client/MoltenCodesTest_MenuKit`, not yet run in a client.
