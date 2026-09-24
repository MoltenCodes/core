# ReadinessKit API

ReadinessKit API generation **1** provides named gates for host data that arrives after load: a gate probes a fact, polls it while it is not yet true, times out, remembers negative answers for one interval, and calls its waiters once with the outcome.

Implementation revision: **3**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
TimerKit.lua
ReadinessKit.lua
```

These three files are the minimum footprint. ReadinessKit depends directly on Registry API 2 and TimerKit API 1, and TimerKit requires only Registry. An addon that uses `gate:ReprobeOn` also embeds SignalKit and EventKit, anywhere after Registry and before the first `ReprobeOn` call. Portable WoW code resolves the package through Registry:

```lua
local ReadinessKit = MoltenCodes.Registries[2]:Get("readinessKit", 1)
```

ReadinessKit does not rely on `require()` at runtime. Loading it without Registry raises `MoltenCodes ReadinessKit requires Registry API 2 to be loaded first`; without TimerKit, `MoltenCodes ReadinessKit requires TimerKit API 1 to be loaded first`.

### Optional host facilities

| Facility | Used by | Without it |
|---|---|---|
| `GetTimePreciseSec` | negative caching, the timeout window | ReadinessKit loads normally. `Probe()` always runs the probe (no negative cache), and a timeout is counted in polls: the gate times out on the poll at which polls × `intervalSeconds` reaches `timeoutSeconds`. |
| EventKit API 1 | `gate:ReprobeOn` | `ReprobeOn` raises at the caller: `ReadinessKit.Gate:ReprobeOn requires EventKit API 1, which is not loaded (absent)`. Everything else works. |

EventKit is looked up with `Registry:Find("eventKit", 1)` when `ReprobeOn` is called, not at load. The package manifest lists it under `optionalDependencies`, which load order and bundles ignore. The lookup fails when the addon does not embed EventKit, or when the EventKit registered is retired or of another generation; the reason `Registry:Find` gives (`absent`, `generation_mismatch` or `retired`) is part of the message.

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `Gate(name, probe, options?)` | Return the gate called `name`, defining it when there is none. |
| `Get(name)` | Return the open gate called `name`, or `nil`. |
| `WhenAll(gates, callback)` | Wait for every gate in the list; returns a waiter. |
| `UNBOUNDED` | Sentinel `options.maxWaiters` takes to lift one gate's waiter limit. See [Limits](#limits). |

Gate handles:

| Method | Purpose |
|---|---|
| `IsReady()` | Whether the gate is ready. A field read. |
| `Await(callback)` | Call `callback` with the gate's outcome; returns a waiter, or `nil, "full"`. |
| `Probe()` | Run the probe now (subject to the negative cache); return whether the gate is ready. |
| `Invalidate()` | Declare the data unusable again; polling resumes. Returns whether it was ready. |
| `ReprobeOn(eventName)` | Re-run the probe whenever the host event fires; needs EventKit. |
| `Close()` | Stop polling, release subscriptions, free the name, tell waiters `"closed"`. |
| `IsClosed()` | Whether the gate is closed. |
| `GetProbeErrorCount()` | How many times the probe has failed (raised, or answered a secret value) since the gate was defined. |

Waiter handles, returned by `Await` and `WhenAll`:

| Method | Purpose |
|---|---|
| `Cancel()` | Stop waiting; `false` when the callback already ran or it was already cancelled. |
| `IsPending()` | Whether the callback is still due. |

Callbacks receive `(ready, reason)`: `true` when the gate became ready, otherwise `false` and a reason.

| Reason | Meaning |
|---|---|
| `"timeout"` | The gate polled for `timeoutSeconds` without the probe answering. |
| `"closed"` | The gate was closed while the callback was queued. |

`"full"` is not a callback reason: it is the second value `Await` and `WhenAll` return when they refuse to queue.

## `ReadinessKit:Gate(name, probe, options?)`

```lua
local talents = ReadinessKit:Gate("MyAddon.talents", function()
    return C_ClassTalents.GetActiveConfigID() ~= nil
end, { intervalSeconds = 1, timeoutSeconds = 20 })
```

`name` is a non-empty string, `probe` a function whose truthy result means "the data is usable". A probe answers a plain value; a secret answer is a probe failure (see [Probes that answer a secret value](#probes-that-answer-a-secret-value)). Options:

| Option | Default | Meaning |
|---|---|---|
| `intervalSeconds` | `0.5` | Seconds between polls, and how long a negative answer is remembered. A finite number greater than zero. |
| `timeoutSeconds` | `30` | Seconds of polling before waiters are told `"timeout"`, or `false` for no timeout. |
| `maxWaiters` | `64` | The most callbacks queued at once. A positive integer, or `ReadinessKit.UNBOUNDED` for no limit. |

Unknown option fields are refused; with several, the message names the alphabetically first.

A new gate is registered under `name` and runs `probe` once, at once. When that answers, the gate is ready and no timer is created. Otherwise the gate starts polling.

**One gate per name.** Gates live in ReadinessKit's shared state, so every addon in the session that asks for the same name gets the same gate. When a gate with `name` already exists, `Gate` returns it and **ignores `probe` and `options`**: the first definition wins. The arguments are still validated, so a malformed repeated call raises exactly as a first one would. Prefix names with your addon's name unless you mean to share the gate.

A probe may call `ReadinessKit:Get(name)` for its own gate: the gate is registered before the first probe runs.

When the host refuses to create the poll timer, `Gate` raises the host's error unchanged and leaves no gate registered.

## Gate states

```text
             probe answers                      Invalidate
  pending ──────────────────────▶ ready ──────────────────────▶ pending
     │  ▲
     │  │ Probe / Invalidate / re-probe event
     ▼  │
  timed out                     Close from any state ──▶ closed
