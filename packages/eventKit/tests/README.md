# EventKit Tests

The EventKit suite treats WoW registration lifetime and SignalKit's dispatch semantics, which EventKit applies to its own listener arrays, as public contract.

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
- the three parts (Units, CombatLog, Coalescing): each part's bootstrap (the revision its file carries, the refusal without the core, the Coalescing part's refusal against part interface 1 and without SignalKit, an equal or newer revision left alone, a higher one taking over unit groups, the combat-log router or live handles and timers, a core upgraded after it serving it), the core's stubs of every part member at the caller's line with the file to embed, `HasPart`, `IsCombatLogAvailable` and `maxUnitFrames` without the parts, the `units` option refused without the Units part, and a scope closing unit, combat-log, plain and coalesced members together;
- the TimerKit timing, with no SchedulerKit loaded: the first key arming one timer, `maxKeys` refusals and counts with its default of 256, the two reused sets, keys recorded during the callback, a zero interval, a timer TimerKit cannot arm keeping the key, `Flush` inside the callback, `GetStats` in one table, a raising callback reported, a stale host callback ignored, the kept `maxKeys` wording; `Derive`'s quiet period re-armed for the remainder, the next-frame default, no clock, a timer TimerKit cannot arm raised to `Invalidate`, close cancelling; and the `lane` path through SchedulerKit with its parts refused by name;
- `Coalesce`: the payload set, `byEvent` and `nil`-payload keying, unit events, `maxKeys`, `Flush`, scope release (also mid-dispatch), refusal without TimerKit, caller-line errors, and an allocation guard;
- `Derive`: recompute, debounce, `delaySeconds`, `OnChange`, `equals`, `Invalidate`, raising compute and listeners, `Close` (which disconnects the change listeners) and scope release, a compute that closes its own scope, and the synchronous path without TimerKit;
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
  `CLOSES_ADDON_SCOPES`, or otherwise EventKit's own `PLAYER_LOGOUT` one-shot,
  with scoped logout listeners still delivered, a refused registration
  retried, and the one-shot carried from the previous revision;
- listener storage: one handle per connection holding the callback itself, the
  tail dropped and compaction in place outside a dispatch, replacement during
  one, a `Once` tombstone settled later, a connect behind a tail tombstone
  deferred, the depth restored after a listener error, a scope's deferred sweep
  settling in place; the channel pool (a record reused for the next event,
  sixteen records at most holding no reference, nothing pooled during a
  dispatch, unit channels pooled with their Frame freed); and allocation
  guards for connect and disconnect beside other listeners and of the only
  listener (the handle only) and for a one-by-one teardown (nothing);
- the method-name form: the receiver and payload a method receives, the
  default method name on `Connect` and `Once`, the required name before the
  unit tokens, the lookup at every delivery (a replaced method runs, a removed
  one is reported and the connection stays), every refusal at the caller's
  line with nothing registered, a secret method name, and scope ownership;
- `Scope:Reopen`: an empty, usable scope after a close, `false` when open, an
  addon scope and a foreign receiver refused at the caller, and a scope closed
  and reopened inside a dispatch (only its earlier connections and handles
  swept);
- the protected walk: no `pcall` for a channel of ordinary listeners, the
  one-shot count through connect, disconnect and delivery, the depth restored
  when a one-shot's host release raises, isolation on the unprotected walk,
  and the count reset when a record is pooled;
- the secret probe resolved at load (a later global not read) and a probe
  installed after load honoured when there was none;
- the connection receiver test by metatable identity (strings, numbers, a
  foreign table with the prototype as `__index`);
- the core loading and serving `Connect` with no SignalKit registered;
- the upgrade floor: in-place upgrade from revision 22 only, with the byte
  copy of revision 22's files (`tests/fixtures/EventKit-revision22.lua` and
  `EventKit-Coalescing-revision1.lua`) loaded first: regular, unit,
  combat-log and coalesced connections kept delivering with the parts, unit
  and combat-log connections retired on the next frame or at the first event
  without their parts and reported once per part, retired Frames reused by a
  Units part loaded later; a copy below the floor refused; set limits and the
  sentinel carried to a newer revision; the refusal to downgrade a newer copy;
- the shared conformance suite (`tests/support/KitConformance.lua`): manifest,
  `maxUnitFrames`, receivers (`CreateScope` and `IsCombatLogAvailable`
  exempt: neither reads an argument), secret arguments and the upgrade from
  the previous revision, emulated and committed.

