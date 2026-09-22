# SchedulerKit API

SchedulerKit API generation **1** provides cooperative, frame-budgeted scheduling for World of Warcraft addons.

The package intentionally separates **when work becomes eligible** from **how much work should execute in a rendered frame**:

- TimerKit owns time delays.
- SchedulerKit owns priority, cooperative execution, frame budgeting, and cancellation.

## Public surface

### Package facade

| Method | Purpose |
|---|---|
| `Schedule(callback[, options])` | Queue a job for scheduler execution. Nested scheduling may run in the current scheduler pass. |
| `NextFrame(callback[, options])` | Defer eligibility through a zero-delay TimerKit timer so the job cannot run in the current rendered frame. |
| `After(delay, callback[, options])` | Make a one-shot job eligible after a TimerKit delay. |
| `Every(interval, callback[, options])` | Run a fixed-delay repeating job. |
| `CreateScope()` | Create a manually owned scheduling scope. |
| `ForAddon(addonName)` | Return the canonical LifecycleKit-owned scope for an addon. |
| `SetFrameBudget(milliseconds)` | Set the scheduler's per-frame cooperative time budget. |
| `GetFrameBudget()` | Return the current frame budget in milliseconds. |
| `SetRunawayThreshold(milliseconds)` | Set the maximum accepted duration of a yielded slice. |
| `GetRunawayThreshold()` | Return the current yielded-slice threshold. |
| `SetMaxResumesPerFrame(count)` | Set the hard resume-count safety ceiling per frame. |
| `GetMaxResumesPerFrame()` | Return the resume-count ceiling. |
| `GetActiveCount()` | Return the number of non-terminal jobs across all scopes. |

### Job handles

| Method | Purpose |
|---|---|
| `GetState()` | Return `delayed`, `pending`, `running`, `completed`, `cancelled`, or `failed`. |
| `GetPriority()` | Return the numeric priority constant. |
| `GetScope()` | Return the owning SchedulerKit scope. |
| `GetName()` | Return the optional diagnostic name. |
| `IsPending()` | Return whether the job is delayed, queued, or running. |
| `IsCancelled()` | Return whether the logical job was cancelled. |
| `HasError()` | Distinguish a failed job even when its Lua error object is `nil`. |
| `GetError()` | Return the original Lua error object for a failed job. |
| `Cancel()` | Logically cancel a non-terminal job. |

### Scopes

| Method | Purpose |
|---|---|
| `Schedule(callback[, options])` | Queue work owned by this scope. |
| `NextFrame(callback[, options])` | Defer scope-owned work until a subsequent rendered frame. |
| `After(delay, callback[, options])` | Schedule delayed one-shot work in this scope. |
| `Every(interval, callback[, options])` | Schedule fixed-delay repeating work in this scope. |
| `CancelAll()` | Best-effort cancel all active jobs while keeping the scope reusable. |
| `Close()` | Terminally close the scope after best-effort cancellation. |
| `IsClosed()` | Return whether the scope is terminally closed. |
| `GetAddonName()` | Return the owning addon name, or `nil` for a manual scope. |
| `GetActiveCount()` | Return the number of non-terminal jobs owned by the scope. |

### Execution context

| Method | Purpose |
|---|---|
| `ShouldYield()` | Return whether the current frame budget has been reached. |
| `Yield()` | Cooperatively suspend the current job and requeue it. |
| `GetJob()` | Return the current logical Job handle. |
| `IsCancelled()` | Return whether the running job was cancelled while executing. |

## Priorities

SchedulerKit exposes four immutable-by-convention numeric constants:

```lua
SchedulerKit.Priority.HIGH
SchedulerKit.Priority.NORMAL
SchedulerKit.Priority.LOW
SchedulerKit.Priority.IDLE
```

Jobs are FIFO within one priority lane.

Across lanes, SchedulerKit uses a persistent weighted round-robin sequence:

```text
HIGH, HIGH, HIGH, HIGH, NORMAL, NORMAL, LOW, IDLE
```

The cursor is preserved between rendered frames. HIGH work therefore receives greater service, but a continuously populated HIGH queue cannot permanently starve NORMAL, LOW, or IDLE queues.

Priority controls **service preference**, not correctness. A consumer must never rely on a lower-priority job being complete before a higher-priority job unless it models that dependency explicitly in its own state.

## Scheduling options

`Schedule`, `NextFrame`, `After`, and `Every` accept an optional table with exactly these fields:

```lua
{
    priority = SchedulerKit.Priority.NORMAL,
    name = "human-readable diagnostic name",
}
```

Unknown fields are rejected so option typos cannot silently alter behavior.

`name` is optional and is not required to be globally unique.

