# TimerKit

TimerKit provides cancelable, deterministic, scope-aware timers on top of World of Warcraft's native `C_Timer.NewTimer` and `C_Timer.NewTicker` APIs.

```lua
local timers = TimerKit:ForAddon("MyAddon")

timers:After(0.5, function(timer)
    print("one shot")
end)

local ticker = timers:Every(5, function(timer)
    print("tick")
end)

-- The scope closes at logout whenever LifecycleKit or EventKit is loaded.
-- With neither: TimerKit:CloseAddonScopes("MyAddon") on PLAYER_LOGOUT.
```

`timer:GetRemaining()` and `timer:GetDeadline()` answer "how long until this fires?" for a running timer and return `nil` otherwise. They read `GetTimePreciseSec`, which is optional: on a host without it TimerKit still loads, and both methods return `nil`.

TimerKit adds a logical timer state machine, restart/cancel generation guards, deterministic scope cleanup, and per-addon ownership without exposing native FunctionContainer details to consumers.

Use `TimerKit:CreateScope()` for manually owned groups and `TimerKit:ForAddon(addonName)` for the addon's canonical scope. `TimerKit:CloseAddonScopes(addonName)` closes the addon scope and cancels every timer in it. An addon scope closes at logout whenever LifecycleKit or EventKit is loaded, and otherwise by your own call: TimerKit finds either through `Registry:Find` without depending on it (see "At logout" in [`docs/API.md`](docs/API.md)). Package-level `TimerKit:New` / `After` / `Every` are convenience methods backed by an internal manual scope and are therefore not tied to an addon.

A caller that needs to carry its own bookkeeping on a timer attaches it through `timer:SetUserData(value)` and reads it back with `timer:GetUserData()`. One opaque value per timer, stored by reference, never read or cleared by TimerKit. This is the supported alternative to writing private fields onto a timer handle.

Two timers that expire at the same instant fire in whatever order the client dispatches them; TimerKit imposes no ordering of its own. See [`docs/API.md`](docs/API.md).

See [`docs/API.md`](docs/API.md) for the full state model, scope semantics, error behavior, and native API boundary.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
```

Minimum footprint: Embed 2 files: Registry, TimerKit.

Direct runtime dependencies: Registry API 2.
Both files are required; omitting Registry makes this package raise at
load. LifecycleKit and EventKit are optional, never dependencies: when an
addon also embeds LifecycleKit, it closes the addon's timer scope at logout
through `TimerKit:CloseAddonScopes`; with EventKit alone, TimerKit's own
`PLAYER_LOGOUT` connection does.
