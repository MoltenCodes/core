# Expected result: `/mct run profileKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package profileKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for profileKit. Type /mct run profileKit to run them; /mct help lists every command.
```

## After `/mct run profileKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green and
`SKIP` yellow in the client). The four allocation tests each run a full
garbage collection first, which can make the client stutter for a moment; the
busy loops spin for a few milliseconds at a time and are not noticeable:

```text
MoltenCodes Test: running profileKit: 10 suites. Results follow when every test has finished.
MoltenCodes Test: PASS profileKit.facade: Registry:Get('profileKit', 1) is the ProfileKit facade with API 1, every documented method, DEFAULT_MAX_SECTIONS 256 and UNBOUNDED
MoltenCodes Test: PASS profileKit.facade: the installed ProfileKit carries the revision of the committed manifest
MoltenCodes Test: PASS profileKit.facade: ProfileKit was disabled when this addon loaded, because nothing in the framework enables it
MoltenCodes Test: PASS profileKit.clock: Enable with the client's debugprofilestop answers true, and Enable, Disable and IsEnabled agree however often they are called
MoltenCodes Test: PASS profileKit.clock: Enable and Disable swap the Begin, End and Measure functions instead of flipping a flag
MoltenCodes Test: PASS profileKit.clock: a section around a 2 ms busy loop records about 2 ms on debugprofilestop, and End returns what Report records
MoltenCodes Test: PASS profileKit.clock: Measure of a 2 ms busy loop records about 2 ms and returns every result of fn, trailing nils included
MoltenCodes Test: PASS profileKit.clock: loops of 1, 3 and 2 ms give count 3, the sum as total, the largest as the spike and the 2 ms one as last
MoltenCodes Test: PASS profileKit.clock: an outer section's span includes the whole span of an inner section begun and ended inside it
MoltenCodes Test: PASS profileKit.states: Begin on a begun section is refused with nil, active and the eventual End measures from the first Begin
MoltenCodes Test: PASS profileKit.states: End without a Begin answers nil, idle and records nothing
MoltenCodes Test: PASS profileKit.states: a measurement begun before Disable is abandoned: End after a later Enable answers nil, idle and records nothing
MoltenCodes Test: PASS profileKit.states: Disable keeps every statistic, and a later Enable continues counting from them
MoltenCodes Test: PASS profileKit.states: Reset zeroes count, total, spike and last but keeps the section, its identity and the enabled state
MoltenCodes Test: PASS profileKit.states: Measure re-raises fn's string error unchanged, naming this file at fn's line, and still records the span
MoltenCodes Test: PASS profileKit.states: Measure re-raises fn's table error as the very same table
MoltenCodes Test: PASS profileKit.states: a recursive Measure of one name is recorded once, at the outermost call, and returns fn's result
MoltenCodes Test: PASS profileKit.disabled: while disabled, Begin and End return nothing and record nothing, and Measure calls fn once and returns its results
MoltenCodes Test: PASS profileKit.disabled: a disabled Measure allocates nothing over 20000 calls (allocation guard)
MoltenCodes Test: PASS profileKit.disabled: disabled Begin and End allocate nothing over 20000 pairs (allocation guard)
MoltenCodes Test: PASS profileKit.disabled: a disabled Measure and a disabled Begin/End pair each cost under 2 microseconds per call, logged beside a direct call
MoltenCodes Test: PASS profileKit.allocation: enabled Begin and End allocate nothing over 20000 pairs (allocation guard)
MoltenCodes Test: PASS profileKit.allocation: an enabled Measure of an existing section allocates nothing over 20000 calls (allocation guard)
MoltenCodes Test: PASS profileKit.report: Report lists every section by total descending, then by name, and after Reset a 3 ms and a 1 ms section lead it
MoltenCodes Test: PASS profileKit.report: Report returns a new array of new rows on every call, and changing them changes nothing in ProfileKit
MoltenCodes Test: PASS profileKit.limits: a new name at maxSections is refused with nil, capped; an existing name is still returned; Measure runs the refused name unmeasured
MoltenCodes Test: PASS profileKit.limits: lowering maxSections below the sections that exist removes none of them and refuses new names
MoltenCodes Test: PASS profileKit.limits: SetLimits with UNBOUNDED returns nothing, and GetLimits hands back the same UNBOUNDED table in a fresh table each call
MoltenCodes Test: PASS profileKit.errors: Section with an empty name names ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.errors: a disabled Measure with a name that is not a string names ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.errors: an enabled Measure with a name that is not a string names ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.errors: Measure with an fn that is not a function names ProfileKitSuite.lua at the calling line, disabled and enabled
MoltenCodes Test: PASS profileKit.errors: an enabled section.Begin() and section.End() without the section name ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.errors: a disabled section.Begin() without the section raises nothing, as documented
MoltenCodes Test: PASS profileKit.errors: SetLimits with a value that is not a table names ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.errors: SetLimits with an unknown limit names ProfileKitSuite.lua at the calling line and changes nothing
MoltenCodes Test: PASS profileKit.errors: SetLimits with a maxSections of 0 names ProfileKitSuite.lua at the calling line and changes nothing
MoltenCodes Test: PASS profileKit.errors: ProfileKit.SetLimits and ProfileKit.GetLimits called with a dot name ProfileKitSuite.lua at the calling line
MoltenCodes Test: PASS profileKit.secrets: a secret maxSections is refused at the calling line with the documented message and the limit is unchanged
MoltenCodes Test: PASS profileKit.secrets: an enabled Measure hands a secret argument to fn and fn's secret result back still secret, and records the span
MoltenCodes Test: SKIP profileKit.host: Enable answers false, unavailable on a host without debugprofilestop -- every client publishes debugprofilestop and ProfileKit binds it at load; proven by the Busted specs
MoltenCodes Test: SKIP profileKit.host: an End whose clock reading went backwards drops the sample with nil, clockReset -- only debugprofilestart() moves the clock back, and it would reset the timer SchedulerKit and other addons read; proven by the Busted specs
MoltenCodes Test: profileKit: 40 passed, 0 failed, 2 skipped, 0 timed out (42 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

### The two expected skips

Both `profileKit.host` tests are registered as skipped on every client, because
a run cannot observe them without harm:

- `Enable` answering `false, "unavailable"` needs a host without
  `debugprofilestop`. Every client publishes it, and ProfileKit binds it once
  when its file loads, so removing it from a running client proves nothing.
- A dropped sample (`nil, "clockReset"`) needs the clock to go backwards, and
  only `debugprofilestart()` does that. It zeroes the one process-wide timer
  that SchedulerKit's frame budget (including the job the tests run in) and
  every other addon read, so the suite never calls it.

The Busted specs under `packages/profileKit/tests/` prove both paths.

### On a client without secret values

The two `profileKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. Retail 12.1 has both. A client without them prints these two
lines instead, and the totals line reads
`38 passed, 0 failed, 4 skipped, 0 timed out (42 tests)`:

