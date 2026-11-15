# signalKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## signalKit (package O): publish and subscribe trims, smaller connections, bus scope reopening and method-name callbacks

**signalKit (package O): publish and subscribe trims, smaller connections, bus scope reopening and method-name callbacks** — a change to facade `SignalKit`

1. Package `signalKit`, facade `SignalKit`, API generation 1 (additive),
   version 0.8.0 (from 0.7.7), implementation revision 11 (from 10).
2. Purpose: the measured SignalKit fixes of
   the decision 18 diagnosis (section eventKit and
   signalKit; prototype the diagnosis prototype), the handle
   memory fix, package O's probe rule, `Scope:Reopen` for ModuleKit's kept
   `Messages` scope, and decision 19c's method-name form.
   - **Fixed cost of `bus:Publish` and `subscribe`.** No `type(self)` in
     front of `getmetatable(self) ~= BUS_METATABLE` (also `:1393`, `:1402`,
     `:1950`); the probe resolved by the rule below; `type(topic)` and
     `topic == ""` only when the topic-table lookup misses (a topic record
     exists only under a validated non-empty string). The validators still
     raise every message at the caller's line.
   - **Probe rule** at `isSecret` (`:1364`), `subscribe` (`:1734`) and
     `busPublish` (`:1888`): resolved at load, per-call
     `rawget(_G, "issecretvalue")` (accepted only as a function) when it was
     absent at load.
   - **Smaller connection handles.** `{ callback, connected, once, signal }`
     in the array part, `[5]` the bus scope for a scope's subscription;
     `_busCallback` (revision 8 and older) is kept by the conversion only.
     Raw signals are not listed anywhere SignalKit can walk, so conversion
     is lazy: a signal created by this revision carries `_layout = 2`, and
     `Fire`, `Connect`, `Once`, `DisconnectAll` and a connection's
     `Disconnect` convert an older signal's listener array in place the
     first time they touch it (the same tables, so held handles keep
     working). `Fire` pays one field read for the marker.
   - **`Scope:Reopen()`** on bus scopes.
   - **Method-name callbacks (decision 19c)**: the counterpart of
     AceEvent's `RegisterMessage("Name", "Method")` / `RegisterMessage("Name")`
     on buses, and of CallbackHandler's `RegisterCallback(self, "event",
     "method")` on raw signals.
   Non-goals: late binding; a method form for `Unsubscribe` (a method-form
   subscription is released by its handle or its scope, since
   `Unsubscribe(topic, callback)` matches functions); journals.
3. Dependencies: unchanged, registry API 2.
4. Surface:
   - `bus:Subscribe(topic, receiver[, methodName])`,
     `bus:SubscribeOnce(topic, receiver[, methodName])`, and the same on bus
     scopes; `methodName` defaults to `topic`, as AceEvent's does. The
     method runs as `method(receiver, ...)` with the published arguments;
     unlike AceEvent, the topic is not passed (a bus subscriber never gets
     it today), which the migration table states.
   - `signal:Connect(receiver, methodName)`, `signal:Once(receiver,
     methodName)`: name required (a raw signal has no name to default to).
   - Checks and errors as in the other runtime Kits, at the caller's line:
     `<method> callback must be a function, or a receiver table followed
     by a method name`, `<method> methodName must be a non-empty string`,
     `<method> methodName must not be a secret value`, `<method> receiver
     has no method "<name>"`.
   - **Early binding** (recorded deviation from AceEvent and
     CallbackHandler, which look the method up per call): the method is
     resolved at subscribe.
   - `scope:Reopen()` → `true` when it reopened a closed bus scope, `false`
     when it was open; refused with `false, "closed"` when its bus is
     closed (an addon bus closed at logout stays closed).
5. Ownership: unchanged.
6. Performance and memory (host bench against AceEvent-3.0 messages, same
   run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | message dispatch-1 | 1.57× | 1.39× in the prototype; 1.42-1.47× expected on the bench host, where the probe fallback keeps its read |
   | message dispatch-10 | 1.06× | 0.98× |
   | message churn-warm / churn-cold | 1.56× / 1.64× | about 1.3× / 1.4× (estimate: handle 224 → 128 B) |

   Subscription bytes (measured): 224 → 128 B, a bus scope's 384 → 144 B.
   Still above AceEvent's 71 B per extra message on a pre-embedded object
   (no handle there). Method form: 136 B closure at subscribe, one extra
   Lua frame per delivery (31.7 against 19.2 ns; Ace3 late-bound 35.1 ns).
7. Tests: publish and subscribe refusals at the caller's line for every
   reordered test (secret topic, non-string, empty, unknown topic, wrong
   receiver: string, number, foreign-metatable table); probe installed
   after load honoured; array-layout handles and every connection method;
   lazy conversion of a revision 10 signal on `Fire`, `Connect` and a held
   handle's `Disconnect`, including a conversion during a dispatch of that
   signal; bus subscriptions converted; the in-place upgrade from revision
   10 keeping order and tombstone counts; method form on bus, bus scope and
   raw signal (default topic name, required name on signals, refusals,
   early binding, the arguments passed); `Reopen` on open, closed, and
   closed-bus scopes.
8. Docs: API.md (method form, `Reopen`, handle cost, conversion note),
   INTERNALS.md (layout, `_layout` marker), CHANGELOG, README (migration
   rows for `RegisterMessage` and `RegisterCallback` with a method name),
   tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.8.0,
   revision 11, 266 specs. Deviations: late binding as above; `Fire` never
   converts: an older signal is converted in place when a connect finds it
   idle, and idle bus topic signals at load, so no signal mixes layouts; no
   secret check on the receiver, which nothing compares.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## signalKit (package O): bucketed bus messages, AceBucket's RegisterBucketMessage, as a part

**signalKit (package O): bucketed bus messages, AceBucket's RegisterBucketMessage, as a part** — a change to facade `SignalKit`

1. Package `signalKit`, facade `SignalKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.0), implementation revision 12 (from 11). New
   part (ADR 0001) `SignalKit-Coalescing`
   (`src/parts/SignalKit-Coalescing.lua`, part revision 1).
