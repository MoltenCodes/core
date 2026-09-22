# LifecycleKit API

LifecycleKit API generation **1** provides per-addon lifecycle coordination over MoltenCodes EventKit and SignalKit.

## State model

A lifecycle instance reports one of four states:

```text
loading → loaded → ready → shutdown
```

`loaded` is reached when `ADDON_LOADED` is observed for the configured addon. `ready` is reached after the addon is loaded and the player is logged in. `shutdown` is reached when `PLAYER_LOGOUT` is observed.

A load-on-demand addon may be created after `PLAYER_LOGIN`. LifecycleKit probes `IsLoggedIn()` and, when available, `C_AddOns.IsAddOnLoaded()` so it can catch up without waiting for events that will not repeat. The legacy `IsAddOnLoaded` fallback is used only when its second return value explicitly confirms that `ADDON_LOADED` has finished; a single truthy "loading" value is intentionally not treated as loaded.

## `LifecycleKit:ForAddon(addonName)`

Returns the stable lifecycle instance for `addonName`. Repeated calls with the same name return the same object.

`addonName` must be a non-empty string and should be the actual addon name supplied by WoW's addon loading system.

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

Late-subscriber callbacks invoked synchronously after a phase has already occurred propagate their own errors directly.

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

Compatible embedded copies share one LifecycleKit facade and state through Registry. Pending phase subscriptions created by the previous compatible implementation revision remain valid across an in-place upgrade. Bootstrap is idempotent for the current implementation revision: if a prior live upgrade accepted the Registry revision but host event registration failed before shared watchers were fully established, a later compatible copy retries the missing watcher setup instead of silently returning an incomplete runtime state. If a one-shot global phase passed while that watcher was absent, bootstrap also reconciles existing instances from the observable host/package state.
