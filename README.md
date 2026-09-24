# MoltenCodes WoW Framework

[![CI](https://github.com/MoltenCodes/core/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/MoltenCodes/core/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/MoltenCodes/core?include_prereleases&sort=semver)](https://github.com/MoltenCodes/core/releases)

A modular Lua 5.1 framework for professional World of Warcraft addon
development: 28 small packages, called Kits, each independently versioned,
tested and publishable, that an addon embeds one by one or loads together as the
standalone addon `MoltenCodes`.

Every Kit registers itself with `registry`, which keys it by package ID and API
generation and keeps one shared instance per session however many addons embed
their own copy: a newer revision upgrades the shared table in place, an older
one steps aside. Runtime code is Lua 5.1, allocation-conscious on hot paths,
bounded by default and safe around the Retail secret-value and taint rules.

## Packages

Twenty-seven release packages and one development package. Each links to its
README; its full contract is the package's `docs/API.md`.

| Package | Purpose |
|---|---|
| [`registry`](packages/registry/) | Zero-dependency shared package registration, discovery and in-place revision upgrades. |
| [`signalKit`](packages/signalKit/) | Deterministic, re-entrant callback dispatch with explicit connection lifetimes, subscriber-transition hooks, journals and named message buses. |
| [`eventKit`](packages/eventKit/) | Lazy game-event subscriptions on SignalKit, unit-event filtering and combat-log routing by sub-event. |
| [`lifecycleKit`](packages/lifecycleKit/) | Replay-aware per-addon loading, readiness and shutdown, a shared combat gate with a bounded out-of-combat queue, and a halted state. |
| [`moduleKit`](packages/moduleKit/) | Addon-scoped module lifecycle, dependency graphs, dependency injection with checked interfaces, and dependency policies. |
| [`timerKit`](packages/timerKit/) | Cancelable one-shot and repeating timers with ownership scopes, and addon scopes closed at logout through LifecycleKit or EventKit when present. |
| [`schedulerKit`](packages/schedulerKit/) | Cooperative, frame-budgeted scheduling with priorities, cancellation scopes and TimerKit delays. |
| [`poolKit`](packages/poolKit/) | Allocation-conscious bounded object pooling with deterministic ownership and cleanup. |
| [`clientKit`](packages/clientKit/) | Client flavour, build floor, probed capability flags, secret-value and frame-access probes, and shims with one shape per host call. |
| [`cacheKit`](packages/cacheKit/) | Bounded LRU and TTL caches, memoisation, negative entries, lazy namespaces, bounded queues and snapshots with diffs. |
| [`profileKit`](packages/profileKit/) | Zero-cost-when-off performance sections with count, total, spike and a sorted report. |
| [`readinessKit`](packages/readinessKit/) | Named readiness gates for host data that arrives after load: polling, timeouts, negative caching and bounded waiters. |
| [`schemaKit`](packages/schemaKit/) | Sealed value schemas with structured, secret-safe failures: one validation core for arguments, saved variables, options and messages. |
| [`localeKit`](packages/localeKit/) | Per-addon translations, missing-key reporting and coverage, indexed format specifiers. |
| [`hookKit`](packages/hookKit/) | Reversible, secure-first hooking of functions, methods and frame scripts in three named semantics. |
| [`settingsKit`](packages/settingsKit/) | Saved variables with scopes, schema-validated writes, defaults never written back, profiles and versioned migrations. |
| [`optionsKit`](packages/optionsKit/) | A typed, validated, introspectable options tree bound to getters or a SettingsKit database, with no renderer. |
| [`commandKit`](packages/commandKit/) | Slash commands with hyperlink-aware parsing, generated usage, schema-checked arguments, sinks, completion and an OptionsKit command line. |
| [`codecKit`](packages/codecKit/) | Serialise, compress and channel-encode values behind a self-describing header; decoding never raises. |
| [`interopKit`](packages/interopKit/) | The LibStub bridge: expose Kits to LibStub consumers and adopt LibStub libraries read-only. |
| [`mediaKit`](packages/mediaKit/) | A typed media registry with font scripts, sorted cached lists, per-consumer defaults and LibSharedMedia adoption and mirroring. |
| [`brokerKit`](packages/brokerKit/) | LibDataBroker-compatible data objects: typed attributes as plain fields, per-attribute change signals and a two-way LibDataBroker-1.1 bridge. |
| [`logKit`](packages/logKit/) | Levelled, structured logging with lazy secret-safe formatting, a bounded journal and chat, callback and table sinks. |
| [`compatKit`](packages/compatKit/) | Versioned shims with a host opt-out, provider registries with a fallback cascade, and the catalogue of taint-hostile subsystems as data. |
| [`commKit`](packages/commKit/) | Addon messaging of any length: a chunk protocol with bounded reassembly, refusing priority queues, a session bandwidth budget and sync sets. |
| [`widgetKit`](packages/widgetKit/) | Pooled, versioned widgets with explicit layouts, saveable anchors and an OptionsKit renderer. |
| [`apiKit`](packages/apiKit/) | The flavour-aware, typed wrapper over the World of Warcraft API (`wow.retail.api`, ...), generated from the client's own documentation tables. |
| [`testKit`](packages/testKit/) | Development only, never bundled: in-client test suites in LifecycleKit phases and SchedulerKit jobs, with structured results. |

## Using the framework in an addon

An addon either embeds the Kits it needs or depends on the installed
`MoltenCodes` addon, which loads every release Kit. Embedded copies leave
nothing for players to download separately, and several addons shipping
different copies of one Kit reconcile to one shared instance at runtime.

Load `Registry.lua` first and every other Kit after the Kits it depends on,
then resolve each Kit by package ID and API generation:

```xml
<Ui xmlns="http://www.blizzard.com/wow/ui/">
    <Script file="Libs\MoltenCodes\registry\Registry.lua" />
    <Script file="Libs\MoltenCodes\timerKit\TimerKit.lua" />
</Ui>
```

```lua
local ADDON_NAME = ...
local Registry = MoltenCodes.Registries[2]
local TimerKit = Registry:Get("timerKit", 1)

-- A scope owned by this addon, closed with the addon's other scopes at logout.
local timers = TimerKit:ForAddon(ADDON_NAME)
timers:After(5, function()
    print("five seconds later")
end)
```

- [`docs/EMBEDDING.md`](docs/EMBEDDING.md) is the guide: directory layout, the
  load order and the files each Kit needs, supported Interface numbers,
  coexistence with LibStub, taint and secret values, the combat log, `/reload`
  semantics, performance guidance, and the exact error each load-order mistake
  produces.
- [`examples/`](examples/) is a complete example addon that a spec loads from
  login to logout and the language server type-checks on every run, so it
  cannot drift from the framework.

Build the bundle you embed or install:

```bash
python3 -m tooling.package.build --all --out dist --verify
```

This writes `dist/MoltenCodes/` in the layout an addon embeds, with a generated
`MoltenCodes.toc` so the same folder installs as a standalone addon, a
`manifest.json` recording every package's version, API generation, revision and
the load order, and SHA-256 checksums in `dist/CHECKSUMS.txt`.
`--package <id>` builds one Kit with the Kits it requires instead. Every commit
on `main` also leaves this bundle behind as a CI artefact, and releases are
described in [`docs/RELEASES.md`](docs/RELEASES.md).

## Quick start for contributors

Install the toolchain from [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md):
Python 3.10 or newer, Lua 5.1.5 with LuaRocks and Busted (built with hererocks),
StyLua, Selene and lua-language-server, and Node.js for the spell check. Then:

```bash
python3 -m tooling.validation.validate_repository             # layout, indexes, packaging, links
python3 -m unittest discover -s tooling/tests -p "test_*.py"  # the tooling's own tests
python3 -m tooling.test.run                                   # every Kit's specs and the example addon
python3 -m tooling.lint                                       # Selene over runtime and test Lua
stylua --check .                                              # formatting
python3 -m tooling.spell                                      # the documentation's spelling
```

`python3 -m tooling.test.run timerKit` runs one Kit's suite. Every command
answers `--help`.

## How the repository is organised

```text
.
├── .github/                 # workflows, the shared Lua setup action, issue forms, labels, Dependabot, CODEOWNERS
├── .luacov                  # LuaCov configuration for the coverage report
├── .pkgmeta                 # addon-site packager metadata
├── .vscode/                 # shared editor settings and tasks
├── busted.yml               # Selene standard library for Busted test code
├── cspell.json              # spell-check configuration for the documentation
├── docs/                    # repository-wide documentation; start at docs/README.md
├── examples/                # a complete example addon, loaded by its own spec
├── lychee.toml              # Markdown link-check configuration
├── meta/                    # editor-only LuaCATS definitions, including the game API
├── packages/                # the 28 Kits, one directory each (see packages/README.md)
├── pyproject.toml           # the supported Python floor for the tooling
├── selene.toml              # Selene configuration for runtime Lua
├── selene-tests.toml        # Selene configuration for test Lua
├── stylua.toml              # StyLua formatting rules
├── tests/support/           # the shared test fixture: the fake game client
└── tooling/                 # repository tooling; never a runtime dependency
```

Every Kit has the same layout: `package.manifest.json`, a README, a changelog,
`docs/API.md`, one facade under `src/` with its `.luarc.json`, and specs under
`tests/` with a `tests/README.md` and `tests/support/<Facade>TestEnv.lua`.
Tooling discovers the Kits from their manifests; nothing keeps a second
hard-coded list, and repository validation enforces the layout
([`docs/PACKAGE_MANIFEST.md`](docs/PACKAGE_MANIFEST.md)).

## Tooling and CI

Repository tooling is Python, standard library only, under `tooling/`:
validation, test orchestration, linting, coverage, packaging, the release
steps and the apiKit metadata pipeline. [`docs/TOOLING.md`](docs/TOOLING.md)
describes every command.

Every push to `main` and every pull request runs one required check, `ci`,
which needs every gate: the Lua 5.1 tests, lua-language-server type checks,
StyLua, Selene, the bundle build with checksum verification, the spell check,
repository validation and the tooling tests on Python 3.10 and 3.14, commit
subjects, a secret scan and actionlint, plus a line-coverage report. Separate
workflows check Markdown links, watch the community mirror for new client
builds for apiKit, keep labels in sync and build releases. Every action is
pinned to a commit SHA and every downloaded binary to a SHA-256;
[`docs/TOOLING.md`](docs/TOOLING.md#continuous-integration) explains each job
and why it is there.

## Documentation

Start with [`docs/README.md`](docs/README.md), the documentation map.

- [`docs/EMBEDDING.md`](docs/EMBEDDING.md) — how an addon embeds and loads the framework.
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — package boundaries, dependency direction and runtime architecture.
- [`docs/DESIGN_CONSTITUTION.md`](docs/DESIGN_CONSTITUTION.md) — the design principles every change preserves.
- [`docs/PACKAGE_MANIFEST.md`](docs/PACKAGE_MANIFEST.md) — package metadata, layout and versioning contracts.
- [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) — local setup and the canonical commands.
- [`docs/TESTING.md`](docs/TESTING.md) — test layers, conventions and orchestration.
- [`docs/TOOLING.md`](docs/TOOLING.md) — repository tooling and continuous integration.
- [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md) — contribution workflow and annotation rules.
- [`docs/RELEASES.md`](docs/RELEASES.md) — versioning, tags, the build and release artifacts.
- [`docs/ROADMAP.md`](docs/ROADMAP.md) — what was decided and delivered, and what remains.

## Principles

- Small, composable runtime packages with explicit API generations and implementation revisions.
- Independent publication, and one shared instance per Kit however many addons embed it.
- Lua 5.1-compatible runtime code with minimal allocation, indirection and global state.
- Bounded by default, deterministic ordering, explicit ownership and cleanup.
- Testable pure-Lua core behaviour against a shared fake client.
- Repository automation that discovers packages rather than hard-coding them.

The full set is [`docs/DESIGN_CONSTITUTION.md`](docs/DESIGN_CONSTITUTION.md).

## Contributing

Contributions are welcome: start with [`CONTRIBUTING.md`](CONTRIBUTING.md),
which links to the full guide in [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).
Ask questions and report bugs as [`SUPPORT.md`](SUPPORT.md) describes, report
vulnerabilities privately as [`SECURITY.md`](SECURITY.md) describes, and follow
the [Code of Conduct](CODE_OF_CONDUCT.md) in every project space. The framework
is released under the [MIT licence](LICENSE).
