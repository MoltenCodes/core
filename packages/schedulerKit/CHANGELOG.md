# Changelog

## 0.8.3 — 2026-09-24

Traceback on the Retail client. Implementation revision 15; API generation 1 is unchanged.

- The Retail client publishes no `debug` global (measured on 12.1.0 build 69933, 2026-09-24, by the SchedulerKit client suite), so `debug.traceback` was absent there and `Job:GetErrorTraceback()` returned `nil` in game. A failed job's stack now falls back to the client's `debugstack(thread)` when `debug.traceback` is absent. Its bare stack is prefixed with the error object rendered by `tostring` and a `stack traceback:` header, so both sources give "message, then `stack traceback:`, then the frames", and the error handler receives that text. `debug.traceback` stays the first choice (standard Lua, Busted); with neither, or when the source raises or returns a non-string, the traceback is `nil` and the bare error object is reported, as before.
- The same fallback for failures that are not jobs: a raising `Debounce` or `Coalesce` callback, or `Watch` predicate or callback, is reported through the host error handler with the stack its `xpcall` handler captured, from `debug.traceback(message, 3)` or, on the Retail client, `debugstack(3)` prefixed with the message and `stack traceback:`. Before, the client got the bare error object. Level 3 skips `pcall` and the handler's own frame, so the stack now starts at the raise (`[C]: in function 'error'`) on both sources; with `debug.traceback` the handler frame used to be listed first.
- `debugstack` is resolved once at load, inside the `do` block that defines `captureTraceback` and as an installer local for the `xpcall` handler: no new top-level local (191 of 200 still; the installer declares 111 locals).
- An in-place upgrade from revision 14 needs no state change; jobs, coroutines, timers and handles carry over.
- Docs: `docs/API.md` ("Error isolation") names both sources and the real-client fact, and says what non-job callback reports and lane failures carry; `docs/INTERNALS.md` updates the traceback and headroom notes; `docs/EMBEDDING.md` names `debugstack` in the host-requirements row; `meta/wow/Runtime.lua` declares `debugstack`.
- Specs: new `Traceback_spec.lua` (both sources, `debug.traceback` preferred when both exist, `tostring` rendering, resolution once at load, a raising or non-string `debugstack`, neither source, and a revision-14 upgrade on a host without `debug.traceback`; the `xpcall` handler's report of a raising `Watch` predicate, `Debounce` and `Coalesce` callback with a stub `debugstack` called with level 3, its first frame under `debug.traceback`, a lane submission's `GetErrorTraceback()`, and the bare message when `debugstack` raises or neither source exists; the spec swaps `debug` for a copy without `traceback` while the package loads, since LuaCov needs the global). The client suite's `jobErrors` test accepts the raising frame from either source; `EXPECTED.md` lists the debug-library diagnostic test (37 tests).

## 0.8.2 — 2026-09-24

Nil rule (decision of 2026-09-24). Implementation revision 14; API generation 1 is unchanged.

- Absence of a value that comes from outside SchedulerKit (an argument, an option or `retry` field, a `SetLimits` value, a coalesce key or value, the Registry lookups, the optional Kits `Registry:Find` returns, the frame `CreateFrame` returns) is tested with `type(value) == "nil"`, never by comparing it with `nil`, because comparing a secret value raises inside the Kit instead of at the caller.
- A secret argument a check would compare is refused at the caller's line with `<argument> must not be a secret value`: names, priorities, delays, intervals, budgets, counts, the numeric and boolean options of `Lane`, `Debounce`, `Coalesce` and `Watch`, `SetLimits` values and coalesce keys. A coalesce value is stored, never compared, and a secret one is still accepted. `issecretvalue` is read once at load; a host without it has no secret values. `docs/API.md` lists the messages under "Secret values".
- The facade checks of `CloseAddonScopes`, `SetLimits` and `GetLimits`, and the yield-token check on a raw `coroutine.yield`, test the type before comparing, so a secret receiver or yielded value is never compared.
- No new top-level local: `debug` and `issecretvalue` are read inside `do` blocks (191 of 200 still).
- A new bootstrap spec upgrades the previous revision in place; new `SecretValues_spec.lua`.

## 0.8.1 — 2026-09-24

Audit fixes. Implementation revision 13; API generation 1 is unchanged.

