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
- `error` levels: every argument failure reports the caller's own line;
- opaque per-timer user data attached through the public handle;
- remaining time and deadlines (`GetRemaining`/`GetDeadline`) in every timer
  state, for repeating, restarted, overdue and rolled-back timers, for timers an
  older revision started, and on a host without `GetTimePreciseSec`;
- duplicate embedded loading, in-place revision upgrade, and Registry publication;
- manifest/runtime API and revision consistency.
