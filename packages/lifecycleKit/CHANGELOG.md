# Changelog

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
