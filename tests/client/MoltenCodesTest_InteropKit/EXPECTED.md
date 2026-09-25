# Expected result: `/mct run interopKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package interopKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

The run adapts to one fact of the session, decided when each test starts:
whether a global `LibStub` exists. The client itself has none; it exists only
when another enabled addon ships one (anything built on Ace3,
LibDataBroker-1.1, LibSharedMedia-3.0 or CallbackHandler-1.0 usually does).
The facade test logs which case the run is in.

- **No LibStub** (the default: only the MoltenCodes addons enabled). The
  `interopKit.standIn` tests build a LibStub stand-in of their own and publish
  it as the global `LibStub` for the length of one test (see "The LibStub
  stand-in" below), the `interopKit.absent` tests prove the path without any
  LibStub, and the three `interopKit.realLibStub` tests are skipped.
- **A real LibStub** (another addon enabled that ships one). The stand-in is
  never installed over it and it is never removed, so the `standIn` and
  `absent` tests are skipped, and the `realLibStub` tests prove InteropKit
  against it read only.

This addon does not ship a copy of LibStub: vendoring third-party code into a
test addon is not allowed.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for interopKit. Type /mct run interopKit to run them; /mct help lists every command.
```

## After `/mct run interopKit` with no LibStub

Within a second or two, exactly these lines, in this order (`PASS` is green in
the client; the allocation test runs two full garbage collections, so the
client may stutter for a moment):

```text
MoltenCodes Test: running interopKit: 7 suites. Results follow when every test has finished.
MoltenCodes Test: PASS interopKit.facade: Registry:Get('interopKit', 1) is the InteropKit facade with API 1 and its six methods
MoltenCodes Test: PASS interopKit.facade: the installed InteropKit carries the revision of the committed manifest
MoltenCodes Test: PASS interopKit.facade: whether the session has a global LibStub is logged (absent, or its minor and libraries, read only), and IsLibStubPresent agrees
MoltenCodes Test: PASS interopKit.standIn: ExposeToLibStub('interopKit', 1) makes LibStub('MoltenCodes-InteropKit-1') the shared facade at minor REVISION, ExposeToLibStub('registry', 2) does the same for Registry, and exposing again changes nothing
MoltenCodes Test: PASS interopKit.standIn: a custom major is honoured, an older exposure of the facade is raised to the current revision in the same table, and a newer one is never lowered
MoltenCodes Test: PASS interopKit.standIn: a major another library holds is refused with false, 'taken' before LibStub is called, and that library and its minor stay as they were
MoltenCodes Test: PASS interopKit.standIn: an unknown package or API generation answers false, 'unknown' with Registry's reason, a LibStub without libs and minors answers 'unsupported', and a LibStub without NewLibrary counts as absent; nothing raises and nothing is written
MoltenCodes Test: PASS interopKit.standIn: ExposeAll exposes every active Registry row of this session under its default major, skips options.except and retired rows, counts a row whose major a foreign library holds as refused, and is idempotent
MoltenCodes Test: PASS interopKit.standIn: AdoptFromLibStub reads a library through the silent GetLibrary and records it; Find answers from the record, Adopted lists it sorted, adopting again refreshes the minor, and the library is never written
MoltenCodes Test: PASS interopKit.standIn: Find keeps answering an adoption after the global LibStub is gone, while AdoptFromLibStub and ExposeToLibStub then answer 'absent' and the record stays
MoltenCodes Test: PASS interopKit.absent: with no LibStub at all, IsLibStubPresent is false, ExposeToLibStub answers false, 'absent' even for an unknown package, AdoptFromLibStub nil, 'absent', and Find nil, 'unknown', without raising or creating a LibStub
MoltenCodes Test: PASS interopKit.absent: with no LibStub at all, ExposeAll counts every active row it would expose as refused and the rest as skipped, with and without options.except
MoltenCodes Test: SKIP interopKit.realLibStub: a LibStub another addon loaded is only read: AdoptFromLibStub of one of its libraries returns LibStub's own table and minor, Find agrees, an unknown major answers 'unknown', and LibStub's libs and minors are unchanged -- no enabled addon loaded LibStub; the standIn and absent suites ran instead
MoltenCodes Test: SKIP interopKit.realLibStub: a real LibStub's library is never overwritten: ExposeToLibStub under its major answers false, 'taken', an unknown package answers 'unknown', both before LibStub is called, and LibStub's tables are unchanged -- no enabled addon loaded LibStub; the standIn and absent suites ran instead
MoltenCodes Test: SKIP interopKit.realLibStub: ExposeAll with every Registry row in options.except registers nothing in a real LibStub and counts every row as skipped -- no enabled addon loaded LibStub; the standIn and absent suites ran instead
MoltenCodes Test: PASS interopKit.allocation: Find of an adopted major and of a never-adopted major allocates nothing over 2000 calls each
MoltenCodes Test: PASS interopKit.errors: ExposeToLibStub refuses a packageName that is not a string, is empty or is not a package identifier, and an api of 0, 1.5 or '1', at the calling line
MoltenCodes Test: PASS interopKit.errors: a major that is empty or not a string is refused by ExposeToLibStub, AdoptFromLibStub and Find at the calling line
MoltenCodes Test: PASS interopKit.errors: ExposeAll refuses options that are not a table, an except that is not a table and an except entry that is not a package identifier, at the calling line
MoltenCodes Test: PASS interopKit.secrets: a secret packageName, api or major handed to ExposeToLibStub is refused at the calling line before anything compares it, and LibStub is left as it was
MoltenCodes Test: PASS interopKit.secrets: a secret major handed to AdoptFromLibStub and Find is refused at the calling line, and the adoption record is unchanged
MoltenCodes Test: PASS interopKit.secrets: a secret package name inside ExposeAll's options.except, first or after a plain one, is refused at the calling line before any row is exposed
MoltenCodes Test: interopKit: 19 passed, 0 failed, 3 skipped, 0 timed out (22 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## After `/mct run interopKit` with another addon's LibStub

The same first and last lines; the facade, allocation, errors and secrets
lines are as above, and the `standIn`, `absent` and `realLibStub` lines read:

```text
MoltenCodes Test: SKIP interopKit.standIn: ExposeToLibStub('interopKit', 1) makes LibStub('MoltenCodes-InteropKit-1') the shared facade at minor REVISION, ExposeToLibStub('registry', 2) does the same for Registry, and exposing again changes nothing -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: a custom major is honoured, an older exposure of the facade is raised to the current revision in the same table, and a newer one is never lowered -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: a major another library holds is refused with false, 'taken' before LibStub is called, and that library and its minor stay as they were -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: an unknown package or API generation answers false, 'unknown' with Registry's reason, a LibStub without libs and minors answers 'unsupported', and a LibStub without NewLibrary counts as absent; nothing raises and nothing is written -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: ExposeAll exposes every active Registry row of this session under its default major, skips options.except and retired rows, counts a row whose major a foreign library holds as refused, and is idempotent -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: AdoptFromLibStub reads a library through the silent GetLibrary and records it; Find answers from the record, Adopted lists it sorted, adopting again refreshes the minor, and the library is never written -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.standIn: Find keeps answering an adoption after the global LibStub is gone, while AdoptFromLibStub and ExposeToLibStub then answer 'absent' and the record stays -- another addon loaded LibStub; the stand-in is never installed over it (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.absent: with no LibStub at all, IsLibStubPresent is false, ExposeToLibStub answers false, 'absent' even for an unknown package, AdoptFromLibStub nil, 'absent', and Find nil, 'unknown', without raising or creating a LibStub -- another addon loaded LibStub, and it is never removed to show the absent path (the realLibStub suite ran instead)
MoltenCodes Test: SKIP interopKit.absent: with no LibStub at all, ExposeAll counts every active row it would expose as refused and the rest as skipped, with and without options.except -- another addon loaded LibStub, and it is never removed to show the absent path (the realLibStub suite ran instead)
MoltenCodes Test: PASS interopKit.realLibStub: a LibStub another addon loaded is only read: AdoptFromLibStub of one of its libraries returns LibStub's own table and minor, Find agrees, an unknown major answers 'unknown', and LibStub's libs and minors are unchanged
MoltenCodes Test: PASS interopKit.realLibStub: a real LibStub's library is never overwritten: ExposeToLibStub under its major answers false, 'taken', an unknown package answers 'unknown', both before LibStub is called, and LibStub's tables are unchanged
MoltenCodes Test: PASS interopKit.realLibStub: ExposeAll with every Registry row in options.except registers nothing in a real LibStub and counts every row as skipped
```

The totals line reads
`MoltenCodes Test: interopKit: 13 passed, 0 failed, 9 skipped, 0 timed out (22 tests)`.
The allocation test then adopts one library of that LibStub instead of a
stand-in library. When that LibStub holds no library at all (or only
`MoltenCodes-*` exposures made by another addon), the first two
`realLibStub` tests and the allocation test end as `SKIP` with
`the loaded LibStub holds no library other than MoltenCodes exposures`.

### On a client without secret values

The three `interopKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these three lines instead:

```text
MoltenCodes Test: SKIP interopKit.secrets: a secret packageName, api or major handed to ExposeToLibStub is refused at the calling line before anything compares it, and LibStub is left as it was -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP interopKit.secrets: a secret major handed to AdoptFromLibStub and Find is refused at the calling line, and the adoption record is unchanged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP interopKit.secrets: a secret package name inside ExposeAll's options.except, first or after a plain one, is refused at the calling line before any row is exposed -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

and the totals read `16 passed, 0 failed, 6 skipped` (no LibStub) or
`10 passed, 0 failed, 12 skipped` (a real LibStub).

## The LibStub stand-in

`newLibStubStandIn` in `InteropKitSuite.lua` builds a table with LibStub's
shape and behaviour, written for this suite (it is not LibStub's code): `libs`
and `minors`, `NewLibrary(major, minor)` that records a higher minor and
creates the table on first use, `GetLibrary(major, silent)`,
`IterateLibraries()`, and a `__call` that is `GetLibrary`. Its own `minor` is
0, below every released LibStub's, so a real LibStub that loaded while it was
installed would take the table over. A probe beside it counts the
`NewLibrary` and `GetLibrary` calls, which is how the tests prove that a
refusal happened before LibStub was called and that adoption uses the silent
`GetLibrary`.

`withStandIn` publishes it as the global `LibStub` only when no `LibStub`
exists, runs the test's synchronous body, and removes it before the test
returns, pass or fail; the After hook of every suite removes it as well should
a test end any other way. It removes it only while it is still the global and
still carries its own `NewLibrary`, and logs `stand-in left in place: ...`
otherwise. Everything exposed into it goes with it.

## Visible side effects

None. Nothing is drawn, no sound plays, no chat line other than the harness's
appears, and no client setting (CVar) changes.

## What stays for the session

- No global: the stand-in is removed at the end of each test, so after the run
  `LibStub` is exactly what it was before (absent, or the other addon's).
- Nothing in a real LibStub: every call that reaches one is a refusal made
  before LibStub is called or a silent `GetLibrary` read, and each
  `realLibStub` test checks that `LibStub.libs` and `LibStub.minors` hold
  exactly the entries they held before.
- InteropKit's adoption record, which has no removal method by design
  (`packages/interopKit/docs/API.md`, "Limits"). Without a LibStub it keeps
  three entries whose majors start with `MoltenCodesTest-InteropKit-`
  (`Adopted-1`, `AdoptedBeforeRemoval-1`, `Allocation-1`), each holding a
  small stand-in table; with a real LibStub it keeps one entry naming a
  library that LibStub already holds (a reference, nothing copied). A second
  run overwrites the same entries, so the record does not grow. `/reload`
  clears it.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('interopKit', 1) is the InteropKit facade ...` | The facade the client loaded is API 1 with a numeric `REVISION` and all six methods. |
| `the installed InteropKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `whether the session has a global LibStub is logged ...` | The log says `global LibStub: absent`, or the other addon's `LibStub.minor`, how many libraries it holds (the first ten by name) and any `MoltenCodes-*` majors another addon already exposed; `IsLibStubPresent()` agrees. The log also gives how many adoption records InteropKit held when the run started. |
| `ExposeToLibStub('interopKit', 1) makes LibStub('MoltenCodes-InteropKit-1') ...` | The default major, the one `rawset` into `libs` (calling the stand-in, `GetLibrary` and `IterateLibraries` all return the shared facade at minor `REVISION`), `ExposeToLibStub('registry', 2)` resolving through `MoltenCodes.Registries[2]`, and idempotence: exposing again does not call `NewLibrary`. |
| `a custom major is honoured, an older exposure ...` | A custom major; a facade recorded at `REVISION - 1` (what an older copy leaves) is raised to `REVISION` in the same table; a facade recorded at `REVISION + 5` is left alone without calling `NewLibrary`. |
| `a major another library holds is refused ...` | `false, "taken"` with no `NewLibrary` call, and the foreign table, its fields and its minor 7 unchanged. |
| `an unknown package or API generation answers false, 'unknown' ...` | `"unknown"` with Registry's own reason (`absent` for an unknown package, `generation_mismatch` for API 99, also for `registry`), with nothing written into the stand-in; a LibStub-like table without `libs` and `minors` gives `"unsupported"` and gains no tables; a global `LibStub` without `NewLibrary` is not LibStub to InteropKit (`IsLibStubPresent()` is `false`, `"absent"` from both `ExposeToLibStub` and `AdoptFromLibStub`). |
| `ExposeAll exposes every active Registry row ...` | Over this session's real `Registry:Packages()` rows: every active row outside `except` is exposed under its default major at its revision as the table `Registry:Find` returns, `interopKit` in `except` and retired rows are skipped, a foreign library pre-registered under the first other active row's major makes that row refused and stays untouched, Registry itself is not a row, and a second call exposes nothing new. The log gives the row count and the three counts. |
| `AdoptFromLibStub reads a library through the silent GetLibrary ...` | `library, minor` from the silent `GetLibrary`; `Find` answers from the record and keeps the old minor after the library upgrades in place until it is adopted again; an unknown major is `nil, "unknown"` for both and creates nothing; `Adopted()` is sorted by major, holds `{ major = ..., minor = 5 }`, never lists the unknown major, and is a fresh array per call; the library's own fields are unchanged. |
| `Find keeps answering an adoption after the global LibStub is gone ...` | With the stand-in removed, `Find` still returns the adopted table and minor, `AdoptFromLibStub` and `ExposeToLibStub` answer `"absent"`, and that answer does not clear the record. |
| `with no LibStub at all, IsLibStubPresent is false ...` | The `"absent"` contract with no global `LibStub`: `ExposeToLibStub` answers `false, "absent"` before looking the package up (also for an unknown package, and with a custom major), `AdoptFromLibStub` answers `nil, "absent"`, `Find` of a never-adopted major `nil, "unknown"`, nothing raises, no record is added and no `LibStub` global appears. |
| `with no LibStub at all, ExposeAll counts every active row ...` | `ExposeAll()` returns `0`, the retired rows and the active rows as `exposed, skipped, refused`; with `except = { "interopKit" }` that row moves to `skipped`. |
| `a LibStub another addon loaded is only read ...` | Against a real LibStub: the first library by name that is not a `MoltenCodes-*` exposure is adopted as exactly the table and minor LibStub's silent `GetLibrary` returns, `Find` agrees, an unknown major is `nil, "unknown"`, and `libs` and `minors` keep every entry by identity. |
| `a real LibStub's library is never overwritten ...` | `ExposeToLibStub('interopKit', 1, <that major>)` answers `false, "taken"`; an unknown package answers `false, "unknown", "absent"` and its major never appears; the tables are unchanged. |
| `ExposeAll with every Registry row in options.except ...` | `0, <rows>, 0`, and the tables are unchanged. |
| `Find of an adopted major and of a never-adopted major allocates nothing ...` | docs/API.md's "allocation-free" `Find`, on the client's collector: after a full collection in its own step and one unmeasured warm-up call, 2000 calls move `collectgarbage("count")` by at most 1 KB, for a recorded major and for one never adopted. The log gives both deltas. |
| `ExposeToLibStub refuses a packageName that is not a string ...` | Each argument error of docs/API.md "Errors" at this file's calling line (`42`, `""`, `"Event-Kit"`, and `api` `0`, `1.5`, `"1"`). Validation runs before LibStub is read, so these run the same in both cases. |
| `a major that is empty or not a string is refused ...` | The `major` errors of `ExposeToLibStub`, `AdoptFromLibStub` (`nil`, `""`) and `Find` (`{}`) at the calling line. |
| `ExposeAll refuses options that are not a table ...` | `options` a string, `except` a string, an `except` entry `5` and `"Hook Kit"`, each at the calling line with docs/API.md's wording. |
| `a secret packageName, api or major handed to ExposeToLibStub ...` | A genuine secret in each of the three arguments is refused at the calling line with InteropKit's own `... must not be a secret value`, so InteropKit found it before the client's comparison error could; the global `LibStub` (and a real one's tables) are unchanged. |
| `a secret major handed to AdoptFromLibStub and Find ...` | Both refuse at the calling line; the number of adoption records is unchanged. |
| `a secret package name inside ExposeAll's options.except ...` | A secret `except` entry, first or after a plain one, is refused at the calling line as `InteropKit:ExposeAll packageName must not be a secret value` before any row is exposed. The secret is only ever an array value: docs/EMBEDDING.md ("Measured on the client") records that the client refuses a secret table key. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a totals line other than
  `19 passed, 0 failed, 3 skipped, 0 timed out (22 tests)` with no LibStub, or
  `13 passed, 0 failed, 9 skipped, 0 timed out (22 tests)` with another
  addon's LibStub. A `SKIP` of a `secrets` test on Retail 12.1 is unexpected.
- A log line `stand-in left in place: ...`: another addon replaced or took
  over the stand-in while a test ran. Send the list of enabled addons.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_InteropKit`. Every error the suite
  provokes is caught by the test itself.
- A `realLibStub` test logging `LibStub.libs changed or gained ...`,
  `... lost ...` or the same for `LibStub.minors`: InteropKit wrote into a
  real LibStub. That contradicts docs/API.md and must be reported.
- The allocation test failing: its log gives the measured deltas. Say which
  other addons are enabled.
- `the installed InteropKit carries the revision ...` failing: another enabled
  addon embeds a different InteropKit copy.
- A `secrets` test failing with "secretwrap raised" or "secretwrap returned a
  value issecretvalue does not report as secret": the client's secret
  functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (whether a LibStub was loaded
   and what it holds, the `ExposeAll` counts, the memory deltas, the client's
   own error messages with their paths) and the client facts. Lua shortens a
   long file path from the left, so a logged message may start with `...`; the
   tests compare only the `InteropKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, especially which one ships LibStub.
