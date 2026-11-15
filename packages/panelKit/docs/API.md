# PanelKit API

PanelKit API generation **1** puts an OptionsKit tree in Blizzard's settings panel, as a category in the AddOns list or a subcategory under one, through the client's Settings API, and draws it with WidgetKit's renderer only while its page is shown.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
PoolKit.lua
SchemaKit.lua
OptionsKit.lua
WidgetKit.lua
PanelKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local PanelKit = MoltenCodes.Registries[2]:Get("panelKit", 1)
```

PanelKit does not rely on `require()` at runtime.

### Host facilities

PanelKit reads these host globals at call time, never at load:

| Facility | Used by | Without it |
|---|---|---|
| `Settings.RegisterCanvasLayoutCategory`, `Settings.RegisterCanvasLayoutSubcategory`, `Settings.RegisterAddOnCategory` | `Register` | `Register` raises at the caller: `PanelKit:Register needs the client's Settings API, which this host does not have`. |
| `Settings.OpenToCategory` | `panel:Open` | `Open` answers `nil, "unavailable"`. |
| `CreateFrame` | `Register` (one frame per panel) | Required. |
| `issecretvalue` | every argument check | Nothing is treated as secret. |
| `geterrorhandler` | a page that cannot be drawn, a default handler that raises | The failure is printed. |

