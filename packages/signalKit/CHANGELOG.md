# Changelog

## 0.4.0 — 2026-09-23

- Added named message buses. `SignalKit:Bus(name, options)` returns the bus shared by everything in the session that asks for that name, so two modules or two addons that hold no common reference can communicate. Each topic is dispatched through an ordinary SignalKit signal, created on its first subscription, so ordering, mutation-during-dispatch and re-entrancy semantics are exactly a signal's.
- Added a validated topic policy. `bus:DeclareTopic(topic, options)` takes an exact argument count or a validator in `options.arguments`, plus `options.description`, which documents the topic at its declaration and is not returned by any method. `bus:Publish` on an undeclared topic, or with arguments that fail the policy, raises at the publishing line; `options.openTopics = true` on the bus lifts the declaration requirement for prototypes. Subscribing never requires a declaration, so load order does not matter. `bus:Topics()` lists declared topics, sorted.
- Added `bus:Subscribe`, `bus:SubscribeOnce` (both returning the existing SignalKit connection handle), `bus:Unsubscribe(topic, callback)` and `bus:CreateScope()`, whose scopes offer `Subscribe`, `SubscribeOnce`, `DisconnectAll`, `Close` and `IsClosed`, mirroring EventKit's scopes.
- Added `SignalKit:ForAddon(addonName)`, an addon's default bus, and `SignalKit:CloseAddonBus(addonName)`, which closes it terminally at shutdown.
- Bus listener errors are isolated and reported through the host error handler, through `securecallfunction` when the client provides it and `xpcall` otherwise; they never reach the publisher. Raw signals are unchanged and still propagate listener errors to the caller of `Fire`.
- Bounded by fixed package constants: 64 buses, 256 topics per bus, 256 live listeners per topic, each refused with `nil, "full"`. A steady-state publish allocates nothing of SignalKit's own on either isolation path; a spec guards the `xpcall` path.
- Implementation revision 4, with private package state (`_state`, schema 1) introduced to carry buses, topics, scopes and subscriptions through in-place upgrades. An upgrade over revisions 1 to 3 creates the state and leaves existing signals and connections untouched. The public-surface predicate now requires `Bus`, `ForAddon` and `CloseAddonBus`.
- A bus scope compacts its connection list as soon as disconnected entries outnumber connected ones, whichever path disconnected them, so the list never exceeds twice the live subscriptions plus one.
- A validator that raises is turned into a refusal at the publishing line (`SignalKit.Bus:Publish validator for topic "<topic>" on bus "<bus>" failed: <reason>`), because the validator may belong to another addon. Refusal messages never include the published argument values.
- `options.arguments` counts that are negative, fractional, infinite or NaN are refused at the caller. `DeclareTopic` on a closed bus is refused at the caller, so it cannot spend a topic slot. `Publish` on a closed bus still checks the topic's type. A secret bus name or topic is refused at the caller before any comparison, when `issecretvalue` exists.
- `SignalKit` API generation 1 is unchanged; every existing signal method behaves as before.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- Implementation revision 3. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `SignalKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 35 annotation lines became 49. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed the LuaCATS types to `SignalKit.Signal` and `SignalKit.Connection`, and annotated the receiver of every public method so `signal:Connect(...)` autocompletes.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- `Connect`, `Once`, `Fire` and `DisconnectAll` now validate that they were called on a signal, and `Disconnect`/`IsConnected` that they were called on a connection handle. A dot call such as `SignalKit.Connect(callback)` raises a SignalKit error naming the misuse at the calling line instead of a raw `attempt to index a function value` from inside the package.
- `Disconnect` is now amortized `O(1)` and allocation-free. It marks a tombstone instead of copying the listener array, and the array is compacted once at least half of its slots are tombstones, so the array never retains more than twice the live listener count. Tearing down 4000 listeners one handle at a time went from 97.6 ms and 168 MB of garbage to 1.4 ms and 65 KB.
- `Fire` remains allocation-free; a spec now guards that with `collectgarbage("count")` deltas.
- Documented the measured complexity and allocation numbers in `docs/API.md`.
- Added specs for `Once` connected during a dispatch, `DisconnectAll` inside a nested `Fire`, compaction order and retention, and the in-place upgrade path for signals created by revision 1.
- Annotated the public surface with LuaCATS types.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Renamed the package identity and Lua facade from `signal` / `Signal` to `signalKit` / `SignalKit` as part of the framework-wide Kit naming convention.

- Added SignalKit API generation 1, implementation revision 1.
- Added deterministic connection-order dispatch.
- Added `Connect`, `Once`, `Fire`, and `DisconnectAll`.
- Added connection handles with idempotent `Disconnect` and `IsConnected`.
- Defined mutation-safe and recursive dispatch semantics.
- Added fixed-boundary dispatch with `O(1)` listener append and copy-on-write disconnect so `Fire()` does not allocate a listener snapshot.
- Added Registry API 2 bootstrap and duplicate-embedding behavior.