2. Purpose: AceBucket-3.0's `RegisterBucketMessage` (Ace3 feature-gap
   diagnosis, section "AceBucket, AceConsole, AceConfigCmd, AceTab", work
   package 10; corpus 1/16, 1 site). Today an author pairs a SchedulerKit
   `Coalesce` handle with a bus subscription by hand, and the host bench
   leaves the message form out for that reason.
   - **Where it belongs.** In SignalKit, as a part. EventKit set the
     pattern: the subscribing Kit owns the subscription half and SchedulerKit
     the timing half (`EventKit:Coalesce` over `SchedulerKit:Coalesce`,
     SchedulerKit's *Coalescing and lanes*). SchedulerKit needs no change:
     its `Coalesce` (revision 7 and later) is used as published. SignalKit
     is required by LifecycleKit, so nearly every addon loads its core; a
     part keeps the feature out of the addons that do not use it.
   - **The calls.** `bus:Coalesce(topics, intervalSeconds, callback[, options])`
     and the same on a bus scope, `scope:Coalesce(...)`, so a module's
     `scope.Messages:Coalesce(...)` is released on disable. `callback` may be
     a function or a receiver table followed by a method name
     (`bus:Coalesce(topics, 0.5, self, "OnBucket")`), checked when the call is
     made (ADR 0003); there is no default method name, as AceBucket takes an
     explicit one. `topics` is a topic or an array of at most 32 distinct
     topics; subscribing needs no declaration, as for `Subscribe`.
   - **Semantics, those of `EventKit:Coalesce`.** The first message starts
     the interval; at its end `callback(set)` runs once. The set is keyed by
     the first published argument, every value `true`; a first argument that
     is `nil`, NaN or a secret value is keyed by the topic (a secret would
     raise as a key, ADR 0002). Options: `byTopic` (key by topic instead),
     `maxKeys` (SchedulerKit's default 256; past it new keys are refused and
     counted), `lane` (a SchedulerKit lane). The set is reused (copy what you
     keep). A raising callback is reported through the host error handler.
     AceBucket's per-key counts and its `"nil"` key stay deliberately
     different (diagnosis section 4, item 5).
   - **The handle**, as EventKit's: `Flush()`, `IsPending()`, `GetStats()`,
     `Close()`, `IsClosed()`.
   - **How it is built.** One listener closure per handle, subscribed to each
     topic through the bus (or through the scope, so the scope's sweep
     disconnects it); one SchedulerKit `Coalesce` handle in one SchedulerKit
     scope private to the part. A scope `Close`, `DisconnectAll` or a bus
     closing disconnects the subscriptions; the next delivery then sees its
     first subscription disconnected, drops the set and closes the handle,
     so nothing is delivered after the owner let go and no change is needed
     in the bus scope's member bookkeeping. If any topic's subscription is
     refused (`nil, "full"`), the ones already made are disconnected and the
     call returns `nil, "full"`.
   - **Core forwarders.** The core's bus and bus-scope prototypes carry
     `Coalesce` forwarders that call `_state.parts.Coalescing` and raise at
     the caller when it is absent:
     `SignalKit.Bus:Coalesce needs SignalKit's Coalescing part, which is not
     loaded: add signalKit\parts\SignalKit-Coalescing.lua to your embeds.xml`.
     SchedulerKit is found with `Registry:Find("schedulerKit", 1)` at each
     call that creates a handle (a found facade is kept, a miss is not);
     a missing or pre-coalescing SchedulerKit raises at the caller.
   Non-goals: arrival counts; a facade-level `SignalKit:Coalesce` over raw
   signals (a raw signal's owner already holds it and can feed a SchedulerKit
   handle directly); any SchedulerKit change.
3. Dependencies: core unchanged (registry API 2; optional eventKit,
   lifecycleKit). The part declares `"dependencies": { "schedulerKit":
   { "api": 1 } }`, so the embeds generator brings SchedulerKit and TimerKit
   along; the required graph has no cycle (SchedulerKit needs only TimerKit
   and Registry). Manifest:

   ```json
   "parts": {
     "Coalescing": {
       "description": "Bucketed bus messages: collect a burst of publishes and deliver them once per interval.",
       "revision": 1,
       "dependencies": { "schedulerKit": { "api": 1 } }
     }
   }
   ```
4. Surface: `bus:Coalesce(topics, intervalSeconds, callback[, options])`,
   `bus:Coalesce(topics, intervalSeconds, receiver, methodName[, options])`,
   the same two on a bus scope; the handle methods above. `BUS_METHODS` and
   `BUS_SCOPE_METHODS` gain `Coalesce`. Refusals at the caller: a closed
   bus or scope, a bad topic (as `Subscribe`), more than 32 topics, a bad
   interval, an unknown option (named with `describeKey`), a bad callback or
   missing method, a secret argument.
5. Ownership: a handle belongs to whoever holds it, and through its
   subscriptions to the bus or scope it was made on; it ends at `Close`, or
   at the first delivery after its subscriptions were disconnected. The
   part's state (`revision`, the found SchedulerKit, its private
   SchedulerKit scope) lives in `_state.parts.Coalescing`; the highest part
   revision wins and upgrades in place. Upgrade from revision 11: the state
   gains `parts`; nothing else changes.
