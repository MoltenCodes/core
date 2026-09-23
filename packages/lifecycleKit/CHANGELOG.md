# Changelog

## 0.6.0 — 2026-09-23

- Added `LifecycleKit.CLOSES_ADDON_SCOPES`, the read-only set of package ids whose addon scopes (for `signalKit`, the addon bus) shutdown closes: `timerKit`, `schedulerKit`, `eventKit`, `hookKit`, `commandKit`, `commKit`, `signalKit`. It is the contract the scope-owning Kits read to learn that LifecycleKit closes their addon scopes at logout; a revision without the field closes none as far as a reader is concerned, and the Kit then arranges the closing itself. With TimerKit 0.6.0, SchedulerKit 0.8.0 and EventKit 0.7.0, an addon scope closes at logout whatever revisions are paired, where pairing TimerKit 0.5.0 or SchedulerKit 0.6.0/0.7.0 with a LifecycleKit older than 0.5.0 used to leave it open. LifecycleKit 0.6.0 pairs with any revision of the other Kits.
- The view refuses every write, including an overwrite of an existing entry, and hides its metatable; it is read with ordinary indexing. Documented under "Addon-scope capability" in `docs/API.md`.
- Implementation revision 13. The state schema is unchanged: the capability set and its view live in `_state.addonScopeCapabilities`, seeded into older state and rewritten on every bootstrap, so every copy publishes the same table. `CLOSES_ADDON_SCOPES` joins the public-surface check, so a newer copy without it is refused. An upgrade from revision 12 replaces its host watchers like the older ones.
- Specs: new `Capabilities_spec.lua` (published, listed, read-only, one table across reloads, seeded into older state, and a cross-check that it names exactly the packages shutdown calls into); `Bootstrap_spec.lua` refuses a newer revision without the field; `OwnedScopes_spec.lua` covers the upgrade from revision 12 as well.
- `LifecycleKit` API generation 1 is unchanged; the addition is compatible.

## 0.5.0 — 2026-09-23

- The dependency between LifecycleKit and TimerKit / SchedulerKit is inverted (design constitution, principle 4b). TimerKit 0.5.0 and SchedulerKit 0.6.0 no longer require LifecycleKit and no longer subscribe their addon scopes to its shutdown; LifecycleKit now calls into them. Both are declared under `optionalDependencies` and found through `Registry:Find("timerKit", 1)` and `Registry:Find("schedulerKit", 1)` at shutdown, with the same method-presence check as the other optional Kits.
- Shutdown gains two steps, placed first among the addon-owned scopes: `TimerKit:CloseAddonScopes(addonName)`, then `SchedulerKit:CloseAddonScopes(addonName)`, so no timer fires and no job runs into event listeners, hooks or subscribers that are being torn down. The documented order, which is also the first-error precedence, is now TimerKit, SchedulerKit, EventKit, HookKit, CommandKit, CommKit, SignalKit bus. Halted addons have their timer and scheduler scopes closed at logout like the rest.
- A TimerKit or SchedulerKit revision without `CloseAddonScopes` (TimerKit before 0.5.0, SchedulerKit before 0.6.0) closes its addon scopes itself, as before; the step then does nothing and shutdown is otherwise unchanged.
- Implementation revision 12. The state schema is unchanged; an in-place upgrade from revisions 7 to 11 replaces the inherited host watchers as before, because none of those revisions' logout handlers closes a timer or scheduler scope.
- Specs: `OwnedScopes_spec.lua` now carries the shutdown integration that used to live in the TimerKit and SchedulerKit suites (timer and scheduler scopes closed at logout, after shutdown callbacks and before the event scope, for halted addons too), plus older TimerKit and SchedulerKit revisions without `CloseAddonScopes`, the extended failure order, and the upgrade from revision 11.
- Limits (design constitution, principle 4a). Added `LifecycleKit:SetLimits{ maxDependencies, defaultCombatQueueLimit }`, `LifecycleKit:GetLimits()` and the `LifecycleKit.UNBOUNDED` sentinel. `maxDependencies` (default 16, the former fixed constant) bounds `DependsOn`; `defaultCombatQueueLimit` (default 64) is the combat-queue limit new instances start with. Both accept `UNBOUNDED`, because each list is the declaring addon's own. `SetLimits` validates the whole table at the caller's line before applying any of it; `GetLimits` returns a fresh table. `Instance:SetCombatQueueLimit` accepts `UNBOUNDED` too, and an unbounded queue still reclaims cancelled slots as it grows. The sentinel lives in package state (`_state.unbounded`) so every copy publishes the same table, and `UNBOUNDED`, `SetLimits` and `GetLimits` join the public-surface check. An upgrade seeds the defaults into older state. ModuleKit already reads `maxDependencies` through `GetLimits` when present. New `Limits_spec.lua`; documented under "Limits" in `docs/API.md`.
- `LifecycleKit` API generation 1 is unchanged; the additions are compatible.

