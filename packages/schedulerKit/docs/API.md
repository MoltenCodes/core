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
| `SetRunawayThreshold(milliseconds)` | Set the slice duration above which a job is demoted. |
| `GetRunawayThreshold()` | Return the current yielded-slice threshold. |
| `SetMaxResumesPerFrame(count)` | Set the hard resume-count safety ceiling per frame. |
| `GetMaxResumesPerFrame()` | Return the resume-count ceiling. |
| `GetActiveCount()` | Return the number of non-terminal jobs across all scopes. |
| `Debounce(callback, delaySeconds[, options])` | Return a callable handle that runs `callback` once a burst of calls goes quiet. See [Coalescing and lanes](#coalescing-and-lanes). |
| `Coalesce(callback, intervalSeconds[, options])` | Return a callable handle that collects keys and delivers them at most once per interval. |
| `Watch(predicate, intervalSeconds, callback[, options])` | Poll `predicate` on a ticker shared by every watch of that interval. |
| `Lane(name[, options])` | Return the shared lane called `name`, which rations one scarce resource. |

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
| `GetErrorTraceback()` | Return the stack captured where a callback error was raised. |
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
| `Debounce(callback, delaySeconds[, options])` | `SchedulerKit:Debounce`, owned by this scope. |
| `Coalesce(callback, intervalSeconds[, options])` | `SchedulerKit:Coalesce`, owned by this scope. |
| `Watch(predicate, intervalSeconds, callback[, options])` | `SchedulerKit:Watch`, owned by this scope. |

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

`HIGH`, `NORMAL`, and `LOW` are **contending** lanes. Across them SchedulerKit uses a persistent weighted round-robin sequence:

```text
HIGH, HIGH, HIGH, HIGH, NORMAL, NORMAL, LOW
```

The cursor is preserved between rendered frames. HIGH work therefore receives greater service, but a continuously populated HIGH queue cannot permanently starve NORMAL or LOW.

`IDLE` is **not** a contending lane. It means what its name says: an IDLE job runs only when no HIGH, NORMAL, or LOW job is ready. It has no guaranteed share of a busy frame, which is the difference between IDLE and LOW — `LOW` is "serve this last among real work", `IDLE` is "serve this only when there is no real work".

### IDLE starvation guard

"Only when nothing else is ready" must not become "never" on a permanently busy client. After **256 consecutive resumes** of contending work while an IDLE job waits, SchedulerKit promotes one IDLE job ahead of the weighted lanes and resets the counter.

The counter is charged only while IDLE work is actually waiting, so an IDLE job that arrives after a long busy stretch does not immediately jump the queue on credit it never earned. Under sustained load the guard leaves IDLE below half a percent of total service.

Priority controls **service preference**, not correctness. A consumer must never rely on a lower-priority job being complete before a higher-priority job unless it models that dependency explicitly in its own state. A job may also be demoted by the scheduler itself (see the runaway threshold below), so `GetPriority()` is not guaranteed to return the value the job was scheduled with.

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

### Important limitation: `Yield()` cannot cross a C-call boundary

This is a property of Lua 5.1, which is the Lua version World of Warcraft runs, and it is the single most common way to break a cooperative job.

A coroutine running under Lua 5.1 cannot suspend while a C function sits between it and the resume. `Context:Yield()` therefore **fails** when it is called from inside any of these:

```lua
pcall(function() context:Yield() end)          -- and xpcall
table.sort(list, function(a, b) context:Yield() return a < b end)
string.gsub(text, "%w+", function() context:Yield() end)
setmetatable({}, { __index = function() context:Yield() end })
```

The error Lua raises is `attempt to yield across metamethod/C-call boundary`. If the callback lets that error propagate, the job fails normally and the reason is visible. The dangerous case is a callback that **swallows** it — typically its own `pcall` around per-item work — because the callback then runs on to completion having never surrendered the frame. That is a silent budget violation: the work looks cooperative and is not.

SchedulerKit detects it. `Context:Yield()` records that a suspension was requested, and the driver notices a slice that ended with the callback returning although the yield never arrived. The outcome depends on how much of the frame the slice actually consumed:

- within the runaway threshold — SchedulerKit reports a diagnostic through the host error handler naming the job and the rule; the job completes normally;
- beyond the runaway threshold — the job is **failed**, because the slice both escaped the cooperative contract and outran the budget. `GetError()` carries the same diagnostic.

The fix is always the same: move the yield point out of the C-called function.

```lua
-- Wrong: the yield is inside the protected call.
SchedulerKit:Schedule(function(context)
    for index = 1, #records do
        pcall(process, records[index])
        if context:ShouldYield() then
            context:Yield()
        end
    end
end)
```

The loop above is already correct, because the yield is outside `pcall`. Keep protected calls around the *work*, never around the yield.

### Important limitation: no preemption

Lua execution is cooperative. SchedulerKit cannot interrupt an arbitrary callback in the middle of a long-running Lua instruction sequence.

If a callback performs 50 ms of work without calling `ShouldYield()` / `Yield()`, the frame has already been blocked for those 50 ms. The scheduler can diagnose a long **yielded slice** after control returns, but it cannot retroactively recover that frame time.

Consumers are therefore responsible for placing cooperative yield points inside potentially large loops.

## Frame budget

The default budget is **2 ms** per scheduler-driven frame.

```lua
SchedulerKit:SetFrameBudget(1.5)
```

The budget is measured in **addon CPU milliseconds**, read from `debugprofilestop()`, not in wall-clock time. SchedulerKit sets one deadline on that clock at the beginning of each OnUpdate scheduling pass, re-anchors it whenever the clock moves backwards (see *The profiling clock is shared* below), and `Context:ShouldYield()` reports against the same accounting.

This distinction matters. A garbage-collection pause, a texture load, or any other client hitch moves wall time forward while the running job consumed none of the frame. Billing that to the job would make a perfectly cooperative callback look like it had blown the budget — it would yield immediately, or be flagged as a runaway, for a stall it did not cause. CPU time charges the job only for work the job actually did.

A host that does not publish `debugprofilestop` falls back to the monotonic precise wall clock (`GetTimePreciseSec`), with the caveat above.

The scheduler always permits at least one resume when work is ready. This prevents a very small budget or driver overhead from causing permanent starvation.

Changing the budget during a currently running frame affects subsequent frames; the current pass retains the deadline it started with.

### The profiling clock is shared

`debugprofilestop()` reports **one process-wide timer**, and `debugprofilestart()`
zeroes it for every addon in the session. It is not SchedulerKit's clock, and
nothing stops a neighbouring addon — or a profiling tool the player installed —
from restarting it in the middle of a SchedulerKit frame.

A budget expressed as a single absolute deadline does not survive that. After a
restart every later reading is below the deadline, the budget check never fires,
and the pass runs to the resume-count ceiling instead of to the budget: a
thousand resumes against a 2 ms budget.

SchedulerKit therefore keeps its frame accounting **monotonic**. Each budget
check remembers the previous reading, and:

- a reading that moved **forward** is spent as ordinary budget;
- a reading that moved **backwards** re-anchors the deadline to the new reading,
  carrying the budget that was left at the last good reading. The frame is never
  extended by a restart and never refunded what it already spent, and because
  the clock counts up again from wherever it restarted, only the sliver of time
  either side of the jump goes uncharged;
- a large **forward** jump is spent like any other reading and simply ends the
  frame early. That is the safe direction: the budget exists to stop the
  scheduler overrunning a frame, not to guarantee it a share of one.

The runaway threshold measures one slice rather than a whole frame, so it cannot
lean on the next reading to recover. When the clock restarted while a slice ran,
the finishing reading is itself the time since the restart, and that lower bound
is used as the slice's duration — a runaway that straddles a restart is still
recognised, and is never credited with a negative duration.

**What this costs you:** nothing, unless you call `debugprofilestart()` yourself.
If you do, you are resetting a timer the whole session shares. Prefer
`GetTimePreciseSec()` for your own measurements; if you genuinely need the CPU
profiler, do not leave it restarting on a per-frame path.

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

The default yielded-slice threshold is **8 ms** of addon CPU time.

If a job calls `Context:Yield()` but the resume consumed more than this threshold before yielding, the job is **demoted one priority lane** (`HIGH` → `NORMAL` → `LOW` → `IDLE`, and no further) and the overrun is reported through the host error handler. The job is then requeued and keeps running.

```lua
SchedulerKit:SetRunawayThreshold(6)
```

A job that yielded honoured the cooperative contract. Its slices being too coarse is a scheduling problem, not misbehaviour, and killing it would destroy work the consumer has no way to resume. Demotion is the proportionate response: the job stops competing with well-behaved work, the overrun is visible in the error log, and the consumer keeps its results. Every subsequent overrunning slice reports again and demotes again until the job reaches `IDLE`.

This is diagnostic containment, not preemption. A slice can only be measured after it yields back to SchedulerKit.

If the shared profiling clock was restarted while the slice ran, the slice is measured as the time since that restart — a lower bound, because the part before the restart is unknowable. The threshold can therefore under-report such a slice, but never over-report it and never see it as free.

A callback that completes normally is not retroactively converted into a failure merely because its final slice was long. The one exception is the swallowed-`Yield()` case described under *Cooperative execution*: there the job never yielded at all, so the threshold is the line between a diagnostic and a failure.

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

SchedulerKit captures `debug.traceback` against the failing coroutine **while that coroutine is still available**, before the job's execution references are released. Lua 5.1 leaves an errored coroutine's frames in place, so the traceback names the function that actually raised rather than the driver frame that observed the failure:

```lua
if job:HasError() then
    print(job:GetError())            -- the original Lua error object
    print(job:GetErrorTraceback())   -- where it was raised
end
```

`GetErrorTraceback()` returns `nil` for a job that did not fail through a callback error, and on a host that publishes no `debug.traceback`.

When WoW's `geterrorhandler()` is available, SchedulerKit also reports the failure through the host error handler on a best-effort basis: the traceback when one was captured, otherwise the original error object. `GetError()` always keeps the original object unchanged, including `nil` and `false`. Failure of the error handler itself cannot poison scheduler execution.

The host error handler is also the seam for non-fatal scheduler diagnostics — a demoted runaway slice and a swallowed `Context:Yield()` are reported there. Those reports never terminate a job.

A failure is signalled **once**. An operation that raises to its direct caller, such as `SchedulerKit:After` failing to arm its TimerKit delay, is not additionally pushed to the error handler; a failure on the driver path, where nothing above SchedulerKit can observe a raise, is reported instead of raised.

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

At shutdown, SchedulerKit closes the scope, cancels queued/running/delayed jobs (lane submissions included), closes its `Debounce` and `Coalesce` handles, cancels its watches, and closes its internal TimerKit delay scope.

If the lifecycle is already terminal when `ForAddon` is first called, SchedulerKit returns the canonical scope already closed.

## Package-level convenience scope

Package-level methods use a lazily created internal manual scope:

```lua
SchedulerKit:Schedule(callback)
SchedulerKit:After(1, callback)
SchedulerKit:Every(5, callback)
```

`Debounce`, `Coalesce` and `Watch` called on the package, and `Lane:Submit`
without `options.scope`, use the same scope.

The package cannot infer addon ownership from an arbitrary caller. Addon code that needs deterministic shutdown cleanup should prefer `ForAddon(addonName)`.

No SchedulerKit convenience scope is allocated merely by loading the package. The SchedulerKit scope is created on the first package-level scheduling operation, while its internal TimerKit delay scope remains unallocated until something first arms a timer in it: `NextFrame()`, `After()`, `Every()`, the window of a package-level `Debounce` or `Coalesce` handle, or the retry backoff of a lane submission it owns. Immediate-only `Schedule()` use therefore does not allocate TimerKit ownership state. If the SchedulerKit scope is closed indirectly through `job:GetScope():Close()`, every job and handle it owns is released as for any scope close, and a later package-level operation creates a fresh scope.

## WoW driver boundary

SchedulerKit relies on these direct WoW facilities:

```text
CreateFrame("Frame") + Frame:SetScript("OnUpdate", ...)
debugprofilestop()          -- addon CPU milliseconds, the budget clock
GetTimePreciseSec()         -- the coalescing family's clock, and the budget
                            -- clock's fallback when the above is absent
geterrorhandler()           -- best-effort diagnostics
```

Every timer SchedulerKit arms, including the `Debounce`, `Coalesce`, `Watch` and lane timers, is a TimerKit timer.

The OnUpdate script is installed only while at least one job is ready to execute and removed when ready queues become empty. Delayed-only jobs therefore do not keep an OnUpdate handler active.

WoW documents OnUpdate as firing on rendered UI frames and notes that it is resource-intensive when left active continuously. SchedulerKit's driver is intentionally lazy for that reason.

`debugprofilestop()` is read directly rather than cached once per rendered frame, so SchedulerKit can observe budget consumption inside one OnUpdate pass. SchedulerKit never calls `debugprofilestart()`: it only ever compares two readings, so it neither needs nor disturbs the shared profiling epoch other addons may be using.

## Protected actions and hardware events

SchedulerKit changes **when** Lua runs; it does not manufacture or preserve a WoW hardware-event context. Deferred, delayed, yielded, or OnUpdate-resumed callbacks must not assume they retain permission to call protected APIs that require a user hardware event.

Consumers should perform protected actions only through the appropriate WoW-secure interaction path and use SchedulerKit for ordinary addon computation/state work.

## Coalescing and lanes

`Debounce`, `Coalesce`, `Watch` and lanes are one family, designed together
with EventKit's `Coalesce` and `Derive` (see EventKit's
[`docs/API.md`](../../eventKit/docs/API.md#coalescing-events)). They answer two
questions that every addon otherwise answers by hand:

- **When is a burst over?** `Debounce` waits for quiet; `Coalesce` collects
  everything one interval brings; `Watch` samples on a fixed beat.
- **How much of a scarce resource may run at once?** A lane rations it:
  in-flight cap, minimum interval between starts, retry with backoff, and a
  bounded queue.

The two halves meet through `options.lane`: a `Debounce` or `Coalesce` given a
lane hands every fire to that lane as a job instead of running it
synchronously, so the whole family shares one throttling vocabulary.

A *lane* here is a named ration of a resource. It is unrelated to the
*priority lanes* (`HIGH`, `NORMAL`, `LOW`, `IDLE`) described under
[Priorities](#priorities); lane jobs are ordinary jobs with an ordinary
priority.

### One clock

Every due time in the family is computed on `GetTimePreciseSec()`, the
monotonic wall clock TimerKit's own deadlines use. Timers are TimerKit timers:
a `Debounce` or `Coalesce` arms at most one timer at a time in its scope's
TimerKit scope, and `Watch` tickers and lane interval timers live in one
package-internal TimerKit scope. A timer that wakes within one millisecond of
its due time counts as due. A computed wait is never longer than the delay,
interval or minimum interval it was derived from, so a clock that steps
backwards cannot stretch it. Nothing in the family keeps an `OnUpdate` handler
alive while it waits.

### `Debounce(callback, delaySeconds[, options])`

Returns a callable handle. Each call records its arguments and restarts the
quiet period; once `delaySeconds` pass without a call, `callback` runs **once**
with the arguments of the **last** call.

```lua
local refresh = SchedulerKit:ForAddon("MyAddon"):Debounce(function(reason)
    rebuildBagIndex(reason)
end, 0.2)

refresh("BAG_UPDATE")  -- returns true; call it as often as you like
```

| Option | Meaning |
|---|---|
| `leading` | Also run on the first call of a burst. A burst of one call then runs once, not twice. |
| `maxWaitSeconds` | Run at most this long after the first call of a burst, even if calls keep coming. At least `delaySeconds`. |
| `lane` | Hand every fire to this lane as a job; see *Firing into a lane*. |

- A call inside an open window records its arguments and a clock reading; it
  does not re-arm the timer. The timer re-arms once, for the remainder, when it
  wakes before the burst is quiet.
- Arguments are kept in a reused slot of **eight** values. A ninth argument
  raises at the caller: `SchedulerKit debounce handle accepts at most 8
  arguments; received 9`. Pass a table if you need more.
- `delaySeconds = 0` means the next frame, as `NextFrame` does.
- Calling the handle returns `true`, or `false` once it is closed.
- If TimerKit cannot arm the handle's timer, the failure is reported through
  the host error handler and the owed fire is kept: the next call opens a new
  window, and `Flush()` delivers it at once.

| Method | Purpose |
|---|---|
| `Cancel()` | Drop the owed fire; returns whether one was owed. The handle stays usable. |
| `Flush()` | Run the owed fire now; returns `true`, or `false` when nothing was owed. With a lane it returns `false, "deferred"` when the lane is full (the fire stays owed and is retried one delay later) and `false, "dropped"` when the lane is closed. |
| `IsPending()` | Whether a fire is owed and has not been handed off yet. |
| `Close()` | Drop what is owed, cancel a delivery still waiting for the lane, and leave the scope. A delivery the lane already admitted finishes, as lane admissions do. Terminal; returns `false` when already closed. |
| `IsClosed()` | Whether the handle is closed. |

### `Coalesce(callback, intervalSeconds[, options])`

Returns a callable handle that collects **keys**. `handle(key[, value])`
records `set[key] = value` (`true` when `value` is omitted). The first key of a
burst starts the interval; at its end `callback(set)` runs once with everything
collected, and the handle is idle again until the next key. This is AceBucket's
"first event starts the interval, callback at its end with everything
collected".

```lua
local changed = SchedulerKit:Coalesce(function(units)
    for unit in pairs(units) do
        updateFrame(unit)
    end
end, 0.1)

changed("player")
changed("target")
changed("player") -- one set { player = true, target = true } in 0.1 s
```

**The set is reused.** It is one of two tables the handle swaps at every
delivery. Without a lane it is emptied as soon as `callback` returns; delivered
through a lane it lives until the lane job reaches a terminal state, across
every retry, and is emptied then. `callback` must not keep a reference to it;
copy what you need. Keys recorded while `callback`
runs go into the other table and arrive with the next interval.

| Option | Meaning |
|---|---|
| `maxKeys` | Distinct keys one interval may hold; default **256**. |
| `lane` | Hand every delivery to this lane as a job; see *Firing into a lane*. |

Past `maxKeys` a **new** key is refused: the call returns `false` and the
refusal is counted. A key already in the set is still updated. Refusing was
chosen over evicting an older key because a set that silently loses a key
it already accepted is harder to reason about than one that says no. A `nil`
or NaN key raises at the caller; a closed handle returns `false`.
`intervalSeconds` may be `0`, which means the next frame.

| Method | Purpose |
|---|---|
| `Cancel()` | Drop the collected keys; returns whether there were any. The handle stays usable. |
| `Flush()` | Deliver now; returns `true`, or `false` when nothing was collected. With a lane it returns `false, "deferred"` while the previous set is still in the lane or the lane is full (the keys stay collected and the interval timer delivers them), and `false, "dropped"` when the lane is closed. |
| `IsPending()` | Whether keys are waiting for delivery. |
| `GetStats()` | `{ keys, refused, delivered, deferred, dropped }`, in a table reused by every call. |
| `Close()` | Drop the keys, cancel a delivery still waiting for the lane, and leave the scope. A delivery the lane already admitted finishes. Terminal; returns `false` when already closed. |
| `IsClosed()` | Whether the handle is closed. |

`Flush()` called from inside the handle's own callback returns `false`: the
delivery in progress is not re-entered. The same holds for a `Debounce`
handle.

### `Watch(predicate, intervalSeconds, callback[, options])`

Polls `predicate()` every `intervalSeconds` and calls `callback(value,
previous)`:

- on the **first** tick, with the first result and `previous = nil`;
- afterwards only when the result differs (`~=`) from the previous tick's;
- or on every tick with `options.everyTick = true`.

A predicate that returns NaN changes on every tick, because NaN is never equal
to itself; return something comparable.

Every watch with the same interval shares **one** TimerKit ticker, created with
the first watch and cancelled with the last; a tick samples its watches in
creation order. Watches added during a tick start with the next one.

| Bound | Value |
|---|---|
| Watches per interval | **128**; one more raises at the caller. |
| Distinct intervals | **32**; one more raises at the caller. |

Both bounds are package-wide, because the tickers are shared by every addon in
the session. They are constants rather than options for the same reason: one
addon raising them would spend everybody's frame.

A predicate that raises is reported once through the host error handler and
its watch is **cancelled**: it would raise again on every tick. A callback that
raises is reported and the watch keeps polling. Predicates run inside the
ticker's callback, so keep them cheap; put heavy work in a job.

| Method | Purpose |
|---|---|
| `Cancel()` | Stop polling. Terminal; returns `false` when already cancelled. |
| `IsActive()` | Whether the watch is still polling. |

### Lanes: `Lane(name[, options])`

A lane is shared by **name** across every addon in the session, which is the
point: two addons querying the same server resource should queue in one line.
The first call creates it; later calls with no options, or the same options,
return the same lane, and a call with different options raises.

```lua
local inspect = SchedulerKit:Lane("inspect", {
    maxInFlight = 1,
    minIntervalSeconds = 1.5,
    retry = { attempts = 2, backoffSeconds = 2, multiplier = 2, maxBackoffSeconds = 10 },
    maxQueued = 64,
})

local job, reason = inspect:Submit(function(context)
    NotifyInspect(unit)
    while not inspectReady(unit) do
        context:Yield() -- the lane's slot stays taken until this returns
    end
end, { scope = work, name = "inspect " .. unit })
```

| Option | Default | Meaning |
|---|---|---|
| `maxInFlight` | `1` | Submissions admitted and not yet finished, at most. |
| `minIntervalSeconds` | `0` | Minimum time between two admissions. |
| `retry.attempts` | `0` | Retries after the first attempt. |
| `retry.backoffSeconds` | `0` | Delay before the first retry. |
| `retry.multiplier` | `2` | Growth of each later delay; at least `1`. |
| `retry.maxBackoffSeconds` | none | Ceiling on one delay. |
| `maxQueued` | `64` | Submissions waiting for admission, at most. |

At most **32** lanes are open at once; one more raises at the caller.

`lane:Submit(callback[, options])` uses the scheduler's own job contract: the
callback receives a `Context`, may `Yield()`, **succeeds by returning** and
**fails by raising**. It returns the `Job`, or `nil, "full"` when `maxQueued`
submissions already wait, or `nil, "closed"` after `Close()`. A refusal
allocates nothing and never grows the queue. `options` takes `priority` and
`name` as for `Schedule`, and `scope`, the owning SchedulerKit scope (the
package-level scope by default).

A submission waits in the `delayed` state until the lane admits it; admission
queues it exactly as an expiring delay would. A submission that raises and has
attempts left is re-armed: the *n*-th retry waits
`backoffSeconds × multiplier^(n − 1)`, capped at `maxBackoffSeconds`, and at
least until `minIntervalSeconds` have passed since the lane's last start; a
retry counts as a start when its backoff expires. It keeps its in-flight slot
while it waits, which is what backing off a resource means. A retried attempt
is **not** reported; the attempt that exhausts the policy fails the job and is
reported with its traceback, like any job failure.

| Method | Purpose |
|---|---|
| `Submit(callback[, options])` | Queue a job under the lane's limits. |
| `GetStats()` | `{ queued, inFlight, completed, failed, retried, cancelled, refused }`, in a table reused by every call. |
| `GetName()` | The shared name. |
| `Close()` | Refuse new submissions, cancel every waiting one, let admitted ones finish; frees the name. Returns `false` when already closed. |
| `IsClosed()` | Whether the lane is closed. |

`Close()` **drains** what is in flight rather than cancelling it: an admitted
job may already have spent the resource, and cancelling it would lose the
answer. Cancel the job itself, or close its scope, to stop it. Retries are
the exception: an admitted job waiting out a retry backoff has not started its
next attempt, so `Close()` cancels it, and an attempt still running that raises
after `Close()` fails instead of retrying. A lane is not
owned by a scope; each submission's job is.

### Firing into a lane

With `options.lane`, a `Debounce` fire or a `Coalesce` delivery becomes one job
in the lane, so the lane's in-flight cap, interval and retry apply to the
callback, and a raising callback is retried.

- A handle has at most **one** delivery in the lane at a time. A `Debounce`
  fire that finds its previous delivery still waiting updates that delivery's
  arguments instead (the last call wins); one that arrives after the delivery
  started runs once more when it finishes.
- A `Coalesce` delivery that finds its previous set still in the lane keeps
  collecting into the current set and tries again one interval later
  (`deferred` in `GetStats()`).
- A lane that is **full** defers the fire by one delay or interval; it is never
  dropped. When a `Debounce` re-delivery meets a full lane after a newer burst
  has started, the newer burst's arguments win and the refused ones are
  discarded.
- A lane that is **closed** drops the fire and reports it through the host
  error handler; the lane counts the refusal (`refused`), and a `Coalesce`
  handle also counts it (`dropped`). A `Debounce` handle keeps no counters.
- `Close()` on the handle cancels a delivery still waiting for the lane and lets
  an admitted one finish; closing the owning scope cancels both, because the
  job belongs to the scope.

### Scopes and release

`Debounce`, `Coalesce` and `Watch` handles are owned by the scope that created
them, exactly like jobs, so an addon scope or ModuleKit's `module.scope.Jobs`
releases them without any teardown code:

| Scope call | Debounce / Coalesce | Watch | Lane jobs of the scope |
|---|---|---|---|
| `CancelAll()` | Pending fire dropped; handle stays usable. | Cancelled. | Cancelled, waiting or admitted. |
| `Close()` | Closed. | Cancelled. | Cancelled, waiting or admitted. |

The package-level methods use the package-level scope, as `Schedule` does.
`GetActiveCount()` still counts jobs only; a handle is not a job.

### Cost

Recording a `Debounce` call inside an open window, recording a `Coalesce` key
already seen, and a `Watch` tick whose values did not change allocate nothing;
specs guard each with `collectgarbage("count")`. A fire without a lane is one
protected call. What does allocate is bounded and per burst, not per call: one
TimerKit timer per quiet window or interval, and one job per lane submission.

## Embedded copies and live compatible revisions

SchedulerKit is registered as `schedulerKit`, API generation `1`, through Registry API 2.

The facade, Job/Scope/Context prototypes, metatables, ready queues, scopes, active jobs, and driver trampoline live in shared package state.

The installed OnUpdate trampoline does not permanently close over one implementation revision. It resolves the current shared dispatch function on every scheduler frame. TimerKit delay callbacks use the same dispatch indirection.

A future compatible SchedulerKit revision can therefore update execution behavior while preserving existing facade, Job, Scope, Context, queue, and addon-scope identity.

Revision 8 changes only behaviour, plus one field: each lane keeps the set of
its admitted jobs (`_admitted`) so `Close()` can cancel pending retries. A lane
created by revision 7 has none and gains it on first use; jobs it admitted
before the upgrade finish as they would have.

Revision 7 adds the coalescing family to shared state: the lane registry, the
watch groups, the package-internal TimerKit scope, and one metatable and method
table per handle kind. A revision-7 copy loading over revision 6 adds them in
place, and scopes the older copy created gain `Debounce`, `Coalesce` and
`Watch`. Handle timers and lane jobs resolve their behaviour through the shared
dispatch table, so a later compatible revision upgrades live handles too.
