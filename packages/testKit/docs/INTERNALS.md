# TestKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`TestKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `dispatch` | `runnerBody`, `phaseReached`, `phaseLost`, `deadlineReached`, `eventArrived`, `waitTimedOut`; every closure TestKit hands out calls through it. |
| `runtimeRevision` | The revision that last committed its functions. |
| `suitePrototype`, `contextPrototype`, `matcherPrototype` | The method tables suites, contexts and matchers index. |
| `suiteMetatable`, `contextMetatable`, `matcherMetatable` | Their metatables; `__index` is the matching prototype. |
| `yieldTokens` | `{ frame, wait, nextFrame }`: the unique values a test step yields to the runner. Kept in state so that a step suspended under one revision is understood by the next. |
| `suites`, `suitesByName` | Registered suites in order, and by name. |
| `finishedCallbacks` | `OnFinished` callbacks, at most `maxFinishedCallbacks` (16 by default). |
| `queue` | Run entries whose phase was reached, in arrival order. |
| `waiting` | Run entries still waiting for their phase. |
| `activeEntry`, `activeTest` | The entry being executed and its current test record, or `false`. |
| `runActive` | Whether a run has started and not finished. |
| `executing` | `true` while a test step is on the stack; `Reset` refuses then. |
| `runnerJob` | The scheduled or running SchedulerKit job, or `false`. |
| `schedulerScope`, `timerScope`, `eventScope` | Kit-owned scopes, created on first use and replaced when closed from outside. |
| `runnerCallback` | The one SchedulerKit callback every runner job shares. |
| `deadlineCallback` | The one TimerKit callback every test deadline shares; the test record travels as timer user data. |
| `unbounded`, `limits` | The `UNBOUNDED` sentinel and the package-wide limits `SetLimits` writes (revision 2; revision-1 state is seeded with the defaults). |

## Suite layout

A suite is one table whose private fields all exist from `Suite` on:

| Field | Meaning |
|---|---|
| `_schema` | The suite layout version, `1`. |
| `_name`, `_phase`, `_addonName`, `_timeoutSeconds` | Identity and options with defaults applied. |
| `_tests`, `_testIndex` | Test records `{ name, fn, skipReason }` in order (`fn` is `false` for a skipped test, `skipReason` `false` otherwise), and name to position. |
| `_before`, `_after` | Hook arrays. |
| `_results`, `_resultIndex` | Result records in registration order of their first run, and name to position. `Reset` replaces both. |
| `_entry` | The suite's pending run entry, or `false`; what makes `Run` skip a suite already queued. |

## The runner state machine

A **run entry** is one queued run of one suite: `{ suite, testName, status, nextIndex, subscription, lostWatches }`. Its status moves:

```text
            Run                phase reached (replayed or dispatched)
  (none) ───────▶ waiting ─────────────────────────────▶ queued
                     │                                      │ advance() takes it
                     │ subscription already disconnected,   ▼
                     │ or OnHalted / OnShutdown fired       running
                     └──────────────▶ done ◀──────────────── │
                         (tests recorded "skipped")   last test finished
```

`Reset` moves every entry to `done` from any state.

The **runner** is one SchedulerKit job at a time. Its body loops:

```text
            ┌──────────────── activeTest? ────────────────┐
            │ no                                          │ yes
            ▼                                             ▼
   advance(): next test of activeEntry,          stepTest(record)
   or the next queued entry                        │
     │ started a test / recorded a skip /          ├─ continue ─▶ loop
     │ finished an entry ──▶ loop                  ├─ yield ────▶ schedulerContext:Yield(), loop
     │ nothing to do                               ├─ wait ─────▶ job ends; an event or timer wakes it
     ▼                                             ├─ nextFrame ▶ job ends; NextFrame job scheduled
   job ends; finishRunIfSettled()                  └─ done ─────▶ finishTest(); yield if over budget; loop
```

`finishRunIfSettled` ends the run (and calls `OnFinished`) only when there is no active test, no active entry, nothing queued and nothing waiting.

`scheduleRunner(nextFrame)` does nothing while `runnerJob` is pending, so any number of wake-ups coalesce into one job. The body sets `runnerJob` to `false` before it returns, so a wake-up after that schedules a fresh job.

## Test records and steps

`beginTest` builds one record per executed test:

| Field | Meaning |
|---|---|
| `entry`, `result`, `context` | The entry, the result record being filled, and the context handed to every step. |
| `steps`, `stepCount`, `afterStart`, `stepIndex` | Before hooks, the body and After hooks as one array; the index of the first After hook; the current step. |
| `coroutine` | The current step's coroutine, or `false` between steps. |
| `waiting` | Whether the step is suspended in `WaitFor` or `WaitUntil` with no job running. |
| `timedOut`, `deadline` | Whether the current window ran out, and the TimerKit timer measuring it. |
| `startedAt` | `GetTimePreciseSec` in milliseconds, or `false`. |
| `replacements`, `replacementCount` | `Replace` records as flat triples `(table, key, previous)`, so a `nil` previous value needs no sentinel; at most `maxReplacements` (256 by default) per test. |

`stepTest` resumes the current step once:

