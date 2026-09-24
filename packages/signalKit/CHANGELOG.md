# Changelog

## 0.7.2 — 2026-09-24

- SignalKit follows the repository-wide nil rule. On a client with secret values a comparison with a secret, `nil` included, raises inside SignalKit instead of at the caller, so every value SignalKit did not create — method arguments, `New`, `NewJournal`, `Bus` and `DeclareTopic` option fields, `SetLimits` entries, validator verdicts and what Registry returns — is tested for absence with `type(value) == "nil"`.
- A secret is refused at the caller before it is compared: `SignalKit:NewJournal capacity`, `SignalKit:Bus options.openTopics`, `options.maxTopics` and `options.maxListeners`, `SignalKit.Bus:DeclareTopic options.arguments` (a count) and `SignalKit:SetLimits limits.<name>`, each with `<label> must not be a secret value`. A validator whose verdict is secret has not accepted the arguments, and the publish is refused at the publisher's line. A facade method called with a dot and a secret first argument is refused as a call without the facade, by its type, before any comparison.
- One `isSecret` helper replaces the two inline `issecretvalue` lookups.
- `docs/API.md` lists the new messages under "Error messages" and states the rule there and under "Secret values".
- Seven specs: `SecretValues_spec.lua` (six) and an in-place upgrade from the previous revision in `Bootstrap_spec.lua`. The bootstrap specs name the current revision once and load `REVISION + 1` as the newer copy.
- Implementation revision 8. The state layout (schema 4) is unchanged; an upgrade over revision 7 keeps the facade, the state, buses, limits and journals. `SignalKit` API generation 1 is unchanged.

## 0.7.1 — 2026-09-24

- `docs/API.md` gains an "Error messages" section listing every message SignalKit raises, each at the caller's line. The receiver rule now names `GetGeneration` and the journal's `Fire` and `History`; the hooks example activates its source with `ConnectUnit("UNIT_HEALTH", forward, "player")`, the unit-filtered registration a unit event wants; the compaction measurements compare tombstones against copying per disconnect rather than narrating revisions 1 and 2.
- The specs share one refusal-at-the-caller assertion, `SignalKitTestEnv.ExpectRefusalAtCaller`, instead of six copies; `Bootstrap_spec.lua` and `Errors_spec.lua` use the shared `expectErrorContaining`, and `Compaction_spec.lua` the environment's `AllocatedKilobytes`. `tests/README.md` names both and records the journals `Bootstrap_spec.lua` carries into a newer revision. 213 specs, unchanged.
- No runtime behaviour change. Implementation revision 7 and `SignalKit` API generation 1 are unchanged.

## 0.7.0 — 2026-09-24

- Added the `onFirst` and `onLast` hooks: `SignalKit:New({ onFirst = fn, onLast = fn })` runs `onFirst` after the live listener count goes from 0 to 1 and `onLast` after it goes from 1 to 0, so a source can be active only while it is observed. A hook receives the signal, is never called by `Fire`, runs synchronously after its transition is committed, and holds under re-entrant connect and disconnect (a hook crossing the threshold the other way causes the opposite hook, once). `Once` listeners count until they disconnect, so the last one runs `onLast` during `Fire`, before its callback. `DisconnectAll` runs `onLast` once. A hook error propagates to the caller of the `Connect`, `Disconnect`, `DisconnectAll` or `Fire` that caused the transition, after the transition took effect. A signal without hooks pays one truthiness test per connect and disconnect. `SignalKit.New()` without options is still accepted; options handed over with a dot call are refused at the caller rather than ignored. Bus topic signals carry no hooks.
- Added `signal:GetGeneration()`: `0` for a new signal, one more per `Fire` (listeners or not, error or not), moved before any listener runs. A Lua 5.1 double counts exactly to 2^53, so it is never wrapped. Signals created by revision 6 report `0` until their next `Fire`.
- Added journals. `SignalKit:NewJournal(capacity, options)` creates a signal that also records its last `capacity` firings (default 128, 1 to `maxJournalCapacity`; `UNBOUNDED` refused) in a ring of slot tables allocated once and reused; `options` takes the same hooks. `journal:Fire(...)` records before dispatching and is refused at the firing line beyond `maxJournalArguments` values (default 8) with a message that names the counts and never a value. `journal:History()` returns a shared stateless iterator for `for position, entry in journal:History() do`, oldest to newest, allocating nothing; an entry exposes `count`, `[1]` to `[count]` and `generation`, is the ring's own slot table and is overwritten by later firings. Nothing is replayed on connect.
- `SignalKit:SetLimits` gains `maxJournalCapacity` (default 1024, ceiling 65536) and `maxJournalArguments` (default 8, ceiling 64); neither accepts `UNBOUNDED`, each with its reason in the message. `GetLimits` returns all three limits. Lowering never shrinks a journal; raising `maxJournalArguments` widens journals that already exist.
- Implementation revision 7, with package state schema 4: the journal method table and metatable, and the two journal limits. An upgrade over revision 6 adds them with the defaults and touches no signal; missing generation and hook fields on older signals read as `0` and none. A newer revision inherits journals with their ring, history and generation. The public-surface predicate now requires `NewJournal` and `GetGeneration`; the state predicate requires the journal tables and all three limits.
- 213 specs; `Hooks_spec.lua`, `Generation_spec.lua` and `Journal_spec.lua` are new, `Limits_spec.lua` covers the two journal limits, and `Bootstrap_spec.lua` covers the revision-6 upgrade, journals carried into a newer revision and an incomplete journal prototype. The bootstrap specs now expect revision 7 and schema 4 and load revision 8 as the newer copy.
- `SignalKit` API generation 1 is unchanged.

