# ModuleKit Tests

The ModuleKit suite covers:

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
- in-place upgrade safety: a deliberately disabled module stays disabled, and no module hook runs during migration;
- re-entrant module creation from a hook, which is deferred to the end of the running whole-container pass;
- the Lua 5.1 rule that a hook cannot yield across the `pcall` boundary;
- deterministic activation order on a larger layered graph fixture;
- module scopes (`Scope_spec.lua`): lazy creation, release on disable, `DisableAll`, shutdown and a failed `OnEnable`, absent Kits, and the enable window (TimerKit and SchedulerKit are recording fakes registered through Registry; EventKit is covered both by a fake and by the real `EventKit:CreateScope()`; HookKit, the SignalKit bus, CommandKit and CommKit are covered against the real Kits);
- intent versus fact (`EnableState_spec.lua`): recovery after a dependency enables, explicit disable winning over recovery, the `ready` phase respecting an explicit disable, and both fields surviving an in-place upgrade;
- dependency cycles reported at the caller's line from every entry method (`Cycle_spec.lua`);
- halted addons (`Halted_spec.lua`): the addon's own halt, a required addon's halt, a halt raised from inside `OnEnable`, `requiresAddons` validation and LifecycleKit's dependency bound, and the halted state across an in-place upgrade;
- package-wide limits (`Limits_spec.lua`): the `maxRequiredAddons` default, a lower and a higher limit, `ModuleKit.UNBOUNDED`, the coupling to LifecycleKit's reported `maxDependencies`, invalid values refused at the caller without changing anything, and the facade receiver check; the upgrade cases live in `Bootstrap_spec.lua`;
- `implements` contracts (`Implements_spec.lua`): the list form on a value, a singleton, a module-scoped and a transient provider and on a module definition, a missing member, a member that is not a function, a value that is not a table, every malformed list and options table refused at the caller's line, the once-per-value rule (a singleton's members are looked up once, a transient's on every resolution), a refused injected value recorded as the module's failure, the schema form against the real SchemaKit (sealed schema and unsealed node, path and root failures, an inherited method that a schema does not see, a module definition against an open table schema, an impostor table) and the refusal of the schema form when SchemaKit is not loaded (the chain is loaded without SchemaKit through `NewPackageWithoutHookKit`; the schema stand-in is an empty table whose protected metatable name is SchemaKit's); the upgrade cases live in `Bootstrap_spec.lua`.

Spec files:

| File | Covers |
|---|---|
| `ModuleKit_spec.lua` | per-addon containers, policies, module creation and lookup, idempotent transitions |
| `Graph_spec.lua` | hard, optional and ordering-only edges, topological order, cycle detection |
| `Cycle_spec.lua` | a two-module cycle reported at the calling line from `InitializeAll`, `EnableAll`, `Initialize`, `Enable` and `Activate`, and an enable from an unexpected state |
| `DependencyPolicy_spec.lua` | `automatic` and `strict` enable and disable |
| `Injection_spec.lua` | values, singletons, module-scoped and transient providers, collisions and cycles |
| `Lifecycle_spec.lua` | `loaded`/`ready`/`shutdown` integration, late modules, calls after shutdown |
| `Errors_spec.lua` | hook failures, retries, blocked dependents, `nil` error objects, `DisableAll` invariants |
| `EnableState_spec.lua` | intent versus fact: `wanted`, `actual`, `blockedBy` and recovery |
| `Scope_spec.lua` | module scopes over fakes and the real EventKit, HookKit, SignalKit bus, CommandKit and CommKit |
| `Halted_spec.lua` | the addon's own halt, a required addon's halt, halts raised inside `OnEnable`, `requiresAddons`, upgrades |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `maxRequiredAddons`, `ModuleKit.UNBOUNDED` and the LifecycleKit coupling |
| `Implements_spec.lua` | the `implements` option on every provider kind and on module definitions, in its list and schema forms, with and without SchemaKit |
| `Bootstrap_spec.lua` | duplicate loading, Registry publication, dispatch repair, in-place upgrades, revision 15, limits and the sentinel carried across upgrades from revision 13 and to a newer revision, a revision-14 provider resolving unchecked and a contract kept under a newer revision |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |
