# Changelog

## 0.1.0 — 2026-09-23

- Added WidgetKit API generation 1, implementation revision 1.
- Added the type registry: `RegisterType(name, constructor, version, options?)` (a lower version is ignored with `false, "older"`, an equal one with `false, "current"`; a higher one retires every pooled widget of older versions through PoolKit generation stamps and raises the frame cap by what it retired), `GetTypeVersion`, `Create` (`nil, "unknownType"` / `nil, "exhausted"`), `Release`, `IsWidget`, `SetFocus` / `ClearFocus` / `GetFocus` and `GetStatistics`. One capped PoolKit pool per type; `MAX_CREATED` is 256 frames per type unless a registration asks for up to 4096.
- Added the widget base (`WidgetKit.Widget`): named callbacks (`SetCallback`, `Fire`; 16 per widget, errors isolated and reported), user data, size requests (`SetFullWidth`, `SetFullHeight`, `SetRelativeWidth`), size, anchor and visibility methods forwarded to the frame, `SetParent`, `IsReleasing` (ancestor-aware), `GetType`, `GetFrame`, `GetParentContainer` and `Release`.
- Added the container base (`WidgetKit.Container`): `AddChild` (with `beforeWidget`), `AddChildren`, `ReleaseChildren`, `GetChildren`, `SetLayout`, `PauseLayout` / `ResumeLayout`, `PerformLayout` (explicit; a pass inside a pass of the same container returns `false, "recursion"`) and the upward `LayoutFinished` report; `MAX_CHILDREN` is 256.
- Added the `List`, `Fill` and `Flow` layouts and `RegisterLayout` / `GetLayout`; layouts borrow a scratch table from a PoolKit table pool.
- Added the base widgets `Frame`, `Group`, `ScrollFrame`, `Label`, `Button` (with key capture), `CheckBox` (with a third state), `Slider`, `EditBox` (single and multi-line), `Dropdown`, `ColorPicker`, `Heading` and `Spacer`, each at version 1.
- Added `WidgetKit.Anchor` (`FromRect`, `Normalize`, `Apply`, `Read`, `POINTS`) and `BindPosition` with bindings (`Capture`, `Restore`, `Flush`, `OnMoved`, `Release`), saving plain anchor tables into any storage table, debounced through SchedulerKit when it is registered.
- Added `RenderOptions(tree, container, options?)`, rendering every OptionsKit kind with `Validate`-then-`Set` writes, inline refusals, `OnChange` refreshes and a rendering handle (`Refresh`, `Rebuild`, `Release`, `GetWidget`, `GetMessage`), and `CreateMediaPicker(mediaType)` over MediaKit.
- Text setters refuse secret values unless `options.allowSecret` is `true`; released widgets clear their text.
- The shared test fixture's `FrameStub` now models sizes, anchors, regions and the frame types widgets use.
- 110 specs, including allocation guards on acquire/release cycles and on `PerformLayout`, and in-place upgrade specs.
