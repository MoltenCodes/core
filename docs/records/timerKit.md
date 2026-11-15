# timerKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## timerKit pausable timers (W15)

**timerKit pausable timers (W15)** — an addition to facade `TimerKit`

1. Package `timerKit`, facade `TimerKit`, API generation 1 (additive),
   version 0.8.0, implementation revision 12.
2. Purpose: pause a running timer and resume it later with what was left
   of its delay, what worklist item W15 asked of an "engine-driven
   pausable ticker". Recorded deviation: it is built on `C_Timer` handles,
   not on an animation host. `Pause` cancels the host handle and keeps the
   remainder; `Resume` asks the host for a fresh one-shot of that
   remainder, and a repeating timer returns to its interval after that
   first fire. TimerKit therefore stays registry only, with no frame and
   no per-frame work. Non-goals: frame-accurate ticks, per-frame updates
   (BarKit draws timer bars), pausing a whole scope.
3. Dependencies: unchanged, registry API 2. `GetTimePreciseSec` measures
   the remainder; without it a paused timer keeps its full delay.
4. Surface: `timer:Pause()` → `true`, or `false` unless it was running;
   `timer:Resume()` → `true`, or `false` unless it was paused (a closed
   scope has cancelled its paused timers, so `Resume` then answers
   `false`); `timer:IsPaused()`. `GetState` may answer
   the new state `"paused"`; `GetRemaining` answers the kept remainder
   while paused, `GetDeadline` `nil`, `IsPending` `false`. `Start` on a
   paused timer answers `false`; `Cancel`, `Restart`, `CancelAll` and
   `Close` treat a paused timer as running.
5. Ownership: a paused timer stays in its scope's active set, so
   `GetActiveCount` counts it and `CancelAll` and `Close` cancel it. Pausing
   unbinds the host callback first, so a stale callback never fires a paused
   timer.
6. Performance and memory: `Pause` is one host `Cancel`, `Resume` one host
   constructor and one closure. The remainder is kept in the timer's
   existing `_deadline` field, so pausing adds no field and never rehashes
   the timer. Nothing new on the start, cancel or fire paths of a timer
   that is never paused.
7. Tests: pause and resume of one-shot and repeating timers with exact
   remainders, a repeating timer back on its interval, a stale callback of
   the paused handle ignored, pause without a clock, the methods' `false`
   answers, cancel, restart, `CancelAll` and `Close` of a paused timer,
   resume after a closed scope, receiver errors at the caller, an upgrade from
   revision 11 keeping timers and a timer paused after it.
8. Docs: API.md (pausing, the state table, the methods), INTERNALS.md (the
   `_deadline` field while paused, the resume closure), CHANGELOG, README,
   tests/README; Package I's deferred item and package M's checklist.
9. Status: implemented 2026-11-15 under core decision 15, 0.8.0, revision
   12, 12 specs. No client suite: pausing uses only `C_Timer` handles the
   existing TimerKit client suite already proves.
   Reviewed 2026-11-15 under core decision 17: 0.8.1, documentation only;
   the client suite gains a `pause` test.

**Further work, decided 2026-11-15 under core decision 16.** The owner asked
to finish the remaining roadmap work before the real-client runs, which come
last: the LibDualSpec counterpart, a ScrollBox list, range checking, a unit
frame finder, and `C_EncodingUtil` where it gains performance, plus W13's
deprecation warnings (W14's frameKit is folded into widgetKit's anchors).
Each record below was researched from Blizzard's UI source, the client API
documentation and the libraries it replaces (ideas only), written before its
code and treated as agreed as under decision 15.

- [x] **clientKit** deprecation warnings (W13) (2026-11-15; client suite not run).
- [x] **settingsKit** spec profiles, with OptionsKit's `ProfileOptions` choice: settingsKit 0.4.0 revision 11, optionsKit 0.6.0 revision 11 (2026-11-15; client suites not run).
- [x] **widgetKit** virtualised lists (`ScrollList`): widgetKit 0.4.0 revision 12 (2026-11-15; client suite not run).
- [x] **rangeKit** — unit range estimates (2026-11-15; client suite not run).
- [x] **unitFrameKit** — the unit frame shown for a unit (2026-11-15; client suite not run).
- [x] **codecKit** native DEFLATE through `C_EncodingUtil`: compression only, codecKit 0.2.0 revision 7 (2026-11-15; client suite not run).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## timerKit (package O): fixed-cost trims, the probe rule, scope reopening and method-name callbacks

