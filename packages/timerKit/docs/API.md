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

TimerKit requires Registry and nothing else, so it does not depend on anything that observes addon shutdown. Closing an addon scope is a separate, public step:

1. timers are created through `TimerKit:ForAddon("MyAddon")`;
2. at logout, `TimerKit:CloseAddonScopes("MyAddon")` closes the scope.

Who takes the second step is arranged by TimerKit itself whenever the framework can observe logout; see [At logout](#at-logout).

### At logout

**An addon scope closes at logout whenever LifecycleKit or EventKit is loaded, and otherwise by your own call**, whatever revisions of them are paired with this one. The first `ForAddon(addonName)` for an addon looks for the optional Kits through `Registry:Find` and takes the first case that applies:

1. **LifecycleKit lists `"timerKit"` in `LifecycleKit.CLOSES_ADDON_SCOPES`** (LifecycleKit 0.6.0 and later). TimerKit subscribes nothing and makes sure the addon is known to LifecycleKit (it calls `LifecycleKit:ForAddon(addonName)` once): LifecycleKit calls `CloseAddonScopes` when the addon reaches `shutdown`, after its shutdown callbacks have run and before it closes the addon's SchedulerKit, EventKit, HookKit, CommandKit and CommKit scopes and its SignalKit bus, so no timer fires into a listener that is being torn down. This is the case with ordering guarantees, and it covers an addon that never used LifecycleKit itself.
2. **An older LifecycleKit, without that field.** TimerKit asks it for `LifecycleKit:ForAddon(addonName):OnShutdown(...)`, once per addon, and closes the scope from that callback, among the addon's shutdown callbacks, as TimerKit 0.4.x did. This is compatibility only: LifecycleKit is found through `Registry:Find` and never becomes a dependency. The subscription is kept on the scope; closing the scope (`CloseAddonScopes` or `Scope:Close()`) disconnects it. If a LifecycleKit that lists TimerKit replaces the older one before logout, the callback leaves the call to it.
3. **No LifecycleKit, but EventKit.** TimerKit keeps one package-level `PLAYER_LOGOUT` one-shot, in an EventKit scope of its own, created by the first `ForAddon` that needs it. At logout it closes every addon scope that neither case above covers, in addon-name order; a failure does not stop the others and reaches the host error handler through EventKit. EventKit runs `PLAYER_LOGOUT` listeners in connection order, so the scope closes when this listener runs: after any listener connected before the addon's first `ForAddon`, before any connected after it. Use LifecycleKit when the addon's own logout code must run while its timers are live.
4. **Neither.** Nothing is subscribed and `ForAddon` works as always. Call `CloseAddonScopes` yourself on `PLAYER_LOGOUT`, for example from a frame of your own:

```lua
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
    TimerKit:CloseAddonScopes("MyAddon")
end)
```

The decision is made once per addon, except for case 4, which the next `ForAddon` for that addon examines again, because a Kit loaded after the first call (an addon later in the load order embedding EventKit, say) can make logout observable. A LifecycleKit 0.5.0 or later that loads after case 4 was chosen closes the scope anyway once the addon asks it for an instance, because it calls `CloseAddonScopes` for every addon it knows. Closing the scope twice is harmless: the second call answers `false`.

The routing costs one field read per `ForAddon` once decided. TimerKit allocates one closure and one LifecycleKit subscription per addon in case 2, and one EventKit scope and connection for the whole package in case 3.

`CloseAddonScopes(addonName)`:

- must be called on the facade (`TimerKit:CloseAddonScopes(...)`); any other receiver raises;
- validates `addonName` as a non-empty string;
- returns `false` when the addon never asked for a scope, and records nothing, so the addon-scope map grows only with `ForAddon` calls;
- returns `false` when the scope is already closed;
- otherwise cancels every running timer of the scope in creation order, closes it and returns `true`. A native cancellation failure does not stop the sweep: every timer is cancelled logically and the first error is re-raised afterwards, as for `Scope:Close()`.

Closing is terminal: the closed scope stays the canonical addon scope, so a later `ForAddon(addonName)` returns it and refuses new timers. A timer callback may close its own addon scope; the firing timer is cancelled with the rest, so a ticker does not tick again.

Manual scopes and TimerKit's package-level convenience scope are never closed by `CloseAddonScopes`.

Revision 5 and older required LifecycleKit and subscribed each addon scope to its addon's shutdown themselves. An embedded copy of this revision that upgrades one of them in place disconnects those subscriptions and then routes the carried scopes as described under [At logout](#at-logout); they stay open and canonical until they are closed. Revision 6 decided no route: its scopes are routed the same way when revision 7 upgrades it. A scope a revision 7 or later copy already routed keeps its route, its `OnShutdown` subscription and the package's `PLAYER_LOGOUT` connection, whose callbacks resolve the running revision's code when they fire. With a LifecycleKit older than 0.5.0 (which does not know `CloseAddonScopes`), case 2 closes the scope.

## Package-level convenience timers

```lua
TimerKit:New({ delay = 1, callback = callback })
TimerKit:After(1, callback)
TimerKit:Every(5, callback)
```

These methods use an internal manual scope. They are intentionally **not addon-owned**, because TimerKit cannot infer ownership from arbitrary callers. Framework and addon code that requires deterministic shutdown cleanup should prefer `ForAddon` (closed through `CloseAddonScopes`) or an explicitly managed scope.

If the internal convenience scope is explicitly reached through `timer:GetScope()` and closed, the next package-level timer operation creates a fresh internal scope rather than permanently disabling the facade.

## Errors

`<method>` below is the public name of the method called, such as
`TimerKit:After`, `TimerKit.Scope:New` or `TimerKit.Timer:Restart`. Every
message in the first table is raised at the caller's line (see
[Argument errors point at the caller](#argument-errors-point-at-the-caller)).

| Message | Raised by |
|---|---|
| `<method> must be called on a TimerKit timer` | a timer method called on anything but a TimerKit timer |
| `<method> must be called on a TimerKit scope` | a scope method called on anything but a TimerKit scope |
| `<method> callback must be a function` | `After`, `Every`, and `New` without a function `callback` |
| `<method> delay must be a finite number` | a delay or interval that is not a number, or is NaN or infinite |
| `<method> delay must be zero or greater` | a negative one-shot delay |
| `<method> delay must be greater than zero for repeating timers` | a repeating interval of zero or less |
| `<method> options must be a table` | `New` without an option table |
| `<method> options contains unknown field "<name>"` | `New` with a field other than `delay`, `callback` and `repeating`; the alphabetically first one is named |
| `<method> repeating must be a boolean` | `New` with a non-boolean `repeating` |
| `<method> cannot create a timer in a closed scope` | `New`, `After` and `Every` on a closed scope |
| `<method> cannot start a timer in a closed scope` | `Timer:Start()` when the timer's scope is closed |
| `<method> cannot restart a timer in a closed scope` | `Timer:Restart()` when the timer's scope is closed |
| `TimerKit:ForAddon addonName must be a non-empty string` | `ForAddon` |
| `TimerKit:CloseAddonScopes addonName must be a non-empty string` | `CloseAddonScopes` |
| `TimerKit:CloseAddonScopes must be called on the TimerKit facade; use TimerKit:CloseAddonScopes(addonName)` | `CloseAddonScopes` with another receiver |
| `MoltenCodes TimerKit host returned an invalid native timer handle` | a start whose `C_Timer` constructor returned something without a `Cancel` method; the start is rolled back |

Host and internal failures carry no added position:

| Message | Raised by |
|---|---|
| the host's own error object, unchanged | a start whose `C_Timer` constructor raised (the start is rolled back), and the first native `Cancel` failure of `Cancel()`, `Restart()`, `CancelAll()`, `Close()` and `CloseAddonScopes` |
| `MoltenCodes TimerKit native timer handle is invalid` | a cancellation whose stored host handle lost its `Cancel` method after the start checked it |
| `MoltenCodes TimerKit runtime dispatch is corrupted` | a native callback that finds the shared dispatch table damaged |

Loading raises `MoltenCodes TimerKit requires Registry API 2 to be loaded
first`, `MoltenCodes TimerKit requires a valid Registry API 2 facade`,
`MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker`, or
`MoltenCodes TimerKit package state is corrupted or incomplete`.

## Cost

- Every getter, `SetUserData`, `IsPending`, `IsCancelled` and
  `GetActiveCount` is a receiver check and a field read; none allocates.
- `New`, `After` and `Every` allocate the timer handle. Every start
  (`Start`, `Restart`, `After`, `Every`) allocates one callback closure and
  whatever the host allocates for its native handle, and reads
  `GetTimePreciseSec` once when the client has it.
- `Cancel()` allocates nothing beyond what the host's `Cancel` does.
- A delivered repeating tick allocates nothing and reads the clock once; a
  delivered one-shot allocates nothing.
- `CancelAll()`, `Close()` and `CloseAddonScopes` allocate one snapshot array
  of the scope's running timers and sort it by creation, O(n log n) in them.
- `ForAddon` is one table lookup once the addon's logout route is decided; see
  [At logout](#at-logout) for what deciding it costs.

## Limits

TimerKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`
(design constitution, principle 4a). What it retains is the consumer's own and
grows only with the consumer's calls:

- a scope holds the timers that are running in it, and releases each one when
  it completes or is cancelled; idle and completed timers are not retained;
- the addon-scope map holds one scope per name passed to `ForAddon`, and
  `CloseAddonScopes` records nothing for a name that never had one;
- the logout routing holds at most one LifecycleKit subscription per addon
  scope (released when the scope closes) and one EventKit connection for the
  package;
- the internal convenience scope behind `TimerKit:New` / `After` / `Every` is one scope,
  replaced only when it is closed.

The host bounds the number of native timers, not TimerKit.

## Native boundary

TimerKit relies only on:

```text
C_Timer.NewTimer
C_Timer.NewTicker
nativeHandle:Cancel()
GetTimePreciseSec()   -- optional; deadlines only, never used to schedule
```

It does not inspect native timer userdata or depend on undocumented implementation fields. This is important because modern WoW timer handles are native FunctionContainer userdata.

LifecycleKit API 1 and EventKit API 1 are optional. TimerKit finds them through `Registry:Find` (an older Registry's `Get` is the equivalent fallback) only inside `ForAddon`, to arrange the logout closing described under [At logout](#at-logout); nothing else reads them.

The native boundary is intentionally narrow so TimerKit behavior can be tested with a deterministic adapter outside the game client.

## Embedded copies

TimerKit is registered as `timerKit`, API generation `1`, through Registry API 2. The package facade, Timer prototype, Scope prototype, and metatables are shared-state compatible so future compatible revisions can preserve existing logical object identity.

Native callbacks route through a shared runtime dispatch table instead of permanently closing over one implementation revision. This provides the foundation for compatible live revision upgrades without replacing running logical timer objects.