6. Performance and memory. Host bench `buckets` (EventKit `Coalesce` against
   AceBucket-3.0's `RegisterBucketEvent`), one run on 2026-11-15: record-event
   1.80×, burst 1.70×, register-remove 2.30×. Expected for the message form
   in phase 2, with a new case pair against `RegisterBucketMessage`
   (a `buckets` workload addition): record-message and burst within 1.1× of the event
   form's ratios (a bus publish to one subscriber is 1.58× of AceEvent's
   `SendMessage`, documented), register-remove about the event form's.
   Publish paths of topics without a bucket are untouched: the core gains
   only two forwarders, not on any publish or subscribe path.
   Held memory (load-and-execute footprint, debug information kept):
   SignalKit 89,324 B today; the core gains about 40 lines (the forwarders
   and the `parts` field, about 1.5 KB). The part is about 260 lines, about
   11 KB, against AceBucket-3.0's 9,788 B (AceBucket also covers events,
   which EventKit's `Coalesce` does here). Per handle: one closure (136 B
   with the method form, less for a function), one subscription handle per
   topic (161 B, or 194 B through a scope), and SchedulerKit's coalesce handle
   with its two sets.
7. Tests (`Coalescing_spec.lua`): one delivery per interval with the first
   message starting it; keys by first argument, `nil`/NaN/secret keyed by
   topic, `byTopic`; several topics; `maxKeys` refusal counted; lane
   delivery; `Flush`, `IsPending`, `GetStats`, `Close`; method form and its
   registration check; scope `Close`, `DisconnectAll`, `Reopen` and the bus
   closing all stopping delivery and closing the handle; partial
   subscription refusal; a raising callback reported; argument errors at the
   caller; the forwarders without the part; the part without its core (ADR
   0001 message); no SchedulerKit, and one without `Coalesce`; upgrade from
   revision 11 keeping buses and subscriptions; a part revision upgrade in
   place.
