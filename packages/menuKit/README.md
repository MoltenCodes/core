# MenuKit

MenuKit lets an addon describe a menu as a plain table and has Blizzard's Menu API (`Blizzard_Menu`, the 11.0 replacement for the deprecated UIDropDownMenu) show it: a context menu at the cursor, the menu of a dropdown button, or lines added to one of Blizzard's own menus, such as the one a right click on a unit frame opens, and removed again.

```lua
local MenuKit = MoltenCodes.Registries[2]:Get("menuKit", 1)

-- A context menu on right click.
button:SetScript("OnMouseUp", function(self, mouseButton)
  if mouseButton == "RightButton" then
    MenuKit:OpenContextMenu(self, {
      { kind = "title", text = "My Addon" },
      { kind = "button", text = "Open window", onClick = function() MyAddon:Toggle() end },
      {
        kind = "checkbox",
        text = "Lock frame",
        isSelected = function() return db.profile.locked end,
        setSelected = function() db.profile.locked = not db.profile.locked end,
      },
      { kind = "divider" },
      {
        kind = "button",
        text = "Size",
        entries = {
          { kind = "radio", text = "Small", data = 0.8, isSelected = isScale, setSelected = setScale },
          { kind = "radio", text = "Large", data = 1.2, isSelected = isScale, setSelected = setScale },
        },
      },
    })
  end
end)

-- A line in the menu a right click on your own unit frame opens.
local extension = MenuKit:ExtendMenu("MENU_UNIT_SELF", function(owner, contextData)
  return { { kind = "divider" }, { kind = "button", text = "My Addon", onClick = openForUnit, data = contextData.unit } }
end)
-- ...and gone again.
extension:Remove()
```

What each piece promises:

- **Blizzard draws, MenuKit describes.** Every entry becomes Blizzard's own element description (`CreateButton`, `CreateCheckbox`, `CreateRadio`, `CreateTitle`, `CreateDivider`, `CreateSpacer`), so menus look and behave like the client's, on Retail, Mists of Pandaria Classic and Classic Era alike.
- **Checked at your line.** An unknown kind, a field the kind does not take (a typo such as `onclick`), a missing text or callback, or a secret value is refused when you call MenuKit, with the path of the entry: `MenuKit:OpenContextMenu menu[2].entries[1].text must be a non-empty string`.
- **Live.** A menu given as a function is called each time Blizzard generates it (when it opens and, for a dropdown, also to show its selection); one given as an array is read again each time. Nothing is cached between openings.
- **Callbacks cannot break the menu.** `onClick`, `isSelected`, `setSelected`, `disabled` and the menu function run protected; one that raises is reported through the error handler and the menu goes on.
- **Removable extensions.** `ExtendMenu` adds your entries after Blizzard's own every time the tagged menu opens, until `extension:Remove()`.
- **Bounded by default, opened on purpose.** 256 entries per menu and 4 menus deep, each opened with `MenuKit:SetLimits` up to `MenuKit.UNBOUNDED`; 64 extensions, up to 1024.

Non-goals: drawing menus, UIDropDownMenu, WidgetKit's own `Dropdown` widget, Blizzard's grid and scroll modes and custom element templates.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\menuKit\MenuKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `menuKit/MenuKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

MenuKit reads Blizzard's `MenuUtil` and `Menu` when it is called, never at
load, so it may load before `Blizzard_Menu`.
