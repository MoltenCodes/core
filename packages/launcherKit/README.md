# LauncherKit

LauncherKit puts a [BrokerKit](../brokerKit/) object on the minimap as a button: the job LibDBIcon-1.0 does for every addon with a LibDataBroker launcher. The object's icon sits on the minimap's edge and is dragged around it; a click calls the object's `OnClick`, hovering fills `GameTooltip` through its `OnTooltipShow`, and the icon follows the object. On Retail the same object can also be listed in Blizzard's addon compartment, the drop-down beside the minimap.

```lua
local Registry = MoltenCodes.Registries[2]
local BrokerKit = Registry:Get("brokerKit", 1)
local LauncherKit = Registry:Get("launcherKit", 1)

BrokerKit:New("MyAddon", {
  type = "launcher",
  icon = [[Interface\AddOns\MyAddon\Icon]],
  OnClick = function(_, mouseButton)
    if mouseButton == "LeftButton" then
      MyAddon:ToggleWindow()
    end
  end,
  OnTooltipShow = function(tooltip)
    tooltip:AddLine("My Addon")
    tooltip:AddLine("Click to open the window.", 1, 1, 1)
  end,
})

-- The state lives in your saved variables; a function follows profile switches.
local launcher = LauncherKit:Register("MyAddon", function()
  return db.profile.minimap
end)
db:OnProfileChanged(function()
  launcher:Refresh()
end)

-- Retail's addon compartment as well; Classic answers nil, "unavailable".
LauncherKit:AddToCompartment("MyAddon")
```

What each piece promises:

- **LibDBIcon's saved data, as it is.** The storage table holds `minimapPos` (degrees counter-clockwise from the right; 225 until moved), `hide` and `lock`, LibDBIcon's field names, so an addon moving from LibDBIcon keeps its players' button positions. LauncherKit writes only those three fields, and only when the button is dragged, shown, hidden, locked or unlocked.
- **Any minimap shape.** The button follows a circle, or the edge of a square where an addon that reshapes the minimap says a quarter is square through the shared `GetMinimapShape` convention.
- **The object drives the button.** Clicks go to `OnClick(button, mouseButton)`, hovering to `OnTooltipShow(GameTooltip)` or `OnEnter`/`OnLeave`, and a change to `icon`, `iconCoords` or `iconR`/`iconG`/`iconB` redraws the icon. A callback that raises is reported through the error handler, never raised into the client.
- **Nothing per frame.** A button runs code only while it is dragged.
- **Bounded.** At most 64 launchers per session, up to 256 with `LauncherKit:SetLimits({ maxLaunchers = n })`; there is no unbounded setting, because each launcher is a frame the client never frees.

Non-goals: adopting or moving other addons' LibDBIcon buttons, a broker display bar, changing the minimap itself.

### Moving from LibDBIcon-1.0

| LibDBIcon-1.0 | LauncherKit |
|---|---|
| `LibStub("LibDataBroker-1.1"):NewDataObject(name, dataobj)` | `BrokerKit:New(name, definition)` |
| `icon:Register(name, dataobj, db.profile.minimap)` | `LauncherKit:Register(name, db.profile.minimap)`, or a function returning the table |
| `icon:Show(name)`, `icon:Hide(name)` | `launcher:Show()`, `launcher:Hide()` (both save `hide`) |
| `icon:Lock(name)`, `icon:Unlock(name)` | `launcher:Lock()`, `launcher:Unlock()` |
| `icon:Refresh(name, db)` | `launcher:Refresh()`; a storage function makes the new table unnecessary |
| `icon:GetMinimapButton(name)` | `launcher:GetButton()`; its icon texture is `button.icon` |
| `icon:AddButtonToCompartment(name)` | `LauncherKit:AddToCompartment(name)` |

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\brokerKit\BrokerKit.lua
Libs\MoltenCodes\launcherKit\LauncherKit.lua
```

Minimum footprint: embed 4 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `brokerKit/BrokerKit.lua`, `launcherKit/LauncherKit.lua`.

Direct runtime dependencies: Registry API 2, BrokerKit API 1.
Every file above is required; omitting one makes this package raise at
load.

LauncherKit reads `Minimap`, `GameTooltip`, `GetMinimapShape` and
`AddonCompartmentFrame` when it is called, never at load. Register on
`PLAYER_LOGIN`, when every minimap addon has defined its shape.