8. Docs: API.md (a *Bucketed messages* section, surface tables, errors,
   *Embedded copies and revision upgrades*), INTERNALS.md (the forwarders,
   part state, the lazy close), README (AceBucket `RegisterBucketMessage` and
   `UnregisterBucket` migration rows), CHANGELOG 0.9.0, tests/README,
   `src/.luarc.json`, the client suite (one bucket fed by `Publish` across
   two frames). For the shared files: the migration guide's
   `RegisterBucketMessage` row; SchedulerKit's *Coalescing and lanes* can
   name the bus form beside EventKit's when its owner next edits it.
9. Status: implemented 2026-11-15, 0.9.0, revision 12, 281 specs; the
   Coalescing part holds 17.6 KB (AceBucket 9.8 KB), the core gains about 1
   KB. One listener per topic rather than per handle, because a message with
   no first argument is keyed by its topic.

**Minimal core (2026-11-16)**

Status: recorded 2026-11-16; code follows.

Measured on host Lua 5.1.5 (64-bit), debug information kept as the client keeps
it, on the shared fake client, string table pre-grown (the method of the
2026-11-15 memory diagnosis). "Measured" means a research copy with the change
applied was loaded and executed; "priced" means summed from measured prototype
sizes.

**Diagnosis**

**What SignalKit holds today (0.9.0, revision 12)**

| | SignalKit core | Coalescing part | CallbackHandler-1.0 (Ace3 `5e2e0d3b`) |
|---|---:|---:|---:|
| Resident after load, debug kept | 90,379 B | 17,698 B | 10,422 B |
| Resident, `luac -s` | 63,221 B | 11,823 B | about 6 KB |
| Live prototype arrays | 58,672 B | 13,528 B | 7,640 B |
| Transient while loading (per embedding addon) | 287,396 B | 54,850 B | 25,446 B |
| Constant strings in live code | 9,300 B (60 prose strings, 4,036 B) | 2,999 B (19, 1,231 B) | 1,407 B (9, 760 B) |
| Source lines: code / comments / LuaCATS / blank | 1,693 / 442 / 732 / 253 | 325 / 56 / 105 / 45 | |

Core is 8.7x CallbackHandler. Live prototypes by section: Facade methods 9,248 B,
Listener storage 7,784 B, Bus methods 7,616 B, Signal methods 7,608 B, Logout
close 6,288 B, Bus scopes 6,024 B, Journals 5,288 B, Bus validation 3,792 B, Bus
topics 2,664 B. Largest functions: `obtainBus` 1,952 B, `busPublish` 1,896 B,
`subscribe` 1,896 B, `busUnsubscribe` 1,752 B, `journalFire` 1,336 B,
`busDeclareTopic` 1,248 B, `fire` 1,240 B, `readTopicOptions` 1,232 B,
`LogoutClose.arrange` 1,232 B. The schema upgrades (`upgradeSchemaOne` to
`Five`), the surface and state validators and `installPartMethods` run only at
load and are freed (27,488 B); they are not a resident cost.

Per object (400 kept, after a warm-up object):

| Object | SignalKit | CallbackHandler | |
|---|---:|---:|---|
| Signal / registry | 468 B (`New`) | 1,212 B (`CallbackHandler:New`, closures per registry) | 0.4x |
| Connection, function | 169 B | 72 B (pre-made owner object) | 2.3x |
| Connection, method form | 305 B | 208 B | 1.5x |
| Bus subscription, one topic | 112 B | | |
| Bus subscription, new topic each | 574 B | 208 B (new event each) | |
| Bus scope | 468 B | | |
| Journal, capacity 128 | 37,716 B | | |

**Classification**

