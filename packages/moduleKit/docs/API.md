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
| `EnableAll()` | Initialize as needed and enable the complete graph, including modules that were explicitly disabled. |
| `DisableAll()` | Disable enabled modules in reverse graph order without terminating the addon container. |
| `ProvideValue(name, value[, options])` | Register an addon-scoped constant. |
| `ProvideSingleton(name, factory[, options])` | Register a lazily cached addon-scoped factory. |
| `ProvideModule(name, factory[, options])` | Register a lazily cached per-requesting-module factory. |
| `ProvideTransient(name, factory[, options])` | Register a non-cached factory. |
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
| `GetEnableState()` | Return a fresh `{ wanted, actual, blockedBy }` snapshot of intent versus fact. |
| `GetInjections()` | Return a shallow-copy snapshot of resolved injections, or an empty table before resolution. |
| `DependsOn(name)` | Add a required activation dependency. |
| `OptionalDependency(name)` | Add an ordering edge only when the target exists. |
| `Before(name)` / `After(name)` | Add ordering-only constraints. |
| `Inject(alias, target)` / `Inject(map)` | Declare injection aliases. Targets are provider/module **names**. |
| `Initialize()` | Targeted initialization under the selected dependency policy. |
| `Enable()` | Targeted enable under the selected dependency policy. |
| `Disable()` | Targeted disable under the selected dependency policy. |
| `Activate()` | Catch this module up to already-reached LifecycleKit phases. |
| `Resolve(name)` | Resolve an injectable with this module as scope context. |

