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
- randomized active-state invariants.

Tests intentionally avoid production-only test hooks. The fake host lives under `tests/support/` and is never part of the published runtime API.
