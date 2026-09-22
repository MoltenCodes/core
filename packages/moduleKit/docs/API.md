# ModuleKit API

ModuleKit API generation **1** provides addon-scoped module lifecycle management, dependency graphs, and dependency injection.

## Container

```lua
local addon = ModuleKit:ForAddon("MyAddon")
```

`ForAddon` is idempotent. Every caller receives the same container for the same addon name in the shared runtime.

### Public surface summary

The addon container exposes:

| Method | Purpose |
|---|---|
| `GetAddonName()` | Return the owning addon name. |
| `GetDependencyPolicy()` | Return `automatic` or `strict`. |
| `SetDependencyPolicy(policy)` | Change targeted dependency behavior and return the previous policy. |
| `CreateModule(name[, definition])` | Create a uniquely named module. |
| `GetModule(name)` | Return a module or `nil`. |
| `HasModule(name)` | Test module existence. |
| `GetModules()` | Return a new array snapshot in module creation order. |
| `GetActivationOrder()` | Return module names in deterministic full-graph topological order. |
| `ValidateGraph()` | Validate the complete graph and return `true` on success. |
| `InitializeAll()` | Initialize the complete graph. |
| `EnableAll()` | Initialize as needed and enable the complete graph. |
| `DisableAll()` | Disable enabled modules in reverse graph order without terminating the addon container. |
| `ProvideValue(name, value)` | Register an addon-scoped constant. |
| `ProvideSingleton(name, factory)` | Register a lazily cached addon-scoped factory. |
| `ProvideModule(name, factory)` | Register a lazily cached per-requesting-module factory. |
| `ProvideTransient(name, factory)` | Register a non-cached factory. |
| `Resolve(name[, requestingModule])` | Resolve an injectable value, optionally with module scope context. |

Each module exposes:

| Method | Purpose |
|---|---|
| `GetName()` | Return the module name. |
| `GetAddon()` | Return the owning addon container. |
| `GetState()` | Return `created`, `initialized`, `enabled`, or `disabled`. |
| `IsInitialized()` | Return whether initialization has completed at least once. |
| `IsEnabled()` | Return whether the module is currently enabled. |
| `GetLastError()` | Return the original last error object, which may itself be `nil`. |
| `HasLastError()` | Distinguish an actual error from `GetLastError() == nil`. |
| `GetBlockedBy()` | Return the related dependency/dependent name when an operation was blocked. |
| `GetInjections()` | Return a shallow-copy snapshot of resolved injections, or an empty table before resolution. |
| `DependsOn(name)` | Add a required activation dependency. |
| `OptionalDependency(name)` | Add an ordering edge only when the target exists. |
| `Before(name)` / `After(name)` | Add ordering-only constraints. |
| `Inject(alias, target)` / `Inject(map)` | Declare injection aliases. |
| `Initialize()` | Targeted initialization under the selected dependency policy. |
| `Enable()` | Targeted enable under the selected dependency policy. |
| `Disable()` | Targeted disable under the selected dependency policy. |
| `Activate()` | Catch this module up to already-reached LifecycleKit phases. |
| `Resolve(name)` | Resolve an injectable with this module as scope context. |

Inspection methods return values/snapshots; mutating a table returned by `GetModules()` or `GetInjections()` does not mutate ModuleKit's owned collection table.

### Dependency policy

```lua
addon:SetDependencyPolicy("automatic")
addon:SetDependencyPolicy("strict")
local policy = addon:GetDependencyPolicy()
```

The default is `automatic`.

`automatic` affects targeted hard-dependency operations:

- `module:Initialize()` recursively initializes its required `DependsOn` closure.
- `module:Enable()` recursively enables its required `DependsOn` closure.
- `module:Disable()` recursively disables enabled hard dependents first.

`strict` performs no implicit hard-dependency activation:

- targeted initialize requires every hard dependency to already be initialized;
- targeted enable requires every hard dependency to already be enabled;
- targeted disable is rejected while an enabled hard dependent exists.

`addon:InitializeAll()` and `addon:EnableAll()` are explicit whole-container operations. They process the complete graph in deterministic topological order under either policy. Policy therefore controls **targeted implicit activation**, not whether an explicit whole-container operation can process dependencies.

## Creating modules

```lua
local module = addon:CreateModule("Inventory")
```

Module names are unique inside one addon container and cannot collide with provider names.

Modules created before lifecycle phases may be configured in mutable form:

```lua
local module = addon:CreateModule("Inventory")
module:DependsOn("Database")

function module:OnInitialize(deps)
end
```

For a module created after the addon is already loaded/ready, either configure the mutable module and call `module:Activate()` explicitly, or provide an atomic definition table:

```lua
local module = addon:CreateModule("Inventory", {
    dependsOn = { "Database" },
    optionalDependencies = { "Analytics" },
    after = { "Profiles" },
    inject = {
        database = "DatabaseService",
    },
    onInitialize = function(self, deps) end,
    onEnable = function(self, deps) end,
    onDisable = function(self, deps) end,
})
```

Definition tables accept only these fields:

- `dependsOn`
- `optionalDependencies`
- `before`
- `after`
- `inject`
- `onInitialize`
- `onEnable`
- `onDisable`

The four ordering/dependency list fields must be dense arrays. Unknown fields, mixed-key tables, and sparse arrays are rejected so misspellings do not silently change behavior. Validation is applied in a fixed order for deterministic diagnostics.

A definition-table module catches up synchronously to already-reached LifecycleKit phases.

### Late module ordering

Once a module has initialized, its already-observed ordering cannot be rewritten retroactively. Creating a new module is rejected if its appearance would make it a predecessor of an already-initialized module. The same rule applies when a mutable late module attempts `Before("AlreadyInitialized")`.