## 0.4.4 — 2026-09-23

- Fixed: the `OnDependencyHalted` replay kept delivering after its own callback ended the subscription. A subscriber that halts its addon in response (the pattern the README shows) was still told about the next already-halted dependency, although a halted addon is documented as hearing nothing more. The replay now stops once the subscription is disconnected, exactly as a dispatch does. New spec in `Halt_spec.lua`.
- An in-place upgrade from revision 10 replaces its shared host watchers, as the upgrades from revisions 7 to 9 do; the schema-3 upgrade spec now runs for each of the four.
- Documentation: `docs/API.md` now counts all five owned scopes closed at shutdown (it still said "three" in two places) and lists the CommandKit and CommKit scopes among what a halted addon keeps until logout.
- Implementation revision 11. Schema 3 and API generation 1 are unchanged.

## 0.4.3 — 2026-09-23

- Shutdown now also closes the addon's canonical CommKit scope (`CommKit:CloseAddonScopes(addonName)`), after the CommandKit scope and before the SignalKit bus. The order is now EventKit scope, HookKit scope, CommandKit scope, CommKit scope, SignalKit bus; every step runs, and the first failure wins in that order. CommKit already closes that scope from its own `OnShutdown` subscription; this step pins it to its place in the order, and `false` (already closed, or no scope) is a normal result.
- CommKit is an optional dependency (`optionalDependencies`), found through `Registry:Find("commKit", 1)`. Without it, or with a CommKit that has no `CloseAddonScopes`, shutdown is unchanged.
- An in-place upgrade from revision 9 replaces its shared host watchers, as the upgrades from revisions 7 and 8 do; the upgrade spec now runs for each of the three.
- New specs in `OwnedScopes_spec.lua` against the real CommKit: a scoped prefix registration is gone after logout; a CommKit without `CloseAddonScopes` leaves shutdown unchanged; a comm-scope failure wins over a bus failure. The failure-order spec covers all five steps. The test environment loads CommKit and its remaining dependencies after the chain (`LoadCommKit`), because CommKit requires LifecycleKit.
- Implementation revision 10. API generation 1 is unchanged.
- Specs only, after EventKit 0.5.1 stopped recording a closed scope for an addon that never asked for one (no executed-code change here, so no version or revision change): the shutdown specs now create the EventKit scope they check, and the "never asked" case asserts that nothing is recorded.

## 0.4.2 — 2026-09-23

- Shutdown now also closes the addon's canonical CommandKit scope (`CommandKit:CloseAddonScopes(addonName)`), after the HookKit scope and before the SignalKit bus, so slash commands registered through `CommandKit:ForAddon` go inert at logout. The order is now EventKit scope, HookKit scope, CommandKit scope, SignalKit bus, and the first failure wins in that order. A halted addon's CommandKit scope is closed at logout too.
- CommandKit is an optional dependency (`optionalDependencies`), found through `Registry:Find("commandKit", 1)`. Without it, or with a CommandKit that has no `CloseAddonScopes`, shutdown is unchanged; `false` (the addon never had a scope) is a normal result.
- An in-place upgrade from revision 8 replaces its shared host watchers, as the upgrade from revision 7 already did.
- Three new specs in `OwnedScopes_spec.lua` against the real CommandKit (a scoped command is inert after logout; a CommandKit without `CloseAddonScopes` leaves shutdown unchanged; a command-scope failure wins over a bus failure), and the failure-order spec now covers all four steps. The test environment models `SlashCmdList` and the `SLASH_*` globals.
- Implementation revision 9. API generation 1 is unchanged.

## 0.4.1 — 2026-09-23

- Shutdown now also closes the addon's canonical HookKit scope (`HookKit:CloseAddonScopes(addonName)`) and its SignalKit bus (`SignalKit:CloseAddonBus(addonName)`), after the EventKit scope. Hooks made through `HookKit:ForAddon` and subscriptions on the bus named after the addon, including its scopes' subscriptions, need no teardown code. Neither Kit observes shutdown itself; this is the second half of the two-step both document.
- Order: EventKit scope, HookKit scope, SignalKit bus. Event listeners go first so no host event fires into hooks or subscribers being torn down; the bus goes last because other addons' shutdown paths may still publish on it, and publishing on a closed bus is a silent no-op. Every step runs even when an earlier one failed, and the first failure wins in that order, after the combat queue and the shutdown callbacks. A halted addon has all three closed at logout.
- HookKit is an optional dependency (`optionalDependencies` in the manifest), found through `Registry:Find("hookKit", 1)` at shutdown. Without it, or with a HookKit that has no `CloseAddonScopes`, shutdown is unchanged. A SignalKit without `CloseAddonBus` is skipped the same way; `false` from `CloseAddonBus` (no bus) is a normal result.
- An in-place upgrade from revision 7 replaces the shared host watchers it inherited, because they would keep calling revision 7's logout handler. Schema 3 is unchanged.
- Nine new specs in `OwnedScopes_spec.lua`, against the real HookKit and SignalKit: a scoped hook and a bus subscription are gone after logout, shutdown callbacks still see both, a halted addon's scopes close at logout, an absent HookKit and one without `CloseAddonScopes` leave shutdown unchanged, the failure order, and the upgrade from revision 7.
- Implementation revision 8. API generation 1 is unchanged; nothing public was added.

