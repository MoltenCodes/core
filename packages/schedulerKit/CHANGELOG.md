# Changelog

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
