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
    ├── Job / Scope / Context metatables
    ├── Frame driver + trampoline
    ├── configuration
    ├── lanes[name] + laneCount
    ├── watchGroups[interval] + watchGroupCount
    ├── familyTimerScope
    └── familyMetatables / familyPrototypes (debounce, coalesce, watch, lane)
```

Existing Jobs, Scopes, Contexts, queues, and the installed Frame trampoline therefore survive a compatible revision upgrade.

Bookkeeping a newer revision introduces is **derived** from inherited state rather than assumed: revision 4 rebuilds `laneOccupied`/`occupiedLaneCount` from the queues it inherits, so jobs an older embedded copy had already queued keep being served.

The Frame trampoline and delayed TimerKit wakeups resolve operations through `_state.dispatch`. They do not permanently pin scheduler behavior to the source revision that originally created them.

## Ready queues

Each priority owns an array-backed FIFO queue with `head`/`tail` indices.

Dequeuing clears consumed array slots to release references immediately. When a queue becomes empty, only its indices are reset; the backing table is reused rather than allocating a new table on every drain.

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

A Job creates its coroutine only when first resumed.

```text
delayed ──wake──> pending ──resume──> running
                           ↑             │
                           │ Context:Yield
                           └─────────────┘

running ──return──> completed
running ──error───> failed
any non-terminal ──Cancel──> cancelled
```

Repeating jobs replace `completed` with a TimerKit-backed `delayed` interval and create a fresh coroutine for the next iteration.

Only SchedulerKit's private yield token is accepted. This makes accidental raw coroutine suspension fail fast instead of creating an undocumented protocol.

### Yield intent

`Context:Yield()` sets `_yieldRequested` on the job immediately before suspending, and `resumeJob` clears it at the start of every slice. If a slice ends with the coroutine dead while the flag is still set, the suspension never reached the driver: Lua 5.1 refused to yield across a C-call boundary and the callback swallowed the error. The driver reports that, and fails the job when the same slice also outran the runaway threshold.

Checking the flag only on the dead-coroutine path avoids a false positive for a callback that catches the boundary error and then yields correctly further on.

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

## Error containment

User callback failure is a Job outcome, not an OnUpdate failure.

SchedulerKit:

1. marks the Job `failed`;
2. preserves the exact Lua error object;
3. removes it from active scope ownership;
4. best-effort reports it through WoW's current error handler;
5. continues unrelated scheduler work.

The traceback is captured by `debug.traceback(thread, message)` **before** the job's coroutine reference is dropped. Lua 5.1 does not unwind an errored coroutine's stack, so this is the only point at which the raising frame can still be named.

Internal/native failures that occur in direct API operations may still be re-raised to the direct caller after logical cleanup has been committed. Such a failure is recorded on the job but **not** reported to the error handler, because the direct caller already has it; the same operation reached from the driver, where no caller can observe a raise, reports instead. One failure therefore produces exactly one signal.

## Coalescing family

`Debounce`, `Coalesce`, `Watch` and lanes live in one installer function,
`installCoalescingFamily`, rather than at the top level of the chunk: Lua 5.1
allows 200 locals per function and the main chunk is close to that.

Headroom at revision 8, as `luac -l -l` counts it (declared locals, an upper
bound on the active ones the limit applies to): the main chunk declares 177 of
200 locals; the installer declares 107 locals and uses 41 of 60 upvalues. New
top-level code belongs in the installer or in a function of its own. The
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

## Allocation policy

The normal resume hot path avoids container copies and queue-table replacement.

Expected allocations include:

- one Job table per logical job;
- one Context table per logical job while the job is executable;
- one coroutine per execution/iteration;
- TimerKit's timer object and one TimerKit ownership scope when a SchedulerKit scope first uses delayed/next-frame eligibility;
- SchedulerKit Scope objects when explicitly created.

Terminal jobs clear execution-only references such as their callback, Context, coroutine, and delay handle. A retained Job handle therefore does not unnecessarily retain the callback closure after completion/cancellation/failure.

Scope ownership is two-stage lazy. Loading SchedulerKit allocates neither its package-level convenience scope nor a TimerKit delay scope. Creating a SchedulerKit scope also does not allocate TimerKit ownership state; that happens only when the scope first arms a timer: `NextFrame`, `After` or `Every` work, a `Debounce` or `Coalesce` window, or a lane retry backoff. Immediate-only scheduling therefore stays independent of TimerKit scope allocation after dependency bootstrap.

The coalescing family adds: one handle table (plus two set tables for
`Coalesce`, one or two eight-slot argument tables for `Debounce`, and one
delivery closure when a lane is given) per handle; one TimerKit timer per quiet
window, interval or lane interval; one job per lane submission; one group table
and ticker per distinct watch interval. Recording calls, recording known keys
and steady ticks allocate nothing.

SchedulerKit deliberately does not pool Job objects in API generation 1 because stable user-visible handles and accidental handle reuse are a more serious correctness risk than the potential allocation saving. A future PoolKit may be used for private, non-escaping scheduler internals where identity reuse is safe.
