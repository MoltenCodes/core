# PanelKit Tests

The PanelKit suite covers:

- `Register`: a canvas category in the AddOns list named after the tree or `options.name`, a subcategory under a parent panel left out of the AddOns list, the category ID read through `GetID` or the `ID` field, a name refused at the same level and accepted under another parent, every argument refusal registering nothing, a host without the Settings API, `Get` at the top and under a parent, facade and panel receivers, and the hidden metatable;
- pages: nothing drawn before the page is shown; the tree rendered into a `ScrollFrame` on the canvas, inset 8 pixels, when the stand-in panel shows it; every widget back in its pool when the page is hidden, by another page or by closing the panel, and the same count drawn again on the next show; writes through the rendered widgets; one line while no tree has the name and the tree after a refresh once it is defined; `OnRefresh` refreshing in place and drawing a redefined or undefined tree again; `OnRefresh` on a hidden page doing nothing; the refresh Blizzard sends right after a show keeping the rendering; the default handler run with the panel and followed by a refresh, removed with `nil`, run for a hidden page by a reset of all settings, and reported when it raises; a tree that fails to render, a `ScrollFrame` and a `Label` WidgetKit cannot hand out, each reported with the page left empty; a subcategory drawing its own tree; `Open` answering `"unavailable"`; `SetDefaultHandler`'s argument;
- the limit: defaults, constants and fresh tables, `maxPanels` refusing at the caller with subcategories counted, lowered without removing panels, the ceiling accepted, out-of-range, non-integer and non-number values and unknown fields refused without changing the limit;
- secret values: a secret tree name, title, options table, option key, parent, `Get` name and parent, limits table, limit key and value, and receiver, each refused at the caller through an `issecretvalue` stub;
- `error` levels: every argument failure of `Register`, `Get`, `SetLimits`, `GetLimits` and the panel methods reports the caller's own line;
- Registry publication, a duplicate embedded load keeping panels, yielding to a newer revision, an in-place upgrade keeping panels, the limit and the shown rendering while a canvas registered before the upgrade runs the new code, a refusal of state holding an invalid limit, missing Registry, WidgetKit or OptionsKit, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/PanelKitTestEnv.lua` provides `UIParent`, a stand-in for Blizzard's `Settings` (`InstallSettings`) that registers canvas categories and subcategories, keeps the AddOns list, shows one canvas at a time on `OpenToCategory` and refreshes it right after the show as Blizzard's `DisplayLayout` does, calls `OnRefresh` and `OnDefault` on the shown canvas and `OnDefault` on every canvas (`DefaultAll`), a small tree (`DefineTree`), the secret probe and `LoadRevision`; `Reset` removes `Settings`.

| Spec | Covers |
|---|---|
| `Register_spec.lua` | `Register`, `Get`, receivers |
| `Page_spec.lua` | drawing, releasing, refresh, defaults, failures, `Open` |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `maxPanels` |
| `SecretValues_spec.lua` | secret arguments and receivers |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
