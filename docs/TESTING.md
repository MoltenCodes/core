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

## Runtime dependencies

Testing dependencies are development-only dependencies and must never become runtime WoW dependencies.

## CI

CI validates formatting, runtime Lua linting, repository structure, repository-tooling unit tests, and the Lua package test suite.

As dependency graphs become larger, orchestration may optimize toward affected-package testing, but the full-suite command remains the correctness baseline.
