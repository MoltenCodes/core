# Development

This document defines the canonical local development workflow for the monorepo.

## Prerequisites

Repository tooling requires:

| Tool | Version | Why |
|---|---|---|
| Python | 3.10 or newer (CI runs 3.10 and 3.13) | repository tooling, validation, test orchestration |
| Lua | 5.1.5 | the World of Warcraft client runtime; runtime code must stay 5.1-compatible |
| LuaRocks | 3.13.0 | installs Busted |
| Busted | 2.3.0-1 | pure-Lua test framework |
| StyLua | 2.5.2 | the authoritative Lua formatter |
| Selene | 0.31.0 | runtime Lua linting |
| Node.js | 22.18 or newer (CI runs 24) | runs the pinned cspell for the spell check; optional locally |

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) pins these versions and
is the source of truth. When the table above and CI disagree, CI wins and this
document is the thing that needs fixing.

No Python third-party package is required by the repository tooling itself.
cspell is not installed into the repository either: `python3 -m tooling.spell`
runs a pinned release through `npx`, and skips with a note when Node is missing.

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

`lua-language-server` is used both by editors and by the `--check` gate below;
it is not needed to run the Lua test suite. CI installs the published
`selene-light` and `lua-language-server` binaries and verifies each download
against a SHA-256 recorded in the workflow, so the versions here and there stay
the same without CI rebuilding Selene from source on every run.

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

Run every package's Lua tests and the example addon's specs:

```bash
python3 -m tooling.test.run
```

Run one target's Lua tests:

```bash
python3 -m tooling.test.run registry
python3 -m tooling.test.run examples
```

Lint all Lua recursively, runtime and test alike:

```bash
python3 -m tooling.lint
```

Test code is judged against the Busted standard library in
[`../busted.yml`](../busted.yml), selected by
[`../selene-tests.toml`](../selene-tests.toml); runtime Lua keeps the stricter
[`../selene.toml`](../selene.toml). Both scopes run, and both must report zero
errors and zero warnings.

Spell-check the documentation:

```bash
python3 -m tooling.spell
```

