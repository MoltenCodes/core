# Changelog

## 0.7.0 — 2026-09-23

- An addon scope now always closes at logout, whatever LifecycleKit revision is paired. The first `EventKit:ForAddon(addonName)` decides who calls `CloseAddonScopes`, finding LifecycleKit through `Registry:Find`: a LifecycleKit that lists `"eventKit"` in `CLOSES_ADDON_SCOPES` (LifecycleKit 0.6.0) makes the call itself; the Kit subscribes nothing and only calls `LifecycleKit:ForAddon(addonName)` once, so an addon that never used LifecycleKit is still closed, and nothing else is connected; an older LifecycleKit gets one `OnShutdown` subscription per addon, kept on the scope and disconnected when the scope closes, and it steps aside if a capable LifecycleKit replaced it before logout; without LifecycleKit, one package-level `PLAYER_LOGOUT` one-shot of EventKit's own closes every addon scope neither LifecycleKit route covers. Only when the host refuses that registration is nothing connected; the next `ForAddon` tries again. Every route closes inside the `PLAYER_LOGOUT` dispatch, so the existing deferred sweep disconnects after that dispatch and a scoped `PLAYER_LOGOUT` listener still runs. Documented under "At logout" in `docs/API.md`; the hand-written `EventKit:Once("PLAYER_LOGOUT", ...)` wiring is no longer needed.
- LifecycleKit is declared under `optionalDependencies`. EventKit still embeds as three files and depends on Registry and SignalKit alone.
- `Scope:Close()` on an addon scope, and `CloseAddonScopes`, release the scope's LifecycleKit subscription.
- Implementation revision 11. `_state` moves from schema 6 to schema 7, adding `logoutConnection`; the handlers `closeOnLogout` and `closeOnShutdown` join the shared functions the state predicate checks. An in-place upgrade from revision 10 or older routes every carried addon scope as a first `ForAddon` would; a scope already routed keeps its subscription or connection.
- Specs: new `LogoutCoverage_spec.lua` (the four cases against the real LifecycleKit, a LifecycleKit with its capability field removed, subscription release, a capable LifecycleKit replacing an older one, scoped `PLAYER_LOGOUT` listeners connected before and after the closing one, a refused host registration retried at the next `ForAddon`, a scope routed before LifecycleKit loaded, and upgrades that route, or carry the routes of, an older copy). The bootstrap specs follow revision 11 and schema 7. The test environment gains `LoadLifecycleKit`.
- `EventKit` API generation 1 is unchanged.

## 0.6.0 — 2026-09-23

- Added `EventKit:SetLimits(limits)` and `EventKit:GetLimits()`, per design principle 4a (bounded by default, opened on purpose). The one package-wide limit, `maxUnitFrames`, replaces the fixed cap of 64 unit-filter Frames: its default stays 64 and it accepts an integer from 1 to 512. The limit is shared by every consumer in the session. `SetLimits` validates the whole table before changing anything and raises at the caller's line on a non-table, an unrecognised name or an out-of-range value. `GetLimits` returns a fresh table.
- Added `EventKit.UNBOUNDED`, the package sentinel. `maxUnitFrames` refuses it (`EventKit:SetLimits limits.maxUnitFrames cannot be EventKit.UNBOUNDED: the client never frees a Frame`), because every Frame admitted lives for the rest of the session.
- Lowering `maxUnitFrames` below the Frames already created evicts nothing; a new Frame is refused until usage drops below it or the limit is raised. The refusal message now names `EventKit:SetLimits{ maxUnitFrames }`.
- Scopes have no connection cap, so they gain no `maxConnections` option. The two-token `ConnectUnit` limit (two `RegisterUnitEvent` filter slots) and the 32-event bound on one `Coalesce` or `Derive` call stay fixed; `docs/API.md` has a new "Limits" section listing all of them.
- Implementation revision 10. `_state` moves from schema 5 to schema 6, adding `unbounded` and `limits`; a copy loading over revisions 7 to 9 adds both in place with `maxUnitFrames` at 64, and a newer copy inherits the sentinel and the limits a consumer set. The public-surface predicate now requires `UNBOUNDED`, `SetLimits` and `GetLimits`, and the state predicate checks the sentinel's identity and the limits' range.
- `EventKit` API generation 1 is unchanged.

## 0.5.2 — 2026-09-23

- `DeriveHandle:Close()` now disconnects the handle's `OnChange` listeners. It used to drop them without disconnecting, so a connection returned by `OnChange` kept answering `IsConnected() == true` for a value that would never change again.
- `scope:Derive` refuses a scope that its own `compute` closed while the handle was being built, raising `EventKit.Scope:Derive cannot connect in a closed scope` at the caller's line and releasing everything the handle had taken. The handle used to be linked into the closed scope, where no sweep would ever reach it, so its event registrations stayed live for the session.
- The reason `Coalesce` gives for an old SchedulerKit now reads `the loaded SchedulerKit predates coalescing, added in its revision 7`; it read as though the loaded copy were revision 7.
- Documentation: `docs/API.md` names the package `eventKit` in the upgrade section (it said `events`), says Frames created since revision 2 resolve dispatch through `_state` rather than the facade, documents `OnChange` on a closed handle and the listener disconnection, and records the revision-8 and revision-9 upgrades; the README states the version it ships and SchedulerKit as an optional partner; `tests/README.md` lists the spec files.
- Implementation revision 9. `_state` schema 5 is unchanged, so a copy loading over revision 8 (or 7) adopts its state as it is, and handles created by that copy close through the new code, because they resolve it through shared state. Three new specs: the listener disconnection, the compute that closes its scope, and the revision-8 upgrade, which loads a real copy at revision 8 through the new `EventKitTestEnv.LoadSourceAtRevision`.
- `EventKit` API generation 1 is unchanged.

## 0.5.1 — 2026-09-23

- `EventKit:CloseAddonScopes(addonName)` for an addon that never asked for a scope now records nothing and returns `false`, as HookKit, CommandKit and CommKit do. It used to record a closed scope and return `true`, so every addon LifecycleKit shut down left an entry behind, and a later `ForAddon` for that name returned a closed scope. A scope that exists is closed exactly as before.
- `CloseAddonScopes` now validates its receiver: a dot call raises `EventKit:CloseAddonScopes must be called on the EventKit facade` at the caller's line.
- Two specs replace the old "recorded as closed" case: nothing is recorded for an addon without a scope, and the dot call is refused at the caller's line.
- Implementation revision 8. `_state` schema 5 is unchanged, so a copy loading over revision 7 adopts its state as it is; a closed scope revision 7 recorded for an addon without one stays recorded. `EventKit` API generation 1 is unchanged.

## 0.5.0 — 2026-09-23

- Added `EventKit:Coalesce(events, intervalSeconds, callback, options)` and `scope:Coalesce`: the listed events (a name or an array, unit events through `options.units` with `ConnectUnit` semantics) are collected into a set keyed by the first payload argument, or by event name with `byEvent` or when that argument is `nil`, and `callback(set)` runs at most once per interval. AceBucket's interval semantics: the first event starts the interval, the callback runs at its end with everything collected. The handle has `Flush`, `IsPending`, `GetStats`, `Close` and `IsClosed`; `maxKeys` and `lane` pass through to SchedulerKit.
- Added `EventKit:Derive(events, compute, options)` and `scope:Derive`: a cached value recomputed when any listed event fires, debounced by `delaySeconds` (default `0`, the next frame), with `Get`, `OnChange` (a SignalKit connection; listeners isolated), `Invalidate`, `Close` and `IsClosed`, and `options.equals` to decide what counts as a change.
- Both are built on SchedulerKit's `Coalesce` and `Debounce`, found through `Registry:Find("schedulerKit", 1)` at call time; EventKit does not depend on SchedulerKit, which depends on LifecycleKit, which depends on EventKit. Without SchedulerKit, `Coalesce` is refused at the caller and `Derive` recomputes synchronously on every event. The family is documented once, in SchedulerKit's `docs/API.md` under *Coalescing and lanes*, which the new *Coalescing events* section links to.
- A `Coalesce` or `Derive` handle joins its EventKit scope as one member; the scope sweep releases its event registrations and its SchedulerKit scope, deferred like any connection when the scope closes during a dispatch. The steady-state per-event path allocates nothing.
- Implementation revision 7; `_state` schema 5. A copy loading over revision 6 adds the composite dispatch table and handle metatables in place. 22 new specs: Coalesce (10), Derive (11) and the revision-6 upgrade; the test environment gains a SchedulerKit-backed variant that puts the sibling sources on the path.
- `EventKit` API generation 1 is unchanged; the additions are compatible.
- Documentation only, after the acceptance review (no executed-code change, so no version or revision change): a set delivered through a lane lives until the lane job's terminal state, across retries; a NaN `Derive` value counts as a change on every recompute; `CoalesceHandle:Flush()` passes SchedulerKit's `"deferred"`/`"dropped"` reason through, now stated in its annotations.

