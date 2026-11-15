# Changelog

## 0.1.0 — 2026-11-15

- Added TooltipKit API generation 1, implementation revision 1: multi-column tooltips, as recorded in `docs/ROADMAP.md` (package M).
- `TooltipKit:Acquire(key, columns, ...justify)` returns the tooltip acquired under the key or a new one; `TooltipKit:Release`, `TooltipKit:IsAcquired`; `SetLimits` and `GetLimits` for `maxTooltips` (16, up to 64), `maxLines` (256, up to 1024) and `maxColumns` (16, up to 32).
- A tooltip: `AddHeader`, `AddLine`, `AddSeparator`, `SetCell` with `span`, `justify`, `font` and `allowSecret`, `SetCellTextColor`, `SetLineColor`, `SetLineScript` (`OnMouseUp`, `OnEnter`, `OnLeave`, run protected), `Clear`, `SetMaxHeight` (wheel scrolling), `SmartAnchorTo`, `SetAutoHideDelay`, `Show`, `Hide`, `IsShown`, `GetLineCount`, `GetColumnCount`, `GetFrame`.
- Tooltips and lines come from PoolKit pools that keep every released frame; a release clears every text, colour, handler and anchor.
- 43 specs, and a client suite, `tests/client/MoltenCodesTest_TooltipKit`, not yet run in a client.
