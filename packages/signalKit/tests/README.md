# SignalKit Tests

The SignalKit suite treats callback dispatch semantics as the package contract rather than implementation detail.

Coverage includes:

- construction and argument forwarding;
- deterministic listener ordering;
- connection lifecycle and idempotent disconnect;
- once-listener behavior, including recursive dispatch;
- connect/disconnect/DisconnectAll mutations during dispatch;
- recursive `Fire()` behavior;
- listener error propagation and post-error reuse;
- receiver validation for signal and connection methods, including the line the
  error points at;
- tombstone/compaction retention bounds and listener order across compaction;
- allocation guards for `Fire()` and `Disconnect()` using `collectgarbage("count")`
  deltas with tolerance;
- the in-place upgrade path for signals created by implementation revision 1;
- the `onFirst` and `onLast` hooks: option validation (a dot call with options
  refused), the 0→1 and 1→0 transitions and nothing in between, `Once`
  listeners counted until they disconnect, `DisconnectAll` as one transition,
  no hooks on bus topic signals, re-entrant connect and disconnect inside a
  hook, and hook errors propagated to the caller after the transition took
  effect;
- `GetGeneration`: from 0, per `Fire` with or without listeners, moved before
  listeners run, unmoved by connects, kept on a listener error, `0` for a
  signal created before the counter, receiver refusal at the caller;
- journals: default and explicit capacity, the hook options, refusal of
  invalid capacities, `UNBOUNDED`, bad options and the wrong receiver at the
  caller, `History` order and 1-based positions, the ring wrapping, entry
  shape (`count`, arguments with `nil`, `generation`), stale arguments cleared
  from a reused slot, no replay on connect, recording before dispatch and on a
  listener error, slot tables reused, the argument cap refused at the firing
  line with no value in the message, secret values stored without comparison,
  a walk that stays in range while the journal fires underneath it, and
  allocation guards on `Fire` (fresh ring, and alternating widths past
  eight) and on `History` walks;
- limits: the `maxTopics` and `maxListeners` bus options with integers and
  `SignalKit.UNBOUNDED`, the first-statement rule on a shared bus,
  `SetLimits`/`GetLimits` for `maxBuses` with its 1024 ceiling,
  `maxJournalCapacity` with its 65536 ceiling (bounding `NewJournal`, the
  default capacity refused once the limit is below it, no shrinking) and
  `maxJournalArguments` with its 64 ceiling (applied at the firing line, also
  to existing journals), refused `UNBOUNDED` with each limit's reason, refusal
  of invalid values at the calling line, atomic updates, and no eviction when
  a limit is lowered;
- named buses: sharing by name, the bus, topic and listener bounds, declared
  versus undeclared topics and `openTopics`, argument-count and validator
  refusal at the publishing line, secret refusal reasons, `Subscribe`,
  `SubscribeOnce`, `Unsubscribe` and `Topics`;
- bus dispatch semantics compared trace for trace with a raw signal;
- bus listener isolation through the host error handler on both the `xpcall`
  and the `securecallfunction` paths, and an allocation guard on steady-state
  `Publish`;
- bus scopes, `ForAddon` and `CloseAddonBus`;
- closing an addon's bus at logout: a LifecycleKit that names `signalKit` in
  `CLOSES_ADDON_SCOPES` left to close it after the shutdown callbacks (also for
  an addon without its own LifecycleKit instance), an older LifecycleKit's
  `OnShutdown` subscription (made once, disconnected by an early
  `CloseAddonBus`, also used for a list that does not name `signalKit`), the one
  `PLAYER_LOGOUT` watcher through EventKit closing addon buses and no other bus,
  nothing arranged without either, the decision taken again when LifecycleKit
  loads later, a failure in another Kit reported, the upgrade from revision-5
  state, and the subscription and watcher kept across an upgrade;
- Registry bootstrap and duplicate embedding, the upgrade from a revision-3 copy
  without state, the upgrade from revision-4 state (sentinel, limits, the
  logout watcher and the journal tables added), the upgrade from revision-6
  state (journal tables and limits added, older signals reporting generation
  0 and connecting without hooks), refusal of schema-3 state without a
  limits table, buses, set limits, the sentinel identity
  and journals with their history carried into a newer revision, refusal of an
  incomplete journal prototype, and refusal to reinterpret a newer revision's
  state;
- runtime API/revision metadata consistency with the package manifest.

Spec files:

| File | Covers |
|---|---|
| `SignalKit_spec.lua` | construction, argument forwarding, ordering, signal independence |
| `Once_spec.lua` | once-listeners, including recursive dispatch |
| `Mutation_spec.lua` | connect, disconnect and `DisconnectAll` during dispatch |
| `Reentrancy_spec.lua` | nested `Fire()` |
| `Errors_spec.lua` | argument and receiver validation at the calling line, listener error propagation |
| `Connection_spec.lua` | connection lifecycle and idempotent `Disconnect` |
| `Compaction_spec.lua` | tombstones, compaction, allocation guards, the revision-1 upgrade |
| `Hooks_spec.lua` | `onFirst` and `onLast`: options, transitions, `Once` and `DisconnectAll`, re-entrancy, hook errors |
| `Generation_spec.lua` | `GetGeneration` |
| `Journal_spec.lua` | `NewJournal`, `History`, the entry shape, the argument cap, secret values, allocation guards |
| `Bus_spec.lua` | buses, topic policy, subscriptions, bus dispatch semantics |
| `BusIsolation_spec.lua` | listener isolation on both paths, the `Publish` allocation guard |
| `BusScope_spec.lua` | bus scopes, `ForAddon`, `CloseAddonBus` |
| `Limits_spec.lua` | bus limit options, `UNBOUNDED`, `SetLimits`/`GetLimits` for all three package-wide limits, refusal at the caller |
| `LogoutClose_spec.lua` | who closes an addon's bus at logout, in each of the four cases, and across upgrades |
| `Bootstrap_spec.lua` | Registry bootstrap, duplicate embedding, revision upgrades, limits and sentinel carried |
| `Manifest_spec.lua` | runtime metadata against `package.manifest.json` |

EventKit and LifecycleKit are declared under `optionalDependencies`, so the
runner puts them on `LUA_PATH`. `LoadEventKit` and `LoadLifecycleKit` install
the World of Warcraft stubs they need and load them after SignalKit;
`SetClosesAddonScopes` writes `LifecycleKit.CLOSES_ADDON_SCOPES` onto the
loaded facade with `rawset`, or removes it to model a LifecycleKit older than
0.6.0.

All executable specs use Busted's `*_spec.lua` convention and are discovered through the repository package-aware test runner.
