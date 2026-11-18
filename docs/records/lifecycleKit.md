# lifecycleKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## lifecycleKit (package O): the probe rule and the halted field as a record field

**lifecycleKit (package O): the probe rule and the halted field as a record field** — a change to facade `LifecycleKit`

1. Package `lifecycleKit`, facade `LifecycleKit`, API generation 1,
   version 0.6.9 (from 0.6.8, internal fix and documentation), implementation
   revision 18 (from 17).
2. Purpose: the LifecycleKit side of the moduleKit fix F3 in
   the decision 18 diagnosis (section lifecycleKit
   and moduleKit) and package O's probe rule.
   - **`_halted` becomes a documented, stable generation-1 field of an
     instance.** ModuleKit reads it on every enable instead of calling
     `IsHalted` twice. It is exact because LifecycleKit writes
     `_halted = true` before it notifies anyone (`LifecycleKit.lua:1973`),
     and every instance gets `_halted = false` at creation (`:674`). An
     instance of a revision older than the halted state has no field and
     reads as not halted, which is what it is. INTERNALS-level promise in
     API.md: the field is written only by LifecycleKit, is `true` from the
     moment the halt begins, and keeps its name and meaning for API 1.
   - **Probe rule.** `isSecret` (`:344`) reads `rawget(_G,
     "issecretvalue")` on every call today. It resolves it once at load and
     falls back to the per-call read, accepted only as a function, when it
     was absent at load.
   - **Decision 19b candidate.** `describeKey` (`:358`) checks a caller
     table's key for a secret before naming it; a table cannot be indexed
     with a secret key on Retail 12.1.0 (`docs/EMBEDDING.md`). The check
     stays until the client suite proves a secret key cannot be written
     either (see the schedulerKit record, point 7), then goes.
   Non-goals: any change to phases, halts, the combat gate or their costs.
3. Dependencies: unchanged, registry API 2, signalKit API 1, eventKit API 1.
4. Surface: no new methods. API.md documents the `_halted` field as above.
5. Ownership: unchanged.
6. Performance and memory: one global read and one `type` fewer per secret
   check in the client; nothing on the bench host, which has no probe. The
   ModuleKit gain the field enables is in the moduleKit record (about 22
   instructions per halt check, twice per enable). No bytes change.
7. Tests: a probe installed after load is honoured; `_halted` is `true`
   inside the first halt listener and before `OnHalted` subscribers run;
   in-place upgrade from revision 17 keeps instances, phases and halts.
8. Docs: API.md (the field, under "Halted state"), CHANGELOG, tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.9,
   revision 18, 202 specs.

**lifecycleKit (core slimming): the combat gate and halting as parts, own phase lists instead of SignalKit, one scope-closing step** — a change to facade `LifecycleKit`

Measurements, classification, the upgrade floor and the part contract:
`core-runtime.md`.

1. Package `lifecycleKit`, facade `LifecycleKit`, API generation 1
   (additive), version 0.7.0 (from 0.6.9), implementation revision 19 (from
   18), state schema 4 (from 3). New parts `CombatGate` and `Halt`,
   revision 1.