```text
MoltenCodes Test: SKIP profileKit.secrets: a secret maxSections is refused at the calling line with the documented message and the limit is unchanged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP profileKit.secrets: an enabled Measure hands a secret argument to fn and fn's secret result back still secret, and records the span -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

## Visible side effects

None. Nothing is drawn, no CVar or setting changes, and no sound plays. The
only thing a player could notice is the short stutter of the garbage
collections.

## What stays in the session

- **ProfileKit's switch and limit are put back.** The Before hook of every
  suite remembers whether ProfileKit was enabled and its `maxSections` limit;
  the After hook disables it (which abandons any measurement a failing test
  left open), enables it again if it was enabled, and restores the limit,
  whatever the test's outcome. After a run ProfileKit is disabled with
  `maxSections` 256, as it was.
- **Twenty sections stay.** ProfileKit never frees a section, so these remain
  until `/reload`, each counting against `maxSections` and holding the
  statistics of the last test that used it: `mctProfileKit.BusyLoop`,
  `MeasuredLoop`, `Semantics`, `Outer`, `Inner`, `Active`, `Idle`,
  `Abandoned`, `Kept`, `Reset`, `Raising`, `Recursive`, `Disabled`,
  `Allocation`, `ReportHeavy`, `ReportLight`, `ReportUnmeasured`,
  `CapExisting`, `Receiver` and `Secret` (all with the `mctProfileKit.`
  prefix). A second run reuses them and creates none. `mctProfileKit.CapProbe`
  is always refused and never created.
- **Statistics are zeroed.** Several tests call `ProfileKit:Reset()`, which
  zeroes the statistics of every section in the session, including sections
  another addon created. Nothing in the framework enables ProfileKit, so in a
  test session there is nothing else to lose.
- `debugprofilestart()` is never called. Nothing is written to a global or a
  saved variable besides the harness's results.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('profileKit', 1) is the ProfileKit facade ...` | The facade the client loaded is API 1 and carries `Enable`, `Disable`, `IsEnabled`, `Section`, `Measure`, `Report`, `Reset`, `SetLimits`, `GetLimits`, `DEFAULT_MAX_SECTIONS` 256 and the `UNBOUNDED` table. |
