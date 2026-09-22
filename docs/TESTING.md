# Testing

Testing is a first-class architectural concern.

## Layers

```text
Pure Lua unit tests
        ↓
Package integration tests
        ↓
Cross-package tests
        ↓
World of Warcraft integration tests
```

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
| `FrameStub.lua` | `CreateFrame`, the Frame registration bookkeeping, and `Emit`/`Tick`/`Frames`/`ActiveOnUpdateCount`. |
| `TimerStub.lua` | `C_Timer` and the native timer handles, including the three host failures a package must survive. |
| `ClockStub.lua` | `GetTimePreciseSec` and `debugprofilestop`, kept independent of each other. |
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
    modules = { "Registry", "SignalKit", "EventKit", "LifecycleKit", "TimerKit" },
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
lua-language-server check for every source directory, repository structure,
repository-tooling unit tests on the supported Python floor and the current
release, and the Lua package and example test suites.

As dependency graphs become larger, orchestration may optimize toward affected-package testing, but the full-suite command remains the correctness baseline.
