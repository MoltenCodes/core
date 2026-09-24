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

Pools also serve objects the host can never free, such as Frames:

- **`maxCreated`** caps how many objects the factory ever builds, and **`maxActive`** caps how many are out at once. At capacity `Acquire()` returns `nil, "exhausted"`; `Acquire(onAvailable)` queues the request in a bounded ring of `maxWaiting` slots and returns `nil, "waiting"`, or refuses with `nil, "queueFull"` when the ring is full. The queue never grows and allocates nothing per acquire.
- **`AttachChild`** makes children follow their parent: releasing a Frame releases its Textures first.
- **`ReleaseAfter(object, animationGroup)`** parks an object until its fade-out finishes.
- **Generations**: `SetGeneration(n)` retires objects built by a superseded factory after an in-place upgrade instead of handing them out again.

For plain tables, `PoolKit:NewTablePool()` provides a zero-configuration pool whose reset step shallow-clears every key.

## Documentation

- [`docs/API.md`](docs/API.md): the complete contract, including a method reference with returns, exact errors and cost.
- [`docs/INTERNALS.md`](docs/INTERNALS.md): ownership and allocation invariants, for maintainers.
- [`tests/README.md`](tests/README.md): what each spec file covers.
- [`src/PoolKit.lua`](src/PoolKit.lua): the whole implementation, one file, with a table of contents at the top.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.
