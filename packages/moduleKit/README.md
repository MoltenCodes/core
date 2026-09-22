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

Definition-table creation is validated strictly: unknown fields and sparse list fields are rejected rather than silently ignored. Late module creation is also guarded so a new module cannot retroactively introduce an ordering predecessor for a module that has already initialized.

See [`docs/API.md`](docs/API.md) for provider scopes, lifecycle behavior, failure semantics, late-module rules, and the complete public contract.

[`docs/INTERNALS.md`](docs/INTERNALS.md) documents the implementation for maintainers: the section map of the runtime file, the ordering algorithm, the failure model, and the lifecycle replay hazard.
