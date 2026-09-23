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
- in-place upgrade from implementation revisions 1, 4, 5, 6, 8 and 9, set limits
  and the sentinel carried to a newer revision, and the refusal to downgrade a
  newer copy.

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
| `Errors_spec.lua` | Argument, receiver and host-environment errors and their levels; refused registrations; listener isolation. |
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

The stub enforces the host's two unit-filter slots so the suite can see a package
bug that passes a third token, and installs a `geterrorhandler` hook so isolated
listener failures are observable. Its `Emit` walks Frames in creation order; that
order is an artefact of the stub, not an EventKit guarantee, so no spec may
depend on it.