2. Purpose: LifecycleKit is 72.4 KB resident (49.0 KB of live prototypes),
   and every addon instance costs 3,544 B, of which 1,872 B are four SignalKit
   signals. AceAddon-3.0, which also holds modules, is 27.0 KB and 1,771 B per
   addon. What every user of LifecycleKit needs is the per-addon phases
   (loaded, ready, shutdown), their replaying subscriptions and queries, and
   the closing of the other Kits' addon scopes at shutdown. The changes, each
   measured on a research copy with the bodies in question emptied unless
   marked priced:
   - **CombatGate part** (`src/parts/LifecycleKit-CombatGate.lua`): the
     shared lockdown flag and its watchers (`PLAYER_REGEN_DISABLED`,
     `PLAYER_REGEN_ENABLED`, the reconcile after login), `IsInCombat`,
     `WhenOutOfCombat`, the `DeferredCall` handle, the bounded combat queue
     with its drain and compaction, `OnCombatStart`, `OnCombatEnd`,
     `SetCombatQueueLimit`, `GetCombatQueueLimit`: −11.9 KB in the core.
     AceAddon has no counterpart; no other Kit's code calls it (CompatKit
     names it only in a message). The `defaultCombatQueueLimit` limit keeps
     its place in the core's limits table; the part applies it. The per-
     instance combat fields (`_combatQueue`, `_combatQueueLength`,
     `_combatPending`, `_combatQueueLimit`, `_draining`, `_combatCaptures`)
     are created by the part on an instance's first use, not with every
     instance.
   - **Halt part** (`src/parts/LifecycleKit-Halt.lua`): `Halt`, `DependsOn`,
     `OnDependencyHalted`, and the announcement to dependents (`halt`,
     `announceHalt`, `dependsOnAddon`, `onDependencyHalted`, `dependsOn`):
     −5.7 KB. **The observers stay in the core**: `IsHalted`,
     `GetHaltReason`, `OnHalted`, the `"halted"` answer of `GetState`, and
     the terminal-state handling. A halt can come from any addon that
     embeds the part, and TestKit and ModuleKit subscribe to `OnHalted`
     unconditionally (`TestKit.lua:2101`, ModuleKit's container
     subscriptions); without the part nothing can halt, and an `OnHalted`
     subscription simply never fires, which is exact. `maxDependencies`
     keeps its place in the core's limits table.
   - **Own phase lists; SignalKit becomes optional.** Each instance keeps,
     per phase and per repeating notice, an array of subscription records
     created on the first subscription, delivered in subscription order
     with each callback isolated and the first failure re-raised once state
     is committed (today's capture protocol, without the per-signal capture
     records). A subscription is its own record in the array, as EventKit's
     connections are. SignalKit is then used only to close the addon bus at
     shutdown, which is found through `Registry:Find` like the other six
     Kits. Priced: code about neutral (the SignalKit wrappers `fireSignal`,
     `newListener`, `recordCallbackFailure`, `getPhaseCaptures` give way to
     one dispatch loop and the inherited-instance path below), −1.9 KB per
     instance.
   - **One scope-closing step.** The seven `closeAddon*Scopes` functions and
     `closeAddonBus` (4.8 KB of prototypes) differ only in the package they
     name and, for SignalKit, the method. They become one loop over
     `CLOSED_ADDON_SCOPE_PACKAGES` with the method name beside each id,
     keeping the documented order and first-error precedence: priced
     −5.5 KB.
   - **The upgrade floor**: the schema 2 migration (`migrateState`,
     `disconnectInheritedWatchers`, `_phaseErrors`), the revision 7
     `DeferredCall` prototype, the revision 12 and 13 state fills and the
     replacement of watchers revisions 7 to 15 installed. The schema 3 to 4
     migration from revision 18 is the only one kept (below). Transient
     mostly; `installGateFields` stops being a per-instance step.
   - **Plain indexing** on `state`, its sub-tables and instances instead of
     literal-key `rawget`/`rawset`: −2.6 to −5.3 KB (upper bound measured on
     309 sites). The facade, prototypes and the `CLOSES_ADDON_SCOPES` view
     keep their raw access.
   - **Shared helper blocks**: `describeKey` (`LifecycleKit.lua:376`, 504 B
     → 504 B) and `limits` (`LifecycleKit.lua:2278`, `validateLimitUpdate`
     with `isLimitValue` and the copy loops of `setLimits`/`getLimits` →
     the block with two `LIMIT_RULES`, both `unbounded = true`): priced
     +1.0 KB. These are the two copies `tooling.shared.sync --list` names for
     lifecycleKit.
   Non-goals: `PLAYER_ENTERING_WORLD` (still a non-goal), changing the
   phase semantics, the replay rule, `CLOSES_ADDON_SCOPES` or any message
   of the remaining surface.
