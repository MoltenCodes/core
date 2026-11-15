# BarKit API

BarKit API generation **1** provides pooled status and timer bars on the client's `StatusBar`: labels, icons, colours, secret values passed through, and pausable countdowns with a callback.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
PoolKit.lua
BarKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local BarKit = MoltenCodes.Registries[2]:Get("barKit", 1)
```

BarKit does not rely on `require()` at runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `CreateFrame`, `UIParent` | `Acquire` | `Acquire` raises at the caller: `BarKit:Acquire needs the client's CreateFrame and UIParent, which this host does not have`. |
| `GetTime` | timers | Time stands still at 0: a timer never runs out. |
| `issecretvalue` | every check | Nothing is treated as secret. |
| `geterrorhandler` | an `onFinished` that raises | The failure is printed. |

## Public surface

| Member | Purpose |
|---|---|
| `Acquire(options?)` | Borrow a bar, shown, empty, at the default colours. |
| `Release(bar)` | Give the bar back to the pool, cleared. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxBars`; `GetLimits` returns a fresh table. |
| `MAX_BARS`, `BARS_CEILING` | `64`, `512`. |
| `API`, `REVISION` | `1`, `1`. |

A bar:

| Method | Purpose |
|---|---|
| `SetLabel(text?, options?)` | The text on the bar's left. `options.allowSecret` draws a secret instead of refusing it. |
| `SetValueText(text?, options?)` | The text on the bar's right; a running timer writes its time there and replaces it at its next change. |
| `SetIcon(texture?)` | A square icon left of the bar, as tall as the bar; `nil` removes it. |
| `SetColor(r, g, b, a?)` | The fill's colour. |
| `SetBackgroundColor(r, g, b, a?)` | The colour behind the fill. |
| `SetMinMax(minimum, maximum)` | The range of a status value; a secret passes through. Stops a timer. |
| `SetValue(value)` | A status value; a secret passes through. Stops a timer. |
| `Start(duration, options?)` | Count `duration` seconds down (below). |
| `Pause()`, `Resume()`, `Stop()` | `true`, or `false` when there was nothing to pause, resume or stop. |
| `IsRunning()`, `IsPaused()` | Whether a timer is running or paused (a paused timer is running too). |
| `GetRemaining()` | The seconds left of a running or paused timer, else `nil`. |
| `GetFrame()` | The `StatusBar`; its parts are `frame.icon`, `frame.label`, `frame.valueText` and `frame.background`. |

## `BarKit:Acquire(options?)`

| Option | Meaning |
|---|---|
| `width`, `height` | A number above 0; default `200` by `18`. |
| `texture` | The fill texture, a path or a FileDataID; default `Interface\TargetingFrame\UI-StatusBar`. |
| `parent` | The frame the bar is a child of; default `UIParent`. |

The bar is shown, unanchored (anchor it with `bar:GetFrame():SetPoint(...)`), with a blue fill and a half-transparent black background. Texts use `GameFontHighlightSmall`. At most `maxBars` bars are acquired at once: `BarKit:Acquire holds at most 64 bars at once; release one, or raise maxBars`.

## Timers

`bar:Start(duration, options)` sets the range to `0 .. duration` and counts down from now (`GetTime`). Options:

| Option | Meaning |
|---|---|
| `onFinished` | `onFinished(bar)`, called once when the time runs out, protected. |
| `fill` | `true`: fill from empty instead of draining from full. |
| `releaseOnFinish` | `true`: release the bar when the time runs out, after `onFinished`. |

While running, the bar's `OnUpdate` sets the fill every frame and writes the time left when the text changes: `1:02:05` from an hour, `1:23` from a minute, whole seconds from 10 seconds, tenths below (`9.4`). At zero the fill is empty (or full with `fill`), the text reads `0.0`, `OnUpdate` stops and `onFinished` runs. A new `Start` replaces a running timer without its callback; `SetValue` and `SetMinMax` stop it the same way.

## Secret values

`SetValue` and `SetMinMax` pass a secret to the client's status bar untouched; anything else that is not a number is refused. A secret label or value text is refused unless `allowSecret` is set; every other argument is checked with `issecretvalue` first and refused at the caller.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxBars`, bars acquired at once | `64` | `BarKit:SetLimits({ maxBars = n })` | no | `512`: each bar is a frame the session keeps |

Lowering `maxBars` keeps every bar and refuses the next `Acquire`. The limit is shared by every addon in the session.

## Error behaviour

Argument errors raise at the caller's line: `BarKit.Bar:SetColor g must be a number from 0 to 1`; methods called on anything but an acquired bar raise `BarKit.Bar:Start must be called on an acquired BarKit bar; use bar:Start(...)`. A released bar's handle is refused by every method.

## Performance

| Path | Cost |
|---|---|
| A status bar | Nothing per frame; each setter is one or two frame calls. |
| A running timer | One `SetValue` per frame; a text only when it changes. |
| A paused or stopped timer | Nothing. |
| `Acquire`, `Release` | One pool operation and a handful of frame calls. |

## Embedded copies and upgrades

Several addons may embed BarKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the bars, the pool and the limit. The pool's factory and reset and every bar's `OnUpdate` call through a dispatch table in the shared state that every loading revision rewrites, so bars an older copy made, running timers included, run the newest copy's code.