## 0.6.0 — 2026-09-23

- An addon's bus is now closed at logout whenever the framework can observe logout, whichever revisions are paired. `SignalKit:ForAddon(addonName)` finds LifecycleKit and EventKit with `Registry:Find` and leaves the bus to a LifecycleKit whose `CLOSES_ADDON_SCOPES` names `signalKit` (making sure the addon has a LifecycleKit instance), subscribes once to an older LifecycleKit's `OnShutdown`, or, without LifecycleKit, connects one package-level `PLAYER_LOGOUT` watcher in SignalKit's own EventKit scope. With neither, nothing is subscribed and the consumer calls `CloseAddonBus` on `PLAYER_LOGOUT`, as before. The decision is taken again by later `ForAddon` calls until LifecycleKit has taken the bus over. Only buses `ForAddon` returned are closed at logout; a bus obtained only through `SignalKit:Bus` is not. See "At logout" in `docs/API.md`.
- `CloseAddonBus` disconnects the `OnShutdown` subscription of a bus that closes before logout.
- LifecycleKit API 1 and EventKit API 1 are declared under `optionalDependencies`. Both depend on SignalKit, so these are cycles through optional edges, which the manifest rules allow; SignalKit still requires only Registry API 2.
- Implementation revision 6, with package state schema 3: the `logoutWatch` table and, on every bus, `_logoutCloser` and `_shutdownSubscription`. An upgrade over revision 5 adds them (no bus is taken for an addon's until its next `ForAddon`, because revision 5 did not record that); an upgrade over revision 6 or later arranges the logout close of the open addon buses it inherits and keeps the subscriptions and the watcher. The state predicate now requires `logoutWatch` and its `close` function.
- 153 specs; `LogoutClose_spec.lua` covers the four cases, a bus first obtained through `Bus`, re-evaluation, a failure in another Kit, the subscription disconnected by an early `CloseAddonBus`, and the upgrades. The bootstrap specs now expect revision 6 and schema 3 and load revision 7 as the newer copy.
- `SignalKit` API generation 1 is unchanged.

## 0.5.0 — 2026-09-23

- Every bus bound can now be opened on purpose, per the design constitution's "bounded by default, opened on purpose". The defaults are unchanged and a bound reached is still refused with `nil, "full"`.
- Added the `SignalKit:Bus` options `maxTopics` and `maxListeners`: a positive integer or `SignalKit.UNBOUNDED`, default 256 each. The first caller that states a limit for a shared bus sets it, in either load order; a different statement later raises at the caller and changes nothing. Invalid values raise at the caller.
- Added `SignalKit:SetLimits({ maxBuses = n })` and `SignalKit:GetLimits()`. `maxBuses` (default 64) is shared by every consumer in the session, accepts an integer from 1 to 1024 and refuses `SignalKit.UNBOUNDED`, because buses are shared by every addon and never freed. `SetLimits` validates the whole table first and raises at the caller on an unknown name or an invalid value; `GetLimits` returns a fresh table.
- Added `SignalKit.UNBOUNDED`, one sentinel table kept in the package state so every embedded copy and revision shares it.
- Lowering a limit never evicts; further additions are refused until the count is below it.
- Implementation revision 5, with package state schema 2. An upgrade over revision 4 adds the sentinel and the default limits and gives every existing bus the default per-bus limits, recorded as not yet stated. A newer revision inherits the sentinel identity, the limits a consumer set and each bus's own limits. The public-surface predicate now requires `UNBOUNDED`, `SetLimits` and `GetLimits`, and the state predicate checks the sentinel identity and the limits.
- `SignalKit` API generation 1 is unchanged.

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
