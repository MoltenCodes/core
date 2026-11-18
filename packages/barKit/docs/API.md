# BarKit API

BarKit API generation **1** provides pooled status and timer bars on the client's `StatusBar`: labels, icons, colours, secret values passed through, and pausable countdowns with a callback.

Implementation revision: **2**.

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
| `FontString:ClearText` | `Release`, and a plain text after a secret one | `SetText(nil)` instead; every promised client has it (Blizzard's `SimpleFontStringAPIDocumentation.lua` on `live`, `classic` and `classic_era`, read 2026-11-15). |
| `issecretvalue` | every check; read once at load, and again on each check only when it was absent at load | Nothing is treated as secret. |
| `geterrorhandler` | an `onFinished` that raises | The failure is printed. A handler that itself raises is not propagated either: the failure is printed instead. |

## Public surface

| Member | Purpose |
|---|---|
| `Acquire(options?)` | Borrow a bar, shown, empty, at the default colours. |
| `Release(bar)` | Give the bar back to the pool, cleared. |
| `SetLimits(limits)` / `GetLimits()` | Change or read `maxBars`; `GetLimits` returns a fresh table. |
| `MAX_BARS`, `BARS_CEILING` | `64`, `512`. |
| `API`, `REVISION` | `1`, `2`. |

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

The time left is always measured against `GetTime`, never summed from frame updates. While running, the bar's `OnUpdate` sets the fill every frame and writes the time left when the text changes: `1:02:05` from an hour, `1:23` from a minute, whole seconds from 10 seconds, tenths below (`9.4`). At zero the fill is empty (or full with `fill`), the text reads `0.0`, `OnUpdate` stops and `onFinished` runs. A new `Start` replaces a running timer without its callback; `SetValue` and `SetMinMax` stop it the same way. After `Stop`, `SetValue` or `SetMinMax`, the bar keeps the range `0 .. duration` and the fill and text where they were until you set them.

**Hidden bars.** The client runs `OnUpdate` only while the frame and every parent are shown ("Blocked by hiding a frame or its parent", warcraft.wiki.gg, the page of the `OnUpdate` script handler, read 2026-11-15). A timer on a hidden bar (its parent hidden, or `bar:GetFrame():Hide()`) keeps its end time but draws nothing and does not finish; `onFinished` and `releaseOnFinish` run at the first frame after it is shown again, at once when the time has run out by then. `GetRemaining` is right throughout. Keep a bar whose callback must run on time shown.

**From inside `onFinished`.** When `onFinished` runs, the timer has already ended (`IsRunning()` is `false`) and the bar is still acquired. It may start the bar again: the new timer runs, and `releaseOnFinish` of the finished one is dropped (before revision 2 the restarted bar was released at once). It may release the bar, and acquire others: `releaseOnFinish` then releases nothing more.

## Secret values

`SetValue` and `SetMinMax` pass a secret to the client's status bar untouched; anything else that is not a number is refused. Two secret bounds, or one, are not compared, so `minimum > maximum` is checked only for plain numbers. A secret label or value text is refused unless `allowSecret` is set (`BarKit.Bar:SetLabel text must not be a secret value; pass { allowSecret = true } to draw one`); every other argument, option field and option key is checked with `issecretvalue` first and refused at the caller.

**What the client keeps (secret aspects).** Blizzard's API documentation (`SimpleStatusBarAPIDocumentation.lua` and `SimpleFontStringAPIDocumentation.lua`, `live`, read 2026-11-15) marks `StatusBar:SetValue`, `StatusBar:SetMinMaxValues` and `FontString:SetText` as adding a secret aspect (`BarValue`, `Text`) to the object given a secret. A font string keeps its `Text` aspect through a later plain `SetText` (measured on Retail 12.1.0 b69933, recorded in widgetKit's `docs/API.md`). So BarKit empties a font string that showed a secret with `ClearText`, which removes the aspect, before it draws a plain text there (a plain label, a plain value text, the timer's time text) and on every release: a plain text on a bar always reads back plainly, in the same use and after the bar was pooled. A font string's measurements may stay secret after `ClearText` (same measurement); BarKit never measures its texts. The status bar's `BarValue` aspect has no addon-callable remedy (`SetToDefaults` is protected), so a pooled frame that once showed a secret value may answer `GetFrame():GetValue()` with a secret in a later use; the client suite logs whether it does. BarKit itself never reads the value back.

## Limits

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxBars`, bars acquired at once | `64` | `BarKit:SetLimits({ maxBars = n })` | no | `512`: each bar is a frame the session keeps |

Lowering `maxBars` keeps every bar and refuses the next `Acquire`. The limit is shared by every addon in the session.

## Error behaviour

A failure of a timer's `onFinished` goes to the host error handler (`geterrorhandler()`), called under `pcall`. When the client has no handler, or the handler itself raises (an error-display addon with a bug), the failure is printed instead, so reporting it never raises into the client's script call (revision 3; earlier revisions let a raising handler's error through).

Argument errors raise at the caller's line, before anything changes. The messages:

| Call | Message |
|---|---|
| a facade method without the facade (`BarKit.Acquire(nil)`) | `BarKit:Acquire must be called on the BarKit facade; use BarKit:Acquire(...)` |
| a bar method on anything but an acquired bar, a released handle included | `BarKit.Bar:Start must be called on an acquired BarKit bar; use bar:Start(...)` |
| `Release` of anything but an acquired bar | `BarKit:Release bar must be an acquired BarKit bar` |
| an options argument that is not a table | `BarKit:Acquire options must be a table or nil` (likewise `Start`, `SetLabel`, `SetValueText`) |
| an unknown option field | `BarKit:Acquire options holds an unknown field; it accepts width, height, texture and parent` |
| `width`, `height`, `duration` | `BarKit:Acquire options.width must be a number above 0`, `BarKit.Bar:Start duration must be a number above 0` |
| `texture`, `SetIcon` | `BarKit.Bar:SetIcon texture must be a texture path, a FileDataID or nil` |
| `parent` | `BarKit:Acquire options.parent must be a frame or nil` |
| the limit | `BarKit:Acquire holds at most 64 bars at once; release one, or raise maxBars` |
| a host without frames | `BarKit:Acquire needs the client's CreateFrame and UIParent, which this host does not have` |
| the pool refusing (it holds at most 512 frames, the ceiling) | `BarKit:Acquire could not get a bar frame: <PoolKit's reason>` |
| colours | `BarKit.Bar:SetColor g must be a number from 0 to 1` |
| status values | `BarKit.Bar:SetValue value must be a number`, `BarKit.Bar:SetMinMax minimum must not be greater than maximum` |
| texts | `BarKit.Bar:SetLabel text must be a string, a number or nil`, `BarKit.Bar:SetLabel options.allowSecret must be a boolean` |
| `Start` options | `BarKit.Bar:Start options.onFinished must be a function or nil`, `BarKit.Bar:Start options.fill must be a boolean`, `BarKit.Bar:Start options.releaseOnFinish must be a boolean` |
| limits | `BarKit:SetLimits limits must be a table`, `BarKit:SetLimits limits holds an unknown field; it accepts maxBars`, `BarKit:SetLimits limits.maxBars must not be a secret value`, `BarKit:SetLimits limits.maxBars must be an integer from 1 to 512` |
| any secret argument checked as such | `<method> <argument> must not be a secret value` |

`options.parent` is checked to be a table, not to be a frame: a table that is not one makes the client's `SetParent` raise inside `Acquire`.

## Performance

| Path | Cost |
|---|---|
| A status bar | Nothing per frame; each setter is one or two frame calls. |
| A running timer | One `SetValue` per frame while shown; a text only when it changes. |
| A paused or stopped timer | Nothing. |
| `Acquire`, `Release` | One pool operation and a handful of frame calls. |

## Embedded copies and upgrades

Several addons may embed BarKit; Registry selects the newest compatible revision and every copy shares one facade and one state: the bars, the pool and the limit. The pool's factory and reset and every bar's `OnUpdate` call through a dispatch table in the shared state that every loading revision rewrites, so bars an older copy made, running timers included, run the newest copy's code.
