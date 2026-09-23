# Changelog

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
