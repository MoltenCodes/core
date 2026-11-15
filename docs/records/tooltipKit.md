# tooltipKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## tooltipKit

**tooltipKit** — facade `TooltipKit`

1. Package `tooltipKit`, facade `TooltipKit`, API generation 1.
2. Purpose: tooltips laid out in columns, what LibQTip-1.0 gives addons
   that show a table on hover (a guild or friends list on a broker
   display, a currency or cooldown summary): a tooltip with a fixed number
   of columns, each with its own justification, lines added as rows of
   cells, a header and a separator, a cell spanning several columns, a
   colour per line or cell, a click or hover callback per line, a height
   limit past which the tooltip scrolls with the mouse wheel, smart
   anchoring to the frame that opened it (the side with room on screen),
   and an auto-hide delay once the cursor has left both. Each tooltip is
   keyed by its owner's name, so a second `Acquire` with the same key
   returns the open one. Tooltips, lines and cells come from PoolKit pools,
   because the client never frees a frame or a font string. Non-goals:
   changing `GameTooltip` (an addon keeps using it for one-column text),
   icons or custom widgets inside cells (later, if an addon needs them),
   sorting or filtering the rows.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent` and the client's font objects
   (the auto-hide check asks each frame's `IsMouseOver`, so
   `GetCursorPosition` turned out not to be needed).
4. Surface: `TooltipKit:Acquire(key, columns, ...justify)` → tooltip (an
   open tooltip under `key` is returned as it is); `TooltipKit:Release(
   tooltip)`; `TooltipKit:IsAcquired(key)`; on a tooltip: `AddHeader(...)`
   and `AddLine(...)` → line index, `AddSeparator(height?, r, g, b, a)`,
   `SetCell(line, column, text, options?)` (`span`, `justify`, `font`,
   `allowSecret`), `SetLineColor` (the line's background) and
   `SetCellTextColor` (a cell's text; it replaced the planned
   `SetCellColor`, because lists colour names, not boxes), `SetLineScript(line,
   script, handler, arg)` for `OnMouseUp`, `OnEnter`, `OnLeave`, `Clear()`,
   `SetMaxHeight(pixels|nil)`, `SmartAnchorTo(frame)`,
   `SetAutoHideDelay(seconds|nil, alternateFrame?)`, `Show()`, `Hide()`,
   `IsShown()`, `GetLineCount()`, `GetColumnCount()`, `GetFrame()`; `SetLimits{ maxTooltips, maxLines, maxColumns }` /
   `GetLimits()`.
5. Ownership: a tooltip is borrowed from the moment `Acquire` returns it
   until `Release` (or its auto-hide, which releases it); a released
   tooltip and every line and cell go back to their pools, cleared, so no
   text, colour or script survives into the next use. A tooltip whose
   owner key is released while hidden is gone; `IsAcquired` says so.
6. Performance and memory: layout runs once per change batch, when the
   tooltip is shown or a line is added while it is shown, never per frame;
   only an auto-hiding tooltip runs code per frame (one cursor check), and
   only while shown. Defaults: 16 tooltips acquired at once, 256 lines per
   tooltip, 16 columns; lines and columns have ceilings (1024, 32) and no
   `UNBOUNDED`, because every line and cell is a region the session keeps;
   `maxTooltips` has a ceiling of 64.
7. Tests: a stand-in for the client's frames and font metrics through the
   shared frame stub; acquire by key and reuse, release and reuse with
   nothing left behind, columns and justification, headers, separators,
   spans, colours, line scripts and one that raises reported, the height
   limit and wheel scrolling, smart anchoring on each side of the screen,
   auto-hide timing and the alternate frame, limits and ceilings, secret
   texts refused without `allowSecret` and drawn with it, upgrade,
   manifest, error levels. A client suite on Retail: a tooltip with a
   header, three columns and a span drawn and measured with the client's
   fonts, scrolled, anchored and auto-hidden, and released with every pool
   back to its count.
8. Docs: README (with the migration from LibQTip-1.0), API.md, CHANGELOG,
   tests/README; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   43 specs; the client suite (`tests/client/MoltenCodesTest_TooltipKit`)
   is written and has not been run in a client. Ticked once it has.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 46 specs
   (cells measured with `GetUnboundedStringWidth`; both `GetCenter`
   coordinates checked for secrets).

