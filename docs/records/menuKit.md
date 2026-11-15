# menuKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## menuKit

**menuKit** — facade `MenuKit`

1. Package `menuKit`, facade `MenuKit`, API generation 1.
2. Purpose: menus an addon describes as plain, checked tables, shown by
   Blizzard's Menu API (`Blizzard_Menu`, 11.0, which replaces the deprecated
   UIDropDownMenu): a context menu at the cursor, the menu of a dropdown
   button, and entries an addon adds to Blizzard's own tagged menus (the
   unit right-click menus, `MENU_UNIT_<TYPE>`) and removes again. Retail,
   Mists of Pandaria Classic and Classic Era ship `Blizzard_Menu` with the
   same `Menu.lua` and `MenuUtil.lua` (branches `live`, `classic` and
   `classic_era`, read 2026-11-15), except `MenuUtil.CreateHighlightButton`,
   which only Retail has and menuKit does not use. What menuKit adds over
   calling `MenuUtil` directly: entries checked at the caller's line (kind,
   text, callbacks, a secret refused), bounded size and depth, callbacks run
   so that one that raises is reported and never breaks Blizzard's menu, and
   menu extensions an addon can remove (Blizzard's `Menu.ModifyMenu` handle).
   Non-goals: drawing a menu (Blizzard does), UIDropDownMenu, WidgetKit's own
   `Dropdown` widget, grid and scroll modes, custom element templates.
3. Dependencies: registry API 2 only. Host requirement: `MenuUtil` and
   `Menu` (`Blizzard_Menu`); without them every call raises at the caller.
4. Surface: an entry is a table `{ kind, text, ... }` with `kind` one of
   `"button"`, `"checkbox"`, `"radio"`, `"title"`, `"divider"`, `"spacer"`;
   a button takes `onClick(data)`, a checkbox or radio `isSelected(data)`
   and `setSelected(data)`, any of them `data`, `disabled` (a boolean or a
   function), `tooltip` (a string), and `entries` for a submenu. A menu is
   an array of entries, or a function returning one, called each time the
   menu opens. `MenuKit:OpenContextMenu(owner, menu)`;
   `MenuKit:SetupDropdown(dropdownButton, menu)`;
   `MenuKit:ExtendMenu(tag, menu)` → extension with `Remove()`;
   `MenuKit:CloseMenus()`; `SetLimits{ maxEntries, maxDepth,
   maxExtensions }` / `GetLimits()`.
5. Ownership: menuKit keeps nothing for a context menu or a dropdown once
   the description is handed to Blizzard; Blizzard owns the open menu. An
   extension is kept until `Remove()`, bounded by `maxExtensions`.
6. Performance and memory: a menu is translated when it opens, never
   before, so a closed menu costs only its table; nothing is cached between
   openings. Defaults: 256 entries per menu, depth 4, 64 extensions; the
   first two open to `UNBOUNDED`, the last to a ceiling (each extension is a
   Blizzard callback registration).
7. Tests: a stand-in `MenuUtil` and `Menu` that records the description
   built (kinds, texts, callbacks, submenus, tooltips, enabled state) and
   clicks it; every entry kind and its checks, dynamic menus, nested
   submenus at the depth limit, limits and `UNBOUNDED`, a raising callback
   reported and not raised, extensions added and removed, secret texts
   refused, upgrade, manifest, error levels. A client suite on Retail: a
   context menu and a dropdown opened and closed again, a unit menu
   extension added and removed (verified by its tag being reached), and
   each callback run on the client.
8. Docs: README, API.md (the entry table field by field, and how each maps
   to `MenuUtil`), CHANGELOG, tests/README; EMBEDDING footprint and
   host-requirements rows; ARCHITECTURE's package list; EMBEDDING's user
   interface section. (The Ace3 migration guide gets no section: Ace3 has no
   menu library.)
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   45 specs; the client suite (`tests/client/MoltenCodesTest_MenuKit`) is
   written and has not been run in a client. Ticked once it has.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2 (entry
   fields read with `rawget` when building, as when checking), 48 specs.

