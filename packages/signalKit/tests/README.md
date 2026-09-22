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
- Registry bootstrap and duplicate embedding;
- runtime API/revision metadata consistency with the package manifest.

All executable specs use Busted's `*_spec.lua` convention and are discovered through the repository package-aware test runner.
