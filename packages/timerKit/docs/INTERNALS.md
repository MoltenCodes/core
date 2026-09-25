# TimerKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API; the contract is [`API.md`](API.md).

## Package state

`TimerKit._state` is shared by every embedded copy (schema 1):

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `runtimeRevision` | The revision that last committed its functions. |
| `addonScopes` | Addon name to its canonical scope. |
| `defaultScope` | The manual scope behind `TimerKit:After`, `Every` and `New`; replaced once closed. |
| `dispatch` | The functions host callbacks and other Kits' callbacks resolve when they run (below). |
| `nextTimerId` | The last timer identifier handed out. |
| `timerMetatable`, `scopeMetatable` | The metatables every timer and scope carries; `__index` is the shared `Timer` or `Scope` prototype. |
| `logoutConnection`, `logoutEventScope` | The package-level EventKit `PLAYER_LOGOUT` connection and its scope, or `false` (API.md, "At logout"). |

## Timer records

A timer is a table only TimerKit writes. Its private fields:

| Field | Meaning |
|---|---|
| `_id` | Session-wide creation order. `CancelAll`, `Close` and `CloseAddonScopes` sort by it. |
| `_scope` | The owning scope. |
| `_callback` | The owner's callback. |
| `_delay` | The delay or interval in seconds. |
| `_repeating` | `true` on a repeating timer. Absent on a one-shot timer built by revision 10 or later, `false` on one an older revision built; both read as not repeating. |
| `_state` | `"idle"`, `"running"`, `"completed"` or `"cancelled"`. |
| `_native` | The host handle of the current start while running, `false` otherwise (`nil` on a timer an older revision left idle). |
| `_deadline` | The `GetTimePreciseSec()` instant of the next fire while running, or `false`. |
| `_userData` | The value `SetUserData` attached. |
| `_generation` | Only on timers revision 9 or older built: the counter their host callbacks are bound to. |

**Shape.** The constructor lists every field the timer will ever hold, `_userData = nil` included: a `nil` field in a table constructor still counts toward the hash size Lua allocates, so the hash part is sized once and no later write rehashes it. That is what keeps `SetUserData` allocation-free. A one-shot timer has eight fields (`_repeating` is left out), the smallest hash with room for all of them, 384 bytes on a 64-bit Lua 5.1; a repeating timer has nine, which Lua rounds up to sixteen slots, 704 bytes. Repeating timers are few and long-lived, one-shot timers are created all the time.

**Access.** The per-timer paths (start, cancel, fire) read and write these fields by plain indexing rather than `rawget`/`rawset`. The timer metatable has no `__newindex`, and a field that is absent falls through `__index` to the `Timer` prototype, which holds only the capitalised public methods, so indexing answers exactly what `rawget` would at the cost of one VM instruction instead of a C call.

## Scope records

| Field | Meaning |
|---|---|
| `_addonName` | The addon name of a canonical scope, `nil` for a manual one. |
| `_active` | The set of running timers. |
| `_activeCount` | Its size. |
| `_closed` | Terminal once `true`. |
| `_logoutRoute`, `_logoutSubscription` | Addon scopes only: who closes the scope at logout (API.md, "At logout"). |

A timer is in `_active` exactly while its state is `"running"`.

## Stale host callbacks

Every start creates one host handle and one callback closure, which captures the timer and, once the host constructor has returned, that handle. The closure calls `dispatch.fireStarted(timer, handle)`, which fires the timer only while it is running and `_native` is still that handle (`rawequal`, so no host `__eq` runs). Cancellation sets `_native` to `false` before it asks the host to cancel, a delivered one-shot does so before it calls the owner, and a restart binds the new handle; so a host callback of an earlier start never re-enters the timer, even when the host's own cancellation raised. A host that called back from inside its constructor would find the timer not yet running, with `_native` still `false`, and be ignored.

**Order of a start (revision 11).** `armTimer` builds the closure, calls the host constructor directly and only then writes `_native`, `_state = "running"`, the scope's active set and `_deadline`. A constructor that raises therefore leaves the timer exactly as it was, with no `pcall` and no rollback; revision 10 and older marked the timer running first and undid it under `pcall`. The handle is trusted (API.md, "Trusting the host handle"): a start refuses only `nil` or `false`, which the closure's captured `nil` could not be told from, and `cancelTimer` calls `native:Cancel()` directly after the logical cancellation.

This relies on one property of `C_Timer`: every `NewTimer` and `NewTicker` call returns its own handle. The closure keeps its handle alive, so the host cannot hand the same object to a later start while the earlier callback can still run.

Revision 9 and older bound a start to a per-timer `_generation` counter and called `dispatch.fire(timer, generation)`. After an in-place upgrade those callbacks keep running: `dispatch.fire` is `fireLegacyTimer`, which fires only while the timer is running with that generation, and every start moves a timer's `_generation` on when it has one. A legacy callback therefore goes stale at the same moments as before.

The per-start closure has two upvalues of its own (the timer and the handle) and allocates about 140 bytes. Binding it to the handle rather than to a counter is what lets a one-shot timer fit in eight fields.

## Dispatch

Callbacks TimerKit hands to the host and to other Kits call through `_state.dispatch` when they run, so a newer revision replaces the code they run without touching them:

| Entry | Called by |
|---|---|
| `fireStarted(timer, handle)` | The host callbacks revision 10 and later create. |
| `fire(timer, generation)` | The host callbacks revision 9 and older created. |
| `closeScope(scope)` | Shutdown wrappers of revision 5 and older that could not be disconnected. |
| `closeOnShutdown(addonName)` | LifecycleKit `OnShutdown` subscriptions (logout route 2). |
| `closeOnLogout()` | The EventKit `PLAYER_LOGOUT` connection (logout route 3). |

A newer revision must keep publishing every entry an older revision's callbacks can still call.

## Upgrades

A newer revision keeps `_state`, the prototypes and the metatables, rewrites the prototypes' methods and the dispatch entries, and leaves every timer and scope object in place. Timers an older revision built keep their field layout; the table above says how each difference reads.

Revision 11 changes no state and no layout. A timer revision 10 started keeps its handle and its callback closure, which calls `dispatch.fireStarted` and so runs the new code; cancelling it after the upgrade calls its handle's `Cancel` directly.
