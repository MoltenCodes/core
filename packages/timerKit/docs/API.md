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
| `ForAddon(addonName)` | Return the canonical scope for an addon, creating it on demand. |
| `CloseAddonScopes(addonName)` | Close that addon's scope; returns `false` when it has none or it was already closed. |

Timer handles:

| Method | Purpose |
|---|---|
| `GetState()` | Return `idle`, `running`, `completed`, or `cancelled`. |
| `GetDelay()` | Return the configured delay/interval in seconds. |
| `GetScope()` | Return the owning TimerKit scope. |
| `GetUserData()` | Return the opaque value attached by the owner, or `nil`. |
| `SetUserData(value)` | Attach one opaque owner-defined value; returns the timer. |
| `IsRepeating()` | Return whether the timer is repeating. |
| `IsPending()` | Return whether the logical timer is running. |
| `IsCancelled()` | Return whether it was logically cancelled. |
| `Start()` | Start an idle/completed/cancelled timer; return `false` if already running. |
| `Cancel()` | Cancel a running timer; return `false` if it is not running. |
| `Restart()` | Cancel if necessary and start a fresh generation. |
| `GetRemaining()` | Seconds until the next fire while running; `nil` otherwise. |
| `GetDeadline()` | Monotonic instant of the next fire while running; `nil` otherwise. |

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

Unknown option fields are rejected so misspellings cannot silently change timer behavior. When several unknown fields are present the message names the alphabetically first one.

Timer callbacks receive the **logical TimerKit timer handle**, not the native `C_Timer` FunctionContainer.

## Timing validation

One-shot timers accept finite delays greater than or equal to zero. A zero-delay one-shot preserves WoW's next-frame scheduling behavior.

Repeating timers require a finite interval strictly greater than zero. TimerKit deliberately rejects a zero-interval repeating ticker to avoid pathological per-frame repetition through an API whose semantic purpose is interval timing.

Negative, NaN, and infinite values are rejected.

## Timer user data

A consumer that has to associate its own bookkeeping with a timer attaches it
through the timer handle instead of writing private fields onto it:

```lua
local timer = scope:After(0.5, wakeCallback)
timer:SetUserData(myJobRecord)

-- inside wakeCallback
local record = timer:GetUserData()
```

The contract is deliberately small:

- exactly **one** value per timer; a second `SetUserData` replaces the first;
- the value is stored **by reference**. TimerKit never reads, copies, compares,
  or serializes it, and attaching a value allocates nothing;
- `SetUserData(nil)` detaches the value;
- user data survives `Cancel()`, `Start()`, and `Restart()`. TimerKit never
  clears it, so an owner that attaches a large object is responsible for
  detaching it when the timer is no longer interesting;
- `GetUserData()` returns `nil` for a timer that has never been given one,
  including timers created by an older embedded TimerKit revision.

This is the supported way for another package to carry state on a timer.
Writing private fields onto a TimerKit timer handle is not supported: it is
another package's internal state and may collide with a future revision.

## Remaining time

```lua
local timer = scope:After(30, expire)

timer:GetRemaining() -- 30, then counting down
timer:GetDeadline()  -- GetTimePreciseSec() at start + 30
```

- `GetRemaining()` returns the seconds until the timer fires next as a number
  while the timer is `running`, and `nil` in every other state — `idle`,
  `completed` and `cancelled`. It never returns `0` to mean "not running", so a
  caller can tell "about to fire" from "will not fire".
- `GetDeadline()` returns the instant of the next fire on the
  `GetTimePreciseSec()` clock while `running`, and `nil` otherwise.
- A repeating timer reports its **next** tick. The deadline moves forward by one
  interval each time a tick is delivered.
- `Start()` and `Restart()` compute a fresh deadline from the moment they run.
- A one-shot reports `nil` from inside its own callback: it is already
  `completed` by then.

### Precision

TimerKit does not fire timers; `C_Timer` does, on the first frame at or after
the requested moment. The deadline is TimerKit's own record of when it asked
the host to fire, read from `GetTimePreciseSec()` — the monotonic wall clock,
because `C_Timer` runs on wall time and `GetTime()` only advances once per
frame. The remaining time is therefore an **estimate**: the real callback can
arrive up to one frame later than the deadline says. While the host is late,
`GetRemaining()` reports `0` and the timer is still `running`; it never returns
a negative number.

Nothing is computed on the dispatch path beyond one clock read per repeating
tick, and TimerKit never schedules from these values.

### Timers started by an older revision

Revisions before 4 kept no deadline. A timer such a revision started keeps
running after an in-place upgrade, but TimerKit cannot know when it will fire,
so `GetRemaining()` and `GetDeadline()` return `nil` for it until its next
`Start()`/`Restart()` or, for a repeating timer, its next tick.

### Without `GetTimePreciseSec`

The clock is optional. On a host that does not publish `GetTimePreciseSec`,
TimerKit loads and every timer works exactly as before, but no deadline is
recorded: `GetRemaining()` and `GetDeadline()` return `nil` even for a running
timer. Requiring the clock would have added a host facility inside API
generation 1, which the compatibility rules reserve for a new generation.
Every supported client publishes it.

