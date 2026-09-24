# ReadinessKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`ReadinessKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `dispatch` | `pollTick`, `reprobe` and `settleGroup`; every closure ReadinessKit hands out calls through it. |
| `runtimeRevision` | The revision that last committed its functions. |
| `gatePrototype`, `waiterPrototype` | The method tables gates and waiters index. |
| `gateMetatable`, `waiterMetatable` | The metatables whose `__index` is the matching prototype. |
| `gates` | Gate name to open gate. |
| `timerScope` | The Kit-owned TimerKit scope every poll timer lives in, or `false` before the first poll. |
| `pollCallback` | The one TimerKit callback every poll timer shares. |
| `unbounded` | The `ReadinessKit.UNBOUNDED` sentinel, kept here so every copy and revision publishes the same table. A revision-1 state, which has none, is given one during the upgrade. |

The prototypes live in state rather than on the facade because the facade's `Gate` field is the constructor the package plan names (`ReadinessKit:Gate(name, ...)`), so it cannot also be the gate method table.

## Gate layout

A gate is one table with a fixed set of private fields, all created by `newGate`, so no later write adds a key to it:

| Field | Meaning |
|---|---|
| `_schema` | The gate layout version, `1`. |
| `_name`, `_probe` | The name it is registered under and the consumer's probe. |
| `_intervalSeconds`, `_timeoutSeconds`, `_maxWaiters` | Options with defaults applied; `_timeoutSeconds` is `false` for none. |
| `_status` | `"pending"`, `"ready"`, `"timedOut"` or `"closed"`. |
| `_waiters`, `_waiterCount` | The live waiter array, in queue order, and its length. |
| `_spareWaiters` | The second waiter array, or `false` while a flush holds it. |
| `_timer` | The gate's TimerKit timer, or `false` before the first poll and after `Close`. |
| `_waitStartedAt`, `_polls` | Start of the current polling round (`false` without a clock) and the polls in it. |
| `_negativeAt` | Clock reading of the last negative answer, or `false`. |
| `_probeErrorCount`, `_probeErrorReported` | Probe failures since the gate was defined, and whether this polling round has reported one. |
| `_eventScope`, `_reprobeEvents`, `_reprobeCallback` | Re-probe state, `false` until the first `ReprobeOn`. |

## Polling

Each gate owns at most one TimerKit timer for its whole life, created with `scope:New({ repeating = true })` on its first polling round and started and cancelled after that, never replaced. (The one exception is a scope somebody closed from outside through `timer:GetScope()`: `getTimerScope` replaces the scope and `startTimer` the timer.) The timer carries its gate as TimerKit user data, and its callback is `state.pollCallback`, so arming a poll allocates no closure of ReadinessKit's own.

A tick (`pollTick`) first checks that the timer's user data is a gate that still owns this timer and is pending; anything else is a stale tick and cancels the timer. It then counts the poll, runs the probe, and either makes the gate ready or checks the timeout. Nothing on that path allocates while the probe answers "not yet": `pcall` of a function, one clock read and a few field writes to fields that already exist. The allocation spec measures it.

The status transitions own the timer: `becomeReady` and `timeOut` cancel it, `startPolling` starts it. A host failure while cancelling is reported, not raised, because the status has already changed and the waiters still have to be called.

## Timeout and negative cache

`startPolling` stamps `_waitStartedAt` and zeroes `_polls`. `hasTimedOut` compares the clock against the stamp; without a clock it compares `_polls × _intervalSeconds` with the timeout, with a tolerance of `1e-9` so that a timeout that is an exact multiple of the interval is not missed by rounding.

`runProbe` stamps `_negativeAt` on every negative answer and on a probe that raised. `isNegativeCached` is true while the clock is less than `_intervalSeconds` past that stamp; without a clock it is always false. Only `Probe()` consults the cache: a tick is already an interval apart, and a re-probe event is fresh information.

## Probe failures and self-closing probes

`recordProbeError` counts every failure and hands only the first of a round to `reportError`. `startPolling` clears `_probeErrorReported` when it leaves the ready or timed-out state, which is what makes a round; the first round of a new gate inherits the flag from the defining probe, so a gate whose probe raises from the start reports once.

