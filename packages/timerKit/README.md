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

See [`docs/API.md`](docs/API.md) for the full state model, scope semantics, error behavior, and native API boundary.
