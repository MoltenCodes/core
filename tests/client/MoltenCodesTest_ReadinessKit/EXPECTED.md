# Expected result: `/mct run readinessKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package readinessKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it standing idle, out of combat, solo, outside any instance (a capital
city is ideal). No test needs combat, a group, an instance or any action of
yours. Every gate is one the test defines itself, over data the client shows
in any tooltip (an item, a spell) or over the cosmetic `chatBubbles` setting,
which is put back after each test. Most waits are a fraction of a second; the
item test waits for the server's answer, at most four seconds. A normal run
finishes within about ten seconds. Keep the game window in the foreground: a
client running in the background renders fewer frames, and the timing tests
measure frames.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for readinessKit. Type /mct run readinessKit to run them; /mct help lists every command.
```

## After `/mct run readinessKit`

Exactly these lines, in this order (`PASS` is green and `SKIP` yellow in the
client):

```text
MoltenCodes Test: running readinessKit: 12 suites. Results follow when every test has finished.
MoltenCodes Test: PASS readinessKit.facade: Registry:Get('readinessKit', 1) is the ReadinessKit facade with API 1, Gate, Get, WhenAll and UNBOUNDED, and its gates and waiters carry every documented method
MoltenCodes Test: PASS readinessKit.facade: the installed ReadinessKit carries the revision of the committed manifest
MoltenCodes Test: PASS readinessKit.facade: the client offers both optional host facilities: GetTimePreciseSec, and EventKit API 1 through Registry:Find (logged)
MoltenCodes Test: PASS readinessKit.hostData: an item gate over C_Item.GetItemInfo for an item the client had not cached becomes ready when GET_ITEM_INFO_RECEIVED re-probes it, before its first poll (cache state and arrival logged)
MoltenCodes Test: PASS readinessKit.hostData: a spell gate over C_Spell.IsSpellDataCached becomes ready when SPELL_DATA_LOAD_RESULT re-probes it after C_Spell.RequestLoadSpellData, before its first poll (cache state logged)
MoltenCodes Test: PASS readinessKit.hostData: a gate over C_Spell.GetSpellInfo for Auto Attack is ready at definition, calls Await at once, and never probes again
MoltenCodes Test: PASS readinessKit.polling: a gate whose probe turns true on a real 0.3-second TimerKit one-shot is ready on the next poll, within one interval plus one frame and 20 ms (lateness logged)
MoltenCodes Test: PASS readinessKit.polling: a pending gate polls on a real TimerKit timer every intervalSeconds, and Close stops the polling for good and frees the name (intervals logged)
MoltenCodes Test: PASS readinessKit.polling: Invalidate on a ready gate resumes polling on the real timer, and the first poll that answers makes it ready again
MoltenCodes Test: PASS readinessKit.timeouts: a gate with timeoutSeconds 0.3 tells its waiter timeout on the first poll past 0.3 s of GetTimePreciseSec, then stops polling (elapsed logged)
MoltenCodes Test: PASS readinessKit.timeouts: Probe on a timed-out gate starts a new polling round whose timeout runs 0.3 s from that Probe on the real clock (elapsed logged)
MoltenCodes Test: PASS readinessKit.negativeCache: a burst of 100 Probe calls within intervalSeconds of GetTimePreciseSec runs the probe once, and the first Probe after the interval runs it again (spin logged)
MoltenCodes Test: PASS readinessKit.reprobe: ReprobeOn('CVAR_UPDATE') makes a gate over the chatBubbles CVar ready inside C_CVar.SetCVar, long before its first poll, and answers false for the same event again
MoltenCodes Test: PASS readinessKit.reprobe: a timed-out gate re-probed by CVAR_UPDATE becomes ready at the event, without Probe or Invalidate
MoltenCodes Test: PASS readinessKit.reprobe: a ready gate ignores CVAR_UPDATE, and after Close a chatBubbles change runs a re-probing gate's probe no more
MoltenCodes Test: PASS readinessKit.reprobe: ReprobeOn with an event name the client does not know is refused at the calling line with EventKit's reason, every time, and the gate still re-probes on a real event
MoltenCodes Test: PASS readinessKit.waiters: a gate with maxWaiters 3 refuses the fourth Await with nil, full, takes one again after a Cancel, and calls the queued callbacks in order when a real timer makes it ready
MoltenCodes Test: PASS readinessKit.waiters: WhenAll over a gate a real timer makes ready and a gate CVAR_UPDATE makes ready calls back once, with true, inside the SetCVar that completes it
MoltenCodes Test: PASS readinessKit.failures: a probe that always raises is reported to the client's error handler once per polling round, naming ReadinessKitSuite.lua at the raising line, while GetProbeErrorCount counts every failure
MoltenCodes Test: PASS readinessKit.failures: a queued Await callback that raises is reported to the client's error handler, naming ReadinessKitSuite.lua at the raising line, and the next callback of the batch still runs
MoltenCodes Test: PASS readinessKit.allocation: IsReady, a negatively cached Probe, IsClosed, GetProbeErrorCount and a waiter's IsPending allocate nothing over 10000 calls each (allocation guard)
MoltenCodes Test: SKIP readinessKit.allocation: a poll tick whose probe answers not yet allocates nothing (allocation guard) -- not measurable here: C_Timer delivers a tick between frames, where every other addon allocates too; packages/readinessKit/tests/Allocation_spec.lua guards it
MoltenCodes Test: PASS readinessKit.errors: Gate with an empty name, a probe that is not a function, or unknown option fields is refused at the calling line, naming the alphabetically first unknown field
MoltenCodes Test: PASS readinessKit.errors: Gate refuses a zero interval, a timeout of true and a fractional maxWaiters at the calling line with their documented messages, and defines no gate
MoltenCodes Test: PASS readinessKit.errors: a gate method called on something that is not a gate, a waiter method called on a gate, and WhenAll with a non-table are refused at the calling line
MoltenCodes Test: PASS readinessKit.errors: Await, Probe, Invalidate, ReprobeOn and WhenAll on a closed gate are refused at the calling line, and a second Close answers false
MoltenCodes Test: PASS readinessKit.secrets: Gate and Get refuse a secret name at the calling line, before comparing it
MoltenCodes Test: PASS readinessKit.secrets: Gate refuses a secret intervalSeconds, timeoutSeconds and maxWaiters at the calling line, and defines no gate
MoltenCodes Test: PASS readinessKit.secrets: ReprobeOn refuses a secret event name at the calling line
MoltenCodes Test: PASS readinessKit.secrets: a probe that answers a secret true or false: what Gate and the polls do with it is logged (docs/API.md does not say), and every such gate closes and frees its name
MoltenCodes Test: SKIP readinessKit.session: without GetTimePreciseSec a timeout is counted in polls and Probe never answers from the cache -- not observable here: every Retail client has GetTimePreciseSec; packages/readinessKit/tests/Timeout_spec.lua and NegativeCache_spec.lua prove the fallback
MoltenCodes Test: SKIP readinessKit.session: gates live in memory only and none survives /reload -- not observable in a run: /reload ends the session before a result could be printed; docs/API.md, Embedded copies and upgrades
MoltenCodes Test: readinessKit: 29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The three `SKIP` lines are expected on every client:

- **A poll tick.** `C_Timer` delivers a tick between two frames, from the
  client's own code, and every other addon allocates in that window too, so a
  memory reading around it cannot be pinned on ReadinessKit.
  `packages/readinessKit/tests/Allocation_spec.lua` guards it.
- **Without `GetTimePreciseSec`.** Every Retail client has the clock, so the
  fallback that counts polls instead cannot run here.
  `packages/readinessKit/tests/Timeout_spec.lua` and `NegativeCache_spec.lua`
  prove it.
- **`/reload`.** Gates live in memory only; a `/reload` ends the session
  before anything could be printed or saved.

Running it again in the same session prints the same lines. The item and the
spell test then pick the next candidate the client has not loaded yet (their
log names it); once every candidate is loaded, which takes eight runs for the
items, they prove the other branch instead, a gate that is ready at
definition, and still print `PASS`.

### On a client without secret values

The four `readinessKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. `secretwrap` only converts the value
handed to it into a secret and changes no game state. A client without them
prints these four lines instead, and the totals line reads
`25 passed, 0 failed, 7 skipped, 0 timed out (32 tests)`:

```text
MoltenCodes Test: SKIP readinessKit.secrets: Gate and Get refuse a secret name at the calling line, before comparing it -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP readinessKit.secrets: Gate refuses a secret intervalSeconds, timeoutSeconds and maxWaiters at the calling line, and defines no gate -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP readinessKit.secrets: ReprobeOn refuses a secret event name at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP readinessKit.secrets: a probe that answers a secret true or false: what Gate and the polls do with it is logged (docs/API.md does not say), and every such gate closes and frees its name -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### Skips decided while the test runs

