# TimerKit Tests

The TimerKit suite covers:

- idle/running/completed/cancelled timer state transitions;
- one-shot and repeating timers;
- zero-delay one-shot and positive-interval ticker validation;
- restart/cancel re-entrancy and stale native callback suppression;
- manual and addon-owned scope lifecycle;
- best-effort scope cleanup after native cancellation failures;
- LifecycleKit shutdown integration and addon-scope isolation;
- native creation rollback and strict public input validation;
- duplicate embedded loading and Registry publication;
- manifest/runtime API and revision consistency.