**timerKit (package O): fixed-cost trims, the probe rule, scope reopening and method-name callbacks** — a change to facade `TimerKit`

1. Package `timerKit`, facade `TimerKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.2), implementation revision 14 (from 13).
2. Purpose: close the measured gap to AceTimer-3.0 on the start, cancel
   and fire paths (the decision 18 diagnosis,
   section timerKit, prototype the diagnosis prototype),
   apply package O's secret-probe rule, give ModuleKit a way to keep a
   module's timer scope across enable cycles (`Scope:Reopen`, see the
   moduleKit record), and add Ace3's method-name callback form under core
   decision 19c. The fixes:
   - **One-frame start.** `Scope:After` and `Scope:Every`, and the
     package-level `TimerKit:After` and `TimerKit:Every`, test the receiver,
     the closed state, the callback, the delay (`delay >= 0 and delay <
     HUGE`, which also refuses NaN and infinity; `> 0` for `Every`) and the
     probe in one condition, then build, arm and record the timer inline.
     When any test fails they hand over, with a non-tail call, to the
     existing `startTimerInScope`, which raises the same message at the
     caller's line as today.
   - **One-frame cancel.** `Timer:Cancel` holds the cancel body inline.
   - **One-frame fire.** `dispatch.fireStarted` merges the stale-callback
     check with the delivery (no `dispatchFire` → `fireTimer` →
     `deliverTimer` → `detachActive` chain on the hot path).
   - **No `type()` before the private-metatable checks** (`TimerKit.lua`
     `:574`, `:583`, `:1011`, `:1408`, `:1708`): `getmetatable(x) ~=
     METATABLE` already refuses everything but a record, because the
     metatable's `__metatable` field hides it from foreign code.
   - **`_userData` layout.** The constructors stop naming `_userData =
     nil`. A one-shot timer stays at 8 hash nodes either way (a wasted store
     only); a repeating timer drops from 16 nodes to 8, and the first
     `SetUserData` on a repeating timer pays the one rehash instead of every
     repeating timer paying the larger table.
   - **Probe rule.** `issecretvalue` is resolved once at load (today, too,
     at `:445`); when it was absent at load, each check reads
     `rawget(_G, "issecretvalue")` and accepts it only as a function, so a
     probe installed later is honoured (today it never is).
   - **Method-name callbacks (decision 19c).** `After(delay, receiver,
     methodName)` and `Every(interval, receiver, methodName)` on scopes and
     on the facade, the counterpart of AceTimer's
     `self:ScheduleTimer("Method", delay)`. The method is looked up once, at
     the call: `receiver` must be a table, `methodName` a non-empty,
     non-secret string, and `receiver[methodName]` a function, or the call
     raises at the caller's line. The resolved function is wrapped in one
     closure, `function(timer) return method(receiver, timer) end`, which
     becomes the timer's callback, so the method runs as
     `method(receiver, timer)`.
   Non-goals: AceTimer's extra callback argument (`ScheduleTimer(f, delay,
   arg)`; `SetUserData` is the counterpart), late binding (see point 4),
   a method form on `New(options)`, changing the host style (`NewTimer`
   handles stay: they are what lets a cancelled timer leave nothing pending).
3. Dependencies: unchanged, registry API 2. Host requirements unchanged.
4. Surface:
   - `scope:After(delay, receiver, methodName)`,
     `scope:Every(interval, receiver, methodName)`, and the same on the
     facade. The method name is required (AceTimer has no default either).
     Errors, each at the caller's line: `<method> callback must be a
     function, or a receiver table followed by a method name` (replacing
     `<method> callback must be a function`, whose text it still
     contains), `<method> methodName must not be a secret value`,
     `<method> methodName must be a non-empty string`, `<method> receiver
     has no method "<name>"` (also when the field is not a function), and
     `<method> receiver must not be a secret value`.
   - **Recorded deviation from AceTimer: early binding.** AceTimer reads
     `obj[func]` when the timer fires; TimerKit reads it once when the timer
     starts (the decision asks for the check at registration, and the
     resolved function is cheaper per fire). Replacing the method on the
     receiver afterwards does not change a timer already started; `Restart`
     keeps the resolved function too. The docs say so in the migration
     table.
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when the scope was open. A reopened scope is empty and usable
     like a new one; timers cancelled by the close stay cancelled and can
     be started again. An addon scope (`ForAddon`) raises at the caller:
     `TimerKit.Scope:Reopen cannot reopen an addon scope`, because closing
     an addon scope is its addon's teardown and stays terminal.
   - Unchanged: every other method, message, level, state and limit.
5. Ownership: unchanged. A method-name timer is owned by its scope like any
   other; the receiver is held by the wrapper closure while the timer is
   held, exactly as a closure callback holds its upvalues.
6. Performance and memory (host bench, ratios against AceTimer-3.0 from the
   same run, prototype numbers from `perf-runtime.md`):

   | Case | Before | Expected after |
   |---|---:|---:|
   | oneshot-create-cancel | 2.46× | 1.84× |
   | oneshot-create-fire | 1.86× | 1.42× |
   | repeat-tick | 1.08× | 1.01× |

   Instructions per create + cancel 188 → 138, calls 22 → 15. Bytes per
   pending one-shot unchanged at 877 B (AceTimer 629 B, of which 306 B is
   the host stub's `NewTimer` handle on our side); a repeating timer's
   record 704 → 384 B (measured, the decision 18 diagnosis). The probe rule saves one global read and one
   `type` per check in the client; on the bench host, which defines no
   `issecretvalue`, the fallback costs what today's code costs, so the
   table above already excludes any probe gain.
   Method-name form (measured in the diagnosis prototype):
   one closure of two upvalues, 136 B, at start; per fire one extra Lua
   frame, 31.7 ns against 19.2 ns for a closure callback (Ace3's late-bound
   lookup costs 35.1 ns on the same host). The closure form is unchanged:
   the method form leaves the fast path at its callback test and is built
   on the existing slow path. `Reopen` adds nothing to any hot path.
   Not reached by these fixes: a timer well below AceTimer's bytes. The
   remaining 248 B gap is the host handle and the two-upvalue fire closure,
   both bought by documented guarantees; an array-part timer record (176 B
   instead of 384 B, measured) would close most of it and is left for an
   owner decision because every record read changes.
7. Tests: the fast paths keep every existing error message and level
   (Arguments spec gains one case per fast-path test that fails, each
   asserting the caller's line); `fireStarted` stale-callback and repeating
   specs; a repeating timer without user data has 8 hash nodes (internal
   spec through the record layout), and `SetUserData` on it still works;
   the probe rule (a probe installed after load is honoured; a probe present
   at load is called without a global read); receiver checks without `type`
   (a string, a number, a table with a foreign metatable, a table with a
   `__metatable` field all raise the receiver message); method form on
   `After`/`Every` of scope and facade: fires as `method(receiver, timer)`,
   each refusal at the caller's line, missing and non-function method,
   secret method name, early binding (replacing the method after start does
   not change the call), `Restart` keeps it; `Reopen` on a closed and an
   open manual scope, on an addon scope (raises), timers of the closed
   period stay cancelled; an in-place upgrade from revision 13 keeps running
   one-shot and repeating timers firing through the new `fireStarted`, and
   their callbacks created by revision 13 resolve it at fire time. Client
   suite additions (never run): a method-name timer fires; `getmetatable`
   on a secret value does not raise (the receiver checks rely on it for a
   meaningless secret receiver only).
8. Docs: API.md (method form, early binding, `Reopen`, the errors table,
   the revised "allocates nothing" note for `SetUserData` on a repeating
   timer, the probe rule), INTERNALS.md (one-frame paths and their
   hand-over to the validators, record layout), CHANGELOG, README (migration
   table row for `ScheduleTimer("Method", delay)`), tests/README. For the shared documents:
   the `MIGRATING_FROM_ACE3.md` timer row and the closures-only paragraph.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 14, 145 specs. Deviations: the method is checked at registration
   and looked up on the receiver at every fire (late binding, as AceTimer),
   not resolved once; every timer, one-shot and repeating, uses one array-part
   record of nine slots, older named-field timers converted in place (active
   ones at load, the rest on first use); the start is two Lua frames, the
   public method and a shared launcher.

