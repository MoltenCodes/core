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

