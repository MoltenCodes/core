# TimerKit API

TimerKit API generation **1** provides cancelable one-shot/repeating timers and explicit ownership scopes over World of Warcraft's native timer facilities.

## Loading

Load Registry API 2, then `timerKit\TimerKit.lua`, the core. An addon that
pauses timers adds the Pausing part after it:

```xml
<Script file="registry\Registry.lua"/>
<Script file="timerKit\TimerKit.lua"/>
<Script file="timerKit\parts\TimerKit-Pausing.lua"/> <!-- only to pause timers -->
```

`python3 -m tooling.package.embeds` writes these lines for any selection of
Kits and parts. TimerKit requires nothing else. LifecycleKit API 1 and
EventKit API 1 are optional: TimerKit finds them through `Registry:Find` at
an addon's first `ForAddon`, only to arrange that the addon's scope is closed
at logout (see [At logout](#at-logout)).

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `New(options)` | Create an idle timer in TimerKit's internal manual scope. |
| `After(delay, callback)` / `After(delay, receiver, methodName)` | Create and immediately start a one-shot timer. The method-name form: see [Method-name callbacks](#method-name-callbacks). |
| `Every(interval, callback)` / `Every(interval, receiver, methodName)` | Create and immediately start a repeating timer. |
| `CreateScope()` | Create a manually owned timer scope. |
| `ForAddon(addonName)` | Return the canonical scope for an addon, creating it on demand. |
| `CloseAddonScopes(addonName)` | Close that addon's scope; returns `false` when it has none or it was already closed. |
| `HasPart(name)` | `true` when the named part (`"Pausing"`) is installed; see [Parts](#parts). |

Timer handles:

| Method | Purpose |
|---|---|
| `GetState()` | Return `idle`, `running`, `paused`, `completed`, or `cancelled`. |
| `GetDelay()` | Return the configured delay/interval in seconds. |
| `GetScope()` | Return the owning TimerKit scope. |
| `GetUserData()` | Return the opaque value attached by the owner, or `nil`. |
| `SetUserData(value)` | Attach one opaque owner-defined value; returns the timer. |
| `IsRepeating()` | Return whether the timer is repeating. |
| `IsPending()` | Return whether the logical timer is running. |
| `IsCancelled()` | Return whether it was logically cancelled. |
| `Start()` | Start an idle/completed/cancelled timer; return `false` if already running or paused. |
| `Cancel()` | Cancel a running or paused timer; return `false` otherwise. |
| `Restart()` | Cancel if necessary and start again; the earlier start's native callback is ignored. |
| `GetRemaining()` | Seconds until the next fire while running, the seconds kept while paused; `nil` otherwise. |
| `GetDeadline()` | Monotonic instant of the next fire while running; `nil` otherwise. |
| `Pause()` | Pause a running timer, keeping what is left of its delay; return `false` if it is not running. [Pausing part](#pausing). |
| `Resume()` | Resume a paused timer for what was left; return `false` if it is not paused. [Pausing part](#pausing). |
| `IsPaused()` | Return whether the timer is paused. [Pausing part](#pausing). |

Scopes:

| Method | Purpose |
|---|---|
| `New(options)` | Create an idle timer owned by this scope. |
| `After(delay, callback)` / `After(delay, receiver, methodName)` | Start a one-shot timer in this scope. |
| `Every(interval, callback)` / `Every(interval, receiver, methodName)` | Start a repeating timer in this scope. |
| `CancelAll()` | Cancel every active timer and keep the scope reusable. |
| `Close()` | Terminally close the scope after best-effort cancellation. |
| `Reopen()` | Reopen a closed manual scope; `false` when it was open; raises on an addon scope. See [Reopening a manual scope](#reopening-a-manual-scope). |
| `IsClosed()` | Return whether the scope is terminally closed. |
| `GetAddonName()` | Return the owning addon name, or `nil` for manual scopes. |
| `GetActiveCount()` | Return the number of logically running or paused timers. |

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

Unknown option fields are rejected so misspellings cannot silently change timer behavior. When several unknown fields are present the message names the alphabetically first one. A field name that is not a string, number or boolean is named by its type (`"<table>"`), so a key's `__tostring` never runs (revision 13).

Timer callbacks receive the **logical TimerKit timer handle**, not the native `C_Timer` FunctionContainer.

## Method-name callbacks

`After` and `Every`, on scopes and on the facade, also take
a receiver table and the name of one of its methods, the counterpart of
AceTimer's `self:ScheduleTimer("Method", delay)`:

```lua
local Poller = {}

function Poller:Refresh(timer)
  -- self is Poller; timer is the TimerKit timer that fired
end

local timers = TimerKit:ForAddon("MyAddon")
timers:After(2, Poller, "Refresh")
timers:Every(5, Poller, "Refresh")
```

- **Checked at the call.** `receiver[methodName]` must be a function when
  `After` or `Every` runs (it may come from the receiver's metatable), or the
  call raises at the caller's line: `<method> receiver has no method "Name"`.
  `methodName` must be a non-empty string and not a secret value. The method
  name is required: AceTimer has no default either.
- **Looked up at every fire, as AceTimer does.** Each time the timer fires it
  reads `receiver[methodName]` and calls it as `method(receiver, timer)`, so a method
  replaced or hooked after the start (for example through HookKit) is the one
  that runs. When the method is gone by then, the callback raises
  `TimerKit timer receiver has no method "Name"`, exactly as a closure
  callback that raises: a one-shot timer has already completed, a repeating
  timer keeps ticking (see [Repeating callback errors](#repeating-callback-errors)).
- **Arguments.** The method receives the receiver and the timer. AceTimer's
  extra argument has no counterpart; attach it with `SetUserData`.
- **Everything else is a timer.** `Restart`, `Pause`, `Resume` (Pausing
  part), `Cancel` and scopes behave exactly as for a closure callback; `Restart` keeps
  calling the same receiver and method name.
- **Cost.** The form wraps the lookup in one closure per timer (136 bytes on
  a 64-bit Lua 5.1) that becomes the timer's callback, so the start, cancel
  and fire paths are those of a closure callback plus one table read and one
  Lua call per fire. Measured on the host: 35.1 ns per call against 19.2 ns
  for a closure.

`New(options)` takes a function `callback` only.

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
  or serializes it, and attaching a value allocates nothing: every timer's
  record has a slot for it from the start (one-shot and repeating timers
  share the same nine-slot record);
- `SetUserData(nil)` detaches the value;
- user data survives `Cancel()`, `Start()`, and `Restart()`. TimerKit never
  clears it, so an owner that attaches a large object is responsible for
  detaching it when the timer is no longer interesting;
- `GetUserData()` returns `nil` for a timer that has never been given one.

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
  while the timer is `running`, the seconds it kept while `paused` (see
  [Pausing](#pausing), a part), and `nil` in every other state — `idle`, `completed`
  and `cancelled`. It never returns `0` to mean "not running", so a caller can
  tell "about to fire" from "will not fire"; a paused timer the host was late
  to deliver keeps `0`.
- `GetDeadline()` returns the instant of the next fire on the
  `GetTimePreciseSec()` clock while `running`, and `nil` otherwise, `paused`
  included.
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

### Without `GetTimePreciseSec`

The clock is optional. On a host that does not publish `GetTimePreciseSec`,
TimerKit loads and every timer works exactly as before, but no deadline is
recorded: `GetRemaining()` and `GetDeadline()` return `nil` even for a running
timer. `Pause()` then keeps the full delay, which `GetRemaining()` answers while
the timer is paused. Requiring the clock would have added a host facility inside API
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
through TimerKit, such as a missing native timer handle, use the same position.

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

With the Pausing part, `Pause` takes a running timer to `paused` and `Resume` takes it back to `running`; `Cancel` and `Restart` work from `paused` as from `running`. See "Pausing".

`Cancel()` and `Start()` are idempotent with respect to an already-satisfied state: cancelling a timer that is neither running nor paused, and starting one that is running or paused, return `false` rather than creating duplicate native work.

## Stale callback protection

Every start or restart binds the timer to the native handle that start created, and the native callback of a start fires the timer only while the timer is running and still bound to that handle. Cancellation unbinds the handle **before** TimerKit asks it to cancel, and a restart binds the new one.

This means an already-queued or otherwise stale native callback cannot execute user code after a logical cancel/restart, even if native cancellation fails. It relies only on what `C_Timer` already promises: each `NewTimer`/`NewTicker` call returns its own handle.

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

Scopes track only **active** timers: running and paused ones. Idle, completed and cancelled timers do not contribute to `GetActiveCount()`.

Bulk cleanup runs in deterministic timer-creation order. If native cancellation raises, TimerKit continues attempting the remaining timers, preserves logical cancellation for every attempted timer, then re-raises the first native error object.

### Reopening a manual scope

`scope:Reopen()` makes a closed manual scope usable again
and answers `true`; on an open scope it answers `false` and changes nothing.
The reopened scope is empty and behaves like a new one. Timers its close
cancelled stay cancelled; `Start()` or `Restart()` runs them in the scope
again. ModuleKit uses this to keep one timer scope per module across enable
cycles instead of building a new one each time.

`Reopen` on an addon scope (`ForAddon`) raises
`TimerKit.Scope:Reopen cannot reopen an addon scope` at the caller's line:
closing an addon scope is its addon's teardown and stays terminal.

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

**An addon scope closes at logout whenever LifecycleKit or EventKit is loaded, and otherwise by your own call**, whatever revisions of them are paired with this one. The first `ForAddon(addonName)` for an addon looks for the optional Kits through `Registry:Find` and takes the first case that applies. The cases keep their numbers; case 2, an `OnShutdown` subscription per addon for a LifecycleKit before 0.6.0, went with revision 15's upgrade floor (no such LifecycleKit was ever published), and such a LifecycleKit now falls to case 3:

1. **LifecycleKit lists `"timerKit"` in `LifecycleKit.CLOSES_ADDON_SCOPES`** (LifecycleKit 0.6.0 and later). TimerKit subscribes nothing and makes sure the addon is known to LifecycleKit (it calls `LifecycleKit:ForAddon(addonName)` once): LifecycleKit calls `CloseAddonScopes` when the addon reaches `shutdown`, after its shutdown callbacks have run and before it closes the addon's SchedulerKit, EventKit, HookKit, CommandKit and CommKit scopes and its SignalKit bus, so no timer fires into a listener that is being torn down. This is the case with ordering guarantees, and it covers an addon that never used LifecycleKit itself.
3. **No such LifecycleKit, but EventKit.** TimerKit keeps one package-level `PLAYER_LOGOUT` one-shot, in an EventKit scope of its own, created by the first `ForAddon` that needs it. At logout it closes every addon scope case 1 does not cover, in addon-name order; a failure does not stop the others and reaches the host error handler through EventKit. EventKit runs `PLAYER_LOGOUT` listeners in connection order, so the scope closes when this listener runs: after any listener connected before the addon's first `ForAddon`, before any connected after it. Use LifecycleKit when the addon's own logout code must run while its timers are live.
4. **Neither.** Nothing is subscribed and `ForAddon` works as always. Call `CloseAddonScopes` yourself on `PLAYER_LOGOUT`, for example from a frame of your own:

```lua
local logoutFrame = CreateFrame("Frame")
logoutFrame:RegisterEvent("PLAYER_LOGOUT")
logoutFrame:SetScript("OnEvent", function()
  TimerKit:CloseAddonScopes("MyAddon")
end)
```

The decision is made once per addon, except for case 4, which the next `ForAddon` for that addon examines again, because a Kit loaded after the first call (an addon later in the load order embedding EventKit, say) can make logout observable. A LifecycleKit 0.5.0 or later that loads after case 4 was chosen closes the scope anyway once the addon asks it for an instance, because it calls `CloseAddonScopes` for every addon it knows. Closing the scope twice is harmless: the second call answers `false`.

The routing costs one field read per `ForAddon` once decided. TimerKit allocates one EventKit scope and connection for the whole package in case 3, and nothing per addon.

`CloseAddonScopes(addonName)`:

- must be called on the facade (`TimerKit:CloseAddonScopes(...)`); any other receiver raises;
- validates `addonName` as a non-empty string;
- returns `false` when the addon never asked for a scope, and records nothing, so the addon-scope map grows only with `ForAddon` calls;
- returns `false` when the scope is already closed;
- otherwise cancels every running or paused timer of the scope in creation order, closes it and returns `true`. A native cancellation failure does not stop the sweep: every timer is cancelled logically and the first error is re-raised afterwards, as for `Scope:Close()`.

Closing is terminal: the closed scope stays the canonical addon scope, so a later `ForAddon(addonName)` returns it and refuses new timers. A timer callback may close its own addon scope; the firing timer is cancelled with the rest, so a ticker does not tick again.

Manual scopes and TimerKit's package-level convenience scope are never closed by `CloseAddonScopes`.

A scope revision 14 already routed keeps its route and the package's `PLAYER_LOGOUT` connection, whose callback resolves the running revision's code when it fires. A scope revision 14 routed through case 2 lets go of its `OnShutdown` subscription when revision 15 takes over and is routed again as a first `ForAddon` would.

## Package-level convenience timers

```lua
TimerKit:New({ delay = 1, callback = callback })
TimerKit:After(1, callback)
TimerKit:Every(5, callback)
```

These methods use an internal manual scope. They are intentionally **not addon-owned**, because TimerKit cannot infer ownership from arbitrary callers. Framework and addon code that requires deterministic shutdown cleanup should prefer `ForAddon` (closed through `CloseAddonScopes`) or an explicitly managed scope.

If the internal convenience scope is explicitly reached through `timer:GetScope()` and closed, the next package-level timer operation creates a fresh internal scope rather than permanently disabling the facade.

## Parts

TimerKit is a core file and one optional part
([ADR 0001](../../../docs/decisions/0001-kit-core-and-parts.md)). An addon
embeds the core and only the parts it uses.

| Part | File | Adds |
|---|---|---|
| `Pausing` | `timerKit\parts\TimerKit-Pausing.lua` | `Timer:Pause`, `Timer:Resume`, `Timer:IsPaused` |

- `TimerKit:HasPart(name)` answers `true` when the named part is installed in
  the session (by any addon), `false` otherwise. A name that is not a string,
  or a secret value, raises `TimerKit:HasPart name must be a part name string`
  at the caller's line. Other Kits ask `HasPart`, never
  `type(TimerKit.Timer.Pause) == "function"`: the member is always there.
- Without the part, each of its members raises at the caller's line, for
  example `TimerKit.Timer:Pause is in TimerKit's Pausing part, which is not
  loaded: add timerKit\parts\TimerKit-Pausing.lua to embeds.xml after
  timerKit\TimerKit.lua`.
- The part keeps nothing of its own: it reads and writes the timer's slots and
  fills two `state.dispatch` entries, so the highest revision of the core and
  of the part each serves every addon, and a core loaded after the part keeps
  the part's members.
- The core keeps the `"paused"` state wherever it already handles it
  (`Cancel`, `Restart`, `CancelAll`, `Close`, `GetState`, `GetRemaining`,
  `GetDeadline`, `IsPending`, `Start`), so a paused timer an upgrade inherits
  without the part stays paused, answers `GetRemaining`, and can be cancelled;
  only `Resume` needs the part.

### Pausing

The Pausing part, `timerKit\parts\TimerKit-Pausing.lua`. Without it,
`Pause`, `Resume` and `IsPaused` raise at the caller's line (see
[Parts](#parts)); everything else on this page works without it, `"paused"`
included wherever a paused timer can be met.

```lua
local cooldown = TimerKit:After(30, onReady)
cooldown:Pause()           -- true; cooldown:GetRemaining() keeps, say, 12.5
cooldown:Resume()          -- true; fires 12.5 seconds from now
```

- `Pause()` cancels the host handle and keeps the seconds left until the next fire: the deadline minus `GetTimePreciseSec()`, never below 0, or the full delay on a host without the clock. A late host's remainder is 0. While paused, `GetRemaining()` answers those seconds, `GetDeadline()` `nil`, `IsPending()` `false` and `GetState()` `"paused"`.
- `Resume()` asks the host for a one-shot of the kept seconds. A one-shot timer completes when it fires. A repeating timer runs its callback then and is armed again as a ticker of its interval just before that callback, so a `Cancel` inside it cancels the ticker. A host constructor that raises leaves the timer paused, or, for that re-arm of a repeating timer, cancelled.
- A paused timer stays in its scope: `GetActiveCount()` counts it, `CancelAll()` and `Close()` cancel it. `Resume()` on a timer a closed scope cancelled answers `false`.
- `Start()` on a paused timer answers `false`; `Restart()` cancels it and starts its full delay.
- A paused timer holds no host handle, and a callback of the handle it held is ignored.

This is built on `C_Timer` handles, not on an animation host, so TimerKit keeps no frame and does no work per frame (`docs/records/timerKit.md`, "timerKit pausable timers").

## Secret values

A secret value (Retail 12.0.0 and later) raises when it is compared, so every
argument TimerKit compares or tests is asked about first, at the caller's
line: the delay or interval of `New`, `After` and `Every`, `repeating`, the
receiver and method name of the method-name form, the addon name of
`ForAddon` and `CloseAddonScopes`, the receiver of `CloseAddonScopes`, and the
name of `HasPart`. An absent option is recognised by its type, never by
comparing it with `nil`. The value given to `Timer:SetUserData` is stored and
never compared, so it may be secret. Receivers of timer and scope methods are
refused by their metatable alone, which no secret value has.

TimerKit reads `issecretvalue` once, when it loads; on a host that had none
then, it asks for the global again at each check, so a probe installed later
is honoured (the shared `isSecret` block, `docs/TOOLING.md`, "Shared helper
blocks"). A host without `issecretvalue` has no secret values. A table key
named in a refusal is described without running its `__tostring` (the shared
`describeKey` block).

## Limits

TimerKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`
(design constitution, principle 4a). What it retains is the consumer's own and
grows only with the consumer's calls:

- a scope holds the timers that are running or paused in it, and releases each
  one when it completes or is cancelled; idle and completed timers are not
  retained;
- the addon-scope map holds one scope per name passed to `ForAddon`, and
  `CloseAddonScopes` records nothing for a name that never had one;
- the logout routing holds one EventKit connection for the package;
- the internal convenience scope behind `TimerKit:New` / `After` / `Every` is one scope,
  replaced only when it is closed.

The host bounds the number of native timers, not TimerKit.

## Error behaviour

`<method>` below is the public name of the method called, such as
`TimerKit:After`, `TimerKit.Scope:New` or `TimerKit.Timer:Restart`. Every
message in the first table is raised at the caller's line (see
[Argument errors point at the caller](#argument-errors-point-at-the-caller)).

| Message | Raised by |
|---|---|
| `<method> must be called on a TimerKit timer` | a timer method called on anything but a TimerKit timer |
| `<method> must be called on a TimerKit scope` | a scope method called on anything but a TimerKit scope |
| `<method> callback must be a function, or a receiver table followed by a method name` | `After` and `Every` with a `callback` that is neither a function nor a table (revision 14; the text still contains the earlier `callback must be a function`) |
| `<method> callback must be a function` | `New` without a function `callback` |
| `<method> methodName must be a non-empty string` | `After` and `Every` with a receiver and no method name, or one that is not a non-empty string |
| `<method> methodName must not be a secret value` | `After` and `Every` with a receiver and a secret method name |
| `<method> receiver must not be a secret value` | `After` and `Every` with a secret receiver |
| `<method> receiver has no method "<name>"` | `After` and `Every` when `receiver[methodName]` is not a function |
| `TimerKit.Scope:Reopen cannot reopen an addon scope` | `Reopen` on a scope `ForAddon` returned |
| `<method> delay must be a finite number` | a delay or interval that is not a number, or is NaN or infinite |
| `<method> delay must be zero or greater` | a negative one-shot delay |
| `<method> delay must be greater than zero for repeating timers` | a repeating interval of zero or less |
| `<method> options must be a table` | `New` without an option table |
| `<method> options contains unknown field "<name>"` | `New` with a field other than `delay`, `callback` and `repeating`; the alphabetically first one is named, a key that is not a string, number or boolean by its type (`"<table>"`) |
| `<method> repeating must be a boolean` | `New` with a non-boolean `repeating` |
| `<method> delay must not be a secret value` | `After`, `Every` and `New` with a secret delay or interval |
| `<method> repeating must not be a secret value` | `New` with a secret `repeating` |
| `TimerKit:ForAddon addonName must not be a secret value` | `ForAddon` with a secret addon name |
| `TimerKit:CloseAddonScopes addonName must not be a secret value` | `CloseAddonScopes` with a secret addon name |
| `<method> cannot create a timer in a closed scope` | `New`, `After` and `Every` on a closed scope |
| `<method> cannot start a timer in a closed scope` | `Timer:Start()` when the timer's scope is closed |
| `<method> cannot restart a timer in a closed scope` | `Timer:Restart()` when the timer's scope is closed |
| `TimerKit:ForAddon addonName must be a non-empty string` | `ForAddon` |
| `TimerKit:CloseAddonScopes addonName must be a non-empty string` | `CloseAddonScopes` |
| `TimerKit:CloseAddonScopes must be called on the TimerKit facade; use TimerKit:CloseAddonScopes(addonName)` | `CloseAddonScopes` with another receiver |
| `TimerKit:HasPart name must be a part name string` | `HasPart` with a name that is not a string, or a secret value |
| `TimerKit.Timer:<member> is in TimerKit's <Part> part, which is not loaded: add timerKit\parts\TimerKit-<Part>.lua to embeds.xml after timerKit\TimerKit.lua` | a member of a part the session has not loaded (`Pause`, `Resume`, `IsPaused`) |
| `MoltenCodes TimerKit host returned an invalid native timer handle` | a start, or a `Resume()` (Pausing part), whose `C_Timer` constructor returned `nil` or `false` instead of a handle; the timer is left in the state it had |

Host and internal failures carry no added position:

| Message | Raised by |
|---|---|
| the host's own error object, unchanged | a start or `Resume()` whose `C_Timer` constructor raised (the timer is left in the state it had), and the first native `Cancel` failure of `Cancel()`, `Restart()`, `Pause()`, `CancelAll()`, `Close()` and `CloseAddonScopes`; inside the host callback of a resumed repeating timer, a ticker constructor that raises (the timer is left cancelled) |
| Lua's own error for calling a missing method, such as `attempt to call method 'Cancel' (a nil value)` | a cancellation of a timer whose host handle has no `Cancel` method; TimerKit trusts the handle (see [Native boundary](#native-boundary)), and the timer is already logically cancelled when it raises |
| `TimerKit timer receiver has no method "<name>"` | the callback of a method-name timer whose method is gone when it fires (see [Method-name callbacks](#method-name-callbacks)) |
| Lua's own error for indexing or calling a missing value | a native callback that finds the shared dispatch table damaged |

Loading raises `MoltenCodes TimerKit requires Registry API 2 to be loaded
first`, `MoltenCodes TimerKit requires a valid Registry API 2 facade`,
`MoltenCodes TimerKit requires C_Timer.NewTimer and C_Timer.NewTicker`,
`MoltenCodes TimerKit package state is corrupted or incomplete`, or, over an
embedded copy older than the upgrade floor, `MoltenCodes TimerKit revision 15
upgrades in place from revision 14 or later only; an addon embeds revision
<n>, which was never published`. The Pausing part raises `MoltenCodes TimerKit
part Pausing requires TimerKit API 1 to be loaded first` when it loads before
the core.

## Performance

- Every getter, `SetUserData`, `IsPending`, `IsCancelled` and
  `GetActiveCount` is a receiver check and a field read; none allocates.
- `New`, `After` and `Every` allocate the timer handle: one table of nine
  array slots, sized once for every field it will hold, `SetUserData`
  included: 208 bytes for a one-shot or a repeating timer on a 64-bit Lua 5.1,
  measured (eight named fields would take 384 and 704 bytes). A pending
  one-shot timer, with its callback closure, the test host's handle and its
  scope entry, holds 936 bytes there. Every start
  (`Start`, `Restart`, `After`, `Every`) allocates one callback closure (about 140
  bytes) and whatever the host allocates for its native handle, and reads
  `GetTimePreciseSec` once when the client has it. The host constructor is
  called directly, not under `pcall`, and the handle it returns is not
  inspected.
- `After` and `Every` with a function callback test every argument in one
  condition and start the timer in one more frame; only a call that fails a
  test, or a method-name call, runs the validators. `Cancel()` is one frame.
- `Cancel()` allocates nothing beyond what the host's `Cancel` does, and calls
  it directly on the stored handle; `Pause()` (Pausing part) likewise, plus
  one clock read.
- `Resume()` (Pausing part) allocates one callback closure and the host's one-shot handle and
  reads the clock once. When a resumed repeating timer fires, it allocates one
  more closure and the host's ticker handle, as a start does.
- A delivered repeating tick allocates nothing and reads the clock once; a
  delivered one-shot allocates nothing.
- `CancelAll()`, `Close()` and `CloseAddonScopes` allocate one snapshot array
  of the scope's running and paused timers and sort it by creation, O(n log n)
  in them.
- `ForAddon` is one table lookup once the addon's logout route is decided; see
  [At logout](#at-logout) for what deciding it costs.

### Resident size

Measured on the host (Lua 5.1.5, 64-bit, debug information kept as the
client keeps it), resident after a full collection, loaded with Registry,
SignalKit, EventKit and LifecycleKit:

| File | Revision 14 | Revision 15 |
|---|---:|---:|
| `TimerKit.lua` | 60.2 KB | 49.6 KB |
| `parts/TimerKit-Pausing.lua`, when embedded | (in the core) | 2.9 KB |

AceTimer-3.0 measures 8.1 KB the same way. What the core keeps beyond it buys
TimerKit's documented guarantees: timer handles, ownership scopes and their
logout routes, argument errors at the caller's line, secret-value refusals,
and in-place upgrade.

### Measured in the client

Measured on 2026-09-24 in the Retail 12.1.0 (build 69933) client:

- `After(0.25)` fired 7.45 ms after the deadline TimerKit recorded, not before
  it; the longest frame of that run took 13.28 ms. This is the lateness of up
  to one frame that [Precision](#precision) describes.
- Three consecutive `Every(0.1)` intervals measured 100.23, 99.74 and 99.94 ms.
- A ticker whose callback raised kept ticking: 5 more ticks arrived in the next
  500 ms and its state stayed `running`, as
  [Repeating callback errors](#repeating-callback-errors) documents.
- `Start` costs about 194 bytes of Lua heap beyond what the client's own
  `C_Timer.NewTimer` followed by `Cancel` costs; the list above says what a
  start allocates.

## Native boundary

TimerKit relies only on:

```text
C_Timer.NewTimer
C_Timer.NewTicker
nativeHandle:Cancel()
GetTimePreciseSec()   -- optional; deadlines only, never used to schedule
```

It does not inspect native timer userdata or depend on undocumented implementation fields. This is important because modern WoW timer handles are native FunctionContainer userdata.

### Trusting the host handle

Since revision 11 (0.7.0) TimerKit trusts the handle `C_Timer.NewTimer` and `C_Timer.NewTicker` return. A start refuses only a missing handle (`nil` or `false`, which the stale-callback check could not tell from "not started yet"); it no longer reads the handle's `Cancel` field under `pcall` to check that it is a function, and a cancellation calls `handle:Cancel()` directly instead of reading `Cancel` again, protected, first. Every supported client returns a FunctionContainer with `Cancel` from both constructors. The checks cost about 110 ns per start and 60 ns per cancellation, on paths every timer takes.

What a host that breaks this promise now sees:

- a start whose constructor returns a handle without `Cancel` succeeds, and the timer runs;
- cancelling it (`Cancel()`, `Restart()`, `CancelAll()`, `Close()`, `CloseAddonScopes`) raises Lua's own error for the missing method instead of `MoltenCodes TimerKit native timer handle is invalid`. The timer is logically cancelled before the call, so its callback still never runs, and the bulk operations still cancel every timer and re-raise the first error afterwards;
- a constructor that raises leaves the timer in the state it had, as before; TimerKit now asks the host before it marks the timer running, so there is nothing to roll back.

Revision 10 and older raised `MoltenCodes TimerKit host returned an invalid native timer handle` at the start for a handle without `Cancel`, and `MoltenCodes TimerKit native timer handle is invalid` at a cancellation whose handle had lost it.

LifecycleKit API 1 and EventKit API 1 are optional. TimerKit finds them through `Registry:Find` (an older Registry's `Get` is the equivalent fallback) only for the logout closing described under [At logout](#at-logout): inside `ForAddon`, to arrange it, and once during the upgrade from revision 14 for a scope that revision routed through case 2. Nothing else reads them.

The native boundary is intentionally narrow so TimerKit behavior can be tested with a deterministic adapter outside the game client.

## Embedded copies and upgrades

TimerKit is registered as `timerKit`, API generation `1`, through Registry API 2. The package facade, Timer prototype, Scope prototype, and metatables are shared-state compatible so future compatible revisions can preserve existing logical object identity. When two addons embed different revisions, the highest wins and upgrades the shared state in place; the same holds for each part, by its own revision.

Native callbacks route through a shared runtime dispatch table instead of permanently closing over one implementation revision, so a running timer's callback runs the newest revision's code when it fires.

### Upgrading in place

Revision 15 takes over the state of revision 14 in place, its upgrade floor: every timer, scope, addon scope, logout route and user value revision 14 made keeps working, running and repeating timers fire through the new code, and a timer revision 14 paused stays paused. Without the Pausing part, such a timer answers `GetRemaining` and can be cancelled or restarted, and `Resume` raises the part's message; a resume revision 14 already armed still fires, through revision 14's own entry in the dispatch table, which the part replaces when it loads.

No revision before 14 was ever published, so revision 15 does not convert what they built (named-field timers, generation-bound callbacks, shutdown subscriptions, state without the logout fields). Loading revision 15 over one of them raises `MoltenCodes TimerKit revision 15 upgrades in place from revision 14 or later only; an addon embeds revision <n>, which was never published`. An older copy loaded after a newer one is ignored, as Registry decides for every Kit.
