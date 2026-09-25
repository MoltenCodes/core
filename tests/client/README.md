# Real-client tests

The Busted specs prove every Kit against a fake World of Warcraft client
(`tests/support/FrameworkTestEnv.lua`). This directory holds what runs in the
**real** client: small development addons that register
[TestKit](../../packages/testKit/README.md) suites, one addon per framework
package, and a harness addon that runs them on request and saves the results
where they can be read back after the session.

It is a test layer of its own; see
[`docs/TESTING.md`](../../docs/TESTING.md#real-client-tests) for where it sits
beside the others. Nothing here is ever shipped: `.pkgmeta` ignores `tests/`,
and the bundle builder never reads it.

## Layout

```text
tests/client/
├── README.md                          # this file
├── RESULTS.md                         # the result matrix, generated from results.json; never edited by hand
├── results.json                       # every package's latest recorded run per flavour: the one source of truth
├── .luarc.json                        # lua-language-server workspace for the addons below
├── MoltenCodesTest/                   # the harness addon
│   ├── MoltenCodesTest.toc
│   └── Harness.lua                    # /mct, the chat report, the saved results
├── MoltenCodesTest_Registry/          # the test addon of the `registry` package
│   ├── MoltenCodesTest_Registry.toc
│   ├── RegistrySuite.lua              # the TestKit suites
│   └── EXPECTED.md                    # what a run should print, and what to send back
├── MoltenCodesTest_SignalKit/         # the test addon of the `signalKit` package
│   ├── MoltenCodesTest_SignalKit.toc
│   ├── SignalKitSuite.lua
│   └── EXPECTED.md
├── MoltenCodesTest_EventKit/          # the test addon of the `eventKit` package
│   ├── MoltenCodesTest_EventKit.toc
│   ├── EventKitSuite.lua
│   └── EXPECTED.md
├── MoltenCodesTest_LifecycleKit/      # the test addon of the `lifecycleKit` package
│   ├── MoltenCodesTest_LifecycleKit.toc
│   ├── LifecycleKitSuite.lua
│   └── EXPECTED.md
├── MoltenCodesTest_ClientKit/         # the test addon of the `clientKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_CacheKit/          # the test addon of the `cacheKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_ModuleKit/         # the test addon of the `moduleKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_ProfileKit/        # the test addon of the `profileKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_ReadinessKit/      # the test addon of the `readinessKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_SchemaKit/         # the test addon of the `schemaKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_LocaleKit/         # the test addon of the `localeKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_HookKit/           # the test addon of the `hookKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_SettingsKit/       # the test addon of the `settingsKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_OptionsKit/        # the test addon of the `optionsKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_CommandKit/        # the test addon of the `commandKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_CodecKit/          # the test addon of the `codecKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_CommKit/           # the test addon of the `commKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_InteropKit/        # the test addon of the `interopKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_MediaKit/          # the test addon of the `mediaKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_WidgetKit/         # the test addon of the `widgetKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_BrokerKit/         # the test addon of the `brokerKit` package (.toc, LibDataBrokerStandIn.lua, suite, EXPECTED.md)
├── MoltenCodesTest_LogKit/            # the test addon of the `logKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_CompatKit/         # the test addon of the `compatKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_ApiKit/            # the test addon of the `apiKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_PoolKit/           # the test addon of the `poolKit` package (.toc, suite, EXPECTED.md)
├── MoltenCodesTest_SchedulerKit/      # the test addon of the `schedulerKit` package (.toc, suite, EXPECTED.md)
└── MoltenCodesTest_TimerKit/          # the test addon of the `timerKit` package (.toc, suite, EXPECTED.md)
```

The harness `.toc` also lists `TestKit.lua` and `Expected.lua`. Neither is
committed: the installer writes both (see below).

## Running the tests

The installer puts everything in place. It never writes anywhere but the
folders it names, and it replaces only its own addons:

```bash
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package registry
```

It builds the release bundle with `python3 -m tooling.package.build --all` in a
temporary directory and installs, under `_retail_/Interface/AddOns/`:

| Folder | What it is |
|---|---|
| `MoltenCodes/` | the framework bundle, exactly as a player installs it |
| `MoltenCodesTest/` | the harness, plus a fresh copy of `packages/testKit/src/TestKit.lua` and a generated `Expected.lua` |
| `MoltenCodesTest_<Facade>/` | the test addon of each `--package` |

`Expected.lua` lists every package the client will load, with the API
generation and revision its committed `package.manifest.json` declares. The
suites compare the live client with it, so a stale install or a newer copy
embedded by another addon shows up as a failure instead of passing silently.
It also records the installation: the commit `git rev-parse HEAD` named, a
`dirty` flag when the working tree had changes (untracked files included), the
flavour folder and the time. The harness saves that with every result, so each
row of the result matrix names the commit it proves. `--dry-run` prints what
would be installed, the `## Interface` line and the commit.

### Client flavours

The same addons run on the three flavours the framework promises. Each is a
folder of its own under the game folder, named by the Battle.net launcher, and
`--flavour-dir` selects it:

| Flavour | Folder | `WOW_PROJECT_ID` |
|---|---|---:|
| Retail | `_retail_` (the default) | 1 |
| Classic Era (also Hardcore and Season of Discovery) | `_classic_era_` | 2 |
| Mists of Pandaria Classic | `_classic_` | 19 |
| Burning Crusade Classic Anniversary (optional: listed, not promised) | `_anniversary_` | 5 |

The Anniversary client loads the addons too, because the supported-client
table lists its Interface number, but the framework does not promise it: the
matrix shows it as optional and gives it columns only once it has a run, and
`Harness:GetFlavour()` answers `nil` there. A test realm (`_ptr_`,
`_classic_era_ptr_`, ...) can be installed into, but its runs never enter the
matrix.

```bash
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package registry
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package registry
```

Every `.toc` here carries one `## Interface` line with every number of
[`tooling/validation/supported_clients.json`](../../tooling/validation/supported_clients.json),
the line `python3 -m tooling.validation.interface_numbers` prints and the
bundle's generated `.toc` carries, so every client loads the addons without
"out of date". The installer writes that line into every `.toc` it installs,
taken from the table at install time, and repository validation holds the
committed files to it, so the numbers cannot drift. Where a suite's outcome
differs by flavour, its `EXPECTED.md` says so in `## Per flavour` with the
exact totals line of each client.

### In the game

1. Log in. The chat frame shows one line, for example
   `MoltenCodes Test: test suites loaded for registry. Type /mct run registry to run them; /mct help lists every command.`
2. Type `/mct run registry`. A line per test and a totals line follow within a
   second or two.
3. `/reload` (or log out) so the client writes the saved variables.
4. Record the run in the result matrix (next section), or send back
   `WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
   folder.

Each test addon's `EXPECTED.md` lists the exact lines a correct run prints.

When testing is over, record the results first, then remove everything the
installer added, and the saved results with it:

```bash
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --remove
```

That deletes `MoltenCodes`, `MoltenCodesTest` and every `MoltenCodesTest_*`
folder from `AddOns`, and every `MoltenCodesTest.lua`, `MoltenCodesTest_*.lua`
and their `.bak` copies under `WTF/Account/*/SavedVariables/` and
`WTF/Account/*/*/*/SavedVariables/`, and drops the lines the client keeps for
those addons in every `WTF/Account/*/AddOns.txt` and
`WTF/Account/*/*/*/AddOns.txt` (every other line stays byte for byte). Close
the game first: a running client writes its saved variables and addon list
again at logout or `/reload`. Add `--dry-run` to see the list first, and
`--flavour-dir` for a Classic client.
Both commands refuse when the `AddOns` folder does not exist, and neither
follows a symbolic link out of the game folder.

## Result matrix

[`RESULTS.md`](RESULTS.md) is the matrix of every package's latest recorded
run, one column group per flavour (tests, passed, failed, skipped, timeout),
with the build, interface, locale, operating system, date and installed
commit of each row, every skipped test with its reason, every failure, and the
gaps no run covers. It is generated from [`results.json`](results.json), the
one source of truth, by a command that only reads the game folder:

```bash
python3 -m tooling.client.report --wow-dir "/Applications/World of Warcraft"
```

It reads the harness's saved results from every flavour folder that exists
(`--flavour-dir` limits it; `--saved-variables FILE` reads a file someone sent
instead), attributes each run to the flavour the client reported, leaves out
runs on a test build, and merges it: a run replaces the row of its flavour, package and mode unless the
recorded row is newer, and every other row stays with its own date and commit.
A session that ran four packages therefore updates four rows. `--dry-run`
prints what would change; `--check` fails when the committed files differ
from what the command would write, and writes nothing.

A flavour no session can run for now is recorded with its reason, and the
matrix shows it as `not run` with that reason rather than blank; the first
run recorded for it clears the reason:

```bash
python3 -m tooling.client.report --unavailable "classic-era=no client session available; the owner has no active game time"
python3 -m tooling.client.report --available classic-era
```

Classic Era and Mists Classic are recorded that way at the moment: the owner
has no active game time, so those clients cannot log in, and every suite's
`## Per flavour` expectations for them are derived from the code and the
apiKit metadata, not yet measured.

The first Retail rows were moved from the table this README used to hold (every
package on Retail 12.1.0 build 69933, enUS, macOS, between 2026-09-24 and
2026-09-25): they carry that interval as their date, no commit and no skip
reasons, and the matrix says so until each package runs again.

What the matrix never shows as covered: a skip (listed apart, with its
reason), a flavour or package without a run, a combat suite without a
`/mct run <package> combat`, anything only a Windows client shows (the owner's
clients run on macOS), and group communication with a second character (none
is available). Those are listed under its Gaps.

Run again after any change to a package's runtime code, and compare with its
`EXPECTED.md` rather than with the matrix.

## The harness

| Command | What it does |
|---|---|
| `/mct run` | Runs the suites of every loaded test addon. |
| `/mct run <package>` | Runs the suites of one package, for example `/mct run registry`. |
| `/mct run <package> combat` | Waits up to 60 seconds for combat, then runs the package's combat suites (see "Combat runs"). |
| `/mct run combat` | The same for every loaded package that has combat suites. |
| `/mct list` | Lists the loaded packages and their suites. |
| `/mct report` | Prints the saved totals and every test that did not pass. |
| `/mct clear` | Empties the saved results. |
| `/mct help` | Lists these commands. |

A run resets TestKit's results, queues the package's suites and, when TestKit
reports the run finished, prints one line per test:

```text
MoltenCodes Test: PASS registry.lookup: Registry:Find of a package nobody registered returns nil and absent without raising
MoltenCodes Test: FAIL registry.facade: the installed Registry carries the revision of the committed manifest -- Interface/AddOns/MoltenCodesTest_Registry/RegistrySuite.lua:185: expected number 11 to be number 12
```

then one totals line per package, then where the results were saved. The
status is `PASS`, `FAIL`, `SKIP` or `TIMEOUT`, TestKit's four outcomes; a
failure carries TestKit's message, which names the test file and line.

### Saved results

`MoltenCodesTestResults` (the `## SavedVariables` of the harness) is keyed by
package ID; a combat run is keyed `<package>:combat`, so it never replaces the
package's default run. A run replaces its own entry:

```lua
MoltenCodesTestResults = {
  registry = {
    schema = 2,
    package = "registry",
    mode = "default", -- or "combat"
    installation = { -- from Expected.lua; absent fields are unknown
      commit = "16878c910979...", dirty = false,
      flavourDirectory = "_retail_", installedAt = "2026-09-26T08:00:00Z",
    },
    client = {
      version = "12.1.0", build = "...", buildDate = "...", interface = 120100,
      projectId = 1, flavour = "retail", testBuild = false, os = "macOS",
      locale = "enUS", date = "2026-09-24 18:00:00",
      registryRevision = 13, expectedInstalled = true,
      packages = {
        { package = "apiKit", api = 1, revision = 2, status = "active",
          facadeRevision = 2, expectedRevision = 2 },
        -- every Registry entry, as Registry:Packages() lists it
      },
    },
    report = { suites = { ... }, totals = { ... } }, -- TestKit:Report(), this package's suites
  },
}
```

The client facts are taken when the run starts: `GetBuildInfo()`,
`WOW_PROJECT_ID` and the apiKit flavour it stands for (`retail`,
`classic-era`, `classic-mop`), `IsTestBuild()` as `testBuild`, the operating system when the client answers
`IsMacClient`, `IsWindowsClient` or `IsLinuxClient` (Retail documents them;
where none answers, `os` is absent), `GetLocale()`, `date()`, and every
package Registry holds with the `REVISION` its facade publishes. `report` has
the shape of `TestKit:Report()` (see the
[TestKit API](../../packages/testKit/docs/API.md#testkitreport)), restricted to
the package's suites, with each test's `logs`. Schema 1 entries, written before
the installation and flavour facts, have no `mode`, `installation`,
`client.flavour`, `client.testBuild` or `client.os`; the report command reads
both.

### Combat runs

Some behaviour exists only in combat lockdown (a protected frame refusing a
script hook, a deferred call waiting for combat to end). A test of it lives in
a **combat suite**, registered with `Harness:Suite(..., { combat = true })`.
The default run queues combat suites like any other, and their tests skip
while the player is out of combat, so the default totals stay what
`EXPECTED.md` states. To exercise them:

1. Stand next to a training dummy, out of combat. Classic Era's cities have
   no training dummies (they arrived with a later expansion): attack a
   low-level creature there instead, and let it die or leave it so combat ends
   when a suite waits for that.
2. Type `/mct run <package> combat`. The harness calls the suites' `prepare`
   functions (set-up the client allows only out of combat, such as creating a
   secure button), then prints
   `MoltenCodes Test: waiting up to 60 seconds for combat: attack a training dummy now. The combat suites of <package> start when combat begins.`
3. Attack the dummy. At `PLAYER_REGEN_DISABLED` the harness queues only the
   package's combat suites and prints
   `MoltenCodes Test: running <package> (combat suites): <n> suites. Results follow when every test has finished.`
   The client raises that event before it applies the lockdown; the tests run
   in later frames, when `InCombatLockdown()` answers `true`. Stop attacking
   when the package's `EXPECTED.md` says so (a suite that waits for combat to
   end needs the dummy to drop combat).
4. The totals line reads `MoltenCodes Test: <package>:combat: ...`; `/reload`
   as after any run.

Typed while already in combat, the command starts at once, without `prepare`.
`Harness:IsCombatRun()` tells a running test which kind of run it is in.
When combat does not start within 60 seconds the harness prints
`MoltenCodes Test: combat did not start within 60 seconds; nothing was run or saved for <package>.`
and records nothing, so a missed combat window never shows up as a result. Each
affected `EXPECTED.md` has a `## Combat run` section with the exact lines.
Tests that need a group or a second character have no such procedure: they
stay skips, and the matrix lists them as a gap.

### Why nothing runs automatically

A run registers probe packages in the session's Registry and measures memory,
so it must never start behind the owner's back, and a run at login would race
the loading screen. Runs therefore start only with `/mct run`; the only thing
the harness does at login is print which suites are loaded and how to run them.
There is no auto-run switch.

### Why the harness raises TestKit's suite limit

TestKit keeps at most 64 suites per session by default, and every package test
addon registers several (eight addons register 68). At load the harness sets
`maxSuites` to 1024, a finite value, so installing every test addon at once
still works while a registration loop would still be caught.

### Why a run raises SchedulerKit's runaway threshold

TestKit runs tests in one SchedulerKit job, and some test steps (an allocation
guard runs a full garbage collection and thousands of calls) take tens of
milliseconds in one slice. Under SchedulerKit's 8 ms default the job would be
demoted and every such slice reported through the error handler, which is the
documented contract but only noise in a test run. `/mct run` therefore sets the
threshold to 500 ms and puts the previous value back when the run finishes. The
threshold is package-wide, so other SchedulerKit jobs in the session share the
relaxed value for the length of the run.

### Why the harness publishes a global

A test addon must reach the harness to register its suites under a package ID,
and the harness must know which suites belong to which package, because
TestKit cannot list its suites. The harness therefore publishes one global,
`MoltenCodesTest`, besides its saved variable `MoltenCodesTestResults` and the
`SLASH_MOLTENCODESTEST1` entry of `/mct`. `MoltenCodesTest:GetOwnGlobalNames()`
returns those three names, so the Registry suite that checks the framework's
globals can tell the harness's apart.

## Writing a package test addon

A test addon is named after the package's facade: `MoltenCodesTest_<Facade>`,
for example `MoltenCodesTest_EventKit` for `eventKit`. The installer finds it
by that name.

```toc
## Interface: 120100, 50504, 20506, 11509
## Title: MoltenCodes Test: EventKit
## Dependencies: MoltenCodesTest

EventKitSuite.lua
```

```lua
local addonName = ...
-- selene: allow(global_usage)
local Harness = rawget(_G, "MoltenCodesTest")

local suite = Harness:Suite("eventKit", "dispatch", addonName) -- the TestKit suite "eventKit.dispatch"
suite:Test("PLAYER_TARGET_CHANGED reaches a listener once per change", function(ctx)
  -- ...
end)
```

`Harness:Suite(packageId, part, addonName, options)` registers a TestKit suite
named `<packageId>.<part>` that waits for the test addon's `ready` phase.
`options` is optional: `timeoutSeconds` lengthens TestKit's 10-second limit
per test for a suite whose test waits for the player (the LifecycleKit
training-dummy test waits up to 30 seconds for combat to end); `combat = true`
makes a combat suite, and `prepare`, a function allowed only with it, runs out
of combat before a combat run waits (see "Combat runs").
`Harness:GetExpectedPackages()` returns what `Expected.lua` lists. Every test
name says what it proves, every test is independent of the others, and a test
cleans up what the API lets it clean up; the file header says what remains for
the session. Test here only what the fake client cannot show (see
[`docs/TESTING.md`](../../docs/TESTING.md#layers)); everything else belongs in
the package's Busted specs.

Add an `EXPECTED.md` next to the `.toc`: the exact chat lines of a correct
run, what counts as unexpected, and what to send back, with a `## Per flavour`
section giving the exact totals line on Retail, Classic Era and Mists Classic
and every test that skips on one of them.

### Writing for every flavour

A test must be honest on each promised client. Where a client lacks a
capability the package documents as optional, the test skips with a reason
that names the missing capability (for example "the client has no
ColorPickerFrame:SetupColorPickerAndShow; ..."), decided by probing the
client, not by its flavour; check what each flavour documents in
`packages/apiKit/metadata/<flavour>/` before deciding. Where the package
itself would break on a flavour, the test stays real and fails there: that is
a package defect to fix, never a skip. Two harness helpers support this:

- `Harness:CanMakeSecrets()` answers whether `issecretvalue` reports what
  `secretwrap` returns as secret, measured once. Classic Era and Mists Classic
  document both functions, so their presence alone proves nothing; a test that
  needs a secret skips with `Harness.NO_SECRETS_REASON` when it answers
  `false`.
- `Harness:GetFlavour()` answers `"retail"`, `"classic-era"` or
  `"classic-mop"` from `WOW_PROJECT_ID`, for the rare expected value the
  package documents per flavour (EventKit's combat-log reader, ClientKit's
  `GetFlavor`).

### Skipping a test at run time

TestKit decides a skip when a test is registered (`suite:Skip`), which suits a
precondition the client answers at load, such as whether it has `secretwrap`.
A precondition only the moment of the run can answer, such as whether the
player is in combat, needs `Harness:SkipTest(ctx, reason)` inside the test: it
ends the test at once, and the harness prints and saves it as `SKIP` with
`reason`. Underneath, it fails the test with `reason` behind a marker that the
harness recognises when it splits the report per package, because TestKit has
no skip for a test that already runs; TestKit's own `Report()` therefore still
lists it as failed. The suite's After hooks run as after any other failure.

### Catching an error a Kit reports instead of raising

A Kit that isolates a consumer's failure (a bus listener, an event handler)
runs it through `securecallfunction` on the Retail client, and the client
reports the failure to the handler `seterrorhandler` installed. The global
`geterrorhandler` only reads that handler there: replacing the global with
`ctx:Replace` neither catches the failure nor keeps the error window closed,
and it taints a global Blizzard code calls. A test that provokes such a
failure therefore swaps the handler with `seterrorhandler` for the one call
and puts the previous one back at once, and replaces `geterrorhandler` only
where `securecallfunction` is absent and the Kit's `xpcall` path asks it. An
error-capturing addon such as BugGrabber may refuse the swap; the test says
so instead of passing. `collectReportedErrors` in
`MoltenCodesTest_SignalKit/SignalKitSuite.lua` is the reference.

## Gates

The addons are runtime Lua that the client loads, so they are held to the
runtime rules: `python3 -m tooling.lint` judges them in the runtime scope
(`selene.toml`), `stylua --check .` holds them to the repository's two-space
formatting (`stylua.toml`), and

```bash
lua-language-server --check tests/client --checklevel=Warning
```

type-checks them against `meta/` and the sources of TestKit's dependency
closure, which is what `.luarc.json` here lists. The same rules as for package
code apply ([`docs/CONTRIBUTING.md`](../../docs/CONTRIBUTING.md)): LuaCATS on
every function, `type(x) == "nil"` for the absence of a value the file did not
create, and a `selene: allow(global_usage)` with its reason at every global
access.