Usage read from every `src/` file: the Kits that depend on SignalKit
(LifecycleKit, EventKit, CommKit, OptionsKit, SettingsKit, MediaKit, the
EventKit and WidgetKit parts) use raw signals only: `New`, `Connect`, `Once`,
`Fire`, `DisconnectAll`, `Connection`. LifecycleKit also calls `CloseAddonBus`
at each addon's shutdown, and ModuleKit calls `ForAddon` for a module's
`Messages` scope when one is asked for. Nothing outside SignalKit calls
`NewJournal`, `Bus`, `SetLimits` or `GetLimits`. Since LifecycleKit requires
SignalKit, nearly every addon loads the core for raw signals alone.

The eventKit and lifecycleKit core records of the same date take SignalKit off
both cores (LifecycleKit keeps calling `CloseAddonBus` when SignalKit is
loaded). The cut here holds either way: with them, SignalKit drops out of the
smallest set altogether and is loaded by the Kits that use raw signals (CommKit,
OptionsKit, SettingsKit, MediaKit, the EventKit Coalescing and WidgetKit
Position parts), which then pay for the core only, and by authors who want
messages, who add the Bus part.

| Class | Members | Live prototypes |
|---|---|---:|
| Every user: raw signals (CallbackHandler's counterpart) | `New`, `Connect`, `Once`, `Fire`, `DisconnectAll`, `GetGeneration`, the connection handle, listener storage, method-name binding, the `onFirst`/`onLast` hooks, receiver checks | 14,464 B |
| Every user, cold: handles in the named-field layout (signals revisions 10 and older created) | `convertToArrayLayout`, `isNamedLayoutHandle`, `connectedKeyOf`, `tombstoneCount`, and the layout branches in the hot functions | 1,816 B plus the branches |
| Every user: package limits (they guard part memory, but `SetLimits`/`GetLimits` keep one shape) | `SetLimits`, `GetLimits`, `validateLimitEntry`, `validateLimitUpdate`, `isIntegerUpTo`, `describeKey`, `refuseSecret` | 3,576 B |
| Some users: named buses (AceEvent-3.0's messages) | `Bus`, topics, `DeclareTopic`, `Publish`, `Subscribe`, `SubscribeOnce`, `Unsubscribe`, `Topics`, `CloseAddonBus`, isolated delivery | 20,376 B |
| Some users: bus scopes | `CreateScope` and the scope methods | 6,352 B |
| Some users: logout close of an addon's bus | `ForAddon`, `LogoutClose.*` | 6,800 B |
| Some users: journals | `NewJournal`, `Fire`, `History`, the ring | 5,288 B |

Duplicated helpers (`tooling.shared.sync --list`): `SignalKit.lua:695 isSecret`,
`:1649 validateFacade`, `:2929 describeKey`, `:2976 limits`;
`SignalKit-Coalescing.lua:124 isSecret`, `:138 reportError`, `:181 describeKey`.
What converting saves, priced from the shared sources: nothing. `isSecret` is the
same size (464 B), `validateFacade` +56 B, `describeKey` +80 B (it asks
`isSecret` first), the `limits` block (3,296 B for its four functions) with
the shorter `SetLimits`/`GetLimits` it allows comes to about +800 B over the
hand-written seven; the Coalescing part's three copies about +130 B. The gain is
one body per helper under the `--check` gate, not memory.

**signalKit: raw-signal core, Bus and Journal parts** — a change to facade `SignalKit`

1. Package `signalKit`, facade `SignalKit`, API generation 1 (unchanged, the
   facade gains `HasPart`), version 0.10.0 (from 0.9.0), implementation
   revision 13 (from 12). Minor. New parts, revision 1 each: `Bus`
   (`src/parts/SignalKit-Bus.lua`) and `Journal`
   (`src/parts/SignalKit-Journal.lua`). `Coalescing` goes to part revision 2.
2. Purpose: the core every addon loads holds raw signals only, the counterpart
   of CallbackHandler-1.0; the message bus, the counterpart of AceEvent-3.0's
   messages, and the journals are parts.
   - **S1 Bus part**: named buses, topics and their argument policies,
     `Publish`/`Subscribe`/`SubscribeOnce`/`Unsubscribe`/`Topics`, bus scopes,
     `ForAddon` with the logout close, and isolated delivery
     (`securecallfunction`, or the `xpcall` staging buffer elsewhere). The
     scopes and the logout close stay in this part rather than parts of their
     own: ModuleKit's `Messages` scope and `ForAddon` are how buses are used.
   - **S2 Journal part**: `NewJournal`, `Journal:Fire`, `Journal:History`.
   - **S3 Parts plumbing** (the ADR 0001 contract as the other split Kits keep
     it): `SignalKit:HasPart(name)`; `_state.parts` (exists since revision
     12), `_state.helpers` (the core functions a part calls: `attach`,
     `disconnectConnection`, `disconnectEveryListener`, `newSignalTable`,
     `bindMethod`, `reportError`, `describeKey`, read at call time on cold
     paths) and `_state.partInterface = 1`; a commit that reinstalls installed
     parts' methods (as `installPartMethods` does for Coalescing today).
     `CloseAddonBus` without the Bus part answers `false` after its argument
     checks, which is exact (no addon bus can exist), so LifecycleKit's
     shutdown keeps working unchanged. `Fire` on an `_isolated` signal calls
     the Bus part's isolated walk through `_state.parts.Bus`; only topic
     signals carry the flag, and they exist only with the part.
   - **S4 Cold named-field layout.** The handling of handles in the
     named-field layout becomes functions created only when this copy inherits
     state from revision 12 or older, recorded as `_state.namedLayouts = true`
     (sticky, so a later revision that inherits from 13 still knows). The hot
     functions keep one `_layout ~= 2` test and call through
     `_state.namedLayout` for such a signal. In a session where no revision
     older than 13 was loaded, the code is freed after load.
   - **S5 Shared helper blocks**: `isSecret`, `validateFacade` and
     `describeKey` in the core; the parts take `isSecret` and `reportError`
     blocks (`isSecret` is on the Coalescing and Bus delivery paths) and read
     `describeKey` through `_state.helpers`. `limits` stays hand-written and
     SignalKit is pinned out of it in `tooling/shared/pins.json` with the
     reason the other Kits' opt-outs give (the block measures more resident
     than the Kit's own loop; kept until a leaner revision of the block). Its
     messages already match the block's, so converting later changes no text.
   - **S6 State created by its owner.** A fresh state no longer creates the
     journal prototype and metatable or the logout watcher; the parts create
     them on install. The bus and scope prototypes and metatables stay core
     state, so Coalescing part revision 1, which checks them at file scope, and
     every inherited bus keep working.
   Non-goals: any change of bus, signal or journal semantics, of per-object
   layouts, or of the hot paths' order of checks.
3. Dependencies: core unchanged (registry API 2; optional eventKit and
   lifecycleKit, now only through the Bus part's logout close, so they move to
   that part's `optionalDependencies`). Manifest parts:
   `"Bus": { "revision": 1, "optionalDependencies": { "eventKit": { "api": 1 }, "lifecycleKit": { "api": 1 } } }`,
   `"Journal": { "revision": 1 }`, and `Coalescing` gains `"parts": ["Bus"]`
   and `"revision": 2`. Other owners (text in the report): ModuleKit names
   `signalKit` parts `["Bus"]` for its `Messages` scope and asks
   `SignalKit:HasPart("Bus")` so its error is raised at the author's line with
   the file to add.
4. Surface: unchanged names. `Bus`, `ForAddon`, `NewJournal` stay on the facade
   (older copies' `validatePublicSurface` tests them); without their part each
   raises at the caller's line:
   `SignalKit:Bus is in SignalKit's Bus part, which is not loaded: add signalKit\parts\SignalKit-Bus.lua to embeds.xml after signalKit\SignalKit.lua`.
   `SetLimits` and `GetLimits` keep all three limits whichever parts are
   loaded. New: `SignalKit:HasPart(name)`. Embedding: an addon that uses buses
   adds `SignalKit-Bus.lua` (the generated `embeds.xml` does, from a manifest
   or a selection); one that uses journals adds `SignalKit-Journal.lua`. The
   migration guide's `SendMessage`/`RegisterMessage` rows name the Bus part.
5. Ownership: unchanged. Each part keeps `_state.parts.<Part>` with its
   `PART_REVISION`; the highest wins and upgrades in place. In-place upgrade
   from revision 12 (the shared rule for splits): with the Bus part loaded,
   it adopts the buses, topic records, signals, subscriptions and scopes as
   they are (layouts unchanged) and every held handle keeps working; without
   it, the core closes every inherited bus at takeover (the terminal close
   `CloseAddonBus` performs), installs the stubs, and reports once through
   `geterrorhandler()` which part to embed. Inherited journals keep their
   slots and work again when the Journal part loads; without it, a journal's
   `Fire` (on its own prototype) is a stub naming the part, and it still fires
   as a signal through `SignalKit.Fire`. A revision 12 copy loaded after
   revision 13 yields and its addon gets the stub's error. No revision was
   ever published.
6. Performance and memory (resident, debug kept):

   | Change | Resident | Basis |
   |---|---:|---|
   | core today | 90,379 B | measured |
   | S1 + S2 + S3 stubs | 36,876 B (-53,503 B, -59%) | measured (research copy) |
   | S4 | about -2,500 B | priced (1,816 B of prototypes plus the branches) |
   | S5 | about +400 B | priced from the shared sources (`limits` not converted) |
   | S6 | about -900 B | priced (journal tables, watcher table) |
   | core target | at most 35,000 B (CallbackHandler 10,422 B) | |
   | Bus part, when loaded | about 52,000 B | priced (33,528 B of prototypes plus its header) |
   | Journal part, when loaded | about 9,500 B | priced |
   | Coalescing part revision 2 | about 17,800 B | priced |

   Transient per embedding addon: 287,396 to about 138,000 B (measured for the
   research copy). The smallest set (Registry, SignalKit, EventKit,
   LifecycleKit, TimerKit) with the Registry record: 341,282 to 279,799 B
   measured (Ace3: 54,010 B). An addon that uses everything pays about 7%
   more than today (one header and bootstrap per part). Per object nothing
   changes; a signal stays at 468 B against a CallbackHandler registry's
   1,212 B. What stays above CallbackHandler buys the documented guarantees:
   explicit connection handles, amortised O(1) disconnect with tombstones,
   re-entrant dispatch without a per-`Fire` snapshot, argument errors at the
   caller's line, the method form checked at registration, secret-value
   refusal. Bench cases `signals` and `message` against Ace3 in phase 2;
   publish and subscribe paths are moved, not changed, so the message ratios
   should stay within noise.
7. Tests: the moved specs (`Bus_spec`, `BusIsolation_spec`, `BusScope_spec`,
   `LogoutClose_spec`, `Journal_spec`, `Coalescing_spec`) run with the parts
   loaded and pass unchanged; without each part, each moved member raises at
   the caller with the file to add, `CloseAddonBus` answers `false`, and
   `HasPart` answers `false`; either load order of core and part; a part
   without its core raises the ADR 0001 message; Coalescing without the Bus
   part refuses at load; in-place upgrade from revision 12 (byte copy of the
   current file as the fixture) with live buses, subscriptions, a scope, an
   addon bus arranged for logout and a journal: with the parts every handle
   keeps working; without them the buses are closed and reported once; S4
   with a named-field signal inherited through revision 12, and a 13-to-14
   in-place upgrade keeping `namedLayouts`; `SetLimits`/`GetLimits` messages
   unchanged. Conformance: opt in with all
   groups (`manifest` with each part's revision, `limits` for the three limits,
   `receivers`, `arguments`, `upgrade`). Client suites
   (`tests/client/MoltenCodesTest_SignalKit/`, never run): the `.toc` loads the
   parts; one stub error with the core alone.
8. Docs: README (parts, embedding, migration rows for CallbackHandler and
   AceEvent messages), `docs/API.md` (each bus and journal section names its
   part; `HasPart`; the section skeleton `docs/CONTRIBUTING.md` defines),
   `docs/INTERNALS.md` (part state, helpers, the cold named-field layout),
   `CHANGELOG.md` 0.10.0, `tests/README.md`, `src/.luarc.json`. Shared files (kept by their owner): `docs/MIGRATING_FROM_ACE3.md` (the `SendMessage`,
   `RegisterMessage`, `RegisterBucketMessage` rows name the parts),
   `docs/EMBEDDING.md` footprint and load order, `packages/README.md`,
   coverage floors for the new part files if they are tracked per file.
9. Status: recorded 2026-11-16; code follows.
