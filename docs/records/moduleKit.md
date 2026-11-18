# moduleKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## moduleKit (package O): kept module scopes, cheaper enables, the probe rule and an opt-in missing-Kit error

**moduleKit (package O): kept module scopes, cheaper enables, the probe rule and an opt-in missing-Kit error** — a change to facade `ModuleKit`

1. Package `moduleKit`, facade `ModuleKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.8), implementation revision 22 (from 21).
2. Purpose: the moduleKit fixes F1-F3 of
   the decision 18 diagnosis (section lifecycleKit
   and moduleKit; prototype the diagnosis prototype),
   package O's probe rule, decision 19b where it applies here, and the
   AddonKit's request for an opt-in error when a module reads a
   scope field whose Kit is not loaded (2026-11-15).
   - **F1, kept scopes.** A module's Kit scopes are closed on disable, as
     today, but kept on the module (`_parkedScopes`, created on first use).
     On the next enable, the first read of a field reopens the kept scope
     with its Kit's `Scope:Reopen()` when the Kit has it (TimerKit, EventKit,
     SignalKit bus scopes, HookKit and SchedulerKit after this package), and
     otherwise creates a new one as today (CommKit and CommandKit until
     their owners add `Reopen`; any older revision). This skips the
     Registry lookup (`findOptionalPackage`) and the construction on every
     enable after the first. A kept scope whose `Reopen` answers `false` or
     raises is dropped and a new one created, so a reopen failure never
     reaches the module.
   - **F2, flag before the blocked-dependents scan.** `recoverBlockedDependents`
     (`:2357`) scans every module on every `Enable` and nearly always finds
     nothing. The container keeps `_mayHaveBlocked`, set to `true` at each of
     the 12 places `_enableBlockedBy` is written and to `false` when a scan
     finds nothing; `false` skips the scan, and `nil` (a container an older
     revision made) scans as today.
   - **F3, halt read from the record.** The two halt checks per enable read
     `rawget(lifecycle, "_halted") == true` instead of calling `IsHalted`;
     LifecycleKit documents the field in its own record of package O.
   - **Probe rule.** `issecretvalue` stays resolved at load (`:342`) and
     gains the per-call fallback (`rawget(_G, ...)`, accepted only as a
     function) when it was absent at load.
   - **Decision 19b.** `scopeIndex` (`:1777`), the scope's `__index`,
     refuses a secret key before `SCOPE_PACKAGES[key]`. The client raises on
     `scope[secret]` before `__index` runs (`docs/EMBEDDING.md`, measured on
     Retail 12.1.0), so the check never runs there; it goes. The checks on
     keys of caller tables read with `next` (`:1355`, `:1530`, `:3259`,
     `:3316`, `:4047`) wait for the client proof described in the
     schedulerKit record, point 7.
   - **Missing scope Kits as an error, opt-in.** See point 4.
   Non-goals: one `pcall` per transition in whole-addon passes (F5, at most
   5%), the other AceAddon conveniences of the Ace3 gap list (a later package O record), any
   method-name form (AceAddon calls `OnInitialize`/`OnEnable`/`OnDisable` by
   name already, as ModuleKit does through definitions).
3. Dependencies: unchanged, registry API 2, lifecycleKit API 1; the scope
   Kits stay optional and are found through `Registry:Find`.
4. Surface:
   - **Scope identity (behaviour change).** `module.scope.Events` (and every
     field whose Kit has `Reopen`) is the same object across enable cycles;
     today it is a new one each time. A reference kept from an earlier
     enabled period raises while the module is disabled, as now, and works
     again after re-enable. The module-scope rules in API.md change from
     "the next enable starts with fresh scopes" to "the next enable starts
     with empty scopes, the same objects where the Kit can reopen them".
   - **`addon:SetMissingScopePolicy(policy)`** → previous policy, and
     **`addon:GetMissingScopePolicy()`**; `policy` is `"nil"` (default,
     today's behaviour) or `"raise"`. Under `"raise"`, reading a scope
     field whose Kit is not loaded, or is a revision without owner scopes,
     raises at the reading line (the `__index` raises at level 2):
     `ModuleKit module "<module>" scope.Timers needs TimerKit API 1, which is
     not loaded; add timerKit/TimerKit.lua to your embeds.xml`. The file
     named is the Kit's facade file under the release layout's package
     folder; phase 2 takes the folder names from `.pkgmeta` and, if the
     tooling's generated `embeds.xml` changes them, from its output.
     `Messages` with SignalKit loaded but its bus full or closed keeps
     reading `nil` under either policy: that is a runtime state, not a
     missing file. A secret or non-string policy raises at the caller.
     AddonKit sets `"raise"` on its addon objects. A definition field
     `missingScopePolicy` is not added (one way to set it).
5. Ownership: a disabled module retains its kept, closed, empty scopes until
   the module is collected with its container (containers live for the
   session, as today).
6. Performance and memory (host bench `addonModules` against AceAddon-3.0,
   same run; the host's Lua `xpcall` stand-in flatters AceAddon, see the
   diagnosis):

   | Case | Before | Expected after |
   |---|---:|---:|
   | disable-enable-module | 1.54× | 1.21× (F2 + F3: 323 → 253 instructions per cycle) |
   | disable-enable-all | 1.31× | 1.18× |
   | disable-enable-all-listening | 2.21× | 1.58× (with EventKit's plain links); 7,784 → 3,944 B per cycle, to fall further when every scope Kit reopens |
   | create-addon / load-addon | 0.77× / 0.99× | unchanged |

   Held memory: a disabled module keeps up to 7 empty scopes (a TimerKit
   scope 308 B, an EventKit scope 404 B), where today it keeps none; an
   enable cycle allocates nothing for a reopened scope instead of a new
   scope each time. The policy is one field on the container, written only
   when set; its test runs only on the branch that answers `nil` today, so
   the default costs nothing.
7. Tests: the same scope object across enable cycles for each reopening Kit,
   a fresh one for a Kit without `Reopen` (a stand-in), a `Reopen` that
   raises or answers `false`; a reference kept across a disable raising,
   then working after re-enable; scopes still closed in the fixed order on
   every way out (disable, failed `OnEnable`, shutdown, halt);
   `_mayHaveBlocked` through each of the 12 writes (blocked dependencies,
   strict policy, halts, late modules) and a container of revision 21
   scanning; halt checks through `_halted`, and a LifecycleKit stand-in
   without it; probe installed after load honoured; the missing-scope
   policy: default `nil` unchanged, `"raise"` raising at the reader's line
   with the file name for each of the seven fields, `Messages` with a full
   bus still `nil`, policy argument errors; in-place upgrade from revision
   21 keeping modules, states and open scopes.
8. Docs: API.md (module scopes: identity and kept scopes, the missing-scope
   policy, the surface table, errors), INTERNALS.md (`_parkedScopes`,
   `_mayHaveBlocked`, the halt read), CHANGELOG, README, tests/README. For
   the shared documents: `MIGRATING_FROM_ACE3.md`'s module-scope paragraph if it says
   scopes are new per enable.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 22, 264 specs. The policy methods are `SetMissingScopePolicy` and
   `GetMissingScopePolicy` as recorded; the error names the file as
   `<packageId>\<Facade>.lua` from MoltenCodes.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## moduleKit (package O): the AceAddon conveniences: intended state, module defaults and prototypes, finding addons, a module-created notice

**moduleKit (package O): the AceAddon conveniences: intended state, module defaults and prototypes, finding addons, a module-created notice** — a change to facade `ModuleKit`

1. Package `moduleKit`, facade `ModuleKit`, API generation 1 (additive),
   version 0.10.0 (from 0.9.0), implementation revision 23 (from 22).
   No part: see point 6 for why these stay in the core.
2. Purpose: close the AceAddon-3.0 gaps the Ace3 feature-gap diagnosis
   measured (section "AceAddon", work package 7), so an Ace addon ports
   without restructuring. Corpus use (16 open-source Ace3 addons):
   `SetEnabledState` 5/16 (39 sites), `SetDefaultModulePrototype` 5/16,
   `NewModule(name, prototype)` 3/16 (9 sites), `GetAddon` 5/16 (49 sites),
   `OnModuleCreated` 3/16, `SetDefaultModuleState` 1/16, `IterateAddons`
   0/16.
   - **Intended state without running hooks.** `module:SetEnabledState(enabled)`
     writes the module's intent (`wanted`, `docs/API.md` *Intent versus
     fact*) and nothing else: no hook runs, the fact does not change, and
     `blockedBy` is cleared when `enabled` is `false`, as `Disable` clears
     it. Before the addon is ready, `false` keeps the module out of the
     `ready` pass (the pass already skips modules that are not wanted).
     After ready it changes what recovery and `GetEnableState` see; `Enable`
     and `Disable` still change the fact. AceAddon's `SetEnabledState` is
     the same: a flag the next enable pass reads.
   - **Default state.** `addon:SetDefaultModuleState(enabled)` sets the
     starting intent of modules created afterwards. AceAddon refuses the call
     once a module exists; ModuleKit applies it forward instead, because an
     AddonKit addon object is itself the module `"Main"` and always exists
     first. A definition field `enabledState` (boolean) overrides it per
     module: a definition-table module catches up inside `CreateModule`, so
     its intent must be known before that.
   - **Catch-up honours intent.** The implicit catch-up of a definition-table
     module created after ready enables it only when it is wanted, as the
     `ready` pass does. Today every such module starts wanted, so no existing
     behaviour changes. `module:Activate()` is an explicit request and still
     enables, as today.
   - **Module prototypes.** `addon:SetDefaultModulePrototype(prototype)` (or
     `nil` to clear) and a definition field `prototype` (a table, or `false`
     for none when a default is set). A module's lookup order is: its own
     fields, then ModuleKit's `Module` methods (framework methods win and
     stay upgradable in place), then the prototype. A prototype chosen at
     creation stays the module's prototype; changing the default later
     affects later modules only, as in AceAddon. Hooks (`OnInitialize`,
     `OnEnable`, `OnDisable`) are found on the prototype too, so AceAddon's
     "prototype carries a shared `OnEnable`" ports unchanged (AdiBags' use).
     Refused at the caller: a prototype that is not a table or is secret, and
     a prototype whose own key (read with `next`, keys checked for secrets
     first, ADR 0002 point 2) names a `Module` method, `scope`, or begins
     with `_` (ModuleKit's private fields).
     Implementation: one **layer** table per distinct prototype, kept in the
     package state in a weak-keyed map. The layer holds a copy of the
     `Module` methods and has `{ __index = prototype }` as its metatable;
     a prototyped module's metatable is `{ __index = layer }`, shared by
     every module with that prototype. A lookup is therefore table hops
     only (own, layer, prototype), no function `__index`. Modules without a
     prototype keep today's `MODULE_METATABLE` and pay nothing. An in-place
     upgrade refreshes every layer from the new `Module` table (copy the
     current methods, drop names that are no longer methods), so prototyped
     modules gain the new revision's methods as plain modules do.
   - **Finding addons.** `ModuleKit:FindAddon(name)` returns the container or
     `nil` and never creates one (`ForAddon` creates). A raising form is not
     added: `nil` plus the caller's own `assert` already raises at the
     caller's line. `ModuleKit:GetAddons()` returns a new sorted array of
     container names (diagnostics; it allocates). Status per addon is
     `addon:GetModules()` and each module's `IsEnabled` / `GetEnableState`.
   - **Module-created notice.** `addon:OnModuleCreated(callback)` or
     `addon:OnModuleCreated(receiver[, methodName])` (method name defaults to
     `"OnModuleCreated"`, checked when registered, ADR 0003) subscribes to the
     topic `"ModuleKit.ModuleCreated"` on the addon's SignalKit bus
     (`SignalKit:ForAddon(addonName)`), declaring it once with
     `arguments = 1`. It returns the bus subscription (a SignalKit
     connection: `Disconnect`, `IsConnected`), or `nil, "full"` at the bus
     limits. `CreateModule` publishes `(module)` after the module is
     published in the container and before its catch-up, so a listener can
     still give a late definition module fields before it initializes. A
     listener error is isolated and reported by the bus (AceAddon uses
     `safecall` the same way); `CreateModule` still returns the module. The
     bus is only touched once someone subscribed: until then `CreateModule`
     pays one `rawget`. A module's own `scope.Messages` can subscribe to
     the same topic and is released on disable like any subscription.
   - **Locals.** The main chunk stays at or under 195 active locals (the
     `lua_limits` ratchet only goes down): the new functions are fields of
     one table, `addonConveniences`, into which `missingScopePolicyMethods`
     and the two dependency-policy methods move (net 195 to 193; the ratchet
     entry is lowered to the measured value).
   Non-goals: `NewAddon(object, name)`, mixins, `IterateEmbeds`,
   `SetDefaultModuleLibraries`, `OnEmbedEnable` (kept different, Ace3
   feature-gap diagnosis section 4, items 3 and 4); a raising `GetAddon`;
   moving "Halted addons" (18.0 KB of prototypes) into a part (worth its own
   record).
3. Dependencies: registry API 2 and lifecycleKit API 1, unchanged.
   `signalKit` API 1 is added to `optionalDependencies` and found through
   `Registry:Find` on the first `OnModuleCreated`. In practice it is always
   loaded: LifecycleKit requires it. A host without it raises at the caller:
   `ModuleKit.Addon:OnModuleCreated needs SignalKit API 1, which is not loaded`.
4. Surface (all additive):

   | Member | Returns | Notes |
   |---|---|---|
   | `module:SetEnabledState(enabled)` | previous intent (boolean) | refused after shutdown, like `Enable`; a non-boolean or secret raises at the caller |
   | `addon:SetDefaultModuleState(enabled)` | previous default | default `true` |
   | `addon:GetDefaultModuleState()` | boolean | |
   | `addon:SetDefaultModulePrototype(prototype)` | previous prototype or `nil` | `nil` clears |
   | `addon:GetDefaultModulePrototype()` | table or `nil` | |
   | `addon:OnModuleCreated(callback)` / `(receiver[, methodName])` | SignalKit connection, or `nil, "full"` | |
   | `ModuleKit:FindAddon(name)` | container or `nil` | |
   | `ModuleKit:GetAddons()` | new sorted array of names | |
   | definition `enabledState` | | boolean |
   | definition `prototype` | | table or `false` |

   Error messages follow the Kit's form, for example
   `ModuleKit.Addon:SetDefaultModulePrototype prototype key "Enable" shadows ModuleKit's Module:Enable`
   and `ModuleKit.Module:SetEnabledState enabled must be a boolean`.