The package facade also exposes `ModuleKit.UNBOUNDED`, `ModuleKit:SetLimits(limits)`
and `ModuleKit:GetLimits()`; see [Limits](#limits).

Each module also carries one field:

| Field | Purpose |
|---|---|
| `scope` | Per-module owner of addon-message registrations and sends, slash commands, timers, events, scheduler jobs, hooks and bus subscriptions, released automatically on disable. See [Module scopes](#module-scopes). |

Inspection methods return values/snapshots; mutating a table returned by `GetModules()` or `GetInjections()` does not mutate ModuleKit's owned collection table.

### Dependency policy

```lua
addon:SetDependencyPolicy("automatic")
addon:SetDependencyPolicy("strict")
local policy = addon:GetDependencyPolicy()
```

The default is `automatic`. Any other value is refused at the caller's line
and the policy is kept; a secret value is refused before it is compared (see
[Argument and state errors](#argument-and-state-errors)).

`automatic` affects targeted hard-dependency operations:

- `module:Initialize()` recursively initializes its required `DependsOn` closure.
- `module:Enable()` recursively enables its required `DependsOn` closure.
- `module:Disable()` recursively disables enabled hard dependents first.

`strict` performs no implicit hard-dependency activation:

- targeted initialize requires every hard dependency to already be initialized;
- targeted enable requires every hard dependency to already be enabled;
- targeted disable is rejected while an enabled hard dependent exists.

`addon:InitializeAll()` and `addon:EnableAll()` are explicit whole-container operations. They process the complete graph in deterministic topological order under either policy. Policy therefore controls **targeted implicit activation**, not whether an explicit whole-container operation can process dependencies.

### `EnableAll()` re-enables explicitly disabled modules

`EnableAll()` states a target for the whole container — every module enabled — rather than a delta from the current state. A module that was explicitly disabled earlier is therefore enabled again, and its `OnEnable` runs again.

This is deliberate. If `EnableAll()` skipped previously disabled modules, the container's final state would depend on history that nothing observable records, and there would be no way to express "enable everything" at all. Keeping the operation a target state makes it idempotent and predictable: calling it twice leaves the same container state either way.

Consumers that want a module to stay off should keep that decision in their own configuration and disable the module after the container operation, or use targeted `module:Enable()` / `module:Disable()` instead of the whole-container form.

Note that LifecycleKit's `ready` phase runs the same whole-container enable once, but it is not a call by the addon and states no intent: a module the addon explicitly disabled before `ready` — for example with `self:Disable()` in `OnInitialize` — stays disabled, and its hard dependents are recorded as blocked by it. Only an `EnableAll()` the addon calls itself re-enables such a module. An in-place ModuleKit upgrade never dispatches an already-delivered phase a second time, so an upgrade cannot re-enable a module either.

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
    requiresAddons = { "OtherAddon" },
    implements = { "OnEnable", "OnDisable" },
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
- `requiresAddons`
- `implements`
- `inject`
- `onInitialize`
- `onEnable`
- `onDisable`

`implements` states what the module must carry when `CreateModule` returns:
a list of method names, or a SchemaKit schema; see
[Implements](#implements). A definition table is atomic, so the members
available at that moment are ModuleKit's own module methods and the hooks the
definition sets: `implements = { "OnEnable", "OnDisable" }` refuses, at the
`CreateModule` line, a definition that forgot a hook, and the module is not
created. Members assigned to a module afterwards, in the mutable style, are not
checked. It is available only in the definition table.

`requiresAddons` names other addons, by folder name exactly as LifecycleKit matches it, that the module cannot work without; see [Halted addons](#halted-addons). It is available only in the definition table.

The four ordering/dependency list fields and `requiresAddons` must be dense arrays. Unknown fields, mixed-key tables, and sparse arrays are rejected so misspellings do not silently change behavior. Validation is applied in a fixed order for deterministic diagnostics.

A definition-table module catches up synchronously to already-reached LifecycleKit phases.

There is one exception. When the module is created from a hook while a whole-container operation (`InitializeAll`, `EnableAll`, `DisableAll`, or the LifecycleKit phase that triggers one) is still running, its catch-up is deferred to the end of that operation. `CreateModule` then returns a module still in `created` state.

Activating it in the middle of the running pass would bypass that pass's failure blocking: the new module could be activated even though the pass had already decided one of its hard dependencies failed. Deferring gives the same result as creating the module immediately after the pass returned.

`module:Activate()` is not deferred. It is an explicit request from addon code rather than implicit catch-up, so it runs synchronously wherever it is called.

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

### Hooks must not yield

ModuleKit invokes every hook through `pcall`, which is what turns a hook failure into a recorded module failure instead of an aborted lifecycle pass.

In Lua 5.1 — the version the WoW client runs — a coroutine cannot suspend across a C function, and `pcall` is one. A hook that calls `coroutine.yield`, directly or through something that yields on its behalf, therefore fails with `attempt to yield across metamethod/C-call boundary`. ModuleKit records that like any other hook failure: the module stays at its previous stable state and `HasLastError()` is set.

Do asynchronous work by starting it from the hook and returning, for example by scheduling it through SchedulerKit, rather than by suspending the hook itself.

`module:Activate()` catches one module up to LifecycleKit's already-reached phases. It follows the selected dependency policy for hard dependencies.

## Module scopes

Everything a module registers through `module.scope` while it is enabled is
released when it is disabled, so a module does not need an `OnDisable` just to
clean up:

```lua
function module:OnEnable()
    self.scope.Events:Connect("BAG_UPDATE", function() self:Refresh() end)
    self.scope.Timers:Every(5, function() self:Poll() end)
    self.scope.Jobs:Schedule(function() self:Rebuild() end)
    self.scope.Hooks:SecureHook(GameTooltip, "SetUnit", function() self:Decorate() end)
    self.scope.Messages:Subscribe("ProfileChanged", function(name) self:Reload(name) end)
    self.scope.Commands:Register("myaddon", { handler = function(context) self:Report(context) end })
    self.scope.Comm:Register("MyAddonSync", function(prefix, text, distribution, sender) self:Merge(text) end)
end
-- No OnDisable: Disable() closes all seven scopes.
```

| Field | What it is | Released by |
|---|---|---|
| `scope.Timers` | a TimerKit scope (`TimerKit:CreateScope()`) | `Close()` |
| `scope.Events` | an EventKit scope (`EventKit:CreateScope()`) | `Close()` |
| `scope.Jobs` | a SchedulerKit scope (`SchedulerKit:CreateScope()`) | `Close()` |
| `scope.Hooks` | a HookKit scope (`HookKit:CreateScope()`) | `Close()`, which undoes every hook |
| `scope.Messages` | a scope over the addon's SignalKit bus (`SignalKit:ForAddon(addonName):CreateScope()`) | `Close()`, which disconnects every subscription |
| `scope.Comm` | a CommKit scope (`CommKit:CreateScope()`) | `Close()`, which cancels its pending sends, closes its SyncSets and disconnects its prefix registrations |
| `scope.Commands` | a CommandKit scope (`CommandKit:CreateScope()`) | `Close()`, which leaves every slash command it registered inert (the client keeps the name; typing it does nothing) |

The rules:

- **Lazy.** Each field is created on its first read and cached; a module that
  never reads its scope creates nothing and pays nothing beyond the one scope
  table every module carries.
- **Optional Kits.** ModuleKit has no required dependency on TimerKit, EventKit,
  SchedulerKit, HookKit, CommandKit or CommKit, and uses SignalKit only through LifecycleKit. Each
  is resolved through `Registry:Find` at first read, and a field reads as `nil`
  when its Kit is not loaded or is a revision without `CreateScope` (for
  `Messages`: without `Bus` and `ForAddon`). Test for `nil` when your addon
  does not embed the Kit.
- **`Messages` can be `nil` with SignalKit loaded.** It is a scope over the bus
  named after the module's addon, the one `SignalKit:ForAddon(addonName)`
  returns. That bus cannot be had when the session already holds SignalKit's
  bound of buses (`ForAddon` answers `nil, "full"`), or when it was closed
  (LifecycleKit closes it at logout); `Messages` then reads as `nil`, exactly
  as for an absent Kit, and nothing is cached, so a later read tries again.
  Publishing is not a scope operation: publish on
  `SignalKit:ForAddon(addonName)` directly.
- **The enable window.** The fields are available from the start of `OnEnable`
  until the module is disabled. Reading one at any other time — in
  `OnInitialize`, or while the module is disabled — raises at the reading line.
- **Released on every way out.** `Disable()`, `DisableAll()`, terminal
  shutdown and the addon halting close every scope the module created, after
  `OnDisable` has run, in the fixed order comm, commands, events, hooks,
  jobs, messages, timers; a failed `OnEnable` closes whatever it created before failing; at
  shutdown or halt a module whose `OnDisable` fails still has its scopes
  closed. The next enable starts with fresh scopes.
- A module that stays enabled because its `OnDisable` failed outside shutdown
  keeps its scopes, like the rest of its state.

## Intent versus fact

A module records what it is *meant* to be separately from what it *is*:

```lua
local state = module:GetEnableState()
-- state.wanted     boolean: what Enable/Disable last asked for
-- state.actual     boolean: whether the module is enabled right now
-- state.blockedBy  string|nil: what keeps it off (a hard dependency, a halted addon)
```

`GetEnableState()` returns a fresh table on every call.

**How intent is set.** Every module starts wanted (`wanted = true`): it is meant
to be enabled once its addon is ready. `module:Enable()` and `EnableAll()` set
it; `module:Disable()` and `DisableAll()` clear it, and only for the modules
they are called on. A successful enable of any kind also sets it. The
LifecycleKit `ready` phase does not set it and skips modules that are not
wanted. Terminal shutdown changes the fact only.

**Recovery.** A wanted module that could not be enabled because a hard
dependency failed, or was not enabled under the `strict` policy, records that
dependency in `blockedBy` and keeps `wanted = true`. So does a dependent that an
`automatic`-policy `Disable()` of its dependency took down: a cascade is a block,
not a change of intent, whether the dependency went away by failure or by an
explicit call. Each module taken down names its own direct dependency: when
`Base:Disable()` takes down `Middle`, which depends on `Base`, and `Top`, which
depends on `Middle`, `Middle` reports `Base` and `Top` reports `Middle`. When the dependency is
later enabled — by its own `Enable()`, by `Activate()`, or by `EnableAll()` —
every blocked module whose hard dependencies are now all enabled is enabled
too, in graph order, so a whole chain recovers at once.

- An explicit `Disable()` on the module itself wins: it clears `wanted` and
  `blockedBy`, and the module is not brought back when its dependency recovers.
- A recovered module whose own `OnEnable` fails stays off, is no longer
  considered blocked, and its error is re-raised from the `Enable()` that
  triggered the recovery; that dependency stays enabled.
- Recovery never runs inside a whole-container operation, which decides
  blocking for every module itself, and never after shutdown.
- `GetBlockedBy()` keeps its existing meaning — the module named by the last
  refused operation of any kind — and is independent of `blockedBy` here.
- A module blocked by a halt never recovers; see [Halted addons](#halted-addons).

## Halted addons

LifecycleKit lets an addon declare itself non-functional for the rest of the
session (`instance:Halt(reason)`), and tells every addon that declared it with
`DependsOn`. ModuleKit maps both onto intent versus fact.

**The addon itself halts.** Every enabled module is disabled, in reverse graph
order, as best-effort terminal cleanup: LifecycleKit never delivers `shutdown`
to a halted addon, so this is the container's last cleanup. It works like
shutdown — a module whose `OnDisable` fails still has its scopes closed — but
it keeps intent: every wanted module reports `blockedBy = "halted"`. The
container stays open to inspection and still accepts new modules, which are blocked
the same way when they are created.

**A required addon halts.** A module names the addons it cannot work without
in its definition:

```lua
addon:CreateModule("Bridge", {
    requiresAddons = { "OtherAddon" },
    onEnable = function(self) OtherAddon:Register(self) end,
})
```

`CreateModule` declares each of them on the owning addon's LifecycleKit
instance (`DependsOn`), so the addon hears when one halts. A module lists at
most `maxRequiredAddons` addons, **16** by default, which matches LifecycleKit's
bound on one addon's declared dependencies (see [Limits](#limits)); that bound
is per addon, so when the addon has already declared 16 others,
`CreateModule` raises and the module is not created. An addon the addon
already declared costs nothing more. Naming the module's own addon raises.

When a required addon halts, every module that names it is disabled, and so
are its enabled hard dependents first, whatever the dependency policy (a
halted addon cannot be waited for). The module keeps its intent and reports
the addon's name in `blockedBy`; each dependent reports its own direct
dependency, as a cascade always does, so a dependent of the module reports the
module and a dependent of that dependent reports the dependent. A module that does not name the addon is untouched, even
when the addon declared that dependency itself. A module created after its
required addon halted is blocked when it is created. A failing `OnDisable`
leaves that one module enabled; the others are still taken down and the first
error is re-raised from `Halt`.

**Halted is terminal.** LifecycleKit offers no resume, so no recovery path
brings such a module back:

- `module:Enable()` and `module:Activate()` raise at the caller's line, for
  example `ModuleKit module "Bridge" cannot be enabled because required addon
  "OtherAddon" has halted`, or `... because its addon "MyAddon" has halted`,
  and record the blocker in `GetBlockedBy()` and `blockedBy`;
- `EnableAll()`, and the LifecycleKit `ready` phase, record the module as
  blocked without raising, and block its hard dependents behind it;
- a definition-table module caught up after a halt is blocked without
  raising out of `CreateModule`;
- recovery of blocked dependents skips it, so enabling its other
  dependencies leaves it off.

A module whose own `OnEnable` halts its addon, or one of its `requiresAddons`,
is taken down as soon as the hook returns, exactly as the halt would have taken
it down had it already been enabled: it runs `OnDisable`, keeps its intent and
reports the halt in `blockedBy`. The `Enable` that started it does not raise
for that; under the `automatic` policy the module that asked for it stays off.
That module is blocked by the halt when the halt stops it too (`"halted"` for
its own addon, or the name of an addon it requires), the value a direct
`Enable` of it would now record, and by the dependency otherwise.

`"halted"` is the value for the addon's own halt. A module named `halted`
would read the same; do not name a module that.

The check asks LifecycleKit each time: `IsHalted()` on the addon's own
instance and `GetHaltReason()` on `LifecycleKit:ForAddon(requiredAddon)`, which
creates that addon's lifecycle instance if nothing has yet. A LifecycleKit
revision older than the halted state never reports a halt.

An in-place upgrade preserves both fields. A module created by a revision older
than 6 has its intent derived from its state: a `disabled` module is not
wanted, every other module is.

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

Whole-container operations validate the complete graph. Missing hard dependencies and graph cycles fail with human-readable diagnostics, raised at the line that called `InitializeAll()`, `EnableAll()`, `DisableAll()`, `ValidateGraph()`, `GetActivationOrder()`, `Initialize()`, `Enable()` or `Activate()`, however deep in a dependency chain the problem was found. A definition-table module that catches up inside `CreateModule` reports the same failures at the `CreateModule` line.

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

### Implements

Every `Provide*` method takes an optional third argument, an options table with
one field, `implements`, that states what the provided value must carry:

```lua
addon:ProvideSingleton("Database", function()
    return Database:New()
end, { implements = { "Save", "Load" } })
```

**The list form** is a dense array of distinct, non-empty method names. Each is
looked up as `value[name]`, so a method inherited through a metatable counts,
and must be a function. An empty list, a name listed twice, an entry that is
not a non-empty string, a sparse array, a keyed table or a non-table value is
refused at the `Provide*` line, as is an options table with any other field.

**When the check runs.** Exactly once per value ModuleKit hands out, and before
that value is cached:

| Provider | Checked |
|---|---|
| `ProvideValue` | at registration, since the value exists; a refused value is not registered and the name stays free |
| `ProvideSingleton` | when the factory's result first arrives |
| `ProvideModule` | when the result for each requesting module first arrives |
| `ProvideTransient` | on every resolution, since every value is new |

A cached value is never checked again: a singleton costs one lookup per name,
once. A refused value is not cached, so the next resolution runs the factory
again, exactly as after a factory that returned `nil`.

**Where a failure is raised.** For `ProvideValue` and for a module definition,
at the line that registered it. For a lazy provider, out of the operation that
first produced the value: `addon:Resolve` or `module:Resolve` raise at their
caller's line; through injection the failure is recorded as the module's
(`HasLastError()`, the module stays in its previous state) and re-raised by the
`Initialize`, `Enable`, `Activate` or whole-container call that resolved it,
like any other provider error. The message names the provider, and for a
module-scoped provider the requesting module, and the member:

```text
ModuleKit provider "Database" must implement "Load": no such member
ModuleKit provider "Database" must implement "Save": member "Save" is a string, not a function
ModuleKit provider "Database" must implement "Save": the value is a number, not a table
ModuleKit provider "Logger[UI]" must implement "Log": no such member
ModuleKit module "Inventory" must implement "OnEnable": no such member
```

ModuleKit does not record where a provider was registered (the client offers no
source positions at run time), so find the `Provide*` call by the provider's
name. The message never contains the value itself, only type names.

**The schema form.** When SchemaKit API 1 is loaded, `implements` may instead be
a SchemaKit node or sealed schema, and the value is validated with
`schema:Check(value)` at the same moments:

```lua
local S = SchemaKit
local function isFunction(value) return type(value) == "function" end

addon:ProvideValue("Settings", settings, {
    implements = S.table({
        fields = {
            Save = S.custom(isFunction, "function"),
            scale = S.number({ min = 0.5, max = 2 }),
        },
        open = true,
    }),
})
```

The node is sealed at registration (`SchemaKit:Seal`), so the contract owns its
failure record. A failure reads `ModuleKit provider "Settings" does not match
its implements schema: at scale, expected number, found string` (`expected
table, found number` for a failure at the root); SchemaKit's failure record
never contains the checked value, so neither does the message. SchemaKit reads
table fields with `rawget`, by its own contract, so a table schema sees a
value's own fields only: a method inherited through a metatable satisfies the
list form, not a schema. A module's table carries ModuleKit's private fields,
so a table schema over a module must be `open`. SchemaKit is found through `Registry:Find("schemaKit", 1)` at
registration, never at load; when it is not loaded and a schema is passed, the
call is refused at its line: `options.implements is a SchemaKit schema, but
SchemaKit API 1 is not loaded`. A table that only presents SchemaKit's
metatable name is refused when SchemaKit cannot seal it.

The list a caller passes is copied, so editing it afterwards changes nothing.
A provider registered without options is never checked, whatever it produces.
The options, and for `ProvideValue` the value, are validated before the name is
claimed, so an `implements` failure is reported before a `name "..." is already
in use` conflict on the same call.

### Injection

```lua
module:Inject({
    database = "Database",
    logger = "Logger",
})
```

Injection targets are **names**, never objects. `Inject("database", "Database")` declares the provider or module *named* `Database`; passing the module or a provider's value instead is rejected. Names are resolved at initialization time, which is what lets a module declare an injection before the target has been registered.

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

## Argument and state errors

Every refusal below is raised at the line that called the public method,
including a refusal found while a definition table is applied, which is raised
at the `CreateModule` line. Messages name the public method in full.

| Raised by | Message |
|---|---|
| `ForAddon` | `ModuleKit:ForAddon addonName must be a non-empty string` |
| `SetDependencyPolicy` | `ModuleKit.Addon:SetDependencyPolicy policy must be "automatic" or "strict"` |
| `CreateModule`, `GetModule`, `HasModule` | `ModuleKit.Addon:<Method> name must be a non-empty string` |
| `CreateModule` | `ModuleKit.Addon:CreateModule name "<name>" is already in use` (a module or a provider) |
| `CreateModule` | `ModuleKit.Addon:CreateModule definition must be a table when provided` |
| `CreateModule` | `ModuleKit module definition contains unknown field "<field>"` (the first unknown field in sorted order) |
| `CreateModule` | `ModuleKit module definition <field> must be a dense array` |
| `CreateModule` | `ModuleKit module definition <hook> must be a function` |
| `CreateModule` | `ModuleKit module definition requiresAddons entries must be non-empty strings`, `... must name other addons, not "<addon>" itself`, `... must list at most <n> addons (ModuleKit:SetLimits maxRequiredAddons)` |
| `CreateModule` | `ModuleKit.Addon:CreateModule module "<name>" requires addon "<addon>", but addon "<own>" already declares the most addon dependencies LifecycleKit accepts` |
| `CreateModule`, `Before` | `ModuleKit cannot create late module "<name>" because it would need to run before already-initialized module "<other>"`; `ModuleKit module "<name>" cannot be ordered before already-initialized module "<other>"` |
| `DependsOn`, `OptionalDependency`, `Before`, `After` (and the matching definition lists) | `ModuleKit.Module:<Method> moduleName must be a non-empty string`; `ModuleKit module "<name>" cannot depend/order against itself` |
| `DependsOn`, `OptionalDependency`, `Before`, `After`, `Inject` | `ModuleKit.Module:<Method> cannot change module "<name>" after initialization` |
| `Inject` (and the definition's `inject`) | `ModuleKit.Module:Inject map aliases must be non-empty strings`, `ModuleKit.Module:Inject alias must be a non-empty string`, `ModuleKit.Module:Inject target must be a non-empty string` |
| `Provide*` | `ModuleKit.Addon:<Method> providerName must be a non-empty string`, `... name "<name>" is already in use`, `... factory must be a function`, `... options must be a table when provided`, `... options contains unknown field "<field>"` (first in sorted order); the `implements` refusals are listed under [Implements](#implements) |
| `ProvideValue` | `ModuleKit.Addon:ProvideValue value must not be nil` |
| `Resolve` | `ModuleKit.Addon:Resolve providerName must be a non-empty string` (`ModuleKit.Module:Resolve ...` for the module form), `ModuleKit.Addon:Resolve requestingModule must be a module owned by this addon`, `ModuleKit injectable "<name>" does not exist`, `ModuleKit module-scoped provider "<name>" requires a requesting module`, `ModuleKit provider "<name>" factory returned nil`, `ModuleKit provider resolution cycle: A -> B -> A` |
| `Initialize`, `Enable`, `Activate` | `ModuleKit strict policy: module "<name>" requires initialized dependency "<dependency>"` (`enabled` for `Enable`); `ModuleKit dependency cycle detected while initializing "<name>"` (`enabling`); `ModuleKit module "<name>" cannot be enabled from state "<state>"`; the halted refusals under [Halted addons](#halted-addons) |
| `Disable` | `ModuleKit strict policy: cannot disable module "<name>" while dependent "<dependent>" is enabled` |
| graph operations | `ModuleKit module "<name>" requires missing dependency "<dependency>"`, `ModuleKit dependency cycle detected: A -> B -> A` |
| after shutdown | `<Method> cannot run after addon shutdown`, for example `ModuleKit.Addon:ProvideValue cannot run after addon shutdown` or `ModuleKit.Module:Enable cannot run after addon shutdown` |
| reading `module.scope.<Field>` outside the enable window | `ModuleKit module "<name>" scope.<Field> is available only while the module is enabling or enabled` |
| `SetLimits` | `ModuleKit:SetLimits limits must be a table`; `ModuleKit:SetLimits limits.<name> is not a recognised limit` (a name that is not a string is shown with `tostring`, for example `limits.1`); `ModuleKit:SetLimits limits.<name> must be a positive integer or ModuleKit.UNBOUNDED`; the LifecycleKit ceiling refusals under [Limits](#limits). Nothing changes on a refusal. |
| `SetLimits`, `GetLimits` | `ModuleKit:SetLimits must be called on the ModuleKit facade; use ModuleKit:SetLimits(...)`, `ModuleKit:GetLimits must be called on the ModuleKit facade; use ModuleKit:GetLimits()` |

A secret value (Retail 12.0.0 and later) cannot be compared, and a secret key
cannot be used to index a table, so every name, list entry, policy, limit and
table key that ModuleKit compares or uses as a key is checked for one first and
refused at the caller's line, before anything changes:

| Raised by | Message |
|---|---|
| every method that takes a name (`ForAddon`, `CreateModule`, `GetModule`, `HasModule`, `DependsOn`, `OptionalDependency`, `Before`, `After`, `Inject`, `Provide*`, `Resolve`) | `<the label of the non-empty-string message above> must not be a secret value`, for example `ModuleKit.Addon:CreateModule name must not be a secret value` or `ModuleKit.Module:Inject target must not be a secret value` |
| `CreateModule` | `ModuleKit module definition requiresAddons entries must not be secret values` |
| `CreateModule`, `Provide*` | `<label>.implements entries must not be secret values`, for example `ModuleKit.Addon:ProvideValue options.implements entries must not be secret values` |
| `SetDependencyPolicy` | `ModuleKit.Addon:SetDependencyPolicy policy must not be a secret value` (the policy is kept) |
| `SetLimits` | `ModuleKit:SetLimits limits.<name> must not be a secret value` (a value); `ModuleKit:SetLimits limit names must not be secret values` (a key) |
| `CreateModule` | `ModuleKit module definition field names must not be secret values` (a key of the definition table) |
| `CreateModule` | `ModuleKit module definition <field> must be a dense array` (a secret key of a definition list, which cannot be an index) |
| `Provide*` | `ModuleKit.Addon:<Method> options field names must not be secret values` (a key of the options table); `<label>.implements must be a dense array of method names or a SchemaKit schema` (a secret key of an `implements` list) |
| `Inject` (and the definition's `inject`) | `ModuleKit.Module:Inject map aliases must not be secret values` (a key of the alias map) |
| `Resolve` | `ModuleKit.Addon:Resolve requestingModule must not be a secret value`; a table whose `_name` is secret is not a module of the container and is refused as `requestingModule must be a module owned by this addon` |

Two reads accept a secret without refusing it, because neither is an argument
error: `module.scope[<secret>]` reads as `nil`, like any key that names no
scope field, and an `implements` table whose `__metatable` is secret is read
as a method list, since it cannot be a SchemaKit schema.

A provided value, an injected value and a factory's result are never compared,
so a secret one is accepted: absence is recognised by type, never by comparing
with `nil`. On a host without `issecretvalue` nothing is secret.

A hook field that is set but is not a function is not refused when it is
assigned; the phase that would call it records `ModuleKit module "<name>"
<Hook> must be a function` as the module's failure and re-raises it.

## Cost

Name lookups (`GetModule`, `HasModule`, the `Get*` / `Is*` inspection methods)
are table reads and allocate nothing. `GetModules`, `GetInjections`,
`GetEnableState` and `GetLimits` return a fresh table on every call. Resolving
a value, or a singleton or module-scoped provider already cached for the
requester, allocates nothing; a factory run allocates one resolution-stack
entry, and the `implements` list form adds one `value[name]` lookup per
declared name. Graph operations (`ValidateGraph`, `GetActivationOrder`, the
whole-container passes, and a targeted `Enable` or `Activate` while some
module is blocked by a dependency) build the graph afresh on every call and
allocate in proportion to modules and edges. All of these are lifecycle-scale
operations; none is meant to run per frame.

## LifecycleKit integration

For each addon container:

- LifecycleKit `loaded` → `InitializeAll()`
- LifecycleKit `ready` → the whole-container enable, which states no intent: a module the addon explicitly disabled stays disabled (see [`EnableAll()` re-enables explicitly disabled modules](#enableall-re-enables-explicitly-disabled-modules))
- LifecycleKit `shutdown` → terminal reverse-order cleanup
- LifecycleKit `OnHalted` → the addon's own halt; see [Halted addons](#halted-addons)
- LifecycleKit `OnDependencyHalted` → a required addon's halt

After shutdown, the container is terminal: new modules, graph/injection definition changes, provider registration, dependency-policy changes, and enable/initialize operations are rejected. Read-only inspection, resolution of already-registered providers, and idempotent disable operations remain available.

Lifecycle subscriptions dispatch through revision-independent shared runtime state. Compatible embedded ModuleKit upgrades therefore preserve existing addon/container identity while moving already-created containers onto the newest accepted implementation, and same-revision bootstrap can repair incomplete shared dispatch after an interrupted bootstrap.

Each container records which lifecycle phases have already been dispatched into it. An upgrade re-subscribes only to phases that have not been dispatched yet, so it never replays `loaded` or `ready` into a container that already received them. Without that, an upgrade would run module hooks out of package bootstrap and the replayed `ready` phase would re-enable modules the addon had deliberately disabled. Phases that have not been reached are still subscribed to, so an upgraded container keeps its shutdown cleanup.

Errors raised out of a phase dispatch leave ModuleKit with the original Lua error object. What happens to them beyond that is EventKit's contract: EventKit isolates listeners at the event-bus boundary and reports the error through the host error handler, so one addon's failing module cannot stop delivery to another addon.

## Limits

ModuleKit bounds what a module may declare, and the bound holds unless the
addon opens it on purpose.

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxRequiredAddons` | 16 | `ModuleKit:SetLimits({ maxRequiredAddons = n })` | Yes, unless LifecycleKit reports an integer `maxDependencies` |

```lua
ModuleKit:SetLimits({ maxRequiredAddons = 24 })
ModuleKit:SetLimits({ maxRequiredAddons = ModuleKit.UNBOUNDED })
local limits = ModuleKit:GetLimits() -- a fresh table on every call
```

`maxRequiredAddons` is the most addons one module may name in
`requiresAddons`. A definition over it is refused at the `CreateModule` line
(`requiresAddons must list at most 16 addons (ModuleKit:SetLimits
maxRequiredAddons)`) and the module is not created.

`SetLimits` accepts any subset of the limits and raises at the caller's line
on an unknown name (`ModuleKit:SetLimits limits.<name> is not a recognised
limit`), a secret name or value, or an invalid value, before changing
anything: a value must be a positive integer or `ModuleKit.UNBOUNDED`, the
package's sentinel for "no limit". [Argument and state
errors](#argument-and-state-errors) lists every message. `GetLimits` returns a new table on every call, so it allocates;
read it at setup, not per frame. **The limits are shared by every consumer in
the session**: every embedded copy and every addon uses one set, so a library
should rely on the default, and an addon that raises a limit raises it for
everybody. Lowering a limit never removes what modules already declared; it
only refuses later definitions over it.

**Coupling to LifecycleKit.** Every required addon is also declared on the
owning addon's LifecycleKit instance, and LifecycleKit bounds one addon's
declared dependencies as a whole (`maxDependencies`, 16). ModuleKit's limit is
per module, LifecycleKit's per addon, so LifecycleKit's is the one that decides
in the end: past it `CreateModule` raises `already declares the most addon
dependencies LifecycleKit accepts` whatever `maxRequiredAddons` says. When the
loaded LifecycleKit reports its limit through `LifecycleKit:GetLimits()`,
`SetLimits` checks against it at call time: a value above it is refused (`must
be an integer from 1 to <n>, LifecycleKit's maxDependencies`) and
`ModuleKit.UNBOUNDED` is refused (`cannot be ModuleKit.UNBOUNDED: LifecycleKit
accepts at most <n> dependencies per addon`) unless LifecycleKit reports its own
`UNBOUNDED`. A LifecycleKit that reports no limit is not consulted, and raising
`maxRequiredAddons` past 16 then only helps once LifecycleKit's own limit is
opened.

The sentinel and the limits live in the package state, so an in-place upgrade
keeps both: a newer compatible revision inherits the limits a consumer set, and
`ModuleKit.UNBOUNDED` keeps its identity across every revision.

ModuleKit keeps no hard ceiling of its own: the other collections it retains
(containers, modules, edges, providers) are the consumer's own declarations and
grow only with them.

## Dependencies

ModuleKit API 1 requires:

- Registry API 2
- LifecycleKit API 1

ModuleKit does not depend directly on EventKit or SignalKit; those are implementation dependencies of LifecycleKit and remain outside ModuleKit's direct contract.

Module scopes use TimerKit API 1, EventKit API 1, SchedulerKit API 1, HookKit
API 1, CommandKit API 1, CommKit API 1 and SignalKit API 1 when they are
loaded, found through `Registry:Find`
(Registry revision 7; an older Registry's `Get` is used as the equivalent
fallback). None of them is a required dependency: without them the matching scope field
reads as `nil`. The schema form of `implements` uses SchemaKit API 1 the same
way, at registration, and refuses a schema when SchemaKit is not loaded; the
list form needs nothing. TimerKit, SchedulerKit, HookKit, CommandKit, CommKit
and SchemaKit are declared under `optionalDependencies` in the manifest;
EventKit and SignalKit are always present through LifecycleKit.

## Internals

[`INTERNALS.md`](INTERNALS.md) documents the section map of the runtime file, the ordering algorithm, the failure model, the lifecycle replay hazard, and the re-entrancy rules. It is maintainer documentation, not part of this contract.
