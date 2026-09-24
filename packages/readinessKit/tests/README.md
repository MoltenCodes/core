# ReadinessKit Tests

The ReadinessKit suite covers:

- gates that are ready at once (no timer is ever created), ready after N polls on one repeating TimerKit timer, `intervalSeconds`, truthy probe results, and a repeated definition that returns the existing gate and ignores the new probe and options;
- timeouts: waiters told `false, "timeout"` once, polling stopped, `timeoutSeconds = false`, the wall-clock window, `Await` on a timed-out gate, and new rounds started by `Invalidate`, `Probe` and a re-probe event;
- negative caching: no probe within the interval of a negative answer, the window restarted by a poll, dropped by `Invalidate`, and never a probe on a ready gate;
- waiters: FIFO order, the `maxWaiters` cap and `"full"`, `Cancel` (also from an earlier callback of the same batch), queued callback errors routed to the host error handler while the batch continues, immediate callback errors raised at the caller, waiters queued during a flush, and the two waiter arrays reused across rounds;
- probes that raise: treated as not ready, polling continues, the first failure of each round reported and every failure counted, the `print` fallback without a host handler;
- a probe that closes its own gate, on every path that runs a probe (definition, poll, timing-out poll, `Probe`, re-probe event): the gate stays closed;
- `ReprobeOn` through the real EventKit, connections released by `Close`, a gate closed during the dispatch in flight, a refused host registration re-raised at the caller and connectable again later, and the errors when `Registry:Find` refuses EventKit, when the embedded Registry has no `Find`, and when the EventKit facade has no `CreateScope`;
- `WhenAll`: success, already-ready gates, the empty list, the first timeout, a gate already timed out, a gate closed while waiting, the gates' caps, and `Cancel`;
- `Close`: waiters told `"closed"`, the name freed, stale ticks ignored, closing from inside a callback;
- a host without `GetTimePreciseSec`: timeouts counted in polls, negative cache disabled;
- allocation guards (`collectgarbage("count")` with the collector stopped) on the poll tick while not ready, `IsReady` and a cached `Probe`;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry or TimerKit, an in-place upgrade from revision 1 that keeps gates, waiters, the poll timer, a re-probe subscription and a `WhenAll` group, and one from the previous revision that keeps the facade, the state, a gate and its waiter;
- `error` levels: every argument failure reports the caller's own line;
- secret values on the `mainline` host: secret names, event names and option values refused at the caller's line before any comparison, ordinary arguments still accepted; a probe answering a secret on every path that runs a probe (definition, poll, `Probe`, re-probe event) counted and reported once per round as a probe failure while the gate stays pending, and a gate made by the previous revision that answers a secret after an in-place upgrade;
- manifest/runtime API and revision consistency.

The required closure is Registry and TimerKit; EventKit is listed under `optionalDependencies`, so the runner puts it and SignalKit on `LUA_PATH` as well. The module chain in `support/ReadinessKitTestEnv.lua` loads Registry, SignalKit, EventKit, TimerKit and ReadinessKit, as an addon that uses `ReprobeOn` would; `NewPackageWithoutEventKit` loads the three-file minimum footprint (Registry, TimerKit, ReadinessKit), so the absent case is a real absence and `Registry:Find` reports `absent`.

The allocation guard calls the native ticker's callback directly rather than through the fixture's `FireNative`, because that helper checks its argument with luassert and allocates on every call.

| Spec | Covers |
|---|---|
| `Gate_spec.lua` | definition, polling, repeated definitions, options, `Close` |
| `Timeout_spec.lua` | timeouts and the clock-less host |
| `NegativeCache_spec.lua` | the negative cache |
| `Waiters_spec.lua` | waiter order, cap, `Cancel`, callback errors |
| `ProbeErrors_spec.lua` | probes that raise |
| `CloseFromProbe_spec.lua` | a probe that closes its own gate |
| `ReprobeOn_spec.lua` | re-probing on events |
| `WhenAll_spec.lua` | `WhenAll` groups |
| `Invalidate_spec.lua` | `Invalidate` |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | argument and refusal errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Limits_spec.lua` | `maxWaiters = ReadinessKit.UNBOUNDED`, the sentinel across a reload, numeric limits still refused |
| `SecretValues_spec.lua` | secret arguments and options refused at the caller's line; secret probe answers treated as probe failures |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement |
