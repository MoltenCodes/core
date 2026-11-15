# Changelog

## 0.1.1 — 2026-11-15

Implementation revision 2. A revision-1 copy loaded first is upgraded in place.

- Fixed: a cell was measured with `GetStringWidth`, which in the client never answers more than the width the font string was given. Every layout gives each cell a width, so a cell whose text grew on a shown tooltip, or a pooled line reused for longer text, was measured at its old width and drawn truncated. Cells are now measured with `GetUnboundedStringWidth`, which Retail, Mists of Pandaria Classic and Classic Era have, and with `GetStringWidth` only on a font string without it. Spec: `Tooltip_spec.lua`, "measures a cell's whole text, not the width the last layout gave it, when it grows or its line is reused".
- Fixed: `SmartAnchorTo` asked `issecretvalue` about the horizontal centre coordinate only. The client answers `GetCenter` with secrets for a frame anchored to a secret, and a secret number is a `number` to `type`, so a secret vertical coordinate was compared and raised. Both coordinates are now checked, and a frame without `GetEffectiveScale` falls back to the default side as well. Spec: `SecretValues_spec.lua`, "anchors to the default side when the client answers either centre coordinate as secret".
- Upgrade spec: `Bootstrap_spec.lua`, "upgrades a revision-1 copy in place, and its tooltips lay out with the new measuring".
- Client suite: the secret test no longer calls `AddLine` as a tail call, which dropped its file and line from the message it checks; a new layout test grows a cell on a shown tooltip.
- Docs: `docs/API.md` lists every error message, the client facilities each method uses, the anchor a tooltip needs before `Show`, the side `SmartAnchorTo` falls back to, and how `SetCellTextColor` and `SetLineColor` on a separator behave.

## 0.1.0 — 2026-11-15

- Added TooltipKit API generation 1, implementation revision 1: multi-column tooltips, as recorded in `docs/ROADMAP.md` (package M).
- `TooltipKit:Acquire(key, columns, ...justify)` returns the tooltip acquired under the key or a new one; `TooltipKit:Release`, `TooltipKit:IsAcquired`; `SetLimits` and `GetLimits` for `maxTooltips` (16, up to 64), `maxLines` (256, up to 1024) and `maxColumns` (16, up to 32).
- A tooltip: `AddHeader`, `AddLine`, `AddSeparator`, `SetCell` with `span`, `justify`, `font` and `allowSecret`, `SetCellTextColor`, `SetLineColor`, `SetLineScript` (`OnMouseUp`, `OnEnter`, `OnLeave`, run protected), `Clear`, `SetMaxHeight` (wheel scrolling), `SmartAnchorTo`, `SetAutoHideDelay`, `Show`, `Hide`, `IsShown`, `GetLineCount`, `GetColumnCount`, `GetFrame`.
- Tooltips and lines come from PoolKit pools that keep every released frame; a release clears every text, colour, handler and anchor.
- 43 specs, and a client suite, `tests/client/MoltenCodesTest_TooltipKit`, not yet run in a client.
