# WidgetKit

WidgetKit gives World of Warcraft addons pooled, versioned widgets on frames it creates itself, containers whose layout runs only when you ask for it, a virtualised list for long lists, a saveable anchor value type with position persistence, and a renderer that turns an [OptionsKit](../optionsKit/) tree into a working options window.

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

- **Pay for the widgets you use.** WidgetKit is a small core (the widget base, containers, layouts and pooling) and parts, one per group of widget types plus the anchors and the options renderer, as Ace3 gives each AceGUI widget a file. An addon embeds the core and the parts it uses; a missing part is named, with the file to add, at the line that needed it.
- **Pooled and bounded.** Each widget type keeps the widgets it built on a free list, made by its first `Create`. The client never frees a frame, so a type builds at most 256 frames for the session (`nil, "exhausted"` beyond), and every released widget is kept for reuse.
- **Versioned.** `RegisterType(name, constructor, version)` ignores a lower version and, for a higher one, retires every pooled widget the older constructor built, so a widget is never reused with a shape its type no longer has.
- **A released widget is clean.** `Release` fires `OnRelease`, releases children last first, clears callbacks, user data, size requests and anchors, hides the frame and re-parents it. Releasing twice, or releasing something that is not a widget, is refused at your line. `IsReleasing()` sees a release anywhere above the widget.
- **Explicit layout.** `List`, `Fill` and `Flow` run when a child is added or when you call `PerformLayout`, never from `OnSizeChanged`; a layout pass inside a pass of the same container is refused rather than looped. Containers hold at most 256 children.
- **Long lists cost only the rows on display.** A `ScrollList` is built on the client's own ScrollBox framework (the same code on Retail, Mists of Pandaria Classic and Classic Era): ten thousand elements in a 200-pixel list of 20-pixel rows make 11 row frames, reused as it scrolls. Hand it an array of tables, a formatter returning each row's text and icon, and listen for `OnValueChanged` (a left click selects) and `OnClick`.
- **Bounded by default, opened on purpose.** Every cap has a documented default and a way to open it: `maxCallbacks` per type, `container:SetMaxChildren` (both accept `WidgetKit.UNBOUNDED`), `WidgetKit:SetLimits{ maxDropdownEntries }` and `WidgetKit:SetLimits{ maxListElements }` (both accept `UNBOUNDED`) and `WidgetKit:SetLimits{ maxCreatedCeiling }` (up to 16384; frames are never freed, so never unbounded). See *Limits* in the API.
- **Anchors you can save.** `WidgetKit.Anchor` elects the nearest of the nine points (`FromRect`), normalises any `SetPoint` argument form (`Normalize`), and applies and reads anchors. `BindPosition` saves a frame's anchor into any table, a SettingsKit scope view included, or into the table a function returns at each save (`function() return db.profile end` follows a profile switch), debounced through SchedulerKit when it is present. A save that fails is reported, never raised, and an anchor the client refuses leaves the frame where it was.
- **Options, rendered.** Every OptionsKit kind has a widget; `order`, `disabled` and `hidden` are honoured, writes go through `Validate` and `Set`, a refusal is shown in a line below the widget, and `OnChange` refreshes the widgets in place.
- **Secrets stay the caller's decision.** Text setters refuse a secret value unless you pass `{ allowSecret = true }` (an `EditBox` refuses one always: the client's edit box takes a secret only from untainted code), and a released widget never carries a secret into its next use.

See [`docs/API.md`](docs/API.md) for the complete contract, including the rules a widget author must follow, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout algorithms, the renderer and pooling.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. The core needs Registry alone; the parts load after it. The
embeds generator writes the list for the parts you choose, in a valid order:

```sh
# A window with labels, buttons, check boxes and an edit box:
python3 -m tooling.package.embeds widgetKit widgetKit/Containers widgetKit/Text widgetKit/Button widgetKit/CheckBox widgetKit/EditBox
# Rendering OptionsKit trees (the Renderer brings the type parts it draws with):
python3 -m tooling.package.embeds optionsKit widgetKit/Renderer
# Everything, as before revision 14:
python3 -m tooling.package.embeds 'widgetKit/*'
```

The first one writes:

```toc
Libs\MoltenCodes-Custom\registry\Registry.lua
Libs\MoltenCodes-Custom\widgetKit\WidgetKit.lua
Libs\MoltenCodes-Custom\widgetKit\parts\WidgetKit-Containers.lua
Libs\MoltenCodes-Custom\widgetKit\parts\WidgetKit-Text.lua
Libs\MoltenCodes-Custom\widgetKit\parts\WidgetKit-Button.lua
Libs\MoltenCodes-Custom\widgetKit\parts\WidgetKit-CheckBox.lua
Libs\MoltenCodes-Custom\widgetKit\parts\WidgetKit-EditBox.lua
```

| Part | Holds | Needs beyond the core |
|---|---|---|
| `Containers` | `Frame`, `Group`, `ScrollFrame` | |
| `Text` | `Label`, `Heading`, `Spacer` | |
| `Button` | `Button` (key capture included) | |
| `CheckBox` | `CheckBox` | |
| `Slider` | `Slider` | |
| `EditBox` | `EditBox` (single and multi-line) | |
| `Dropdown` | `Dropdown`, `CreateMediaPicker` | MediaKit when registered |
| `ColorPicker` | `ColorPicker` | |
| `ScrollList` | `ScrollList` | the client's ScrollBox framework |
| `Position` | `WidgetKit.Anchor`, `BindPosition` (and `Frame:BindPosition`) | SignalKit API 1 |
| `Renderer` | `RenderOptions`, `childGroups` pages | the type parts above but `ScrollList`; OptionsKit when rendering |

Direct runtime dependencies of the core: Registry API 2. The `Position` part
needs SignalKit API 1.

Optional, found with `Registry:Find` when they are used, so they may load in any
order:

| Kit | Used by | Without it |
|---|---|---|
| OptionsKit API 1 | `RenderOptions` | `RenderOptions` raises at the caller. |
| SchedulerKit API 1 with its `Coalescing` part | `BindPosition` | Every captured position is saved at once instead of debounced. |
| MediaKit API 1 | `CreateMediaPicker`, `RenderOptions` with `options.media` | `CreateMediaPicker` raises at the caller; the renderer shows the option's own `values`. |
| SettingsKit API 1 | nothing directly: a scope view, or a function returning one, is a valid `BindPosition` storage | Any plain table works. |

### Coming from AceGUI-3.0

| AceGUI-3.0 file | WidgetKit part |
|---|---|
| `AceGUI-3.0.lua` | the core, `WidgetKit.lua` |
| `AceGUIContainer-Frame.lua`, `-InlineGroup.lua`, `-SimpleGroup.lua`, `-ScrollFrame.lua` | `Containers` (`Frame`, `Group`, `ScrollFrame`) |
| `AceGUIWidget-Label.lua`, `-Heading.lua` | `Text` (`Label`, `Heading`, `Spacer`) |
| `AceGUIWidget-Button.lua`, `-Keybinding.lua` | `Button` (`SetKeyCapture`) |
| `AceGUIWidget-CheckBox.lua` | `CheckBox` |
| `AceGUIWidget-Slider.lua` | `Slider` |
| `AceGUIWidget-EditBox.lua`, `-MultiLineEditBox.lua` | `EditBox` (`SetMultiLine`) |
| `AceGUIWidget-DropDown.lua`, `-DropDown-Items.lua` | `Dropdown` |
| `AceGUIWidget-ColorPicker.lua` | `ColorPicker` |
| `AceConfigDialog-3.0` (drawing an options table) | `Renderer` |
| `AceGUIContainer-TabGroup.lua`, `-TreeGroup.lua`, `-DropDownGroup.lua` | the `Renderer`'s pages for `childGroups`; no container of their own yet |

AceGUI-3.0.xml loads every widget file; an addon embedding WidgetKit loads
only the parts it lists.

`ScrollList` also needs the client's ScrollBox framework (`Blizzard_SharedXML`,
on every supported client); without it `Create("ScrollList")` raises at the
caller and the other widgets work as before.

Taint, in short: WidgetKit creates every frame it scripts, except a
`ScrollList`'s rows, which Blizzard's ScrollBox view creates inside the list's
own calls and hands to it; it never writes a field onto a client frame and
calls no protected function. Its frames are ordinary insecure frames: use them
for configuration and display, never for protected actions. The client's
`ColorPickerFrame` is only opened through its own `SetupColorPickerAndShow`
method, after `IsForbidden` and `CanBeAccessedInContext` allow it.