3. Dependencies: core registry API 2, eventKit API 1; **signalKit moves to
   `optionalDependencies`** (beside timerKit, schedulerKit, hookKit,
   commandKit, commKit). Parts `CombatGate` and `Halt`: none beyond the
   core. The optional cycle signalKit ↔ lifecycleKit is allowed by
   `validate_manifests` (cycles are refused only on required edges).
4. Surface:
   - New: `LifecycleKit:HasPart(name)`.
   - Stubs without their part, each raising at the caller's line with the
     file to embed: `LifecycleKit:IsInCombat`, `Instance:WhenOutOfCombat`,
     `Instance:OnCombatStart`, `Instance:OnCombatEnd`,
     `Instance:SetCombatQueueLimit`, `Instance:GetCombatQueueLimit`,
     `DeferredCall:Cancel`, `DeferredCall:IsPending` (CombatGate);
     `Instance:Halt`, `Instance:DependsOn`, `Instance:OnDependencyHalted`
     (Halt). For example `LifecycleKit.Instance:WhenOutOfCombat is in
     LifecycleKit's CombatGate part, which is not loaded: add
     lifecycleKit\parts\LifecycleKit-CombatGate.lua to embeds.xml after
     lifecycleKit\LifecycleKit.lua`.
   - Unchanged without either part: `ForAddon`, the phase methods and
     queries, `GetState`, `IsHalted`, `GetHaltReason`, `OnHalted`,
     `SetLimits`/`GetLimits` (both names), `UNBOUNDED`,
     `CLOSES_ADDON_SCOPES`.
   - Subscription handles keep `Disconnect` and `IsConnected` with the same
     answers.
   - Embedding: LifecycleKit alone needs Registry and EventKit (and EventKit
     no longer needs SignalKit, see the eventKit record).
5. Ownership: unchanged for phases and scopes. Combat queues and dependency
   lists are per instance, created by their part on first use and kept in
   the instance, so an upgraded part takes them over. The combat watchers
   live in the core's `globalWatchers` table under the part's keys, so the
   core's teardown at logout still releases them.
6. Performance and memory (resident):

   | Change | Saving |
   |---|---:|
   | CombatGate to a part (core side; 8 stubs priced at +0.8 KB) | −11.1 KB |
   | Halt to a part (core side; 3 stubs priced at +0.3 KB) | −5.4 KB |
   | One scope-closing step (priced) | −5.5 KB |
   | Plain indexing on internal tables (priced) | −2.6 to −5.3 KB |
   | Own phase lists: code (priced) | ≈ 0 (±1 KB) |
   | Shared blocks (priced) | +1.0 KB |
   | Part interface for two parts (priced) | +0.6 KB |
   | **LifecycleKit core** | **72.4 → ≈ 47 KB** |
   | Per instance (priced) | 3,544 → ≈ 1,000 B (no signals until a subscription; no combat or dependency fields) |
   | LifecycleKit-CombatGate, when embedded (priced) | ≈ 14 KB |
   | LifecycleKit-Halt, when embedded (priced) | ≈ 8 KB |

   Both parts emptied together measure 53.9 KB, before the priced items.
   A phase delivery loses one SignalKit `Fire` (a `pcall` into another Kit)
   and its capture-record writes. Transient allocation while loading
   (231.8 KB today) falls with the removed migrations; measured in phase 2.
