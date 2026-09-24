# TimerKit Tests

The TimerKit suite covers:

- idle/running/completed/cancelled timer state transitions;
- one-shot and repeating timers;
- zero-delay one-shot and positive-interval ticker validation;
- restart/cancel re-entrancy and stale native callback suppression;
- manual and addon-owned scope lifecycle;
- best-effort scope cleanup after native cancellation failures;
- addon scopes closed through `CloseAddonScopes` (the two-step), and addon-scope isolation; the shutdown order against LifecycleKit lives in LifecycleKit's suite;
- who closes an addon scope at logout: a LifecycleKit that lists TimerKit in `CLOSES_ADDON_SCOPES`, an older LifecycleKit through `OnShutdown`, EventKit's `PLAYER_LOGOUT` without LifecycleKit, or nobody, re-examined when a Kit loads later and carried across an upgrade;
- native creation rollback and strict public input validation;
- `error` levels: every argument failure reports the caller's own line;
- opaque per-timer user data attached through the public handle;
- remaining time and deadlines (`GetRemaining`/`GetDeadline`) in every timer
  state, for repeating, restarted, overdue and rolled-back timers, for timers an
  older revision started, and on a host without `GetTimePreciseSec`;
- no allocation on a repeating tick or a cancellation;
- duplicate embedded loading, in-place revision upgrade, and Registry publication;
- manifest/runtime API and revision consistency.

Spec files:

| File | Covers |
|---|---|
| `TimerKit_spec.lua` | idle one-shot timers, start and completion, zero-delay `After`, idempotent cancel, restart |
| `Repeating_spec.lua` | repeating timers, self-cancel and self-restart, errors in a repeating callback |
| `Reentrancy_spec.lua` | completion before user code, restart from a callback, stale native callbacks |
| `Scope_spec.lua` | active tracking, bulk cancel, terminal close, package-level convenience recovery |
| `LogoutCoverage_spec.lua` | the four logout routes, re-examination, subscription release on close, carrying routes across an upgrade |
| `AddonScopes_spec.lua` | canonical per-addon scopes, `CloseAddonScopes`, terminal closure, unknown addons, facade receiver, manual scopes |
| `Errors_spec.lua` | definition validation, non-finite delays, native creation and cancellation failures |
| `ErrorLevels_spec.lua` | every argument failure at the caller's line |
| `UserData_spec.lua` | opaque per-timer user data |
| `Remaining_spec.lua` | `GetRemaining`/`GetDeadline` in every state, restarts, late hosts, rolled-back starts |
| `Allocation_spec.lua` | a repeating tick and a cancellation allocate nothing |
| `Property_spec.lua` | deterministic mixed operations keep the scope active count consistent |
| `Bootstrap_spec.lua` | duplicate loading, Registry publication, loading with Registry alone, the revision-1, revision-5 and revision-7 upgrades, older revisions' deadlines, no `GetTimePreciseSec` |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |
