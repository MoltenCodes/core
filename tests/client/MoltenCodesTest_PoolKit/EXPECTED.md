# Expected result: `/mct run poolKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package poolKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat, with the interface shown (not hidden with Alt+Z).

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for poolKit. Type /mct run poolKit to run them; /mct help lists every command.
```

## After `/mct run poolKit`

Within about three seconds, exactly these lines, in this order (`PASS` is
green in the client). The animation tests wait for real 0.1-second
animations, and the two allocation tests each run a full garbage collection
first, which can make the client stutter for a moment:

```text
MoltenCodes Test: running poolKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS poolKit.facade: Registry:Get('poolKit', 1) is the PoolKit facade with API 1, New, NewTablePool, UNBOUNDED and DEFAULT_MAX_RETAINED 128
MoltenCodes Test: PASS poolKit.facade: the installed PoolKit carries the revision of the committed manifest
MoltenCodes Test: PASS poolKit.frames: a released Frame comes back from Acquire as the same Frame, hidden, unanchored and without a parent
MoltenCodes Test: PASS poolKit.frames: a second pool doing the same work draws the Frames the first gave back, so no Frame is created twice
MoltenCodes Test: PASS poolKit.frames: maxRetained 1 keeps one released Frame and hands the other to destroy, which gives it back to this file's bank
MoltenCodes Test: PASS poolKit.frames: Close hands every retained Frame to destroy, and a Frame borrowed across Close is reset and destroyed on its Release
MoltenCodes Test: PASS poolKit.capacity: maxCreated 2 builds two Frames at most: Acquire then answers exhausted, even after Clear destroyed both, until SetMaxCreated raises the cap
MoltenCodes Test: PASS poolKit.capacity: maxActive 1 with maxWaiting 1 queues one request, refuses the next with queueFull, and hands the released Frame to the queued callback
MoltenCodes Test: PASS poolKit.capacity: maxActiveWarning 2 reports once through the client's error handler when two Frames are out, and not again at three
MoltenCodes Test: PASS poolKit.strict: Release of a Frame borrowed from another pool is refused at the calling line and changes neither pool
MoltenCodes Test: PASS poolKit.strict: a second Release of a retained Frame is refused as already released at the calling line
MoltenCodes Test: PASS poolKit.strict: a Frame discarded by maxRetained 0 is refused as already released under strict, and as not acquired from this pool without it
MoltenCodes Test: PASS poolKit.strict: strictReset refuses a Frame pool without a reset at the calling line
MoltenCodes Test: PASS poolKit.children: releasing a parent Frame releases its attached child Frames first, most recently attached first, each through its own pool
MoltenCodes Test: PASS poolKit.children: a child Frame released on its own is detached, so the parent's later release leaves the re-borrowed child alone
MoltenCodes Test: PASS poolKit.animation: ReleaseAfter a playing Alpha animation parks the Frame, and the client's OnFinished returns it to the pool
MoltenCodes Test: PASS poolKit.animation: Release before the animation finishes completes the parked release at once, and the animation's end then changes nothing
MoltenCodes Test: PASS poolKit.animation: ReleaseAfter on an animation group that is not playing releases the Frame at once and returns false
MoltenCodes Test: PASS poolKit.animation: an animation stopped with Stop never finishes, so the Frame stays parked until Release completes it
MoltenCodes Test: PASS poolKit.animation: one animation group reused for two deferred releases of its pooled Frame returns the Frame both times
MoltenCodes Test: PASS poolKit.animation: a reset that raises when the animation finishes reaches the client's error handler, naming PoolKitSuite.lua, and leaves the Frame borrowed
MoltenCodes Test: PASS poolKit.animation: ReleaseAfter on a group that already holds a pending release is refused at the calling line and the second Frame stays borrowed
MoltenCodes Test: PASS poolKit.allocation: Acquire and Release of a retained Frame with a Hide, ClearAllPoints and SetParent(nil) reset allocate nothing over 5000 cycles
MoltenCodes Test: PASS poolKit.allocation: a request queued behind maxActive and served by Release allocates nothing over 5000 cycles
MoltenCodes Test: PASS poolKit.errors: PoolKit:New with options that are not a table names PoolKitSuite.lua at the calling line
MoltenCodes Test: PASS poolKit.errors: PoolKit:New with a misspelt option names the field at the calling line
MoltenCodes Test: PASS poolKit.errors: a pool method called with UIParent instead of a pool names PoolKitSuite.lua at the calling line
MoltenCodes Test: PASS poolKit.errors: Prewarm with a negative count names PoolKitSuite.lua at the calling line
MoltenCodes Test: PASS poolKit.errors: Prewarm beyond maxCreated is refused at the calling line and builds no Frame
MoltenCodes Test: PASS poolKit.errors: ReleaseAfter with a table that is not an animation group is refused at the calling line and the Frame stays borrowed
MoltenCodes Test: PASS poolKit.secrets: a secret maxRetained is refused by PoolKit:New at the calling line
MoltenCodes Test: PASS poolKit.secrets: a secret maxCreated is refused by PoolKit:New at the calling line
MoltenCodes Test: PASS poolKit.secrets: a secret strictReset is refused by PoolKit:New at the calling line
MoltenCodes Test: PASS poolKit.secrets: a secret Prewarm count is refused at the calling line and builds no Frame
MoltenCodes Test: PASS poolKit.secrets: secret Trim, SetMaxRetained, SetGeneration and SetMaxCreated arguments are each refused at the calling line
MoltenCodes Test: poolKit: 35 passed, 0 failed, 0 skipped, 0 timed out (35 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

None. Every Frame the suite creates is anonymous, has no texture and is kept
at alpha 0. Six animation tests show one Frame for about a tenth of a second,
1x1 pixel at the centre of `UIParent`, while its Alpha animation (from alpha 0
to alpha 0) plays; nothing is drawn. No sound, no chat line other than the
harness's, no setting changed, no global or saved variable written.

## What stays for the session

The client never frees a Frame, so the suite creates its Frames through one
bank kept for the session: every pool a test builds borrows Frames from it and
gives them back, and it creates a Frame only when it has no spare one. Its
budget is **3 Frames per session**, the most one test holds at once, and a
second run creates none. Until `/reload` the session keeps:

- at most 3 anonymous Frames, hidden, unanchored and without a parent;
- at most one AnimationGroup with one Alpha animation on each of them, created
  the first time an animation test used that Frame; PoolKit has hooked each
  group's `OnFinished` once, which cannot be undone, and holds no pending
  release for any of them.

Every pool a test builds is released and closed by its suite's After hook,
pass or fail, and every Frame goes back to the bank. The client's error handler
is replaced only while the two tests that expect a report run, and put back by
the test or, at the latest, by the After hook; any other report arriving in
that time is passed on to the handler it replaced.

### With the interface hidden

The client plays no animation under a hidden `UIParent`, so the six
animation tests that need one to play end as skipped when the interface is
hidden (Alt+Z) at the moment they run. They print these lines instead, and the
totals line reads `29 passed, 0 failed, 6 skipped, 0 timed out (35 tests)`:

```text
MoltenCodes Test: SKIP poolKit.animation: ReleaseAfter a playing Alpha animation parks the Frame, and the client's OnFinished returns it to the pool -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
MoltenCodes Test: SKIP poolKit.animation: Release before the animation finishes completes the parked release at once, and the animation's end then changes nothing -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
MoltenCodes Test: SKIP poolKit.animation: an animation stopped with Stop never finishes, so the Frame stays parked until Release completes it -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
MoltenCodes Test: SKIP poolKit.animation: one animation group reused for two deferred releases of its pooled Frame returns the Frame both times -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
MoltenCodes Test: SKIP poolKit.animation: a reset that raises when the animation finishes reaches the client's error handler, naming PoolKitSuite.lua, and leaves the Frame borrowed -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
MoltenCodes Test: SKIP poolKit.animation: ReleaseAfter on a group that already holds a pending release is refused at the calling line and the second Frame stays borrowed -- the interface is hidden (Alt+Z); an animation does not play under a hidden UIParent
```

### On a client without secret values

The five `poolKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead, and the totals
line reads `30 passed, 0 failed, 5 skipped, 0 timed out (35 tests)`:

```text
MoltenCodes Test: SKIP poolKit.secrets: a secret maxRetained is refused by PoolKit:New at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP poolKit.secrets: a secret maxCreated is refused by PoolKit:New at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP poolKit.secrets: a secret strictReset is refused by PoolKit:New at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP poolKit.secrets: a secret Prewarm count is refused at the calling line and builds no Frame -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP poolKit.secrets: secret Trim, SetMaxRetained, SetGeneration and SetMaxCreated arguments are each refused at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('poolKit', 1) is the PoolKit facade ...` | The facade the client loaded is API 1 and carries `New`, `NewTablePool`, the `UNBOUNDED` sentinel and `DEFAULT_MAX_RETAINED` 128. |
| `the installed PoolKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `a released Frame comes back from Acquire as the same Frame ...` | A reset of `Hide`, `ClearAllPoints` and `SetParent(nil)` leaves a real Frame hidden, with no anchor and no parent, and the next `Acquire` hands back that same Frame without building another. |
| `a second pool doing the same work draws the Frames the first gave back ...` | `Close` hands every retained Frame to `destroy`, and a later pool's factory reuses those Frames: the session's Frame count does not move. |
| `maxRetained 1 keeps one released Frame ...` | The retention bound discards the second release through `destroy`, which receives the Frame already reset; the pool no longer owns it. |
| `Close hands every retained Frame to destroy ...` | `Close` destroys what it retains, and a Frame borrowed across `Close` is reset and then destroyed, not retained, when it comes back. |
| `maxCreated 2 builds two Frames at most ...` | At the creation cap `Acquire` answers `nil, "exhausted"`; destroying both Frames with `Clear` does not give the cap back, because the client still holds them; `SetMaxCreated(3)` does. |
| `maxActive 1 with maxWaiting 1 queues one request ...` | At the live limit a callback request waits, a second is refused with `queueFull`, a plain `Acquire` gets `exhausted`, and `Release` hands the same Frame to the waiting callback with the pool. |
| `maxActiveWarning 2 reports once ...` | The leak diagnostic reaches the handler `seterrorhandler` installed on the second borrowed Frame, once, and not on the third. |
| `Release of a Frame borrowed from another pool ...` | A foreign Frame is refused at this file's calling line, and neither pool's counts move. |
| `a second Release of a retained Frame ...` | A duplicate release is refused as already released at the calling line. |
| `a Frame discarded by maxRetained 0 ...` | With `strict` (the default) the weak history still recognises a discarded Frame; with `strict = false` the same mistake reads "not acquired from this pool". |
| `strictReset refuses a Frame pool without a reset ...` | `strictReset = true` without `reset` fails construction at the calling line. |
| `releasing a parent Frame releases its attached child Frames first ...` | Children attached with `AttachChild` are reset before their parent, most recently attached first, each back in its own pool and off the parent Frame. |
| `a child Frame released on its own is detached ...` | A child released alone leaves its parent's list at once, so the parent's later release does not take the Frame from whoever borrowed it since. |
| `ReleaseAfter a playing Alpha animation parks the Frame ...` | With a real AnimationGroup, `ReleaseAfter` parks the Frame (owned, not active, counted by `GetParkedCount`) and the client's own `OnFinished` completes the release; the log gives the time it took. |
| `Release before the animation finishes ...` | `Release` of a parked Frame completes at once, and the animation's later end (or its stop when the reset hid the Frame; the log says whether it was still playing) does not release the Frame again from its next borrower. |
| `ReleaseAfter on an animation group that is not playing ...` | The client's `IsPlaying()` is false for a group never played, and `ReleaseAfter` then releases at once and returns `false`. |
| `an animation stopped with Stop never finishes ...` | The client's `Stop()` does not fire `OnFinished`, so the Frame stays parked until `Release` completes it, as docs/API.md warns. |
| `one animation group reused for two deferred releases ...` | The hook PoolKit installs once per group still completes the second deferred release of the same pooled Frame. |
| `a reset that raises when the animation finishes ...` | A failure inside the release that the client's `OnFinished` starts reaches the client's error handler once, naming this file and the failing line, and the Frame is rolled back to borrowed. |
| `ReleaseAfter on a group that already holds a pending release ...` | One group holds one pending release; a second is refused at the calling line and that Frame stays borrowed. |
| `Acquire and Release of a retained Frame ... allocate nothing ...` | After a full collection, 5000 acquire/release cycles of a real Frame with its reset move `collectgarbage("count")` by at most 1 KB. |
| `a request queued behind maxActive and served by Release allocates nothing ...` | The same for 5000 cycles through the waiting ring: queue a request, release, serve it, release again. |
| `PoolKit:New with options that are not a table ...` | The constructor error names this file at the calling line, as the client names it. |
| `PoolKit:New with a misspelt option ...` | An unknown option is refused at the calling line with its name. |
| `a pool method called with UIParent instead of a pool ...` | The receiver check refuses a real Frame table at the calling line and builds nothing. |
| `Prewarm with a negative count ...` | A count error names this file at the calling line. |
| `Prewarm beyond maxCreated ...` | The creation cap bounds `Prewarm` before any Frame is built. |
| `ReleaseAfter with a table that is not an animation group ...` | A value without `HookScript` is refused at the calling line and the Frame stays borrowed, not parked. |
| `a secret maxRetained is refused ...`, `a secret maxCreated ...`, `a secret strictReset ...` | A genuine secret option is refused at the calling line before PoolKit compares it. |
| `a secret Prewarm count ...` | A secret count is refused at the calling line and no Frame is built. |
| `secret Trim, SetMaxRetained, SetGeneration and SetMaxCreated ...` | Each of the four refuses a secret at the calling line and leaves the pool's settings as they were. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1 with the
  interface shown, or a totals line other than
  `35 passed, 0 failed, 0 skipped, 0 timed out (35 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- Anything drawn on screen, or a Lua error window or a BugSack entry naming
  `MoltenCodes`, `MoltenCodesTest` or `MoltenCodesTest_PoolKit`. The reset
  test raises `mctPoolKit deliberate reset failure` on purpose, but it must
  reach only the test's own collector.
- `maxActiveWarning 2 reports once ...` or `a reset that raises when the
  animation finishes ...` failing with "the client's error handler could not
  be replaced": an error-capturing addon (BugGrabber, usually with BugSack)
  keeps the handler. Disable it and run again; the test is reporting the
  session truthfully.
- A failure naming "the Frame bank's budget of 3 Frames is spent": an earlier
  test did not give its Frames back. Send the whole output.
- An animation test failing on its `WaitUntil` (the Frame was not back within
  two seconds): the client did not fire `OnFinished`. Say whether the
  interface was hidden, or the game minimised, during the run.
- `an animation stopped with Stop never finishes ...` failing on the parked
  count: the client fired `OnFinished` for a stopped group, which docs/API.md
  says it does not.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed PoolKit carries the revision ...` failing: another enabled
  addon embeds a different PoolKit copy.
- A `poolKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the client's own error
   messages with their paths, how many Frames the suite has created this
   session, how long the animation took to return the Frame, whether the
   animation was still playing after the early release, the message the error
   handler received, the two measured memory deltas) and the client facts.
   Lua shortens a long file path from the left, so a logged message may start
   with `...`; the tests compare only the `PoolKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
