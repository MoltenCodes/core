# Expected result: `/mct run schedulerKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package schedulerKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it standing idle, out of combat, solo, outside any instance (a capital
city is ideal). No test needs combat, a group, an instance or any action of
yours: every job, timer and handle is one the test creates itself, and every
wait is short (no test waits longer than about one and a half seconds when the
client behaves as documented, and none longer than three seconds per wait). A
normal run finishes within ten seconds. Keep the game window in the
foreground: a client running in the background renders fewer frames, and the
budget, priority and timing tests measure frames.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for schedulerKit. Type /mct run schedulerKit to run them; /mct help lists every command.
```

## After `/mct run schedulerKit`

Exactly these lines, in this order (`PASS` is green and `SKIP` yellow in the
client):

```text
MoltenCodes Test: running schedulerKit: 12 suites. Results follow when every test has finished.
MoltenCodes Test: PASS schedulerKit.facade: Registry:Get('schedulerKit', 1) is the SchedulerKit facade with API 1 and four priorities, and its jobs, scopes and contexts carry every documented method
MoltenCodes Test: PASS schedulerKit.facade: the installed SchedulerKit carries the revision of the committed manifest
MoltenCodes Test: PASS schedulerKit.facade: the frame budget is the 2 ms default, the resume ceiling the 1000 default, and the runaway threshold the 500 ms the harness sets for a run
MoltenCodes Test: PASS schedulerKit.clocks: GetTime stays fixed within a frame while debugprofilestop and GetTimePreciseSec advance together over 5 ms of work, and all three move across a rendered frame (readings logged)
MoltenCodes Test: PASS schedulerKit.budget: a job of forty 0.5 ms units that yields when ShouldYield says so is spread over rendered frames, spending at most the budget plus one unit in each (ms per frame logged)
MoltenCodes Test: PASS schedulerKit.priority: eight HIGH, NORMAL and LOW jobs and one IDLE job scheduled lowest first are served HIGH before NORMAL before LOW, with IDLE last (order logged)
MoltenCodes Test: PASS schedulerKit.priority: a HIGH job scheduled by the first job of a LOW backlog spread over rendered frames runs next, ahead of the eleven LOW jobs still waiting (order and frames logged)
MoltenCodes Test: PASS schedulerKit.timers: NextFrame is delayed on return, never runs in the frame it was scheduled in, and runs within the next two rendered frames (frame logged)
MoltenCodes Test: PASS schedulerKit.timers: After(0.25) keeps its job delayed, then runs it within two frames plus 20 ms of the deadline on the real C_Timer (lateness logged)
MoltenCodes Test: PASS schedulerKit.timers: Every(0.1) is fixed-delay on the real C_Timer: each iteration of a job that yields once starts one interval after the previous one finished, never overlapping, and Cancel stops it (gaps logged)
MoltenCodes Test: PASS schedulerKit.runaway: under the 8 ms default threshold, a 15 ms slice demotes a HIGH job to NORMAL, is reported once through the client's error handler, and the job runs on to completion (slice logged)
MoltenCodes Test: PASS schedulerKit.runaway: Context:Yield inside pcall cannot cross the client's C-call boundary: the job runs on, completes, and the swallowed yield is reported once (client message logged)
MoltenCodes Test: PASS schedulerKit.jobErrors: the client's debug library is logged: what debug.traceback and debugstack return for a failed coroutine
MoltenCodes Test: PASS schedulerKit.jobErrors: a job that raises is failed with its original error object and a traceback naming SchedulerKitSuite.lua at the raising line, is reported once, and does not stop an unrelated job
MoltenCodes Test: PASS schedulerKit.scopes: CancelAll stops a yielding job between slices and cancels a delayed and a repeating job before the real C_Timer fires, and the scope still runs new work
MoltenCodes Test: PASS schedulerKit.scopes: Close cancels a delayed job before the real C_Timer fires, answers true then false, and the closed scope refuses Schedule at the calling line
MoltenCodes Test: PASS schedulerKit.scopes: ForAddon with this test addon's name returns one open scope naming the addon, and its jobs run
MoltenCodes Test: PASS schedulerKit.scopes: CloseAddonScopes stops a probe addon's yielding job and delayed job, answers true then false, and ForAddon keeps the closed scope
MoltenCodes Test: SKIP schedulerKit.scopes: at logout this addon's scope is closed and its jobs cancelled -- not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/schedulerKit/tests/LogoutCoverage_spec.lua proves it
MoltenCodes Test: PASS schedulerKit.coalescing: Debounce(0.1) called on five consecutive frames runs once, with the last call's argument, one delay after the last call (delay logged)
MoltenCodes Test: PASS schedulerKit.coalescing: Debounce with leading runs inside the first call of a three-call burst and once more after it goes quiet, with the last call's argument
MoltenCodes Test: PASS schedulerKit.coalescing: Coalesce(0.1) delivers the keys recorded over three frames as one set, once, one interval after the first key (set and delay logged)
MoltenCodes Test: PASS schedulerKit.coalescing: two Watch(0.1) of one interval share the real ticker: first tick with previous nil in one frame, then a call only on change, and Cancel stops one watch while the other keeps ticking (calls logged)
MoltenCodes Test: PASS schedulerKit.allocation: 20000 resumes of one yielding job allocate nothing, counted in chunks of 1000 that stayed inside one driver pass (allocation guard; chunks logged)
MoltenCodes Test: PASS schedulerKit.allocation: 10000 Debounce calls inside an open window and 10000 Coalesce calls of a known key allocate nothing (allocation guard)
MoltenCodes Test: SKIP schedulerKit.allocation: a Watch tick whose value did not change allocates nothing (allocation guard) -- not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/schedulerKit/tests/Watch_spec.lua guards it
MoltenCodes Test: PASS schedulerKit.errors: package-level and scope Schedule, NextFrame, After and Every refuse bad arguments, and a scope's methods and Job:Cancel a wrong receiver, at the calling line (messages logged)
MoltenCodes Test: PASS schedulerKit.errors: ForAddon with an empty name and CloseAddonScopes on another receiver are refused at the calling line
MoltenCodes Test: PASS schedulerKit.errors: SetFrameBudget(0), SetRunawayThreshold(-1) and SetMaxResumesPerFrame(1.5) are refused at the calling line and change nothing
MoltenCodes Test: PASS schedulerKit.errors: Schedule on a scope with unknown option fields names the alphabetically first one at the calling line, and schedules nothing
MoltenCodes Test: PASS schedulerKit.errors: Context:ShouldYield and Context:Yield after their job finished are refused at the calling line
MoltenCodes Test: PASS schedulerKit.errors: Debounce with maxWaitSeconds below its delay, Watch with a zero interval and Lane with an empty name are refused at the calling line
MoltenCodes Test: PASS schedulerKit.secrets: ForAddon, CloseAddonScopes and Lane refuse a secret name at the calling line before comparing it
MoltenCodes Test: PASS schedulerKit.secrets: SetFrameBudget, SetRunawayThreshold and SetMaxResumesPerFrame refuse a secret at the calling line and change nothing
MoltenCodes Test: PASS schedulerKit.secrets: Debounce leading, Coalesce maxKeys, Watch intervalSeconds and SetLimits maxLanes refuse a secret at the calling line and change no limit
MoltenCodes Test: PASS schedulerKit.secrets: package-level Schedule priority and name, After delay and a scope's Every interval refuse a secret at the calling line and schedule nothing (messages logged)
MoltenCodes Test: PASS schedulerKit.secrets: a coalesce handle refuses a secret key at the calling line and delivers a secret value still secret
MoltenCodes Test: schedulerKit: 35 passed, 0 failed, 2 skipped, 0 timed out (37 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The two `SKIP` lines are expected on every client:

- **At logout.** An addon scope closes when the addon reaches `shutdown` at
  `PLAYER_LOGOUT`, which ends the session before any result could be printed
  or saved. `packages/schedulerKit/tests/LogoutCoverage_spec.lua` proves the
  routing for every combination of LifecycleKit and EventKit.
- **A steady Watch tick.** `C_Timer` delivers a tick between two frames, from
  the client's own code, and every other addon allocates in that window too,
  so a memory reading around it cannot be pinned on SchedulerKit.
  `packages/schedulerKit/tests/Watch_spec.lua` guards it.

Running it again in the same session prints the same lines.

### On a client without secret values

The five `schedulerKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. `secretwrap` only converts the value
handed to it into a secret and changes no game state. A client without them
prints these five lines instead, and the totals line reads
`30 passed, 0 failed, 7 skipped, 0 timed out (37 tests)`:

```text
MoltenCodes Test: SKIP schedulerKit.secrets: ForAddon, CloseAddonScopes and Lane refuse a secret name at the calling line before comparing it -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schedulerKit.secrets: SetFrameBudget, SetRunawayThreshold and SetMaxResumesPerFrame refuse a secret at the calling line and change nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schedulerKit.secrets: Debounce leading, Coalesce maxKeys, Watch intervalSeconds and SetLimits maxLanes refuse a secret at the calling line and change no limit -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schedulerKit.secrets: package-level Schedule priority and name, After delay and a scope's Every interval refuse a secret at the calling line and schedule nothing (messages logged) -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schedulerKit.secrets: a coalesce handle refuses a secret key at the calling line and delivers a secret value still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### On a client without the clocks

Every test that measures time or counts frames needs `GetTime`,
`GetTimePreciseSec` and `debugprofilestop`, which every Retail client has.
Without one of them those tests print `SKIP` with the reason
`the client lacks GetTime, GetTimePreciseSec or debugprofilestop; frames and time were not measured`.

## Visible side effects

None meant to be seen. No window opens, nothing is printed besides the
harness lines, and no setting of the game is changed. Three tests work on
purpose for a few milliseconds of one frame each: the clock test (5 ms), the
runaway test (one 15 ms slice) and the resume allocation guard (up to 20 ms of
scheduler work in each of a few frames); a frame-rate counter may show one
short dip. Four tests make SchedulerKit report through the client's error
handler on purpose (the runaway demotion, the swallowed `Yield`, and two
deliberate job failures raising `mctSchedulerKit deliberate job failure` and
a table); while each waits for its report, the client's error handler is
swapped for the test's own collector, so no error window opens and BugSack
records nothing.

## What a run leaves behind

Every scope a test creates is closed by its suite's After hook, pass or fail,
which cancels its jobs and closes its `Debounce`, `Coalesce` and `Watch`
handles. Every package-wide SchedulerKit setting a test changes is read first
and put back as soon as the test stops needing it, and again by the After
hook: the runaway threshold (8 ms for the runaway test, then the harness's
500 ms again, which the harness itself restores when the run ends), the frame
budget and the resume ceiling (20 ms and 5000 for the resume guard, then the
defaults again). The client's error handler is put back as soon as each
reporting test stops waiting (the After hook puts it back as well). This
SchedulerKit state stays in the session until `/reload`:

- this addon's own scope, `SchedulerKit:ForAddon("MoltenCodesTest_SchedulerKit")`,
  empty, closed at logout;
- one closed scope per run for a probe addon name,
  `MoltenCodesTest_SchedulerKitProbe1`, then `...Probe2` on the next run, and
  so on, each with the LifecycleKit instance SchedulerKit asked for when it
  arranged the probe's logout. No such addon exists; LifecycleKit keeps the
  instance in `loading` and does nothing with it;
- SchedulerKit's package-level convenience scope, which the refused
  package-level calls may create (docs/API.md, "Package-level convenience
  scope"). No job is ever scheduled in it.

No lane is created: the one `Lane` call with a valid shape is refused for its
secret name. Nothing is written to a global or a saved variable besides the
harness's own results.

## What each test proves

"The calling line" of an argument error is the line of `SchedulerKitSuite.lua`
that makes the refused call; in the tests that go through the
`expectRefusals` helper that is the one line inside the helper that calls the
method, so every such message names the same line number.

| Test | Proves in the real client |
|---|---|
| `Registry:Get('schedulerKit', 1) is the SchedulerKit facade ...` | The facade the client loaded is API 1 with all twenty facade methods of docs/API.md, `UNBOUNDED`, and the priorities ordered `HIGH < NORMAL < LOW < IDLE`; a scope carries its twelve methods, a job its ten, and the context a running job receives its four; `GetJob` inside the job is the handle `Schedule` returned. |
| `the installed SchedulerKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the frame budget is the 2 ms default ...` | With no other addon retuning SchedulerKit, the budget is 2 ms and the resume ceiling 1000; the runaway threshold reads 500 ms because the harness raised it for the run. The log gives all three. |
| `GetTime stays fixed within a frame ...` | Over 5 ms of busy work in one frame, `GetTime` does not move (the frame key every frame-counting test relies on), `debugprofilestop` advances at least 5 ms, and `GetTimePreciseSec` advances at least as far less 0.5 ms; across the next rendered frame all three move. The log gives every delta: whether `debugprofilestop` counts only addon time or wall time shows as a difference between its delta and the wall clock's over a frame. |
| `a job of forty 0.5 ms units ...` | A job that checks `ShouldYield` after each 0.5 ms unit is spread over at least seven rendered frames (20 ms of work at no more than 3 ms per frame), and no frame gives it more than the budget plus one unit plus 0.5 ms. The log gives the budget, the frames, the yields and the milliseconds spent in each frame. |
| `eight HIGH, NORMAL and LOW jobs and one IDLE job ...` | Scheduled IDLE first, then LOW, NORMAL and HIGH, the jobs are served by priority, not in submission order: the last HIGH runs before the last NORMAL, which runs before the last LOW; four of the first seven are HIGH (the weighted sequence `HIGH x4, NORMAL x2, LOW`); the IDLE job runs last. The log gives the order as letters and the number of frames. |
| `a HIGH job scheduled by the first job of a LOW backlog ...` | Twelve LOW jobs of 1 ms each spread over at least four frames; a HIGH job that the first of them schedules runs second or third, in the same frame or the next, ahead of the LOW jobs still waiting. The log gives the order with each job's frame. |
| `NextFrame is delayed on return ...` | `NextFrame` returns a `delayed` job that runs in a later frame than the one it was scheduled in, by the second frame of the wait. The log also says whether a `Schedule` job from the same line ran in the same frame, as docs/API.md allows. |
| `After(0.25) keeps its job delayed ...` | The job reads `delayed` right after the call and halfway through the delay, then runs no earlier than 21 ms before and no later than two frames plus 20 ms after the deadline. The log gives the lateness, the allowance and the frames. |
| `Every(0.1) is fixed-delay on the real C_Timer ...` | Each iteration of a job that yields once (so it spans two slices) starts one interval after the previous iteration finished, within 21 ms early and two frames plus 20 ms late; the job reads `delayed` between iterations; after `Cancel` no iteration starts within 0.35 s. The log gives the gaps. |
| `under the 8 ms default threshold, a 15 ms slice demotes ...` | With the threshold set to the 8 ms default for this test only, a HIGH job whose first slice works 15 ms and then yields is demoted to NORMAL, keeps running (its second slice sees NORMAL) and completes; the client's error handler receives exactly one report naming the job, `exceeded the cooperative slice threshold`, and `> 8ms`. The harness's threshold is back afterwards. The log gives the slice on both clocks and the report. |
| `Context:Yield inside pcall cannot cross ...` | The client's Lua refuses to yield across `pcall` (`attempt to yield across metamethod/C-call boundary`); the job runs on and completes without an error, and the swallowed yield is reported exactly once, naming the job and `never reached the scheduler`. The log gives the client's message and the report. |
| `the client's debug library is logged ...` | A diagnostic: a coroutine that raises fails, and the log records whether the client publishes `debug`, `debug.traceback` and `debugstack`, and what each available one returns for the failed coroutine and for the current stack. Measured on Retail 12.1.0 build 69933 on 2026-09-24: there is no `debug` global, and `debugstack(thread)` returns the bare stack (`[C]: in function 'error'`, then `[Interface/AddOns/MoltenCodesTest_SchedulerKit/SchedulerKitSuite.lua]:<line>: in function <...>`), with `debugstack(thread, 1, 12, 12)` the same without the `[C]` line. |
| `a job that raises is failed ...` | A job raising a string fails; `GetError` names this file at the raising line; `GetErrorTraceback` holds a `stack traceback:` whose frames name this file at the raising line, written `SchedulerKitSuite.lua:<line>:` when SchedulerKit captured it with `debug.traceback` and `SchedulerKitSuite.lua]:<line>:` when it used the client's `debugstack` (the Retail client has no `debug` global). A job raising a table fails with that very table as `GetError`. Each failure reaches the error handler exactly once, as its traceback. A job scheduled after them completes without an error. |
| `CancelAll stops a yielding job between slices ...` | A job that yields forever, an `After(0.25)` and an `Every(0.25)` job are all cancelled by `CancelAll`: no slice, delayed run or repeat follows within 0.6 s, and a new job in the same scope completes. |
| `Close cancels a delayed job ...` | `Close` answers `true`, then `false`; the delayed job never runs; `Schedule` on the closed scope is refused with `SchedulerKit.Scope:Schedule cannot schedule work in a closed scope` at the calling line. |
| `ForAddon with this test addon's name ...` | `ForAddon("MoltenCodesTest_SchedulerKit")` returns the same open scope every time, naming the addon, and a job in it completes. The log says whether LifecycleKit is loaded and lists `schedulerKit` in `CLOSES_ADDON_SCOPES` (it should: that is the route that closes the scope at logout). |
| `CloseAddonScopes stops a probe addon's yielding job ...` | `CloseAddonScopes` answers `false` for a name that never had a scope, `true` once the probe's job yielded twice, then `false`; the scope is closed and empty, `ForAddon` still returns it, and neither the yielding job nor the `After(0.25)` job runs again. |
| `Debounce(0.1) called on five consecutive frames ...` | Five calls on five distinct frames produce no fire during the burst and exactly one afterwards, with the fifth call's argument, one delay (less 1 ms) to one delay plus two frames plus 20 ms after the last call. The log gives the delay. |
| `Debounce with leading ...` | With `leading`, the first call of the burst runs the callback inside the call; the burst's end runs it once more with the last call's argument, and nothing else runs. |
| `Coalesce(0.1) delivers the keys recorded over three frames ...` | Keys recorded on three distinct frames (`player`, `target`, `player` again) arrive as one set, `{ player = 3, target = 2 }`, delivered once, one interval after the first key; `GetStats().delivered` is 1. The log gives the set and the delay. |
| `two Watch(0.1) of one interval share the real ticker ...` | Two watches of one interval are first called in the same frame, the first with `previous = nil`; the first watch is called again only when its value changes, with the old value as `previous`; after `Cancel` (which answers `true`, then `false`) it is no longer called, while the second watch (`everyTick`) keeps being called on the shared ticker. The log gives every count. |
| `20000 resumes of one yielding job allocate nothing ...` | With a 20 ms budget and a 5000-resume ceiling for this test only, a HIGH job yields 1000 times per chunk and reads `collectgarbage("count")` around each chunk; only chunks that stayed in one frame with no other job resumed in between are counted, until twenty such chunks (20000 resumes) grew the heap by at most 1 KB in total. The budget and ceiling are back to their defaults afterwards. The log gives the chunks measured and discarded and the delta. |
| `10000 Debounce calls inside an open window ...` | After a full collection, 10000 calls of a `Debounce` handle whose window is open, and 10000 calls of a `Coalesce` handle with a key it already holds, each grow the heap by at most 1 KB. |
| `package-level and scope Schedule, NextFrame, After and Every refuse bad arguments ...` | Each refusal carries its documented message and names this file at the calling line: the package-level callback, priority, delay and interval checks, the scope `Schedule` name, `NextFrame` priority, `After` delay and `Every` interval checks, and the wrong-receiver refusals of a scope's `Schedule`, `After`, `CancelAll` and `Close` and of `Job:Cancel`. Nothing is scheduled, the scope stays open and its delayed job stays delayed. The log gives each client message. Before SchedulerKit 0.8.4 these methods reached their checks through a tail call, and on Retail 12.1.0 build 69933 (2026-09-24) the priority, delay, interval and wrong-receiver messages carried no position at all. |
| `ForAddon with an empty name and CloseAddonScopes on another receiver ...` | Both refusals name this file at the calling line. |
| `SetFrameBudget(0), SetRunawayThreshold(-1) and SetMaxResumesPerFrame(1.5) ...` | Each is refused with its documented message at the calling line, and none of the three settings changes. |
| `Schedule on a scope with unknown option fields ...` | With `zeta` and `alpha` unknown, the refusal names `alpha`, at the calling line, and no job is scheduled. |
| `Context:ShouldYield and Context:Yield after their job finished ...` | A context kept past its job's end refuses both calls at the calling line. |
| `Debounce with maxWaitSeconds below its delay, Watch with a zero interval ...` | The three refusals name this file at the calling line with their documented messages; nothing is created. |
| `ForAddon, CloseAddonScopes and Lane refuse a secret name ...` | A genuine secret name is refused with `... must not be a secret value` at the calling line, before SchedulerKit compares it. |
| `SetFrameBudget, SetRunawayThreshold and SetMaxResumesPerFrame refuse a secret ...` | The three setters refuse a secret at the calling line and no setting changes. |
| `Debounce leading, Coalesce maxKeys, Watch intervalSeconds and SetLimits maxLanes ...` | The four refusals name this file at the calling line; `GetLimits()` is unchanged. |
| `package-level Schedule priority and name, After delay and a scope's Every interval ...` | Each secret is refused with its documented message at the calling line, as docs/API.md ("Argument errors") promises, and nothing is scheduled. Before SchedulerKit 0.8.4 these four refusals carried no position. |
| `a coalesce handle refuses a secret key ...` | A secret key is refused at the calling line; a secret value is stored and `Flush` delivers it still secret. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` other than the two above on Retail
  12.1, or a totals line other than
  `35 passed, 0 failed, 2 skipped, 0 timed out (37 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_SchedulerKit`. The four reporting
  tests provoke reports on purpose, but they must reach only the test's own
  collector.
- A reporting test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack)
  keeps the handler, and the report went to it. Disable it and run again.
- The clock test failing at `ToBe(frameBefore)`: `GetTime` moved inside one
  frame on this client, so the frame-counting tests cannot trust it. Send the
  log back.
- A budget, priority or timing test failing on a comparison (`expected
  boolean false to be boolean true`): its log gives the measured numbers
  (milliseconds per frame, order, lateness, gaps). Say whether the game window
  was in the background or the frame rate was low (below about 30 frames per
  second).
- The runaway test failing at the priority or at the report count: its log
  gives the slice on both clocks and every report the collector received.
- An allocation test failing: its log gives the measured deltas (and for the
  resume guard, how many chunks were measured and discarded). Say which other
  addons are enabled.
- `the installed SchedulerKit carries the revision ...` failing: another
  enabled addon embeds a different SchedulerKit copy.
- `the frame budget is the 2 ms default ...` failing: another enabled addon
  retuned SchedulerKit's package-wide settings.
- A `schedulerKit.secrets` test failing with "secretwrap raised" or
  "secretwrap returned a value issecretvalue does not report as secret": the
  client's secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the clock deltas, the
   milliseconds per frame, the service order, the lateness and gaps, the
   runaway slice and its report, the client's yield-boundary message, the
   job traceback and the debug library probe, the logout route, the measured memory deltas, and each
   argument-error message with its position) and the client facts. Lua shortens a
   long file path from the left, so a logged message may start with `...`; the
   tests compare only the `SchedulerKitSuite.lua:<line>` part (or
   `SchedulerKitSuite.lua]:<line>` in a `debugstack` frame). Send it back
   whatever the result: the per-frame milliseconds, the clock deltas and the
   argument-error positions are the facts the run exists to collect.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, and the frame rate the client showed
   (`Ctrl+R`), when a test failed.
