# ModuleKit Tests

The ModuleKit suite covers the core and its three parts. `ModuleKitTestEnv.NewPackage()` loads the chain and every part (and LifecycleKit's Halt part when LifecycleKit ships it as a file), `NewCore()` the chain without ModuleKit's parts, and `LoadParts([names])` loads parts on top of a loaded core. `LoadRevision23()` runs the verbatim revision 23 file kept in `fixtures/ModuleKit-revision23.lua`, the oldest revision an upgrade takes over.

It covers:

- addon/container identity, shared bootstrap state, and embedded revision behavior;
- `automatic` and `strict` dependency policies;
- hard, optional, and ordering-only graph semantics;
- deterministic topological ordering and cycle diagnostics;
- late-module ordering safety and targeted-operation isolation;
- dependency-injection scopes, deterministic aliases, provider cycles, and requester validation;
- hook failures, blocked dependents, retries, and non-terminal dependency-invariant preservation;
- terminal best-effort shutdown cleanup;
- late-created modules and definition-table catch-up;
- strict definition-schema validation;
- manifest/runtime metadata consistency;
- in-place upgrade safety: a deliberately disabled module stays disabled, and no module hook runs during an upgrade;
- the parts (`Parts_spec.lua`): `HasPart`, every stub and every refused definition field and option at the caller's line, hooks' empty injection table, the own-addon halt and the limits without any part, loading a part without its core or without LifecycleKit's Halt part, a part kept across a newer core and a repeated load, prototype modules served by a part loaded before or after them;
- the conformance suite (`Conformance_spec.lua`, `tests/support/KitConformance.lua`): manifest and part revisions, `maxRequiredAddons` within LifecycleKit's default ceiling, facade receivers, secret arguments, and the upgrade from the previous revision;
- re-entrant module creation from a hook, which is deferred to the end of the running whole-container pass;
- the Lua 5.1 rule that a hook cannot yield across the `pcall` boundary;
- deterministic activation order on a larger layered graph fixture;
- module scopes (`Scope_spec.lua`): lazy creation, release on disable, `DisableAll`, shutdown and a failed `OnEnable`, absent Kits, and the enable window (TimerKit and SchedulerKit are recording fakes registered through Registry; EventKit is covered both by a fake and by the real `EventKit:CreateScope()`; HookKit, the SignalKit bus, CommandKit and CommKit are covered against the real Kits, and `Messages` over a SignalKit without its Bus part reads `nil` or, under `"raise"`, names the part);
- intent versus fact (`EnableState_spec.lua`): recovery after a dependency enables, explicit disable winning over recovery, and the `ready` phase respecting an explicit disable;
- dependency cycles reported at the caller's line from every entry method (`Cycle_spec.lua`);
- argument and state refusals reported at the caller's line and naming the public method (`ErrorLevels_spec.lua`): container and module arguments, provider registration and resolution, definition-table fields and entries at the `CreateModule` line, a definition's catch-up failure, `DisableAll`'s graph error, the method named after shutdown, a deterministic unknown-option report and the `SetLimits` refusals, including an unknown limit name, and a table definition field, option field and limit key named by their type without running their `__tostring`;
- halted addons (`Halted_spec.lua`): the addon's own halt, a required addon's halt, a halt raised from inside `OnEnable`, `requiresAddons` validation and LifecycleKit's dependency bound, and the halted state across an in-place upgrade (the RequiredAddons part loaded);
- package-wide limits (`Limits_spec.lua`): the `maxRequiredAddons` default, a lower and a higher limit, `ModuleKit.UNBOUNDED`, the coupling to LifecycleKit's reported `maxDependencies`, invalid values refused at the caller without changing anything, and the facade receiver check; the upgrade cases live in `Bootstrap_spec.lua`;
- `implements` contracts (`Implements_spec.lua`): the list form on a value, a singleton, a module-scoped and a transient provider and on a module definition, a missing member, a member that is not a function, a value that is not a table, every malformed list and options table refused at the caller's line, the once-per-value rule (a singleton's members are looked up once, a transient's on every resolution), a refused injected value recorded as the module's failure, the schema form against the real SchemaKit (sealed schema and unsealed node, path and root failures, an inherited method that a schema does not see, a module definition against an open table schema, an impostor table) and the refusal of the schema form when SchemaKit is not loaded (the chain is loaded without SchemaKit through `NewPackageWithoutOptionalKits`; the schema stand-in is an empty table whose protected metatable name is SchemaKit's); the upgrade cases live in `Bootstrap_spec.lua`;
- kept module scopes, the blocked-module flag, the halt read and the missing-scope policy (`KeptScopes_spec.lua`), and `scope.Commands` kept across enables now that CommandKit has `Reopen`;
- the revision-23 conveniences (`Conveniences_spec.lua`): `SetEnabledState` before ready (the module kept out of the `ready` pass, its dependents blocked), after ready (intent only), clearing a block, after shutdown and with bad arguments; the default state applied to later modules and overridden by `enabledState`; a late definition module that is not wanted initialized but not enabled while `Activate` still enables a mutable one; prototypes (lookup order, hooks in every phase and in `implements`, a per-module prototype, `prototype = false`, a later default not changing earlier modules, a shared metatable per prototype, a prototype with its own metatable, every refusal leaving no module, a newer revision's methods reaching a prototyped module); `FindAddon` never creating and `GetAddons` sorted and fresh; the module-created notice (published after the module is in the container and before its catch-up, `Disconnect`, the receiver forms, a raising listener reported, no bus touched before a subscription, `"full"`, argument refusals, no SignalKit, SignalKit without its Bus part); and secret arguments refused on the `mainline` host;
- secret values on the `mainline` host (`SecretValues_spec.lua`): secret names, `requiresAddons` entries, `implements` entries, the dependency policy (kept unchanged), limit values and limit names, keys of definition, options, `implements` and alias-map tables, and a secret or secret-named `requestingModule` refused at the caller's line before any comparison or key use; a scope key that names no field read as `nil` (the client itself refuses a secret key before `__index` runs), a secret missing-scope policy refused, an `implements` list with a secret `__metatable` read as a list, a secret provided value accepted and resolved unchanged, and ordinary arguments still accepted.

Spec files:

| File | Covers |
|---|---|
| `ModuleKit_spec.lua` | per-addon containers, policies, module creation and lookup, idempotent transitions |
| `Graph_spec.lua` | hard, optional and ordering-only edges, topological order, cycle detection |
| `GraphCache_spec.lua` | the cached graph order, dependency lists and dependents seeing every graph change, an invalid graph reported on every call, a pass keeping its order when a hook creates a module, and a module that declares nothing storing no constraint tables |
| `Allocation_spec.lua` | `#allocation`: whole-container cycles (with and without a dependency chain), a targeted disable and enable, and `ValidateGraph` on a cached graph allocate nothing; and, untagged, the lazy container tables (providers, resolution stack, catch-up queue created on first use) |
| `Parts_spec.lua` | the three parts: `HasPart`, stubs and refused fields without them, the core working without them, part loading and upgrades |
| `Conformance_spec.lua` | the Kit conformance suite |
| `Cycle_spec.lua` | a two-module cycle reported at the calling line from `InitializeAll`, `EnableAll`, `Initialize`, `Enable` and `Activate`, and an enable from an unexpected state |
| `DependencyPolicy_spec.lua` | `automatic` and `strict` enable and disable |
| `Injection_spec.lua` | values, singletons, module-scoped and transient providers, collisions and cycles |
| `Lifecycle_spec.lua` | `loaded`/`ready`/`shutdown` integration, late modules, calls after shutdown |
| `Errors_spec.lua` | hook failures, retries, blocked dependents, `nil` error objects, `DisableAll` invariants |
| `EnableState_spec.lua` | intent versus fact: `wanted`, `actual`, `blockedBy` and recovery |
| `Scope_spec.lua` | module scopes over fakes and the real EventKit, HookKit, SignalKit bus, CommandKit and CommKit |
| `Halted_spec.lua` | the addon's own halt, a required addon's halt, halts raised inside `OnEnable`, `requiresAddons`, the on-demand `OnDependencyHalted` subscription, upgrades |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `maxRequiredAddons`, `ModuleKit.UNBOUNDED` and the LifecycleKit coupling |
| `Implements_spec.lua` | the `implements` option on every provider kind and on module definitions, in its list and schema forms, with and without SchemaKit |
| `ErrorLevels_spec.lua` | argument and state refusals at the caller's line, from every public entry and from definition tables |
| `Bootstrap_spec.lua` | duplicate loading, Registry publication, dispatch repair, the refusal of state older than revision 23, in-place upgrades, the manifest revision, limits and the sentinel carried to a newer revision, a contract kept under a newer revision, and the upgrade from the verbatim revision 23 file: containers, providers, a resolved singleton, a contract, injections, required addons, the dependency policy and the limits kept with the parts loaded, and with a part absent its stubs raising and its state left in place and reported once |
| `KeptScopes_spec.lua` | scopes kept and reopened across enables (one object per field), a Kit without `Reopen`, a `Reopen` that refuses or raises, a scope whose `Close` raised not kept, the real EventKit scope across enables; the blocked-module flag set by a block, cleared by an empty scan and absent on an older container; the halt read from `_halted`, and an instance without the field; the missing-scope policy (default `nil`, `"raise"` at the reading line naming each field's Kit and file, a Kit revision without owner scopes, a bus that cannot be had still `nil`, return to the default, argument errors) |
| `SecretValues_spec.lua` | secret arguments, policies and table keys refused at the caller's line, secret provided values accepted |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |
