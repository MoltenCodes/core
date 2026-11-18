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

Pools also serve objects the host can never free, such as Frames. `maxCreated`
is in the core; the other mechanisms are optional parts (revision 12 and
later), so an addon loads only what it uses:

- **`maxCreated`** caps how many objects the factory ever builds. At capacity `Acquire()` returns `nil, "exhausted"`.
- **`Waiting` part**: **`maxActive`** caps how many are out at once, and `Acquire(onAvailable)` queues the request in a bounded ring of `maxWaiting` slots and returns `nil, "waiting"`, or refuses with `nil, "queueFull"` when the ring is full. The queue never grows and allocates nothing per acquire. Without the part a pool has no queue, so `Acquire(onAvailable)` at capacity answers `nil, "queueFull"`.
- **`Children` part**: **`AttachChild`** makes children follow their parent: releasing a Frame releases its Textures first.
- **`Deferred` part**: **`ReleaseAfter(object, animationGroup)`** parks an object until its fade-out finishes.
- **`Generations` part**: `SetGeneration(n)` retires objects built by a superseded factory after an in-place upgrade instead of handing them out again.

A method or option whose part is not loaded raises at the caller's line,
naming the file to add; `PoolKit:HasPart(name)` answers whether a part is
loaded. The core keeps 62.2 KB resident with debug information kept
(revision 11, one file: 82.4 KB), measured as `docs/API.md` *Performance*
describes.

For plain tables, `PoolKit:NewTablePool()` provides a zero-configuration pool whose reset step shallow-clears every key.

## Documentation

- [`docs/API.md`](docs/API.md): the complete contract, including a method reference with returns, exact errors and cost.
- [`docs/INTERNALS.md`](docs/INTERNALS.md): ownership and allocation invariants, for maintainers.
- [`tests/README.md`](tests/README.md): what each spec file covers.
- [`src/PoolKit.lua`](src/PoolKit.lua): the core, with a table of contents at the top; [`src/parts/`](src/parts/) holds the four parts.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\poolKit\parts\PoolKit-Waiting.lua       # only for maxActive, maxWaiting, CancelWaiting
Libs\MoltenCodes\poolKit\parts\PoolKit-Children.lua      # only for AttachChild, DetachChild
Libs\MoltenCodes\poolKit\parts\PoolKit-Deferred.lua      # only for ReleaseAfter
Libs\MoltenCodes\poolKit\parts\PoolKit-Generations.lua   # only for generation, SetGeneration
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `poolKit/PoolKit.lua`.
A part loads after the core; the generated `embeds.xml`
(`python3 -m tooling.package.embeds`) adds one when a manifest names it.

Direct runtime dependencies: Registry API 2.
Registry and the core are required; omitting one makes this package raise at
load.
