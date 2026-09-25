# Testing

Testing is a first-class architectural concern.

## Layers

Each layer answers a question the one before it cannot, and each has one place
in the repository and one command:

| Layer | What it proves | Where | Run by |
|---|---|---|---|
| Package specs | a Kit's documented behaviour, error messages and upgrade paths, against the shared fake client | `packages/<id>/tests/*_spec.lua` | `python3 -m tooling.test.run <id>` |
| Allocation guards | a hot path allocates nothing (`collectgarbage("count")` around it, collector stopped) | the same suites, usually `Allocation_spec.lua` | the same command |
| Cross-package specs | a Kit with its optional dependencies present and absent, and several embedded copies resolving through Registry | the same suites (optional dependencies are on their `LUA_PATH`) | the same command |
| Example addon | the embedding instructions work as written: `.toc`, `embeds.xml`, load order, type-checking | `examples/tests/` | `python3 -m tooling.test.run examples` |
| Fixture fidelity | the shared fake client behaves like the real one | `packages/testKit/fidelity/` (runs under Busted and in the client) | `python3 -m tooling.test.run testKit`, and testKit in the client |
| In-client suites | what only the client shows: event order and payloads, combat lockdown, taint | testKit suites | the game client, by hand |
| Real-client tests | a package as the owner's installed client loads it: the published globals, the committed revisions, the documented behaviour on the client's own Lua | `tests/client/MoltenCodesTest_<Facade>/`, run by the harness `tests/client/MoltenCodesTest/` | `python3 -m tooling.client.install`, then `/mct run <package>` in the client |

