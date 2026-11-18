# LifecycleKit API

LifecycleKit API generation **1** provides per-addon lifecycle coordination over MoltenCodes EventKit: four lifecycle phases, the closing of each addon's scopes in the other Kits at shutdown, and, as optional parts, a halted state an addon can declare and a combat gate shared by every addon.

## Loading

Load Registry and EventKit first, then `LifecycleKit.lua`, then the parts the addon uses:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\lifecycleKit\parts\LifecycleKit-CombatGate.lua
Libs\MoltenCodes\lifecycleKit\parts\LifecycleKit-Halt.lua
```

`python3 -m tooling.package.embeds` writes this list for any selection of Kits and parts. While EventKit itself still requires SignalKit (its revisions up to 22), SignalKit loads before EventKit.

LifecycleKit API 1 requires Registry API 2 and EventKit API 1. Neither part needs anything beyond the core. It optionally uses SignalKit API 1, TimerKit API 1, SchedulerKit API 1, HookKit API 1, CommandKit API 1 and CommKit API 1, each found through `Registry:Find` (Registry revision 7; an older Registry's `Get` is the equivalent fallback) when an addon shuts down. Without them nothing changes except that there are no timers to cancel, no jobs to cancel, no hooks to undo, no commands to make inert, no addon-message scopes and no bus to close. None of the Kits whose scopes shutdown closes depends on LifecycleKit: LifecycleKit calls into them, which is what lets each embed without it. Each finds LifecycleKit through `Registry:Find` in the same way and reads `CLOSES_ADDON_SCOPES` to learn that it closes that Kit's addon scopes. Before revision 19 SignalKit was required: each instance kept its subscribers in SignalKit signals.

LifecycleKit does not create WoW Frames directly. All frame/event registration remains inside EventKit.

Host API read directly: `C_AddOns.IsAddOnLoaded` (falling back to the legacy `IsAddOnLoaded`), `IsLoggedIn`, and, in the CombatGate part, `InCombatLockdown`. Every one is optional; without it LifecycleKit assumes not loaded, not logged in, and not in combat respectively. Host events observed through EventKit: `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT`, and, in the CombatGate part, `PLAYER_REGEN_DISABLED` and `PLAYER_REGEN_ENABLED`.

## Public surface

The facade carries two read-only constants: `LifecycleKit.API`, the API generation (`1`), and `LifecycleKit.REVISION`, the implementation revision of the copy that is active in the session (`19` for this one). A newer embedded copy replaces `REVISION` when it upgrades the facade in place.

| Member | Where |
|---|---|
| `LifecycleKit:ForAddon(addonName)`, `LifecycleKit:HasPart(name)`, `LifecycleKit:SetLimits(limits)`, `LifecycleKit:GetLimits()`, `LifecycleKit.UNBOUNDED`, `LifecycleKit.CLOSES_ADDON_SCOPES` | core |
| `GetAddonName`, `GetState`, `IsLoaded`, `IsReady`, `IsShutdown`, `IsHalted`, `GetHaltReason`, `OnLoaded`, `OnReady`, `OnShutdown`, `OnHalted` | core (instance) |
| `Subscription:Disconnect()`, `Subscription:IsConnected()` | core |
| `LifecycleKit:IsInCombat()`, `WhenOutOfCombat`, `OnCombatStart`, `OnCombatEnd`, `SetCombatQueueLimit`, `GetCombatQueueLimit`, `DeferredCall:Cancel()`, `DeferredCall:IsPending()` | CombatGate part |
| `Halt`, `DependsOn`, `OnDependencyHalted` | Halt part |

## State model

A lifecycle instance reports one of five states:

```text
loading → loaded → ready → shutdown
   │         │        │
   └─────────┴────────┴──→ halted      (Halt; terminal for the session)
```

`loaded` is reached when `ADDON_LOADED` is observed for the configured addon. `ready` is reached after the addon is loaded and the player is logged in. `shutdown` is reached when `PLAYER_LOGOUT` is observed. `halted` is reached when the addon calls `Halt` before shutdown; see [Halted state](#halted-state).

A load-on-demand addon may be created after `PLAYER_LOGIN`. LifecycleKit probes `IsLoggedIn()` and, when available, `C_AddOns.IsAddOnLoaded()` so it can catch up without waiting for events that will not repeat.

Both the modern and the legacy addon probe return `(loaded, finished)`. An addon whose files are executing but whose `ADDON_LOADED` transition has not completed answers `(true, false)`. LifecycleKit trusts only the second value, so a mid-load addon stays in `loading` and reaches `loaded` when its real `ADDON_LOADED` arrives.

### Non-goal: `PLAYER_ENTERING_WORLD`

`ready` means *loaded and logged in*, and nothing more. LifecycleKit deliberately does not observe `PLAYER_ENTERING_WORLD`.

`PLAYER_ENTERING_WORLD` fires again on every zone change, instance transition and `/reload`, so it is not a lifecycle phase: it is a world-state event with no one-shot meaning. Folding it into `ready` would either make a one-shot phase fire repeatedly or silently delay `ready` until the first world load, which is not what an addon that only needs saved variables and a logged-in player is waiting for. An addon that genuinely needs world state should subscribe to `PLAYER_ENTERING_WORLD` through EventKit itself, where its repeating nature is explicit.

## `LifecycleKit:ForAddon(addonName)`

Returns the stable lifecycle instance for `addonName`. Repeated calls with the same name return the same object.

`addonName` must be a non-empty string.

### Addon names are matched exactly

`addonName` is compared to the payload WoW delivers with `ADDON_LOADED`, which is the addon's folder name exactly as installed. Pass that same name: inside an addon file it is available as the first vararg of the file chunk (`local addonName = ...`).

LifecycleKit deliberately does not normalise case, and the contract is exact equality, because:

- the host is the authority on the name, and the payload it sends is the only string guaranteed to match;
- two addon folders may differ only by case, and normalising would merge two independent addons onto one lifecycle instance;
- `GetAddonName()` returns what the caller passed, so normalising would make it disagree with the caller and with the host;
- matching is on the `ADDON_LOADED` hot path, and case folding would allocate a string per event for a mismatch that is a caller bug.

A name that does not match the installed folder therefore never reaches `loaded`. That is a loud, debuggable failure rather than a silent near-match.

## Instance queries

```lua
instance:GetAddonName()
instance:GetState()
instance:IsLoaded()
instance:IsReady()
instance:IsShutdown()
instance:IsHalted()
instance:GetHaltReason()
```

`GetState()` returns `"loading"`, `"loaded"`, `"ready"`, `"shutdown"`, or `"halted"`. `halted` takes precedence over every phase.

The boolean query methods report whether that phase itself has been reached. They do not infer earlier phases solely from a later state, which keeps behavior well-defined even in unusual host/test sequences.

## Phase subscriptions

```lua
local subscription = instance:OnLoaded(callback)
local subscription = instance:OnReady(callback)
local subscription = instance:OnShutdown(callback)
```

Callbacks receive the lifecycle instance as their first argument. A delivery
that replays a phase already reached passes a second argument that is `nil`
(the slot `OnHalted` uses for its reason), so a callback that counts its
arguments with `select("#", ...)` sees two on replay and one on a live
delivery; read the instance and ignore the rest.

Each phase is delivered at most once per subscription. If the requested phase has already occurred, the callback is invoked synchronously before the method returns and the returned subscription is already disconnected. This replay behavior is intentional and prevents event-registration races.

When a phase transition callback raises an error, LifecycleKit records the transition before invoking callbacks. LifecycleKit isolates pending phase callbacks from one another: all callbacks already subscribed to that phase are given one delivery even when multiple callbacks fail, then the first callback error is re-raised with its original Lua error object (including non-string values such as `false`, `nil`, or tables). Internal progression that is already known (for example, `loaded` immediately followed by `ready` for a load-on-demand addon created after login) also continues before that error is re-raised.

`PLAYER_LOGIN` and `PLAYER_LOGOUT` are coordinated once at package scope. If one addon's ready/shutdown callback raises, LifecycleKit still advances every existing addon lifecycle instance through that global phase before re-raising the first callback error. This prevents one addon from starving another addon of a one-shot global transition.

### Replay and dispatch report failures identically

A subscription is delivered either by replay (the phase had already occurred when the method was called) or by dispatch (the phase occurred later). A consumer cannot know in advance which path its subscription will take, so the two report a failing callback the same way: the original Lua error object is re-raised unchanged, after LifecycleKit has committed its own phase state.

The two paths differ only in *where* the error surfaces, which follows from when the callback ran:

- a replayed callback runs inside `OnLoaded` / `OnReady` / `OnShutdown`, so its error leaves that call;
- a dispatched callback runs inside the host event delivery, so its error leaves that delivery — after every other subscriber pending for the same one-shot phase has been given its single delivery.

What happens to a dispatched error after it leaves LifecycleKit is EventKit's contract: EventKit isolates listeners at the event-bus boundary and reports the error through the host error handler, so one addon's failing lifecycle callback cannot stop event delivery to another addon.

When an addon reaches `shutdown`, LifecycleKit first closes the addon's canonical TimerKit scope (`TimerKit:CloseAddonScopes(addonName)`), which cancels every timer made through `TimerKit:ForAddon(addonName)`, and then its canonical SchedulerKit scope (`SchedulerKit:CloseAddonScopes(addonName)`), which cancels its jobs (lane submissions included), closes its `Debounce` and `Coalesce` handles, cancels its watches and releases its delay timers. Neither Kit depends on LifecycleKit, so neither observes shutdown: this is the second half of the two-step both document. TimerKit and SchedulerKit are optional: each is found through `Registry:Find` (`"timerKit"`, `"schedulerKit"`, API 1) at shutdown, and without it, or with a revision that has no `CloseAddonScopes` (TimerKit before 0.5.0, SchedulerKit before 0.6.0, which close their addon scopes themselves from a shutdown subscription), that step does nothing; `false` from `CloseAddonScopes` (no scope, or already closed) is not a failure.

After those two, LifecycleKit closes that addon's canonical EventKit scope (`EventKit:ForAddon(addonName)`) after the shutdown callbacks have run, so event connections made through the scope need no teardown code in the addon. EventKit cannot do this itself: it loads before LifecycleKit and never observes shutdown. With an EventKit revision that has no `CloseAddonScopes`, nothing is closed and shutdown is otherwise unchanged. Closing the scope never takes the logout away from the scope's own listeners: LifecycleKit's watcher runs inside EventKit's `PLAYER_LOGOUT` dispatch, and EventKit defers the disconnects until that dispatch returns, so a scoped `PLAYER_LOGOUT` listener still runs once. Combat-log listeners connected through the scope's `ConnectCombatLog` are closed with the rest. An addon that never asked for an EventKit scope has none to close: `CloseAddonScopes` answers `false` and records nothing.

The same two-step applies to the addon's HookKit scope, its CommandKit scope, its CommKit scope and its SignalKit bus. After the EventKit scope, LifecycleKit closes the addon's canonical HookKit scope (`HookKit:CloseAddonScopes(addonName)`), which undoes every hook made through `HookKit:ForAddon(addonName)`, then its canonical CommandKit scope (`CommandKit:CloseAddonScopes(addonName)`), which leaves every slash command registered through `CommandKit:ForAddon(addonName)` inert, then its canonical CommKit scope (`CommKit:CloseAddonScopes(addonName)`), which cancels its pending sends, closes its SyncSets and disconnects its prefix registrations, and then its bus (`SignalKit:CloseAddonBus(addonName)`, SignalKit found through `Registry:Find` like the others), which disconnects every subscription on the bus named after the addon, including those made through its scopes. HookKit, CommandKit, CommKit and SignalKit are optional: each is found through `Registry:Find` (`"hookKit"`, `"commandKit"`, `"commKit"`, `"signalKit"`, API 1) at shutdown, and without it, or with a revision that has no `CloseAddonScopes`, that step does nothing; `false` from `CloseAddonScopes` (no scope, or already closed) is not a failure. A CommKit older than 0.2.0 closes the scope of `CommKit:ForAddon` from its own `OnShutdown` subscription, among the shutdown callbacks, and then answers `false` here. A SignalKit revision without `CloseAddonBus` skips the last step the same way, and an addon that never asked for a bus has nothing to close (`CloseAddonBus` answers `false`, which is not a failure).

The seven are closed in this order for a reason:

1. **TimerKit scope first** and
2. **SchedulerKit scope second**, so no timer fires and no job runs into event listeners, hooks or bus subscribers that are being torn down.
3. **EventKit scope next**, so no host event fires into hooks or bus subscribers that are being torn down.
4. **HookKit scope next**, so the addon's hooks stop running.
5. **CommandKit scope next**, so the addon's slash commands become inert.
6. **CommKit scope next**, so the addon's addon messages stop being sent and received.
7. **SignalKit bus last**, because other addons' shutdown paths may still publish on it. Publishing on a closed bus delivers nothing and does not raise, so closing it last only keeps it useful for as long as possible.

Shutdown callbacks run before any of the seven is closed, so an `OnShutdown` callback can still rely on its timers, jobs, event connections, hooks, slash commands and addon-message scope and can still publish on its bus.

Shutdown therefore runs these steps per addon, in this order: the addon's combat queue is closed (CombatGate part; each pending deferred call receives `(instance, false, "shutdown")`), the shutdown callbacks run, then the TimerKit scope, the SchedulerKit scope, the EventKit scope, the HookKit scope, the CommandKit scope, the CommKit scope and the SignalKit bus are closed. Every step runs even when an earlier one failed. Errors follow a first-error-wins policy in that order: a deferred-call error is re-raised before a shutdown callback error, which is re-raised before a TimerKit, then a SchedulerKit, then an EventKit, then a HookKit, then a CommandKit, then a CommKit, then a SignalKit closing failure. Either way every addon's lifecycle has advanced first.

### Addon-scope capability: `CLOSES_ADDON_SCOPES`

`LifecycleKit.CLOSES_ADDON_SCOPES` names the packages whose addon scopes (for SignalKit, the addon bus) shutdown closes. It is the contract the scope-owning Kits read to decide whether LifecycleKit covers their addon scopes at logout or whether they have to arrange it themselves:

```lua
LifecycleKit.CLOSES_ADDON_SCOPES
-- { timerKit = true, schedulerKit = true, eventKit = true, hookKit = true,
--   commandKit = true, commKit = true, signalKit = true }
```

- **Read it with ordinary indexing**, `capabilities[packageId] == true`. It is a read-only view: every write raises (`LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "<key>" cannot be written`), including an overwrite of an existing entry, and `getmetatable` answers `false`. Because the view holds no keys of its own, `rawget`, `next` and `pairs` see nothing through it.
- **It names exactly what shutdown closes**: the seven steps above, one package id each. A package id not listed is not closed by this revision.
- **A LifecycleKit without the field closes none of them** as far as a reader is concerned. That is every revision before 13 (0.6.0), including those that do call some `CloseAddonScopes`: a reader then arranges the closing itself, typically through `LifecycleKit:ForAddon(addonName):OnShutdown(...)`, and a second close answers `false`.
- **It stays identical across upgrades.** The table and its contents live in the package state; every revision from 13 on publishes the same table, rewritten to name what that revision closes, and it is part of the public surface a newer copy must publish.

Every Kit it names reads it in its own `ForAddon` (TimerKit from 0.6.0, SchedulerKit from 0.8.0, EventKit from 0.7.0, SignalKit from 0.6.0, HookKit, CommandKit and CommKit from 0.2.0; see "At logout" in their `docs/API.md`). **LifecycleKit from 0.6.0 on pairs with any revision of the other Kits**: a Kit that reads the field leaves the closing to LifecycleKit; one that has `CloseAddonScopes` but does not read the field is closed by the calls above; one without `CloseAddonScopes` closes its scopes from its own shutdown subscription, as before.

If shutdown occurs before `loaded` or `ready` was reached (for example, a lifecycle was created for a load-on-demand addon that never loaded), pending subscriptions for those now-impossible phases are disconnected without invocation. New subscriptions to an earlier phase that is already impossible because shutdown occurred are returned already disconnected. Shutdown also disconnects the addon's `OnHalted`, `OnDependencyHalted`, `OnCombatStart` and `OnCombatEnd` subscriptions.

Each phase and notice keeps its subscriptions in a list of its own, delivered in subscription order. A subscription made while a notice is being delivered waits for the next delivery; one disconnected meanwhile is skipped at once; a raising callback does not stop the rest.

## Parts

```lua
LifecycleKit:HasPart("CombatGate") -- boolean
LifecycleKit:HasPart("Halt")       -- boolean
```

LifecycleKit is a core file and two optional parts (ADR 0001, `docs/decisions/0001-kit-core-and-parts.md`):

| Part | File | Members |
|---|---|---|
| `CombatGate` | `lifecycleKit\parts\LifecycleKit-CombatGate.lua` | `IsInCombat`, `WhenOutOfCombat`, `OnCombatStart`, `OnCombatEnd`, `SetCombatQueueLimit`, `GetCombatQueueLimit`, `DeferredCall:Cancel`, `DeferredCall:IsPending` |
| `Halt` | `lifecycleKit\parts\LifecycleKit-Halt.lua` | `Halt`, `DependsOn`, `OnDependencyHalted` |

A part loads after the core; loaded before it, it raises `MoltenCodes LifecycleKit part <Part> requires LifecycleKit API 1 to be loaded first`. Without a part its members stay on the facade and the prototypes, and each raises at the caller's line, for example `LifecycleKit.Instance:WhenOutOfCombat is in LifecycleKit's CombatGate part, which is not loaded: add lifecycleKit\parts\LifecycleKit-CombatGate.lua to embeds.xml after lifecycleKit\LifecycleKit.lua`. Another Kit that uses a part optionally asks `HasPart`, never `type(member) == "function"`, which a stub satisfies. `HasPart` raises `LifecycleKit:HasPart name must be a part name string` at the caller for a name that is not a string or is secret.

Without either part, `ForAddon`, the phases and their queries, `GetState`, `IsHalted`, `GetHaltReason`, `OnHalted`, `SetLimits`/`GetLimits` (both names), `UNBOUNDED` and `CLOSES_ADDON_SCOPES` work unchanged. A part keeps its per-addon state in the addon's instance (the combat queue from the first queued call, the dependency list from the first `DependsOn`) and its two combat watchers in the core's watcher table, so the core's logout teardown releases them, and a higher part revision loaded by another addon takes everything over in place.

## Halted state

`IsHalted`, `GetHaltReason` and `OnHalted` are in the core; `Halt`, `DependsOn` and `OnDependencyHalted` are in the **Halt part** (`parts/LifecycleKit-Halt.lua`, see [Parts](#parts)). A halt can come from any addon that embeds the part, so an addon that only watches for one needs the core alone; without the part in the session nothing halts, and an `OnHalted` subscription simply never fires and is disconnected at shutdown.

```lua
instance:Halt(reason)                    -- boolean
instance:OnHalted(callback)              -- Subscription; callback(instance, reason)
instance:DependsOn(otherAddonName)       -- true | false | nil, "full" | "halted" | "shutdown"
instance:OnDependencyHalted(callback)    -- Subscription; callback(instance, otherAddonName, reason)
```

An addon calls `Halt(reason)` when it cannot work: a failed dependency, a broken saved-variables file, an incompatible client. `reason` must be a non-empty string; it is kept for `GetHaltReason()` and passed to every subscriber. `Halt` returns `true` for the call that halted, and `false` when the addon is already halted or already shut down (shutdown is terminal too, so it cannot be followed by a halt).

Halting, in order:

1. The state becomes `halted`, and every phase the addon has not reached becomes unreachable. Its pending `OnLoaded` / `OnReady` / `OnShutdown` subscriptions are disconnected without invocation, exactly as shutdown does for the phases it rules out, and so are its `OnCombatStart`, `OnCombatEnd` and `OnDependencyHalted` subscriptions.
2. The addon's combat queue is closed: each pending deferred call receives `(instance, false, "halted")`.
3. The `OnHalted` subscribers run with `(instance, reason)`.
4. Every live addon that declared this one with `DependsOn` receives `OnDependencyHalted` with `(dependent, haltedAddonName, reason)`.

Every subscriber is given its delivery even when some fail, then the first error is re-raised from `Halt` with its original Lua error object, after the state is committed.

**Halted is terminal for the session.** API 1 offers no `Resume`: an addon that halted because something was broken cannot prove the breakage is gone, and a resumable state would need every dependent to handle a second transition. Reloading the UI starts a fresh session. Later host events do not move a halted addon: `ADDON_LOADED`, `PLAYER_LOGIN` and `PLAYER_LOGOUT` leave `IsLoaded()`, `IsReady()` and `IsShutdown()` as they were at the halt. The one exception is what the addon owns through the other Kits — its TimerKit scope, its SchedulerKit scope, its EventKit scope, its HookKit scope, its CommandKit scope, its CommKit scope and its SignalKit bus — which are still closed at logout, in the shutdown order, like every other addon's.

A halted addon does not close any of them at the halt. Event connections, hooks, slash commands, addon-message registrations and bus subscriptions it made stay live until logout, so it can still, for example, report its failure once the player logs in.

Phase subscriptions after a halt follow the shutdown rule: a phase reached before the halt still replays, and every other phase returns an already-disconnected subscription. `OnHalted` replays for a halted addon, synchronously, with the reason, like the phase subscriptions. For an addon that has shut down, `OnHalted` returns an already-disconnected subscription.

### The `_halted` field

Every instance carries `_halted`, a boolean field LifecycleKit alone writes:
`false` from creation, `true` from the moment `Halt` begins, before step 1
above and before any subscriber runs, and never `false` again. It is part of
API generation 1: its name and meaning stay for the life of the generation, so
another Kit may read it with `rawget(instance, "_halted") == true` instead of
calling `IsHalted()`. ModuleKit does exactly that on every module enable,
where the method call would cost more than the check. An instance made by a
revision older than the halted state has no field, and `nil` correctly reads
as "not halted". Write nothing to it: `Halt` is the only way in.

### Dependencies between addons

`DependsOn(otherAddonName)` records that this addon cannot work without another one. The name is matched exactly, like `ForAddon`, and the other addon does not need a lifecycle instance yet. The call returns `true` when it recorded the dependency and `false` when it was already recorded. An addon records at most `maxDependencies` dependencies, **16** unless changed with `LifecycleKit:SetLimits` (see [Limits](#limits)); the next one is refused with `nil, "full"`. A halted or shut-down addon refuses new dependencies with `nil, "halted"` or `nil, "shutdown"`. Declaring the addon itself raises an argument error.

If the dependency has already halted, `DependsOn` delivers `OnDependencyHalted` at once. `OnDependencyHalted` is a repeating subscription, and it replays every recorded dependency that has already halted when it is made, so the order of `DependsOn` and `OnDependencyHalted` does not matter: each subscriber hears of each halted dependency exactly once. A failing replay is re-raised from `OnDependencyHalted` after the other replays, and, as with a failing dispatch, the subscription stays connected. A replay that ends the subscription, typically by halting the dependent in response, stops the replay: a halted addon hears of no further dependency.

A dependent may itself `Halt` from inside `OnDependencyHalted`; its own dependents are then told in turn. Dependents that are already halted or shut down are not told.

## Combat gate

Everything in this section is the **CombatGate part** (`parts/LifecycleKit-CombatGate.lua`, see [Parts](#parts)).

```lua
LifecycleKit:IsInCombat()                 -- boolean
instance:WhenOutOfCombat(callback)        -- DeferredCall | nil, "full" | "halted" | "shutdown"
instance:OnCombatStart(callback)          -- Subscription; callback(instance)
instance:OnCombatEnd(callback)            -- Subscription; callback(instance)
instance:SetCombatQueueLimit(limit)
instance:GetCombatQueueLimit()            -- integer or LifecycleKit.UNBOUNDED, 64 by default
```

During combat lockdown the client refuses protected frame work (showing, moving or re-anchoring secure frames, changing secure attributes, key bindings) from addon code. The rule an addon follows is *persist intent always, apply only out of combat*; see the taint section of [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md). The combat gate is that rule as a service, so each addon does not track `PLAYER_REGEN_*` itself.

### One lockdown state

`IsInCombat()` reads one state shared by every addon. It is kept by one package-level pair of watchers on `PLAYER_REGEN_DISABLED` and `PLAYER_REGEN_ENABLED`, installed with the other shared watchers by the first `ForAddon`. The state is seeded from `InCombatLockdown()` when the package loads, when the watchers are installed, and again at `PLAYER_LOGIN`, because the host may load an addon mid-combat (a `/reload` in combat), and a combat that began before the watchers existed sends no `PLAYER_REGEN_DISABLED` to them. At `PLAYER_LOGIN` the state is re-read before any addon enters `ready`, so an `OnReady` callback (and every module `OnEnable` ModuleKit runs from it) already sees the host's answer in `IsInCombat()` and in `WhenOutOfCombat`; the `OnCombatStart` or `OnCombatEnd` notices and queued calls that re-reading implies run before the `OnReady` callbacks. Before the first `ForAddon`, and after logout, nothing watches the events and `IsInCombat()` asks `InCombatLockdown()` directly. A host without `InCombatLockdown` is treated as never in combat.

The state flips to `true` on `PLAYER_REGEN_DISABLED`. The host sends that event just before lockdown begins, so inside it `InCombatLockdown()` still answers `false` while `IsInCombat()` already answers `true`: from that moment on protected work belongs in the queue.

### `WhenOutOfCombat(callback)`

Out of combat, `callback(instance, true)` runs at once, before `WhenOutOfCombat` returns, and an error it raises leaves `WhenOutOfCombat` unchanged. The returned handle is already spent.

In combat, the callback is queued and `WhenOutOfCombat` returns a pending `DeferredCall`. Queued callbacks run on the next `PLAYER_REGEN_ENABLED`, first in, first out, as `callback(instance, true)`. A `WhenOutOfCombat` call made from inside one of those callbacks finds the player out of combat, so it runs at once, ahead of the calls still queued behind the running one. They run for every addon that is not halted or shut down, including one still `loading`: the caller asked for the call explicitly.

When the queue is closed, which happens at shutdown and at halt, each pending callback is called once with `(instance, false, "shutdown")` or `(instance, false, "halted")` instead, so work that needed the out-of-combat window learns it will not get one. After that, `WhenOutOfCombat` refuses with `nil, "shutdown"` or `nil, "halted"` and does not call the callback.

Every queued callback runs protected. When several fail, every other queued callback, in this addon and in every other addon, still runs, and the first error is re-raised afterwards with its original Lua error object: the same first-error policy as the phase callbacks. Raised inside the host event, it is reported through EventKit's listener isolation.

The client never delivers `PLAYER_REGEN_DISABLED` synchronously inside another event handler, so a drain is never interrupted by a new combat. As a defensive guard, should a host ever do so, the drain stops and the remaining calls stay queued for the next combat end rather than running protected work in combat.

**Bounded.** An addon may have at most `GetCombatQueueLimit()` calls waiting: the package's `defaultCombatQueueLimit` (64 unless changed with `LifecycleKit:SetLimits`) when the instance was created, or what `SetCombatQueueLimit(limit)` set (a positive integer or `LifecycleKit.UNBOUNDED`). With `UNBOUNDED` nothing is refused as `"full"`; the queue holds only this addon's own callbacks, and cancelled slots are still reclaimed as it grows. Beyond it `WhenOutOfCombat` returns `nil, "full"` and drops nothing already queued. Lowering the limit below the number already waiting drops nothing either; new calls are refused until the queue is below it. The queue array is reused across combats.

### `DeferredCall`

```lua
call:Cancel()     -- boolean
call:IsPending()  -- boolean
```

`Cancel()` returns `true` only for the call that cancelled a pending call; the callback then never runs and its place in the queue is freed. Cancelling only flags the slot, so it allocates nothing and moves nothing; the slot is reclaimed the next time the queue needs room. `IsPending()` is `true` while the callback waits for the end of combat.

### Combat notices

`OnCombatStart` and `OnCombatEnd` are repeating subscriptions, delivered after the shared state flipped: inside them `IsInCombat()` already answers `true` and `false` respectively. Addons are served in creation order for lifecycle instances created by this revision, and in name order for instances inherited from an older revision in an in-place upgrade (they come before any created afterwards). On combat end, an addon's queued calls run before its `OnCombatEnd` subscribers. A redundant host event, one that does not change the state, is not announced.

Notices are delivered only to addons that have reached `loaded` and are not halted or shut down. Loading is synchronous: an addon's files run, and the frames they create exist, before its `ADDON_LOADED`, with no host event in between, so no `PLAYER_REGEN_*` event can fall between file execution and `ADDON_LOADED`. The rule therefore takes nothing from a loading addon; it keeps notices away from lifecycle instances created for addons that have not loaded (yet). A subscription made while `loading` stays connected and starts receiving once the addon has loaded.

A load-on-demand addon loaded mid-combat reaches `loaded` after the combat began, so it receives `OnCombatEnd` without a matching `OnCombatStart`. Read `IsInCombat()` in `OnLoaded` to learn the state it starts in.

Failing notice subscribers are isolated and reported with the same first-error policy as the queued calls.

A combat transition allocates nothing once the subscriptions exist, and nothing for an addon without them; only queuing a call allocates its handle. An instance creates the subscriber list of `OnDependencyHalted`, `OnCombatStart` or `OnCombatEnd` when that notice gets its first subscriber, and its combat queue with its first queued call, so an addon that never uses one pays nothing for it.

## Subscription

```lua
subscription:Disconnect()   -- boolean
subscription:IsConnected()  -- boolean
```

`Disconnect()` is idempotent and returns `true` only when it changed a pending subscription to disconnected.

Phase subscriptions (`OnLoaded`, `OnReady`, `OnShutdown`, `OnHalted`) are one-shot: they disconnect themselves when delivered. Notice subscriptions (`OnCombatStart`, `OnCombatEnd`, `OnDependencyHalted`) repeat until they are disconnected or the addon halts or shuts down; a notice subscription made after that is returned already disconnected.

## Secret values

On a client with secret values, comparing a secret with a value of its own
type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike), and so does using it
as a table key; a comparison with `nil` or with a value of another type happens
not to raise (measured on Retail 12.1.0 b69933, see
[`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)).
LifecycleKit still tests every value it did not create for absence with
`type(value) == "nil"`, the repository rule, which never compares anything, and
refuses a secret at the caller before it would compare one (revision 14 and
later). The probe, `issecretvalue`, is read once when the file loads, since
every client defines it before any addon runs; only when it was absent at load
does each check read the global again, accepting it only as a function, so a
probe installed later is still honoured (revision 18; from revision 19 the
shared `isSecret` block, `tooling/shared/lua/isSecret.lua`):

| Call | Message |
|---|---|
| `LifecycleKit:ForAddon` | `LifecycleKit:ForAddon addonName must not be a secret value` |
| `Halt` | `LifecycleKit.Instance:Halt reason must not be a secret value` |
| `DependsOn` | `LifecycleKit.Instance:DependsOn addonName must not be a secret value` |
| `SetCombatQueueLimit` | `LifecycleKit.Instance:SetCombatQueueLimit limit must not be a secret value` |
| `LifecycleKit:SetLimits` | `LifecycleKit:SetLimits limits.<name> must not be a secret value` |

`SetLimits` and `GetLimits` called with a dot and a secret first argument are
refused as calls without the facade, by its type, before any comparison.

`HasPart` refuses a secret name with its argument error.

## Limits

LifecycleKit keeps two lists per addon, and both are bounded by default and opened on purpose (design constitution, principle 4a):

| Limit | Default | Guards | `UNBOUNDED` |
|---|---|---|---|
| `maxDependencies` | 16 | the addons one addon may declare with `DependsOn` | accepted: the list is the declaring addon's own |
| `defaultCombatQueueLimit` | 64 | the combat-queue limit a new instance starts with | accepted: the queue holds only that addon's own callbacks |

```lua
LifecycleKit:SetLimits({ maxDependencies = 32 })
LifecycleKit:SetLimits({ defaultCombatQueueLimit = LifecycleKit.UNBOUNDED })
local limits = LifecycleKit:GetLimits() -- { maxDependencies = 32, defaultCombatQueueLimit = UNBOUNDED }
instance:SetCombatQueueLimit(LifecycleKit.UNBOUNDED) -- one addon only
```

- `LifecycleKit:SetLimits(limits)` changes any subset of the two, each an integer from 1 to 2147483647 or `LifecycleKit.UNBOUNDED`. The limits are package-wide: they apply to every addon in the session. The whole table is validated before anything is applied, so a refused call changes nothing. It must be called on the facade.
- `LifecycleKit:GetLimits()` returns a fresh table with both values (one allocation per call).
- `LifecycleKit.UNBOUNDED` is one sentinel table, the same across embedded copies and upgrades; compare against it, never copy it.
- Lowering `maxDependencies` forgets no dependency already declared; further `DependsOn` calls answer `nil, "full"` until the list is below it.
- `defaultCombatQueueLimit` is the limit instances created from then on start with. Instances that already exist keep theirs; `instance:SetCombatQueueLimit(limit)` changes one addon's.
- ModuleKit reads `maxDependencies` through `GetLimits` when it validates its own `maxRequiredAddons` in `ModuleKit:SetLimits`, and refuses a value above it. Lower `maxDependencies` after that and ModuleKit's limit is not revisited, so set LifecycleKit's limits first.

Both limits stay in the core's table whether or not their part is loaded (`maxDependencies` is applied by the Halt part, `defaultCombatQueueLimit` by the CombatGate part), so `SetLimits` and `GetLimits` have one shape in every embedding. The ceiling of 2147483647 only refuses a mistaken number: both lists belong to one addon and accept `UNBOUNDED`.

## Error behaviour


Every public method validates its arguments and raises at the caller's own file and line. Each message starts with the qualified method name, `LifecycleKit:<Method>` for a facade method and `LifecycleKit.Instance:<Method>` for an instance method, followed by the text below: for example `LifecycleKit.Instance:OnReady callback must be a function`.

| Call | Message |
|---|---|
| `LifecycleKit:ForAddon` | `addonName must be a non-empty string` |
| `OnLoaded`, `OnReady`, `OnShutdown`, `OnHalted`, `OnDependencyHalted`, `OnCombatStart`, `OnCombatEnd`, `WhenOutOfCombat` | `callback must be a function` |
| `Halt` | `reason must be a non-empty string` |
| `DependsOn` | `addonName must be a non-empty string`, `addonName must name another addon` |
| `SetCombatQueueLimit` | `limit must be a positive integer or LifecycleKit.UNBOUNDED` |
| `LifecycleKit:HasPart` | `name must be a part name string` |
| `LifecycleKit:SetLimits` | `limits must be a table`, `limits.<name> is not a recognised limit; it accepts maxDependencies, defaultCombatQueueLimit` (a key that is not a string, number or boolean is named by its type, `limits.<table>`, so its `__tostring` never runs), `limits.<name> must be an integer from 1 to 2147483647`, `must be called on the LifecycleKit facade` |
| `LifecycleKit:GetLimits` | `must be called on the LifecycleKit facade` |

A member of a part that is not loaded raises at the caller's line, naming the file to embed (see [Parts](#parts)).

Writing to `LifecycleKit.CLOSES_ADDON_SCOPES` raises `LifecycleKit.CLOSES_ADDON_SCOPES is read-only; field "<key>" cannot be written`. A string key is shown as written and a number or boolean as `tostring` gives it; any other key is named by its type (`field "<table>"`), and a secret key by `<secret>`, so neither a key's `__tostring` nor a secret conversion runs inside LifecycleKit.

Loading `LifecycleKit.lua` raises `MoltenCodes LifecycleKit requires Registry API 2 to be loaded first`, `MoltenCodes LifecycleKit requires a valid Registry API 2 facade`, the same two for EventKit API 1 (`MoltenCodes LifecycleKit requires EventKit API 1 to be loaded first`, `... requires a valid EventKit API 1 facade`), or `MoltenCodes LifecycleKit package state is corrupted or incomplete`.

## Performance

Resident memory on host Lua 5.1.5 with debug information kept (`tooling/bench` host, one process per set, after a full collection), revision 18 against revision 19:

| File | Revision 18 | Revision 19 |
|---|---:|---:|
| `LifecycleKit.lua` | 72.4 KB | 51.3 KB |
| `parts/LifecycleKit-CombatGate.lua`, when embedded | (in the core) | 12.5 KB |
| `parts/LifecycleKit-Halt.lua`, when embedded | (in the core) | 5.3 KB |
| Allocated while loading the core | 231.8 KB | 179.7 KB |
| Per instance (`ForAddon`, no subscriptions) | 3,289 B | 329 B |

An instance holds its name and its four phase flags; a subscriber list is created by the first subscription to each phase or notice, the combat queue by the first queued call, the dependency list by the first `DependsOn`. With the CombatGate part each instance also records the combat-queue limit it was created with. A phase delivery runs each subscriber under `pcall` in one loop, with no call into another Kit. A combat transition allocates nothing once the subscriptions exist, and nothing for an addon without them.

## Embedded copies and upgrades

Compatible embedded copies share one LifecycleKit facade and state through Registry. Bootstrap is idempotent for the current implementation revision: if a prior live upgrade accepted the Registry revision but host event registration failed before shared watchers were fully established, a later compatible copy retries the missing watcher setup instead of silently returning an incomplete runtime state. If a one-shot global phase passed while that watcher was absent, bootstrap also reconciles existing instances from the observable host/package state, re-reading the combat state (CombatGate part) before any addon enters `ready`.

**The upgrade floor.** Revision 19 takes over only revision 18's state (schema 3), which it brings to schema 4: the part interface (`parts`, `helpers`, `dispatch`) and the delivery depth are added, every instance keeps its fields, and revision 18's host watchers are replaced, because a watcher keeps calling the handler of the revision that installed it. No revision before 19 was ever published, so the migrations from older state (schema 2, the per-revision fills of revisions 7 to 15) are gone: such state is refused as `package state is corrupted or incomplete`. Revision 18's subscriptions live in SignalKit signals on its instances (`_signals`); revision 19 keeps firing those signals, with the capture records their listeners write into, before its own lists, and answers `Disconnect`/`IsConnected` of their handles. Instances revision 19 creates never use SignalKit. Revision 18's combat queues, dependency lists and halts are read by the parts unchanged. When the CombatGate part is not embedded, revision 18's queued calls run on the next frame if the player is out of combat and are closed with `"shutdown"` or `"halted"` otherwise, and the missing file is reported once through `geterrorhandler()`.
