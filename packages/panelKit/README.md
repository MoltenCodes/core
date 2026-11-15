# PanelKit

PanelKit puts an addon's [OptionsKit](../optionsKit/) tree in Blizzard's settings panel, the AddOns tab the player opens with Esc → Options, as a category or a subcategory of one. It is what Ace3's `AceConfigDialog:AddToBlizOptions` does, built on Blizzard's own Settings API rather than a panel of its own, and drawn by [WidgetKit](../widgetKit/)'s renderer only while the page is on screen.

```lua
local Registry = MoltenCodes.Registries[2]
local OptionsKit = Registry:Get("optionsKit", 1)
local PanelKit = Registry:Get("panelKit", 1)

OptionsKit:Define("MyAddon", {
  type = "group",
  name = "My Addon",
  args = {
    enabled = { type = "toggle", name = "Enabled", order = 1, bind = "profile.enabled" },
    scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, order = 2, bind = "profile.scale" },
  },
}, { db = db })

-- A category in the AddOns list, and a subcategory under it for a second tree.
local panel = PanelKit:Register("MyAddon", { name = "My Addon" })
PanelKit:Register("MyAddonProfiles", { name = "Profiles", parent = panel })

-- The Defaults button on the page.
panel:SetDefaultHandler(function()
  db:ResetProfile()
end)

-- /myaddon opens the page.
SlashCmdList.MYADDON = function()
  panel:Open()
end
```

What each piece promises:

- **Blizzard's panel, wrapped.** `Register` calls `Settings.RegisterCanvasLayoutCategory` and `Settings.RegisterAddOnCategory`, or `Settings.RegisterCanvasLayoutSubcategory` for a `parent`; `panel:Open()` calls `Settings.OpenToCategory`. Retail, Mists of Pandaria Classic and Classic Era ship these with the same code.
- **Nothing drawn while hidden.** Each panel has one plain frame, the canvas Blizzard shows on its page. When Blizzard shows it, PanelKit takes a pooled WidgetKit `ScrollFrame` and renders the tree into it; when Blizzard hides it, every widget goes back to its pool. A page nobody opens costs one frame.
- **The tree by name.** The page draws whatever `OptionsKit:Get(treeName)` answers when it is shown, so a tree defined after `Register`, or defined again, is picked up; with none, the page says so in one line.
- **Blizzard's buttons.** The panel's refresh redraws the values (or the whole page when the tree under the name changed); Defaults runs your handler and then refreshes (Blizzard's reset of all settings runs the handler of every page, shown or not); there is nothing to commit, because OptionsKit writes at once. A handler that raises is reported through the error handler, never raised into Blizzard's panel.
- **Bounded.** At most 64 panels per session, subcategories included; `PanelKit:SetLimits({ maxPanels = n })` raises it up to 1024. There is no unbounded setting: Blizzard cannot remove a category and the client never frees a frame, so a registration lasts until logout.
- **Checked at your line.** Every argument error, a secret value included, is raised at the line that called PanelKit.

Non-goals: building widgets or laying them out (WidgetKit), the option model (OptionsKit), Blizzard's own vertical-layout setting controls, a standalone window (`WidgetKit:Create("Frame")` with `RenderOptions`), the pre-10.0 `InterfaceOptions_AddCategory` API.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\optionsKit\OptionsKit.lua
Libs\MoltenCodes\widgetKit\WidgetKit.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Containers.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Text.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Button.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-CheckBox.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Slider.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-EditBox.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Dropdown.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-ColorPicker.lua
Libs\MoltenCodes\widgetKit\parts\WidgetKit-Renderer.lua
Libs\MoltenCodes\panelKit\PanelKit.lua
```

Minimum footprint: embed 15 files: `registry/Registry.lua`, `schemaKit/SchemaKit.lua`, `signalKit/SignalKit.lua`, `optionsKit/OptionsKit.lua`, `widgetKit/WidgetKit.lua`, `widgetKit/parts/WidgetKit-Containers.lua`, `widgetKit/parts/WidgetKit-Text.lua`, `widgetKit/parts/WidgetKit-Button.lua`, `widgetKit/parts/WidgetKit-CheckBox.lua`, `widgetKit/parts/WidgetKit-Slider.lua`, `widgetKit/parts/WidgetKit-EditBox.lua`, `widgetKit/parts/WidgetKit-Dropdown.lua`, `widgetKit/parts/WidgetKit-ColorPicker.lua`, `widgetKit/parts/WidgetKit-Renderer.lua`, `panelKit/PanelKit.lua`. `python3 -m tooling.package.embeds panelKit` writes the list.

Direct runtime dependencies: Registry API 2, WidgetKit API 1 with its `Renderer` part, OptionsKit API 1.
Every file above is required; omitting one makes this package raise at
load.

PanelKit reads the client's `Settings` table when `Register` and `Open` are
called, so it may load before Blizzard's settings addon; register at load or on
`PLAYER_LOGIN`.