## 0.4.0 — 2026-09-23

- Added the combat gate. `LifecycleKit:IsInCombat()` reads one lockdown state shared by every addon, kept by one package-level pair of watchers on `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` and seeded from `InCombatLockdown()` when the package loads, when the watchers are installed and at `PLAYER_LOGIN`, because the host may load an addon mid-combat.
- Added `instance:WhenOutOfCombat(callback)`: runs at once out of combat, otherwise queues the call, first in first out, until the next `PLAYER_REGEN_ENABLED`. The queue is bounded per addon (64 by default, `SetCombatQueueLimit` / `GetCombatQueueLimit`); beyond it the call is refused with `nil, "full"` and nothing queued is dropped. The returned `LifecycleKit.DeferredCall` has `Cancel()` and `IsPending()`; cancelling flags the slot and allocates nothing, and the queue array is reused across combats. Queued calls run under the phase machinery's first-error policy. Shutdown and halt close the queue and call each pending callback with `(instance, false, "shutdown")` or `(instance, false, "halted")`.
- Added `instance:OnCombatStart(callback)` and `instance:OnCombatEnd(callback)`, repeating subscriptions delivered after the shared state flips, only to addons that have reached `loaded` and are not halted or shut down. Loading is synchronous, so no combat event falls between an addon's file execution and its `ADDON_LOADED`; a load-on-demand addon loaded mid-combat receives `OnCombatEnd` without a matching `OnCombatStart` and should read `IsInCombat()` in `OnLoaded`. A combat transition allocates nothing once the subscriptions exist.
- Added the `halted` state. `instance:Halt(reason)` declares the addon non-functional for the rest of the session: unreached phases become unreachable and their pending callbacks are disconnected, the combat queue is closed, and `OnHalted(callback)` subscribers run, replayed for late subscribers like the phase subscriptions. `IsHalted()` and `GetHaltReason()` report it and `GetState()` returns `"halted"`. There is no resume in API 1.
- Added `instance:DependsOn(otherAddonName)` (at most 16 per addon) and `instance:OnDependencyHalted(callback)`: when a declared dependency halts, the dependent receives `(instance, dependencyName, reason)`, at once when the dependency has already halted.
- Shutdown now closes the combat queue before the shutdown callbacks run; the first-error precedence follows that order (queue, shutdown callbacks, EventKit scope).
- Package state schema 3. An in-place upgrade from an older revision adds the combat flag, the instance list (inherited instances in name order, later ones in creation order) and the new per-instance fields, and replaces the older revision's shared host watchers, which would otherwise keep calling handlers that know nothing of halting or of the combat queue.
- New host surface: `InCombatLockdown` (optional; absent means never in combat) and the `PLAYER_REGEN_DISABLED` / `PLAYER_REGEN_ENABLED` events.
- Implementation revision 7. API generation 1 is unchanged: every addition is new surface, and a newer revision is now expected to publish it.

## 0.3.1 — 2026-09-23

