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
- callback/error isolation and tracebacks captured at the point of failure, from `debug.traceback` or, on a host without it (the Retail client), the client's `debugstack`;
- delayed wakeups carried on TimerKit's public user-data seam;
- scopes closed from inside a running job, including during an `Every` callback;
- bootstrap/reload identity and in-place revision upgrade;
- randomized active-state invariants;
- `Debounce`: restart, last arguments, the eight-argument slot, `leading`, `maxWaitSeconds`, `Cancel`, `Flush`, re-entrant calls, scope release, caller-line errors, and an allocation guard;
- `Coalesce`: set accumulation, the interval, `maxKeys` refusal and stats, reuse of the two set tables, keys recorded by the callback, `Flush`, scope release, and an allocation guard;
- `Watch`: edge trigger, `everyTick`, one shared ticker per interval, both caps, a raising predicate or callback, a result that cannot be compared, cancellation during a tick, scope release, and an allocation guard;
- lanes: sharing by name, `maxInFlight`, `minIntervalSeconds`, retry with capped backoff, `maxQueued` refusal with an allocation guard on full and closed refusals, queue compaction, `Close`, scope release, and `Debounce`/`Coalesce` delivering through a lane;
- lane and family edge cases: newest debounce arguments against a full lane, `Flush` deferral, member close against admitted and waiting deliveries, timer-arm failure recovery, retries against the minimum interval and `Close`, backwards clock steps, Watch callback tracebacks, and FIFO index reset;
- an allocation guard on the resume path: a job yielding slice after slice, across every priority, allocates nothing, and a never-drained priority queue keeps its indices at the front;
- in-place upgrades from revisions 3, 6, 7, 9, 10, 11, 12 and 14, and from the previous revision (the current one minus one), keeping the facade and state tables;
- secret values on the `mainline` host: every argument a check would compare refused before the comparison, a secret coalesce value stored, ordinary arguments still accepted.

Spec files:

| File | Covers |
|---|---|
| `SchedulerKit_spec.lua` | next-frame scheduling, nested `Schedule` versus `NextFrame`, defaults, configuration and option validation |
| `Priority_spec.lua` | FIFO within a priority, weighted service, IDLE work and its starvation guard (no credit earned while the IDLE lane is empty), the fairness cursor |
| `Cooperative_spec.lua` | yielding, the CPU-time frame budget, the resume ceiling, runaway-slice demotion |
| `Delayed_spec.lua` | delayed and repeating work through TimerKit, the user-data seam, stale wakeups, scopes closed mid-callback |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `UNBOUNDED`, ceilings, the 33rd lane, wide debounce calls direct and through a lane, atomic validation |
| `Scope_spec.lua` | lazy TimerKit scopes, cancellation, terminal close, self-closing jobs, addon scopes and `CloseAddonScopes` |
| `LogoutCoverage_spec.lua` | the four logout routes, re-examination, subscription release on close, carrying routes across the revision-11 upgrade |
| `Errors_spec.lua` | error isolation, `nil`/`false` error objects, tracebacks, arming and re-arm failures |
| `Traceback_spec.lua` | the two traceback sources: `debug.traceback`, preferred when both exist, and `debugstack` on a host without `debug.traceback` (a stub installed, and `debug` swapped for a copy without `traceback` only while the package loads); `tostring` rendering, resolution once at load, a failing source, neither source, the revision-14 upgrade on that host; the `xpcall` handler's `Watch`, `Debounce` and `Coalesce` reports from level 3 on both sources, and a lane submission's traceback |
| `ErrorLevels_spec.lua` | `ShouldYield`, `Yield` and context receiver guards, and `CloseAddonScopes` argument and receiver errors, at the caller's line; every argument, closed-scope and wrong-receiver error of the package-level and scope `Schedule`, `NextFrame`, `After` and `Every`, and the wrong-receiver errors of `Scope:CancelAll`, `Scope:Close` and `Job:Cancel`, at the caller's line with no tail call into the Kit on the way (a line hook checks, since standard Lua 5.1 still counts the level of a tail-called frame); the same after a revision-15 upgrade |
| `Property_spec.lua` | randomized scope and package active-count invariants |
| `Debounce_spec.lua` | `Debounce`: restart, last arguments, `leading`, `maxWaitSeconds`, `Cancel`, `Flush`, scope release, allocation guard |
| `Coalesce_spec.lua` | `Coalesce`: key sets, `maxKeys`, set reuse, `Flush`, raising callbacks, scope release |
| `Watch_spec.lua` | `Watch`: edge trigger, `everyTick`, shared tickers, both caps, raising predicates and callbacks, results that cannot be compared |
| `Allocation_spec.lua` | the resume path allocates nothing; a never-drained priority queue keeps its indices at the front |
| `Lane_spec.lua` | lanes: sharing, `maxInFlight`, `minIntervalSeconds`, retries, `maxQueued`, `Close`, allocation-free refusals, family delivery |
| `Bootstrap_spec.lua` | duplicate loading, live job identity, the revision-3, -6, -7, -9, -10 and -12 upgrades and the previous-revision upgrade, live family handles |
| `SecretValues_spec.lua` | secret arguments, options, limits and coalesce keys refused with `... must not be a secret value` at the caller's line, the scheduling methods' included; a secret coalesce value delivered |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |

`support/SchedulerKitTestEnv.lua` adds the optional-Kit loaders, `LoadRevision` (this source loaded as an older revision for upgrade specs) and `AllocatedKilobytes` (the allocation meter every allocation guard uses) to the shared fixture.

Tests intentionally avoid production-only test hooks. The fake host lives under `tests/support/` and is never part of the published runtime API.
