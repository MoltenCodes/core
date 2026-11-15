# Changelog

## 0.1.0 — 2026-11-15

- Added PanelKit API generation 1, implementation revision 1: an OptionsKit tree in Blizzard's settings panel, as recorded in `docs/ROADMAP.md` (package M).
- `PanelKit:Register(treeName, { name, parent })` registers a canvas category in the AddOns list, or a subcategory under a panel, through the client's `Settings` API; `PanelKit:Get(name, parent?)` finds one; `SetLimits` and `GetLimits` hold `maxPanels` (64 by default, 1024 at most, no unbounded setting).
- A panel: `Open()` (`Settings.OpenToCategory`; `nil, "unavailable"` without it), `GetName()`, `GetCategoryID()`, `GetRendering()` while the page is shown, `SetDefaultHandler(callback)` for the Defaults button.
- The page is drawn with `WidgetKit:RenderOptions` into a pooled `ScrollFrame` when Blizzard shows the canvas and released when it hides it. Blizzard's `OnRefresh` refreshes the rendering, or draws the page again when the tree under the name changed; `OnDefault` runs the handler, reporting what it raises, then refreshes.
- 48 specs, and a client suite, `tests/client/MoltenCodesTest_PanelKit`, not yet run in a client.