## 0.4.1 — 2026-09-23

- Fixed a scoped `PLAYER_LOGOUT` listener being silently dropped. LifecycleKit's logout watcher runs before listeners connected after it and closes the addon's scope; the close disconnected them mid-dispatch, so an addon's `EventKit:ForAddon(name):Connect("PLAYER_LOGOUT", save)` never ran. `Close()` and `CloseAddonScopes` called during a dispatch now close the scope at once — new connections are refused — and sweep its connections when the outermost dispatch returns. The documented rule: `Close` prevents future deliveries, never the one in flight. A failure during that sweep goes to the host error handler.
- EventKit counts dispatches on the stack with two field writes per event; the per-event path still allocates nothing, and the existing allocation specs still hold.
- `docs/API.md` no longer says LifecycleKit has yet to make the `CloseAddonScopes` call, and explains why the documented `PLAYER_LOGOUT` wiring is now safe.
- Implementation revision 6; `_state` schema 4. A copy loading over revision 5 adds the dispatch accounting in place. Four new specs cover the in-flight close, the refusal of new connections mid-dispatch, the reported sweep failure and the revision-5 upgrade; LifecycleKit gains the end-to-end spec.

## 0.4.0 — 2026-09-23

- Added owner scopes, mirroring TimerKit's scope model in naming and semantics: `EventKit:CreateScope()` and `EventKit:ForAddon(addonName)` return a scope with `Connect`, `Once`, `ConnectUnit`, `OnceUnit`, `DisconnectAll`, `Close`, `IsClosed`, `GetAddonName` and `GetActiveCount`. One call now tears down every subscription an owner made.
- A scoped connection is an ordinary handle: it can still be disconnected on its own and leaves its scope the moment it disconnects, including a one-shot that fired. Scopes keep their connections on an intrusive doubly linked list whose links are fields on the connection, so joining and leaving allocate nothing, a disconnect unlinks in constant time, and no dead handle is ever retained. Dispatch is unchanged.
- `DisconnectAll()` and `Close()` run in creation order, continue past a host failure and re-raise the first error object unchanged. `Close()` is terminal: later connections through the scope raise `EventKit.Scope:<Method> cannot connect in a closed scope` at the caller's line.
- Added `EventKit:CloseAddonScopes(addonName)`. EventKit cannot depend on LifecycleKit, which depends on it, so an addon scope is closed by whoever observes that addon's shutdown. The two-step is documented in `docs/API.md`, with the wiring a consumer uses without LifecycleKit. Closing is terminal and the closed scope stays canonical.
- Argument errors are now built from the qualified method name, so errors raised through a scope name the scope method. Package-level messages are unchanged.
- Implementation revision 5; `_state` schema 3. A copy loading over revision 2 to 4 adds the scope prototype, the addon-scope map and the shared scope metatable in place; connections made by the older revision keep working and belong to no scope. Eighteen new specs cover scope bookkeeping, one-shots, unit subscriptions, bulk teardown order and failure handling, closing, caller-line errors, receiver validation, per-event allocation, addon scopes, the two-step shutdown wiring and both upgrade paths.
- Added a table-of-contents header to `src/EventKit.lua`, and corrected the stale version and revision in the README.
- `EventKit` API generation 1 is unchanged; the additions are compatible.

## 0.3.1 — 2026-09-22