Retail, Mists of Pandaria Classic and Classic Era ship the four `Settings` functions with the same code (`Blizzard_Settings_Shared`, branches `live`, `classic` and `classic_era` of Blizzard's interface source, read 2026-11-15), so on every promised client they are there. PanelKit does not fall back to the pre-10.0 `InterfaceOptions_AddCategory`.

## Public surface

| Member | Purpose |
|---|---|
| `Register(treeName, options?)` | Register a page for the tree `OptionsKit:Get(treeName)` answers; return its panel. |
| `Get(name, parent?)` | The panel registered as `name`, at the top or under `parent`, or `nil`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxPanels`; `GetLimits` returns a fresh table. |
| `MAX_PANELS` | `64`, the default `maxPanels`. |
| `PANELS_CEILING` | `1024`, the highest `maxPanels` accepts. |
| `API`, `REVISION` | `1`, `1`. |

A panel:

| Method | Purpose |
|---|---|
| `Open()` | Open Blizzard's settings panel on this page: `true`, or `nil, "unavailable"` without `Settings.OpenToCategory`. |
| `GetName()` | The title in the settings list. |
| `GetCategoryID()` | The ID Blizzard gave the category, as `Settings.OpenToCategory` takes it. |
| `GetRendering()` | The WidgetKit rendering while the page is shown, otherwise `nil`. |
| `SetDefaultHandler(callback?)` | What the page's Defaults button runs, `callback(panel)`; `nil` removes it. |

## `PanelKit:Register(treeName, options?)`

`treeName` is the name the tree was defined under, `OptionsKit:Define(treeName, ...)`. `options` accepts:

| Field | Meaning |
|---|---|
| `name` | The title in the settings list, a non-empty string. Default: `treeName`. |
| `parent` | A panel `Register` returned: this page becomes a subcategory under it. |

Without `parent`, PanelKit calls `Settings.RegisterCanvasLayoutCategory(frame, name)` and then `Settings.RegisterAddOnCategory(category)`, so the page is listed in the AddOns tab. With `parent`, it calls `Settings.RegisterCanvasLayoutSubcategory(parent's category, frame, name)`, which Blizzard lists under the parent. The category ID is read with `category:GetID()`, or the category's `ID` field when it has no `GetID`.

`Register` raises at the caller, and registers nothing, when:

- `treeName` or `options.name` is not a non-empty string, or is a secret;
- `options` is not a table or `nil`, holds a field other than `name` and `parent`, or `options.parent` is not a panel;
- a panel of that name is already registered at the same level (the top, or under the same parent): `PanelKit:Register a panel named General is already registered there`. The same name under two parents is fine;
- `maxPanels` panels are registered: `PanelKit:Register holds at most 64 panels; raise maxPanels with PanelKit:SetLimits`;
- the client has no Settings API.

The tree does not need to exist yet: it is looked up when the page is shown.

## What a page shows, and when

Each panel owns one frame, created by `Register` without a parent and hidden: the canvas. Blizzard's panel parents, anchors and shows it when the player selects the page, and hides it when the player selects another page or closes the panel.

| Blizzard does | PanelKit does |
|---|---|
| shows the canvas (`OnShow`) | Acquires a WidgetKit `ScrollFrame`, parents it to the canvas 8 pixels inside its edges, and renders `OptionsKit:Get(treeName)` into it with `WidgetKit:RenderOptions`. With no tree under that name, the scroll frame holds one `Label`: `No options are defined for MyAddon.` |
| hides the canvas (`OnHide`) | Releases the scroll frame, which releases the rendering and every widget it drew back to their pools. |
| calls `OnRefresh` on the shown canvas | When `OptionsKit:Get(treeName)` is still the tree drawn, `rendering:Refresh()`. When it is another tree, or none, the page is drawn again. |
| calls `OnDefault` (the Defaults button) | Runs the default handler, if any, with the panel; then refreshes as above. |
| calls `OnCommit` | Nothing: a canvas without `OnCommit` is skipped, and OptionsKit writes every change at once. |

A page whose tree is undefined or redefined while it is shown keeps what it drew until the next refresh or show; the rendering itself follows `tree:OnChange` as WidgetKit documents.

**Failures are reported, never raised.** These calls come from Blizzard's panel, so nothing PanelKit does there raises into it. A `ScrollFrame` or `Label` WidgetKit cannot hand out (`exhausted`) is reported as `PanelKit could not draw the page MyAddon: no ScrollFrame is free`, and the page stays empty until it is shown again. A `RenderOptions` that raises (an option function that raises, a full container) is reported with WidgetKit's message, and the page holds the empty scroll frame. A default handler that raises is reported, and the page is still refreshed.

## `panel:Open()`

Calls `Settings.OpenToCategory(panel:GetCategoryID())` and answers `true`. Blizzard opens the panel and selects the page, which shows its canvas. Blizzard marks the function it calls, `C_SettingsUtil.OpenSettingsPanel`, as `HasRestrictions` without documenting the restriction; what it does in combat is measured by the client suite, not assumed here.

## Secret values

Every argument is checked with `issecretvalue` before anything else touches it: a secret `treeName`, `options.name` or limit value is refused with `... must not be a secret value`; a secret `options`, `parent`, receiver or option key is refused as the wrong kind of value. Names are never secret afterwards, so the messages PanelKit builds from them are plain strings.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxPanels`, panels in the session, subcategories included | `64` | `PanelKit:SetLimits({ maxPanels = n })` | no | `1024`: each panel is a frame and a category the session keeps until logout; neither can be freed |

`SetLimits` accepts `maxPanels` alone and raises at the caller for any other field, a secret, or a value that is not an integer from 1 to 1024, before changing anything. Lowering it below the number registered keeps every panel and refuses the next `Register`. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line. Facade methods called without the facade (`PanelKit.Register(nil, ...)`) raise `PanelKit:Register must be called on the PanelKit facade; use PanelKit:Register(...)`; panel methods called on anything but a panel raise `PanelKit.Panel:Open must be called on a PanelKit panel; use panel:Open(...)`. What Blizzard's panel calls is reported through `geterrorhandler`, as above.

## Performance

| Path | Cost |
|---|---|
| `Register` | One frame, one category, two small tables. |
| A hidden page | Nothing beyond its frame and record: no widget. |
| Showing a page | One `RenderOptions` (WidgetKit's cost, allocation included). |
| Hiding a page | One `WidgetKit:Release`; every widget returns to its pool. |
| `Get`, the panel getters | One or two table lookups, no allocation. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed PanelKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the panels, their records, the limit and the canvas frames. A canvas frame keeps the scripts and fields it was given for the session, because Blizzard holds it; those call through a dispatch table in the shared state that every loading revision rewrites, so a canvas registered by an older copy runs the newest copy's code. A panel handle reaches its methods through a shared prototype that every revision rewrites as well.
