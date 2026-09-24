# EventKit Tests

The EventKit suite treats WoW registration lifetime and SignalKit-backed dispatch semantics as public contract.

Coverage includes dependency/bootstrap behavior, lazy registration, final-listener unregistration, payload forwarding, listener mutation, one-shot subscriptions, unit-filter normalization, host registration failures, embedded-copy reconciliation, and manifest/runtime metadata consistency.

It also covers:

- the two-token `RegisterUnitEvent` limit, including duplicate collapsing;
- listener isolation with two tenants where the first throws, on both the
  `securecallfunction` and `xpcall` paths;
- unit-group release, Frame reuse, and the Frame-creation cap;
- disconnect-during-dispatch from another connection and from another channel;
- the stack level of argument errors versus host-environment errors;
- per-event allocation, guarded with `collectgarbage("count")` deltas;
- owner scopes: bookkeeping, one-shots, unit subscriptions, bulk teardown order
  and failure handling, closing (also during a dispatch, with the deferred
  sweep), caller-line errors, receiver validation, addon scopes and the
  two-step shutdown wiring;
- `Coalesce`: the payload set, `byEvent` and `nil`-payload keying, unit events, `maxKeys`, `Flush`, scope release (also mid-dispatch), refusal without SchedulerKit, caller-line errors, and an allocation guard;
- `Derive`: recompute, debounce, `delaySeconds`, `OnChange`, `equals`, `Invalidate`, raising compute and listeners, `Close` (which disconnects the change listeners) and scope release, a compute that closes its own scope, and the synchronous path without SchedulerKit;
- the shared `maxUnitFrames` limit: its default, `SetLimits` raising and
  lowering it without eviction, the refusal of `EventKit.UNBOUNDED` and of
  invalid values at the caller's line, atomic updates, and `GetLimits` copies;
- `ConnectCombatLog`: routing by sub-event, forwarding of every
  `CombatLogGetCurrentEventInfo()` return with its count intact (holes,
  trailing `nil`, payloads wider than the inline slots), one client read per
  event, the `"*"` wildcard and its order after the sub-event's own listeners,
  no allocation per event, host registration held only while a combat-log
  listener exists and shared with a plain `Connect` on the same event, a
  refused registration and a missing client API leaving nothing behind, the
  `C_CombatLog.GetCurrentEventInfo` fallback when the global is absent,
  a plain listener detaching or attaching the router mid-fire, the last
  listener reconnecting inside its own callback, a wildcard listener
  connected or dropped during a dispatch, a raising client read reported
  while plain listeners still run, isolation on both paths, scopes with the
  deferred close, and caller-line errors;
- `IsCombatLogAvailable`: `true` with the global reader or only
  `C_CombatLog.GetCurrentEventInfo`, `false` with neither (a Retail 12 client),
  following a reader installed after load, agreeing with `ConnectCombatLog`,
  reading nothing, registering nothing and allocating nothing; and the
  `ConnectCombatLog` refusal at the caller's line without a reader, through
  the facade and a scope;
- event-name validation with `C_EventUtils.IsEventValid`: an unknown name
  refused at the caller's line by every package and scope method, `Coalesce`
  and `Derive` names and list entries included, before anything is registered;
  the type and secret checks first; one client call per subscribing call and
  per distinct list entry, after the length bound; only a plain `false`
  refusing; EventKit's own `PLAYER_LOGOUT` and combat-log registrations left
  unchecked; the function probed once at load; and, without it, the previous
  behaviour;
- who closes an addon scope at logout: a LifecycleKit that lists EventKit in
  `CLOSES_ADDON_SCOPES`, an older LifecycleKit through `OnShutdown`, or
  EventKit's own `PLAYER_LOGOUT` one-shot, with scoped logout listeners still
  delivered, a refused registration retried, and routes given to or carried
  from an older copy;
- in-place upgrade from implementation revisions 1, 4, 5, 6, 8, 9, 10, 11, 12
  and the previous revision (which gains `IsCombatLogAvailable` and name checks),
  set limits and the sentinel carried to a newer revision, and the refusal to
  downgrade a newer copy.

