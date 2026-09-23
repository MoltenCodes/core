# SchedulerKit Tests

SchedulerKit is tested outside the WoW client through a deterministic fake Frame, independently controllable CPU and wall clocks, and C_Timer boundary. Driving the two clocks apart is what makes a client hitch reproducible in a spec.

The suite covers:

- weighted priority/FIFO scheduling, IDLE background service, and the IDLE starvation guard;
- cooperative yielding and CPU-time frame-budget observation, including the wall-clock fallback;
- runaway-slice demotion and the Lua 5.1 swallowed-`Yield()` diagnostic;
- delayed and fixed-delay repeating work through TimerKit;
- cancellation and ownership scopes;
- self-cancellation followed by cooperative yield;
- lazy package bootstrap plus per-scope TimerKit allocation;
- addon scopes closed through `CloseAddonScopes` (the two-step); the shutdown order against LifecycleKit lives in LifecycleKit's suite;
- who closes an addon scope at logout: a LifecycleKit that lists SchedulerKit in `CLOSES_ADDON_SCOPES`, an older LifecycleKit through `OnShutdown`, EventKit's `PLAYER_LOGOUT` without LifecycleKit, or nobody, re-examined when a Kit loads later and carried across an upgrade;
- callback/error isolation and tracebacks captured at the point of failure;
- delayed wakeups carried on TimerKit's public user-data seam;
- scopes closed from inside a running job, including during an `Every` callback;
- bootstrap/reload identity and in-place revision upgrade;
- randomized active-state invariants;
- `Debounce`: restart, last arguments, the eight-argument slot, `leading`, `maxWaitSeconds`, `Cancel`, `Flush`, re-entrant calls, scope release, caller-line errors, and an allocation guard;
- `Coalesce`: set accumulation, the interval, `maxKeys` refusal and stats, reuse of the two set tables, keys recorded by the callback, `Flush`, scope release, and an allocation guard;
- `Watch`: edge trigger, `everyTick`, one shared ticker per interval, both caps, a raising predicate or callback, cancellation during a tick, scope release, and an allocation guard;
- lanes: sharing by name, `maxInFlight`, `minIntervalSeconds`, retry with capped backoff, `maxQueued` refusal with an allocation guard on full and closed refusals, queue compaction, `Close`, scope release, and `Debounce`/`Coalesce` delivering through a lane;
- the revision-6 upgrade of shared state and older scopes;
- the 0.5.1 review fixes: newest debounce arguments against a full lane, `Flush` deferral, member close against admitted and waiting deliveries, timer-arm failure recovery, retries against the minimum interval and `Close`, backwards clock steps, Watch callback tracebacks, FIFO index reset, and the revision-7 upgrade.

Spec files:

| File | Covers |
|---|---|
| `SchedulerKit_spec.lua` | next-frame scheduling, nested `Schedule` versus `NextFrame`, defaults, configuration and option validation |
| `Priority_spec.lua` | FIFO within a priority, weighted service, IDLE work and its starvation guard, the fairness cursor |
| `Cooperative_spec.lua` | yielding, the CPU-time frame budget, the resume ceiling, runaway-slice demotion |
| `Delayed_spec.lua` | delayed and repeating work through TimerKit, the user-data seam, stale wakeups, scopes closed mid-callback |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `UNBOUNDED`, ceilings, the 33rd lane, wide debounce calls direct and through a lane, atomic validation |
| `Scope_spec.lua` | lazy TimerKit scopes, cancellation, terminal close, self-closing jobs, addon scopes and `CloseAddonScopes` |
| `LogoutCoverage_spec.lua` | the four logout routes, re-examination, subscription release on close, carrying routes across an upgrade |
| `Errors_spec.lua` | error isolation, `nil`/`false` error objects, tracebacks, arming and re-arm failures |
| `ErrorLevels_spec.lua` | `ShouldYield`, `Yield` and context receiver guards at the caller's line |
| `Property_spec.lua` | randomized scope and package active-count invariants |
| `Debounce_spec.lua` | `Debounce`: restart, last arguments, `leading`, `maxWaitSeconds`, `Cancel`, `Flush`, scope release, allocation guard |
| `Coalesce_spec.lua` | `Coalesce`: key sets, `maxKeys`, set reuse, `Flush`, raising callbacks, scope release |
| `Watch_spec.lua` | `Watch`: edge trigger, `everyTick`, shared tickers, both caps, raising predicates and callbacks |
| `Lane_spec.lua` | lanes: sharing, `maxInFlight`, `minIntervalSeconds`, retries, `maxQueued`, `Close`, allocation-free refusals, family delivery |
| `Bootstrap_spec.lua` | duplicate loading, live job identity, the revision-3, -6 and -7 upgrades, live family handles |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |

Tests intentionally avoid production-only test hooks. The fake host lives under `tests/support/` and is never part of the published runtime API.
