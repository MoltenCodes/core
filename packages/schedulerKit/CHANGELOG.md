# Changelog

## 0.5.1 — 2026-09-23

Fixes from the acceptance review of 0.5.0.

- A `Debounce` re-delivery that met a full lane swapped the refused, older arguments back over a newer burst, so the newest call was never delivered. The newer burst now supersedes them and the refused arguments are discarded.
- `Flush()` on a `Coalesce` handle whose previous set is still in its lane claimed success while deferring; it now returns `false, "deferred"`. Both `Flush()` methods return `false, "deferred"` or `false, "dropped"` when a lane does not take the delivery.
- `Close()` on a `Debounce` or `Coalesce` handle cancelled its lane delivery even after the lane admitted it. It now cancels only a delivery still waiting for admission and lets an admitted one finish, matching the lane's own drain rule; closing the scope still cancels both.
- A `Debounce` handle could get stuck after TimerKit failed to arm its timer: it stayed "waiting" with no timer, and later calls only marked a fire owed. The failure is now reported, the handle goes idle with the fire kept, the next call opens a new window, and `Flush()` delivers an owed fire even when no window is open.
- Lane retries now honour `minIntervalSeconds`: a retry waits at least until the interval has passed since the lane's last start, and counts as a start when its backoff expires. `Lane:Close()` cancels admitted jobs still waiting out a retry backoff, and an attempt that raises after `Close()` fails instead of retrying.
- Computed waits in the lane pump and in `Debounce` are clamped to the interval or delay they came from, so a clock stepping backwards cannot stretch them.
- A raising `Watch` callback is reported with a traceback, like a raising predicate. The lane FIFO restarts its indices whenever it drains.
- Documentation: a closed lane's refusal is counted by the lane and by a `Coalesce` handle, not by a `Debounce` handle; a `Coalesce` set delivered through a lane lives until the job's terminal state, across retries; a NaN predicate result changes on every tick; `INTERNALS.md` records the local and upvalue headroom.
- Implementation revision 8. Lanes gain an admitted-job set, created on first use for a lane that revision 7 made. 13 new specs: 11 for the fixes, the member-close spec split into its waiting and admitted cases, and the revision-7 upgrade.

## 0.5.0 — 2026-09-23

- Added the coalescing family, designed as one thing with EventKit's `Coalesce` and `Derive` and documented together in `docs/API.md` under *Coalescing and lanes*:
  - `Debounce(callback, delaySeconds, options)` returns a callable handle that runs `callback` once a burst of calls goes quiet, with the last call's arguments kept in a reused eight-value slot. Options `leading`, `maxWaitSeconds` and `lane`; methods `Cancel`, `Flush`, `IsPending`, `Close`, `IsClosed`. A call inside an open window only records a clock reading; the timer re-arms once, for the remainder, when it wakes early.
  - `Coalesce(callback, intervalSeconds, options)` returns a callable handle that collects keys: the first key starts the interval and `callback(set)` runs once at its end with everything collected. The set is one of two reused tables, emptied as soon as the callback returns. `maxKeys` (default 256) refuses new keys past the bound and counts them in `GetStats()`.
  - `Watch(predicate, intervalSeconds, callback, options)` polls on one TimerKit ticker per interval shared by every watch of that interval; the callback runs on the first tick and on every change, or on every tick with `everyTick`. At most 128 watches per interval and 32 distinct intervals. A raising predicate is reported once and its watch cancelled.
  - `Lane(name, options)` returns a lane shared by name across the session (at most 32 open): `maxInFlight`, `minIntervalSeconds`, `retry = { attempts, backoffSeconds, multiplier, maxBackoffSeconds }` and `maxQueued` (default 64). `lane:Submit(callback, options)` runs `callback` as an ordinary job under those limits and returns the job, or `nil, "full"` / `nil, "closed"` without allocating. A raising submission with attempts left is retried after an exponential backoff and keeps its slot; only the final failure is reported. `GetStats()`, `GetName()`, `Close()` (cancels waiting submissions, drains admitted ones), `IsClosed()`.
  - `options.lane` on `Debounce` and `Coalesce` hands every fire to the lane as a job, so the family shares one throttling vocabulary. A full lane defers a fire; a closed lane drops it, counts it and reports it.
