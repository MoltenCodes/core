# LifecycleKit Tests

The LifecycleKit suite covers state transitions, late subscribers, load-on-demand catch-up, callback error isolation, bootstrap/reload behavior, validation, the combat gate, the halted state, the scopes closed at shutdown, and dependency integration.

WoW APIs are simulated by the shared fixture and `support/LifecycleKitTestEnv.lua`; production source does not expose test-only hooks. `NewPackage` loads the core and both parts, `NewCore` the core alone, and `LoadParts` adds the parts later; `Module(name)` returns a module of the chain by name. The chain loads SchemaKit only while CommandKit's manifest requires it.

| Spec | Covers |
|---|---|
| `LifecycleKit_spec.lua` | the phase machine: `loading`, `loaded`, `ready`, `shutdown` |
| `Subscriptions_spec.lua` | phase subscriptions, replay, `Disconnect` / `IsConnected` |
| `LateLoad_spec.lua` | load-on-demand catch-up through `IsLoggedIn` and `IsAddOnLoaded` |
| `Isolation_spec.lua` | one addon's failing callback does not starve another of a global phase |
| `Errors_spec.lua` | argument validation, pinned `file:line` error positions, error-object propagation |
| `Bootstrap_spec.lua` | registration, duplicate embedding, newer-revision refusal (including one without `CLOSES_ADDON_SCOPES`), watcher repair, refusal of state below the upgrade floor, and the upgrade from the previous revision (checked against the table-key limit refusal) |
| `SecretValues_spec.lua` | secret addon names, halt reasons and limits refused at the caller before a comparison; a secret `CLOSES_ADDON_SCOPES` write key named by a placeholder; dot calls with a secret receiver; the probe kept from load, and a non-function `issecretvalue` global ignored |
| `CombatGate_spec.lua` | the CombatGate part: `IsInCombat` (including its value inside `OnReady` at `PLAYER_LOGIN`), `WhenOutOfCombat`, `OnCombatStart` / `OnCombatEnd`, notice lists and the combat queue created on first use |
| `Halt_spec.lua` | the Halt part: `Halt`, `OnHalted`, `DependsOn`, `OnDependencyHalted`; the documented `_halted` field set before the first `OnHalted` subscriber |
| `EventScopes_spec.lua` | closing the addon's EventKit scope at shutdown, its combat-log listeners included |
| `OwnedScopes_spec.lua` | closing the TimerKit, SchedulerKit, HookKit, CommandKit and CommKit scopes and the SignalKit bus at shutdown, their order and first-error precedence, and older TimerKit and SchedulerKit revisions without `CloseAddonScopes` |
| `Capabilities_spec.lua` | `CLOSES_ADDON_SCOPES`: published, listed, read-only (a table key named by its type without running its `__tostring`), one table across reloads, required in the state an upgrade takes over, and exactly what shutdown closes |
| `Limits_spec.lua` | `SetLimits` / `GetLimits` (the shared `limits` block), `UNBOUNDED` for `maxDependencies` and the combat queue, atomic validation at the caller's line, a table limit key named by its type without running its `__tostring`, limits kept across a reload |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |
| `Parts_spec.lua` | the core without its parts (every stub at the caller's line, `HasPart`, phases, `OnHalted` that never fires, limits), parts loaded after the core or twice (one combat watcher per event either way), a higher CombatGate revision replacing the older one's watchers, and the own phase lists (order, a subscription made or disconnected during a delivery, isolation) |
| `Upgrade_spec.lua` | the in-place upgrade from revision 18 (`tests/fixtures/LifecycleKit-revision18.lua`, a byte copy) with and without the parts: its instances, phase subscriptions and their handles, combat queues, notices, dependencies and halts; and the core loading, replaying and shutting down with no SignalKit registered |
| `Conformance_spec.lua` | the shared Kit conformance suite (`tests/support/KitConformance.lua`) on the core: manifest, limits, receivers, a secret `ForAddon` name, and the upgrade from the previous revision |

Additional regression coverage includes multiple callback failures within one phase, arbitrary Lua error objects, same-revision watcher recovery, and missed-login catch-up after interrupted bootstrap.

Argument-error positions are pinned: each spec asserts the exact `file:line` the error reports, so a stray tail call or a wrong `error` level fails the suite instead of passing unnoticed.

The shared fixture does not model `InCombatLockdown`, so `support/LifecycleKitTestEnv.lua` installs it on top of the fixture and removes it again on `Reset`; `EnterCombat` and `LeaveCombat` send the two `PLAYER_REGEN_*` events in the order the client does. The same file models the slash-command globals CommandKit writes (`RunSlash`) and loads CommKit after the chain (`LoadCommKit`), with TimerKit, SchedulerKit and PoolKit, which CommKit requires; it is kept out of the chain so the plain suites load without it.
