# TimerKit API

TimerKit API generation **1** provides cancelable one-shot/repeating timers and explicit ownership scopes over World of Warcraft's native timer facilities.

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `New(options)` | Create an idle timer in TimerKit's internal manual scope. |
| `After(delay, callback)` | Create and immediately start a one-shot timer. |
| `Every(interval, callback)` | Create and immediately start a repeating timer. |
| `CreateScope()` | Create a manually owned timer scope. |
| `ForAddon(addonName)` | Return the shared LifecycleKit-owned scope for an addon. |

Timer handles:

| Method | Purpose |
|---|---|
| `GetState()` | Return `idle`, `running`, `completed`, or `cancelled`. |
| `GetDelay()` | Return the configured delay/interval in seconds. |
| `GetScope()` | Return the owning TimerKit scope. |
| `IsRepeating()` | Return whether the timer is repeating. |
| `IsPending()` | Return whether the logical timer is running. |
| `IsCancelled()` | Return whether it was logically cancelled. |
| `Start()` | Start an idle/completed/cancelled timer; return `false` if already running. |
| `Cancel()` | Cancel a running timer; return `false` if it is not running. |
| `Restart()` | Cancel if necessary and start a fresh generation. |

Scopes:

| Method | Purpose |
|---|---|
| `New(options)` | Create an idle timer owned by this scope. |
| `After(delay, callback)` | Start a one-shot timer in this scope. |
| `Every(interval, callback)` | Start a repeating timer in this scope. |
| `CancelAll()` | Cancel every active timer and keep the scope reusable. |
| `Close()` | Terminally close the scope after best-effort cancellation. |
| `IsClosed()` | Return whether the scope is terminally closed. |
| `GetAddonName()` | Return the owning addon name, or `nil` for manual scopes. |
| `GetActiveCount()` | Return the number of logically running timers. |

## Basic timers

```lua
local timer = TimerKit:New({
    delay = 1.5,
    callback = function(self)
        print(self:GetState()) -- completed for a one-shot callback
    end,
})

timer:Start()
timer:Cancel()
timer:Restart()
```

`New` does not auto-start. `After` and `Every` are convenience constructors that start immediately.

`New(options)` accepts exactly these fields:

- `delay` — required finite number;
- `callback` — required Lua function;
- `repeating` — optional boolean, default `false`.

Unknown option fields are rejected so misspellings cannot silently change timer behavior.

Timer callbacks receive the **logical TimerKit timer handle**, not the native `C_Timer` FunctionContainer.

## Timing validation

One-shot timers accept finite delays greater than or equal to zero. A zero-delay one-shot preserves WoW's next-frame scheduling behavior.

Repeating timers require a finite interval strictly greater than zero. TimerKit deliberately rejects a zero-interval repeating ticker to avoid pathological per-frame repetition through an API whose semantic purpose is interval timing.

Negative, NaN, and infinite values are rejected.

## State model

One-shot lifecycle:

```text
idle ──Start──> running ──fire──> completed
  ↑                 │                 │
  └──── Restart ────┴──── Restart ────┘
                    │
                  Cancel
                    ↓
                cancelled
```

Repeating timers remain `running` after each callback until cancelled or restarted.

`Cancel()` and `Start()` are idempotent with respect to an already-satisfied state: cancelling a non-running timer and starting an already-running timer return `false` rather than creating duplicate native work.

## Stale callback protection

Every start/restart receives a monotonically increasing logical generation. Cancellation invalidates that generation **before** TimerKit asks the native handle to cancel.

This means an already-queued or otherwise stale native callback cannot execute user code after a logical cancel/restart, even if native cancellation fails.

For one-shot timers, TimerKit marks the logical timer `completed` and removes it from its active scope before invoking user code. A callback can therefore safely call `Restart()` on itself.

## Repeating callback errors

TimerKit does not swallow callback errors. They propagate through the host callback boundary.

The logical repeating timer remains `running` after a callback error, matching WoW's native repeating-ticker behavior: a callback error does not automatically cancel the ticker. Consumers that want failure to stop repetition should explicitly cancel before raising or handle their own errors.

## Manual scopes

```lua
local scope = TimerKit:CreateScope()
local first = scope:After(1, callback)
local second = scope:Every(5, callback)

scope:CancelAll() -- scope remains reusable
scope:Close()     -- terminal; future timer creation/restart is rejected
```

Scopes track only **active** timers. Idle and completed timers do not contribute to `GetActiveCount()`.

Bulk cleanup runs in deterministic timer-creation order. If native cancellation raises, TimerKit continues attempting the remaining timers, preserves logical cancellation for every attempted timer, then re-raises the first native error object.

## Addon-owned scopes

```lua
local timers = TimerKit:ForAddon("MyAddon")
```

`ForAddon` is idempotent for an addon name. Its scope is tied to `LifecycleKit:ForAddon(addonName)` and closes when the addon lifecycle reaches shutdown.

After shutdown the same closed scope remains the canonical addon scope; callers cannot accidentally create timers that outlive a terminal lifecycle.

Manual scopes and TimerKit's package-level convenience scope are not closed by addon lifecycle events.

## Package-level convenience timers

```lua
TimerKit:After(1, callback)
TimerKit:Every(5, callback)
```

These methods use an internal manual scope. They are intentionally **not addon-owned**, because TimerKit cannot infer ownership from arbitrary callers. Framework and addon code that requires deterministic shutdown cleanup should prefer `ForAddon` or an explicitly managed scope.

If the internal convenience scope is explicitly reached through `timer:GetScope()` and closed, the next package-level timer operation creates a fresh internal scope rather than permanently disabling the facade.

## Native boundary

TimerKit relies only on:

```text
C_Timer.NewTimer
C_Timer.NewTicker
nativeHandle:Cancel()
```

It does not inspect native timer userdata or depend on undocumented implementation fields. This is important because modern WoW timer handles are native FunctionContainer userdata.

The native boundary is intentionally narrow so TimerKit behavior can be tested with a deterministic adapter outside the game client.

## Embedded copies

TimerKit is registered as `timerKit`, API generation `1`, through Registry API 2. The package facade, Timer prototype, Scope prototype, and metatables are shared-state compatible so future compatible revisions can preserve existing logical object identity.

Native callbacks route through a shared runtime dispatch table instead of permanently closing over one implementation revision. This provides the foundation for compatible live revision upgrades without replacing running logical timer objects.
