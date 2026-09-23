# Changelog

## 0.5.1 — 2026-09-23

- Fixed an explicit `Disable()` before `ready` being overridden. The LifecycleKit `ready` phase ran the same pass as the addon's `EnableAll()`, which set every module's intent to wanted, so a module that called `self:Disable()` in `OnInitialize` was enabled at login. The lifecycle-driven pass now states no intent and skips modules that are not wanted, recording their hard dependents as blocked by them; only an `EnableAll()` the addon calls itself re-enables them.
- Recovery of blocked dependents no longer builds the dependency graph on every targeted `Enable`/`Activate`: a linear scan returns early when no module is blocked.
- Two regression specs: a module disabled in `OnInitialize` stays off through login and is enabled by a later explicit `EnableAll`; a targeted `Enable` with nothing blocked does not build the graph.
- Implementation revision 7.

## 0.5.0 — 2026-09-23

- Added module scopes. Every module carries `module.scope`, whose `Timers`, `Events` and `Jobs` fields are a TimerKit, EventKit and SchedulerKit scope created on first read. `Disable`, `DisableAll` and terminal shutdown close every scope the module created, so a module needs no `OnDisable` to release what it registered; a failed `OnEnable` releases what it registered before failing, and shutdown releases a module's scopes even when its `OnDisable` fails. The fields are readable from the start of `OnEnable` until the module is disabled and raise at the reading line otherwise. A module that never reads its scope creates nothing.
- The three Kits stay optional: each is resolved through `Registry:Find` (with `Registry:Get` as the fallback on a Registry older than revision 7) and a field reads as `nil` when its Kit is not loaded or has no `CreateScope`. That capability check also keeps ModuleKit working beside an EventKit revision that predates `EventKit:CreateScope()`. ModuleKit's manifest dependencies are unchanged.
- Added intent versus fact. A module records `wanted` (`true` from creation; changed only by `Enable`/`Disable` on the module itself and by `EnableAll`/`DisableAll`) apart from `actual`, and the dependency that blocks a wanted module. A module blocked by its dependency — a failed dependency in `EnableAll`, under the `strict` policy or inside an `automatic` targeted `Enable`, or a dependency whose `Disable` took it down in an `automatic` cascade — keeps `wanted = true` and is enabled automatically, in graph order, when that dependency is enabled again (its own `Enable`, `Activate` or `EnableAll`). A cascade is a block, not a change of intent. An explicit `Disable` on the module itself wins over that recovery. New `module:GetEnableState()` returns `{ wanted, actual, blockedBy }`.
- An in-place upgrade backfills the new per-module fields on modules an older revision created (intent is derived from state) and keeps them unchanged on modules that already carry them. The shared scope metatable lives in `_state`, so scopes created by an older copy use the newer lookup after an upgrade.
- Documented both features in `docs/API.md` and `docs/INTERNALS.md`.
- 22 new specs in `Scope_spec.lua` and `EnableState_spec.lua`, one of them against the real `EventKit:CreateScope()`.
- Implementation revision 6. `ModuleKit` API generation 1 is unchanged; the additions are additive.

## 0.4.0 — 2026-09-22

