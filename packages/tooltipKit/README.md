# TooltipKit

TooltipKit draws tooltips laid out in columns: what LibQTip-1.0 gives addons that show a table on hover, such as a guild list on a broker display or a currency summary. A tooltip has a fixed number of columns, each justified its own way; lines are rows of cells, with headers, separators, cells spanning several columns, colours and a click or hover handler per line. Past a height limit it scrolls with the mouse wheel; it anchors itself to the frame that opened it on the side with room, and can release itself once the cursor has left both.

```lua
local TooltipKit = MoltenCodes.Registries[2]:Get("tooltipKit", 1)

local function showGuild(owner)
  local tooltip = TooltipKit:Acquire("MyAddonGuild", 3, "LEFT", "CENTER", "RIGHT")
  tooltip:Clear()
  tooltip:AddHeader("Name", "Level", "Zone")
  tooltip:AddSeparator()
  for _, member in ipairs(MyAddon:GuildMembers()) do
    local line = tooltip:AddLine(member.name, member.level, member.zone)
    tooltip:SetCellTextColor(line, 1, member.r, member.g, member.b)
    tooltip:SetLineScript(line, "OnMouseUp", MyAddon.Whisper, member.name)
  end
  tooltip:SetMaxHeight(400)
  tooltip:SmartAnchorTo(owner)
  tooltip:SetAutoHideDelay(0.25, owner)
  tooltip:Show()
end
```

What each piece promises:

- **Keyed.** `Acquire` with a key that is already acquired returns that tooltip, so an `OnEnter` that runs twice never stacks two.
- **Pooled and clean.** Tooltips and lines are frames the client never frees, so they come from PoolKit pools that keep every one for reuse. `TooltipKit:Release` (or the auto-hide) gives the tooltip and its lines back cleared: no text, colour, handler or anchor survives into the next use.
- **Laid out on change, not per frame.** A shown tooltip lays out again when a line or cell changes; a hidden one lays out at `Show`. Only an auto-hiding tooltip runs code per frame, and only while shown.
- **Handlers cannot break it.** A line's `OnMouseUp`, `OnEnter` or `OnLeave` handler runs protected; one that raises is reported through the error handler.
- **Secrets are your decision.** A secret text is refused unless that cell is set with `{ allowSecret = true }`; a size the client measures as secret counts as 0.
- **Bounded.** 16 tooltips acquired at once, 256 lines each, 16 columns; `TooltipKit:SetLimits` raises them up to 64, 1024 and 32. There is no unbounded setting, because every line and cell is a frame or font string the session keeps.

Non-goals: changing `GameTooltip` (keep using it for one column of text), icons or widgets inside cells, sorting or filtering the rows.

### Moving from LibQTip-1.0

| LibQTip-1.0 | TooltipKit |
|---|---|
| `QTip:Acquire(key, numColumns, ...)` | `TooltipKit:Acquire(key, columns, ...)` |
| `QTip:Release(tooltip)` | `TooltipKit:Release(tooltip)` |
| `QTip:IsAcquired(key)` | `TooltipKit:IsAcquired(key)` |
| `tooltip:AddHeader(...)`, `AddLine(...)` | the same; `nil` leaves a cell empty |
| `tooltip:AddSeparator(height, r, g, b, a)` | the same |
| `tooltip:SetCell(line, column, value, font, justification, colSpan)` | `tooltip:SetCell(line, column, value, { font = ..., justify = ..., span = ... })` |
| `tooltip:SetLineColor(line, r, g, b, a)` | the same (the line's background) |
| `tooltip:SetCellTextColor(line, column, r, g, b, a)` | the same |
| `tooltip:SetLineScript(line, script, func, arg)` | the same, for `OnMouseUp`, `OnEnter` and `OnLeave` |
| `tooltip:UpdateScrolling(maxHeight)` | `tooltip:SetMaxHeight(maxHeight)` |
| `tooltip:SmartAnchorTo(frame)` | the same |
| `tooltip:SetAutoHideDelay(delay, alternateFrame)` | the same |
| cell providers, `SetCellScript`, `SetColumnLayout` after acquiring | none; a tooltip's columns are fixed by `Acquire` |

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\tooltipKit\TooltipKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`, `tooltipKit/TooltipKit.lua`.

Direct runtime dependencies: Registry API 2, PoolKit API 1.
Every file above is required; omitting one makes this package raise at
load.

TooltipKit reads `CreateFrame` and `UIParent` when a tooltip is acquired,
never at load.