## Cooperative execution

A scheduled callback receives one Context:

```lua
SchedulerKit:Schedule(function(context)
    for index = 1, #records do
        process(records[index])

        if context:ShouldYield() then
            context:Yield()
        end
    end
end)
```

`Context:Yield()` suspends the callback's coroutine and places the same logical Job back at the tail of its priority lane.

Raw `coroutine.yield(...)` is deliberately unsupported. A coroutine that suspends without SchedulerKit's internal yield token is failed with a diagnostic error. This prevents ambiguous scheduling semantics.

### Important limitation: no preemption

Lua execution is cooperative. SchedulerKit cannot interrupt an arbitrary callback in the middle of a long-running Lua instruction sequence.

If a callback performs 50 ms of work without calling `ShouldYield()` / `Yield()`, the frame has already been blocked for those 50 ms. The scheduler can diagnose a long **yielded slice** after control returns, but it cannot retroactively recover that frame time.

Consumers are therefore responsible for placing cooperative yield points inside potentially large loops.

## Frame budget

The default budget is **2 ms** per scheduler-driven frame.

```lua
SchedulerKit:SetFrameBudget(1.5)
```

SchedulerKit reads WoW's monotonic precise-time clock and sets one deadline at the beginning of each OnUpdate scheduling pass.

`Context:ShouldYield()` compares the current profiling time with that deadline.

The scheduler always permits at least one resume when work is ready. This prevents a very small budget or driver overhead from causing permanent starvation.

Changing the budget during a currently running frame affects subsequent frames; the current pass retains the deadline it started with.

### Shared configuration

Frame budget, runaway threshold, and resume ceiling are package-wide settings because all embedded copies and addon scopes share one SchedulerKit driver. Changing them affects every SchedulerKit consumer in the current WoW session. Libraries should normally rely on defaults rather than competing to retune global scheduler policy.

## Resume-count safety ceiling

Time alone is not sufficient protection because extremely cheap callbacks may complete without the precise-time clock advancing measurably.

SchedulerKit therefore also caps the number of coroutine resumes per OnUpdate pass. The default is **1000**. The configured value must be a finite positive integer; `math.huge` is rejected because this setting is a hard safety ceiling.

```lua
SchedulerKit:SetMaxResumesPerFrame(250)
```

This limit is a safety valve for nested/zero-cost scheduling storms, not a throughput target.

## Runaway yielded-slice threshold

The default yielded-slice threshold is **8 ms**.

If a job eventually calls `Context:Yield()` but the resume consumed more than this threshold before yielding, the job is failed instead of being requeued repeatedly.

```lua
SchedulerKit:SetRunawayThreshold(6)
```

This is diagnostic containment, not preemption. A slice can only be measured after it yields back to SchedulerKit.

A callback that completes normally is not retroactively converted into a failure merely because its final slice was long.

## Immediate vs next-frame scheduling

`Schedule()` means **ready for scheduler execution**, not "force a new rendered frame". If a running job schedules another job and the current frame still has budget/resume capacity, the nested job may execute later in the same SchedulerKit OnUpdate pass.

Use `NextFrame()` when the current rendered frame must be excluded:

```lua
SchedulerKit:NextFrame(function(context)
    updateLayout()
end)
```

`NextFrame()` is implemented through TimerKit's zero-delay one-shot path, whose WoW timing boundary defers the wakeup until a subsequent frame before SchedulerKit queues the job.

## Delayed work

```lua
SchedulerKit:After(0.5, function(context)
    refresh()
end)
```

Delayed scheduling uses TimerKit. Before its delay expires, the job state is `delayed` and the scheduler's OnUpdate driver does not need to run solely for that job.

A one-shot delay may be zero, preserving TimerKit/WoW next-frame timer semantics. Negative, NaN, and infinite delays are rejected.

When the TimerKit delay fires, the job moves to `pending` and enters its priority queue.

## Repeating work

```lua
local poller = SchedulerKit:Every(5, function(context)
    refreshRemoteState()
end)
```

`Every` is **fixed-delay**, not fixed-rate:

```text
wait interval
→ run job to completion (possibly across multiple scheduler frames)
→ wait interval again
→ next iteration
```

Iterations never overlap. The interval starts again only after the previous coroutine finishes.

If a repeating callback fails, the logical job becomes `failed` and stops repeating.

If TimerKit cannot re-arm the next interval, that failure is captured on the job and does not escape the scheduler OnUpdate driver or starve unrelated work.

## Cancellation

Cancellation is logical first.

```lua
job:Cancel()
```

A cancelled queued job remains harmless even if its stale queue node has not yet been popped. A delayed job invalidates its logical generation before TimerKit cancellation is attempted, so an already-queued native timer callback cannot resurrect it.