- `connection:Disconnect()` and `connection:IsConnected()` now validate their receiver. Reached through the shared `EventKit.Connection` prototype with no receiver — `EventKit.Connection.Disconnect()`, or a dot where a colon was meant — they used to raise `bad argument #1 to 'rawget'` from a line inside `src/EventKit.lua`, which named neither the package nor the mistake. They now raise `EventKit:Disconnect must be called on a connection handle; use connection:Disconnect()` at the caller's line, matching SignalKit's existing guard.
- The receiver test is a `_connected` field type test rather than a metatable comparison, so handles created by an older embedded revision keep working after an in-place upgrade: the newer copy replaces the methods on the shared prototype those handles already index.
- Implementation revision 4. Two regression specs cover the named message and the caller's line for both methods.
- No public API change. `EventKit` API generation 1 is unchanged.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- Implementation revision 3. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `EventKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 12 annotation lines became 100. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Annotated the whole package: it previously carried 12 annotation lines, all on the facade declaration, and nothing on the implementation.
- Renamed `EventKitConnection` to `EventKit.Connection`, added the `EventKit.Listener` callback alias, and declared the internal channel and unit-group shapes as `EventKit.Channel` and `EventKit.UnitGroup` so the Frame boundary is typed rather than `table`.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- `ConnectUnit`/`OnceUnit` now reject more than two distinct unit tokens instead of letting the client silently drop the extras. `Frame:RegisterUnitEvent` has two filter slots; a third token used to be sorted away by the host while EventKit's group key still claimed it, so the caller got a filter they never asked for. Fan-in was considered and rejected: it needs an extra Frame per pair and makes delivery order for one logical subscription unspecified, because EventKit does not define ordering between Frames.
- Listeners are now isolated from each other at EventKit's dispatch boundary. EventKit is one shared instance per WoW session, and an erroring handler used to abort delivery to every listener behind it, including listeners belonging to unrelated addons. Errors are now reported through the host error handler and delivery continues. Isolation uses `securecallfunction` when the client provides it, otherwise `xpcall` with `geterrorhandler()` driven by a reusable upvalue trampoline, so nothing is allocated per event.
- Unit groups are released when their last channel goes. The Frame's `OnEvent` handler is detached and the Frame returns to a free list that new unit sets re-purpose, so creating and releasing a hundred distinct unit sets creates one Frame instead of a hundred. The number of unit-filter Frames EventKit will ever create is capped at 64, which also bounds the free list.
- Host-environment failures (`CreateFrame` missing, a missing Frame method, the Frame cap) now raise at level 0 with an `EventKit:` prefix. They were raised two to four frames below the public API, so their stack level named a line inside EventKit. Argument errors continue to point at the calling line, and a spec now verifies that.
- The per-event `rawget(EventKit, "_DispatchRegular")` plus type check is gone: the dispatchers are validated once at load and kept in shared state. `_DispatchRegular`/`_DispatchUnit` remain on the facade so Frames created by revision 1 keep working after an in-place upgrade.
- `releaseChannel` treats any non-positive listener count as empty rather than testing `count ~= 0`, so a bookkeeping slip cannot pin a registration for the rest of the session.
- Documented the combat-log event's empty payload, the taint consequences of a shared bus, and the reserved underscore-prefixed facade fields.
- Made the test stub enforce the host's two unit-filter slots, documented cross-Frame delivery order as unspecified, and added specs for two tenants where the first throws, disconnect-during-dispatch from another connection, Frame retention, the revision-1 upgrade path, and per-event allocation.
- Annotated the public surface with LuaCATS types.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Made the test-support `CreateFrame` stub raise a plain error when asked for a frame type it does not model. It previously called a luassert matcher, which is unavailable inside a `require`d support module and reported a confusing indexing failure instead of the real misuse.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Renamed the package identity and Lua facade from `events` / `Events` to `eventKit` / `EventKit` as part of the framework-wide Kit naming convention.

- Added lazy regular WoW event subscriptions.
- Added unit-filtered event subscriptions.
- Added one-shot subscriptions.
- Added explicit, idempotent connection lifecycle.
- Added shared-frame grouping and automatic unregistration.
- Added Registry-backed embedded-copy reconciliation.
