# ModuleKit

ModuleKit provides addon-scoped module lifecycle management and deterministic dependency graphs on top of LifecycleKit. Dependency injection, `implements` contracts and required addons are optional parts an addon embeds only when it uses them (see [Parts](#parts)).

```lua
local addon = ModuleKit:ForAddon("MyAddon")
addon:SetDependencyPolicy("automatic") -- or "strict"

addon:ProvideSingleton("Database", function()
  return Database:New()
end)

local inventory = addon:CreateModule("Inventory")
inventory:Inject({ database = "Database" })

function inventory:OnInitialize(deps)
  self.database = deps.database
end
```

ModuleKit deliberately separates **activation dependencies** from **ordering constraints**:

- `DependsOn("Database")` is a required lifecycle dependency.
- `OptionalDependency("Analytics")`, `Before("UI")`, and `After("Profiles")` affect deterministic whole-container ordering when their targets exist, but do not implicitly activate those modules.

Dependency policy is explicit:

- `automatic` — targeted initialize/enable operations recursively activate the hard `DependsOn` closure; targeted disable first disables enabled hard dependents.
- `strict` — targeted operations never activate dependencies implicitly and reject unmet hard dependencies/dependents.

Whole-container `InitializeAll()` / `EnableAll()` operations always process the complete valid graph in deterministic topological order. `DisableAll()` uses reverse topological order and preserves hard-dependency state if a dependent fails to disable.

Each module carries a `scope` whose `Timers`, `Events`, `Jobs`, `Hooks`, `Messages`, `Commands` and `Comm` fields are released automatically when the module is disabled (and, where the Kit can reopen a scope, are the same objects again at the next enable), and records what it is meant to be (`wanted`) apart from what it is (`actual`), so a module blocked by a failed dependency comes back when that dependency is enabled. When the addon halts, or an addon a module lists in `requiresAddons` halts (RequiredAddons part), the affected modules are taken down and stay blocked for the session. See [`docs/API.md`](docs/API.md).

With the Implements part, a provider or a module definition can state what its value must carry, and ModuleKit checks it once, at the caller's line for a value or a module and when the factory's result first arrives for a lazy provider: `addon:ProvideSingleton("Database", factory, { implements = { "Save", "Load" } })`. When SchemaKit is loaded, `implements` may be a SchemaKit schema instead (see [Implements](docs/API.md#implements)).

`requiresAddons` is bounded per module (16 by default); `ModuleKit:SetLimits({ maxRequiredAddons = n })` or `ModuleKit.UNBOUNDED` opens it, within LifecycleKit's own per-addon limit (see [Limits](docs/API.md#limits)).

Definition-table creation is validated strictly: unknown fields and sparse list fields are rejected rather than silently ignored. Late module creation is also guarded so a new module cannot retroactively introduce an ordering predecessor for a module that has already initialized.

See [`docs/API.md`](docs/API.md) for provider scopes, lifecycle behavior, failure semantics, late-module rules, and the complete public contract.

[`docs/INTERNALS.md`](docs/INTERNALS.md) documents the implementation for maintainers: the section map of the runtime file, the ordering algorithm, the failure model, and the lifecycle replay hazard.

## Parts

| Part | File | Use it for |
|---|---|---|
| Injection | `moduleKit\parts\ModuleKit-Injection.lua` | `ProvideValue`, `ProvideSingleton`, `ProvideModule`, `ProvideTransient`, `Resolve`, `Inject` and the `inject` definition field |
| Implements | `moduleKit\parts\ModuleKit-Implements.lua` | `implements` contracts on module definitions and provider options |
| RequiredAddons | `moduleKit\parts\ModuleKit-RequiredAddons.lua` | the `requiresAddons` definition field (needs LifecycleKit's Halt part) |

Each part loads after `moduleKit\ModuleKit.lua`; `python3 -m tooling.package.embeds` writes the lines. Without a part its members raise at the caller's line naming the file to add, and `ModuleKit:HasPart(name)` answers whether it is loaded. See [`docs/API.md`](docs/API.md#loading).

## Moving from AceAddon-3.0

| AceAddon-3.0 | ModuleKit |
|---|---|
| `LibStub("AceAddon-3.0"):NewAddon("MyAddon")` | `ModuleKit:ForAddon("MyAddon")`, a container of modules; the addon's own `OnInitialize`/`OnEnable` code moves into a "Main" module |
| `MyAddon:NewModule("Bags")` | `addon:CreateModule("Bags"[, definition])` |
| `MyAddon:NewModule("Bags", prototype)`, `SetDefaultModulePrototype(prototype)` | `addon:CreateModule("Bags", { prototype = prototype })`, `addon:SetDefaultModulePrototype(prototype)`; ModuleKit's own methods win over the prototype's |
| `OnInitialize`, `OnEnable`, `OnDisable` | the same hook names, called with the module's resolved injections; `OnDisable` also runs at logout |
| mixins such as `"AceEvent-3.0"` in `NewModule` | `self.scope.Events`, `Timers`, `Jobs`, `Hooks`, `Commands`, `Comm` and `Messages`, released when the module is disabled |
| `MyAddon:GetModule("Bags")`, which raises unless `silent` | `addon:GetModule("Bags")`, `nil` when absent |
| `MyAddon:IterateModules()` | `addon:GetModules()`, an array in creation order |
| `MyAddon:EnableModule("Bags")`, `module:Disable()` | `addon:GetModule("Bags"):Enable()`, `module:Disable()`, under the dependency policy |
| `SetDefaultModuleState(false)` | `addon:SetDefaultModuleState(false)`, applying to modules created afterwards; per module, `{ enabledState = false }` |
| `module:SetEnabledState(false)` | `module:SetEnabledState(false)`: intent only, no hook runs |
| `AceAddon:GetAddon("MyAddon", true)` | `ModuleKit:FindAddon("MyAddon")`, `nil` when absent; `assert(...)` for the raising form |
| `AceAddon:IterateAddons()` | `ModuleKit:GetAddons()`, a sorted array of names |
| `function MyAddon:OnModuleCreated(module)` | `addon:OnModuleCreated(MyAddon)` after defining the method, or `addon:OnModuleCreated(function(module) end)` |
| creation order decides who starts first | `DependsOn`, `Before`, `After`: dependency order, checked for cycles |
| a shared object passed around by hand | `addon:ProvideSingleton(name, factory)` and `inject`, in the Injection part |

See [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#aceaddon-30) for a worked example.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\moduleKit\ModuleKit.lua
Libs\MoltenCodes\moduleKit\parts\ModuleKit-Injection.lua    (only when the addon uses injection)
Libs\MoltenCodes\moduleKit\parts\ModuleKit-Implements.lua   (only for implements contracts)
Libs\MoltenCodes\moduleKit\parts\ModuleKit-RequiredAddons.lua (only for requiresAddons)
```

Minimum footprint: embed 4 files: `registry/Registry.lua`, `eventKit/EventKit.lua`, `lifecycleKit/LifecycleKit.lua`, `moduleKit/ModuleKit.lua`.

Direct runtime dependencies: LifecycleKit API 1, Registry API 2.
Every core file above is required; omitting one makes this package raise at
load. The parts are optional. TimerKit, SchedulerKit, HookKit, CommandKit, CommKit and
SignalKit with its Bus part (`signalKit\SignalKit.lua`, then
`signalKit\parts\SignalKit-Bus.lua`) are optional: `module.scope` uses
each one the addon embeds, and `addon:OnModuleCreated` needs SignalKit's Bus part. A field whose Kit is not embedded reads as `nil`;
`addon:SetMissingScopePolicy("raise")` turns that into an error at the reading
line that names the file to add to `embeds.xml`. SchemaKit is optional too: the schema form of
`implements` (Implements part) uses it when the addon embeds it.
