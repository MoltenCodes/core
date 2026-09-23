# SchedulerKit Tests

SchedulerKit is tested outside the WoW client through a deterministic fake Frame, independently controllable CPU and wall clocks, C_Timer boundary, and addon lifecycle environment. Driving the two clocks apart is what makes a client hitch reproducible in a spec.

The suite covers:

- weighted priority/FIFO scheduling, IDLE background service, and the IDLE starvation guard;
- cooperative yielding and CPU-time frame-budget observation, including the wall-clock fallback;
- runaway-slice demotion and the Lua 5.1 swallowed-`Yield()` diagnostic;
- delayed and fixed-delay repeating work through TimerKit;
- cancellation and ownership scopes;
- self-cancellation followed by cooperative yield;
- lazy package bootstrap plus per-scope TimerKit allocation;
- LifecycleKit shutdown cleanup;
- callback/error isolation and tracebacks captured at the point of failure;
- delayed wakeups carried on TimerKit's public user-data seam;
- scopes closed from inside a running job, including during an `Every` callback;
- bootstrap/reload identity and in-place revision upgrade;
- randomized active-state invariants;
- `Debounce`: restart, last arguments, the eight-argument slot, `leading`, `maxWaitSeconds`, `Cancel`, `Flush`, re-entrant calls, scope release, caller-line errors, and an allocation guard;
- `Coalesce`: set accumulation, the interval, `maxKeys` refusal and stats, reuse of the two set tables, keys recorded by the callback, `Flush`, scope release, and an allocation guard;
- `Watch`: edge trigger, `everyTick`, one shared ticker per interval, both caps, a raising predicate or callback, cancellation during a tick, scope release, and an allocation guard;
- lanes: sharing by name, `maxInFlight`, `minIntervalSeconds`, retry with capped backoff, `maxQueued` refusal, queue compaction, `Close`, scope release, and `Debounce`/`Coalesce` delivering through a lane;
- the revision-6 upgrade of shared state and older scopes;
- the 0.5.1 review fixes: newest debounce arguments against a full lane, `Flush` deferral, member close against admitted and waiting deliveries, timer-arm failure recovery, retries against the minimum interval and `Close`, backwards clock steps, Watch callback tracebacks, FIFO index reset, and the revision-7 upgrade.

Tests intentionally avoid production-only test hooks. The fake host lives under `tests/support/` and is never part of the published runtime API.