Safe late relationships that place the new module **after** existing initialized modules remain valid.

## Module lifecycle

Stable states are:

```text
created → initialized → enabled ↔ disabled
```

Initialization succeeds at most once. Enable and disable are idempotent when the requested state is already satisfied.

```lua
module:Initialize()
module:Enable()
module:Disable()
module:Activate()

module:GetState()
module:IsInitialized()
module:IsEnabled()
```

Hooks are ordinary fields on the module object:

```lua
function module:OnInitialize(deps) end
function module:OnEnable(deps) end
function module:OnDisable(deps) end
```

Each hook receives the stable resolved injection table as its second argument. A failed hook leaves the module at its previous stable state and can be retried.

`module:Activate()` catches one module up to LifecycleKit's already-reached phases. It follows the selected dependency policy for hard dependencies.

## Dependency graph

```lua
module:DependsOn("Database")
module:OptionalDependency("Analytics")
module:Before("UI")
module:After("Profiles")
```

Semantics:

- `DependsOn` — required module and lifecycle-ordering edge.
- `OptionalDependency` — ordering edge only when the target exists; absence is valid.
- `Before` / `After` — ordering-only edges; they never create implicit activation dependencies.

Graph mutation is allowed only while the module remains in `created` state.

```lua
addon:ValidateGraph()
local names = addon:GetActivationOrder()
```

Whole-container operations validate the complete graph. Missing hard dependencies and graph cycles fail with human-readable diagnostics.

Targeted `Initialize()` / `Enable()` operations intentionally inspect only the module's hard `DependsOn` closure. An unrelated invalid optional feature therefore does not prevent an otherwise independent targeted operation. Ordering-only constraints are honored by whole-container graph ordering and introspection; use `DependsOn` whenever runtime activation of another module is required.

Activation order is deterministic and uses module creation order as the tie-breaker. Normal bulk disable order is the reverse topological order.

## Dependency injection

Providers are addon-local. Different addon containers never share provider registration or caches.

### Value

```lua
addon:ProvideValue("Config", config)
```

`nil` values are rejected so missing providers remain unambiguous.

### Singleton

```lua
addon:ProvideSingleton("Database", function(addon)
    return Database:New()
end)
```

The factory runs once for the addon container. Factory providers must return a non-`nil` value.

### Module-scoped

```lua
addon:ProvideModule("Logger", function(addon, module)
    return Logger:New(module:GetName())
end)
```

The factory runs once per requesting module. The same module-scoped provider may resolve for a different requesting module while a factory is running; cycle detection tracks `(provider, requesting module)` identity rather than rejecting that legitimate case by provider name alone.

### Transient

```lua
addon:ProvideTransient("Request", function(addon, module)
    return Request:New()
end)
```

The factory runs on every resolution.

### Injection

```lua
module:Inject({
    database = "Database",
    logger = "Logger",
})
```

Injection aliases are resolved in sorted alias order for deterministic factory side effects. Provider/module names cannot collide, so resolution remains unambiguous. A module itself can be injected by its module name.

Injection does **not** implicitly create a lifecycle dependency. If an injected module must initialize or enable before the consumer, declare the corresponding `DependsOn` explicitly.

Direct resolution is available through:

```lua
local value = addon:Resolve("Database")
local logger = module:Resolve("Logger")
local sameLogger = addon:Resolve("Logger", module)
```

The optional second argument to `addon:Resolve(name, requestingModule)` supplies module context for module-scoped providers and must be a real module owned by that addon container. `module:Resolve(...)` is the normal convenience form. Recursive provider resolution is cycle-checked and reports the provider path.

## Failure diagnostics

A module does not enter a permanent failed state. Instead:

```lua
local failed = module:HasLastError()
local errorObject = module:GetLastError()
local relatedModule = module:GetBlockedBy()
```

A callback/provider failure sets `HasLastError()` and stores the original Lua error object, including `nil`, `false`, tables, and strings.

Bulk initialization/enable operations continue independent modules, block hard dependents of failed dependencies, and re-raise the first actual callback/provider error after the pass.

For non-terminal `addon:DisableAll()`, if a dependent's `OnDisable` fails and remains enabled, its hard dependency is kept enabled as well. This preserves the runtime invariant that an enabled module never loses a hard dependency solely because bulk cleanup continued after an error.

Lifecycle shutdown is different: it is terminal best-effort cleanup. ModuleKit attempts every enabled module even after earlier failures. If an inactive late definition makes the full graph invalid, enabled modules are still cleaned up using their hard-dependency subgraph, and the original graph error is re-raised after cleanup.

## LifecycleKit integration

For each addon container:

- LifecycleKit `loaded` → `InitializeAll()`
- LifecycleKit `ready` → `EnableAll()`
- LifecycleKit `shutdown` → terminal reverse-order cleanup

After shutdown, the container is terminal: new modules, graph/injection definition changes, provider registration, dependency-policy changes, and enable/initialize operations are rejected. Read-only inspection, resolution of already-registered providers, and idempotent disable operations remain available.

Lifecycle subscriptions dispatch through revision-independent shared runtime state. Compatible embedded ModuleKit upgrades therefore preserve existing addon/container identity while moving already-created containers onto the newest accepted implementation. Revision-1 subscriptions are migrated once during the revision-2 upgrade, and same-revision bootstrap can repair incomplete shared dispatch after an interrupted bootstrap.

## Dependencies

ModuleKit API 1 requires:

- Registry API 2
- LifecycleKit API 1

ModuleKit does not depend directly on EventKit or SignalKit; those are implementation dependencies of LifecycleKit and remain outside ModuleKit's direct contract.
