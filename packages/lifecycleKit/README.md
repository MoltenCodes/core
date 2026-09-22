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

`LifecycleKit:ForAddon(name)` is idempotent: every caller in the same runtime receives the same lifecycle instance for that addon name.

See [`docs/API.md`](docs/API.md) for the complete contract.
