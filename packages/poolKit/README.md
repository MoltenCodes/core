# PoolKit

PoolKit provides allocation-conscious reusable object pools for Lua tables and userdata. It is a pure-Lua runtime primitive with no WoW Frame, timer, lifecycle, or scheduler dependency.

```lua
local pool = PoolKit:New({
    create = function()
        return {}
    end,
    reset = function(object)
        wipe(object)
    end,
    maxRetained = 128,
})

local object = pool:Acquire()
object.value = 42
pool:Release(object)
```

Retention is bounded by default (`128` objects). Consumers that deliberately need an unbounded pool must opt in with `PoolKit.UNBOUNDED`. PoolKit rejects foreign releases, protects against duplicate/re-entrant release, preserves state when reset fails, and performs best-effort destruction during bulk cleanup.

For plain tables, `PoolKit:NewTablePool()` provides a zero-configuration pool whose reset step shallow-clears every key.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for ownership/allocation invariants.
