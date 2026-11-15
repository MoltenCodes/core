# panelKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## panelKit

**panelKit** — facade `PanelKit`

1. Package `panelKit`, facade `PanelKit`, API generation 1.
2. Purpose: put an addon's OptionsKit tree in Blizzard's settings panel
   (the AddOns tab), as a category or a subcategory of one, drawn by
   WidgetKit's renderer only while the page is shown — Ace3's
   `AceConfigDialog:AddToBlizOptions`. It wraps `Settings.RegisterCanvasLayoutCategory`,
   `Settings.RegisterCanvasLayoutSubcategory`, `Settings.RegisterAddOnCategory`
   and `Settings.OpenToCategory`, which Retail, Mists of Pandaria Classic and
   Classic Era ship with the same code (Blizzard's `Blizzard_Settings_Shared`,
   branches `live`, `classic` and `classic_era`, read 2026-11-15).
   Non-goals: building widgets or laying them out (WidgetKit), the option
   model (OptionsKit), Blizzard's own vertical-layout controls, a standalone
   window, the old `InterfaceOptions_AddCategory` API (no promised client
   lacks `Settings`).
3. Dependencies: registry API 2, widgetKit API 1 and optionsKit API 1, all
   required (panelKit has nothing to draw without them). Host requirement:
   the client's `Settings` table.
4. Surface: `PanelKit:Register(treeName, options?)` → panel, with
   `options.name` (the title in the list; default the tree's name) and
   `options.parent` (a panel, for a subcategory); `panel:Open()` → `true`,
   or `nil` and a reason; `panel:GetCategoryID()`; `panel:GetRendering()`
   (`nil` while hidden); `panel:SetDefaultHandler(callback|nil)`, run by the
   panel's Defaults button; `PanelKit:Get(name, parent?)`;
   `SetLimits{ maxPanels }` / `GetLimits()`. (A sorted `Panels()` was
   dropped while building: names are unique per level, so `Get` with the
   parent finds every panel, and nothing needed the list.)
5. Ownership: Blizzard cannot unregister a category, so a panel lives for
   the session, with one plain frame created at `Register`. The tree is
   found by name with `OptionsKit:Get` each time the page is shown, so
   redefining it is picked up and an undefined tree shows one line saying
   so. On show a WidgetKit `ScrollFrame` is acquired and the tree rendered
   into it; on hide both go back to their pools. Blizzard's `OnRefresh`
   refreshes the rendering, `OnDefault` runs the default handler (nothing
   without one), and `OnCommit` has nothing to do: OptionsKit writes at
   once. The frame's scripts call through the facade, so an upgraded
   revision runs its own code.
6. Performance and memory: no widget exists while a page is hidden;
   `Register` costs one frame and one category; showing a page costs one
   render. `maxPanels` defaults to 64; it has a ceiling (1024) and no
   `UNBOUNDED`, because neither frames nor categories are ever freed.
7. Tests: a stand-in `Settings` that records categories and fires
   `OnShow`, `OnHide`, `OnRefresh` and `OnDefault`; top-level and
   subcategory registration, name and parent validation, duplicate names
   refused, the limit and its ceiling, render on show and every widget back
   in its pool on hide, refresh, an undefined and a redefined tree, a
   raising default handler reported and not raised, `Open` and its reasons,
   secret names refused, upgrade, manifest, error levels. A client suite on
   Retail: register, open by category ID (a subcategory included), show and
   hide with the pools balanced, and what `Open` does in combat
   (`C_SettingsUtil.OpenSettingsPanel` is flagged `HasRestrictions`, which
   Blizzard does not document).
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING footprint and
   host-requirements rows; ARCHITECTURE's package list; the
   `AddToBlizOptions` recipe in `MIGRATING_FROM_ACE3.md`.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   48 specs; the client suite (`tests/client/MoltenCodesTest_PanelKit`) is
   written and has not been run in a client. Ticked once it has.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 1
   (documentation and tests only), 50 specs.