These print `SKIP` instead of `PASS` only on a client that lacks what they
read; on Retail 12.1 none of them should appear:

- the item test: `the client lacks C_Item.GetItemInfo, RequestLoadItemDataByID or IsItemDataCachedByID`,
  or `the client knows none of the candidate items`;
- the spell data test: `the client lacks C_Spell.IsSpellDataCached or C_Spell.RequestLoadSpellData`,
  or `the client knows none of the candidate spells`;
- the Auto Attack test: `the client has no C_Spell.GetSpellInfo`;
- the two host data tests and every `readinessKit.reprobe` test, plus the
  `WhenAll` test: `EventKit API 1 is not loaded ...`, which cannot happen with
  the MoltenCodes bundle installed.

## Visible side effects

- The chat-bubble setting (`chatBubbles`, Interface options, "Chat Bubbles")
  flips several times during the `readinessKit.reprobe` tests and the
  `WhenAll` test, and is back to its value from before the run when each test
  ends. Nothing else is visible.
- For about 50 ms the negative-cache test spins on the clock inside one frame,
  so that no poll can run between its calls: one frame is that much longer.
  It is not noticeable at normal frame rates.
- The client loads the data of one item (a legendary weapon of a past
  expansion) and of one spell per run, as hovering a link would. The item
  data comes from the server.

No window opens. Two tests raise `mctReadinessKit deliberate probe failure`
and `mctReadinessKit deliberate callback failure` on purpose; while each
waits for it, the client's error handler is swapped for the test's own
collector, so no error window opens and BugSack records nothing. The secret
probe test swaps the handler for the same reason, in case the client refuses
to test a secret answer from a poll.

## What a run leaves behind

Every gate a test defines is closed by its suite's After hook, pass or fail:
that cancels its poll timer, calls its queued waiters with `"closed"`, frees
its name and closes its private EventKit scope. Every TimerKit timer and
EventKit connection a test starts is cancelled or disconnected, the client's
error handler is put back, and only then is `chatBubbles` restored, so no gate
is still open to re-probe when it changes. Three things stay in the session
until `/reload`:

- ReadinessKit's own TimerKit scope, created with the first poll timer; it is
  empty once every gate is closed;
- the Frames EventKit created to register CVAR_UPDATE,
  GET_ITEM_INFO_RECEIVED and SPELL_DATA_LOAD_RESULT (the client never frees a
  Frame; with no listener left they are unregistered);
- the item and spell data the client loaded, which it keeps cached for the
  session.

