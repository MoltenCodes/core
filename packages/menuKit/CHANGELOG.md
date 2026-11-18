# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that itself raises (an error-display addon with a bug) made the failure MenuKit was reporting raise again into whatever the client was running. `reportError` now calls the handler through `pcall` and prints the failure when the handler is missing or raises.
- `isSecret`, `reportError` and `validateFacade` are now the shared helper blocks (`tooling/shared/lua/`, kept in step by `python3 -m tooling.shared.sync`). The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 3; an embedded revision 2 is upgraded in place, its state kept.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the raising error handler, the facade message, the upgrade over the committed revision 2 file in `tests/fixtures/MenuKit-revision2.lua`) and `Conformance_spec.lua` (the repository's conformance suite; pending: limits (`maxEntries` and `maxDepth` have no ceiling), see the spec).

## 0.1.1 — 2026-11-15

- Fixed (revision 2): the build read an entry's fields with plain indexing while the check read them with `rawget`, so a field an `__index` metatable supplied reached Blizzard unchecked. A submenu there escaped `maxEntries` and `maxDepth`, and an `onClick`, `disabled` or `tooltip` there skipped its type check. The build now reads every field with `rawget`, as the check does; such fields are ignored. Spec: `MenuKit limits builds only the entry fields it checked, not ones a metatable supplies`. An in-place upgrade from revision 1 keeps its dropdowns and extensions (spec in `Bootstrap_spec.lua`).
- Documented that `Menu.ModifyMenu` calls a new extension at once with the last menu generated under its tag, that a dropdown's menu function also runs when Blizzard shows the dropdown's selection, that a button without `onClick` leaves the menu open and a radio click closes it, and which small differences between the three clients' `Blizzard_Menu` exist (none in what MenuKit calls). The test stand-in's `Menu.ModifyMenu` now models the immediate call.
- Client suite: the secret test called `OpenContextMenu` as a tail call, which drops the caller's line from the error, so it could never find `MenuKitSuite.lua:`; the extension test counted the immediate `ModifyMenu` call from an earlier right click as the requested one. Both fixed.

## 0.1.0 — 2026-11-15

- Added MenuKit API generation 1, implementation revision 1: checked, bounded menus on Blizzard's Menu API, as recorded in `docs/ROADMAP.md` (package M).
- `MenuKit:OpenContextMenu(owner, menu)`, `MenuKit:SetupDropdown(dropdown, menu)`, `MenuKit:ExtendMenu(tag, menu)` returning an extension with `Remove()` and `IsActive()`, `MenuKit:CloseMenus()`, `SetLimits` and `GetLimits` (`maxEntries` 256, `maxDepth` 4, both openable with `UNBOUNDED`; `maxExtensions` 64, up to 1024).
- Entries of six kinds (`button`, `checkbox`, `radio`, `title`, `divider`, `spacer`) with `data`, `disabled`, `tooltip` and submenus, checked at the caller's line with the entry's path; a menu function is called, and an entry array read, each time the menu opens. Every callback runs protected and is reported when it raises.
- 45 specs, and a client suite, `tests/client/MoltenCodesTest_MenuKit`, not yet run in a client.