```

- **pending** — polling. One repeating TimerKit timer runs every `intervalSeconds`; each tick runs the probe.
- **ready** — no timer runs, and the probe is never run again: readiness is sticky until `Invalidate()`.
- **timed out** — the round lasted `timeoutSeconds`. Waiters were told `"timeout"` and no timer runs.
- **closed** — terminal.

The timeout is checked after each negative poll, measured from the start of the round on `GetTimePreciseSec`. A host timer that fires late (a loading screen) therefore times out on its first tick after the deadline, but only if that tick's probe also fails.

## `gate:Await(callback)`

- On a ready gate, `callback(true)` runs at once, before `Await` returns.
- On a timed-out gate, `callback(false, "timeout")` runs at once. Call `Probe()` or `Invalidate()` first to start a new round.
- Otherwise the callback is queued, after every callback already queued, and runs once: with `true` when the gate becomes ready, `false, "timeout"` when it times out, or `false, "closed"` when it is closed.
- When `maxWaiters` callbacks are already queued, nothing is queued and `Await` returns `nil, "full"`.

`Await` returns a waiter in every case but the refusal; for a callback that already ran, the waiter is not pending and `Cancel()` returns `false`.

**Callback errors.** A callback run at once runs on your stack, so its error propagates out of `Await` unchanged. A queued callback runs from a TimerKit tick, an EventKit dispatch or somebody else's `Probe`, none of which is the code that queued it, so its error is handed to the host error handler (`geterrorhandler()`, or `print` without one) and the remaining callbacks of the batch still run.

A callback that queues a new waiter on the same gate (after invalidating it, say) queues it for the next outcome, not the one being delivered. A callback may cancel a waiter later in the same batch, and may close the gate; the rest of the batch still receives the outcome being delivered.

## `gate:Probe()`

Returns `true` at once for a ready gate, without running the probe. Otherwise:

1. When the last negative answer is younger than `intervalSeconds`, returns `false` without running the probe (the negative cache).
2. Otherwise runs the probe. When it answers, the gate becomes ready, polling stops and every queued waiter is called before `Probe` returns `true`.
3. On a timed-out gate that is still not ready, starts a new polling round with a fresh timeout, whether or not the probe ran.

Every negative answer, from a poll, `Probe`, a re-probe event or the first probe, restarts the negative-cache window.

## `gate:Invalidate()`

Declares that the data the gate guards is no longer usable. It does not run the probe: invalidating usually happens on the event that says the data is being rebuilt.

| State | Effect |
|---|---|
| ready | Back to pending; a new polling round starts. Returns `true`. |
| timed out | A new polling round starts. Returns `false`. |
| pending | The negative cache is dropped; the round and its timeout window continue. Returns `false`. |

## `gate:ReprobeOn(eventName)`

Re-runs the probe whenever the host event `eventName` fires, through a private EventKit scope the gate owns. The event is fresh information, so the negative cache is ignored. A ready gate ignores the event, because readiness only ends with `Invalidate()`; to drop readiness on an event, connect it yourself and call `Invalidate()`. A timed-out gate that is still not ready starts a new polling round.

Returns `true` when it connected, `false` when the gate already re-probes on that event. `eventName` must be a non-empty string. A closed gate refuses: `ReadinessKit.Gate:ReprobeOn cannot subscribe a closed gate`.

When the host refuses the registration, the failure is raised at the caller's line with the host reason kept: `ReadinessKit.Gate:ReprobeOn could not connect SPELLS_CHANGED: EventKit.Scope:Connect could not register event SPELLS_CHANGED`. The event is not recorded, so a later `ReprobeOn` for it may try again. An embedded Registry older than API 2 revision 7 has no `Find`, and `ReprobeOn` then raises `ReadinessKit.Gate:ReprobeOn requires Registry:Find (Registry API 2 revision 7 or newer)`; an EventKit facade without `CreateScope` raises `ReadinessKit.Gate:ReprobeOn requires a valid EventKit API 1 facade`.

A gate closed from inside a listener of the same event is not probed by a delivery EventKit still owes it.

A refusal whose reason is a secret value is re-raised with the fixed text `(secret value)` in place of the reason, because stripping the position from a secret would test it as a boolean.

## `gate:Close()`

Marks the gate closed, cancels its poll timer, removes it from the shared name table (a later `Gate` with that name defines a new gate), calls every queued waiter with `false, "closed"`, and closes its EventKit scope. Returns `false` when it was already closed.

After `Close`, `IsReady()` returns `false`, and `Await`, `Probe`, `Invalidate` and `ReprobeOn` raise at the caller. A failure EventKit re-raises while releasing the subscriptions is raised after the gate is fully closed and its waiters were called.

## `ReadinessKit:WhenAll(gates, callback)`

```lua
ReadinessKit:WhenAll({ spellbook, items, talents }, function(ready, reason)
    if ready then
        Initialise()
    end
end)
```

Queues one waiter on each gate and calls `callback` once:

- with `true` when every gate is ready — at once when they already are, and at once for an empty list;
- with `false, reason` for the first gate that times out or is closed; the waiters on the other gates are cancelled.

A gate listed twice counts twice. The group is bounded by the gates' own caps: when any gate refuses with `"full"`, the waiters already queued are cancelled and `WhenAll` returns `nil, "full"`. The returned waiter's `Cancel()` cancels every per-gate waiter. `gates` must be an array of open gates; a closed gate raises at the caller. Callback errors follow `Await`: raised at the caller when the outcome is already known, reported to the host error handler otherwise.

## Probes that raise

A probe that raises counts as "not ready": the gate keeps polling, the failure restarts the negative-cache window, and `Probe()` returns `false`. The error never reaches `Gate`, `Probe` or a TimerKit tick.

Only the **first** failure of each polling round is handed to the host error handler (`geterrorhandler()`, or `print` without one); every failure is counted, and `gate:GetProbeErrorCount()` returns the total since the gate was defined. A new round (after `Invalidate`, or when `Probe` or a re-probe event restarts a timed-out gate) reports its first failure again. So a probe that always raises is reported once, not twice a second, even with `timeoutSeconds = false`.

## Probes that answer a secret value

On Retail 12.0.0 and later a host API may return a secret value, and the client raises on any boolean test of one: measured on Retail 12.1.0 b69933, `if result then` with `result = secretwrap(true)` raised `attempt to perform boolean test on local 'result' (a secret boolean value, while execution tainted by 'MoltenCodes')`. ReadinessKit therefore never tests a secret answer for truth. It checks the answer with `issecretvalue` (read once at load) before anything else touches it, and a secret answer, `true` or `false` underneath, is a **probe failure**:

- it counts as "not ready": the gate stays pending and keeps polling, the failure restarts the negative-cache window, and `Probe()` returns `false`;
- nothing raises out of `Gate`, `Probe`, a TimerKit tick or a re-probe event;
- it is counted by `gate:GetProbeErrorCount()` and reported under the same once-per-round rule as a probe that raises, with the fixed message `ReadinessKit gate "<name>" probe answered a secret value; a probe must answer a plain true or false`.

A probe over a host API that may answer a secret checks it itself (`issecretvalue`) and answers a plain `true` or `false`. On a host without `issecretvalue` nothing is secret and the check costs one upvalue test.

## A probe that closes its own gate

A probe, or something it calls, may close its own gate. The gate stays closed whatever the probe answers: it does not become ready, time out or poll again, and its name stays free. `Gate` returns the closed gate, and `Probe` returns `false`.

## Limits

ReadinessKit bounds one retained collection, and opens it on purpose (design
constitution, principle 4a):

| Limit | Where | Default | `UNBOUNDED` |
|---|---|---|---|
| `maxWaiters` | `Gate` option, per gate | 64 | accepted: the queue holds the consumer's own callbacks |

```lua
local gate = ReadinessKit:Gate("bags", probe, { maxWaiters = ReadinessKit.UNBOUNDED })
```

`ReadinessKit.UNBOUNDED` is one sentinel table kept in package state, the same
across embedded copies and upgrades. There is no package-wide `SetLimits`:
the only limit belongs to the gate that sets it.

`intervalSeconds` and `timeoutSeconds` are not caps. They are timing: how
often a pending gate polls and when its waiters are told `"timeout"`. They
bound nothing ReadinessKit retains. The gate table is keyed by name, one gate
per name for the session, so it grows only with the names the consumer defines.

## Error behaviour

Argument failures report the line that called the public method, never a line inside ReadinessKit. Messages name the method (`ReadinessKit:Gate`, `ReadinessKit.Gate:Await`, `ReadinessKit.Waiter:Cancel`, `ReadinessKit:WhenAll`). Calling a method on something that is not a gate raises `ReadinessKit.Gate:IsReady must be called on a ReadinessKit gate`.

A secret value (Retail 12.0.0 and later) cannot be compared or tested as a boolean, so it is refused before any check touches it, at the caller's line:

| Argument | Message |
|---|---|
| `name` of `Gate` | `ReadinessKit:Gate name must not be a secret value` |
| `name` of `Get` | `ReadinessKit:Get name must not be a secret value` |
| `eventName` of `ReprobeOn` | `ReadinessKit.Gate:ReprobeOn eventName must not be a secret value` |
| an option of `Gate` | `ReadinessKit:Gate intervalSeconds must not be a secret value` (likewise `timeoutSeconds`, `maxWaiters`) |

An absent option is recognised by its type, never by comparing it with `nil`. On a host without `issecretvalue` nothing is secret and these checks cost one upvalue test.

## Performance

| Operation | Cost |
|---|---|
| `IsReady` | A field read; no allocation. |
| Poll tick, gate not ready | One probe call and one clock read; no allocation. |
| `Probe`, negatively cached | One clock read; no allocation. |
| `Await`, queued | One waiter handle. The waiter array is reused. |
| `Gate` | One gate table and two waiter arrays; the poll timer is created on the gate's first polling round and reused for every later round. |
| `WhenAll` | One group handle, one child array and one callback closure. |

No timer exists for a gate that is ready, timed out or closed. Every poll timer lives in one TimerKit scope ReadinessKit owns.

## Embedded copies and upgrades

Several addons may embed ReadinessKit; Registry selects the newest compatible revision and every copy shares one facade and one set of gates. An upgrade happens in place: gates keep their state, queued waiters and poll timers, and the poll callback, re-probe callbacks and `WhenAll` callbacks an older copy created run the newer implementation.

Nothing survives `/reload`: gates live in memory only.
