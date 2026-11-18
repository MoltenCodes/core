# TimerKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API; the contract is [`API.md`](API.md).

## Package state

`TimerKit._state` is shared by every embedded copy (schema 1). It has no
metatable, so the core reads and writes it, its sub-tables, and every scope
and timer by plain indexing; only the facade and the two prototypes are
written with `rawset`.

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `runtimeRevision` | The revision that last committed its functions. |
| `addonScopes` | Addon name to its canonical scope. |
| `defaultScope` | The manual scope behind `TimerKit:After`, `Every` and `New`; replaced once closed. |
| `dispatch` | The functions host callbacks and other Kits' callbacks resolve when they run (below). |
| `nextTimerId` | The last timer identifier handed out. |
| `timerRecordMetatable` | The metatable of every timer; `__index` is the shared `Timer` prototype. |
| `scopeMetatable` | The metatable every scope carries; `__index` is the shared `Scope` prototype. |
| `logoutConnection`, `logoutEventScope` | The package-level EventKit `PLAYER_LOGOUT` connection and its scope, or `false` (API.md, "At logout"). |
| `parts` | Part name to `{ revision = n }` for each installed part. |
| `helpers` | The core functions a part calls (below), refreshed by every core revision. |
| `partInterface` | The number of the part interface the core offers, `1`. A part refuses to load against a lower one. |

State revision 14 left also holds `timerMetatable`, the mark of named-field
timers revisions 13 and older built; revision 15 never reads it.

## Timer records

A timer is a table only TimerKit writes. It keeps its fields in nine array
slots:

| Slot | Meaning |
|---|---|
| `[1]` id | Session-wide creation order. `CancelAll`, `Close` and `CloseAddonScopes` sort by it. |
| `[2]` scope | The owning scope. |
| `[3]` callback | The function the timer calls: the owner's callback, or the method-name wrapper below. |
| `[4]` delay | The delay or interval in seconds. |
| `[5]` state | `"idle"`, `"running"`, `"paused"`, `"completed"` or `"cancelled"`. |
| `[6]` native | The host handle of the current start while running, `false` otherwise. |
| `[7]` deadline | The `GetTimePreciseSec()` instant of the next fire while running; the seconds left while paused; `false` otherwise. |
| `[8]` repeating | `true` on a repeating timer, `nil` on a one-shot. |
| `[9]` userData | The value `SetUserData` attached. |

**Shape.** Every timer is built by one constructor that names all nine slots,
the last two possibly `nil`. Lua 5.1 sizes the array part from the
constructor's item count, `nil` items included, so the record is 200 bytes
of table (208 measured with allocator overhead) for a one-shot and a
repeating timer alike, and `SetUserData` never grows it. Eight named fields
would take 384 bytes for a one-shot timer, and nine, which Lua rounds up to
sixteen hash slots, 704 bytes for a repeating one.

**Access.** The per-timer paths read and write the slots by plain indexing;
the source names each slot in a trailing comment (`timer[5] --[[state]]`).
Indexing an array slot is one VM instruction with a constant key, cheaper than
a named field and much cheaper than `rawget`. The timer metatable has no
`__newindex`, and the slots a timer may leave empty (`[8]`, `[9]`) fall
through `__index` to the `Timer` prototype, which holds only the capitalised
public methods, so they read `nil`. The Pausing part reads and writes the
same slots.

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
timer's callback, so nothing else in TimerKit knows the form exists.

## Scope records

| Field | Meaning |
|---|---|
| `_addonName` | The addon name of a canonical scope, `nil` for a manual one. |
| `_active` | The set of running and paused timers. |
| `_activeCount` | Its size. |
| `_closed` | Terminal once `true`. |
| `_logoutRoute` | Addon scopes only: who closes the scope at logout (API.md, "At logout"). |

A timer is in `_active` exactly while its state is `"running"` or `"paused"`.

## Stale host callbacks

Every start creates one host handle and one callback closure, which captures the timer and, once the host constructor has returned, that handle. The closure calls `dispatch.fireStarted(timer, handle)`, which fires the timer only while it is running and its handle slot `[6]` is still that handle (`rawequal`, so no host `__eq` runs). Cancellation and a pause set the handle slot to `false` before they ask the host to cancel, a delivered one-shot does so before it calls the owner, and a restart binds the new handle; so a host callback of an earlier start never re-enters the timer, even when the host's own cancellation raised. A host that called back from inside its constructor would find the timer not yet running, with the handle slot still `false`, and be ignored.

