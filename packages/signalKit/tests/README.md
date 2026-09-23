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
  without state, buses carried into a newer revision, and refusal to reinterpret
  a newer revision's state;
- runtime API/revision metadata consistency with the package manifest.

All executable specs use Busted's `*_spec.lua` convention and are discovered through the repository package-aware test runner.
