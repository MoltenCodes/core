# LifecycleKit API

LifecycleKit API generation **1** provides per-addon lifecycle coordination over MoltenCodes EventKit and SignalKit.

## State model

A lifecycle instance reports one of four states:

```text
loading → loaded → ready → shutdown
```

`loaded` is reached when `ADDON_LOADED` is observed for the configured addon. `ready` is reached after the addon is loaded and the player is logged in. `shutdown` is reached when `PLAYER_LOGOUT` is observed.

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
```

`GetState()` returns `"loading"`, `"loaded"`, `"ready"`, or `"shutdown"`.

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

If shutdown occurs before `loaded` or `ready` was reached (for example, a lifecycle was created for a load-on-demand addon that never loaded), pending subscriptions for those now-impossible phases are disconnected without invocation. New subscriptions to an earlier phase that is already impossible because shutdown occurred are returned already disconnected.

## Subscription

```lua
subscription:Disconnect()   -- boolean
subscription:IsConnected()  -- boolean
```

`Disconnect()` is idempotent and returns `true` only when it changed a pending subscription to disconnected.

## Dependencies

LifecycleKit API 1 requires:

- Registry API 2
- SignalKit API 1
- EventKit API 1

LifecycleKit does not create WoW Frames directly. All frame/event registration remains inside EventKit.

## Embedded bootstrap recovery

Compatible embedded copies share one LifecycleKit facade and state through Registry. Pending phase subscriptions created by the previous compatible implementation revision remain valid across an in-place upgrade; the upgrade releases per-instance state that the newer revision no longer owns. Bootstrap is idempotent for the current implementation revision: if a prior live upgrade accepted the Registry revision but host event registration failed before shared watchers were fully established, a later compatible copy retries the missing watcher setup instead of silently returning an incomplete runtime state. If a one-shot global phase passed while that watcher was absent, bootstrap also reconciles existing instances from the observable host/package state.
