# LifecycleKit API

LifecycleKit API generation **1** provides per-addon lifecycle coordination over MoltenCodes EventKit and SignalKit: four lifecycle phases, a halted state an addon can declare, and a combat gate shared by every addon.

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

Callbacks receive the lifecycle instance as their only argument.

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

After those two, LifecycleKit closes that addon's canonical EventKit scope (`EventKit:ForAddon(addonName)`) after the shutdown callbacks have run, so event connections made through the scope need no teardown code in the addon. EventKit cannot do this itself: it loads before LifecycleKit and never observes shutdown. With an EventKit revision that has no `CloseAddonScopes`, nothing is closed and shutdown is otherwise unchanged. Closing the scope never takes the logout away from the scope's own listeners: LifecycleKit's watcher runs inside EventKit's `PLAYER_LOGOUT` dispatch, and EventKit defers the disconnects until that dispatch returns, so a scoped `PLAYER_LOGOUT` listener still runs once. An addon that never asked for an EventKit scope has none to close; EventKit 0.5.1 (revision 8) answers `false` and records nothing, where earlier revisions recorded a closed scope.

The same two-step applies to the addon's HookKit scope, its CommandKit scope, its CommKit scope and its SignalKit bus. After the EventKit scope, LifecycleKit closes the addon's canonical HookKit scope (`HookKit:CloseAddonScopes(addonName)`), which undoes every hook made through `HookKit:ForAddon(addonName)`, then its canonical CommandKit scope (`CommandKit:CloseAddonScopes(addonName)`), which leaves every slash command registered through `CommandKit:ForAddon(addonName)` inert, then its canonical CommKit scope (`CommKit:CloseAddonScopes(addonName)`), which cancels its pending sends, closes its SyncSets and disconnects its prefix registrations, and then its bus (`SignalKit:CloseAddonBus(addonName)`), which disconnects every subscription on the bus named after the addon, including those made through its scopes. HookKit, CommandKit and CommKit are optional: each is found through `Registry:Find` (`"hookKit"`, `"commandKit"`, `"commKit"`, API 1) at shutdown, and without it, or with a revision that has no `CloseAddonScopes`, that step does nothing; `false` from `CloseAddonScopes` (no scope, or already closed) is not a failure. CommKit depends on LifecycleKit and already closes the scope of `CommKit:ForAddon` from its own `OnShutdown` subscription, which runs among the shutdown callbacks; the CommKit step pins it to its place in this order whatever CommKit revision is loaded, and usually answers `false`. A SignalKit revision without `CloseAddonBus` skips the last step the same way, and an addon that never asked for a bus has nothing to close (`CloseAddonBus` answers `false`, which is not a failure).

The seven are closed in this order for a reason:

1. **TimerKit scope first** and
2. **SchedulerKit scope second**, so no timer fires and no job runs into event listeners, hooks or bus subscribers that are being torn down.
3. **EventKit scope next**, so no host event fires into hooks or bus subscribers that are being torn down.
4. **HookKit scope next**, so the addon's hooks stop running.
5. **CommandKit scope next**, so the addon's slash commands become inert.
6. **CommKit scope next**, so the addon's addon messages stop being sent and received.
7. **SignalKit bus last**, because other addons' shutdown paths may still publish on it. Publishing on a closed bus delivers nothing and does not raise, so closing it last only keeps it useful for as long as possible.

Shutdown callbacks run before any of the seven is closed, so an `OnShutdown` callback can still rely on its timers, jobs, event connections, hooks, slash commands and addon-message scope and can still publish on its bus.

Shutdown therefore runs these steps per addon, in this order: the addon's combat queue is closed (each pending deferred call receives `(instance, false, "shutdown")`), the shutdown callbacks run, then the TimerKit scope, the SchedulerKit scope, the EventKit scope, the HookKit scope, the CommandKit scope, the CommKit scope and the SignalKit bus are closed. Every step runs even when an earlier one failed. Errors follow a first-error-wins policy in that order: a deferred-call error is re-raised before a shutdown callback error, which is re-raised before a TimerKit, then a SchedulerKit, then an EventKit, then a HookKit, then a CommandKit, then a CommKit, then a SignalKit closing failure. Either way every addon's lifecycle has advanced first.

If shutdown occurs before `loaded` or `ready` was reached (for example, a lifecycle was created for a load-on-demand addon that never loaded), pending subscriptions for those now-impossible phases are disconnected without invocation. New subscriptions to an earlier phase that is already impossible because shutdown occurred are returned already disconnected. Shutdown also disconnects the addon's `OnHalted`, `OnDependencyHalted`, `OnCombatStart` and `OnCombatEnd` subscriptions.

## Halted state

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

### Dependencies between addons

`DependsOn(otherAddonName)` records that this addon cannot work without another one. The name is matched exactly, like `ForAddon`, and the other addon does not need a lifecycle instance yet. The call returns `true` when it recorded the dependency and `false` when it was already recorded. An addon records at most `maxDependencies` dependencies, **16** unless changed with `LifecycleKit:SetLimits` (see [Limits](#limits)); the next one is refused with `nil, "full"`. A halted or shut-down addon refuses new dependencies with `nil, "halted"` or `nil, "shutdown"`. Declaring the addon itself raises an argument error.

If the dependency has already halted, `DependsOn` delivers `OnDependencyHalted` at once. `OnDependencyHalted` is a repeating subscription, and it replays every recorded dependency that has already halted when it is made, so the order of `DependsOn` and `OnDependencyHalted` does not matter: each subscriber hears of each halted dependency exactly once. A failing replay is re-raised from `OnDependencyHalted` after the other replays, and, as with a failing dispatch, the subscription stays connected. A replay that ends the subscription, typically by halting the dependent in response, stops the replay: a halted addon hears of no further dependency.

A dependent may itself `Halt` from inside `OnDependencyHalted`; its own dependents are then told in turn. Dependents that are already halted or shut down are not told.

## Combat gate

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

`IsInCombat()` reads one state shared by every addon. It is kept by one package-level pair of watchers on `PLAYER_REGEN_DISABLED` and `PLAYER_REGEN_ENABLED`, installed with the other shared watchers by the first `ForAddon`. The state is seeded from `InCombatLockdown()` when the package loads, when the watchers are installed, and again at `PLAYER_LOGIN`, because the host may load an addon mid-combat (a `/reload` in combat), and a combat that began before the watchers existed sends no `PLAYER_REGEN_DISABLED` to them. Before the first `ForAddon`, and after logout, nothing watches the events and `IsInCombat()` asks `InCombatLockdown()` directly. A host without `InCombatLockdown` is treated as never in combat.

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

A combat transition allocates nothing once the subscriptions exist; only queuing a call allocates its handle.

## Subscription

```lua
subscription:Disconnect()   -- boolean
subscription:IsConnected()  -- boolean
```

`Disconnect()` is idempotent and returns `true` only when it changed a pending subscription to disconnected.

Phase subscriptions (`OnLoaded`, `OnReady`, `OnShutdown`, `OnHalted`) are one-shot: they disconnect themselves when delivered. Notice subscriptions (`OnCombatStart`, `OnCombatEnd`, `OnDependencyHalted`) repeat until they are disconnected or the addon halts or shuts down; a notice subscription made after that is returned already disconnected.

## Argument errors

Every public method validates its arguments and raises at the caller's own file and line:

| Call | Message |
|---|---|
| `LifecycleKit:ForAddon` | `addonName must be a non-empty string` |
| `OnLoaded`, `OnReady`, `OnShutdown`, `OnHalted`, `OnDependencyHalted`, `OnCombatStart`, `OnCombatEnd`, `WhenOutOfCombat` | `callback must be a function` |
| `Halt` | `reason must be a non-empty string` |
| `DependsOn` | `addonName must be a non-empty string`, `addonName must name another addon` |
| `SetCombatQueueLimit` | `limit must be a positive integer or LifecycleKit.UNBOUNDED` |
| `LifecycleKit:SetLimits` | `limits must be a table`, `limits.<name> is not a recognised limit`, `limits.<name> must be a positive integer or LifecycleKit.UNBOUNDED`, `must be called on the LifecycleKit facade` |
| `LifecycleKit:GetLimits` | `must be called on the LifecycleKit facade` |

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

- `LifecycleKit:SetLimits(limits)` changes any subset of the two. The limits are package-wide: they apply to every addon in the session. The whole table is validated before anything is applied, so a refused call changes nothing. It must be called on the facade.
- `LifecycleKit:GetLimits()` returns a fresh table with both values (one allocation per call).
- `LifecycleKit.UNBOUNDED` is one sentinel table, the same across embedded copies and upgrades; compare against it, never copy it.
- Lowering `maxDependencies` forgets no dependency already declared; further `DependsOn` calls answer `nil, "full"` until the list is below it.
- `defaultCombatQueueLimit` is the limit instances created from then on start with. Instances that already exist keep theirs; `instance:SetCombatQueueLimit(limit)` changes one addon's.
- ModuleKit reads `maxDependencies` through `GetLimits` when it validates its own `maxRequiredAddons` in `ModuleKit:SetLimits`, and refuses a value above it. Lower `maxDependencies` after that and ModuleKit's limit is not revisited, so set LifecycleKit's limits first.

State written by revisions before 12 has neither field; an upgrade seeds the defaults those revisions enforced as constants, so behaviour carries over unchanged until a consumer calls `SetLimits`.

## Dependencies

LifecycleKit API 1 requires:

- Registry API 2
- SignalKit API 1
- EventKit API 1

It optionally uses TimerKit API 1, SchedulerKit API 1, HookKit API 1, CommandKit API 1 and CommKit API 1, each found through `Registry:Find` (Registry revision 7; an older Registry's `Get` is the equivalent fallback) when an addon shuts down. Without them nothing changes except that there are no timers to cancel, no jobs to cancel, no hooks to undo, no commands to make inert and no addon-message scopes to close. TimerKit and SchedulerKit do not depend on LifecycleKit: LifecycleKit calls into them, which is what lets each embed without it.

LifecycleKit does not create WoW Frames directly. All frame/event registration remains inside EventKit.

Host API read directly: `C_AddOns.IsAddOnLoaded` (falling back to the legacy `IsAddOnLoaded`), `IsLoggedIn`, and `InCombatLockdown`. Every one is optional; without it LifecycleKit assumes not loaded, not logged in, and not in combat respectively. Host events observed through EventKit: `ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_LOGOUT`, `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`.

## Embedded bootstrap recovery

Compatible embedded copies share one LifecycleKit facade and state through Registry. Pending phase subscriptions created by the previous compatible implementation revision remain valid across an in-place upgrade; the upgrade releases per-instance state that the newer revision no longer owns.

Revisions 8 to 12 keep schema 3. Upgrading from revision 7, 8, 9, 10 or 11 replaces its shared host watchers, which would otherwise keep calling the older revision's handlers: revision 7's logout handler closes no HookKit scope and no bus, revision 8's no CommandKit scope, revision 9's no CommKit scope, and no revision before 12 closes a TimerKit or SchedulerKit scope.

Revision 7 changed the package state from schema 2 to schema 3. Upgrading from an older revision adds the shared combat flag (seeded from `InCombatLockdown()`), the instance list (inherited instances in name order) and every instance's combat queue, dependency list and halted flag, and replaces the older revision's shared host watchers with its own, because a watcher keeps calling the handler of the revision that installed it. Pending deferred calls and notice subscriptions are carried across a same-revision reload unchanged. Bootstrap is idempotent for the current implementation revision: if a prior live upgrade accepted the Registry revision but host event registration failed before shared watchers were fully established, a later compatible copy retries the missing watcher setup instead of silently returning an incomplete runtime state. If a one-shot global phase passed while that watcher was absent, bootstrap also reconciles existing instances from the observable host/package state.