- `scope:Debounce`, `scope:Coalesce` and `scope:Watch` mirror `scope:Schedule`. `CancelAll()` drops pending fires (handles stay usable) and cancels watches and the scope's lane jobs; `Close()` closes everything, so ModuleKit's `module.scope.Jobs` releases the family on disable.
- Every due time uses `GetTimePreciseSec`, the clock TimerKit's deadlines use; every timer is a TimerKit timer. Recording calls and known keys, and steady watch ticks, allocate nothing; specs guard each.
- Implementation revision 7. Shared state gains the lane registry, the watch groups, a package-internal TimerKit scope and one metatable and method table per handle kind; a copy loading over revision 6 adds them in place, and older scopes gain the new methods. The family lives in one installer function because the main chunk was near Lua 5.1's 200-local limit.
- 52 new specs: Debounce (14), Coalesce (9), Watch (12), lanes and lane delivery (15), and the revision-6 upgrade and live-reload cases (2).
- `SchedulerKit` API generation 1 is unchanged; the additions are compatible.

## 0.4.0 — 2026-09-22

- The frame budget is no longer defeated by a resettable clock. `debugprofilestop` reports one process-wide timer that any addon can zero with `debugprofilestart()`, and the budget was a single absolute deadline computed at the start of the pass. After a restart every later reading fell below that deadline, the budget check never fired, and the pass ran to the resume-count ceiling instead: a thousand resumes against a 2 ms budget, in one frame.
- Frame accounting is now monotonic. Each budget check remembers the previous reading; forward movement is spent as budget, and a backwards jump re-anchors the deadline to the new reading while carrying the budget left at the last good reading. A restart can neither extend a frame nor refund what it already spent, and a large forward jump simply ends the frame early, which is the safe direction. `Context:ShouldYield()` shares the same accounting, so a restart cannot leave a cooperating job believing it still owns the frame.
- The runaway yielded-slice measurement is protected the same way. The raw difference between readings either side of a restart is negative, so a slice that burned fifty milliseconds used to measure as free and escape demotion. The finishing reading is the time since the restart, and that lower bound is now used as the slice's duration.
- Documented the shared-clock hazard in `docs/API.md` under *The profiling clock is shared*, and the "do not call `debugprofilestart()`" rule in the framework's `docs/EMBEDDING.md` performance guidance.
- Implementation revision 6. Package state carries the previous clock reading beside the frame deadline; state written by an older revision is seeded rather than rejected, and the inherited deadline is left untouched so a copy loading while the older one drives a frame does not have that frame pulled out from under it.
- Five regression specs: a neighbour zeroing the clock mid-frame, the remaining budget carried across a backwards jump, a forward jump, `ShouldYield()` after a reset, and a runaway slice that restarted the profiler. The shared test fixture gained `SetProfileMs` to drive them.
- No public API change. `SchedulerKit` API generation 1 is unchanged.

## 0.3.0 — 2026-09-22

- Moved the bootstrap handshake onto `Registry:Bootstrap`. The package lookup, the refusal to reinterpret a newer revision's private state, the registration and the inherited-revision reporting now live in Registry; what stays here is the dependency check, the public-surface predicate, the state predicate and the migration itself.
- Registry is now resolved as `MoltenCodes.Registries[2]` with the `MoltenCodes.Registry` alias as the fallback. The alias belongs to the newest Registry generation loaded, so an eventual API 3 would otherwise hand this file a contract it was not written against.
- `Context:ShouldYield()` and `Context:Yield()` raised their "may only be called while its job is running" guard at level 3, which pointed at the caller's caller rather than at the line that made the call. Both now raise at level 2, and a regression spec pins the reported position. Left over from the phase 1 error-level audit.
- Implementation revision 5. The executed bootstrap changed, and an older embedded copy upgrades in place exactly as before; the package's bootstrap specs cover the upgrade, the retired-state and corrupted-facade refusals, and the load-order cases.
- No public API change. `SchedulerKit` API generation 1 is unchanged.

## 0.2.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 74 annotation lines became 268. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed the LuaCATS types to `SchedulerKit`, `SchedulerKit.Job`, `SchedulerKit.Scope`, `SchedulerKit.Context`, `SchedulerKit.Priority`, `SchedulerKit.JobState` and `SchedulerKit.ScheduleOptions`, and added the `SchedulerKit.Callback` alias.
- Annotated the queue, driver, delay and execution internals, including the `SchedulerKit.Queue` lane shape and the `SchedulerKit.ErrorRecord` wrapper.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.2.0 — 2026-09-22

