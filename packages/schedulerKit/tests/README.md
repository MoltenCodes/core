# SchedulerKit Tests

SchedulerKit is tested outside the WoW client through a deterministic fake Frame, precise-time clock, C_Timer boundary, and addon lifecycle environment.

The suite covers:

- weighted priority/FIFO scheduling;
- cooperative yielding and frame-budget observation;
- delayed and fixed-delay repeating work through TimerKit;
- cancellation and ownership scopes;
- self-cancellation followed by cooperative yield;
- lazy package bootstrap plus per-scope TimerKit allocation;
- LifecycleKit shutdown cleanup;
- callback/error isolation;
- bootstrap/reload identity;
- randomized active-state invariants.

Tests intentionally avoid production-only test hooks. The fake host lives under `tests/support/` and is never part of the published runtime API.