Line coverage (`python3 -m tooling.test.coverage`) is a gate over the first
four layers, not a layer of its own: every spec except the allocation guards
must pass under LuaCov, and every package must stay at or above its floor in
`tooling/test/coverage-floors.json`; see [`TOOLING.md`](TOOLING.md#coverage).

### Allocation guards carry the `#allocation` tag

Every spec that measures allocation (`collectgarbage("count")` around a
workload, a TestEnv's `AllocatedKilobytes`, or a local helper doing the same)
carries the Busted tag `#allocation` in its description, on the `it` or on
the `describe` that holds only such specs:

```lua
describe("TimerKit allocation #allocation", function()
  it("allocates nothing to deliver a repeating tick", function()
    -- ...
  end)
end)

it("allocates nothing per event in steady state #allocation", function()
  -- ...
end)
```

The rule holds for every new allocation spec, in `Allocation_spec.lua` or any
other file. `python3 -m tooling.test.run` runs tagged specs like any other, so
the `test` job still judges them. The coverage run leaves them out with
`--exclude-tags=allocation`, because LuaCov's line hook allocates on every
line and would fail each of them; an untagged allocation spec therefore fails
the `coverage` job. Keep behavioural assertions out of a tagged `describe`,
because they would stop counting toward coverage: put them in a spec of their
own. To run only the guards, pass `--busted-arg=--tags=allocation` to the
runner.

### In-client suites

Only the real client proves four things: event order and payload shapes, combat
lockdown, taint (`issecurevariable` after our code runs) and the fidelity of the
shared fixture itself. `testKit` (development-only, never bundled) runs suites
for exactly those inside the client, gated on LifecycleKit phases and driven by
SchedulerKit jobs; everything else stays a Busted spec.
`packages/testKit/fidelity/FixtureFidelity.lua` runs in both environments
through `packages/testKit/tests/FixtureFidelity_spec.lua`, which lists what the
fixture does not model yet (`InCombatLockdown` in `AddonStub`, `C_Timer.After`
in `TimerStub`) and fails as soon as one of them starts passing, so the list
stays truthful. Add a fidelity test whenever a stub models a new host fact.

### Real-client tests

[`tests/client/`](../tests/client/README.md) turns the in-client layer into a
package-by-package procedure an owner of a real installation can follow. Each
package gets a development addon, `MoltenCodesTest_<Facade>`, whose TestKit
suites prove in the client what the shared fixture can only simulate; the
harness addon `MoltenCodesTest` runs them with `/mct run <package>`, prints one
line per test and a totals line, and saves the full `TestKit:Report()` with the
client's build, flavour, locale, date and loaded package revisions in its saved
variable, keyed by package ID.

```bash
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package registry
python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --remove
```

The first builds the release bundle and installs it with the harness, a fresh
copy of TestKit, a generated `Expected.lua` (every package's committed API and
revision) and the requested test addons; the second removes all of them, the
harness's and test addons' saved-variables files and the addons' lines in the
client's `AddOns.txt`. Nothing runs at login: runs start only by
`/mct run`. Each test addon's `EXPECTED.md` lists the exact chat lines of a
correct run and what to send back. The addons are runtime Lua for the gates:
the runtime lint scope, StyLua, and
`lua-language-server --check tests/client --checklevel=Warning`.

Pure Lua tests should remain independent from the WoW client whenever practical. WoW-specific integration should be isolated at narrow boundaries.

## Test framework

Busted is the primary pure-Lua test framework. CI pins its version so test behavior cannot change implicitly when LuaRocks publishes a newer release.

Typical tests use:

```lua
describe("Feature", function()
  it("does something", function()
    assert.are.equal(expected, actual)
  end)
end)
```

Executable specs use Busted's conventional suffix:

```text
*_spec.lua
```

Repository validation requires at least one such spec for every publishable package.

## Package-aware orchestration

Do not add package-specific source paths to root `.busted` configuration.

The canonical test command is:

```bash
python3 -m tooling.test.run
```

The runner discovers packages from manifests, generates `LUA_PATH` entries for
package source, package test support and the shared fixture, then invokes Busted
for every discovered package.

A package whose manifest declares `"distribution": "development"` is tested
exactly like any other but is never bundled or published; see
[`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#distribution).

### Which package sources a suite can `require`

A package's suite runs with these source directories on `LUA_PATH`, in this
order:

1. the package under test;
2. its required dependency closure, from `dependencies`;
3. each package named in `optionalDependencies`, together with that package's
   own required closure.

The order makes a module-name collision resolve in favour of the package under
test. Step 3 exists because an optional dependency is found at call time
through `Registry:Find` and is absent from the load order, yet the specs that
cover the "present" path need to load it. Declaring it in the manifest is all a
package does; its test environment does not add source directories by hand. The
specs that cover the "absent" path simply leave it out of the module chain they
load. See [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md#optional-dependencies).

The example addon under `examples/` is a target beside the packages, named
`examples`. It is the documented embedding instructions in executable form, so
it runs from the same command rather than from a second one CI could forget:

```bash
python3 -m tooling.test.run           # every package, then the examples
python3 -m tooling.test.run registry  # one package
python3 -m tooling.test.run examples  # only the example addon
```

`busted examples/tests` still works on its own; the root `.busted` puts the
shared fixture on the Lua path so it does.

Every selected target always runs, even when an earlier one fails, so one
broken target can never hide the state of the targets behind it. The runner
echoes each suite's Busted output, then prints one table of successes, failures,
errors and pending specs per target with a totals row, and exits non-zero when
any target failed. Counts come from Busted's own summary line; when that line
cannot be parsed the table shows `-` and falls back to the process exit status,
so a reporting change can never turn a passing suite into a failure.

This design allows new packages to participate in the test suite without editing CI or root Busted paths.

## Test isolation

Tests must not depend on execution order.

## Shared and package-specific test support

The host a package is tested against is shared; what a package does with that
host is not.

```text
tests/support/FrameworkTestEnv.lua      # the fake World of Warcraft client (facade)
tests/support/framework/                # one file per stub behind that facade
packages/<package>/tests/support/       # that package's own helpers
```

`tests/support/FrameworkTestEnv.lua` is the one fake client the whole suite
runs against. It provides the `CreateFrame` stub (including the two-slot
`RegisterUnitEvent` limit the real host enforces), `C_Timer`, `C_AddOns`,
`IsLoggedIn`, `securecallfunction`, `CombatLogGetCurrentEventInfo`, the
independent `GetTimePreciseSec` and `debugprofilestop` clocks, the
`geterrorhandler` capture behind `ReportedErrors`/`TakeReportedErrors`, the
`package.loaded` bookkeeping behind `Reset`/`NewPackage`/`ReloadPackage`, and
the `requireAfterFailedLoad` and `expectErrorContaining` helpers.

`FrameworkTestEnv.lua` is the facade specs require; the stubs themselves are one
module-level factory per file under `tests/support/framework/`:

| Module | What it stands in for |
|---|---|
| `Constants.lua` | Registry state keys, the namespace key, the unit-token limit, and the list of globals an environment owns. |
| `FrameStub.lua` | `CreateFrame` for Frame, Button, CheckButton, Slider, EditBox and ScrollFrame; named frames as globals; sizes and anchors resolved into unscaled rectangles, with anchors to the region itself or into a cycle refused as the client refuses them; `OnShow`/`OnHide` when a frame's own shown flag changes (never for its children); one focused edit box at a time with `OnEditFocusLost`/`OnEditFocusGained`; font strings and textures; frame-type state; the event registration bookkeeping; and `Emit`/`Tick`/`Frames`/`ActiveOnUpdateCount`/`RunScript`/`MoveFrame`/`RecordAnchorCalls`. |
| `TimerStub.lua` | `C_Timer` and the native timer handles, including the three host failures a package must survive. |
| `ClockStub.lua` | `GetTimePreciseSec` and `debugprofilestop`, kept independent of each other. |
| (in `LifecycleKitTestEnv.lua`) | `InCombatLockdown` and the `EnterCombat` / `LeaveCombat` helpers, stubbed by the lifecycleKit suite alone; worth promoting into `AddonStub` when a second suite needs them. |
| `ClientStub.lua` | `WOW_PROJECT_ID`, `GetBuildInfo` and one host profile per supported flavour (`wowProfile`), plus secret values, event validity, spells and addon metadata. |
| `AddonStub.lua` | `C_AddOns`, `IsLoggedIn`, `CombatLogGetCurrentEventInfo`, and the `LoadAddon`/`Login`/`Logout` helpers. |
| `ErrorHandlerStub.lua` | `geterrorhandler` and `securecallfunction`, and the two ways a spec reads what reached them. |

Each stub module exposes the same three functions over the environment's shared
state table: `Reset(state)` returns the fields it owns to their initial values,
`InstallGlobals(state)` installs the globals it owns, and
`Attach(environment, state)` publishes its helpers on the environment. The
facade owns what is not any one stub's: option handling, the module chain's load
order, and the `Reset`/`NewPackage`/`ReloadPackage` lifecycle that drives every
stub together. `ErrorHandlerStub` has no `InstallGlobals`, because a pure-Lua
package's specs opt into a host error sink with `InstallHostErrorHandler()`
rather than having one installed for them.

Adding a stub is therefore a new file under `framework/` and one entry in the
facade's `STUBS` list. Specs never require the stub modules directly.

`FrameworkTestEnv.New(options)` builds one environment per package, each with
its own stub state. `options.modules` is the module chain in load order, and the
package under test is the last entry:

```lua
local FrameworkTestEnv = require("FrameworkTestEnv")

local TimerKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "TimerKit" },
})
```

`options.wowApi = false` suits a pure-Lua package whose specs opt into a host
error sink explicitly, and `options.legacyRegistryState = true` also clears the
retired Registry API 1 state key.

Each package keeps `packages/<package>/tests/support/<Kit>TestEnv.lua` for what
is genuinely its own: the load order above, and any helper only its specs can
describe. That file is package-owned and published with the package; the shared
fixture is repository test scaffolding and is not.

`tooling/test/run.py` puts the shared directory on every target's `LUA_PATH`,
after the package's own support directory, so a package could shadow a shared
module from its own `tests/support/` without the runner changing.

Test-only helpers are not public runtime API.

## Support modules must not rely on Busted's injected globals

Busted injects `describe`, `it`, `assert` and the rest of its vocabulary into
spec chunks only. A support module under `tests/support/` is loaded through
plain `require`, so inside it `assert` is Lua's own `assert` function, which
takes a value and a message and knows nothing about `assert.are.equal`. Reaching
for a luassert matcher there fails with an unhelpful "attempt to index a
function value" at the first call instead of reporting the real problem.

Every assertion in a support module is therefore one of two kinds, and the kind
decides the mechanism:

- **A stub precondition** — the support code itself is being misused, for
  example a fake `CreateFrame` asked for something other than a `"Frame"`.
  Raise a plain `error("...", 2)` with a message that names the stub and the
  unexpected argument. This is not a test expectation; it is the helper
  refusing an input it was never written to model.
- **A genuine test expectation** — the helper asserts something about the code
  under test, for example that a timer the package was supposed to create
  actually exists before firing it. Import the library by name at the top of the
  module:

  ```lua
  local assert = require("luassert")
  ```

  luassert is a Busted dependency, so it is always available wherever the specs
  run, and naming it explicitly keeps the helper honest about what it needs.

The same rule applies to the rest of Busted's vocabulary: a support module never
calls `describe`, `it`, `before_each` or `spy` at the top level. If a helper
needs Busted's lifecycle, it belongs in the spec that owns it.

## Bootstrap specs and failed `require`

Lua 5.1 marks a module as in-progress in `package.loaded` before running its
chunk and does not clear that marker when the chunk raises. A second `require`
of the same module therefore reports `loop or previous error loading module`
rather than re-running the bootstrap.

A spec that checks more than one bootstrap guard must clear the marker between
attempts, otherwise every expectation after the first silently matches the wrong
error and the guard it claims to cover is never executed:

```lua
local function requireAfterFailedLoad(moduleName)
  package.loaded[moduleName] = nil
  return require(moduleName)
