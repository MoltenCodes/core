# Expected result: `/mct run timerKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package timerKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it standing idle, out of combat, solo, outside any instance (a capital
city is ideal). No test needs combat, a group, an instance or any action of
yours: every timer is one the test starts itself, and every wait is short
(no test waits longer than about one second when the client behaves as
documented, and none longer than three seconds in any case). A normal run
finishes within ten seconds. Keep the game window in the foreground: a client
running in the background renders fewer frames, and the timing tests measure
frames.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for timerKit. Type /mct run timerKit to run them; /mct help lists every command.
```

## After `/mct run timerKit`

Exactly these lines, in this order (`PASS` is green and `SKIP` yellow in the
client):

```text
MoltenCodes Test: running timerKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS timerKit.facade: Registry:Get('timerKit', 1) is the TimerKit facade with API 1, and its timers and scopes carry every documented method
MoltenCodes Test: PASS timerKit.facade: the installed TimerKit carries the revision of the committed manifest
MoltenCodes Test: PASS timerKit.oneShot: After(0.25) fires once on the real C_Timer, within one frame plus 20 ms of the deadline it recorded (lateness logged)
MoltenCodes Test: PASS timerKit.oneShot: After(0) does not run inside the call and runs within the next two rendered frames
MoltenCodes Test: PASS timerKit.oneShot: Cancel before the deadline keeps the callback from ever running, and the timer reads cancelled with no remaining time
MoltenCodes Test: PASS timerKit.repeating: Every(0.1) ticks at its interval with its own handle, moves its deadline one interval per tick, and stops for good on Cancel (intervals logged)
MoltenCodes Test: PASS timerKit.repeating: a ticker that cancels itself inside its second tick never ticks a third time
MoltenCodes Test: PASS timerKit.remaining: GetDeadline is GetTimePreciseSec at Start plus the delay, and GetRemaining counts down against that clock while running
MoltenCodes Test: PASS timerKit.remaining: GetRemaining polled on every frame until the callback never goes negative, and is nil once the one-shot completed
MoltenCodes Test: PASS timerKit.scopes: CancelAll stops a scope's running one-shot and ticker on the real C_Timer, and the scope still runs new timers
MoltenCodes Test: PASS timerKit.scopes: Close cancels every running timer of the scope, none fires afterwards, and the closed scope refuses After at the calling line
MoltenCodes Test: PASS timerKit.scopes: ForAddon with this test addon's name returns one open scope naming the addon, and its timers fire
MoltenCodes Test: PASS timerKit.scopes: CloseAddonScopes stops a probe addon's ticker before its next tick, answers true then false, and ForAddon keeps the closed scope
MoltenCodes Test: SKIP timerKit.scopes: at logout this addon's scope is closed and its timers cancelled -- not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/timerKit/tests/LogoutCoverage_spec.lua proves it
MoltenCodes Test: PASS timerKit.callbackErrors: a one-shot callback error reaches the client's error handler once, naming TimerKitSuite.lua at the raising line
MoltenCodes Test: PASS timerKit.callbackErrors: a repeating timer whose callback raised keeps ticking and stays running, as docs/API.md documents (ticks after the error logged)
MoltenCodes Test: PASS timerKit.allocation: getters, GetRemaining, GetDeadline and SetUserData on a running timer allocate nothing over 10000 calls each (allocation guard)
MoltenCodes Test: PASS timerKit.allocation: Cancel of 200 running timers allocates nothing beyond the client's own C_Timer Cancel of 200 handles (allocation guard)
MoltenCodes Test: PASS timerKit.allocation: Start allocates at most its one callback closure beyond the client's own C_Timer.NewTimer, over 200 start-cancel pairs (per-start cost logged)
MoltenCodes Test: SKIP timerKit.allocation: a delivered tick allocates nothing (allocation guard) -- not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/timerKit/tests/Allocation_spec.lua guards it
MoltenCodes Test: PASS timerKit.errors: After with a callback that is not a function names TimerKitSuite.lua at the calling line
MoltenCodes Test: PASS timerKit.errors: negative, NaN and infinite delays and a zero repeating interval are refused at the calling line with their documented messages
MoltenCodes Test: PASS timerKit.errors: New with unknown option fields names the alphabetically first one at the calling line
MoltenCodes Test: PASS timerKit.errors: a timer method called on a scope and a scope method called on a timer are refused at the calling line
MoltenCodes Test: PASS timerKit.errors: ForAddon with an empty name and CloseAddonScopes on another receiver are refused at the calling line
MoltenCodes Test: PASS timerKit.secrets: After and Every refuse a secret delay at the calling line before comparing it, and start nothing
MoltenCodes Test: PASS timerKit.secrets: New refuses a secret delay and a secret repeating flag at the calling line
MoltenCodes Test: PASS timerKit.secrets: ForAddon and CloseAddonScopes refuse a secret addon name at the calling line
MoltenCodes Test: PASS timerKit.secrets: SetUserData stores a secret value and GetUserData hands it back still secret
MoltenCodes Test: timerKit: 27 passed, 0 failed, 2 skipped, 0 timed out (29 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The two `SKIP` lines are expected on every client:

- **At logout.** An addon scope closes when the addon reaches `shutdown` at
  `PLAYER_LOGOUT`, which ends the session before any result could be printed
  or saved. `packages/timerKit/tests/LogoutCoverage_spec.lua` proves the
  routing for every combination of LifecycleKit and EventKit.
- **A delivered tick.** `C_Timer` delivers a tick between two frames, from
  the client's own code, and every other addon allocates in that window too,
  so a memory reading around it cannot be pinned on TimerKit.
  `packages/timerKit/tests/Allocation_spec.lua` guards it.

Running it again in the same session prints the same lines.

### On a client without secret values

The four `timerKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. `secretwrap` only converts the value
handed to it into a secret and changes no game state. A client without them
prints these four lines instead, and the totals line reads
`23 passed, 0 failed, 6 skipped, 0 timed out (29 tests)`:

```text
MoltenCodes Test: SKIP timerKit.secrets: After and Every refuse a secret delay at the calling line before comparing it, and start nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP timerKit.secrets: New refuses a secret delay and a secret repeating flag at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP timerKit.secrets: ForAddon and CloseAddonScopes refuse a secret addon name at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP timerKit.secrets: SetUserData stores a secret value and GetUserData hands it back still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

## Visible side effects

None. No window opens, nothing is printed besides the harness lines, and no
setting is changed. Two tests raise `mctTimerKit deliberate callback failure`
from a timer callback on purpose; while each waits for it, the client's error
handler is swapped for the test's own collector, so no error window opens and
BugSack records nothing.

## What a run leaves behind

Every timer, scope and native `C_Timer` handle a test creates is cancelled or
closed by its suite's After hook, pass or fail, and the client's error handler
is put back as soon as each error test stops waiting (the After hook puts it
back as well). Two kinds of TimerKit state stay in the session until
`/reload`, because TimerKit keeps an addon scope once `ForAddon` created it:

- this addon's own scope, `TimerKit:ForAddon("MoltenCodesTest_TimerKit")`,
  empty, closed at logout;
- one closed scope per run for a probe addon name,
  `MoltenCodesTest_TimerKitProbe1`, then `...Probe2` on the next run, and so
  on, each with the LifecycleKit instance TimerKit asked for when it arranged
  the probe's logout. No such addon exists; LifecycleKit keeps the instance
  in `loading` and does nothing with it.

Nothing is written to a global or a saved variable besides the harness's own
results.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('timerKit', 1) is the TimerKit facade ...` | The facade the client loaded is API 1 and carries `New`, `After`, `Every`, `CreateScope`, `ForAddon` and `CloseAddonScopes`; a timer carries all thirteen timer methods and a scope all eight scope methods of docs/API.md. |
| `the installed TimerKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `After(0.25) fires once on the real C_Timer ...` | The callback runs once, and the moment it runs, read with `GetTimePreciseSec`, is within the allowance of the deadline `GetDeadline` recorded at the start, early or late. The allowance is one frame (the longest frame seen during the wait, never shorter than `1 / GetFramerate()`) plus 20 ms. The log gives the lateness in milliseconds (negative means early), the time since the call, the allowance and the longest frame. Inside its callback the timer is already `completed` and `GetRemaining` answers `nil`; 0.4 s later it has still run once. |
| `After(0) does not run inside the call ...` | A zero delay keeps the client's next-frame behaviour: the callback has not run when `After` returns, and has run by the second rendered frame. The log gives the delay and the frame. |
| `Cancel before the deadline keeps the callback from ever running ...` | After `Cancel` (which answers `true`, then `false`), nothing runs within 0.65 s, past the deadline; the timer reads `cancelled`, not pending, with `nil` remaining time and deadline. |
| `Every(0.1) ticks at its interval ...` | Four ticks arrive, each interval within the allowance of 0.1 s, each callback receiving the TimerKit handle; inside every tick `GetDeadline` is already one interval ahead (within 5 ms). After `Cancel`, no tick arrives within 0.4 s. The log lists the intervals and the ticks after `Cancel`. |
| `a ticker that cancels itself inside its second tick ...` | `Cancel` from inside the ticker's own callback answers `true` and the native ticker never ticks a third time. |
| `GetDeadline is GetTimePreciseSec at Start plus the delay ...` | The deadline lies between the clock readings just before and just after `Start`, plus the delay; after about 0.3 s, `GetRemaining` equals the deadline minus the clock at the moment of the call, and `GetDeadline` has not moved; after `Cancel` both are `nil`. |
| `GetRemaining polled on every frame ...` | Read once per frame until the callback runs, `GetRemaining` never goes below 0 (it answers 0 while the client is late); once the one-shot completed, both getters answer `nil`. The log gives the smallest reading and how many readings were 0. |
| `CancelAll stops a scope's running one-shot and ticker ...` | `CancelAll` answers 2 (the idle timer does not count), nothing runs within 0.65 s, and a new timer in the same scope fires. |
| `Close cancels every running timer of the scope ...` | `Close` answers `true`, then `false`; nothing runs afterwards; `After` on the closed scope is refused with `TimerKit.Scope:After cannot create a timer in a closed scope` at this file's calling line. |
| `ForAddon with this test addon's name ...` | `ForAddon("MoltenCodesTest_TimerKit")` returns the same open scope every time, naming the addon, and a timer in it fires once. The log says whether LifecycleKit is loaded and lists `timerKit` in `CLOSES_ADDON_SCOPES` (it should: that is the route that closes the scope at logout). |
| `CloseAddonScopes stops a probe addon's ticker ...` | `CloseAddonScopes` answers `false` for a name that never had a scope, `true` once the probe's ticker ticked, then `false`; the scope is closed and empty, `ForAddon` still returns it, and the ticker does not tick again within 0.4 s. |
| `a one-shot callback error reaches the client's error handler once ...` | TimerKit does not catch a callback error: the client reports it to the handler `seterrorhandler` installed, exactly once, naming `TimerKitSuite.lua` at the raising line. The timer is `completed`. |
| `a repeating timer whose callback raised keeps ticking ...` | The open owner question. docs/API.md ("Repeating callback errors") says a callback error does not cancel the ticker and the timer stays `running`. The test raises in the first tick only, then counts the ticks in the next 0.5 s, and passes when there are at least two and the timer still reads `running`. The log gives the count, the state and `GetRemaining` whatever happens; when the count is 0 it adds the line `the client stopped the native ticker after its callback raised, while TimerKit still reports it running`. |
| `getters, GetRemaining, GetDeadline and SetUserData ...` | After a full collection, 10000 rounds of the eleven read-only calls and `SetUserData` on a running timer move `collectgarbage("count")` by at most 1 KB. |
| `Cancel of 200 running timers allocates nothing beyond ...` | Cancelling 200 running TimerKit timers grows the heap by at most 1 KB more than cancelling 200 native `C_Timer.NewTimer` handles. The log gives both deltas. |
| `Start allocates at most its one callback closure ...` | 200 `Start`+`Cancel` pairs on one TimerKit timer cost at most 256 bytes per pair more than 200 native `NewTimer`+`Cancel` pairs: the one callback closure docs/API.md ("Cost") names, and nothing else. The log gives both totals and the bytes per start. |
| `After with a callback that is not a function ...` | The argument error names this file at the calling line. |
| `negative, NaN and infinite delays ...` | `-1`, NaN, infinity and a zero repeating interval are each refused at the calling line with the documented message, and nothing starts. |
| `New with unknown option fields ...` | With `zeta` and `alpha` unknown, the refusal names `alpha`, at the calling line. |
| `a timer method called on a scope ...` | `timer.Cancel(scope)` and `scope.CancelAll(timer)` are refused at the calling line with the receiver messages. |
| `ForAddon with an empty name and CloseAddonScopes on another receiver ...` | Both refusals name this file at the calling line; this addon's scope stays open. |
| `After and Every refuse a secret delay ...` | A genuine secret delay is refused with `... delay must not be a secret value` at the calling line, before TimerKit compares it, and no timer starts. |
| `New refuses a secret delay and a secret repeating flag ...` | Both option fields are refused with their secret messages at the calling line. |
| `ForAddon and CloseAddonScopes refuse a secret addon name ...` | Both refuse with `addonName must not be a secret value` at the calling line; this addon's scope stays open. |
| `SetUserData stores a secret value ...` | User data is stored by reference and never compared, so a secret is accepted and comes back still secret; `SetUserData(nil)` detaches it. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` other than the two above on Retail
  12.1, or a totals line other than
  `27 passed, 0 failed, 2 skipped, 0 timed out (29 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_TimerKit`. The two callback-error
  tests raise `mctTimerKit deliberate callback failure` on purpose, but it
  must reach only the test's own collector.
- A callback-error test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack) keeps
  the handler, and the deliberate failure went to it. Disable it and run
  again.
- `a repeating timer whose callback raised keeps ticking ...` failing at
  `ticksAfterError >= 2` with the "stopped the native ticker" log line: the
  client cancels a native ticker whose callback raised, and docs/API.md is
  wrong about it. This is an answer, not a fault of the run: send it back.
- A timing test failing on the allowance (`expected boolean false to be
  boolean true` at a lateness, interval or deadline comparison): its log gives
  the measured numbers. Say whether the game window was in the background or
  the frame rate was low (below about 30 frames per second).
- An allocation test failing: its log gives the measured deltas. Say which
  other addons are enabled.
- `the installed TimerKit carries the revision ...` failing: another enabled
  addon embeds a different TimerKit copy.
- A `timerKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the lateness of the one-shot,
   the tick intervals, the remaining-time readings, the logout route, the
   ticks after a raising tick, the measured memory deltas, the client's own
   error messages with their paths) and the client facts. Lua shortens a long
   file path from the left, so a logged message may start with `...`; the
   tests compare only the `TimerKitSuite.lua:<line>` part. Send it back
   whatever the result: the lateness and the ticks after an error are the
   facts the run exists to collect.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, and the frame rate the client showed
   (`Ctrl+R`), when a test failed.