## Spec files

| File | Covers |
|---|---|
| `Bootstrap_spec.lua` | Load order, loading without SignalKit, duplicate embedding, corrupted state (including a mismatched sentinel and out-of-range limits), the upgrade from the previous revision and the refusal below the floor, limits carried to a newer revision, no downgrade, connection receiver checks. |
| `Upgrade_spec.lua` | The in-place upgrade from the byte copy of revision 22's files, with and without the Units and CombatLog parts. |
| `Conformance_spec.lua` | The shared conformance suite. |
| `Manifest_spec.lua` | Manifest and runtime metadata agree. |
| `Registration_spec.lua` | Lazy registration and final-listener unregistration. |
| `Connection_spec.lua` | Connection handles: connected state and exactly-once disconnect. |
| `Dispatch_spec.lua` | Payload forwarding, ordering, mutation and nesting during dispatch, per-event allocation. |
| `Once_spec.lua` | One-shot subscriptions. |
| `UnitEvents_spec.lua` | Unit filters, the two-token limit, unit-group release and the Frame cap. |
| `SecretValues_spec.lua` | Secret names, unit tokens, options and limits refused at the caller before a comparison; the probe resolved at load; secret `Coalesce` payloads keyed by event name; secret `Derive` values counted as a change. |
| `Errors_spec.lua` | Argument, receiver and host-environment errors and their levels; refused registrations; listener isolation. |
| `CombatLog_spec.lua` | `ConnectCombatLog`: routing, forwarding, the single client read, the wildcard, allocation, host registration beside a plain `Connect`, the refusal without a reader, isolation, scopes, errors; `IsCombatLogAvailable`. |
| `EventValidity_spec.lua` | Unknown event names refused through `C_EventUtils.IsEventValid`, with the function present and absent. |
| `LogoutCoverage_spec.lua` | The logout routes, scoped `PLAYER_LOGOUT` listeners around the close, re-examination, the one-shot carried across an upgrade. |
| `Scope_spec.lua` | Manual and addon scopes, deferred close, `CloseAddonScopes`. |
| `Coalesce_spec.lua` | `Coalesce`, with and without TimerKit, and with TimerKit loaded after a refused call; the part's one TimerKit scope, one lookup, the handle cost, and a table option key named by its type without running its `__tostring`. |
| `Derive_spec.lua` | `Derive`, with and without TimerKit. |
| `Parts_spec.lua` | The three parts' bootstrap and revisions, the core's stubs and `HasPart`, the core without its parts, a scope with every kind of member. |
| `Timing_spec.lua` | Every TimerKit timing rule of `Coalesce` and `Derive` with no SchedulerKit loaded, and the `lane` path. |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `EventKit.UNBOUNDED`, the `maxUnitFrames` limit, and a table limit key named by its type without running its `__tostring`. |
| `ListenerStorage_spec.lua` | Listener arrays in and out of a dispatch, the channel pool, handle-only allocation guards (unscoped and scoped handle bounds). |
| `MethodForm_spec.lua` | The method-name form of the four connecting methods and their scope forms. |
| `Reopen_spec.lua` | `Scope:Reopen`, including a close and reopen inside a dispatch. |
| `ProtectedWalk_spec.lua` | When the listener walk is protected, the one-shot count, the depth after a raising release. |

`EventKitTestEnv.LoadSourceAtRevision(revision)` runs the EventKit core
source again with only its revision changed, standing in for another embedded
copy whose `_state` schema matches. `LoadRevision22("core")` and
`LoadRevision22("coalescing")` run the byte copies of revision 22's files.

`EventKitTestEnv.NewPackage()` loads the core with the Units and CombatLog
parts, which most specs use; `NewCore()` loads the core alone,
`LoadUnitsAndCombatLog()` adds those two parts and `LoadCoalescing()` the
third. SignalKit stays in the chain because the Coalescing part needs it;
`NewPackageWithout("SignalKit")` loads the core without it. `EventKitTestEnv.Scheduled` is a second environment that also loads
TimerKit, SchedulerKit with its Coalescing and Lanes parts, and EventKit's
part; `EventKitTestEnv.Timed` loads TimerKit and the part without
SchedulerKit (LifecycleKit is optional for all and not loaded). The part's
manifest entry names TimerKit and SchedulerKit under `optionalDependencies`,
so the runner puts those sources on `LUA_PATH` for this suite; the release
load order ignores optional dependencies.

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