end
```

Each package's `TestEnv.Reset()` clears the same marker, so a spec that calls
`Reset` before every `require` already satisfies this. The shared fixture also
exposes that helper directly as `TestEnv.requireAfterFailedLoad(moduleName)`.

## Runtime dependencies

Testing dependencies are development-only dependencies and must never become runtime WoW dependencies.

## Linting test code

Specs are linted with the same Selene rules as runtime code. Busted injects its
vocabulary into spec chunks as globals rather than as a module, so test code is
judged against the `busted.yml` standard library selected by
`selene-tests.toml`; `python3 -m tooling.lint` runs both scopes. See
[`TOOLING.md`](TOOLING.md) for what that standard corrects and why.

## CI

CI validates formatting, Lua linting for runtime and test code, the
lua-language-server check for every source directory (the real-client test
addons included), repository structure,
that the generated `apiKit` outputs match their committed metadata
(`python3 -m tooling.api.generate --all --check`), repository-tooling unit
tests on the supported Python floor and the current release, the Lua
package and example test suites, and line coverage: the same suites under
LuaCov without the `#allocation` specs, held to per-package floors.

The generated data of `apiKit` has tests of its own in the tooling suite:
for every committed flavour a stub host is built from the metadata and the
committed runtime file must bind every documented function and nothing else
(`tooling/tests/test_api_committed_flavours.py`), the generators' and the
diff's corpus tests run against the committed Retail metadata, and a Busted
spec per flavour loads the file against the real facade. Two environment
variables point those tests at other data; see
[`TOOLING.md`](TOOLING.md#api-metadata-tooling).

As dependency graphs become larger, orchestration may optimize toward affected-package testing, but the full-suite command remains the correctness baseline.