Cancelling a running job does **not** forcibly abort Lua currently on the stack. `Context:IsCancelled()` lets a cooperative callback observe cancellation and return early. `Context:ShouldYield()` returns `true` for a self-cancelled running callback, and `Context:Yield()` remains legal so control can be surrendered immediately. Once control returns or yields, the cancelled job is not requeued.

`Cancel()` returns `false` for already terminal jobs.

If native TimerKit cancellation raises, the logical SchedulerKit job remains cancelled and the native error is re-raised to the direct caller.

## Error isolation

User callback errors are captured by `coroutine.resume` and do not escape the OnUpdate driver.

The failing job becomes `failed`, preserves the original Lua error object, and unrelated jobs continue running:

```lua
if job:HasError() then
    local value = job:GetError()
end
```

`HasError()` exists separately because valid Lua error objects include `nil` and `false`.

When WoW's `geterrorhandler()` is available, SchedulerKit also reports the original error object through the host error handler on a best-effort basis. Failure of the error handler itself cannot poison scheduler execution.

## Scopes

Manual scope:

```lua
local work = SchedulerKit:CreateScope()

work:Schedule(jobA)
work:After(2, jobB)
work:Every(10, jobC)

work:CancelAll() -- reusable
work:Close()     -- terminal
```

Scopes use intrusive active-job links rather than retaining an ever-growing history of completed jobs. Completed, cancelled, and failed jobs are removed in O(1) from scope ownership state.

`CancelAll()` attempts every active job in deterministic creation order. If one cancellation raises, cleanup continues and the first error object is re-raised after the pass.

## Addon-owned scopes

```lua
local work = SchedulerKit:ForAddon("MyAddon")
```

`ForAddon` is idempotent for one addon name and binds the scope to `LifecycleKit:ForAddon(addonName)`.

At shutdown, SchedulerKit closes the scope, cancels queued/running/delayed jobs, and closes its internal TimerKit delay scope.

If the lifecycle is already terminal when `ForAddon` is first called, SchedulerKit returns the canonical scope already closed.

## Package-level convenience scope

Package-level methods use a lazily created internal manual scope:

```lua
SchedulerKit:Schedule(callback)
SchedulerKit:After(1, callback)
SchedulerKit:Every(5, callback)
```

The package cannot infer addon ownership from an arbitrary caller. Addon code that needs deterministic shutdown cleanup should prefer `ForAddon(addonName)`.

No SchedulerKit convenience scope is allocated merely by loading the package. The SchedulerKit scope is created on the first package-level scheduling operation, while its internal TimerKit delay scope remains unallocated until the first `NextFrame()`, `After()`, or `Every()` operation. Immediate-only `Schedule()` use therefore does not allocate TimerKit ownership state. If the SchedulerKit scope is closed indirectly through `job:GetScope():Close()`, a later package-level scheduling operation creates a fresh scope.

## WoW driver boundary

SchedulerKit relies on only two direct WoW facilities:

```text
CreateFrame("Frame") + Frame:SetScript("OnUpdate", ...)
GetTimePreciseSec()
```

The OnUpdate script is installed only while at least one job is ready to execute and removed when ready queues become empty. Delayed-only jobs therefore do not keep an OnUpdate handler active.

WoW documents OnUpdate as firing on rendered UI frames and notes that it is resource-intensive when left active continuously. SchedulerKit's driver is intentionally lazy for that reason.

`GetTimePreciseSec()` is used as the monotonic time source. It is not cached once per rendered frame, so SchedulerKit can observe budget consumption inside one OnUpdate pass without resetting or sharing a global profiling epoch.

## Protected actions and hardware events

SchedulerKit changes **when** Lua runs; it does not manufacture or preserve a WoW hardware-event context. Deferred, delayed, yielded, or OnUpdate-resumed callbacks must not assume they retain permission to call protected APIs that require a user hardware event.

Consumers should perform protected actions only through the appropriate WoW-secure interaction path and use SchedulerKit for ordinary addon computation/state work.

## Embedded copies and live compatible revisions

SchedulerKit is registered as `schedulerKit`, API generation `1`, through Registry API 2.

The facade, Job/Scope/Context prototypes, metatables, ready queues, scopes, active jobs, and driver trampoline live in shared package state.

The installed OnUpdate trampoline does not permanently close over one implementation revision. It resolves the current shared dispatch function on every scheduler frame. TimerKit delay callbacks use the same dispatch indirection.

A future compatible SchedulerKit revision can therefore update execution behavior while preserving existing facade, Job, Scope, Context, queue, and addon-scope identity.