- Measured the frame budget and the runaway threshold in addon CPU milliseconds (`debugprofilestop`) instead of wall-clock time. A garbage-collection pause or client hitch used to be charged to whichever job happened to be running, so a perfectly cooperative job could be flagged as a runaway for a stall it did not cause. `GetTimePreciseSec` remains the documented fallback for a host without the CPU clock.
- Stopped failing a job that exceeded the runaway threshold **and then yielded**. Such a job kept its side of the cooperative contract, so it is now demoted one priority lane and the overrun is reported through `geterrorhandler`, instead of being killed and losing work the consumer cannot resume. Demotion stops at `IDLE`.
- Detected the Lua 5.1 yield hazard: `Context:Yield()` cannot suspend across a `pcall`, `xpcall`, metamethod, `table.sort` comparator, or `string.gsub` callback. A job that swallowed that error previously ran to completion having never surrendered the frame — a silent budget violation. `Yield()` now records the request and the driver reports a slice that ended without the promised suspension, failing the job when that slice also outran the runaway threshold. The rule is documented under *Cooperative execution*.
- Captured `debug.traceback` against the failing coroutine while its stack is still intact, and added `Job:GetErrorTraceback()`. The host error handler now receives the traceback rather than the bare error value; `Job:GetError()` still returns the original error object unchanged.
- Made `IDLE` mean what it says. It previously received a guaranteed 1/8 share of the weighted sequence, the same as `LOW`. `IDLE` now runs only when no `HIGH`, `NORMAL`, or `LOW` job is ready, bounded by a starvation guard that promotes one IDLE job after 256 consecutive resumes of contending work. `HIGH`/`NORMAL`/`LOW` keep their 4:2:1 ratio.
- Replaced the private fields SchedulerKit wrote onto TimerKit timer handles with TimerKit's public `SetUserData`/`GetUserData` seam, so cross-package behaviour uses a public API as `docs/ARCHITECTURE.md` requires. Staleness is now decided by handle identity; the delay-wake dispatch contract is unchanged, so a delay armed before a live upgrade still wakes correctly.
- Stopped reporting an arming failure twice. `SchedulerKit:After` raising to its caller no longer also pushes the same failure to `geterrorhandler`; the repeat re-arm path, where nothing can observe a raise, reports instead. One failure now produces exactly one signal.
- Skipped empty priority lanes during ready selection using per-lane occupancy bookkeeping. Selection order and per-lane FIFO are unchanged; a single-`LOW`-lane workload dropped from 8 queue probes per selection to 1 (200 000 resumes: 0.540 s → 0.345 s).
- Added a table-of-contents header block to `src/SchedulerKit.lua`, and covered two previously untested paths: a job closing its own scope mid-run, and an `Every` job whose scope closes during its callback.

## 0.1.3 — 2026-09-22

- No runtime behaviour change. Revision 3 still describes the shipped implementation.
- Removed a duplicate `defaultScope` key from the initial package-state constructor. Both entries assigned `false`, so the constructed state is identical; the table simply no longer assigns the same field twice.
- Pointed the test-support helpers at luassert explicitly and made the `CreateFrame` stub raise a plain error when asked for a frame type it does not model. Busted injects luassert into spec chunks only, so the support module previously failed on Lua's own `assert` global.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.2

- Rejected non-finite `maxResumesPerFrame` values so the hard per-frame safety ceiling cannot be disabled accidentally with `math.huge`.
- Made each SchedulerKit scope allocate its TimerKit delay scope lazily, so immediate-only scheduling avoids an unnecessary scope allocation and TimerKit failure surface.
- Removed unused internal job IDs and runtime-revision bookkeeping that had no observable or diagnostic purpose.
- Hardened precise-clock validation against non-finite host values.

## 0.1.1

- Fixed cooperative self-cancellation so `Context:Yield()` preserves the `cancelled` state instead of converting the job to `failed`.
- Made the package-level TimerKit scope lazy, eliminating an unnecessary bootstrap allocation and a host-failure point after Registry revision acceptance.
- Released callback/context execution references when jobs become terminal to reduce closure retention for long-lived job handles.
- Hardened duplicate-load validation to accept the intentionally uninitialized lazy default scope.

## 0.1.0

- Added SchedulerKit API generation 1.
- Added weighted `HIGH` / `NORMAL` / `LOW` / `IDLE` priority scheduling.
- Added cooperative coroutine jobs with frame-budget-aware contexts.
- Added delayed and fixed-delay repeating work through TimerKit.
- Added manual and LifecycleKit-owned cancellation scopes.
- Added callback error isolation and job diagnostics.
- Added runaway-slice and per-frame resume safety limits.
- Added compatible embedded-copy runtime dispatch and identity preservation.