- Shutdown now closes the addon's canonical EventKit scope (`EventKit:ForAddon(addonName)`) after the addon's shutdown callbacks have run, through `EventKit:CloseAddonScopes`. EventKit cannot observe shutdown itself because it sits below LifecycleKit in the load order; this is the second half of the two-step its documentation describes, and an addon that connects events through its scope no longer writes any teardown for them.
- An EventKit revision that predates scopes has no `CloseAddonScopes`; shutdown then behaves exactly as before. A failure while disconnecting is captured, after every addon's lifecycle has advanced, under a first-error-wins policy: a shutdown callback error from the same addon takes precedence, and the scope error is re-raised only when no callback failed.
- A scoped `PLAYER_LOGOUT` listener connected after this package's logout watcher still runs: the watcher closes the scope inside EventKit's dispatch, and EventKit 0.4.1 (revision 6) defers the disconnects until that dispatch returns. A spec connects such a listener after `LifecycleKit:ForAddon` and checks it runs once and the scope is closed afterwards. No LifecycleKit code changed for this.
- Implementation revision 6. The executed shutdown path changed; the bootstrap specs cover the in-place upgrade.
- No public API change. `LifecycleKit` API generation 1 is unchanged.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- The same-revision repair path — re-running this file against the stable facade when an earlier attempt committed the Registry revision but failed while installing the shared host watchers — is now expressed as the `resume` hook Registry calls, rather than as bespoke branching here.
- Implementation revision 5. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `LifecycleKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 39 annotation lines became 86. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Moved the LuaCATS declarations into a "Public types" section at the top of the file and off the prototype locals, added the missing `LifecycleKit` facade class, and gave `LifecycleKit.Instance` and `LifecycleKit.Subscription` their full method lists.
- Added the `LifecycleKit.PhaseCallback` alias and the `LifecycleKit.ErrorRecord` class, which the phase machinery passes around and previously documented as bare `table`.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- Implementation revision 4.
- Raised `LifecycleKit:ForAddon` argument errors at level 2 instead of level 3. `ForAddon` is the frame the consumer calls, so level 3 pointed one frame past the calling addon code.
- Stopped `OnLoaded`, `OnReady` and `OnShutdown` from tail-calling their shared implementation. Lua 5.1 drops the calling frame on a tail call, which collapsed one level and made an invalid-callback error report a position outside the addon that raised it. All four argument errors now report the caller's own file and line, and specs pin those positions.
- Unified callback-error reporting across the replay and the dispatch path. A callback invoked synchronously because its phase had already occurred is now captured and re-raised the same way a dispatched callback is, so a subscriber sees the original Lua error object unchanged regardless of which path its subscription took.
- Removed the pre-1.0 compatibility machinery: the revision-1 state migration and the revision-2/revision-3 dual error-capture protocol. No revision before this one was ever published, so nothing could rely on them. Phase-callback failures are captured through the single `_phaseCaptures` protocol, and the retired `_phaseErrors` slot is released from every carried-over instance during an in-place upgrade.
- Documented exact addon-name matching as the contract, with the reason, rather than normalising case.
- Documented that `PLAYER_ENTERING_WORLD` is a non-goal: `ready` means loaded and logged in.
- Adapted the phase-error specs to EventKit's listener isolation: an error LifecycleKit re-raises from inside a host event dispatch is now reported through the host error handler rather than escaping the delivery, so the specs observe that handler instead of catching the error at the emit site.

## 0.1.3 — 2026-09-22

- No runtime behaviour change. Revision 3 still describes the shipped implementation.
- Collapsed the three identical corrupted-state branches in package bootstrap into one check. Package state that the running revision cannot reuse still fails with the same message, at the same error level, for the same inputs.
- Split the combined SignalKit/EventKit bootstrap test in two and cleared the failed-load marker Lua 5.1 leaves in `package.loaded` between attempts. The EventKit dependency guard is now genuinely exercised; it previously only observed "loop or previous error loading module" and never reached the guard it claimed to cover.
- Made the test-support `CreateFrame` stub raise a plain error when asked for a frame type it does not model.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.2

- Renamed the package identity and Lua facade from `lifecycle` / `Lifecycle` to `lifecycleKit` / `LifecycleKit` as part of the framework-wide Kit naming convention.

- Kept phase dispatch running when multiple callbacks fail during the same lifecycle phase.
- Preserved the first callback error while still delivering every already-pending phase subscriber exactly once.
- Made same-revision bootstrap retry missing shared watcher setup after an interrupted live upgrade or host-registration failure.
- Reconciled loaded instances when a one-shot login/shutdown phase passed while a shared watcher was temporarily missing.
- Preserved arbitrary Lua error objects, including `false` and `nil`, during phase error aggregation.
- Kept pending revision-2 phase subscription closures compatible with revision-3 in-place upgrades through a dual error-capture protocol.
- Disconnected pending `loaded`/`ready` subscriptions when shutdown makes those phases impossible, preventing stale connected handles and retained callback closures.

## 0.1.1

- Coordinated `PLAYER_LOGIN` and `PLAYER_LOGOUT` once per LifecycleKit package instead of once per addon instance.
- Prevented one addon lifecycle callback error from starving other addon lifecycle instances of global login/shutdown transitions.
- Added live revision-1 state migration to shared package-level event watchers.

## 0.1.0

- Added per-addon lifecycle identity with `LifecycleKit:ForAddon`.
- Added `loading`, `loaded`, `ready`, and `shutdown` states.
- Added replay-aware `OnLoaded`, `OnReady`, and `OnShutdown` subscriptions with callback-failure isolation.
- Added late-load detection through `C_AddOns.IsAddOnLoaded` and `IsLoggedIn` when available.
- Added Registry, SignalKit, and EventKit integration.