It runs the cspell release pinned in `tooling/spell.py` over the files
[`../cspell.json`](../cspell.json) lists, and needs Node 22.18 or newer; without
it the command prints a note and exits 0. A word cspell does not know is either
a typo to fix or a deliberate term for
[`../tooling/spell-words.txt`](../tooling/spell-words.txt); the rule for telling
them apart is in [`TOOLING.md`](TOOLING.md#adding-a-word).

Print the supported `## Interface` line, from the one table that defines it:

```bash
python3 -m tooling.validation.interface_numbers
```

Check Lua formatting:

```bash
stylua --check .
```

Format Lua:

```bash
stylua .
```

Type-check one package's runtime Lua:

```bash
lua-language-server --check packages/registry/src --checklevel=Warning
```

and the example addon, which is checked against the packages' own annotations:

```bash
lua-language-server --check examples --checklevel=Warning
```

`--check` treats the directory it is given as its workspace root and ignores
parent configuration, so each package source directory and `examples/` owns a
`.luarc.json`. Repository validation keeps those files in step with what they
describe: a package's file with the manifests, and `examples/.luarc.json` with
`examples/embeds.xml`, so the example is only ever type-checked against the
packages it actually embeds. See [`CONTRIBUTING.md`](CONTRIBUTING.md).

Check that the generated `apiKit` outputs (runtime bindings, types, history)
match the committed metadata, as CI does:

```bash
python3 -m tooling.api.generate --all --check
```

The metadata pipeline itself (capturing the client's documentation tables,
normalising, diffing and generating) is described in
[`TOOLING.md`](TOOLING.md#api-metadata-tooling); the refresh procedure for a
new client build is `packages/apiKit/docs/UPDATING.md`.

Check the workflow file after editing it:

```bash
actionlint
```

## Supported Python

Repository tooling supports Python 3.10 and newer, declared once as
`requires-python` in [`../pyproject.toml`](../pyproject.toml). Repository
validation refuses to run on anything older and checks that the declaration and
the validator's own constant agree. Every CI job that runs repository tooling —
the Lua tests, the linter, the spell check, repository validation and the
release build — runs on both 3.10 and 3.13, so the floor is exercised rather than asserted.

## Client behaviour the test stubs model on request

The shared fixture under `tests/support/` stands in for the client; its stubs
are described in [`TESTING.md`](TESTING.md). The Retail 12.x access rules that
[`EMBEDDING.md`](EMBEDDING.md#secret-values-retail-12x) documents for consumers
are modelled by `ClientStub.lua`, which is off unless a test environment asks
for a host profile (`wowProfile`), so every other suite sees the same host as
before:

- `issecretvalue(value)` reports a **secret value** (patch 12.0.0 and later).
  Tainted code may store one, pass it to functions, and concatenate or format
  it into another secret string; comparing it, arithmetic, `#`, indexing,
  calling it, a boolean test on a secret boolean and using it as a table key
  raise. Some unit and aura APIs return secrets in combat.
- `frame:IsForbidden()` and `frame:CanBeAccessedInContext()` (patch 12.1.0)
  say whether a frame found by enumeration may be touched at all.
- `issecurevariable` and `securecallfunction` are the taint probes and the
  isolation call; the fixture already stubs `securecallfunction`.

Their signatures are declared in [`../meta/wow/`](../meta/wow/). A spec that
needs a secret builds a test environment with a `wowProfile` and calls
`NewSecretValue()`; the `mainline` profile installs `issecretvalue`,
`C_EventUtils.IsEventValid` and the frame access probes, and the other profiles
omit what their client lacks. Code under test must treat a missing
`issecretvalue` as "never secret", which is what every client without secret
values looks like; `ClientKit:IsSecret` is that check, ready made.

## Measuring a change with ProfileKit

[`profileKit`](../packages/profileKit/README.md) is how a Kit change that claims
to be faster, or that touches a hot path, gets a number. In the package suites
the shared fixture's `debugprofilestop` is the `ClockStub`, which moves only
when a spec advances it: a ProfileKit spec there proves the wiring, not the
speed. To time real work, write a throwaway spec that puts real CPU time in the
clock's place after the chain is loaded and before ProfileKit binds it:

```lua
local Env = require("SignalKitTestEnv") -- the suite of the Kit being changed

it("measures SignalKit Fire", function()
    local SignalKit = Env.NewPackage() -- resets the stubs, so override after it
    rawset(_G, "debugprofilestop", function()
        return os.clock() * 1000 -- CPU milliseconds, like the client clock
    end)
    local ProfileKit = require("ProfileKit") -- binds the clock now
    ProfileKit:Enable()

    local signal = SignalKit:New()
    signal:Connect(function() end)
    local fire = ProfileKit:Section("SignalKit.Fire")
    for _ = 1, 100000 do
        fire:Begin()
        signal:Fire("player", 42)
        fire:End()
    end

    local row = ProfileKit:Report()[1]
    print(row.name, row.count, row.total, row.max)
    package.loaded.ProfileKit = nil
end)
```

`python3 -m tooling.test.run` puts only a package's own dependency closure on
the Lua path, so run the file with Busted directly and name the source and
support directories it needs:

```bash
LUA_PATH="packages/registry/src/?.lua;packages/signalKit/src/?.lua;packages/profileKit/src/?.lua;packages/signalKit/tests/support/?.lua;tests/support/?.lua;;" \
  busted path/to/FireCost_spec.lua
```

Run it against the code before and after the change on the same machine, and
quote `count`, `total` and `max` from both runs in the change description. The
clock reads are inside the span, so compare the two totals rather than reading
either as an absolute cost. Do not commit the spec: the numbers depend on the
machine, and a timing threshold fails on a busy CI runner. What does get
committed is an allocation guard (`collectgarbage("count")` around the hot path
with the collector stopped) and the specs that pin behaviour. In the client,
the same sections, enabled from a debug build, measure the real frame.

## Building a release bundle

Build a distributable bundle:

```bash
python3 -m tooling.package.build --all --out dist
```

Build it and check the checksums it wrote against the files it produced:

```bash
python3 -m tooling.package.build --all --out dist --verify
```

`--verify` is what CI runs, together with `sha256sum --check --strict
CHECKSUMS.txt` inside the output directory — the command somebody verifying a
downloaded artifact would run. Both must pass before a bundle is published.

See [`RELEASES.md`](RELEASES.md) for the artifact layout and checksums.

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
