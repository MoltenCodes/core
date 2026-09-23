# LifecycleKit Tests

The LifecycleKit suite covers state transitions, late subscribers, load-on-demand catch-up, callback error isolation, bootstrap/reload behavior, validation, and dependency integration.

WoW APIs are simulated by `support/LifecycleKitTestEnv.lua`; production source does not expose test-only hooks.

Additional regression coverage includes multiple callback failures within one phase, arbitrary Lua error objects, same-revision watcher recovery, and missed-login catch-up after interrupted bootstrap.

Argument-error positions are pinned: each spec asserts the exact `file:line` the error reports, so a stray tail call or a wrong `error` level fails the suite instead of passing unnoticed.

The combat gate and the halted state have their own suites, `CombatGate_spec.lua` and `Halt_spec.lua`. The shared fixture does not model `InCombatLockdown`, so `support/LifecycleKitTestEnv.lua` installs it on top of the fixture and removes it again on `Reset`; `EnterCombat` and `LeaveCombat` send the two `PLAYER_REGEN_*` events in the order the client does.
