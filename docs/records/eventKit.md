# eventKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## eventKit (package O): fixed-cost trims, smaller connections, scope reopening and method-name callbacks

**eventKit (package O): fixed-cost trims, smaller connections, scope reopening and method-name callbacks** — a change to facade `EventKit`

1. Package `eventKit`, facade `EventKit`, API generation 1 (additive),
   version 0.10.0 (from 0.9.8), implementation revision 21 (from 20).
2. Purpose: the measured EventKit fixes of
   the decision 18 diagnosis (sections lifecycleKit
   and moduleKit F1/F4, eventKit and signalKit, schedulerKit P1; prototypes
   the diagnosis prototype,
   the diagnosis prototype, the diagnosis prototype), the memory fix for connection handles from
   `memory.md`, package O's probe rule, and decision 19c's method-name form.
   - **Plain fields in the scope links.** `linkToScope` and
     `unlinkFromScope` use plain indexing: neither metatable has
     `__newindex` and every field written exists on the record.
   - **The second `pcall` only while a channel needs it.** `fireChannel`
     walks unprotected unless the channel holds a legacy signal (connections
     from revision 16 and older) or a one-shot listener, whose release talks
     to the host. A per-channel count `onceCount`, created on first use and
     kept by `Once`/`OnceUnit` connect, disconnect and delivery, says so.
     Listener calls already run through `securecallfunction` or `xpcall`,
     neither of which propagates a listener error
     (`docs/EMBEDDING.md`, "Secure calls and secure variables"), so the
     unprotected walk cannot leave `dispatchDepth` raised.
   - **Smaller connection handles.** A connection becomes an array-part
     record: `[1]` callback, `[2]` connected, `[3]` once, `[4]` fan-out
     (channel or combat-log route), and for a scoped connection `[5]` scope,
     `[6]` previous, `[7]` next. The fan-out kind is told by the fan-out
     record itself. The connection metatable moves into shared state, so
     `Disconnect`/`IsConnected` check the receiver by metatable identity
     (one C call instead of `type`, `rawget`, `type`). Connections an older
     revision made are converted in place when this revision loads (the
     same tables, so handles held by addons keep working), walking every
     channel, unit group, combat-log route and scope list once; the hot
     path then reads one layout only. Any closure of an older revision that
     reads connection fields directly is found and covered before the
     conversion is written (phase 2 audits SchedulerKit's and LifecycleKit's
     uses; only methods are called on handles today, as far as read).
   - **Probe rule.** `isSecret` (`:718`) and the dispatch check (`:1996`)
     use `issecretvalue` resolved at load, and fall back to
     `rawget(_G, "issecretvalue")` per call, accepted only as a function,
     when it was absent at load.
   - **No `type()` before the private-metatable checks** (`:818`, `:2898`).
   - **`Scope:Reopen()`** for ModuleKit's kept scopes (moduleKit record).
   - **Method-name callbacks (decision 19c)**, the counterpart of AceEvent's
     `self:RegisterEvent("X", "OnX")` and `self:RegisterEvent("X")`.
   Non-goals: the method form on `ConnectCombatLog`, `Coalesce` and
   `Derive` (no Ace3 counterpart for the first two besides AceBucket, whose
   coalescing moves to a part in a later package O record and gets the form there); late
   binding; flattening the four-frame regular dispatch (P4, a later package O record with the
   coalescing part).