- `Watch`: a result that cannot be compared with the previous tick's (a secret value, or two tables whose `__eq` raises) no longer escapes the tick. It escaped the shared ticker's callback, so every watch after it on the same interval was skipped on every tick; it is now reported once and cancels only its own watch, as a raising predicate does. With `everyTick` no comparison is made.
- The ready queues restart at the front the moment their last entry is popped, not only when a later probe finds them empty, so a job that yields slice after slice reuses slot 1 instead of climbing the indices; the lane occupancy flag is cleared at that point too. Before, a drained `IDLE` lane could keep its flag while the contending lanes stayed busy, and the starvation guard then kept counting resumes although no `IDLE` job waited, which `docs/API.md` rules out. Selection order within and across lanes is otherwise unchanged.
- Re-arming a repeating job's delay, cancelling a delayed job's timer and closing a scope's TimerKit scope no longer allocate a closure for their protected call. Re-arming was the one steady path that did, although the source already said it did not.
- The two always-true drain checks after the queue scans are gone.
- An in-place upgrade from revision 12 needs no state change; jobs mid-yield, armed delays and live handles carry over.
- Docs: `docs/API.md` states what an `Every` iteration allocates, the incomparable-`Watch`-result rule, and that the resume-count ceiling guards the budget clock (not the precise wall clock); `docs/INTERNALS.md` lists every shared-state field, states the current local and upvalue headroom (191 of 200 top-level locals), and no longer anticipates PoolKit for internals.
- Specs: new `Allocation_spec.lua` (the resume path allocates nothing across every priority; a never-drained queue keeps its indices at the front), an incomparable-result `Watch` spec, a `Priority_spec.lua` case for an `IDLE` job arriving after the lane drained, and a revision-12 upgrade spec. `Property_spec.lua` draws its random operations from the high bits of its Park-Miller generator (`math.floor(seed / 65536) % limit`), as timerKit and poolKit now do, because an LCG's low bits cycle quickly. The allocation meter and the older-revision loader each exist once, in `SchedulerKitTestEnv` (`AllocatedKilobytes`, `LoadRevision`), instead of being copied into four and one spec files.

## 0.8.0 — 2026-09-23

