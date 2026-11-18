# TimerKit Tests

The TimerKit suite covers:

- idle/running/paused/completed/cancelled timer state transitions;
- one-shot and repeating timers;
- zero-delay one-shot and positive-interval ticker validation;
- restart/cancel re-entrancy and stale native callback suppression;
- manual and addon-owned scope lifecycle;
- best-effort scope cleanup after native cancellation failures;
- addon scopes closed through `CloseAddonScopes` (the two-step), and addon-scope isolation; the shutdown order against LifecycleKit lives in LifecycleKit's suite;
- who closes an addon scope at logout: a LifecycleKit that lists TimerKit in `CLOSES_ADDON_SCOPES`, EventKit's `PLAYER_LOGOUT` without one (a LifecycleKit without the capability included), or nobody, re-examined when a Kit loads later and carried across the upgrade from revision 14;
- native creation rollback and strict public input validation;
- `error` levels: every argument failure reports the caller's own line;
- secret values on the `mainline` host: secret delays, options, addon names and receivers refused at the caller's line before any comparison, secret user data stored untouched;
- opaque per-timer user data attached through the public handle;
- pausing and resuming one-shot and repeating timers with the Pausing part loaded: exact remainders, a repeating timer back on its interval, stale callbacks of a paused handle, cancel, restart, `CancelAll` and `Close` of a paused timer, host failures on resume, no clock;
- the Pausing part: its stubs at the caller's line without it, `HasPart`, paused timers through the core's paths, a core reloaded after the part, the part loaded before the core;
- remaining time and deadlines (`GetRemaining`/`GetDeadline`) in every timer
  state, for repeating, restarted, overdue and rolled-back timers, and on a host
  without `GetTimePreciseSec`;
- no allocation on a repeating tick or a cancellation;
- duplicate embedded loading, the in-place upgrade from revision 14 (the byte copy in `fixtures/TimerKit-revision14.lua`) and the refusal of an older revision, and Registry publication;
- method-name callbacks (`After`/`Every` with a receiver and a method name): checked at the call, looked up at every fire, refusals at the caller's line;
- the nine-slot timer record and its size;
- reopening a closed manual scope, and the refusal for an addon scope;
- the secret probe installed after load;
- manifest/runtime API and revision consistency, and the shared Kit conformance suite.

Spec files:

| File | Covers |
|---|---|
| `TimerKit_spec.lua` | idle one-shot timers, start and completion, zero-delay `After`, idempotent cancel, restart |
| `Repeating_spec.lua` | repeating timers, self-cancel and self-restart, errors in a repeating callback |
| `Reentrancy_spec.lua` | completion before user code, restart from a callback, stale native callbacks |
| `Scope_spec.lua` | active tracking, bulk cancel, terminal close, package-level convenience recovery |
| `LogoutCoverage_spec.lua` | logout routes 1, 3 and 4, a LifecycleKit without the capability, re-examination, carrying routes across the upgrade from revision 14 and re-routing a revision 14 route 2 scope |
| `AddonScopes_spec.lua` | canonical per-addon scopes, `CloseAddonScopes`, terminal closure, unknown addons, facade receiver, manual scopes |
| `Errors_spec.lua` | definition validation, non-finite delays, native creation and cancellation failures, the trusted host handle (a missing handle refused, one without `Cancel` raising only when cancelled) |
| `ErrorLevels_spec.lua` | every argument failure at the caller's line, every check of the `After`/`Every` fast paths, receivers refused by metatable alone; a table option field named by its type without running its `__tostring` |
| `UserData_spec.lua` | opaque per-timer user data |
| `Remaining_spec.lua` | `GetRemaining`/`GetDeadline` in every state, restarts, late hosts, rolled-back starts |
| `Pause_spec.lua` | with the Pausing part: `Pause`/`Resume`/`IsPaused` of one-shot and repeating timers, stale callbacks, cancel, restart and scope cleanup of paused timers, host failures, no clock |
| `Parts_spec.lua` | the Pausing part's stubs without it, `HasPart`, paused timers through the core's paths, a core reloaded after the part, the part before the core |
| `Upgrade_spec.lua` | the upgrade from revision 14's byte copy: running, repeating and paused timers, with and without the Pausing part, and a resume revision 14 armed |
| `Conformance_spec.lua` | the shared Kit conformance suite: manifest and part revision, receivers, secret arguments, upgrade (no limits) |
| `Allocation_spec.lua` | a repeating tick and a cancellation allocate nothing |
| `Property_spec.lua` | deterministic mixed operations keep the scope active count consistent |
| `Bootstrap_spec.lua` | duplicate loading, Registry publication, loading with Registry alone, the previous-revision upgrade (which then names a table option field by its type), the refusal of a revision older than 14, no `GetTimePreciseSec` |
| `SecretValues_spec.lua` | secret arguments refused at the caller's line, secret user data accepted, a probe installed after load honoured |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |
| `MethodCallbacks_spec.lua` | `After`/`Every` with a receiver and a method name on scopes and the facade, late lookup, a method gone at fire time, refusals, `Restart`/`Pause`/`Resume` (with the Pausing part) |
| `RecordLayout_spec.lua` | the record size and allocation-free user data |
| `Reopen_spec.lua` | `Scope:Reopen` on closed, open and addon scopes, and on foreign receivers |
