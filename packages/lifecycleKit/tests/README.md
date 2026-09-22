# LifecycleKit Tests

The LifecycleKit suite covers state transitions, late subscribers, load-on-demand catch-up, callback error isolation, bootstrap/reload behavior, validation, and dependency integration.

WoW APIs are simulated by `support/LifecycleKitTestEnv.lua`; production source does not expose test-only hooks.

Additional regression coverage includes multiple callback failures within one phase, arbitrary Lua error objects, same-revision watcher recovery, and missed-login catch-up after interrupted bootstrap.
