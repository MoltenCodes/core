# EventKit Tests

The EventKit suite treats WoW registration lifetime and SignalKit-backed dispatch semantics as public contract.

Coverage includes dependency/bootstrap behavior, lazy registration, final-listener unregistration, payload forwarding, listener mutation, one-shot subscriptions, unit-filter normalization, host registration failures, embedded-copy reconciliation, and manifest/runtime metadata consistency.

`EventKitTestEnv.lua` supplies a narrow fake WoW Frame boundary. Production APIs are not added solely for tests.
