# Changelog

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