The probe is consumer code and may close its own gate. Every caller of `runProbe` (`packageGate`, `pollTick`, `gateProbe`, `reprobe`) checks `closedDuringProbe` before acting on the answer, because `becomeReady`, `timeOut` and `startPolling` all overwrite `_status` and would otherwise revive a closed gate that `Get` no longer returns.

## The waiter arrays

A gate has two arrays. `_waiters` holds queued waiters in order; `_spareWaiters` is empty and waiting.

`flushWaiters` swaps them before calling anything: the live array becomes the batch, the spare becomes the live array, and `_spareWaiters` is set to `false` while the batch is being delivered. Each slot of the batch is cleared as it is delivered, so after the batch the array is empty and becomes the spare again. A callback that queues a new waiter therefore queues it in the other array, for the next outcome.

A flush nested inside another flush of the same gate (a callback that invalidates the gate and then makes it ready again through `Probe`) finds `_spareWaiters == false` and allocates a fresh array; that is the one case in which the arrays are not reused, and the extra array is dropped afterwards.

`Cancel` marks the waiter cancelled and removes it from the live array, shifting the rest down to keep the order (at most `maxWaiters` moves). A waiter that is in a batch being delivered is not in the live array; the flush skips it because of its status.

`maxWaiters` bounds the live array only. The batch being delivered is the previous live array, so at most two times `maxWaiters` waiters are referenced at once.

## Protected calls

Queued callbacks and probes run under `pcall` without a closure per call: `callQueued` stages the callback and its two arguments in upvalues and calls the reusable `invokeStaged`, which reads and clears the stage before calling, so a callback that makes another gate ready does not see stale arguments. Failures go to `reportError`, which calls `geterrorhandler()` or falls back to `print`, exactly as EventKit reports listener failures.

Callbacks run at once by `Await` or `WhenAll` are not protected: they run on the caller's stack, and the caller is the one who should see the error.

## `WhenAll` groups

A group is a waiter with `_gate = false`, a `_children` array of per-gate waiters and a `_remaining` count. One closure per group, built by `newGroupCallback`, is queued on every gate and calls `dispatch.settleGroup`. Settling on a `true` decrements `_remaining` and calls the group's callback at zero; settling on `false` calls it at once and cancels every child. `Cancel` on the group cancels its children.

## Closures and upgrades

ReadinessKit hands out three kinds of closure: `state.pollCallback` (one for the whole package), one re-probe callback per gate that re-probes, and one callback per `WhenAll` group. Each captures only the object it serves and the shared `dispatch` table, and calls `dispatch.pollTick`, `dispatch.reprobe` or `dispatch.settleGroup` at call time. A newer revision rewrites those fields, so closures an older revision created run the newer behaviour.

Gates and waiters use the metatables stored in state. An upgrade keeps both metatables and rewrites the prototype methods in place, so existing gates and waiters keep their state and gain the new methods. Each gate carries `_schema`, so a revision that changes the layout can upgrade old gates lazily.

A second upgrade spec loads the source as the previous revision (the current one minus one), queues a waiter on a polling gate and checks that the current revision keeps the facade, the state table, the gate and the waiter. The first upgrade spec loads the source as a revision-1 copy (with `IMPLEMENTATION_REVISION` patched to 1 and the `unbounded` sentinel removed from its state, as revision 1 had none), builds a polling gate, a queued waiter, a re-probe subscription and a `WhenAll` group on it, then loads the current revision over it and checks that all four keep working and that the sentinel is published.

## Error levels

`ReprobeOn` calls `scope:Connect` through `pcall`: EventKit raises a refused host registration at its own caller, which is a ReadinessKit line. The failure is re-raised at level 2 under `ReadinessKit.Gate:ReprobeOn`, with EventKit's `file:line: ` prefix stripped and its reason kept, and the event is not recorded, so a later `ReprobeOn` can try again.

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass `3` to a validator (the validator, the method, the caller) and raise their own state errors at `2`.
