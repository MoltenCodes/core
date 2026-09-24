# Changelog

## 0.4.3 — 2026-09-24

- `docs/API.md` gained a method reference: the return values, the exact error messages and the cost of every method and constructor, and which methods count as mutating inside a lifecycle callback.
- `docs/API.md` and `docs/INTERNALS.md` describe generations, the capacity options and the embedded-copy upgrade in their current form instead of narrating earlier revisions.
- New `Allocation_spec.lua` proves the steady-state promise in `docs/INTERNALS.md`: acquiring and releasing through a generic, a table and a capped pool, and attaching and cascading a child once the link maps exist, allocate nothing.
- New spec for `"release is already in progress for this object"`, reached when a child's `reset` releases the parent whose release is running. The ownership and `strictReset` specs now assert the message each refusal carries rather than only that one was raised, and the property spec lost a branch its random walk could never take.
- `Property_spec.lua` draws its random walk from the high bits of an exact Park-Miller generator. The previous power-of-two-modulus generator overflowed double precision and its low bits, which chose each step, cycled within a few steps.
- No runtime behaviour change; implementation revision 6 is unchanged.

## 0.4.2 — 2026-09-23

- Fixed the lazy upgrade of pools built by revision 1. Revision 2 added `_callbackDepth`, `_maxActiveWarning` and `_activeWarned` to the pools it built but never back-filled them, so the first `Acquire` on a revision-1 pool raised "attempt to compare number with nil". `upgradePool` now fills each of the three when it is absent and leaves a revision 2 or 3 pool's own values alone.
- Pools no longer carry a `_strict` field. No revision ever read it: strict diagnostics are the presence of the weak `_released` table.
- `docs/API.md`: the list of methods a lifecycle callback may not call on its own pool now names every mutating method, `Owns` and `Close` describe parked objects and waiting requests, and the cascading-release section states what a failing child or parent `reset` leaves behind.
- Implementation revision 6. Two new bootstrap specs cover the revision-1 pool upgrade and an in-place upgrade from revision 5 that keeps a waiting request, a child link and a parked release working, with the `OnFinished` hook revision 5 installed completing through revision 6.

## 0.4.1 — 2026-09-23

- The default pool generation is now a fixed `1`, and pools built by a revision older than generations take `1` as well. 0.4.0 defaulted to PoolKit's own revision, so behaviour depended on which embedded copy won. Pools created by 0.4.0 keep the generation they were given; the shared state's unused `legacyGeneration` field is left in place.
- Added `Pool:GetMaxCreated()` and `Pool:SetMaxCreated(n)`. Retired stale objects still count against `maxCreated`, so raising the generation of a capped pool could exhaust it permanently; the cap can now be raised (never lowered), a `maxRetained` that equalled the old cap follows it, and waiting requests are served at once. `docs/API.md` states the interaction next to `generation`.
- Fixed the error a release re-raises when a child's release and the parent's `reset` both fail: the first error, the child's, now wins, as `docs/API.md` promised; the parent is still rolled back to borrowed.
- Documented the `ReleaseAfter` caveats: play the animation before calling it; looping, paused and stopped groups never fire `OnFinished`; and a later `SetScript("OnFinished", …)` replaces PoolKit's hook undetectably, so set the group's own script before the first `ReleaseAfter`.
- Implementation revision 5. Five new specs cover `SetMaxCreated` (recovery after a generation raise, waiting requests, an explicit retention bound, refusals) and the first-error rule; the default-generation and upgrade specs now expect `1`.

## 0.4.0 — 2026-09-23

