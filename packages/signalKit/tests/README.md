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
- limits: the `maxTopics` and `maxListeners` bus options with integers and
  `SignalKit.UNBOUNDED`, the first-statement rule on a shared bus,
  `SetLimits`/`GetLimits` for `maxBuses` with its 1024 ceiling and refused
  `UNBOUNDED`, refusal of invalid values at the calling line, atomic updates,
  and no eviction when a limit is lowered;
- named buses: sharing by name, the bus, topic and listener bounds, declared
  versus undeclared topics and `openTopics`, argument-count and validator
  refusal at the publishing line, secret refusal reasons, `Subscribe`,
  `SubscribeOnce`, `Unsubscribe` and `Topics`;
- bus dispatch semantics compared trace for trace with a raw signal;
- bus listener isolation through the host error handler on both the `xpcall`
  and the `securecallfunction` paths, and an allocation guard on steady-state
  `Publish`;
- bus scopes, `ForAddon` and `CloseAddonBus`;
- Registry bootstrap and duplicate embedding, the upgrade from a revision-3 copy
  without state, the upgrade from revision-4 state (sentinel and limits added),
  buses, set limits and the sentinel identity carried into a newer revision,
  and refusal to reinterpret a newer revision's state;
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
| `Bus_spec.lua` | buses, topic policy, subscriptions, bus dispatch semantics |
| `BusIsolation_spec.lua` | listener isolation on both paths, the `Publish` allocation guard |
| `BusScope_spec.lua` | bus scopes, `ForAddon`, `CloseAddonBus` |
| `Limits_spec.lua` | bus limit options, `UNBOUNDED`, `SetLimits`/`GetLimits`, refusal at the caller |
| `Bootstrap_spec.lua` | Registry bootstrap, duplicate embedding, revision upgrades, limits and sentinel carried |
| `Manifest_spec.lua` | runtime metadata against `package.manifest.json` |

All executable specs use Busted's `*_spec.lua` convention and are discovered through the repository package-aware test runner.