Nothing is written to a global or a saved variable besides the harness's own
results.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('readinessKit', 1) is the ReadinessKit facade ...` | The facade the client loaded is API 1 with `Gate`, `Get`, `WhenAll` and the `UNBOUNDED` table; a gate carries all eight gate methods and a waiter both waiter methods of docs/API.md; `Get` finds the gate by its name and answers `nil` for a name nobody defined. |
| `the installed ReadinessKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's (3), not an older or newer embedded copy. |
| `the client offers both optional host facilities ...` | `GetTimePreciseSec` exists and `Registry:Find("eventKit", 1)` returns the same EventKit the bundle registered, so ReadinessKit's clock and `ReprobeOn` both have their host. The log gives `Find`'s answer. |
| `an item gate over C_Item.GetItemInfo ...` | For the first candidate item `C_Item.IsItemDataCachedByID` reports as not cached, a gate over `C_Item.GetItemInfo(item) ~= nil` is pending at definition; with `ReprobeOn("GET_ITEM_INFO_RECEIVED")` and `C_Item.RequestLoadItemDataByID`, it becomes ready when the server's answer arrives, well before its first poll (the interval is 5 s, the wait at most 4 s), and its waiter is called with `true`. The log names the item, whether it was cached at the start, how long the server took, how many GET_ITEM_INFO_RECEIVED events named it with which `success`, and how often the probe ran. When every candidate is already cached, it proves instead that the gate is ready at definition and its probe ran once. |
| `a spell gate over C_Spell.IsSpellDataCached ...` | The same with spell data: a gate over `C_Spell.IsSpellDataCached` for the first candidate spell not loaded this session becomes ready when SPELL_DATA_LOAD_RESULT re-probes it after `C_Spell.RequestLoadSpellData`, before any poll. The log says whether the event arrived inside `RequestLoadSpellData` (the client documents it as synchronous) or on a later frame. |
| `a gate over C_Spell.GetSpellInfo for Auto Attack ...` | Data the client always has makes a gate ready at definition: `Await` calls back at once with `true`, the waiter is not pending, `Probe` answers `true` without probing, and 0.35 s later (three and a half intervals) the probe has still run exactly once: no poll timer runs for a ready gate. |
| `a gate whose probe turns true on a real 0.3-second TimerKit one-shot ...` | A pending gate polling every 0.1 s notices the probe's answer change on the next poll: the waiter is called between 0 and one interval plus one frame plus 20 ms after the one-shot fired. The log gives that lateness in milliseconds and the probe runs. |
| `a pending gate polls on a real TimerKit timer ...` | Polls arrive every 0.1 s within one frame plus 20 ms; `Close` answers `true`, the gate is closed, `Get` no longer finds the name, and no poll runs in the next 0.35 s. The log lists the intervals. |
| `Invalidate on a ready gate resumes polling ...` | `Invalidate` answers `true`, the gate is at once not ready and the probe has not run; the first poll, within one interval plus one frame plus 20 ms, makes it ready again with exactly one more probe. |
| `a gate with timeoutSeconds 0.3 tells its waiter timeout ...` | The waiter gets `false, "timeout"` no earlier than 0.3 s after the definition on `GetTimePreciseSec` and no later than one interval plus one frame plus 20 ms after that; no probe runs in the next 0.35 s; a new `Await` is answered `"timeout"` at once. The log gives the elapsed time and the probe runs. |
| `Probe on a timed-out gate starts a new polling round ...` | After the first timeout, `Probe` answers `false` and starts a new round: polls resume (at least two more probes) and a new waiter is told `"timeout"` 0.3 s after that `Probe`, within the same allowance. |
| `a burst of 100 Probe calls ...` | Inside one step (no poll can run): after `Invalidate` drops the cache, `Probe` runs the probe once; 100 more `Probe` calls within 50 ms of that answer run it no more; once `GetTimePreciseSec` has passed the 50 ms interval, the next `Probe` runs it again. The log gives the burst's duration, the spin and the probe runs. |
| `ReprobeOn('CVAR_UPDATE') makes a gate ... ready inside C_CVar.SetCVar ...` | `ReprobeOn` answers `true`, then `false` for the same event; the CVAR_UPDATE the client raises inside `C_CVar.SetCVar("chatBubbles", ...)` re-probes the gate, which is ready and has called its waiter by the time `SetCVar` returns, with the probe run exactly twice (definition and event), long before its 5-second poll. |
| `a timed-out gate re-probed by CVAR_UPDATE ...` | After a 0.3-second timeout, the CVar change alone makes the gate ready; a new `Await` answers `true` at once. |
| `a ready gate ignores CVAR_UPDATE ...` | A CVar change does not run the probe of a ready gate that re-probes on it; it does run the probe of a pending one, and after that gate's `Close` another change runs its probe no more: `Close` released the EventKit subscription. |
| `ReprobeOn with an event name the client does not know ...` | `ReprobeOn("MOLTENCODES_TEST_NO_SUCH_EVENT")` raises at this file's calling line with `ReadinessKit.Gate:ReprobeOn could not connect MOLTENCODES_TEST_NO_SUCH_EVENT: EventKit.Scope:Connect eventName "MOLTENCODES_TEST_NO_SUCH_EVENT" is not an event this client knows`, twice (nothing was recorded by the first refusal), and the same gate then connects CVAR_UPDATE. |
| `a gate with maxWaiters 3 refuses the fourth Await ...` | The fourth `Await` answers `nil, "full"`; after a `Cancel` (`true`, then `false`) one more is accepted; when a real one-shot makes the gate ready, the queued callbacks run in queue order, the cancelled one never. |
| `WhenAll over a gate a real timer makes ready and a gate CVAR_UPDATE makes ready ...` | The group waits while only the timer-driven gate is ready, and calls back once, with `true`, inside the `SetCVar` that makes the second gate ready; 0.35 s later it has still been called once. |
| `a probe that always raises is reported ... once per polling round ...` | A probe raising on every call is handed to the handler `seterrorhandler` installed exactly once in its first round (definition and at least three polls, until its 0.3-second timeout), naming `ReadinessKitSuite.lua` at the raising line; `Probe` on the timed-out gate starts a second round, whose first failure is reported again (two reports in all), while `GetProbeErrorCount` counts every failure. The log gives the counts. |
| `a queued Await callback that raises is reported ...` | When a real one-shot makes the gate ready, the raising second callback is reported once to the client's handler, naming this file at the raising line, and the third callback still runs. |
| `IsReady, a negatively cached Probe, IsClosed, GetProbeErrorCount ...` | After a full collection, 10000 rounds of the five calls on a pending gate with a 60-second interval move `collectgarbage("count")` by at most 1 KB, and the probe never ran again. |
| `Gate with an empty name, a probe that is not a function, or unknown option fields ...` | Each refusal names this file at the calling line with its documented message; with `zeta` and `alpha` unknown, it names `alpha`. |
| `Gate refuses a zero interval, a timeout of true and a fractional maxWaiters ...` | Each is refused at the calling line with its documented message, and `Get` finds no gate under the name. |
| `a gate method called on something that is not a gate ...` | `gate.IsReady({})`, `waiter.Cancel(gate)` and `WhenAll("not a list", ...)` are refused at the calling line with their receiver messages. |
| `Await, Probe, Invalidate, ReprobeOn and WhenAll on a closed gate ...` | A second `Close` answers `false`, a closed gate is not ready, and each of the five calls is refused in this file with its closed-gate message. |
| `Gate and Get refuse a secret name ...` | A genuine secret name is refused with `name must not be a secret value` at the calling line, before ReadinessKit compares it (which would raise on the client). |
| `Gate refuses a secret intervalSeconds, timeoutSeconds and maxWaiters ...` | Each secret option is refused at the calling line with its own message, and no gate is defined. |
| `ReprobeOn refuses a secret event name ...` | Refused with `ReadinessKit.Gate:ReprobeOn eventName must not be a secret value` at the calling line. |
| `a probe that answers a secret true or false ...` | An observation: docs/API.md does not say what a probe that answers a secret counts as. ReadinessKit tests the answer for truth (`if result then`), outside the probe's protected call. The log says, for `secretwrap(true)` and `secretwrap(false)`, whether `Gate` returned or raised (and with what), whether the gate is registered and ready, how many reports reached the handler during two intervals, and the probe error count. The test passes whatever the client does, as long as every such gate then closes and frees its name. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` other than the three above on Retail
  12.1, or a totals line other than
  `29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_ReadinessKit`. The two failure tests
  raise their `mctReadinessKit deliberate ...` errors on purpose, but they
  must reach only the test's own collector.
