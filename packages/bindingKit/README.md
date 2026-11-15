# BindingKit

BindingKit lets an addon set key bindings at run time without touching the player's own. It uses override bindings, which the client drops at logout and never saves, and keeps them in named scopes, so an addon clears only what it set. A key can run a binding command, click a named button, or call a Lua function.

```lua
local BindingKit = MoltenCodes.Registries[2]:Get("bindingKit", 1)

local keys = BindingKit:CreateScope("MyAddon")
keys:BindCommand("CTRL-M", "TOGGLEWORLDMAP")
keys:BindClick("CTRL-SHIFT-B", "MyAddonToggleButton")
keys:BindFunction("CTRL-SHIFT-T", function()
  MyAddon:ToggleWindow()
end)

-- Later: give every key back.
keys:ClearAll()
```

What each piece promises:

- **The player's bindings stay theirs.** Nothing is saved; `SetBinding` and `SaveBindings` are never called. Each scope has its own owner frame, so clearing one scope leaves every other addon's bindings alone.
- **Combat is handled.** The client refuses binding changes from addon code in combat. A change made then is kept, `scope:IsPending()` says so, and it is applied when combat ends.
- **Lua functions on keys.** `BindFunction` binds the key to a hidden named button of BindingKit's own that calls your function with the key, protected; a function that raises is reported through the error handler. The function runs as insecure addon code: it cannot cast, target or use items.
- **Bounded.** 32 scopes and 64 function keys by default, up to 256 and 512 with `BindingKit:SetLimits`; each is a frame the session keeps, so neither opens to unbounded.

Non-goals: the player's saved bindings, the Key Bindings panel, secure action buttons.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\bindingKit\BindingKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `bindingKit/BindingKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

BindingKit reads the client's binding functions when a scope is made, never
at load.
