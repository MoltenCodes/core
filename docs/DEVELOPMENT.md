# Development

This document defines the canonical local development workflow for the monorepo.

## Prerequisites

Repository tooling requires:

- Python 3.10 or newer;
- Lua 5.1-compatible development runtime;
- LuaRocks;
- Busted;
- StyLua;
- Selene.

CI pins exact third-party tool versions in [`.github/workflows/ci.yml`](../.github/workflows/ci.yml). Treat CI as the source of truth when reproducing the repository toolchain locally.

No Python third-party package is required by the repository tooling itself.

## Canonical commands

Run repository validation:

```bash
python3 -m tooling.validation.validate_repository
```

Run repository-tooling unit tests:

```bash
python3 -m unittest discover -s tooling/tests -p "test_*.py"
```

Run every package's Lua tests:

```bash
python3 -m tooling.test.run
```

Run one package's Lua tests:

```bash
python3 -m tooling.test.run registry
```

Lint all runtime Lua recursively:

```bash
python3 -m tooling.lint
```

Check Lua formatting:

```bash
stylua --check .
```

Format Lua:

```bash
stylua .
```

## Why commands go through tooling

Monorepo commands must not require contributors to update CI, editor tasks, and root configuration every time a package is added.

The test runner discovers package manifests, generates the Lua module path for selected packages, and invokes Busted. The lint runner recursively discovers runtime Lua under every package. Repository validation verifies package structure and documentation navigation.

This keeps package discovery in tooling rather than in shell globs or hard-coded package names.

## Editor setup

The repository includes VS Code recommendations and settings under `.vscode/`.

LuaLS behavior belongs in [`.luarc.json`](../.luarc.json). VS Code settings intentionally contain editor-specific behavior only, such as selecting StyLua as the Lua formatter. Keeping those concerns separate prevents duplicated settings from drifting.

Editor metadata under `meta/` exists only for static analysis and autocomplete. It is never a runtime dependency.

## Adding a package

A new publishable package begins as a directory under `packages/` with a valid `package.manifest.json` and the package structure described in [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md).

Capability packages follow the canonical `Kit` convention: lowerCamelCase package/directory/Registry identity (`signalKit`) and PascalCase Lua facade/module identity (`SignalKit`). `registry` / `Registry` is the infrastructure exception.

After adding a package, the normal repository commands should discover it automatically. If adding a package requires editing CI merely to make tests or linting see it, repository tooling is missing an abstraction and should be improved instead of adding another hard-coded package entry.