## Spec files

| File | Covers |
|---|---|
| `Bootstrap_spec.lua` | Load order, duplicate embedding, corrupted state (including a mismatched sentinel and out-of-range limits), every in-place upgrade, limits carried to a newer revision, no downgrade. |
| `Manifest_spec.lua` | Manifest and runtime metadata agree. |
| `Registration_spec.lua` | Lazy registration and final-listener unregistration. |
| `Connection_spec.lua` | Connection handles: connected state and exactly-once disconnect. |
| `Dispatch_spec.lua` | Payload forwarding, ordering, mutation and nesting during dispatch, per-event allocation. |
| `Once_spec.lua` | One-shot subscriptions. |
| `UnitEvents_spec.lua` | Unit filters, the two-token limit, unit-group release and the Frame cap. |
| `SecretValues_spec.lua` | Secret names, unit tokens, options and limits refused at the caller before a comparison; secret `Coalesce` payloads keyed by event name; secret `Derive` values counted as a change. |
| `Errors_spec.lua` | Argument, receiver and host-environment errors and their levels; refused registrations; listener isolation. |
| `CombatLog_spec.lua` | `ConnectCombatLog`: routing, forwarding, the single client read, the wildcard, allocation, host registration beside a plain `Connect`, the refusal without a reader, isolation, scopes, errors; `IsCombatLogAvailable`. |
| `EventValidity_spec.lua` | Unknown event names refused through `C_EventUtils.IsEventValid`, with the function present and absent. |
| `LogoutCoverage_spec.lua` | The logout routes, subscription release, scoped `PLAYER_LOGOUT` listeners around the close, re-examination, routes across an upgrade. |
| `Scope_spec.lua` | Manual and addon scopes, deferred close, `CloseAddonScopes`. |
| `Coalesce_spec.lua` | `Coalesce`, with and without SchedulerKit. |
| `Derive_spec.lua` | `Derive`, with and without SchedulerKit. |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `EventKit.UNBOUNDED` and the `maxUnitFrames` limit. |

`EventKitTestEnv.LoadSourceAtRevision(revision)` runs the EventKit source again
with only its revision changed, standing in for another embedded copy whose
`_state` schema matches.

`EventKitTestEnv.Scheduled` is a second environment that also loads
TimerKit and SchedulerKit (LifecycleKit is optional for both and not loaded). The manifest names SchedulerKit under
`optionalDependencies`, so the runner puts those sources on `LUA_PATH` for this
suite; the release load order ignores optional dependencies.

`EventKitTestEnv.lua` supplies a narrow fake WoW Frame boundary. Production APIs are not added solely for tests.

It also replaces the shared fixture's `CombatLogGetCurrentEventInfo` with one
that returns exactly the values a spec set, `nil` holes and trailing `nil`s
included, and counts its reads: `SetCombatLogEventInfo(...)`,
`CombatLogEventInfoReads()` and `EmitCombatLogEvent(...)`, which sets the
values and emits the payload-free `COMBAT_LOG_EVENT_UNFILTERED`. EventKit
resolves the API when its first combat-log listener connects, so the fake is
installed with the other host globals, before the package loads.

By default no `C_EventUtils` is installed, which is the "absent" profile: an
unknown event name reaches the Frame stub's `RegisterEvent`. The "present"
profile is loaded with `NewPackageKnowingEvents(names)` (or
`Scheduled.NewEventKitKnowingEvents(names)`), which installs a
`C_EventUtils.IsEventValid` fake knowing exactly `names` before EventKit loads,
because EventKit probes it once at load; `SetEventKnown(name, known)` changes
the answer and `EventValidityChecks()` counts the calls. The shared fixture's
client profiles that publish `C_EventUtils` know every literal event name of
the retail metadata in `packages/apiKit/metadata/`.

The stub enforces the host's two unit-filter slots so the suite can see a package
bug that passes a third token, and installs a `geterrorhandler` hook so isolated
listener failures are observable. Its `Emit` walks Frames in creation order; that
order is an artefact of the stub, not an EventKit guarantee, so no spec may
depend on it.
