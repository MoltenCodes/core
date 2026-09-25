# SchedulerKit Internals

This document explains SchedulerKit's implementation invariants. It is not a public API contract; [`API.md`](API.md) is authoritative for consumer-visible behavior.

## Why one runtime source file?

SchedulerKit intentionally keeps its runtime bootstrap and implementation in `src/SchedulerKit.lua`.

MoltenCodes packages must remain portable to WoW clients without depending on a general-purpose module loader for internal source composition. The file is organized into explicit sections instead of introducing runtime `require()` coupling solely to make the repository look smaller.

## Shared embedded state

Registry owns one implementation table for `(schedulerKit, API 1)`. SchedulerKit stores compatible-revision state on that shared table:

```text
SchedulerKit facade
└── _state
    ├── dispatch
    ├── queues[priority]
    ├── laneOccupied[priority] + occupiedLaneCount
    ├── priorityCursor + idleGuard
    ├── addonScopes
    ├── defaultScope
    ├── Job / Scope / Context metatables + yieldToken
    ├── Frame driver + trampoline (frame, driverEnabled, driverTrampoline)
    ├── frame pass (currentJob, frameDeadline, frameReading)
    ├── configuration
    ├── activeCount
    ├── lanes[name] + laneCount
    ├── watchGroups[interval] + watchGroupCount
    ├── familyTimerScope
    ├── familyMetatables / familyPrototypes (debounce, coalesce, watch, lane)
    ├── unbounded + limits
    ├── logoutConnection + logoutEventScope
    └── workerFinished + idleWorkers + idleWorkerCount (revision 18)
```

Existing Jobs, Scopes, Contexts, queues, and the installed Frame trampoline therefore survive a compatible revision upgrade.

Bookkeeping a newer revision introduces is **derived** from inherited state rather than assumed: revision 4 rebuilds `laneOccupied`/`occupiedLaneCount` from the queues it inherits, so jobs an older embedded copy had already queued keep being served.

The Frame trampoline and delayed TimerKit wakeups resolve operations through `_state.dispatch`. They do not permanently pin scheduler behavior to the source revision that originally created them.

## Ready queues

Each priority owns an array-backed FIFO queue with `head`/`tail` indices.

Dequeuing clears consumed array slots to release references immediately. When a queue becomes empty, only its indices are reset; the backing table is reused rather than allocating a new table on every drain. The reset happens as soon as the last entry is popped, before the job runs, so a job that yields slice after slice is pushed back into slot 1 each time instead of walking the indices upwards; `Allocation_spec.lua` guards that the resume path allocates nothing.

### Lane occupancy

Shared state carries a per-lane `laneOccupied` flag plus an `occupiedLaneCount`. The flag is set when a job is pushed and cleared the moment a drain resets a lane's indices, so it is a conservative hint: a lane holding only stale cancelled nodes still reads as occupied, but a cleared flag always means *definitely empty*.

That one-sided guarantee is what lets ready selection skip a lane with a single table read instead of a `queuePop` call, and lets an entirely empty scheduler answer in one integer comparison.

Measured on Lua 5.1.5, 200 000 trivial jobs resumed in one pass:

| Workload | Probes per selection (before → after) | Frame pass |
|---|---|---|
| single `LOW` lane | 8 → 1 | 0.540 s → 0.345 s (**-36%**) |
| single `HIGH` lane | 1 → 1 | 0.333 s → 0.314 s (-6%) |

The saving scales with how many empty lanes the weighted cursor used to cross. `HIGH` sits at the front of the sequence and rarely crossed any, so it only gains the empty-scheduler early exit; `LOW` sat behind six empty probes on every selection. Selection order and per-lane FIFO are unchanged.

Cancellation is lazy with respect to queue position:

1. the Job is marked non-queued/terminal immediately;
2. an existing stale queue node is harmless;
3. queue traversal skips and clears stale nodes when encountered.

This avoids O(n) removal from the middle of an array on `Job:Cancel()`.

## Weighted fairness

Ready selection uses this repeating service sequence over the three contending lanes:

```text
HIGH HIGH HIGH HIGH NORMAL NORMAL LOW
```

The cursor is stored in shared state and is **not reset at frame boundaries**. Preserving the cursor is what turns the sequence into starvation-resistant weighted service instead of repeatedly favoring the beginning of the sequence every frame.

FIFO is preserved independently inside each lane.

`IDLE` is deliberately outside the sequence. It is served only after a full pass over the contending lanes finds nothing ready, which is what makes `IDLE` mean "background" rather than "a slightly smaller share than LOW".