- An addon scope now closes at logout whenever LifecycleKit or EventKit is loaded, whatever revisions are paired; 0.7.0 left it open when paired with a LifecycleKit older than 0.5.0 or loaded without LifecycleKit. The first `SchedulerKit:ForAddon(addonName)` decides who calls `CloseAddonScopes`, finding the optional Kits through `Registry:Find`: a LifecycleKit that lists `"schedulerKit"` in `CLOSES_ADDON_SCOPES` (LifecycleKit 0.6.0) makes the call itself; the Kit subscribes nothing and only calls `LifecycleKit:ForAddon(addonName)` once, so an addon that never used LifecycleKit is still closed, and nothing else is subscribed; an older LifecycleKit gets one `OnShutdown` subscription per addon, kept on the scope and disconnected when the scope closes, and it steps aside if a capable LifecycleKit replaced it before logout; without LifecycleKit, one package-level EventKit `PLAYER_LOGOUT` one-shot, in an EventKit scope of SchedulerKit's own, closes every addon scope neither LifecycleKit route covers; with neither, nothing is subscribed and the addon makes the call. The last outcome is examined again at the next `ForAddon`. Documented under "At logout" in `docs/API.md`, including the ordering each case gives.
- LifecycleKit and EventKit are declared under `optionalDependencies`. SchedulerKit still embeds as three files and depends on Registry and TimerKit alone.
- `Scope:Close()` on an addon scope, and `CloseAddonScopes`, release the scope's LifecycleKit subscription.
- Implementation revision 12. Package state gains `logoutConnection` and `logoutEventScope` without a schema change, and the shared dispatch table gains `closeOnShutdown` and `closeOnLogout`, which the subscriptions and the connection resolve when they fire. An in-place upgrade from revision 11 or older routes every carried addon scope as a first `ForAddon` would (after releasing revision 9's own subscriptions, as before); a scope already routed keeps its subscription or connection.
- Specs: new `LogoutCoverage_spec.lua` (the four cases against the real LifecycleKit and EventKit, a LifecycleKit with its capability field removed, subscription release on `CloseAddonScopes` and `Close`, a capable LifecycleKit replacing an older one, connection order against scoped `PLAYER_LOGOUT` listeners, a failing close, re-examination after EventKit or LifecycleKit loads, and upgrades that route, or carry the routes of, an older copy). The test environment gains `LoadEventKit`, `LoadLifecycleKit` and `LoadRevision`.
- `SchedulerKit` API generation 1 is unchanged.

## 0.7.0 — 2026-09-23

- Limits (design constitution, principle 4a). Added `SchedulerKit:SetLimits`, `SchedulerKit:GetLimits()` and the `SchedulerKit.UNBOUNDED` sentinel, modelled on SignalKit. The four former constants become package-wide limits: `maxLanes` (32, `UNBOUNDED` accepted), `maxWatchIntervals` (32, at most 256, `UNBOUNDED` refused: one TimerKit ticker each), `maxWatchersPerInterval` (128, `UNBOUNDED` accepted) and `maxDebounceArguments` (8, at most 64, `UNBOUNDED` refused: the slot is reused per handle). `SetLimits` validates the whole table at the caller's line before applying any of it; `GetLimits` returns a fresh table. The 33rd lane and the ninth debounce argument can now be opened.
- A debounce call of more than eight arguments is recorded into the handle's reused slot and delivered in full, directly or through a lane; such a fire allocates one table and one closure, while calls of eight or fewer stay allocation-free.
- Implementation revision 11. The sentinel and the limits live in package state; older state is seeded with the former constants. `UNBOUNDED`, `SetLimits` and `GetLimits` join the public-surface check. Refusal messages now name the limit to raise.
- New `Limits_spec.lua` and a bootstrap spec for seeding revision-10 state. `docs/API.md` gains a "Limits" section.

## 0.6.0 — 2026-09-23

- SchedulerKit no longer requires LifecycleKit (design constitution, principle 4b). The manifest lists Registry API 2 and TimerKit API 1 only, the load-time LifecycleKit facade check is gone, and SchedulerKit embeds as three files: Registry, TimerKit and SchedulerKit. It never used SignalKit or EventKit, so neither is in its closure any more.
- `SchedulerKit:ForAddon(addonName)` still returns one canonical scope per addon, but no longer subscribes to the addon's shutdown. Added `SchedulerKit:CloseAddonScopes(addonName)`, the second half of the two-step EventKit and TimerKit use: it closes the addon's scope exactly as `Scope:Close()` does, returns `false` when the addon never had a scope (recording nothing) or it was already closed, and must be called on the facade. LifecycleKit 0.5.0 makes the call at shutdown; without LifecycleKit an addon calls it on `PLAYER_LOGOUT`.
- Behaviour change for an addon that asks for its scope after its lifecycle already shut down: revision 9 handed back a closed scope, this revision hands back an open one until `CloseAddonScopes` is called.
- Implementation revision 10. An in-place upgrade from revision 9 or older disconnects the LifecycleKit shutdown subscription each carried addon scope held (best-effort) and keeps the scopes and their work running. `CloseAddonScopes` joins the public-surface check.
- Specs: the module chain is Registry, TimerKit and SchedulerKit. `Scope_spec.lua` covers the two-step by hand, terminal closure, unknown addons, a job closing its own addon scope, isolation and the facade receiver; the logout integration moved to LifecycleKit's suite. A new bootstrap spec covers the revision-9 upgrade, and `ErrorLevels_spec.lua` the new method's argument and receiver errors.
- `SchedulerKit` API generation 1 is unchanged; the addition is compatible.

## 0.5.3 — 2026-09-23

- The driver pass no longer declares the elapsed-seconds parameter the OnUpdate
  driver hands it; the pass measures its own CPU time and never read it. This
  removes the last unused local the language server reported.
- Implementation revision 9. The executed bootstrap is unchanged apart from the
  constant; an older embedded copy upgrades in place as before.

## 0.5.2 — 2026-09-23

Documentation and annotation corrections from the phase 4 audit. No runtime
behaviour change: `IMPLEMENTATION_REVISION` stays 8, and `luac -s -l` produces an
identical instruction listing before and after.

- `docs/API.md`: the addon-scope shutdown and package-level scope sections now
  say that they also release `Debounce`, `Coalesce` and `Watch` handles and lane
  submissions; the lazy TimerKit scope is also allocated by a `Debounce` or
  `Coalesce` window or a lane retry backoff, not only by `NextFrame`, `After` and
  `Every`; the WoW driver boundary lists `GetTimePreciseSec` as the family's
  clock, not only a fallback, and names `geterrorhandler`; `Close()` and
  `Cancel()` document their `false` return when already closed; a closed
  `Coalesce` handle returns `false`, and its interval may be `0`.
- `docs/INTERNALS.md`: the same lazy-scope correction, and scopes created by
  any revision before 7, not only revision 6, carry no member links.
- LuaCATS: both `Flush` methods return `"deferred"|"dropped"` as their reason;
  `SchedulerKit.CoalesceCallback` states that a set delivered through a lane
  lives until the lane job ends; `maxInFlight` counts admitted submissions,
  including those waiting out a retry backoff.
- One new spec: a full or closed lane refuses `Submit` without allocating, as
  `docs/API.md` promises.

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
