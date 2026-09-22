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

The runner discovers packages from manifests, generates `LUA_PATH` entries for package source and test support, then invokes Busted for every discovered package.

Every selected package always runs, even when an earlier package fails, so one
broken package can never hide the state of the packages behind it. The runner
echoes each suite's Busted output, then prints one table of successes, failures,
errors and pending specs per package with a totals row, and exits non-zero when
any package failed. Counts come from Busted's own summary line; when that line
cannot be parsed the table shows `-` and falls back to the process exit status,
so a reporting change can never turn a passing suite into a failure.

To run a subset:

```bash
python3 -m tooling.test.run registry
```

This design allows new packages to participate in the test suite without editing CI or root Busted paths.

## Test isolation

Tests must not depend on execution order.

Package-specific helpers belong under:

```text
packages/<package>/tests/support/
```

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
`Reset` before every `require` already satisfies this.

## Runtime dependencies

Testing dependencies are development-only dependencies and must never become runtime WoW dependencies.

## CI

CI validates formatting, runtime Lua linting, repository structure, repository-tooling unit tests, and the Lua package test suite.

As dependency graphs become larger, orchestration may optimize toward affected-package testing, but the full-suite command remains the correctness baseline.
