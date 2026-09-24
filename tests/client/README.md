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
`--flavour-dir` selects another client folder than `_retail_`, and
`--dry-run` prints what would be installed.

In the game:

1. Log in. The chat frame shows one line, for example
   `MoltenCodes Test: test suites loaded for registry. Type /mct run registry to run them; /mct help lists every command.`
2. Type `/mct run registry`. A line per test and a totals line follow within a
   second or two.
3. `/reload` (or log out) so the client writes the saved variables.
4. Send back `WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.

Each test addon's `EXPECTED.md` lists the exact lines a correct run prints.

When testing is over, remove everything the installer added, and the saved
results with it:

```bash
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --remove
```

That deletes `MoltenCodes`, `MoltenCodesTest` and every `MoltenCodesTest_*`
folder from `AddOns`, and every `MoltenCodesTest.lua` and
`MoltenCodesTest.lua.bak` under `WTF/Account/*/SavedVariables/` and
`WTF/Account/*/*/*/SavedVariables/`. Add `--dry-run` to see the list first.
Both commands refuse when the `AddOns` folder does not exist, and neither
follows a symbolic link out of the game folder.

## The harness

| Command | What it does |
|---|---|
| `/mct run` | Runs the suites of every loaded test addon. |
| `/mct run <package>` | Runs the suites of one package, for example `/mct run registry`. |
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
package ID. A run replaces its package's entry:

```lua
MoltenCodesTestResults = {
    registry = {
        schema = 1,
        package = "registry",
        client = {
            version = "12.1.0", build = "...", buildDate = "...", interface = 120100,
            projectId = 1, locale = "enUS", date = "2026-09-24 18:00:00",
            registryRevision = 12, expectedInstalled = true,
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
`WOW_PROJECT_ID`, `GetLocale()`, `date()`, and every package Registry holds
with the `REVISION` its facade publishes. `report` has the shape of
`TestKit:Report()` (see the [TestKit API](../../packages/testKit/docs/API.md#testkitreport)),
restricted to the package's suites, with each test's `logs`.

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
## Interface: 120100
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
named `<packageId>.<part>` that waits for the test addon's `ready` phase;
`options` is optional, and its one field, `timeoutSeconds`, lengthens
TestKit's 10-second limit per test for a suite whose test waits for the player
(the LifecycleKit training-dummy test waits up to 30 seconds for combat to
end). `Harness:GetExpectedPackages()` returns what `Expected.lua` lists. Every test
name says what it proves, every test is independent of the others, and a test
cleans up what the API lets it clean up; the file header says what remains for
the session. Test here only what the fake client cannot show (see
[`docs/TESTING.md`](../../docs/TESTING.md#layers)); everything else belongs in
the package's Busted specs.

Add an `EXPECTED.md` next to the `.toc`: the exact chat lines of a correct
run, what counts as unexpected, and what to send back.

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
(`selene.toml`), `stylua --check .` formats them, and

```bash
lua-language-server --check tests/client --checklevel=Warning
```

type-checks them against `meta/` and the sources of TestKit's dependency
closure, which is what `.luarc.json` here lists. The same rules as for package
code apply ([`docs/CONTRIBUTING.md`](../../docs/CONTRIBUTING.md)): LuaCATS on
every function, `type(x) == "nil"` for the absence of a value the file did not
create, and a `selene: allow(global_usage)` with its reason at every global
access.