7. Tests: Bootstrap and Manifest for both parts; the CombatGate, Halt,
   Isolation and Subscriptions specs run with the parts loaded, unchanged;
   without each part, every stub raises at the caller's line and `HasPart`
   answers `false`; `OnHalted` without the Halt part returns a connected
   subscription that never fires and is disconnected at shutdown; LifecycleKit
   loads, replays and shuts down with no SignalKit registered, and closes
   the addon bus when SignalKit is loaded later; the scope-closing order and
   first-error precedence of the seven steps (existing `OwnedScopes_spec`)
   unchanged; ordering, isolation and replay of the own phase lists
   (subscribe during a dispatch waits for the next delivery of a repeating
   notice; disconnect during a dispatch takes effect at once; a raising
   callback does not stop the rest). In-place upgrade from revision 18, using
   a byte copy of today's `LifecycleKit.lua` as the fixture: instances,
   pending phase subscriptions, combat queues and halts made by revision 18
   keep working. Revision 18's subscriptions live in SignalKit signals
   (`_signals`, `_inner`), and their listeners were built by revision 18, so
   the new revision keeps a small inherited-instance path: it fires an
   inherited instance's signals through SignalKit (present, since revision
   18 required it) with the capture records revision 18's listeners write
   into, and answers `Disconnect`/`IsConnected` of an `_inner` handle;
   instances it creates never take that path. With a part absent, revision
   18's combat queues are drained or closed as today's shutdown would, and
   reported once. Removed with their code: the cases that seed schema 2 or
   revisions 7 to 15 (in `Bootstrap_spec`). LifecycleKit opts
   into KitConformance (limits with both names, receivers, arguments,
   upgrade).
8. Docs: README (dependencies, parts), `docs/API.md` (Parts, the two parts'
   sections moved under them, Dependencies without SignalKit, "Embedded
   bootstrap recovery" rewritten for the floor and revision 18, Cost, the
   `docs/CONTRIBUTING.md` skeleton), `CHANGELOG.md` 0.7.0 (floor, SignalKit,
   schema 4), `tests/README.md`, client suite (`.toc` lists the parts;
   combat and halt tests need them; `EXPECTED.md`). Shared, for the
   maintainer: `docs/EMBEDDING.md` footprint rows and load order,
   `docs/ARCHITECTURE.md` dependency graph (LifecycleKit no longer requires
   SignalKit), `docs/MIGRATING_FROM_ACE3.md` (no Ace3 row changes).
9. Status: implemented 2026-11-18, 0.7.0, revision 19, 235 specs.
   Measured (host Lua 5.1.5, debug information kept, the core-runtime
   method): core 72.4 → 51.3 KB resident (allocated while loading 231.8 →
   179.7 KB); CombatGate part 12.5 KB, Halt part 5.3 KB when embedded; per
   instance without subscriptions 3,289 → 329 B (one warm-up, 200 kept; the
   baseline differs from the 3,544 B above because the addon names were made
   beforehand). The core is about 4 KB above the ≈ 47 KB expected: the shared
   blocks (`isSecret` came with `limits`, which requires it) and the
   revision 18 path (its signals fired with their capture records, its
   handles, its combat queues without the part) stay resident. Choices: the
   `limits` block needs a ceiling, so both limits take 2147483647 (any
   practical value is still accepted, `UNBOUNDED` too); the refusal texts
   become the block's (`; it accepts ...`, `must be an integer from 1 to
   2147483647`) and a secret key is named `<secret>`. With the CombatGate
   part each instance records `_combatQueueLimit` when created, so
   "existing instances keep theirs" holds; the other combat fields are
   created by the first queued call. Without the CombatGate part, revision
   18's queued calls run on the next frame (a `C_Timer.NewTimer(0)`) when
   out of combat, are closed at shutdown or halt otherwise, and are reported
   once. "Loads with no SignalKit registered" is proved by a Registry that
   denies SignalKit while LifecycleKit loads and runs, because EventKit up
   to revision 22 still requires it. Other Kits' test environments load the
   Halt part (ModuleKit's chain and secret spec, TestKit's `Phases_spec`).

**Not recorded (owner decisions, priced):**
- A cheaper phase hook for ModuleKit: one container callback receiving the
  phase name instead of three replaying subscriptions per container
  (about −0.7 KB per addon); a new instance method, so an API addition for
  one consumer.
- The core's `globalWatchers` keep three EventKit connections for every
  session; folding `ADDON_LOADED` into a one-shot per pending addon would save
  little and change the replay timing.