## Same-instant ordering

When two timers are scheduled to fire at the same instant, the order in which
their callbacks run is **host-defined**. TimerKit adds no ordering of its own:
it hands each timer to `C_Timer` independently, and the client decides how
same-frame expirations are dispatched. Creation order, delay value, and scope
membership must not be relied on to sequence two timers that expire together.

Work that genuinely depends on ordering should express it directly — by
starting the second timer from the first timer's callback, or by using
SchedulerKit, which owns deterministic ordering within a priority lane.

Bulk operations are the one place TimerKit does impose an order: `CancelAll()`
and `Close()` process the scope's active timers in creation order so cleanup is
reproducible.

## Argument errors point at the caller

Every argument-validation failure is raised so that its `file:line` prefix is
the line that called the public method:

```lua
scope:After(1, "nope")
-- MyAddon/Main.lua:42: TimerKit.Scope:After callback must be a function
```

This holds for every public entry point — package-level and scope-level
constructors, option-table fields, closed-scope rejections, and methods invoked
on something that is not a TimerKit timer or scope. Host failures reported
through TimerKit, such as an invalid native timer handle, use the same position.

Errors that are re-raised after best-effort cleanup — the first native
cancellation error from `CancelAll()` or `Close()` — deliberately keep the
original error object unchanged and therefore carry no added position.

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

`ForAddon` is idempotent for an addon name: every call with the same name returns the same scope.

### Addon scopes and shutdown: the two-step

TimerKit requires Registry and nothing else, so it does not observe addon shutdown. Closing an addon scope is a separate, public step taken by whoever does:

1. timers are created through `TimerKit:ForAddon("MyAddon")`;
2. when the addon shuts down, its observer calls `TimerKit:CloseAddonScopes("MyAddon")`.

**LifecycleKit calls `CloseAddonScopes` at shutdown; without LifecycleKit, call it yourself on `PLAYER_LOGOUT`.** LifecycleKit makes the call after the addon's shutdown callbacks have run, and before it closes the addon's SchedulerKit, EventKit, HookKit, CommandKit and CommKit scopes and its SignalKit bus, so no timer fires into a listener that is being torn down. An addon using LifecycleKit writes no teardown for its scoped timers. An addon without it closes the scope from its own logout handler, through EventKit when it embeds it or through a frame of its own:

```lua
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
    TimerKit:CloseAddonScopes("MyAddon")
end)
```

`CloseAddonScopes(addonName)`:

- must be called on the facade (`TimerKit:CloseAddonScopes(...)`); any other receiver raises;
- validates `addonName` as a non-empty string;
- returns `false` when the addon never asked for a scope, and records nothing, so the addon-scope map grows only with `ForAddon` calls;
- returns `false` when the scope is already closed;
- otherwise cancels every running timer of the scope in creation order, closes it and returns `true`. A native cancellation failure does not stop the sweep: every timer is cancelled logically and the first error is re-raised afterwards, as for `Scope:Close()`.

Closing is terminal: the closed scope stays the canonical addon scope, so a later `ForAddon(addonName)` returns it and refuses new timers. A timer callback may close its own addon scope; the firing timer is cancelled with the rest, so a ticker does not tick again.

Manual scopes and TimerKit's package-level convenience scope are never closed by `CloseAddonScopes`.

Revision 5 and older required LifecycleKit and subscribed each addon scope to its addon's shutdown themselves. An embedded copy of this revision that upgrades one of them in place disconnects those subscriptions; the carried scopes stay open and canonical until `CloseAddonScopes` is called. A pairing of this revision with a LifecycleKit older than 0.5.0 closes no timer scope at logout, since that LifecycleKit does not know the call.

## Package-level convenience timers

```lua
TimerKit:After(1, callback)
TimerKit:Every(5, callback)
```

These methods use an internal manual scope. They are intentionally **not addon-owned**, because TimerKit cannot infer ownership from arbitrary callers. Framework and addon code that requires deterministic shutdown cleanup should prefer `ForAddon` (closed through `CloseAddonScopes`) or an explicitly managed scope.

If the internal convenience scope is explicitly reached through `timer:GetScope()` and closed, the next package-level timer operation creates a fresh internal scope rather than permanently disabling the facade.

## Native boundary

TimerKit relies only on:

```text
C_Timer.NewTimer
C_Timer.NewTicker
nativeHandle:Cancel()
GetTimePreciseSec()   -- optional; deadlines only, never used to schedule
```

It does not inspect native timer userdata or depend on undocumented implementation fields. This is important because modern WoW timer handles are native FunctionContainer userdata.

The native boundary is intentionally narrow so TimerKit behavior can be tested with a deterministic adapter outside the game client.

## Embedded copies

TimerKit is registered as `timerKit`, API generation `1`, through Registry API 2. The package facade, Timer prototype, Scope prototype, and metatables are shared-state compatible so future compatible revisions can preserve existing logical object identity.

Native callbacks route through a shared runtime dispatch table instead of permanently closing over one implementation revision. This provides the foundation for compatible live revision upgrades without replacing running logical timer objects.
