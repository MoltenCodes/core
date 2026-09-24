# LifecycleKit Tests

The LifecycleKit suite covers state transitions, late subscribers, load-on-demand catch-up, callback error isolation, bootstrap/reload behavior, validation, the combat gate, the halted state, the scopes closed at shutdown, and dependency integration.

WoW APIs are simulated by the shared fixture and `support/LifecycleKitTestEnv.lua`; production source does not expose test-only hooks.

| Spec | Covers |
|---|---|
| `LifecycleKit_spec.lua` | the phase machine: `loading`, `loaded`, `ready`, `shutdown` |
| `Subscriptions_spec.lua` | phase subscriptions, replay, `Disconnect` / `IsConnected` |
| `LateLoad_spec.lua` | load-on-demand catch-up through `IsLoggedIn` and `IsAddOnLoaded` |
| `Isolation_spec.lua` | one addon's failing callback does not starve another of a global phase |
| `Errors_spec.lua` | argument validation, pinned `file:line` error positions, error-object propagation |
| `Bootstrap_spec.lua` | registration, duplicate embedding, newer-revision refusal (including one without `CLOSES_ADDON_SCOPES`), watcher repair, upgrades from revisions 3 and 6 and from the previous revision |
| `SecretValues_spec.lua` | secret addon names, halt reasons and limits refused at the caller before a comparison; dot calls with a secret receiver |
| `CombatGate_spec.lua` | `IsInCombat`, `WhenOutOfCombat`, `OnCombatStart` / `OnCombatEnd` |
| `Halt_spec.lua` | `Halt`, `OnHalted`, `DependsOn`, `OnDependencyHalted` |
| `EventScopes_spec.lua` | closing the addon's EventKit scope at shutdown, its combat-log listeners included |
| `OwnedScopes_spec.lua` | closing the TimerKit, SchedulerKit, HookKit, CommandKit and CommKit scopes and the SignalKit bus at shutdown, their order and first-error precedence, older TimerKit and SchedulerKit revisions without `CloseAddonScopes`, and the upgrades from revisions 7 to 12 |
| `Capabilities_spec.lua` | `CLOSES_ADDON_SCOPES`: published, listed, read-only, one table across reloads, seeded into older state, and exactly what shutdown closes |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `UNBOUNDED` for `maxDependencies` and the combat queue, atomic validation at the caller's line, seeding on upgrade |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |

Additional regression coverage includes multiple callback failures within one phase, arbitrary Lua error objects, same-revision watcher recovery, and missed-login catch-up after interrupted bootstrap.

Argument-error positions are pinned: each spec asserts the exact `file:line` the error reports, so a stray tail call or a wrong `error` level fails the suite instead of passing unnoticed.

The shared fixture does not model `InCombatLockdown`, so `support/LifecycleKitTestEnv.lua` installs it on top of the fixture and removes it again on `Reset`; `EnterCombat` and `LeaveCombat` send the two `PLAYER_REGEN_*` events in the order the client does. The same file models the slash-command globals CommandKit writes (`RunSlash`) and loads CommKit after the chain (`LoadCommKit`), with TimerKit, SchedulerKit and PoolKit, which CommKit requires; it is kept out of the chain so the plain suites load without it.