**The fast start.** `After` and `Every` test the receiver, the closed state,
the callback, the delay's type, the secret probe (`isSecret`) and the delay's
range in one condition. When it holds, `launchTimer` builds the record, calls
the host constructor and records the timer in one frame; otherwise
`startTimerInScope` runs every validator in order and raises the exact message
at the caller's line. `Timer:Cancel` holds the cancel body inline, and
`fireStarted` merges the stale check with the delivery.

**Order of a start.** `armTimer` builds the closure, calls the host constructor directly and only then writes the handle slot, the state `"running"`, the scope's active set and the deadline slot. A constructor that raises therefore leaves the timer exactly as it was, with no `pcall` and no rollback. The handle is trusted (API.md, "Trusting the host handle"): a start refuses only `nil` or `false`, which the closure's captured `nil` could not be told from, and `cancelTimer` calls `native:Cancel()` directly after the logical cancellation.

This relies on one property of `C_Timer`: every `NewTimer` and `NewTicker` call returns its own handle. The closure keeps its handle alive, so the host cannot hand the same object to a later start while the earlier callback can still run.

The per-start closure has two upvalues of its own (the timer and the handle) and allocates about 140 bytes.

## Dispatch

Callbacks TimerKit hands to the host and to other Kits call through `_state.dispatch` when they run, so a newer revision replaces the code they run without touching them:

| Entry | Filled by | Called by |
|---|---|---|
| `fireStarted(timer, handle)` | the core | The host callbacks every start creates. |
| `closeOnLogout()` | the core | The EventKit `PLAYER_LOGOUT` connection (logout route 3). |
| `fireResumed(timer, handle)` | the Pausing part | The one-shot callbacks `Resume` creates. |
| `pause(timer)` | the Pausing part | `Timer:Pause`, after its receiver check. |

The core never writes the Pausing part's entries. Without the part no callback
that needs them exists, with one exception the upgrade from revision 14
leaves: a resume one-shot revision 14 armed. Revision 14's own `fireResumed`
then stays in the table and serves it; it writes the same slots and arms the
next tick of a repeating timer through `fireStarted`, so the timer continues
under the current code. Loading the part replaces the entry.

A newer revision must keep publishing every entry an older revision's
callbacks can still call.

## Parts

The core keeps, for its parts, `state.parts`, `state.helpers` and
`state.partInterface` (above). `PART_LAYOUT` in the core names each part, its
file and the `Timer` members it provides; at commit, `installPartStubs` puts a
stub in place of each member of a part that is not installed (one closure per
member, whose message is built only when it raises). A member of an installed
part is left alone, so a core loaded after the part keeps the part's code.

`state.helpers` holds `validateTimer`, `armTimer`, `detachActive`,
`fireTimer`, `deadlineAfter`, `now` and `newOneShotHandle` (`C_Timer.NewTimer`).
The part keeps the table, not the functions, so it calls the newest core's
code.

**Pausing.** `pauseTimer` unbinds the handle slot before calling the handle's
`Cancel`, as a cancellation does, sets the state `"paused"` and keeps the
remainder in the deadline slot. The timer stays in its scope's active set.
`armRemainder` builds a closure that resolves `dispatch.fireResumed` at call
time, calls `newOneShotHandle(remaining, closure)` first and only then marks
the timer running, so a raising constructor leaves it paused.
`fireResumedTimer` hands a one-shot to the core's `fireTimer`, which applies
the stale check and completes it; for a repeating timer it applies the same
stale check, cancels the timer logically, calls `armTimer` for a ticker of
the interval and then runs the callback.

## Upgrades

A newer revision keeps `_state`, the prototypes and the metatables, rewrites the prototypes' methods and the dispatch entries, and leaves every timer and scope object in place.

**The upgrade floor.** Revision 15 upgrades in place from revision 14 only
(`OLDEST_UPGRADABLE_REVISION`); no earlier revision was ever published. Over
an older copy it raises at load. From revision 14 it adds `parts`, `helpers`
and `partInterface` to the state, installs the part stubs, and in one
main-chunk pass removes the dispatch entries no remaining caller can reach
(`fire`, `closeScope`, `closeOnShutdown`), drops the `_logoutSubscription`
field of every addon scope, and gives a scope revision 14 routed through
`OnShutdown` (logout route 2, a LifecycleKit before revision 13) a route
again after disconnecting that subscription. Timers keep their layout:
revision 14 already stored them in the nine slots.