- A failure test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack) keeps
  the handler. Disable it and run again.
- The item test failing at `reached`: the server did not answer within four
  seconds. Its log says whether GET_ITEM_INFO_RECEIVED arrived at all and with
  which `success`. Say whether the connection was slow.
- The spell data test failing: its log says whether SPELL_DATA_LOAD_RESULT
  arrived and whether `C_Spell.IsSpellDataCached` turned true.
- A timing test failing on its allowance (`expected boolean false to be
  boolean true` at a lateness, interval or elapsed comparison): its log gives
  the measured numbers. Say whether the game window was in the background or
  the frame rate was low (below about 30 frames per second).
- A `readinessKit.reprobe` test or the `WhenAll` test failing at a probe count
  or at "ready when SetCVar returned": the client no longer raises CVAR_UPDATE
  inside `C_CVar.SetCVar`, or raises it more than once.
- The allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed ReadinessKit carries the revision ...` failing: another
  enabled addon embeds a different ReadinessKit copy.
- The chat-bubble setting not back to its value from before the run.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the item and spell chosen and
   whether they were cached, the server's answer time, the poll lateness and
   intervals, the timeouts, the negative-cache spin, the client's error
   messages with their paths, the memory delta, and what the client did with a
   secret probe answer) and the client facts. Lua shortens a long file path
   from the left, so a logged message may start with `...`; the tests compare
   only the `ReadinessKitSuite.lua:<line>` part. Send it back whatever the
   result: the item timing and the secret-answer observation are facts the run
   exists to collect.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, and the frame rate the client showed
   (`Ctrl+R`), when a test failed.
