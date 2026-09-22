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
    ├── addonScopes
    ├── defaultScope
    ├── Job / Scope / Context metatables
    ├── Frame driver + trampoline
    └── configuration
```

Existing Jobs, Scopes, Contexts, queues, and the installed Frame trampoline therefore survive a compatible revision upgrade.

The Frame trampoline and delayed TimerKit wakeups resolve operations through `_state.dispatch`. They do not permanently pin scheduler behavior to the source revision that originally created them.

## Ready queues

Each priority owns an array-backed FIFO queue with `head`/`tail` indices.

Dequeuing clears consumed array slots to release references immediately. When a queue becomes empty, only its indices are reset; the backing table is reused rather than allocating a new table on every drain.

Cancellation is lazy with respect to queue position:

1. the Job is marked non-queued/terminal immediately;
2. an existing stale queue node is harmless;
3. queue traversal skips and clears stale nodes when encountered.

This avoids O(n) removal from the middle of an array on `Job:Cancel()`.

## Weighted fairness

Ready selection uses this repeating service sequence:

```text
HIGH HIGH HIGH HIGH NORMAL NORMAL LOW IDLE
```

The cursor is stored in shared state and is **not reset at frame boundaries**. Preserving the cursor is what turns the sequence into starvation-resistant weighted service instead of repeatedly favoring the beginning of the sequence every frame.

FIFO is preserved independently inside each lane.

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

`GetTimePreciseSec()` is converted to milliseconds for budget accounting. The scheduler records one deadline per OnUpdate pass.

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

A delayed TimerKit logical handle stores two private fields:

```text
__schedulerKitJob
__schedulerKitGeneration
```

All delays share one SchedulerKit wake callback rather than allocating a new callback closure for every repeat interval. The wake callback clears those fields before dispatching, then resolves the current implementation through shared `_state.dispatch`.

Logical generations protect against stale delayed callbacks after cancellation.

## Error containment

User callback failure is a Job outcome, not an OnUpdate failure.

SchedulerKit:

1. marks the Job `failed`;
2. preserves the exact Lua error object;
3. removes it from active scope ownership;
4. best-effort reports it through WoW's current error handler;
5. continues unrelated scheduler work.

Internal/native failures that occur in direct API operations may still be re-raised to the direct caller after logical cleanup has been committed.

## Allocation policy

The normal resume hot path avoids container copies and queue-table replacement.

Expected allocations include:

- one Job table per logical job;
- one Context table per logical job while the job is executable;
- one coroutine per execution/iteration;
- TimerKit's timer object and one TimerKit ownership scope when a SchedulerKit scope first uses delayed/next-frame eligibility;
- SchedulerKit Scope objects when explicitly created.

Terminal jobs clear execution-only references such as their callback, Context, coroutine, and delay handle. A retained Job handle therefore does not unnecessarily retain the callback closure after completion/cancellation/failure.

Scope ownership is two-stage lazy. Loading SchedulerKit allocates neither its package-level convenience scope nor a TimerKit delay scope. Creating a SchedulerKit scope also does not allocate TimerKit ownership state; that happens only when the scope first schedules `NextFrame`, `After`, or `Every` work. Immediate-only scheduling therefore stays independent of TimerKit scope allocation after dependency bootstrap.

SchedulerKit deliberately does not pool Job objects in API generation 1 because stable user-visible handles and accidental handle reuse are a more serious correctness risk than the potential allocation saving. A future PoolKit may be used for private, non-escaping scheduler internals where identity reuse is safe.
