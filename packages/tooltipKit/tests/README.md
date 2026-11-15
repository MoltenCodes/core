# TooltipKit Tests

The TooltipKit suite covers:

- tooltips: acquire by key and the same key returning the open tooltip, a different column count refused, the `TOOLTIP` strata and the hidden metatable; columns as wide as their widest cell and justified as acquired, the frame's size, header and line fonts; a cell measured by its whole text with the client's bounded `GetStringWidth` stood in for, after it grew on a shown tooltip and on a pooled line reused for longer text; a span widening its last column; a span emptying the cells it covers, a later cell shortening an earlier span, a span past the last column refused, and a cell emptied with `nil`; separators, line backgrounds, cell text colours, a cleared line colour and a separator refusing cells; layout again when a shown tooltip changes, and `Clear`; line handlers with the line frame, their argument and the mouse button, one that raises reported, and handlers removed with the mouse off again; the height limit, wheel scrolling clamped at both ends and the limit removed; smart anchoring in each quarter of the screen; auto-hide counting only the time off the tooltip, its anchor and the alternate frame, then releasing; auto-hide stopped with `nil`; and `Hide` keeping the tooltip acquired;
- pools: the tooltip and every line given back on `Release` and reused cleared (no text, colour, handler, anchor, auto-hide or height limit), a released handle refused, and frames kept so the created count stops growing;
- argument checks of every method, a host without `UIParent`, and the facade and tooltip receivers;
- the limits: defaults, constants and fresh tables, `maxTooltips` refusing and freed by `Release`, `maxLines` with separators and headers counted, `maxColumns` at `Acquire`, the line pool's creation cap raised and never lowered, and invalid values refused without changing any;
- secret values: secret texts refused in `AddLine`, `AddHeader` and `SetCell` without `allowSecret` and drawn with it, secret sizes counted as 0, secret keys, columns, justifications, lines, options, colours, limits and receivers refused, a secret mouse-over answer counted as off, a secret wheel delta ignored, and either `GetCenter` coordinate answered secret anchoring to the default side;
- `error` levels: every argument failure reports the caller's own line;
- Registry publication, a duplicate embedded load keeping tooltips, yielding to a newer revision, an in-place upgrade keeping tooltips, pools and limits while line handlers and auto-hide made before it run the new code, a revision-1 copy upgraded in place to the shipped revision, a refusal of state holding an invalid limit, missing Registry or PoolKit, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/TooltipKitTestEnv.lua` provides `UIParent`, `FrameAt` (a frame at a screen position), `SetMouseOver` (an `IsMouseOver` answer, which the shared stub does not model), `BoundStringWidths` (font strings measuring as the client's do: `GetStringWidth` stopped at the width given, and `GetUnboundedStringWidth`), `Run` (a frame's script), `TakeReportedValues`, the secret probe and `LoadRevision`. Specs read line frames from the package state.

| Spec | Covers |
|---|---|
| `Tooltip_spec.lua` | acquiring, layout, cells, colours, handlers, scrolling, anchoring, auto-hide |
| `Pools_spec.lua` | `Release` and reuse |
| `Arguments_spec.lua` | argument and receiver checks |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, the three limits |
| `SecretValues_spec.lua` | secret texts, sizes, arguments and answers |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
