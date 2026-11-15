# TooltipKit API

TooltipKit API generation **1** draws keyed, pooled tooltips laid out in columns, with headers, separators, spans, colours, line handlers, a height limit with wheel scrolling, smart anchoring and auto-hide.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
TooltipKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local TooltipKit = MoltenCodes.Registries[2]:Get("tooltipKit", 1)
```

TooltipKit does not rely on `require()` at runtime.

### Host facilities

TooltipKit reads these host globals at call time, never at load:

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `UIParent` | `Acquire` (the first tooltip and line frames) | `Acquire` raises at the caller: `TooltipKit:Acquire needs the client's CreateFrame and UIParent, which this host does not have`. |
| the font objects `GameTooltipText` and `GameTooltipHeaderText` | lines and headers | Every client defines both. |
| `issecretvalue` | every check, every measured size | Nothing is treated as secret. |
| `geterrorhandler` | line handlers that raise | The failure is printed. |

## Public surface

| Member | Purpose |
|---|---|
| `Acquire(key, columns, ...)` | The tooltip acquired under `key`, or a new one with `columns` columns, each justified by the matching argument. |
| `Release(tooltip)` | Give the tooltip and its lines back to their pools, cleared. |
| `IsAcquired(key)` | Whether a tooltip is acquired under `key`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxTooltips`, `maxLines` and `maxColumns`; `GetLimits` returns a fresh table. |
| `MAX_TOOLTIPS`, `MAX_LINES`, `MAX_COLUMNS` | `16`, `256`, `16`: the defaults. |
| `TOOLTIPS_CEILING`, `LINES_CEILING`, `COLUMNS_CEILING` | `64`, `1024`, `32`: the highest each limit accepts. |
| `API`, `REVISION` | `1`, `1`. |

A tooltip:

| Method | Purpose |
|---|---|
| `AddHeader(...)` | Add a line in `GameTooltipHeaderText`, one value per column from the left; return its index. |
| `AddLine(...)` | Add a line in `GameTooltipText`; return its index. `nil` leaves a cell empty. |
| `AddSeparator(height?, r?, g?, b?, a?)` | Add a coloured line across the tooltip, `height` pixels (default 1, at most 100), default colour white at a quarter opacity; return its index. |
| `SetCell(line, column, text?, options?)` | Set one cell (below). `nil` empties it. |
| `SetCellTextColor(line, column, r, g, b, a?)` | Colour one cell's text. |
| `SetLineColor(line, r?, g?, b?, a?)` | Colour a line's background; no colour clears it. |
| `SetLineScript(line, script, handler?, arg?)` | Run `handler(lineFrame, arg, ...)` for the line's `OnMouseUp`, `OnEnter` or `OnLeave`; `nil` removes it. A line with a handler takes the mouse and highlights. |
| `Clear()` | Remove every line; the tooltip keeps its key and columns. |
| `SetMaxHeight(pixels?)` | Limit the height (at least 20); taller content scrolls with the mouse wheel. `nil` removes the limit. |
| `SmartAnchorTo(frame)` | Anchor to `frame` on the side with room (below). |
| `SetAutoHideDelay(seconds?, alternateFrame?)` | Release the tooltip once the cursor has been off it, its anchor and `alternateFrame` for `seconds`. `nil` stops it. |
| `Show()` / `Hide()` / `IsShown()` | Lay out and show; hide (the tooltip stays acquired); whether it is shown. |
| `GetLineCount()`, `GetColumnCount()` | Lines (separators included) and columns. |
| `GetFrame()` | The tooltip's frame, for an addon that styles it. |

## `TooltipKit:Acquire(key, columns, ...)`

`key` is a non-empty string, normally your addon's name and what the tooltip shows. `columns` is an integer from 1 to `maxColumns`. Each further argument justifies its column: `"LEFT"` (the default), `"CENTER"` or `"RIGHT"`.

When a tooltip is acquired under `key`, it is returned as it is, with its lines; acquiring it with another column count raises `TooltipKit:Acquire MyAddon is acquired with 2 columns, not 3`. Otherwise a tooltip frame is taken from the pool (made on first use) at the `TOOLTIP` strata, clamped to the screen, and returned hidden and empty. At most `maxTooltips` tooltips are acquired at once: `TooltipKit:Acquire holds at most 16 tooltips at once; release one, or raise maxTooltips`.

## Cells

`AddLine` and `AddHeader` take at most one value per column: `TooltipKit.Tooltip:AddLine got 3 values for 2 columns` otherwise. A value is a string, a number (shown with `tostring`) or `nil`; a secret is refused (`... value 2 must not be a secret value; pass { allowSecret = true } to SetCell to draw one`). At most `maxLines` lines, separators included.

`SetCell(line, column, text, options)` sets one cell of an existing line (a separator has none). `options`:

| Field | Meaning |
|---|---|
| `span` | How many columns the cell covers from its own, 1 to the columns left; default 1. The cells it covers are emptied, and a span an earlier cell of the line started that reached this column is shortened to end before it. |
| `justify` | `"LEFT"`, `"CENTER"` or `"RIGHT"`; default the column's. |
| `font` | A font object or its global name; default the line's font. |
| `allowSecret` | `true`: a secret `text` is drawn instead of refused. |

## Layout

Every column is as wide as its widest single-column cell. A spanning cell that needs more room than its columns and the gaps between them widens the last column it covers. A line is as tall as its tallest cell, 12 pixels when empty, or its separator's height. The tooltip adds 10 pixels of padding on every side and 10 between columns. A size the client measures as a secret counts as 0.

With a height limit, a taller tooltip is that tall, takes the mouse wheel and scrolls 24 pixels a notch, never past either end; a shorter one ignores the wheel.

## `tooltip:SmartAnchorTo(frame)`

Compares the frame's centre, in `UIParent`'s scale, with the middle of the screen: in the top half the tooltip hangs below the frame (`TOP` to `BOTTOM`), in the bottom half it sits above it; in the left half their left edges align, in the right half their right edges. The frame becomes the tooltip's anchor for auto-hide.

## `tooltip:SetAutoHideDelay(seconds, alternateFrame)`

While the tooltip is shown, every frame it asks `IsMouseOver()` of itself, its anchor and `alternateFrame`. While the cursor is over any of them nothing counts; once the time off all of them reaches `seconds`, the tooltip is released, exactly as `TooltipKit:Release`. A secret answer counts as off.

## Release

`TooltipKit:Release(tooltip)` gives every line back to the line pool (hidden, without anchors, no text, white text colour, no background, no handler, mouse off) and the tooltip frame back to its pool (hidden, no anchor, no auto-hide, no wheel, scrolled to the top). Both pools keep every frame they ever made, so the frame count stops growing at the largest tooltip shown. The handle is then refused by every method: `TooltipKit.Tooltip:AddLine must be called on an acquired TooltipKit tooltip; use tooltip:AddLine(...)`.

## Secret values

Every key, column count, justification, line and column index, option, colour component, limit and receiver is checked with `issecretvalue` first and refused at the caller. A secret text is refused unless the cell was set with `allowSecret`; a secret mouse-over answer counts as off; a secret wheel delta does nothing.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxTooltips`, tooltips acquired at once | `16` | `TooltipKit:SetLimits({ maxTooltips = n })` | no | `64`: each is a frame the session keeps |
| `maxLines`, lines in one tooltip | `256` | `TooltipKit:SetLimits({ maxLines = n })` | no | `1024`: each is a frame with a font string per column |
| `maxColumns`, columns of one tooltip | `16` | `TooltipKit:SetLimits({ maxColumns = n })` | no | `32` |

`SetLimits` accepts any subset and raises at the caller for an unknown field, a secret, or a value outside its range, before changing anything. The line pool's creation cap is `maxTooltips` times `maxLines`, raised with them and never lowered. The limits are shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line. Facade methods called without the facade raise `TooltipKit:Acquire must be called on the TooltipKit facade; use TooltipKit:Acquire(...)`. What the client calls (line handlers, the wheel, auto-hide) never raises; a handler's failure is reported through `geterrorhandler`.

## Performance

| Path | Cost |
|---|---|
| A hidden or idle tooltip | Nothing runs. |
| A change while shown | One layout pass over the lines. |
| An auto-hiding tooltip while shown | Up to three `IsMouseOver` calls per frame. |
| `Acquire`, `Release` | One pool operation each, plus one per line on release. |

## Embedded copies and upgrades

Several addons may embed TooltipKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the acquired tooltips, the pools and the limits. The pools' factories and resets, and the scripts every tooltip and line frame holds, call through a dispatch table in the shared state that every loading revision rewrites, so frames an older copy made run the newest copy's code.
