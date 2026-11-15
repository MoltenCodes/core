# MenuKit API

MenuKit API generation **1** turns menus described as plain tables into Blizzard's Menu API calls: context menus, dropdown menus and removable extensions of Blizzard's tagged menus, each checked at the caller's line, bounded, and with every callback run protected.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
MenuKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local MenuKit = MoltenCodes.Registries[2]:Get("menuKit", 1)
```

MenuKit does not rely on `require()` at runtime.

### Host facilities

MenuKit reads these host globals at call time, never at load:

| Facility | Used by | Without it |
|---|---|---|
| `MenuUtil.CreateContextMenu`, `Menu.ModifyMenu`, `Menu.GetManager` | every method but `SetLimits` and `GetLimits` | The method raises at the caller: `MenuKit:OpenContextMenu needs the client's Menu API (Blizzard_Menu), which this host does not have`. |
| `issecretvalue` | every check | Nothing is treated as secret. |
| `geterrorhandler` | callbacks and menu functions that raise, a menu function's result that fails the check | The failure is printed. |

Retail, Mists of Pandaria Classic and Classic Era ship `Blizzard_Menu` with the same `Menu.lua` and `MenuUtil.lua` (branches `live`, `classic` and `classic_era` of Blizzard's interface source, read 2026-11-15). The one difference, `MenuUtil.CreateHighlightButton` on Retail alone, is not used.

## Public surface

| Member | Purpose |
|---|---|
| `OpenContextMenu(owner?, menu)` | Open `menu` at the cursor; return Blizzard's menu, or `nil` when it did not open. |
| `SetupDropdown(dropdown, menu)` | Give a `DropdownButton` its menu. |
| `ExtendMenu(tag, menu)` | Add `menu`'s entries to Blizzard's menu tagged `tag` every time it opens; return an extension. |
| `CloseMenus()` | Close every open menu (`Menu.GetManager():CloseMenus()`). |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxEntries`, `maxDepth` and `maxExtensions`; `GetLimits` returns a fresh table. |
| `MAX_ENTRIES`, `MAX_DEPTH`, `MAX_EXTENSIONS`, `EXTENSIONS_CEILING` | `256`, `4`, `64`, `1024`. |
| `UNBOUNDED` | Sentinel `maxEntries` and `maxDepth` accept to lift the bound. |
| `API`, `REVISION` | `1`, `1`. |

An extension:

| Method | Purpose |
|---|---|
| `Remove()` | Unregister it from Blizzard's menu: `true`, or `false` when it was already removed. |
| `IsActive()` | Whether it is still registered. |

## Menus and entries

A **menu** is an array of entries, or a function returning one. A function is called each time the menu opens, with the owner (for an extension, also Blizzard's context data: `function(owner, contextData)`); an array is read again each time, so a change to it shows at the next opening. Nothing is cached between openings.

An **entry** is a table with a `kind` and the fields that kind takes:

| Field | `button` | `checkbox`, `radio` | `title` | `divider`, `spacer` | Meaning |
|---|---|---|---|---|---|
| `kind` | yes | yes | yes | yes | The kind of line. |
| `text` | required | required | required | — | A non-empty string, never a secret. |
| `data` | optional | optional | — | — | Any value, handed to the entry's callbacks; never inspected, so it may be a secret. |
| `disabled` | optional | optional | — | — | `true` greys the line out; a function `disabled(data)` is asked whenever Blizzard polls the line. |
| `tooltip` | optional | optional | — | — | A string shown when the cursor rests on the line. |
| `onClick` | optional | — | — | — | `onClick(data)` when clicked. A button without one does nothing when clicked. |
| `entries` | optional | — | — | — | An entry array: the button opens it as a submenu. |
| `isSelected` | — | required | — | — | `isSelected(data)`: whether the line shows as selected. |
| `setSelected` | — | required | — | — | `setSelected(data)` when clicked. |

Any other field is refused, so a typo (`onclick`, `disable`) is caught at your line.

How each entry maps to Blizzard's element descriptions:

| Entry | Blizzard call |
|---|---|
| `button` | `parent:CreateButton(text, responder, data)`; the responder calls `onClick(data)`. With `entries`, its own entries are added to the returned description, which makes it a submenu. |
| `checkbox` | `parent:CreateCheckbox(text, isSelected, setSelected, data)`. Blizzard refreshes the menu after a click. |
| `radio` | `parent:CreateRadio(text, isSelected, setSelected, data)`. |
| `title` | `parent:CreateTitle(text)`. |
| `divider`, `spacer` | `parent:CreateDivider()`, `parent:CreateSpacer()`. |
| `disabled` | `description:SetEnabled(not disabled)`, or `SetEnabled(function)` for a function. |
| `tooltip` | `description:SetTooltip(function(tooltip) tooltip:SetText(text, nil, nil, nil, nil, true) end)`. |

Blizzard's own rules then apply: a button's click closes the menu, a checkbox click keeps it open and refreshes it, a submenu opens on hover.

## Checks and failures

A menu given as an array is checked completely when you call `OpenContextMenu`, `SetupDropdown` or `ExtendMenu`, and refused at your line with the path of the first problem:

- `menu must be an array of entries`, `menu[2] must be an entry table`;
- `menu[1].kind must be "button", "checkbox", "radio", "title", "divider" or "spacer"`;
- `menu[1] holds the field onclick, which a button does not take` (a key that is not a string is named by its type, `<number>`; a secret key as `<secret value>`);
- `menu[3].text must be a non-empty string`, `... must not be a secret value`; the same for `tooltip`;
- `menu[1].disabled must be a boolean, a function or nil`, `menu[1].onClick must be a function or nil`, `menu[1].isSelected must be a function`, `menu[1].setSelected must be a function`;
- `menu[2].entries must be an array of entries`, `menu[1].entries contains itself` (an array inside itself; the same array twice side by side is fine);
- `menu[1].entries opens 5 menus deep; maxDepth is 4`, `menu holds more than 256 entries; maxEntries is 256`.

The same check runs again each time the menu opens, because an array can change and a function's result is only known then. There the caller is Blizzard, so a problem is **reported** through `geterrorhandler` (the message starts with `MenuKit menu`) and the menu opens empty, never raised. A menu function that raises is reported the same way.

**Callbacks run protected.** `onClick`, `isSelected`, `setSelected` and a `disabled` function are called through `pcall`; one that raises is reported, and the line behaves as if it had answered nothing: an `isSelected` that raises shows unselected, a `disabled` that raises leaves the line enabled. A failure while the descriptions are being built is reported, and the menu keeps what was added before it.

The other arguments are refused at your line: `owner must be a frame or nil` (any table is accepted; Blizzard closes the menu when that region hides), `dropdown must be a DropdownButton` (a table with `SetupMenu`), `tag must be a non-empty string`.

## `MenuKit:ExtendMenu(tag, menu)`

Calls `Menu.ModifyMenu(tag, callback)` and keeps the handle Blizzard returns. Every time a menu tagged `tag` opens, Blizzard first adds its own lines, then calls every registered callback in registration order; MenuKit's adds `menu`'s entries at the end. Tags are Blizzard's: the unit menus are `MENU_UNIT_<TYPE>` (`MENU_UNIT_SELF`, `MENU_UNIT_PARTY`, `MENU_UNIT_RAID_PLAYER`, ...) and carry a `contextData` table (`contextData.unit`, `contextData.name`, ...); `Menu.PrintOpenMenuTags()` in the client lists the tags of the menus open at that moment.

`extension:Remove()` calls the handle's `Unregister`. A handle that raises there is reported, and the extension still counts as removed. At most `maxExtensions` extensions are registered at a time: `MenuKit:ExtendMenu holds at most 64 extensions; remove one, or raise maxExtensions with MenuKit:SetLimits`.

## Secret values

Every text, tooltip, kind, field name, entry, menu, owner, dropdown, tag, limit and receiver is checked with `issecretvalue` before anything else touches it and refused at the caller. `data` is never inspected: a secret there is handed to your callbacks as it is.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxEntries`, entries in one menu, submenus included | `256` | `MenuKit:SetLimits({ maxEntries = n })` | yes | none: a menu is translated when it opens and nothing is kept |
| `maxDepth`, menus a submenu may open deep (the root is 1) | `4` | `MenuKit:SetLimits({ maxDepth = n })` | yes | none; an array inside itself is refused whatever the depth |
| `maxExtensions`, extensions registered at a time | `64` | `MenuKit:SetLimits({ maxExtensions = n })` | no | `1024`: each one is a callback Blizzard keeps until it is removed |

`SetLimits` accepts any subset and raises at the caller for an unknown field, a secret, or a value outside its range, before changing anything. Lowering `maxExtensions` below the number registered keeps every extension and refuses the next. The limits are shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line. Facade methods called without the facade raise `MenuKit:OpenContextMenu must be called on the MenuKit facade; use MenuKit:OpenContextMenu(...)`; extension methods called on anything else raise `MenuKit.Extension:Remove must be called on a MenuKit extension; use extension:Remove(...)`. What Blizzard calls is reported through `geterrorhandler`, as above.

## Performance

| Path | Cost |
|---|---|
| A menu that is closed | Only your table or function; MenuKit keeps nothing. |
| Opening a menu | One check of the entries and one Blizzard description per entry, plus one closure per callback MenuKit wraps. |
| `ExtendMenu` | One handle, one record, one Blizzard callback registration. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed MenuKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the limits, the `UNBOUNDED` sentinel and the registered extensions. The generators handed to a dropdown and the callbacks handed to `Menu.ModifyMenu` stay with Blizzard after an upgrade, so they call through a dispatch table in the shared state that every loading revision rewrites: a menu set up by an older copy is filled by the newest copy's code.
