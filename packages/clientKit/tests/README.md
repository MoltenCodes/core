# ClientKit Tests

The ClientKit suite runs against the shared fixture's client profiles
(`tests/support/framework/ClientStub.lua`): one per supported flavour —
`mainline`, `mists`, `tbc`, `classic` — plus `noProjectId`, a host that
publishes no `WOW_PROJECT_ID` and no `GetBuildInfo`. `ClientKitTestEnv.NewPackageFor(profile)`
selects one and loads Registry and ClientKit against it.

The suite covers:

- flavour and build per profile, with each interface number checked against
  `tooling/validation/supported_clients.json`;
- the absent-project-id trap: an absent id yields `"classic"`, interface `0`,
  and never every capability at once; an unknown, non-number or
  constant-less id is handled by value;
- `IsAtLeast` boundaries, including the cross-flavour ordering it does not
  promise;
- the capability table flag by flag for every profile, a host that exposes
  nothing, flags probed from the host rather than the flavour, unknown names,
  and zero allocation after bootstrap;
- `IsSecret` with the `issecretvalue` stub and without it; `CanAccessFrame`
  for forbidden, context-restricted, unrestricted and method-less frames;
  `IsEventValid` for a known, an invalid and an unknowable name;
- every shim on modern and legacy hosts and on a host with neither;
- `error` levels: every argument failure reports the caller's own line;
- Registry publication, duplicate loads, a newer revision not being
  downgraded, an in-place upgrade that re-reads the host into the same state
  tables (a copy of the source loaded with a higher revision), load-order
  failures, and corrupted-state refusal;
- manifest/runtime API and revision consistency.