- `installAddonSubscriptions` no longer keeps subscribing after the container has been shut down. LifecycleKit replays a phase it has already reached synchronously, inside the `subscribe()` call and before it returns the handle, so a module hook running in that replay can reach container shutdown. The loop tested `_shutdown` exactly once, before the first subscription, and then went on to subscribe the remaining phases: a container that believed it was shut down was left listening for `ready`, and would have run `EnableAll` on it. The shutdown test is now repeated after every `subscribe()`, and a handle produced by a call the shutdown happened inside is disconnected rather than stored.
- The loop also re-reads `rawget(addon, "_subscriptions")` for each phase instead of holding the table it captured before the first call, so a handle can never be filed in a table the container has since replaced, where nothing would ever disconnect it.
- Extracted `disconnectSubscriptionHandle` from `disconnectAddonSubscriptions`, which is what both paths now use to release a handle.
- The deferred catch-up queue is drained with an index cursor instead of `table.remove(pending, 1)`. Shifting every remaining entry down a slot per module made a flush quadratic in the number of modules waiting; the queue is now walked once and cleared at the end. Modules queued while the flush runs are still picked up by the same pass, and the order modules are caught up in is unchanged.
- Implementation revision 5. Two regression specs: a replayed phase that shuts the container down leaves no live subscription behind, and a flush that catches five deferred modules up produces the same order as before.
- No public API change. `ModuleKit` API generation 1 is unchanged.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- The resume path that repairs a half-built shared runtime dispatch is now the `resume` hook Registry calls, and reads the inherited revision from the package's own `runtimeRevision` exactly as before.
- Implementation revision 4. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `ModuleKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 140 annotation lines became 314. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Moved the LuaCATS declarations into a "Public types" section at the top of the file and off the prototype locals, added the missing `ModuleKit` facade class, and gave `ModuleKit.Addon` and `ModuleKit.Module` their full method lists.
- Declared the definition table as `ModuleKit.Definition` instead of `table|nil`, so `CreateModule`'s second argument autocompletes and a misspelled field is reported by the language server as well as at runtime.
- Gave `Module:Inject` an `---@overload` for its map form, and replaced the `table` placeholders in the graph and container-pass helpers with the real module and container types.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- Implementation revision 3.
- Fixed an in-place upgrade re-enabling deliberately disabled modules. Re-installing lifecycle subscriptions made LifecycleKit replay `ready` into containers that had already received it, which ran `EnableAll` a second time out of package bootstrap. Each container now records the phases dispatched into it, an upgrade subscribes only to phases that have not been dispatched, and during an upgrade the lifecycle is probed directly as well, so a module hook can never run out of package bootstrap. A container created by an earlier revision has its dispatched set rebuilt from LifecycleKit.
- Deferred definition-table catch-up for a module created from a hook while a whole-container pass is running. Activating it mid-pass bypassed that pass's dependency-failure blocking; it is now caught up when the outermost pass finishes, with the same result as creating it immediately afterwards. `module:Activate()` stays immediate, because it is an explicit request rather than implicit catch-up.
- Replaced the topological sort's front removal and per-insertion full re-sort with a ready set kept sorted by descending creation order, consumed from its end and refilled by binary search. The emitted order is unchanged and is now pinned on a twelve-module fixture as well as the small ones.
- Documented that `EnableAll()` states a target for the whole container and therefore re-enables modules that were explicitly disabled, with the reason; kept the behaviour.
- Documented that `Inject` accepts provider and module names only, never the objects themselves.
- Documented that hooks must not yield: they run under `pcall`, and Lua 5.1 cannot suspend a coroutine across a C function.
- Added `docs/INTERNALS.md` and a contents block at the top of `ModuleKit.lua`.
- Adapted the lifecycle specs to EventKit's listener isolation: an error raised out of a phase dispatch is now reported through the host error handler instead of escaping the event delivery.

## 0.1.2 — 2026-09-22

- No runtime behaviour change. Revision 2 still describes the shipped implementation.
- Renamed the late-module ordering loop variable to `existingModule` so it no longer shadows the bootstrap-level `existing` local. The shadowing was harmless but made the two unrelated values hard to tell apart while reading the bootstrap.
- Made the test-support `CreateFrame` stub raise a plain error when asked for a frame type it does not model.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.1

- Made existing addon lifecycle subscriptions upgrade-safe through shared runtime dispatch and migrated revision-1 subscriptions without replacing addon/container identity.
- Added same-revision bootstrap recovery for incomplete runtime dispatch state.
- Preserved hard-dependency invariants when non-terminal `DisableAll()` encounters a dependent disable failure.
- Made terminal shutdown perform best-effort cleanup even when an inactive late module leaves the full graph invalid.
- Rejected late module definitions that would retroactively place a new module before an already-initialized module.
- Restricted targeted initialize/enable validation to the relevant hard-dependency closure so unrelated invalid modules do not block independent targeted operations.
- Tightened definition-table validation: unknown fields and sparse/mixed dependency arrays are rejected deterministically.
- Improved module-scoped provider cycle tracking so the same provider can legitimately resolve for different requesting modules during nested resolution.
- Strengthened public-surface, lifecycle-subscription, and requesting-module validation.

## 0.1.0

- Added addon-scoped module containers integrated with LifecycleKit.
- Added `automatic` and `strict` dependency policies.
- Added hard, optional, and ordering-only dependency graph constraints.
- Added deterministic topological initialization, enable, and reverse disable ordering.
- Added value, singleton, module-scoped, and transient dependency injection providers.
- Added provider-cycle and module-cycle detection with human-readable diagnostics.
- Added late-module activation and definition-table catch-up support.
- Added module failure/blocking diagnostics without permanent failed states.