5. Ownership: a prototype is referenced by the modules created with it and,
   while it is the default, by the container; its layer lives as long as the
   prototype (weak key). The module-created subscription belongs to the
   addon's bus: it ends with `Disconnect`, or when the bus closes at logout.
   Containers still live for the session.
6. Performance and memory. Host bench `addonModules` against AceAddon-3.0,
   one run on 2026-11-15 (Lua 5.1.5, 3 rounds):

   | Case | Before | Expected after |
   |---|---:|---:|
   | create-addon | 0.78× | 0.78× (± noise: one `rawget` per `CreateModule`) |
   | load-addon | 1.02× | 1.02× |
   | disable-enable-module | 1.23× | 1.23× (a hook missing on a plain module costs one extra `rawget` for `_prototype`) |
   | disable-enable-all | 1.14× | 1.14× |
   | disable-enable-all-listening | 1.62× | 1.62× |

   New measurement in phase 2 (host micro-benchmark beside the bench, same
   run, both sides): a method call through a prototype, target at most 1.3×
   AceAddon's (two table hops against one); `GetEnableState`-free paths
   unchanged.
   Held memory (load-and-execute footprint, debug information kept, one
   process): ModuleKit 137,205 B today against AceAddon-3.0 27,041 B. The
   additions are about 330 lines, about 13 KB at the measured 35 to 44 KB per
   1,000 lines: expected about 150 KB. Why not a part: the two largest pieces,
   prototypes (about 4.5 KB) and the created notice (about 2 KB), both hook
   into `CreateModule` and `invokeHook`, so the core would keep forwarders
   and checks for them, and a part's fixed cost (header, bootstrap, state
   checks, about 1.5 KB) would take a third of the saving. Per object: a
   module without a prototype is unchanged (933 B); a prototype costs one
   layer (about 1.3 KB, the `Module` methods' hash part) per distinct
   prototype, not per module; a container gains at most three fields, written
   only when set.
7. Tests: `SetEnabledState` before load, before ready (the module stays
   off, its dependents are blocked as for a `Disable`), after ready (fact
   unchanged; recovery skips it), after shutdown (refused), argument errors at
   the caller; default state applied to later modules only, overridden by
   `enabledState`; a late definition module with `enabledState = false`
   initialized but not enabled, and `Activate` still enabling a mutable one;
   prototypes: lookup order (own, framework, prototype), hooks from the
   prototype in all three phases and in `implements`, a per-module prototype,
   `prototype = false` against a default, refusals (non-table, secret,
   secret key, framework name, `scope`, `_` key) leaving no module, layer
   sharing between modules, a prototype with its own metatable; an in-place
   upgrade from revision 22 that keeps every container and module and
   refreshes layers (a method added by the new revision reaches a prototyped
   module); `FindAddon` never creating, `GetAddons` sorted and fresh;
   `OnModuleCreated`: function and method forms, missing method refused at
   registration, order (published, then catch-up), a raising listener
   reported while `CreateModule` returns the module, `nil, "full"` at the bus
   limit, `Disconnect`, nothing published before the first subscription, the
   missing-SignalKit refusal with a stand-in Registry; the lua_limits
   measurement of the main chunk (195 to 193).
8. Docs: API.md (surface tables, *Intent versus fact*: `SetEnabledState`,
   defaults and catch-up; a new *Module prototypes* section; *Creating
   modules*: the two definition fields; a *Finding addons* section; the
   created notice; *Argument and state errors*; *Cost*), INTERNALS.md (layers
   and their upgrade, the `_prototype` field, the hook fallback, the bus
   topic), README migration table (`SetEnabledState`, `SetDefaultModuleState`,
   `SetDefaultModulePrototype`, `NewModule(name, prototype)`, `GetAddon`,
   `IterateAddons`, `OnModuleCreated`), CHANGELOG 0.10.0, tests/README, the
   client suite (two tests: a prototype hook at login, `SetEnabledState(false)`
   keeping a module off through `ready`). For the shared migration guide:
   the AceAddon rows above leave "What has no equivalent yet".
9. Status: implemented 2026-11-15, 0.10.0, revision 23, 288 specs; 151.5 KB
   held (137.7 KB before; AceAddon 27.0 KB). The prototype map is not weak-
   keyed: Lua 5.1 has no ephemeron tables, so a weak key would not free a
   prototype. The main chunk is down to 193 locals.

**moduleKit (core slimming): injection, implements contracts and required addons as parts, the upgrade floor** — a change to facade `ModuleKit`

Measurements, classification, the upgrade floor and the part contract:
`core-runtime.md`.

1. Package `moduleKit`, facade `ModuleKit`, API generation 1 (additive),
   version 0.11.0 (from 0.10.0), implementation revision 24 (from 23). New
   parts `Injection`, `Implements` and `RequiredAddons`, revision 1.
2. Purpose: ModuleKit is the largest file of the runtime set, 150.7 KB
   resident (103.0 KB of live prototypes), against 27.0 KB for AceAddon-3.0,
   which also holds the lifecycle; a container costs 4,203 B on top of its
   LifecycleKit instance (AceAddon's `NewAddon` 1,771 B for both). What every
   ModuleKit user needs: containers, modules and their hooks, the module
   graph and its policies (AddonKit's every `NewModule` depends on `"Main"`,
   `AddonKit.lua:944-962`, so the graph is part of the entry point of ADR
   0004), module scopes, intent versus fact, the AceAddon conveniences
   (default state, prototypes, `FindAddon`, the created notice) and the
   reaction to the addon's own halt (a halt can come from any addon that
   embeds LifecycleKit's Halt part, so this reaction cannot live in an
   optional part of ModuleKit). The changes, each measured on a research copy
   with the bodies in question emptied unless marked priced:
   - **Injection part** (`src/parts/ModuleKit-Injection.lua`): the four
     provider kinds (`ProvideValue`, `ProvideSingleton`, `ProvideModule`,
     `ProvideTransient`), `Resolve` on the container and the module,
     `Inject` and the `inject` definition field, provider conflicts,
     resolution records and the resolution cycle stack (`resolveProvider`,
     `addInjections`, `resolveInjections`, `registerProvider`,
     `providerConflict`, `validateFactory`, `resolutionRecordMatches`,
     `resolutionLabel` and the public wrappers): −15.7 KB in the core.
     AceAddon has no injection. A hook still receives its `injections`
     argument; without the part it is the module's empty injection table,
     as today for a module that declares none, and `GetInjections` stays in
     the core (an empty snapshot without the part).
   - **Implements part** (`src/parts/ModuleKit-Implements.lua`): the
     `implements` contracts of module definitions and of provider options
     (`compileImplements`, `compileImplementsNames`,
     `compileImplementsSchema`, `checkImplements`, `isSchemaLike`,
     `describeSchemaFailure`, `readProvideOptions`): −8.4 KB. Its SchemaKit
     form keeps SchemaKit optional, as today.
   - **RequiredAddons part** (`src/parts/ModuleKit-RequiredAddons.lua`): the
     `requiresAddons` definition field and everything that follows another
     addon's halt (`addRequiredAddon`, `declareRequiredAddons`,
     `moduleRequiredAddons`, `requiresAddon`, `isOtherAddonHalted`,
     `subscribeToDependencyHalts`, `dependencyHaltedInternal`,
     `blockForHaltedAddon`): −5.5 KB (the emptied copy measured −6.3 KB with
     `lifecycleDependencyCeiling`, which stays in the core with `SetLimits`).
     `requiresAddons` declares LifecycleKit `DependsOn` edges, so this part
     requires LifecycleKit's Halt part. `maxRequiredAddons` keeps its place
     in the core's limits table and its ceiling check against LifecycleKit's
     `maxDependencies`.
   - **The upgrade floor**: the per-container and per-module fills for
     revisions before 23 (`ensureContainerRuntimeFields`,
     `ensureModuleRuntimeFields`: the dispatched-phase set rebuilt from
     LifecycleKit, `_passDepth`, `_pendingCatchUp`, `_wantedEnabled`,
     `_scopeOpen` for revisions before 6, scope creation for old modules):
     priced −2.9 KB resident. New containers are built complete by
     `createAddon`; the upgrade from revision 23 adopts containers that are
     already complete.
   - **Lazy container tables**: `_providers` and `_resolutionStack` are
     created by the Injection part on first use, `_pendingCatchUp` on the
     first deferred catch-up: priced −0.3 KB per container. With
     LifecycleKit's own phase lists (lifecycleKit record) each of the
     container's subscriptions loses its SignalKit connection: priced about
     −0.8 KB per container. Container 4,203 → ≈ 3,100 B.
   - **Plain indexing** on `state`, `state.addons`, containers, modules and
     module scopes (metatables the Kit owns) instead of literal-key
     `rawget`/`rawset`: −2.8 to −5.6 KB (upper bound measured on 349 sites).
     Module definitions, prototypes and providers' values are the author's
     tables and keep raw access; the facade and prototypes keep `rawset`.
   - **Shared helper blocks**: `isSecret` (`ModuleKit.lua:377`, 448 B →
     464 B), `describeKey` (`ModuleKit.lua:397`, 416 B → 504 B), `limits`
     (`ModuleKit.lua:4527`, `validateLimitUpdate` and the copy loops of
     `setLimits`/`getLimits` → the block with one `LIMIT_RULES` entry,
     `maxRequiredAddons`, whose `check` is the LifecycleKit ceiling): priced
     +1.4 KB. These are the three copies `tooling.shared.sync --list` names
     for moduleKit.
   Non-goals: moving the graph, the dependency policies, module scopes, the
   AceAddon conveniences or intent versus fact (see "Not recorded");
   changing any message of the remaining surface.
3. Dependencies: core unchanged (registry API 2, lifecycleKit API 1;
   commKit, commandKit, hookKit, schedulerKit, schemaKit, signalKit and
   timerKit optional). Part `Injection`: none beyond the core; it uses the
   Implements part when loaded (`optionalDependencies` cannot name a sibling
   part, so the core's `HasPart("Implements")` decides at call time). Part
   `Implements`: `optionalDependencies` `schemaKit` API 1. Part
   `RequiredAddons`: `dependencies` `lifecycleKit` API 1 with `"parts":
   ["Halt"]`.
4. Surface:
   - New: `ModuleKit:HasPart(name)`.
   - Stubs without their part, raising at the caller's line with the file to
     embed: `Addon:ProvideValue`, `ProvideSingleton`, `ProvideModule`,
     `ProvideTransient`, `Addon:Resolve`, `Module:Resolve`, `Module:Inject`
     (Injection). For example `ModuleKit.Addon:ProvideSingleton is in
     ModuleKit's Injection part, which is not loaded: add
     moduleKit\parts\ModuleKit-Injection.lua to embeds.xml after
     moduleKit\ModuleKit.lua`.
   - Definition fields: `CreateModule` with `inject`, `implements` or
     `requiresAddons` and the matching part absent raises at the caller's
     line with the same message form, naming the field
     (`ModuleKit.Addon:CreateModule definition field "inject" is in
     ModuleKit's Injection part, ...`). An `implements` provider option
     without the Implements part raises the same way.
   - Unchanged: every other member, `SetLimits`/`GetLimits` with
     `maxRequiredAddons`, `UNBOUNDED`, `FindAddon`, `GetAddons`, the
     created notice, the error messages of the remaining surface.
   - Embedding: the example addon uses `ProvideSingleton`, `ProvideValue`
     and `Resolve` (`examples/Settings.lua:67`, `Commands.lua:48`,
     `Window.lua:99`), so its `embeds.xml` gains the Injection part.
5. Ownership: unchanged. Providers, resolution records and required-addon
   lists stay in the container and module records, created by their part on
   first use, so an upgraded part takes them over; the core's
   `state.dispatch` gains the entries the parts fill (`resolveForHook`,
   `dependencyHalted`), whose defaults do nothing, which is exact.
6. Performance and memory (resident):

   | Change | Saving |
   |---|---:|
   | Injection to a part (core side; 7 stubs priced at +0.7 KB) | −15.0 KB |
   | Implements to a part (core side; field check priced at +0.2 KB) | −8.2 KB |
   | RequiredAddons to a part (core side; field check priced at +0.2 KB) | −5.3 KB |
   | Upgrade floor (priced) | −2.9 KB |
   | Plain indexing on internal tables (priced) | −2.8 to −5.6 KB |
   | Shared blocks (priced) | +1.4 KB |
   | Part interface for three parts (priced) | +0.9 KB |
   | **ModuleKit core** | **150.7 → ≈ 117 KB** (AceAddon 27.0 KB: 5.6× → 4.3×) |
   | ModuleKit-Injection, when embedded (priced) | ≈ 18 KB |
   | ModuleKit-Implements, when embedded (priced) | ≈ 10 KB |
   | ModuleKit-RequiredAddons, when embedded (priced) | ≈ 8.5 KB |
   | Per container (priced) | 4,203 → ≈ 3,100 B; with its LifecycleKit instance 7,535 → ≈ 4,100 B |

   The three parts emptied together measure 121.7 KB, before the priced
   items. The main chunk's locals (193 today, the `lua_limits` ratchet entry)
   fall by about 20 with the moved helpers; phase 2 updates the ratchet.
   Lifecycle passes are unchanged; phase 2 runs the module bench cases
   against AceAddon in one run.
7. Tests: Bootstrap and Manifest for the three parts; the Injection,
   Implements, Halted and DependencyPolicy specs run with their parts
   loaded, unchanged; without each part, every stub and every refused
   definition field raises at the caller's line (`ErrorLevels_spec` style)
   and `HasPart` answers `false`; hooks receive an empty injection table
   without the Injection part; a container whose own addon halts disables
   its modules with no ModuleKit part loaded; `SetLimits{
   maxRequiredAddons }` and the LifecycleKit ceiling without the
   RequiredAddons part; `Allocation_spec` gains the lazy container tables.
   In-place upgrade from revision 23, using a byte copy of today's
   `ModuleKit.lua` as the fixture: containers with providers, resolved
   singletons, `implements` contracts and `requiresAddons` made by revision
   23 keep working when the parts are loaded; when a part is absent, its
   members raise the stub message and the state it would serve is left in
   place, reported once through `geterrorhandler()`. Removed with their
   code: the cases that seed containers or modules of revisions before 23.
   ModuleKit opts into KitConformance (limits with `maxRequiredAddons`,
   receivers, arguments, upgrade).
8. Docs: README (parts; migration table rows for AceAddon unchanged,
   injection named as a part), `docs/API.md` (Parts, the Dependency
   injection, Implements and Halted addons sections split by part, Cost,
   the `docs/CONTRIBUTING.md` skeleton), `docs/INTERNALS.md` (dispatch
   entries, lazy container tables, no runtime-field fills), `CHANGELOG.md`
   0.11.0 (the upgrade floor named), `tests/README.md`, client suite (`.toc`
   and `EXPECTED.md`). Shared, for the maintainer: the example addon's
   `embeds.xml` (`moduleKit\parts\ModuleKit-Injection.lua` after
   `moduleKit\ModuleKit.lua`), `docs/GETTING_STARTED.md` and
   `docs/COOKBOOK.md` where they use providers, `docs/EMBEDDING.md`
   footprint rows, `tooling/validation/lua_limits.json` (ModuleKit's
   `mainLocals` after the change, lower).
9. Status: implemented 2026-11-18, 0.11.0, revision 24, 315 specs.
   Measured (host Lua 5.1.5, debug information kept, `exec.lua` of the
   diagnosis): the core 150,707 → 123,497 B resident (expected ≈ 117 KB),
   432,153 → 359,472 B allocated while loading; Injection 16,141 B,
   Implements 7,601 B, RequiredAddons 5,077 B resident when embedded. A
   container beside its LifecycleKit instance 4,136 → 3,880 B (the
   −0.8 KB of LifecycleKit's own phase lists is that record's), with it
   7,599 → 7,343 B; a module unchanged at 933 B. Main chunk 193 → 168
   active locals (the `lua_limits` entry removed). Choices and deviations:
   the core is about 6 KB above the priced figure (the part stubs, the
   dispatch defaults, and two shared blocks the record did not list,
   `validateFacade` for the conformance receivers group and `reportError`
   for the unserved-state report); `maxRequiredAddons` takes the shared
   block's required ceiling, 1024, the `UNBOUNDED` refusal against
   LifecycleKit's ceiling stays a check in `SetLimits` after the block;
   unserved state of an absent part is reported once when it would have been
   served (initialization, resolution, enable), not at load; the upgrade from
   revision 23 keeps containers' subscriptions instead of re-subscribing;
   the defensive re-test of shutdown inside a new container's phase replay
   was removed (a new container holds no module, so it was dead code).

**Not recorded (owner decisions, priced):**
- **The module graph as a part** (dependency edges, ordering constraints,
  cycle reports, `ValidateGraph`, `GetActivationOrder`, the policies'
  recursion): about −20 to −25 KB from the core (Graph section 12.7 KB of
  prototypes plus the policy recursion). The core would order by creation,
  as AceAddon does. AddonKit would have to stop declaring `dependsOn =
  { "Main" }` for every module and rely on creation order, which changes
  what a targeted `module:Enable()` does when `Main` is disabled. This is
  the only remaining lever of AceAddon's order of magnitude; it is a
  decision about AddonKit's module model, not a measurement.
- The `strict` dependency policy as a part: a few KB, but it is woven into
  the same recursive paths as `automatic`, so the split would cost about
  what it saves.
- Composed error prose (101 resident strings, 6.8 KB): about −1.5 to
  −2.5 KB, wording changes in every message family.
