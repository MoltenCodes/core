# Contributing

## Development principles

Keep changes small, explicit, documented, and testable.

StyLua is the authoritative Lua formatter for this repository. LuaLS formatting is disabled in [`.luarc.json`](../.luarc.json) to avoid competing formatters.

Before submitting a change:

1. Run `python3 -m tooling.validation.validate_repository`.
2. Run `python3 -m unittest discover -s tooling/tests -p "test_*.py"` when tooling changed.
3. Run `python3 -m tooling.test.run`.
4. Run `python3 -m tooling.lint`.
5. Run `stylua --check .`.
6. Update package documentation when public behavior changes.
7. Update the owning package changelog for user-visible changes.

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for local setup.

## Commit scope

Prefer commits that represent one coherent change.

Do not mix unrelated package changes without a reason.

## Public API changes

Public API changes require:

- documentation;
- tests;
- changelog entry;
- explicit API-generation consideration.

A breaking public contract must not be hidden behind an implementation revision.

## New packages

New packages must satisfy the package layout and manifest contract in [`PACKAGE_MANIFEST.md`](PACKAGE_MANIFEST.md).

Public framework capability packages use a lowerCamelCase `Kit` package ID and matching PascalCase Lua facade/module name (for example `eventKit` / `EventKit`). `registry` / `Registry` is the infrastructure exception.

Repository tooling should discover a new package automatically. Avoid adding package names directly to CI or editor configuration.

## Documentation language

Repository and package documentation is written in English.
