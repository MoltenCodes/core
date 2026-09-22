# SchedulerKit

SchedulerKit provides cooperative, frame-budgeted work scheduling for World of Warcraft addons.

It is designed for workloads that should make progress without monopolizing a rendered frame: cache rebuilds, incremental indexing, bulk data normalization, deferred UI work, and other jobs that can cooperate with an execution budget.

SchedulerKit is **not** a preemptive thread scheduler. A Lua callback must either finish or explicitly cooperate through `context:Yield()` / `context:ShouldYield()` before SchedulerKit can give time back to the frame.

## Highlights

- deterministic FIFO ordering within each priority;
- weighted fair scheduling across the `HIGH`, `NORMAL`, and `LOW` priorities, with `IDLE` reserved for work that runs only when nothing else is ready;
- frame-budget observation in addon CPU time (`debugprofilestop`), so a client hitch is not charged to a cooperating job;
- explicit `NextFrame` deferral when same-pass nested execution is not acceptable;
- coroutine-backed resumable jobs;
- explicit cancellation handles;
- delayed and fixed-delay repeating jobs through TimerKit;
- manual and addon-owned cancellation scopes;
- automatic LifecycleKit shutdown cleanup;
- callback-error isolation, captured tracebacks, and per-job diagnostics;
- stale delayed-callback protection;
- compatible embedded-copy identity through Registry.

## Example

```lua
local work = SchedulerKit:ForAddon("MyAddon")

work:Schedule(function(context)
    for index = 1, #items do
        rebuild(items[index])

        if context:ShouldYield() then
            context:Yield()
        end
    end
end, {
    priority = SchedulerKit.Priority.NORMAL,
    name = "rebuild item cache",
})
```

For the complete public contract, see [`docs/API.md`](docs/API.md). Maintainers can also read [`docs/INTERNALS.md`](docs/INTERNALS.md) for queue, driver, shared-state, and allocation invariants.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\schedulerKit\SchedulerKit.lua
```

Direct runtime dependencies: LifecycleKit API 1, Registry API 2, TimerKit API 1.
Every file above is required; omitting one makes this package raise at
load.