- a step that raised records a failure; a failed step before `afterStart` jumps to `afterStart`, one after it moves to the next After hook;
- a step that returned moves to the next step;
- a step that yielded a token becomes an outcome (`yield`, `wait`, `nextFrame`); any other yielded value fails the test;
- when `timedOut` is set, the suspended step is dropped (`abandonStep`) and the next resume moves on. Before `afterStart` that jump lands on the first After hook and re-arms the deadline; past it `timedOut` stays set, so every remaining After hook is abandoned in turn without being started (the first failure is the one recorded).

`finishStep` re-arms the deadline when the step index crosses `afterStart`, which is what gives After hooks their own window. `recordFailure` keeps the first failure only.

`finishTest` restores replacements newest first, clears the deadline's user data, releases every connection and timer in the Kit-owned EventKit and TimerKit scopes (`DisconnectAll`, `CancelAll`), deactivates the context, measures the duration and stores the result.

## Waits

`WaitFor` builds a waiter `{ record, fired, timedOut, payload, count }`, connects `Once` in the Kit-owned EventKit scope and starts `After` in the Kit-owned TimerKit scope; both closures call `dispatch.eventArrived` or `dispatch.waitTimedOut`. The step then loops `coroutine.yield(yieldTokens.wait)` until one flag is set. `wake(record)` schedules the runner only while the record is the active test and marked `waiting`, so a late callback of an abandoned step, or a callback that fires while the step is still running, is harmless: the loop simply re-checks its own flags.

`WaitUntil` yields `yieldTokens.nextFrame`; the runner ends its job and schedules the next one with SchedulerKit `NextFrame`, so the predicate is polled once per rendered frame without an `OnUpdate` of TestKit's own.

## Why each step is its own coroutine

A test body must be protected (a failure is a result, not a crash) and must be able to yield. In Lua 5.1 `pcall` is a C boundary a coroutine cannot yield across, so the runner cannot wrap steps in `pcall` inside the job. Instead each step runs in a coroutine the runner resumes: `coroutine.resume` catches the error, and a yield returns to the runner, which then yields the SchedulerKit job itself (outside any `pcall`) or ends it.

## Phase gating

`startEntry` subscribes the entry to `LifecycleKit:ForAddon(addonName):OnLoaded` or `:OnReady` with a closure that calls `dispatch.phaseReached(entry)`. LifecycleKit replays a phase already reached synchronously, so the entry may be queued before `startEntry` returns. When it is still waiting and the returned subscription is already disconnected, LifecycleKit has declared the phase impossible, and the entry's tests are recorded as skipped with the cause `GetState()` names.

A halt or shutdown *later* disconnects the pending phase subscription without calling it, so a waiting entry also holds `lostWatches`: an `OnHalted` and an `OnShutdown` subscription whose closures call `dispatch.phaseLost(entry, cause)`. `phaseLost` skips the entry and schedules the runner, which finds nothing to run and finishes the run. `phaseReached`, `phaseLost` and `abortRun` release the watches. An entry queued by an older revision has no `lostWatches` field and is treated as having none.

## Secret values

`isSecret` reads `issecretvalue` from the global table on every call, so the probe a test installs with `Replace` is honoured. Every value that reaches a message goes through `describeValue` or `describeMessage`, which ask `isSecret` first and never call `tostring` on a table. Comparisons check `isSecret` before any equality test, because a secret compared with a value of its own type raises in the client (`rawequal` included); an absent argument is told apart with `type(value) == "nil"` rather than `value == nil` by the repository rule, which never compares anything (a comparison with `nil` happens not to raise; measured on Retail 12.1.0 b69933). `compareValues` returns a third value, `secret`, so that `ToEqual` can fail a comparison a secret made impossible even under `Not`.

## Closures and upgrades

TestKit hands out six kinds of closure: `state.runnerCallback` (one for the package), `state.deadlineCallback` (one for the package), one phase callback and two halt/shutdown watch callbacks per run entry, and one event and one timeout callback per wait. Each calls through `dispatch` at call time, so a newer revision's functions run behind closures an older one created. Suites, contexts and matchers keep the metatables stored in state, and the prototypes are rewritten in place.

A runner job that is suspended in `schedulerContext:Yield()` during an upgrade finishes its current loop on the older code, because Lua cannot swap a running function; the next job runs the new `runnerBody`. A suspended test step is a coroutine of consumer code and is unaffected.

The upgrade spec loads the same source again with `IMPLEMENTATION_REVISION` raised by one while one test waits in `WaitFor` and another suite waits for its phase, and checks that both finish and the run reports them. Four further specs load the source as revision 1, 2, 3 and 4 and upgrade each with the current file: revision 2 seeds the limits into revision-1 state, and revisions 3, 4 and 5 keep revision-2 state as it is.

## Error levels

Every argument validator takes an explicit `level`, the value `error` needs *inside the function that receives it*; each further hop adds one. Public methods pass `3` to a validator and raise their own errors at `2`. Matcher methods end in `conclude`, which raises at level 3 (conclude, the matcher, the test); it is called as a statement, never as `return conclude(...)`, because a Lua 5.1 tail call would remove the matcher's frame and the message would lose its position.