3. Dependencies: unchanged, registry API 2, signalKit API 1.
4. Surface:
   - `Connect(eventName, receiver[, methodName])`,
     `Once(eventName, receiver[, methodName])` on the facade and on scopes;
     `methodName` defaults to `eventName`, as AceEvent's does.
     `ConnectUnit(eventName, receiver, methodName, unit1[, unit2])` and
     `OnceUnit(...)` the same, with `methodName` required (a unit token in
     its place would be ambiguous). The method runs as
     `method(receiver, eventName, ...)`, what AceEvent passes.
   - Resolved and checked at the call: `receiver` a table, `methodName` a
     non-empty, non-secret string, `receiver[methodName]` a function;
     otherwise raises at the caller's line: `<method> callback must be a
     function, or a receiver table followed by a method name` (still
     containing today's `callback must be a function`), `<method>
     methodName must be a non-empty string`, `<method> methodName must not
     be a secret value`, `<method> receiver has no method "<name>"`.
   - **Recorded deviation from AceEvent: early binding.** AceEvent reads
     `self[method]` on every event; EventKit reads it once at connect.
     Replacing the method on the receiver afterwards (including another
     addon's HookKit `Hook` on that method) is not seen by an existing
     connection; reconnect to pick it up. Stated in API.md and the
     migration table.
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when it was open; empty afterwards; an addon scope raises at
     the caller (`EventKit.Scope:Reopen cannot reopen an addon scope`).
     During a dispatch, a scope closed and reopened in the same dispatch is
     open again at once, and the sweep of its earlier connections still
     runs when the outermost dispatch returns.
5. Ownership: unchanged; a method-form connection is owned like any other.
6. Performance and memory (host bench against AceEvent-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | event dispatch-1 | 1.13× | 1.07× (measured without the `pcall`) |
   | event churn-warm / churn-cold | 1.33× / 1.53× | about 1.2× / 1.4× (estimate: handle 224 → 128 B and fewer C calls on disconnect) |
   | disable-enable-all-listening (moduleKit) | 2.21× | 1.58× with ModuleKit's reuse (6,740 → 6,130 instructions from the links alone) |
   | buckets record-event (via schedulerKit) | 1.90× | 1.73× in the client; on the bench host, which has no `issecretvalue`, the fallback keeps today's cost |

   Connection bytes (measured, the diagnosis prototype):
   unscoped 224 → 128 B, scoped 384 → 176 B. Per marginal connection that is
   still above AceEvent's 71 B on a pre-embedded object, which stores one
   hash entry and returns no handle; an EventKit scope (404 B) stays below
   an AceEvent embed (455 B). Method form: one closure of two upvalues,
   136 B, at connect; one extra Lua frame per delivery (31.7 against
   19.2 ns, Ace3's late-bound 35.1 ns). The closure form's paths are
   unchanged. The conversion of old connections runs once per upgrade.
7. Tests: dispatch with and without a one-shot (`onceCount` kept through
   connect, disconnect, delivery, `DisconnectAll`, close during dispatch);
   a legacy signal still protected; dispatch depth restored after a host
   failure in a one-shot release; array-layout handles: every method, the
   receiver message for a string, a table with a foreign metatable and an
   old-layout imitation; scope links after many connect/disconnect orders;
   the in-place upgrade from revision 20 converting regular, unit,
   combat-log and scoped connections, held handles still disconnecting,
   connection order kept; probe rule (installed after load honoured);
   method form on the four methods of facade and scope (default name,
   required name on the unit forms, each refusal at the caller's line,
   early binding, `method(receiver, eventName, ...)`); `Reopen` (manual,
   open, addon scope, inside a dispatch). Client suite additions (never
   run): a method-name connection on `PLAYER_ENTERING_WORLD`;
   `securecallfunction` does not propagate a listener error.
8. Docs: API.md (method form, early binding, `Reopen`, connection cost,
   errors), INTERNALS.md (handle layout and its conversion, `onceCount`,
   when the walk is protected), CHANGELOG, README (migration rows for
   `RegisterEvent("X", "OnX")` and `RegisterEvent("X")`), tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.10.0,
   revision 21, 271 specs. Deviations: late binding (the method is checked at
   registration and looked up at every delivery; one missing then is reported
   through listener isolation as `EventKit receiver has no method "<name>"`
   and the connection stays); Coalesce and Derive handles keep named scope
   links; the main chunk is down to 187 locals.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## eventKit (package O): Coalesce and Derive as a part, timed by TimerKit

**eventKit (package O): Coalesce and Derive as a part, timed by TimerKit** — a change to facade `EventKit`

1. Package `eventKit`, facade `EventKit`, API generation 1 (additive),
   version 0.11.0 (from 0.10.0), implementation revision 22 (from 21). Part
   `Coalescing`, revision 1.
2. Purpose: two changes, both for memory.
   - **Split.** `Coalesce` and `Derive` are 19.5 KB of EventKit's 74.1 KB
     of live prototypes and 25.4 KB resident, in the smallest set every
     addon embeds. Usage: `RegisterEvent` is in 8 of 16 corpus addons (215
     sites, AceEvent addons, frame receivers excluded) and stays core with
     units and the combat log; the bucket counterpart `Coalesce` is in 3 of
     16; `Derive` has no Ace3 counterpart. The combat-log routing (4.8 KB of
     prototypes) and unit groups (2.4 KB) stay in the core: damage meters
     and unit frames, the commonest addon kinds, use them, and their parts
     would save less than the interface they need.
   - **Timed by TimerKit.** Today `Coalesce` needs SchedulerKit, so the
     AceBucket counterpart costs SchedulerKit's core and its Coalescing
     part as well (about 141 KB on top of EventKit's part). Without a lane,
     SchedulerKit's `Coalesce` and `Debounce` do nothing a TimerKit timer
     does not already do: they arm one TimerKit timer in the owning scope
     and deliver from its callback, never as a scheduler job (SchedulerKit
     `docs/API.md`, "One clock"). The part therefore times `Coalesce` and
     `Derive` itself on one TimerKit timer per handle, with the semantics
     SchedulerKit documents for them: the first key starts the interval,
     `maxKeys` (default 256) refuses new keys past it and counts them, the
     set is one of two reused tables, a key recorded during the callback
     goes into the next interval, `intervalSeconds = 0` is the next frame, a
     timer that cannot be armed on the first key raises to that caller and
     keeps the key, `Flush()` from inside the callback returns `false`,
     `GetStats()` returns `{ keys, refused, delivered, deferred, dropped }`
     in a reused table, and a raising callback is reported through the host
     error handler. `Derive`'s recompute is a quiet-period timer on the same
     clock (`delaySeconds`, default 0, the next frame). **A `lane` option
     still goes to SchedulerKit**: lanes are SchedulerKit's, so a `Coalesce`
     given `lane` uses SchedulerKit's `Coalesce` exactly as today and needs
     SchedulerKit with its Coalescing and Lanes parts; it is refused at the
     caller naming the missing file otherwise. No guarantee is weakened:
     every documented option, return, error and ordering is the same.
     One documented fallback changes, for the better, and is recorded as a
     behaviour change: the table "SchedulerKit is optional" becomes
     "TimerKit is optional". With TimerKit and without SchedulerKit,
     `Coalesce` now works instead of being refused, and `Derive` coalesces
     its recomputes instead of recomputing synchronously; without TimerKit,
     both behave as they do today without SchedulerKit. TimerKit is in the
     smallest set, so in practice every addon gets coalescing from
     EventKit's part alone.
   Non-goals: the method-name form for `Coalesce`; a lane without
   SchedulerKit.
3. Dependencies: core unchanged (registry API 2, signalKit API 1;
   lifecycleKit and schedulerKit optional, but the core no longer uses
   SchedulerKit at all). Part `Coalescing`: `optionalDependencies` `timerKit`
   API 1 (the timing) and `schedulerKit` API 1 with `"parts": ["Coalescing",
   "Lanes"]` (only for `lane`).
4. Surface:
   - New: `EventKit:HasPart(name)`.
   - `Coalesce` and `Derive` on the facade and the scope prototype, and the
     handle methods, unchanged with the part loaded; stubs without it.
   - `Coalesce` without TimerKit: `EventKit:Coalesce requires TimerKit API
     1, which is not available (absent)` at the caller (today's message names
     SchedulerKit). `Coalesce` with `lane` and SchedulerKit absent, or its
     Coalescing or Lanes part absent, is refused at the caller with the file
     named; today's "predates coalescing" refusal stays for a SchedulerKit
     revision 6 or older. The part asks `SchedulerKit:HasPart` when that
     method exists and falls back to today's member test for a whole
     SchedulerKit revision.
5. Ownership: unchanged. Composite handles join their EventKit scope; the
   scope sweep closes them through `state.composites.close`, which the part
   fills, with their TimerKit timer (in one TimerKit scope the part owns,
   created on the first handle, as CommKit owns its scopes) or their
   SchedulerKit handle. `MAXIMUM_COMPOSITE_EVENTS` moves into the part.
   Timer callbacks resolve through `state.composites`, so an upgraded part
   takes over pending timers. Handles made by revision 21 keep their
   SchedulerKit timing handle and are served through it until closed; the
   part reads which kind a handle holds from the handle.
6. Performance and memory: EventKit 106.3 KB → 80.9 KB measured for the core
   (about 82 KB expected); the part about 42 KB (today's 25.4 KB plus about
   17 KB for its own timing, priced), core and part about 124 KB. Smallest
   set 353.5 → 328.2 KB measured (Ace3 53.8 KB: 6.6× → 6.1×). The AceBucket
   counterpart (the smallest set plus `Coalesce`) 529.8 KB today → about
   495 KB split on SchedulerKit → about 370 KB timed by TimerKit, against
   63.4 KB for Ace3's smallest set plus AceBucket (8.4× → 5.8×). Against
   AceEvent + CallbackHandler (16.9 KB) the core goes 6.3× → 4.8×.
   Dispatch, connect and disconnect paths unchanged: `eventDispatch` and
   churn benches within noise. The bucket benches (`buckets record-event`,
   `burst`, `register-remove` against AceBucket) are expected at or below
   today, since a key no longer crosses into a second Kit's `__call`; phase 2
   measures them in one run. Main chunk 187 → about 160 locals.
7. Tests: Bootstrap and Manifest for the part; every Coalesce/Derive spec
   with the part loaded, unchanged, run once with SchedulerKit absent
   (TimerKit timing) and once with a `lane`; the SchedulerKit coalesce
   semantics listed in point 2, each as a spec on the TimerKit path (first
   key, `maxKeys` refusals and counts, reused set, keys during the callback,
   zero interval, arm failure on the first key, `Flush` inside the callback,
   `GetStats`, callback error reported); `Derive` debounced, `delaySeconds`,
   and synchronous without TimerKit; without the part, stubs at the
   caller's line and `HasPart`; `lane` without SchedulerKit or its parts;
   in-place upgrade from revision 21 with a live coalesce and derive handle
   on SchedulerKit timing (part loaded: kept and still delivering; not
   loaded: closed, reported once); revision 21 after a core-only revision 22
   yields. Client suite: a coalesced `UNIT_HEALTH` burst with only
   EventKit's part and TimerKit.
8. Docs: README (migration row for AceBucket naming one part), `docs/API.md`
   (Parts, `HasPart`, "TimerKit is optional", the `lane` rule, the timing
   semantics stated in EventKit's own docs instead of by reference),
   `INTERNALS.md` (the two timing kinds, the part's TimerKit scope),
   `CHANGELOG.md` 0.11.0 (with the fallback change), `tests/README.md`,
   client suite `EXPECTED.md`. Shared (text for the maintainer):
   `docs/MIGRATING_FROM_ACE3.md` AceBucket rows name `EventKit-Coalescing`
   only; the example addon's `embeds.xml` gains
   `eventKit\parts\EventKit-Coalescing.lua` (its `Core.lua` uses
   `Coalesce`), and `docs/COOKBOOK.md`'s coalescing recipe names it.
9. Status: implemented 2026-11-15, 0.11.0, revision 22, 309 specs. Core 85.1
   KB (106.3 KB before), Coalescing part about 36 KB; buckets against
   AceBucket: record-event 1.79x to 1.54x, burst 1.75x to 1.52x, register-
   remove 2.31x to 1.65x. The AceBucket-equivalent set holds 370.1 KB against
   Ace3's 63.4 KB (8.4x before, 5.8x now).

**eventKit (core slimming): unit events and the combat log as parts, SignalKit off the core, the upgrade floor** — a change to facade `EventKit`

Measurements, classification, the upgrade floor and the part contract:
`core-runtime.md`.

1. Package `eventKit`, facade `EventKit`, API generation 1 (additive),
   version 0.12.0 (from 0.11.0), implementation revision 23 (from 22). New
   parts `Units` and `CombatLog`, revision 1; part `Coalescing` revision 2
   (from 1).
2. Purpose: EventKit's core is 87.1 KB resident (56.5 KB of live
   prototypes) against 17.3 KB for AceEvent-3.0 with CallbackHandler-1.0.
   AceEvent registers regular events and messages only; a typical addon
   needs `Connect`, `Once`, scopes and connection handles. The changes, each
   measured on a research copy with the bodies in question emptied:
   - **Units part** (`src/parts/EventKit-Units.lua`): `ConnectUnit` and
     `OnceUnit` on the facade and the scope prototype, unit-filter
     normalisation, the unit-group Frames and their reuse, unit channels
     and unit dispatch (`normalizeUnits`, `acquireUnitFrame`,
     `ensureUnitGroup`, `releaseUnitGroup`, `createUnitChannel`,
     `subscribeUnitMethod`, `attachUnitSubscription`, `dispatchUnit` and the
     four public wrappers): −8.6 KB in the core. AceEvent has no unit
     events. The `maxUnitFrames` limit keeps its place in the core's limits
     table, so `SetLimits`/`GetLimits` keep one shape; the part enforces it.
   - **CombatLog part** (`src/parts/EventKit-CombatLog.lua`):
     `ConnectCombatLog` on the facade and the scope, the routes by
     sub-event, the router and its single reader call per event
     (`acquireCombatLogRoute`, `releaseCombatLogRoute`,
     `attachCombatLogRouter`, `detachCombatLogRouter`,
     `routeCombatLogEvent`, `dispatchCombatLog`, `onCombatLogEvent`,
     `subscribeCombatLog`, `validateSubEvent`, `connectToRoute`): −7.6 KB.
     `IsCombatLogAvailable` and the reader probe (`findCombatLogReader`)
     stay in the core: they answer for the client, not for the part, and
     Retail 12 gives addon code no reader at all, so on Retail the part is
     dead weight an addon should not have to carry. The earlier split
     record kept both in the core on the ground that the interface would
     cost more than it saves; measured, each saves 7 to 9 KB against about
     1 KB of stubs and interface.
   - **Closing Coalesce and Derive handles moves into the Coalescing part**
     (`closeCompositeHandle`, `closeUnservedComposite`): −2.3 KB in the core.
     Such a handle exists only when the part made it; the scope sweep calls
     `state.composites.close`, which the part fills, as it already does for
     the timing.
   - **SignalKit leaves the core's dependencies.** Past its load-time facade
     check, the core reads SignalKit only to release connections that
     revisions before 17 made (`_inner`). `Derive`'s change listeners in the
     Coalescing part are the only real use, so `signalKit` API 1 moves to the
     part's `dependencies`. An addon that embeds EventKit without the
     Coalescing part no longer needs SignalKit (`core-runtime.md`, the set
     without buses).
   - **The upgrade floor**: handles with named fields from revisions before
     21 (`disconnectLegacyConnection`, `releaseNamedHandle`,
     `isNamedConnectionHandle`, the `_inner` and `_connected` branches of
     `disconnectHandle` and `IsConnected`), the state migrations of schemas
     before 10, and handles of the whole revision 21 with SchedulerKit timing
     that the Coalescing part adopts: −1.6 KB resident plus main-chunk code.
   - **Logout route 2 goes** (the `OnShutdown` subscription for a
     LifecycleKit before revision 13): `subscribeToShutdown`,
     `closeOnShutdown`, `releaseLogoutSubscription`: −1.7 KB. The
     LifecycleKit route and EventKit's own `PLAYER_LOGOUT` connection stay.
   - **Plain indexing** on `state`, its sub-tables, channels and scopes
     (metatables with a method-table `__index` only) instead of literal-key
     `rawget`/`rawset`: −1.7 to −3.4 KB (upper bound measured on 357 sites).
     Connection handles keep their array slots; the facade and prototypes
     keep `rawset`.
   - **Shared helper blocks**: `describeKey` (`EventKit.lua:2788`, 424 B →
     504 B) and `limits` (`EventKit.lua:3088`, `validateLimitUpdate`,
     `applyLimits`, `copyLimits`, 2,408 B → 3,296 B with one `LIMIT_RULES`
     entry for `maxUnitFrames`, `unboundedReason` "the client never frees a
     Frame"): +1.0 KB. These are the two copies `tooling.shared.sync --list`
     names for eventKit; the conversion buys the drift gate, not memory.
   Non-goals: changing dispatch, listener storage, isolation, the
   method-name form or any message of the remaining surface.
3. Dependencies: core registry API 2; lifecycleKit API 1 optional;
   **signalKit removed**. Part `Units`: none beyond its core. Part
   `CombatLog`: none beyond its core. Part `Coalescing`: `dependencies`
   `signalKit` API 1 (new), `optionalDependencies` unchanged (timerKit;
   schedulerKit with its Coalescing and Lanes parts for `lane`).
4. Surface:
   - `ConnectUnit`, `OnceUnit` (facade and scope) and `ConnectCombatLog`
     (facade and scope) stay as members; without their part each raises at
     the caller's line, for example `EventKit:ConnectUnit is in EventKit's
     Units part, which is not loaded: add eventKit\parts\EventKit-Units.lua
     to embeds.xml after eventKit\EventKit.lua`.
   - `HasPart` answers for `"Units"` and `"CombatLog"` as for
     `"Coalescing"`.
   - `IsCombatLogAvailable`, `SetLimits{ maxUnitFrames }` and `GetLimits`
     work without either part.
   - Embedding: SignalKit is no longer listed for EventKit alone; the
     Coalescing part lists it.
   - Other Kits: SettingsKit's spec listener tests
     `type(rawget(EventKit, "ConnectUnit")) == "function"`
     (`SettingsKit.lua:5266-5277`), which a stub satisfies. It must ask
     `EventKit:HasPart("Units")` (falling back to the member test for an
     EventKit without `HasPart`), and its manifest's optional `eventKit`
     contract names `"parts": ["Units"]`. That is SettingsKit's change, given
     to its owner; until it lands, an addon that embeds SettingsKit's spec
     profiles must also embed the Units part.
5. Ownership: unchanged. Unit and combat-log connections join their EventKit
   scope like any connection; the core's channel release, scope sweep and
   connection disconnect call `state.dispatch` entries the parts fill
   (`releaseUnitChannel`, `releaseRoute`); the core's defaults do nothing,
   which is exact, since no such connection exists without its part.
   Unit-group Frames and routes live in the core's state, so an upgraded
   part takes them over.
6. Performance and memory (resident, measured unless marked priced):

   | Change | Saving |
   |---|---:|
   | Units to a part (core side; stubs priced at +0.4 KB) | −8.2 KB |
   | CombatLog to a part (core side; stubs priced at +0.2 KB) | −7.4 KB |
   | Composite-handle closing to the Coalescing part | −2.3 KB |
   | Upgrade floor | −1.6 KB |
   | Logout route 2 | −1.7 KB |
   | Plain indexing on internal tables (priced) | −1.7 to −3.4 KB |
   | Shared blocks (priced) | +1.0 KB |
   | Part interface for two more parts (priced) | +0.6 KB |
   | **EventKit core** | **87.1 → ≈ 65 KB** (AceEvent + CallbackHandler 17.3 KB: 5.0× → 3.8×) |
   | EventKit-Units, when embedded (priced) | ≈ 11 KB |
   | EventKit-CombatLog, when embedded (priced) | ≈ 10 KB |
   | EventKit-Coalescing (priced) | 37.4 → ≈ 40 KB |

   All emptied together measure 65.3 KB, before the priced items. Per
   object unchanged (a connection 169 B; AceEvent 71 B on a pre-embedded
   object). Dispatch, connect and disconnect paths are unchanged apart from
   the `rawget` calls they lose; phase 2 runs the event bench cases against
   AceEvent in one run. An addon embedding the core alone no longer loads
   SignalKit's 90.3 KB.
7. Tests: Bootstrap and Manifest for the two new parts; the UnitEvents,
   CombatLog and existing unit-related Limits specs run with their part
   loaded, unchanged; without each part, its stubs raise at the caller's line
   (facade and scope forms) and `HasPart` answers `false`;
   `IsCombatLogAvailable` and `SetLimits{ maxUnitFrames }` without the parts;
   a scope holding unit, combat-log and coalesced connections closes all of
   them; EventKit loads and serves `Connect` with no SignalKit registered;
   the Coalescing part refuses to load without SignalKit, naming it. In-place
   upgrade from revision 22, using a byte copy of today's `EventKit.lua` as
   the fixture: regular, unit and combat-log connections and a coalesce
   handle made by revision 22 keep delivering when the parts are loaded;
   when a part is absent, its connections are disconnected at takeover and
   reported once through `geterrorhandler()` with the file to embed (the
   rule the earlier splits use). Removed with their code: the cases that
   seed handles or state of revisions before 22 (in `Bootstrap_spec`,
   `Coalesce_spec` and `Parts_spec`) and the route 2 cases of
   `LogoutCoverage_spec`. EventKit opts into KitConformance (limits with
   `maxUnitFrames`, receivers, arguments, upgrade).
8. Docs: README (dependencies without SignalKit, the minimum footprint of
   two files, the parts, migration rows for `RegisterUnitEvent`-style use
   naming the Units part), `docs/API.md` (Parts, the three parts, "At
   logout" without route 2, Cost tables, the `docs/CONTRIBUTING.md` section
   skeleton), `docs/INTERNALS.md` (the dispatch entries the parts fill, no
   named handles), `CHANGELOG.md` 0.12.0 (the upgrade floor and the
   SignalKit change named), `tests/README.md`, the client suite (`.toc`
   lists the parts; `EXPECTED.md`). Shared, for the maintainer:
   `docs/EMBEDDING.md` footprint rows and load-order lists (EventKit without
   SignalKit), `docs/MIGRATING_FROM_ACE3.md` (unit events and the combat log
   name their parts), the example addon's `embeds.xml` if it uses unit
   events.
9. Status: recorded 2026-11-16; code follows.

**Not recorded (owner decisions, priced):**
- Drop EventKit's own `PLAYER_LOGOUT` route for addon scopes when no
  LifecycleKit is loaded: about −4 KB; the addon would call
  `CloseAddonScopes` itself.
- `C_EventUtils.IsEventValid` checks (`validateEventName`,
  `refuseUnknownEvent`, about 1.5 KB) are a newcomer guarantee AceEvent does
  not give; they stay.
