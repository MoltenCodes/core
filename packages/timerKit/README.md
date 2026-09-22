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

-- Addon-owned scopes close automatically on LifecycleKit shutdown.
```

TimerKit adds a logical timer state machine, restart/cancel generation guards, deterministic scope cleanup, and addon lifecycle ownership without exposing native FunctionContainer details to consumers.

Use `TimerKit:CreateScope()` for manually owned groups and `TimerKit:ForAddon(addonName)` when timers must be cancelled automatically during addon shutdown. Package-level `TimerKit:After` / `Every` are convenience methods backed by an internal manual scope and are therefore not tied to an addon lifecycle.

A caller that needs to carry its own bookkeeping on a timer attaches it through `timer:SetUserData(value)` and reads it back with `timer:GetUserData()`. One opaque value per timer, stored by reference, never read or cleared by TimerKit. This is the supported alternative to writing private fields onto a timer handle.

Two timers that expire at the same instant fire in whatever order the client dispatches them; TimerKit imposes no ordering of its own. See [`docs/API.md`](docs/API.md).

See [`docs/API.md`](docs/API.md) for the full state model, scope semantics, error behavior, and native API boundary.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
```

Direct runtime dependencies: LifecycleKit API 1, Registry API 2.
Every file above is required; omitting one makes this package raise at
load.