| `the installed ProfileKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `ProfileKit was disabled when this addon loaded ...` | ProfileKit loads disabled and nothing in the installed framework turns it on. |
| `Enable with the client's debugprofilestop answers true ...` | The client's `debugprofilestop` was found at load: `Enable` answers `true` with no reason, twice, and `IsEnabled` follows `Enable` and `Disable`, each repeated. |
| `Enable and Disable swap the Begin, End and Measure functions ...` | The switch is a function swap: a section's `Begin` and `End` and the facade's `Measure` are other functions while enabled and the same no-op functions again after `Disable`. |
| `a section around a 2 ms busy loop records about 2 ms ...` | A loop that spins 2 ms on the client's `debugprofilestop` is recorded as at least 2 ms and at most 3 ms, and `count`, `total`, `max` and `last` of the report row are exactly the value `End` returned. |
| `Measure of a 2 ms busy loop records about 2 ms ...` | The same through `Measure`, which also hands back all three results of `fn`, the two trailing `nil`s included. |
| `loops of 1, 3 and 2 ms give count 3 ...` | Count, total (the exact sum of the three `End` values), spike (the largest, the 3 ms loop) and last (the 2 ms loop) on the real clock. |
| `an outer section's span includes the whole span of an inner section ...` | Nesting is inclusive: the outer span is at least the inner span plus the 1 ms spun before it. |
| `Begin on a begun section is refused with nil, active ...` | The second `Begin` answers `nil, "active"` and the `End` measures from the first `Begin` (at least both 1 ms loops), recording once. |
| `End without a Begin answers nil, idle ...` | `End` on an idle section answers `nil, "idle"` and the count stays 0. |
| `a measurement begun before Disable is abandoned ...` | `Begin`, `Disable`, `Enable`, `End` answers `nil, "idle"` and records nothing. |
| `Disable keeps every statistic ...` | The row is unchanged while disabled, and the next measurement after `Enable` adds to it. |
| `Reset zeroes count, total, spike and last ...` | After `Reset` the row is all zeros, the section is the same object, the section count is unchanged and ProfileKit is still enabled. |
| `Measure re-raises fn's string error unchanged ...` | The error keeps `fn`'s own position in this file, and the failed call is still recorded. |
| `Measure re-raises fn's table error as the very same table` | A table error comes back as the same table. |
| `a recursive Measure of one name is recorded once ...` | Three nested `Measure` calls of one name record one measurement and the result travels back through all of them. |
| `while disabled, Begin and End return nothing ...` | Disabled `Begin` and `End` return no values; a disabled `Measure` calls `fn` once, returns both its results and records nothing. |
| `a disabled Measure allocates nothing over 20000 calls` | After a full collection, 20000 disabled `Measure` calls move `collectgarbage("count")` by at most 1 KB. |
| `disabled Begin and End allocate nothing over 20000 pairs` | The same for 20000 disabled `Begin`/`End` pairs. |
| `a disabled Measure and a disabled Begin/End pair each cost under 2 microseconds ...` | Timed on `debugprofilestop` over 20000 calls each, beside 20000 direct calls of the same empty function (logged): the documented "two type checks and a tail call" and "one table read and one call" stay far below the cost of a clock read or a `pcall`, and nothing is recorded. |
| `enabled Begin and End allocate nothing over 20000 pairs` | 20000 measured pairs allocate at most 1 KB and are all counted. |
| `an enabled Measure of an existing section allocates nothing ...` | 20000 measured `Measure` calls (two clock reads and a `pcall` each) allocate at most 1 KB and are all counted. |
| `Report lists every section by total descending, then by name ...` | After `Reset`, a 3 ms and a 1 ms section are the first two rows, every pair of rows is ordered by total then name, and a never-measured section is listed with zeros. |
| `Report returns a new array of new rows on every call ...` | Two reports share neither the array nor a row, and changing a row does not change the next report. |
| `a new name at maxSections is refused with nil, capped ...` | With the limit set to the sections that exist, a new name gets `nil, "capped"`, an existing name still resolves to its section, and `Measure` of the refused name returns its results without creating a section. |
| `lowering maxSections below the sections that exist ...` | A limit of 1 removes no section and refuses a new name. |
| `SetLimits with UNBOUNDED returns nothing ...` | `SetLimits` returns no values, and `GetLimits` returns the `UNBOUNDED` table itself, in a new table each call. |
| The ten `profileKit.errors` tests | Each documented argument error names this file at the calling line, as the client names it, for `Section`, `Measure` (disabled and enabled), an enabled dot-called `Begin` and `End`, and `SetLimits` / `GetLimits`; a refused `SetLimits` changes no limit; a disabled dot-called `Begin` raises nothing, as documented. |
| `a secret maxSections is refused at the calling line ...` | A genuine secret from `secretwrap(64)` is refused with the documented message at this file's line before ProfileKit compares it, and the limit is unchanged. |
| `an enabled Measure hands a secret argument to fn ...` | A secret passes into `fn` and back out of `Measure` still secret (and still a number), with the call measured. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line other than the two
  `profileKit.host` ones on Retail 12.1, or a totals line other than
  `40 passed, 0 failed, 2 skipped, 0 timed out (42 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_ProfileKit`. The re-raise test raises
  `mctProfileKit deliberate measured failure` on purpose, but the test catches
  it itself.
- `ProfileKit was disabled when this addon loaded ...` failing: another
  enabled addon turns ProfileKit on. Name it.
- A busy-loop test failing on the upper bound (more than 1 ms over the loop):
  the log gives the value. One such failure can be the operating system
  pausing the client for a moment; run again, and report it if it repeats.
- The cost test failing: its log gives the cost per call of all three paths.
  Say which other addons are enabled and what computer the client ran on.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed ProfileKit carries the revision ...` failing: another enabled
  addon embeds a different ProfileKit copy.
- A `profileKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (every measured span in
   milliseconds, the cost per call of the disabled paths beside a direct call,
   the four memory deltas, the number of sections in the session, the
   client's own error messages with their paths) and the client facts. Lua
   shortens a long file path from the left, so a logged message may start
   with `...`; the tests compare only the `ProfileKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
