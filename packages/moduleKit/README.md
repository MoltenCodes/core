# ModuleKit

ModuleKit provides addon-scoped module lifecycle management, deterministic dependency graphs, and dependency injection on top of LifecycleKit.

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

Each module carries a `scope` whose `Timers`, `Events`, `Jobs`, `Hooks`, `Messages`, `Commands` and `Comm` fields are released automatically when the module is disabled, and records what it is meant to be (`wanted`) apart from what it is (`actual`), so a module blocked by a failed dependency comes back when that dependency is enabled. When the addon halts, or an addon a module lists in `requiresAddons` halts, the affected modules are taken down and stay blocked for the session. See [`docs/API.md`](docs/API.md).

A provider or a module definition can state what its value must carry, and ModuleKit checks it once, at the caller's line for a value or a module and when the factory's result first arrives for a lazy provider: `addon:ProvideSingleton("Database", factory, { implements = { "Save", "Load" } })`. When SchemaKit is loaded, `implements` may be a SchemaKit schema instead (see [Implements](docs/API.md#implements)).

`requiresAddons` is bounded per module (16 by default); `ModuleKit:SetLimits({ maxRequiredAddons = n })` or `ModuleKit.UNBOUNDED` opens it, within LifecycleKit's own per-addon limit (see [Limits](docs/API.md#limits)).

Definition-table creation is validated strictly: unknown fields and sparse list fields are rejected rather than silently ignored. Late module creation is also guarded so a new module cannot retroactively introduce an ordering predecessor for a module that has already initialized.

See [`docs/API.md`](docs/API.md) for provider scopes, lifecycle behavior, failure semantics, late-module rules, and the complete public contract.

[`docs/INTERNALS.md`](docs/INTERNALS.md) documents the implementation for maintainers: the section map of the runtime file, the ordering algorithm, the failure model, and the lifecycle replay hazard.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\moduleKit\ModuleKit.lua
```

Minimum footprint: embed 5 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `eventKit/EventKit.lua`, `lifecycleKit/LifecycleKit.lua`, `moduleKit/ModuleKit.lua`.

Direct runtime dependencies: LifecycleKit API 1, Registry API 2.
Every file above is required; omitting one makes this package raise at
load. TimerKit, SchedulerKit, HookKit, CommandKit and CommKit are optional: `module.scope` uses
each one the addon embeds. SchemaKit is optional too: the schema form of
`implements` uses it when the addon embeds it.
