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
| `timerRecordMetatable` | The metatable of every timer in the array layout of revision 14 and later; `__index` is the shared `Timer` prototype. Created by revision 14 when the state lacks it. |
| `timerMetatable` | The metatable revisions 13 and older gave every timer. From revision 14 it marks a timer still in the named-field layout, which is converted when met (below). |
| `scopeMetatable` | The metatable every scope carries; `__index` is the shared `Scope` prototype. |
| `logoutConnection`, `logoutEventScope` | The package-level EventKit `PLAYER_LOGOUT` connection and its scope, or `false` (API.md, "At logout"). |

## Timer records

A timer is a table only TimerKit writes. From revision 14 it keeps its fields
in nine array slots:

| Slot | Meaning |
|---|---|
| `[1]` id | Session-wide creation order. `CancelAll`, `Close` and `CloseAddonScopes` sort by it. |
| `[2]` scope | The owning scope. |
| `[3]` callback | The function the timer calls: the owner's callback, or the method-name wrapper below. |
| `[4]` delay | The delay or interval in seconds. |
| `[5]` state | `"idle"`, `"running"`, `"paused"` (revision 12), `"completed"` or `"cancelled"`. |
| `[6]` native | The host handle of the current start while running, `false` otherwise. |
| `[7]` deadline | The `GetTimePreciseSec()` instant of the next fire while running; the seconds left while paused; `false` otherwise. |
| `[8]` repeating | `true` on a repeating timer, `nil` on a one-shot. |
| `[9]` userData | The value `SetUserData` attached. |
| `_generation` | A named field, only on timers revision 9 or older built: the counter their host callbacks are bound to. |

**Shape.** Every timer is built by one constructor that names all nine slots,
the last two possibly `nil`. Lua 5.1 sizes the array part from the
constructor's item count, `nil` items included, so the record is 200 bytes
of table (208 measured with allocator overhead) for a one-shot and a
repeating timer alike, and `SetUserData` never grows it. Revision 13 used
eight named fields for a one-shot timer (384 bytes) and nine for a repeating
one, which Lua rounds up to sixteen hash slots (704 bytes).

**Access.** The per-timer paths read and write the slots by plain indexing;
the source names each slot in a trailing comment (`timer[5] --[[state]]`).
Indexing an array slot is one VM instruction with a constant key, cheaper than
a named field and much cheaper than `rawget`. The timer metatable has no
`__newindex`, and the slots a timer may leave empty (`[8]`, `[9]`) fall
through `__index` to the `Timer` prototype, which holds only the capitalised
public methods, so they read `nil`.

**Older timers.** A timer an older revision built still has its named fields
and the metatable `timerMetatable`. `adoptLegacyTimer` converts it in place:
the same table, so a handle an addon holds keeps working. It clears the named
fields first, so the rehash the slots cause counts only the keys that stay,
then writes the slots and sets `timerRecordMetatable`; a missing `_native` or
`_deadline` becomes `false`, and `_generation` stays a named field. The
conversion happens:

- at load, for the running and paused timers of the addon scopes and the
  package scope (`adoptReachableLegacyTimers`);
- in `validateTimer`, which every timer method calls (`Cancel` only when the
  metatable is not the current one), for any other timer an addon holds;
- in `fireStarted`, `fire` and `fireResumed`, for a running timer of a manual
  scope whose host callback arrives first; `fireStarted` tests for it only on
  the branch that would ignore the callback, so a current timer pays nothing;
- in the snapshot of `CancelAll`, `Close` and `CloseAddonScopes`.

Every other path reads the array layout only.

## Method-name callbacks

`After(delay, receiver, methodName)` and `Every` resolve the form in
`resolveCallback`, on the slow path: the receiver and the name are checked and
`receiver[methodName]` must be a function, or the call raises at the caller's
line. `bindMethod` then builds one closure with two upvalues, the receiver and
the name (136 bytes), which looks the method up at every fire and calls
`method(receiver, timer)`; it raises `TimerKit timer receiver has no method`
when the lookup answers `nil`. The test is `== nil` rather than `type`, a VM
instruction instead of a C call; comparing even a secret value with `nil`
answers `false` without raising (docs/EMBEDDING.md). The closure is the
timer's callback, so nothing else in TimerKit knows the form exists, and a
revision that does not know it runs such a timer like any other.

## Scope records

| Field | Meaning |
|---|---|
| `_addonName` | The addon name of a canonical scope, `nil` for a manual one. |
| `_active` | The set of running and paused timers. |
| `_activeCount` | Its size. |
| `_closed` | Terminal once `true`. |
| `_logoutRoute`, `_logoutSubscription` | Addon scopes only: who closes the scope at logout (API.md, "At logout"). |

A timer is in `_active` exactly while its state is `"running"` or `"paused"` (revision 12).

## Stale host callbacks

