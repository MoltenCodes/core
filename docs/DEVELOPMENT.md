# Development

This document defines the canonical local development workflow for the monorepo.

## Prerequisites

Repository tooling requires:

| Tool | Version | Why |
|---|---|---|
| Python | 3.10 or newer (CI runs 3.13) | repository tooling, validation, test orchestration |
| Lua | 5.1.5 | the World of Warcraft client runtime; runtime code must stay 5.1-compatible |
| LuaRocks | 3.13.0 | installs Busted |
| Busted | 2.3.0-1 | pure-Lua test framework |
| StyLua | 2.5.2 | the authoritative Lua formatter |
| Selene | 0.31.0 | runtime Lua linting |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) pins these versions and
is the source of truth. When the table above and CI disagree, CI wins and this
document is the thing that needs fixing.

No Python third-party package is required by the repository tooling itself.

## Installing the toolchain

### Lua 5.1, LuaRocks and Busted

Lua 5.1 reached end of life long ago. Homebrew ships only `lua` (5.5), `lua@5.5`
and `lua@5.4` — there is no `lua@5.1` formula — so the interpreter is installed
into a private prefix rather than system-wide. The framework targets 5.1 because
that is what the WoW client runs; testing against a newer Lua would let 5.2+
behaviour leak into runtime code unnoticed.

[hererocks](https://github.com/luarocks/hererocks) builds a matched
Lua + LuaRocks pair into one directory and is the recommended route:

```bash
pipx install hererocks
hererocks ~/.local/lua51 --lua 5.1.5 --luarocks latest
export PATH="$HOME/.local/lua51/bin:$PATH"
luarocks install busted 2.3.0-1
```

Put the `export` line in your shell profile so `lua`, `luarocks` and `busted`
resolve to that prefix in every new shell. Nothing outside that directory is
modified, and removing the directory removes the toolchain.

[asdf](https://asdf-vm.com) with the `lua` plugin is an equally good
alternative if you already manage runtimes with it:

```bash
asdf plugin add lua
asdf install lua 5.1.5
asdf local lua 5.1.5
luarocks install busted 2.3.0-1
```

Verify the result before running anything else:

```bash
lua -v        # Lua 5.1.5
busted --version
```

### StyLua, Selene and the language server

These are standalone binaries and come from Homebrew:

```bash
brew install stylua selene lua-language-server
```

`lua-language-server` is editor tooling only; it is not needed to run the
repository commands. Selene can also be installed with
`cargo install selene --version 0.31.0 --locked --no-default-features`, which is
what CI does.

## Troubleshooting

### `busted: command not found`

The Lua 5.1 prefix is not on `PATH`. `python3 -m tooling.test.run` reports the
same thing and repeats the install commands. Check, in order:

1. `command -v busted` — empty means the prefix is missing from `PATH`.
   Re-run `export PATH="$HOME/.local/lua51/bin:$PATH"` and make sure that line
   is in your shell profile, not just the current shell.
2. `lua -v` — anything other than `Lua 5.1.5` means a different interpreter is
   winning the `PATH` lookup. Homebrew's `lua` formula is Lua 5.5 and
   shadows the 5.1 prefix whenever it comes first.
3. `luarocks list busted` — if the prefix is on `PATH` but Busted is missing,
   run `luarocks install busted 2.3.0-1`.

Installing Busted through a system LuaRocks bound to a newer Lua produces a
`busted` that runs but fails specs in ways that do not reproduce in CI. If
results disagree with CI, confirm `lua -v` first.

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
