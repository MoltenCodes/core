# WidgetKit

WidgetKit gives World of Warcraft addons pooled, versioned widgets on frames it creates itself, containers whose layout runs only when you ask for it, a saveable anchor value type with position persistence, and a renderer that turns an [OptionsKit](../optionsKit/) tree into a working options window.

```lua
local Registry = MoltenCodes.Registries[2]
local WidgetKit = Registry:Get("widgetKit", 1)
local OptionsKit = Registry:Get("optionsKit", 1)

-- A movable, resizable window whose position is saved in the addon's
-- SettingsKit database (any plain table works too).
local window = WidgetKit:Create("Frame")
window:SetTitle("My Addon")
window:BindPosition(db.global, { key = "optionsWindow" })

-- A scrolling area filling the window, holding the rendered options.
window:SetLayout("Fill")
local scroll = WidgetKit:Create("ScrollFrame")
window:AddChild(scroll)

local rendering = WidgetKit:RenderOptions(OptionsKit:Get("MyAddon"), scroll)

window:SetCallback("OnClose", function()
    rendering:Release()           -- every rendered widget goes back to its pool
    WidgetKit:Release(window)     -- and the window with its scroll frame
end)
```

What each piece promises:

- **Pooled and bounded.** Each widget type has one PoolKit pool. The client never frees a frame, so a type builds at most 256 frames for the session (`nil, "exhausted"` beyond), and every released widget is kept for reuse.
- **Versioned.** `RegisterType(name, constructor, version)` ignores a lower version and, for a higher one, retires every pooled widget the older constructor built, so a widget is never reused with a shape its type no longer has.
- **A released widget is clean.** `Release` fires `OnRelease`, releases children last first, clears callbacks, user data, size requests and anchors, hides the frame and re-parents it. Releasing twice, or releasing something that is not a widget, is refused at your line. `IsReleasing()` sees a release anywhere above the widget.
- **Explicit layout.** `List`, `Fill` and `Flow` run when a child is added or when you call `PerformLayout`, never from `OnSizeChanged`; a layout pass inside a pass of the same container is refused rather than looped. Containers hold at most 256 children.
- **Bounded by default, opened on purpose.** Every cap has a documented default and a way to open it: `maxCallbacks` per type, `container:SetMaxChildren` (both accept `WidgetKit.UNBOUNDED`), `WidgetKit:SetLimits{ maxDropdownEntries }` (accepts `UNBOUNDED`) and `WidgetKit:SetLimits{ maxCreatedCeiling }` (up to 16384; frames are never freed, so never unbounded). See *Limits* in the API.
- **Anchors you can save.** `WidgetKit.Anchor` elects the nearest of the nine points (`FromRect`), normalises any `SetPoint` argument form (`Normalize`), and applies and reads anchors. `BindPosition` saves a frame's anchor into any table, a SettingsKit scope view included, debounced through SchedulerKit when it is present.
- **Options, rendered.** Every OptionsKit kind has a widget; `order`, `disabled` and `hidden` are honoured, writes go through `Validate` and `Set`, a refusal is shown in a line below the widget, and `OnChange` refreshes the widgets in place.
- **Secrets stay the caller's decision.** Text setters refuse a secret value unless you pass `{ allowSecret = true }`, and a released widget never carries a secret into its next use.

See [`docs/API.md`](docs/API.md) for the complete contract, including the rules a widget author must follow, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout algorithms, the renderer and pooling.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\widgetKit\WidgetKit.lua
```

Minimum footprint: embed 4 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`, `signalKit/SignalKit.lua`, `widgetKit/WidgetKit.lua`.

Direct runtime dependencies: Registry API 2, PoolKit API 1 and SignalKit API 1.
All four files above are required; omitting one makes WidgetKit raise at load.

Optional, found with `Registry:Find` when they are used, so they may load in any
order:

| Kit | Used by | Without it |
|---|---|---|
| OptionsKit API 1 | `RenderOptions` | `RenderOptions` raises at the caller. |
| SchedulerKit API 1 | `BindPosition` | Every captured position is saved at once instead of debounced. |
| MediaKit API 1 | `CreateMediaPicker`, `RenderOptions` with `options.media` | `CreateMediaPicker` raises at the caller; the renderer shows the option's own `values`. |
| SettingsKit API 1 | nothing directly: a scope view is a valid `BindPosition` storage table | Any plain table works. |

Taint, in short: WidgetKit creates every frame it scripts, never sets a script
on a frame it did not create, never writes a field onto a client frame, and
calls no protected function. Its frames are ordinary insecure frames: use them
for configuration and display, never for protected actions. The client's
`ColorPickerFrame` is only opened through its own `SetupColorPickerAndShow`
method, after `IsForbidden` and `CanBeAccessedInContext` allow it.
