# Changelog

## 0.1.2 — 2026-11-15

- Changed: PanelKit's WidgetKit contract names WidgetKit's `Renderer` part (`"widgetKit": { "api": 1, "parts": ["Renderer"] }`), so the embeds generator and the builder load the renderer and the type parts it draws with. WidgetKit 0.5.0 split into a core and parts, and its core holds a raising stand-in for `RenderOptions` until the part loads, so the load check now asks `WidgetKit:GetPartRevision("Renderer")` instead of the type of `RenderOptions`; with an older, single-file WidgetKit it still checks `RenderOptions`. Without the part, loading raises `MoltenCodes PanelKit requires WidgetKit API 1 with its Renderer part to be loaded first`.
- Implementation revision 2. No state changed: an in-place upgrade from revision 1 keeps every panel, the limit and the shown rendering.
- Specs: 51 (50 before): loading without the `Renderer` part. The test chain loads WidgetKit's parts and no longer PoolKit.

## 0.1.1 — 2026-11-15

Documentation and tests only; implementation revision 1 is unchanged.

- `docs/API.md` says when Blizzard calls a canvas (`Blizzard_SettingsPanel.lua`, branches `live`, `classic` and `classic_era`): `OnRefresh` right after every show, so a show is one render and one refresh; `OnDefault` on every canvas, hidden pages included, when the player resets all settings, so a default handler runs for a page that is not on screen; `OnCommit` never reaching a PanelKit canvas. It also lists every argument error message by method.
- The `Settings` stand-in refreshes a canvas right after showing it, as `DisplayLayout` does, and gains `DefaultAll()`; two specs cover both (50 specs). `tests/README.md` no longer claims `OnDefault` does nothing on a hidden page.
- The client suite's secret test called `PanelKit:Register(secret)` as a tail call inside its `pcall`, which leaves no line in the message, so its check for `PanelKitSuite.lua:` could never pass. It now keeps the result in a local.

## 0.1.0 — 2026-11-15

- Added PanelKit API generation 1, implementation revision 1: an OptionsKit tree in Blizzard's settings panel, as recorded in `docs/ROADMAP.md` (package M).
- `PanelKit:Register(treeName, { name, parent })` registers a canvas category in the AddOns list, or a subcategory under a panel, through the client's `Settings` API; `PanelKit:Get(name, parent?)` finds one; `SetLimits` and `GetLimits` hold `maxPanels` (64 by default, 1024 at most, no unbounded setting).
- A panel: `Open()` (`Settings.OpenToCategory`; `nil, "unavailable"` without it), `GetName()`, `GetCategoryID()`, `GetRendering()` while the page is shown, `SetDefaultHandler(callback)` for the Defaults button.
- The page is drawn with `WidgetKit:RenderOptions` into a pooled `ScrollFrame` when Blizzard shows the canvas and released when it hides it. Blizzard's `OnRefresh` refreshes the rendering, or draws the page again when the tree under the name changed; `OnDefault` runs the handler, reporting what it raises, then refreshes.
- 48 specs, and a client suite, `tests/client/MoltenCodesTest_PanelKit`, not yet run in a client.