Every start creates one host handle and one callback closure, which captures the timer and, once the host constructor has returned, that handle. The closure calls `dispatch.fireStarted(timer, handle)`, which fires the timer only while it is running and its handle slot `[6]` (`_native` before revision 14) is still that handle (`rawequal`, so no host `__eq` runs). Cancellation sets the handle slot to `false` before it asks the host to cancel, a delivered one-shot does so before it calls the owner, and a restart binds the new handle; so a host callback of an earlier start never re-enters the timer, even when the host's own cancellation raised. A host that called back from inside its constructor would find the timer not yet running, with the handle slot still `false`, and be ignored.

**The fast start (revision 14).** `After` and `Every` test the receiver, the
closed state, the callback, the delay's type, the secret probe and the delay's
range in one condition. When it holds, `launchTimer` builds the record, calls
the host constructor and records the timer in one frame; otherwise
`startTimerInScope` runs every validator in order and raises the exact message
at the caller's line. `Timer:Cancel` holds the cancel body inline, and
`fireStarted` merges the stale check with the delivery. Host callbacks
created from revision 14 read `state.dispatch.fireStarted` (or `fireResumed`)
directly; those of revisions 10 to 13 still go through their own
`dispatchFire`, which checks the table first.

**Order of a start (revision 11).** `armTimer` builds the closure, calls the host constructor directly and only then writes the handle slot, the state `"running"`, the scope's active set and the deadline slot. A constructor that raises therefore leaves the timer exactly as it was, with no `pcall` and no rollback; revision 10 and older marked the timer running first and undid it under `pcall`. The handle is trusted (API.md, "Trusting the host handle"): a start refuses only `nil` or `false`, which the closure's captured `nil` could not be told from, and `cancelTimer` calls `native:Cancel()` directly after the logical cancellation.

This relies on one property of `C_Timer`: every `NewTimer` and `NewTicker` call returns its own handle. The closure keeps its handle alive, so the host cannot hand the same object to a later start while the earlier callback can still run.

Revision 9 and older bound a start to a per-timer `_generation` counter and called `dispatch.fire(timer, generation)`. After an in-place upgrade those callbacks keep running: `dispatch.fire` is `fireLegacyTimer`, which fires only while the timer is running with that generation, and every start moves a timer's `_generation` on when it has one. A legacy callback therefore goes stale at the same moments as before.

The per-start closure has two upvalues of its own (the timer and the handle) and allocates about 140 bytes. Binding it to the handle rather than to a counter is what lets a one-shot timer fit in eight fields.

## Dispatch

Callbacks TimerKit hands to the host and to other Kits call through `_state.dispatch` when they run, so a newer revision replaces the code they run without touching them:

| Entry | Called by |
|---|---|
| `fireStarted(timer, handle)` | The host callbacks revision 10 and later create. |
| `fire(timer, generation)` | The host callbacks revision 9 and older created. |
| `fireResumed(timer, handle)` | The one-shot callbacks `Resume` creates (revision 12). |
| `closeScope(scope)` | Shutdown wrappers of revision 5 and older that could not be disconnected. |
| `closeOnShutdown(addonName)` | LifecycleKit `OnShutdown` subscriptions (logout route 2). |
| `closeOnLogout()` | The EventKit `PLAYER_LOGOUT` connection (logout route 3). |

A newer revision must keep publishing every entry an older revision's callbacks can still call.

## Upgrades

A newer revision keeps `_state`, the prototypes and the metatables, rewrites the prototypes' methods and the dispatch entries, and leaves every timer and scope object in place. Up to revision 13 timers kept the field layout their revision built; revision 14 converts them to the array layout in place ("Timer records").

Revision 11 changes no state and no layout. A timer revision 10 started keeps its handle and its callback closure, which calls `dispatch.fireStarted` and so runs the new code; cancelling it after the upgrade calls its handle's `Cancel` directly.

Revision 12 changes no state and no layout either: it adds the state `"paused"`, which no older revision can have left, and the dispatch entry `fireResumed`. A timer an older revision started can be paused after the upgrade; its old callback is unbound by the pause like any other.

Revision 13 changes no state and no layout either: a refusal names a table option field by its type instead of passing it to `tostring`.

Revision 14 changes the timer layout (see "Timer records") without a schema
change: it adds `timerRecordMetatable` to the state, converts the reachable
running and paused timers at load and every other older timer when it is
first met, and keeps publishing `fire` and `fireResumed` with the same
arguments. Scopes keep their layout; `Reopen` is new. The secret-value probe
is read once at load, with a per-call fallback to the global on a host that
had none then.

## Pausing (revision 12)

`pauseTimer` unbinds the handle slot before calling the handle's `Cancel`, as a cancellation does, sets the state `"paused"` and keeps the remainder in the deadline slot; it moves `_generation` on for a timer revision 9 or older built, so a callback of that era goes stale too. The timer stays in its scope's active set. `armRemainder` builds a closure that resolves `dispatch.fireResumed` at call time, calls `C_Timer.NewTimer(remaining, closure)` first and only then marks the timer running, so a raising constructor leaves it paused. `fireResumedTimer` applies the same stale check as `fireTimer`; for a repeating timer it cancels the timer logically, calls `armTimer` for a ticker of the interval and then runs the callback.
