# TooltipKit API

TooltipKit API generation **1** draws keyed, pooled tooltips laid out in columns, with headers, separators, spans, colours, line handlers, a height limit with wheel scrolling, smart anchoring and auto-hide.

Implementation revision: **2**.

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
| the font objects `GameTooltipText` and `GameTooltipHeaderText` | lines and headers | Every promised client defines both (`Blizzard_Fonts_Shared/Shared/FontStyles.xml`, branches `live`, `classic` and `classic_era`, read 2026-11-15). |
| `FontString:GetUnboundedStringWidth` | measuring a cell | The cell is measured with `GetStringWidth`. Every promised client has it (`SimpleFontStringAPIDocumentation.lua` on the same three branches). |
| `issecretvalue` | every check, every measured size; read once at load, and again on each check only when it was absent at load | Nothing is treated as secret. |
| `geterrorhandler` | line handlers that raise | The failure is printed. A handler that itself raises is not propagated either: the failure is printed instead. |

Every other client call is a method of the frames and font strings TooltipKit made, or of the frame passed to `SmartAnchorTo` (`GetCenter`, `GetEffectiveScale`, `IsMouseOver`).

## Public surface

| Member | Purpose |
|---|---|
| `Acquire(key, columns, ...)` | The tooltip acquired under `key`, or a new one with `columns` columns, each justified by the matching argument. |
| `Release(tooltip)` | Give the tooltip and its lines back to their pools, cleared. |
| `IsAcquired(key)` | Whether a tooltip is acquired under `key`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxTooltips`, `maxLines` and `maxColumns`; `GetLimits` returns a fresh table. |
| `MAX_TOOLTIPS`, `MAX_LINES`, `MAX_COLUMNS` | `16`, `256`, `16`: the defaults. |
| `TOOLTIPS_CEILING`, `LINES_CEILING`, `COLUMNS_CEILING` | `64`, `1024`, `32`: the highest each limit accepts. |
| `API`, `REVISION` | `1`, `2`. |

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

When a tooltip is acquired under `key`, it is returned as it is, with its lines; acquiring it with another column count raises `TooltipKit:Acquire MyAddon is acquired with 2 columns, not 3`. Otherwise a tooltip frame is taken from the pool (made on first use) at the `TOOLTIP` strata, parented to `UIParent`, clamped to the screen, and returned hidden, empty and without a position: anchor it with `SmartAnchorTo`, or through `GetFrame()`, before `Show`, or the client has nowhere to draw it. Justifications past `columns` are ignored, and a tooltip returned under an acquired key keeps the justifications it was acquired with. At most `maxTooltips` tooltips are acquired at once: `TooltipKit:Acquire holds at most 16 tooltips at once; release one, or raise maxTooltips`.

## Cells

`AddLine` and `AddHeader` take at most one value per column: `TooltipKit.Tooltip:AddLine got 3 values for 2 columns` otherwise. A value is a string, a number (shown with `tostring`) or `nil`; a secret is refused (`... value 2 must not be a secret value; pass { allowSecret = true } to SetCell to draw one`). At most `maxLines` lines, separators included.

`SetCell(line, column, text, options)` sets one cell of an existing line (a separator has none: `TooltipKit.Tooltip:SetCell line 2 is a separator and has no cells`). `line` is an index `AddLine`, `AddHeader` or `AddSeparator` returned, `column` an integer from 1 to the tooltip's columns. `options`:

| Field | Meaning |
|---|---|
| `span` | How many columns the cell covers from its own, 1 to the columns left; default 1. The cells it covers are emptied, and a span an earlier cell of the line started that reached this column is shortened to end before it. |
| `justify` | `"LEFT"`, `"CENTER"` or `"RIGHT"`; default the column's. |
| `font` | A font object or its global name; default the line's font. |
| `allowSecret` | `true`: a secret `text` is drawn instead of refused. |

A font name the client does not know is passed to `FontString:SetFontObject` as it is, and what the client does with it is not checked.

`SetCellTextColor` colours a cell's text whether or not it holds one, and the colour stays through later `SetCell` calls until the line is released. `SetLineColor` on a separator replaces the separator's colour; without a colour it clears it.

## Layout

Every column is as wide as its widest single-column cell. A cell is measured with `GetUnboundedStringWidth`, the width its whole text needs: the client's `GetStringWidth` never answers more than the width the layout last gave the font string (warcraft.wiki.gg, `API FontString GetUnboundedStringWidth`), so a text that grew, or a pooled line reused for longer text, would otherwise be measured truncated (fixed in revision 2). A spanning cell that needs more room than its columns and the gaps between them widens the last column it covers. A line is as tall as its tallest cell, 12 pixels when empty, or its separator's height. The tooltip adds 10 pixels of padding on every side and 10 between columns. A size the client measures as a secret counts as 0.

With a height limit, a taller tooltip is that tall, takes the mouse wheel and scrolls 24 pixels a notch, never past either end; a shorter one ignores the wheel.

## `tooltip:SmartAnchorTo(frame)`

`frame` is any region with `GetCenter` (a frame, a texture, a font string): `TooltipKit.Tooltip:SmartAnchorTo frame must be a frame` otherwise. The method compares the frame's centre, in `UIParent`'s scale, with the middle of the screen: in the top half the tooltip hangs below the frame (`TOP` to `BOTTOM`), in the bottom half it sits above it; in the left half their left edges align, in the right half their right edges. The frame becomes the tooltip's anchor for auto-hide. When the frame has no position yet (`GetCenter` answers nothing), when either coordinate or a scale is a secret (the client answers secrets for a frame anchored to a secret), or when `UIParent` cannot be measured, the tooltip sits above the frame, left edges aligned. Revision 1 compared a secret vertical coordinate, which raises on Retail.

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

A failure of a line handler goes to the host error handler (`geterrorhandler()`), called under `pcall`. When the client has no handler, or the handler itself raises (an error-display addon with a bug), the failure is printed instead, so reporting it never raises into the client's script call (revision 3; earlier revisions let a raising handler's error through).

Argument errors raise at the caller's line, before anything changes. Facade methods called without the facade raise `TooltipKit:Acquire must be called on the TooltipKit facade; use TooltipKit:Acquire(...)`; tooltip methods called on anything but an acquired tooltip raise `TooltipKit.Tooltip:AddLine must be called on an acquired TooltipKit tooltip; use tooltip:AddLine(...)`. The other messages, with `<method>` the method's full name (`TooltipKit.Tooltip:SetCell`):

| Message | When |
|---|---|
| `TooltipKit:Acquire key must be a non-empty string`, `... key must not be a secret value` (also `TooltipKit:IsAcquired`) | the key |
| `TooltipKit:Acquire columns must be an integer from 1 to 16` | `columns` outside `maxColumns` |
| `TooltipKit:Acquire justify 2 must be "LEFT", "CENTER", "RIGHT" or nil` | a justification |
| `TooltipKit:Acquire MyAddon is acquired with 2 columns, not 3` | another column count for an acquired key |
| `TooltipKit:Acquire holds at most 16 tooltips at once; release one, or raise maxTooltips` | `maxTooltips` reached |
| `TooltipKit:Acquire needs the client's CreateFrame and UIParent, which this host does not have` | no client frames |
| `TooltipKit:Acquire could not get a tooltip frame: exhausted` | the tooltip pool made its 64 frames, all acquired |
| `TooltipKit:Release tooltip must be an acquired TooltipKit tooltip` | `Release` of anything else, a released tooltip included |
| `<method> got 3 values for 2 columns` | `AddLine`, `AddHeader` |
| `<method> value 2 must be a string, a number or nil`, `... must not be a secret value; pass { allowSecret = true } to SetCell to draw one` | a cell value (`text` for `SetCell`) |
| `<method> holds at most 256 lines; raise maxLines with TooltipKit:SetLimits` | `maxLines` reached |
| `<method> could not get a line frame: exhausted` | the line pool reached its creation cap |
| `<method> line must be the index of a line of this tooltip (1 to 3)`, `... line must not be a secret value` | a line index |
| `<method> column must be an integer from 1 to 3`, `... column must not be a secret value` | a column |
| `<method> r must be a number from 0 to 1`, `... must not be a secret value` (also `g`, `b`, `a`) | a colour component |
| `TooltipKit.Tooltip:AddSeparator height must be a number above 0 and at most 100, or nil` | the separator height |
| `TooltipKit.Tooltip:SetCell options must be a table or nil`, `... options holds an unknown field; it accepts span, justify, font and allowSecret` | the options table |
| `TooltipKit.Tooltip:SetCell options.span must be an integer from 1 to 2` | a span past the last column |
| `TooltipKit.Tooltip:SetCell options.justify must be "LEFT", "CENTER" or "RIGHT"`, `... options.font must be a font object or its name`, `... options.allowSecret must be a boolean` | the other options |
| `TooltipKit.Tooltip:SetLineScript script must be "OnMouseUp", "OnEnter" or "OnLeave"`, `... handler must be a function or nil` | `SetLineScript` |
| `TooltipKit.Tooltip:SetMaxHeight pixels must be a number of at least 20, or nil` | the height limit |
| `TooltipKit.Tooltip:SmartAnchorTo frame must be a frame` | a value without `GetCenter` |
| `TooltipKit.Tooltip:SetAutoHideDelay seconds must be a number of 0 or more, or nil`, `... alternateFrame must be a frame or nil` | `SetAutoHideDelay` |
| `TooltipKit:SetLimits limits must be a table`, `... limits holds an unknown field; it accepts maxTooltips, maxLines and maxColumns`, `... limits.maxLines must be an integer from 1 to 1024`, `... limits.maxLines must not be a secret value` | `SetLimits` |

Loading raises `MoltenCodes TooltipKit requires Registry API 2 to be loaded first`, `... requires a valid Registry API 2 facade`, `... requires PoolKit API 1 to be loaded first`, or `MoltenCodes TooltipKit package state is corrupted or incomplete`. What the client calls (line handlers, the wheel, auto-hide) never raises; a handler's failure is reported through `geterrorhandler`.

## Performance

| Path | Cost |
|---|---|
| A hidden or idle tooltip | Nothing runs. |
| A change while shown | One layout pass over the lines (two for `AddSeparator`). Adding many lines to a shown tooltip lays it out once per line; fill it hidden, then `Show`. |
| An auto-hiding tooltip while shown | Up to three `IsMouseOver` calls per frame. |
| `Acquire`, `Release` | One pool operation each, plus one per line on release. |

## Embedded copies and upgrades

Several addons may embed TooltipKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the acquired tooltips, the pools and the limits. The pools' factories and resets, and the scripts every tooltip and line frame holds, call through a dispatch table in the shared state that every loading revision rewrites, so frames an older copy made run the newest copy's code.
