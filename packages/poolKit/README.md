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

Two contracts are worth knowing before the first `Acquire`:

- **`Acquire` does not clean.** Cleaning happens in `reset`, at release time. A pool with no `reset` hands objects back exactly as the previous borrower left them. Pass `strictReset = true` to refuse to build such a pool by accident.
- **Borrowed objects are caller-owned and unbounded.** `maxRetained` bounds what the pool keeps, not what callers hold. Use `GetActiveCount()`, and `maxActiveWarning` to be told once when too many objects are out at the same time.

For plain tables, `PoolKit:NewTablePool()` provides a zero-configuration pool whose reset step shallow-clears every key.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for ownership/allocation invariants.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
```

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.