- Added generations. Every pool has one — `generation` on `New` and `NewTablePool`, defaulting to the PoolKit revision that created the pool — and `Pool:GetGeneration()` / `Pool:SetGeneration(n)`. Raising it destroys retained objects of older generations at once and destroys, instead of retaining, borrowed ones when they come back, so an object built by a superseded factory is never handed out again after an in-place upgrade. Lowering it is refused. Stamps live in a weak-keyed side table and never touch the object; a pool that never raises its generation writes none.
- Added pools for objects the host can never free, such as Frames. `maxCreated` caps factory calls over the pool's life and makes `maxRetained` default to the cap; `maxActive` caps objects out at once. At capacity `Acquire()` returns `nil, "exhausted"`, and `Acquire(onAvailable)` either queues the request and returns `nil, "waiting"` or refuses it with `nil, "queueFull"`. The queue is a ring of `maxWaiting` slots allocated once with the pool, so it never grows and allocates nothing per acquire; freed capacity goes to the oldest request first. Added `Pool:GetWaitingCount()` and `Pool:CancelWaiting(callback)`; `Close()` fails queued requests with `"closed"`. Without the new options `Acquire` behaves exactly as before.
- Added cascading release: `Pool:AttachChild(parent, child, childPool)` and `Pool:DetachChild(child)`. Releasing a parent releases its children first, most recently attached first, grandchildren included; a child released on its own leaves its parent in constant time, and a cycle terminates.
- Added deferred release: `Pool:ReleaseAfter(object, animationGroup)` parks an object until the group's `OnFinished` fires, hooking each group once ever, and releases at once when the group is not playing. `Release` completes a parked release early and `Close` completes all of them. Added `Pool:GetParkedCount()`. PoolKit still has no WoW or scheduler dependency: it calls only the group's `HookScript` and `IsPlaying`.
- Failures on paths no caller can observe — a queued callback, the factory while serving the queue, a release completed by `OnFinished` — are reported through the host error handler.
- Implementation revision 4; shared state schema 2. Pools built by an older revision cannot be enumerated, so every pool method upgrades such a pool the first time it touches it, keeping its objects and counters and taking the previous revision as its generation. A bootstrap spec loads revision 4 over hand-built revision-3 state and pools and retires their objects through `SetGeneration`. Forty-two new specs cover generations, the creation cap, the live limit, the waiting ring (FIFO, wrap-around, cancellation, refusal, close, failures, zero allocation), cascading and deferred release, and the upgrade.
- Added a table-of-contents header to `src/PoolKit.lua`.
- `PoolKit` API generation 1 is unchanged; the additions are compatible.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- Implementation revision 3. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `PoolKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 50 annotation lines became 171. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed the LuaCATS types to `PoolKit`, `PoolKit.Pool`, `PoolKit.NewOptions` and `PoolKit.CommonOptions`, and added the `PoolKit.Factory` and `PoolKit.ObjectCallback` aliases.
- Annotated every public method and internal helper; the twelve accessor methods on a pool previously had no annotation at all.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- Documented that `Acquire()` never cleans: a pool constructed without a `reset` callback hands back objects still carrying the previous borrower's state. Added the opt-in `strictReset` option, which refuses to construct such a pool at all. It is validated at construction and never stored, so it costs the acquire/release hot paths nothing.
- Documented `_active` as unbounded, caller-owned retention — the one structure in a pool PoolKit cannot bound, because it cannot reclaim an object the caller never releases. Added the optional `maxActiveWarning` threshold, reported once per pool through `geterrorhandler`. With no threshold configured the acquire path pays one comparison.
- Made the lifecycle-callback guard a depth counter that restores the previous phase instead of a flag that clears it, so a nested lifecycle callback cannot release a guard it did not take, and a callback that returns by raising cannot leave its pool permanently locked.
- Normalised every `error` level so argument failures report the line that called the public method. `Release` object checks, `Prewarm`/`Trim` counts, `SetMaxRetained`, factory-result rejections reached through `Prewarm`, and the constructor's own option checks previously reported one stack level too deep, which stripped the `file:line` prefix or pointed it at the wrong frame.
- Added LuaCATS annotations for the package facade, `Pool`, and both option tables.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Added PoolKit API generation 1.
- Added bounded generic object pools with explicit `PoolKit.UNBOUNDED` escape hatch.
- Added shallow-clearing table pools.
- Added strict ownership, duplicate/re-entrant release protection, and reset rollback.
- Added prewarm, trim, clear, close, runtime retention resizing, and scalar diagnostics.
- Added best-effort bulk destroy semantics and weak discarded-object history.