The `idleGuard` counter bounds that: it is incremented on every contending resume **while IDLE work is waiting**, and once it reaches `IDLE_STARVATION_RESUMES` one IDLE job is promoted ahead of the sequence and the counter resets. It is also reset to zero whenever the IDLE lane is empty, so credit cannot accumulate during a busy stretch and then be spent by an IDLE job that arrives afterwards.

## Frame driver

The driver Frame is created lazily on first ready work.

```text
ready queue becomes non-empty
        ↓
install OnUpdate
        ↓
run cooperative slices
        ↓
all ready queues empty
        ↓
remove OnUpdate
```

Delayed-only jobs are owned by TimerKit and do not keep SchedulerKit's OnUpdate active.

### The budget clock

Budget and runaway accounting use `debugprofilestop()`, which reports **addon CPU milliseconds**. The clock function is chosen once at load and bound to a file-local, so the hot path never branches on availability; `GetTimePreciseSec()` (converted to milliseconds) is the fallback when a host does not publish the CPU clock.

Wall-clock time was wrong for this job. A garbage-collection pause or client hitch advances it while the running coroutine consumed none of the frame, which charged a cooperating job for a stall it did not cause and could convert it into a runaway. CPU time measures only what the job executed.

SchedulerKit never calls `debugprofilestart()`. It compares two readings of the same counter, so it neither needs its own epoch nor disturbs one another addon may have started.

That counter is not monotonic, though: it is one process-wide timer, and any other addon calling `debugprofilestart()` zeroes it mid-frame. The accounting is therefore made monotonic here rather than assumed. Each budget check keeps the previous reading in `state.frameReading` beside `state.frameDeadline`; forward movement is spent, and a backwards jump re-anchors the deadline to the new reading with the budget that was left at the previous one. `Context:ShouldYield()` runs through the same function, so a job and the driver can never disagree about whether the frame is over. The runaway slice measurement cannot lean on a later reading, so when it sees a backwards jump it uses the finishing reading — the time since the restart — as a lower bound rather than a negative duration.

The scheduler records one deadline per OnUpdate pass.

Two independent ceilings stop one pass:

- time deadline (`frameBudgetMs`);
- resume-count ceiling (`maxResumesPerFrame`).

The resume ceiling matters when callbacks are so cheap that the time source does not advance enough to exhaust the configured budget.

## Cooperative coroutine lifecycle

A Job takes its coroutine only when first resumed.

```text
delayed ──wake──> pending ──resume──> running
                           ↑             │
                           │ Context:Yield
                           └─────────────┘

running ──return──> completed
running ──error───> failed
any non-terminal ──Cancel──> cancelled
```

Repeating jobs replace `completed` with a TimerKit-backed `delayed` interval and take a coroutine again for the next iteration.

Only SchedulerKit's private yield token is accepted. This makes accidental raw coroutine suspension fail fast instead of creating an undocumented protocol.

### Worker coroutines

Since revision 18 a job's first slice runs on a **worker**: a coroutine whose body (`runWorker`) reads the job's callback and context, calls the callback, then yields `state.workerFinished` and waits there to be resumed with the next job. `resumeJob` starts a job by resuming a worker with the job as the resume value (the body's argument for a new worker, the `yield`'s result for an idle one), and resumes later slices with no value, so `Context:Yield()` still returns nothing.

A slice that ends with the finished token means the callback returned; a slice that ends with the coroutine dead means the same for a coroutine an older revision created for the job, which ends by returning. Both complete (or re-arm) the job. Only a worker that yielded the finished token is kept, on a stack of at most four (`MAX_IDLE_WORKERS`) idle workers; a coroutine whose callback raised, raw-yielded, or whose job was cancelled while it was suspended in `Context:Yield()` is dropped with its stack, exactly as before. The body clears its locals before the `yield`, so an idle worker keeps neither the finished job nor its callback alive.

What this saves is the coroutine (about 1.2 KB on Lua 5.1, its stack and call-info arrays included) and the closure that started it, per job and per repeating iteration. Callbacks can observe the reuse only through `coroutine.running()`, which SchedulerKit never documented as unique per job.

The finished token lives in shared state so a worker that is running an older revision's body when a newer copy loads ends in a way the newer copy recognises. The idle stack is dropped at every upgrade, so a copy never resumes a worker body another revision wrote.

### Yield intent

`Context:Yield()` sets `_yieldRequested` on the job immediately before suspending, and `resumeJob` clears it at the start of every slice. If a slice ends with the coroutine dead while the flag is still set, the suspension never reached the driver: Lua 5.1 refused to yield across a C-call boundary and the callback swallowed the error. The driver reports that, and fails the job when the same slice also outran the runaway threshold.

Checking the flag only on the callback-returned path (the finished token, or a dead coroutine an older revision created) avoids a false positive for a callback that catches the boundary error and then yields correctly further on.

### Runaway slices

A slice that exceeded the runaway threshold **and** ended in a real cooperative yield demotes the job one lane and reports through `geterrorhandler`. It is never failed: the job kept its side of the contract, and killing it would discard work the consumer cannot resume. Demotion is idempotent at `IDLE`.

## Scope ownership

Active Jobs are linked into each Scope through intrusive previous/next pointers.

This gives:

- O(1) active insertion;
- O(1) terminal removal;
- deterministic creation-order bulk cancellation;
- no ever-growing completed-job history inside long-lived scopes.

`CancelAll()` walks the active list while capturing each next pointer before cancellation mutates the links.

## Delayed wakeups

SchedulerKit uses a child TimerKit Scope per scheduling Scope.

The waking job travels on the TimerKit handle through TimerKit's public `SetUserData`/`GetUserData` seam. SchedulerKit writes no private fields onto another package's objects, which is what `docs/ARCHITECTURE.md` requires of cross-package behaviour, and attaching the reference allocates nothing.

All delays share one SchedulerKit wake callback rather than allocating a new callback closure for every repeat interval. The wake callback reads the job from the handle, detaches it, then resolves the current implementation through shared `_state.dispatch`.

Staleness is decided by handle identity: a cancelled or re-armed job no longer points at the handle that fired, so the wake callback resolves a generation that cannot match. The dispatch entry still takes `(job, generation)`, unchanged from revision 3, so a delay armed before a live upgrade wakes correctly against the new implementation.

## Argument-error levels

Every argument and wrong-receiver error names the caller's line, so the
`error` level each check uses counts the frames between it and the caller. A
public method must therefore never end in `return helper(...)` when the helper
can raise an argument error: that is a tail call, the public method's frame is
replaced, and the level lands on a frame that no longer exists. The Retail
client then prints the message with no position at all (measured on 12.1.0
build 69933, 2026-09-24). Standard Lua 5.1 keeps a "(tail call)" placeholder
level, so under Busted the count can still come out right; the unit specs
check with a line hook that no tail-called frame of SchedulerKit.lua runs on
the way to the raise.

The pattern the source uses instead:

- the public method validates its own receiver (`validateScope`,
  `validateJob`), at level 3;
- it keeps the helper's result in a local (`local job = helper(...)`, then
  `return job`), so its frame stays on the stack;
- `scheduleInScope` and `scheduleAfterInScope` raise their own errors at
  level 3 and pass level 4 to the validators they call; `validateOptions`
  raises at level 4 and passes level 5 on.

Revisions 15 and older used the tail call for the package-level and scope
`Schedule`, `NextFrame`, `After` and `Every`, and for `Scope:CancelAll`,
`Scope:Close` and `Job:Cancel`.

## Error containment

User callback failure is a Job outcome, not an OnUpdate failure.

SchedulerKit:

1. marks the Job `failed`;
2. preserves the exact Lua error object;
3. removes it from active scope ownership;
4. best-effort reports it through WoW's current error handler;
5. continues unrelated scheduler work.

The traceback is captured by `debug.traceback(thread, message)` **before** the job's coroutine reference is dropped. Lua 5.1 does not unwind an errored coroutine's stack, so this is the only point at which the raising frame can still be named. The Retail client publishes no `debug` global (measured on 12.1.0 build 69933, 2026-09-24), so there the capture falls back to the client's `debugstack(thread)`, whose bare stack is prefixed with `tostring(message)` and a `stack traceback:` header to keep the shape `debug.traceback` gives. `Debounce`, `Coalesce` and `Watch` run their callbacks under `xpcall` instead, and its handler `captureFailure` (in the installer) captures the current stack from level 3, skipping `pcall` and itself, with `debug.traceback(message, 3)` or `debugstack(3)`; the installer reads `debugstack` into a local of its own.

Internal/native failures that occur in direct API operations may still be re-raised to the direct caller after logical cleanup has been committed. Such a failure is recorded on the job but **not** reported to the error handler, because the direct caller already has it; the same operation reached from the driver, where no caller can observe a raise, reports instead. One failure therefore produces exactly one signal.

## Coalescing family

`Debounce`, `Coalesce`, `Watch` and lanes live in one installer function,
`installCoalescingFamily`, rather than at the top level of the chunk: Lua 5.1
allows 200 locals per function and the main chunk is close to that.

