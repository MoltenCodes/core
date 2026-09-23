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
- in-place upgrade from implementation revision 1;
- per-event allocation, guarded with `collectgarbage("count")` deltas;
- `Coalesce`: the payload set, `byEvent` and `nil`-payload keying, unit events, `maxKeys`, `Flush`, scope release (also mid-dispatch), refusal without SchedulerKit, caller-line errors, and an allocation guard;
- `Derive`: recompute, debounce, `delaySeconds`, `OnChange`, `equals`, `Invalidate`, raising compute and listeners, `Close` and scope release, and the synchronous path without SchedulerKit;
- in-place upgrade from implementation revision 6.

`EventKitTestEnv.Scheduled` is a second environment that also loads
LifecycleKit, TimerKit and SchedulerKit, whose sources it adds to
`package.path` because the runner's path follows manifest dependencies and
SchedulerKit is only an optional partner.

`EventKitTestEnv.lua` supplies a narrow fake WoW Frame boundary. Production APIs are not added solely for tests.

The stub enforces the host's two unit-filter slots so the suite can see a package
bug that passes a third token, and installs a `geterrorhandler` hook so isolated
listener failures are observable. Its `Emit` walks Frames in creation order; that
order is an artefact of the stub, not an EventKit guarantee, so no spec may
depend on it.
