# ReadinessKit Tests

The ReadinessKit suite covers:

- gates that are ready at once (no timer is ever created), ready after N polls on one repeating TimerKit timer, `intervalSeconds`, truthy probe results, and a repeated definition that returns the existing gate and ignores the new probe and options;
- timeouts: waiters told `false, "timeout"` once, polling stopped, `timeoutSeconds = false`, the wall-clock window, `Await` on a timed-out gate, and new rounds started by `Invalidate`, `Probe` and a re-probe event;
- negative caching: no probe within the interval of a negative answer, the window restarted by a poll, dropped by `Invalidate`, and never a probe on a ready gate;
- waiters: FIFO order, the `maxWaiters` cap and `"full"`, `Cancel` (also from an earlier callback of the same batch), queued callback errors routed to the host error handler while the batch continues, immediate callback errors raised at the caller, waiters queued during a flush, and the two waiter arrays reused across rounds;
- probes that raise: treated as not ready, polling continues, the first failure of each round reported and every failure counted, the `print` fallback without a host handler;
- a probe that closes its own gate, on every path that runs a probe (definition, poll, timing-out poll, `Probe`, re-probe event): the gate stays closed;
- `ReprobeOn` through the real EventKit, connections released by `Close`, a gate closed during the dispatch in flight, and the error when `Registry:Find` refuses EventKit;
- `WhenAll`: success, already-ready gates, the empty list, the first timeout, a gate already timed out, a gate closed while waiting, the gates' caps, and `Cancel`;
- `Close`: waiters told `"closed"`, the name freed, stale ticks ignored, closing from inside a callback;
- a host without `GetTimePreciseSec`: timeouts counted in polls, negative cache disabled;
- allocation guards (`collectgarbage("count")` with the collector stopped) on the poll tick while not ready, `IsReady` and a cached `Probe`;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry or TimerKit, and an in-place upgrade that keeps gates, waiters, the poll timer, a re-probe subscription and a `WhenAll` group;
- `error` levels: every argument failure reports the caller's own line;
- manifest/runtime API and revision consistency.

TimerKit depends on LifecycleKit, EventKit and SignalKit, so the whole chain is in the manifest dependency closure the runner puts on `LUA_PATH` (EventKit is also listed under `optionalDependencies`). EventKit therefore cannot be absent in this suite; `support/ReadinessKitTestEnv.lua` models the absent case by making `Registry:Find` refuse EventKit, which is exactly the lookup ReadinessKit performs.

The allocation guard calls the native ticker's callback directly rather than through the fixture's `FireNative`, because that helper checks its argument with luassert and allocates on every call.
