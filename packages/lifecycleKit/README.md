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

The name is matched exactly against the folder name WoW reports in `ADDON_LOADED`, so pass the addon's own name — inside an addon file, `local addonName = ...`.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
```

Direct runtime dependencies: EventKit API 1, Registry API 2, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load.