Headroom at revision 17: the main chunk holds 191 top-level locals of the 200
Lua 5.1 allows active at once (`luac -l -l` reports 213 declared, counting
block-scoped ones, in 194 stack slots); the installer declares 111 locals and
uses 41 of 60 upvalues. Revision 14 added the secret-value check without a new
top-level slot: `debug` and `issecretvalue` are read inside `do` blocks, so
only `nativeTraceback` and `refuseSecretValue` stay at the top level. Revision
15 reads `debugstack` the same way, inside the `do` block that defines
`captureTraceback`, and once more as an installer local for `captureFailure`.
Revision 16 adds no local: its argument-error fix only moves receiver checks
into the public methods and keeps their results in function locals.
Revision 17 adds no local and no installer upvalue: the option-table checks
call the existing `refuseSecretValue`. Revision 18 adds two top-level slots
(193 of 200 active; 217 declared in 196 stack slots): `isSecretValue`, the bare
probe the hot validators use to build an error label only on refusal, and the
worker helpers, which share one slot pair because `runWorker` and
`MAX_IDLE_WORKERS` live in the `do` block that defines `acquireWorker` and
`retainWorker` and `createCoroutine` is gone. The installer gains one upvalue
(`isSecretValue`, 42 of 60). New top-level code belongs in the installer or in a
function of its own. The
installer commits its own methods; only four hooks forward-declared above the
job machinery (`laneJobFinished`, `retryLaneJob`, `cancelFamilyMembers`,
`closeFamilyMembers`) escape it.

### Scope members

A scope keeps a second intrusive list beside its jobs: `_familyHead` /
`_familyTail`, with `_familyPrev` / `_familyNext` / `_linked` on each
`Debounce`, `Coalesce` and `Watch` handle. `CancelAll` walks it with the next
pointer captured first (a cancelled watch unlinks itself); `Close` re-reads the
head after each member, because every member close unlinks before anything
that can raise. Scopes created before revision 7 have no such fields; `nil` reads
as an empty list.

### Timers and dispatch

One shared TimerKit callback, `familyWakeCallback`, serves every `Debounce`,
`Coalesce` and lane timer. The owner rides on the TimerKit handle as public
user data, and the owner's `_timer` field is the staleness token, exactly as
for delayed jobs. The callback resolves `_state.dispatch.familyWake`, and each
lane-delivery job resolves `_state.dispatch.runDelivery`, so live handles
follow a compatible upgrade. A wake never raises into TimerKit: failures are
reported.

`Debounce` does not re-arm per call. A call records its arguments and a clock
reading; the timer, armed once per quiet window, re-arms for the remainder when
it wakes early. `maxWaitSeconds` only shortens the due time while a trailing
fire is owed.

Every computed wait (the Debounce remainder, the lane interval) is clamped to
the delay or interval it came from, so a clock that steps backwards cannot
stretch it. A Debounce timer that cannot be armed leaves the handle idle with
its fire still owed; `debounceCall` only treats the handle as "waiting" while a
timer really exists.

`Coalesce` keeps two set tables and swaps them at each delivery, so the
callback can record keys without touching the table it is iterating, and
`wipe` empties the delivered table in place so its hash part is reused.

A fire without a lane runs through one `xpcall` trampoline with the callback and
up to eight arguments staged in upvalues, the same technique EventKit uses for
listener isolation: no closure and no argument table per fire. A call wider
than eight (possible once `maxDebounceArguments` is raised) is recorded into
the slot with a `select` loop, the slot's `width` field remembers the highest
position written so clearing stays bounded, and its fire copies the values into
one table and calls through one closure.

### Lanes

A lane submission is a job with four extra fields: `_lane`, `_laneAdmitted`,
`_attempt` and `_laneOwner`. It is created `delayed` and parked in the lane's
FIFO (`_items`, `_head`, `_tail`); `pumpLane` admits it by setting it `pending`
and pushing it onto its priority queue. `finishJob` calls `laneJobFinished` for
every lane job exactly once, which decrements `_queued` or `_inFlight`, counts
the outcome, tells a `Debounce`/`Coalesce` owner its delivery ended, and pumps
the lane again.

A waiting submission cancelled in place leaves a stale FIFO entry, like a
cancelled job in a ready queue. The indices restart at `1, 0` whenever the FIFO
drains, so they do not climb for the lane's whole life; between drains
`_tail` rises by one per submission, bounded by compaction.

Each lane also keeps `_admitted`, the set of its admitted, unfinished jobs,
maintained by `pumpLane` and `laneJobFinished`. `Close()` walks it to cancel
jobs waiting out a retry backoff. A retry's delay is at least the lane's
remaining minimum interval, and `wakeDelayed` records the lane's last start
when an admitted lane job wakes from its backoff. When the backing array reaches `maxQueued`
entries while fewer are live, `compactLaneQueue` rewrites it, so the array
never exceeds `maxQueued` whatever the churn.

`resumeJob`'s error path asks `retryLaneJob` first. A retry increments the
job's generation, drops its coroutine and re-arms it through the ordinary
`armDelay`; the job keeps `_laneAdmitted`, so it keeps its slot.

### Watch groups

`watchGroups[interval]` holds the watchers of one interval in an array plus a
live count, and one TimerKit ticker in the package-internal timer scope. A
cancel during a tick marks the group dirty; the array is compacted after the
tick, keeping creation order, and the group and its ticker are released when
the live count reaches zero.

## Plain indexing on the hot paths

The ready queues, the frame pass, job creation and completion, scope links and
the `Coalesce` record and delivery path read and write their tables by plain
indexing (`job._state`) rather than `rawget`/`rawset`. On Lua 5.1 a plain index
is one VM instruction and `rawget` a C function call, and those calls were a
large share of every scheduled job. It is the same operation on these tables:
package state and the queues have no metatable, and the Job, Scope, Context and
family metatables have an `__index` whose prototype holds only methods and no
`__newindex`. A field a record may lack (a lane field, a failure field) reads
as `nil` either way, and a write to a present field is a raw write. Option
tables and anything else a caller supplies are still read with `rawget`.

Option validation builds its error labels (`methodName .. " name"`) only once a
value is refused: the fast test in front of each validator accepts exactly
what the validator accepts, so a reused option table costs no string work.

## Allocation policy

The normal resume hot path avoids container copies and queue-table replacement.

Expected allocations include:

- one Job table per logical job;
- one Context table per logical job while the job is executable;
- no coroutine once a worker is idle: a finished one-shot run or iteration hands its worker back, and at most four idle workers are kept (see *Worker coroutines*); a new worker is created only when none is idle, for example while several jobs are suspended in `Context:Yield()` at once;
- TimerKit's timer object and one TimerKit ownership scope when a SchedulerKit scope first uses delayed/next-frame eligibility;
- SchedulerKit Scope objects when explicitly created.

Terminal jobs clear execution-only references such as their callback, Context, coroutine, and delay handle. A retained Job handle therefore does not unnecessarily retain the callback closure after completion/cancellation/failure.

Scope ownership is two-stage lazy. Loading SchedulerKit allocates neither its package-level convenience scope nor a TimerKit delay scope. Creating a SchedulerKit scope also does not allocate TimerKit ownership state; that happens only when the scope first arms a timer: `NextFrame`, `After` or `Every` work, a `Debounce` or `Coalesce` window, or a lane retry backoff. Immediate-only scheduling therefore stays independent of TimerKit scope allocation after dependency bootstrap.

The coalescing family adds: one handle table (plus two set tables for
`Coalesce`, whose handle is written with sixteen fields so its hash part has 16
slots: the lane fields, the rare counters and the `GetStats` view are written
when first needed and read as `false` or `0` while absent; one or two eight-slot argument tables for `Debounce`, and one
delivery closure when a lane is given) per handle; one TimerKit timer per quiet
window, interval or lane interval; one job per lane submission; one group table
and ticker per distinct watch interval. Recording calls, recording known keys
and steady ticks allocate nothing.

A Job table is written with at most fifteen fields, so its hash part has 16 slots rather than 32: the failure fields (`_errorPresent`, `_error`, `_errorTraceback`) are written when a job fails and `_yieldRequested` at its first slice, and every read treats an absent one as "no". A one-shot job therefore allocates about 0.8 KB, its record and its Context, where revision 17 allocated about 2.8 KB.

SchedulerKit deliberately does not pool Job objects in API generation 1 because stable user-visible handles and accidental handle reuse are a more serious correctness risk than the potential allocation saving. Contexts are not pooled for the same reason: a callback may keep its Context, and `Context:GetJob()` must keep answering its own job. It does not use PoolKit for private internals either: that would add a dependency (design constitution, principle 4b) for internals that are already allocated once per job or handle.

Protected calls on the steady paths take a named function and its arguments (`pcall(armScopeTimer, scope, delay)`, `pcall(resultsDiffer, value, previous)`) rather than a fresh closure, so re-arming a repeating job and comparing watch results allocate nothing of their own.
