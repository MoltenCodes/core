# LifecycleKit

LifecycleKit converts low-level World of Warcraft loading/login/logout events into a small, replay-aware per-addon lifecycle contract.

```lua
local lifecycle = LifecycleKit:ForAddon("MyAddon")

lifecycle:OnLoaded(function(self)
  -- The addon's ADDON_LOADED event has completed its transition.
end)

lifecycle:OnReady(function(self)
  -- The addon is loaded and the player is logged in.
end)

lifecycle:OnShutdown(function(self)
  -- PLAYER_LOGOUT has begun.
end)
```

A lifecycle instance moves through `loading`, `loaded`, `ready`, and `shutdown`. Phase subscriptions are one-shot and replay synchronously for late subscribers, so consumers do not need to race WoW events.

```text
loading → loaded → ready → shutdown
   │         │        │
   └─────────┴────────┴──→ halted      (Halt; terminal for the session)
```

An addon that cannot work declares it, and the addons that depend on it are told (the Halt part, `parts/LifecycleKit-Halt.lua`):

```lua
lifecycle:OnLoaded(function(self)
  if not MyAddonDB or MyAddonDB.version == nil then
    self:Halt("saved variables are unreadable")
  end
end)

local consumer = LifecycleKit:ForAddon("MyPlugin")
consumer:DependsOn("MyAddon")
consumer:OnDependencyHalted(function(self, dependencyName, reason)
  self:Halt(dependencyName .. " halted: " .. reason)
end)
```

The combat gate (the CombatGate part, `parts/LifecycleKit-CombatGate.lua`) keeps one lockdown state for every addon and defers protected frame work until combat ends:

```lua
lifecycle:WhenOutOfCombat(function(self, ran, reason)
  if ran then
    MyAddonSecureButton:SetAttribute("spell", MyAddonDB.spell)
  end
  -- ran is false, with reason "shutdown" or "halted", when the queue closed first
end)

lifecycle:OnCombatStart(function(self)
  MyAddonOptionsFrame:Hide()
end)
```

`WhenOutOfCombat` runs at once out of combat; in combat it queues the call (at most 64 per addon by default, `nil, "full"` beyond; `SetCombatQueueLimit` and `LifecycleKit:SetLimits` open it, `LifecycleKit.UNBOUNDED` included) and returns a handle with `Cancel()`. `LifecycleKit:IsInCombat()` answers from the shared state.

At shutdown, after the shutdown callbacks, LifecycleKit closes what the addon owns through the other Kits: its TimerKit scope (`TimerKit:ForAddon(name)`, when TimerKit is loaded), its SchedulerKit scope (`SchedulerKit:ForAddon(name)`, when SchedulerKit is loaded), its EventKit scope (`EventKit:ForAddon(name)`), its HookKit scope (`HookKit:ForAddon(name)`, when HookKit is loaded), its CommandKit scope (`CommandKit:ForAddon(name)`, when CommandKit is loaded), its CommKit scope (`CommKit:ForAddon(name)`, when CommKit is loaded) and its SignalKit bus (`SignalKit:ForAddon(name)`, when SignalKit is loaded), in that order. Timers, jobs, connections, hooks and subscriptions made through them need no teardown code. `LifecycleKit.CLOSES_ADDON_SCOPES` is the read-only list of those packages, which they read to leave the closing to LifecycleKit; from 0.6.0 on, LifecycleKit pairs with any revision of them.

`LifecycleKit:ForAddon(name)` is idempotent: every caller in the same runtime receives the same lifecycle instance for that addon name.

The name is matched exactly against the folder name WoW reports in `ADDON_LOADED`, so pass the addon's own name — inside an addon file, `local addonName = ...`.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Moving from AceAddon-3.0

LifecycleKit is the lifecycle half of AceAddon-3.0; modules are ModuleKit,
which runs on it.

| AceAddon-3.0 | LifecycleKit |
|---|---|
| `LibStub("AceAddon-3.0"):NewAddon("MyAddon")` | `LifecycleKit:ForAddon("MyAddon")`, the same instance for every caller |
| `MyAddon:OnInitialize()`, run at `ADDON_LOADED` | `lifecycle:OnLoaded(callback)`; a callback added after the phase runs at once |
| `MyAddon:OnEnable()`, run at `PLAYER_LOGIN` | `lifecycle:OnReady(callback)`: loaded and logged in, also for a load-on-demand addon loaded later |
| `MyAddon:OnDisable()`, run only when something disables the addon | `lifecycle:OnShutdown(callback)`, run at `PLAYER_LOGOUT`; there is no runtime disable of a whole addon |
| `NewModule`, `GetModule`, `EnableModule` | ModuleKit (`ModuleKit:ForAddon(name):CreateModule(...)`) |
| no equivalent | `Halt` and `DependsOn`/`OnDependencyHalted`, the combat gate (`WhenOutOfCombat`, `OnCombatStart`, `OnCombatEnd`) and the closing of the addon's Kit scopes at shutdown |

See [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#aceaddon-30).

## Parts

LifecycleKit is a core file and two optional parts. The core holds the phases,
their subscriptions and queries, the halted-state observers (`IsHalted`,
`GetHaltReason`, `OnHalted`) and the closing of the addon's scopes at shutdown.

| Part | File | Adds |
|---|---|---|
| CombatGate | `lifecycleKit\parts\LifecycleKit-CombatGate.lua` | `IsInCombat`, `WhenOutOfCombat`, `OnCombatStart`, `OnCombatEnd`, the combat-queue limit, `DeferredCall` |
| Halt | `lifecycleKit\parts\LifecycleKit-Halt.lua` | `Halt`, `DependsOn`, `OnDependencyHalted` |

Without a part its members raise at the calling line and name the file to
embed; `LifecycleKit:HasPart(name)` answers whether one is loaded.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\lifecycleKit\parts\LifecycleKit-CombatGate.lua
Libs\MoltenCodes\lifecycleKit\parts\LifecycleKit-Halt.lua
```

Minimum footprint: Embed 3 files: Registry, EventKit, LifecycleKit (SignalKit
too while EventKit requires it); each part is one more line.

Direct runtime dependencies: EventKit API 1, Registry API 2. Omitting either
makes this package raise at load. SignalKit API 1, TimerKit API 1,
SchedulerKit API 1, HookKit API 1, CommandKit API 1 and CommKit API 1 are
optional: when the addon embeds them, shutdown also cancels the addon's scoped
timers and jobs, undoes its scoped hooks, leaves its scoped slash commands
inert, closes its addon-message scope and closes its bus. They may load before
or after LifecycleKit; none depends on it.
