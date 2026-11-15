# BarKit

BarKit gives addons status and timer bars: what LibCandyBar-3.0 gives boss-timer and cooldown addons, and what unit-frame addons build by hand. A bar has a label, an icon, a value text and a colour, and either shows a value between a minimum and a maximum or counts a duration down, drawing the time left as `1:23` or `9.4`.

```lua
local BarKit = MoltenCodes.Registries[2]:Get("barKit", 1)

-- A health bar. On Retail 12.x UnitHealth may answer a secret value: it goes
-- to the bar as it is, and the client draws it.
local health = BarKit:Acquire({ width = 180, height = 16 })
health:GetFrame():SetPoint("CENTER", UIParent, "CENTER", 0, -120)
health:SetColor(0.1, 0.8, 0.1)
health:SetMinMax(0, UnitHealthMax("target"))
health:SetValue(UnitHealth("target"))
health:SetLabel(UnitName("target"), { allowSecret = true })

-- A timer bar that releases itself when it runs out.
local pull = BarKit:Acquire()
pull:GetFrame():SetPoint("TOP", UIParent, "TOP", 0, -200)
pull:SetLabel("Pull")
pull:SetIcon(132337)
pull:Start(10, {
  releaseOnFinish = true,
  onFinished = function()
    PlaySound(8960)
  end,
})
```

What each piece promises:

- **The client's own status bar.** `SetValue` and `SetMinMax` pass a secret value to the `StatusBar` untouched, so a bar shows what an addon may not read. Any other value must be a number, checked at your line.
- **Timers that cost nothing when idle.** A running timer runs one `OnUpdate` that sets the fill and writes the time text only when it changes; `Pause` holds it where it is, `Resume` goes on from there, `Stop` ends it without its callback. A status bar runs nothing per frame. The client runs `OnUpdate` only for a shown frame, so a timer on a hidden bar keeps its end time but finishes, and calls `onFinished`, only once the bar is shown again.
- **Callbacks cannot break it.** `onFinished` runs protected; one that raises is reported through the error handler. It may start the bar again (a repeating timer), which keeps the bar even with `releaseOnFinish`, or release it.
- **Pooled and clean.** Bars are frames the client never frees, so they come from a PoolKit pool that keeps every one. `BarKit:Release` gives a bar back cleared of every text, icon, colour, value, timer and callback, its texts emptied with the client's `ClearText` so a secret shown in one use never makes a later plain text read back as a secret.
- **Bounded.** At most 64 bars acquired at once, up to 512 with `BarKit:SetLimits({ maxBars = n })`; there is no unbounded setting, as each bar is a frame the session keeps.

Non-goals: laying bars out in groups (anchor them yourself, or use WidgetKit's layouts), unit-frame logic, reading unit data.

### Moving from LibCandyBar-3.0

| LibCandyBar-3.0 | BarKit |
|---|---|
| `candy:New(texture, width, height)` | `BarKit:Acquire({ texture = texture, width = width, height = height })` |
| `bar:SetLabel(text)`, `bar:SetIcon(icon)`, `bar:SetColor(r, g, b, a)` | the same |
| `bar:SetDuration(seconds)`, `bar:Start()` | `bar:Start(seconds)` |
| `bar:SetFill(true)` | `bar:Start(seconds, { fill = true })` |
| `bar:Pause()`, `bar:Resume()`, `bar:Stop()` | the same; `Stop` ends the timer and keeps the bar, release it with `BarKit:Release(bar)` |
| the `LibCandyBar_Stop` callback | `onFinished` in `Start`'s options, called only when the time runs out |
| `bar:SetTimeVisibility(false)` | `bar:SetValueText(nil)` after each start, or style `bar:GetFrame().valueText` |

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\barKit\BarKit.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`, `barKit/BarKit.lua`.

Direct runtime dependencies: Registry API 2, PoolKit API 1.
Every file above is required; omitting one makes this package raise at
load.

BarKit reads `CreateFrame`, `UIParent` and `GetTime` when it is called, never
at load.
