# MoltenCodes WoW Framework Roadmap

> Canonical development roadmap for the MoltenCodes WoW framework.
>
> This document is intentionally kept inside the repository so that project
> planning does not depend on chat history or external notes.

## Status

The framework is developed incrementally as small, reusable packages. Public
framework packages follow the Apple-like `Kit` convention:

- package IDs use **lowerCamelCase** (for example, `signalKit`)
- Lua/runtime facades use **PascalCase** (for example, `SignalKit`)
- `registry` / `Registry` is the infrastructure exception

Performance is a first-class requirement. New packages must minimize CPU time,
allocations, garbage-collector pressure, and retained memory. Caches and pools
must be bounded by default. Explicit developer opt-in escape hatches may relax
those defaults when they are documented and observable.

## Completed foundation

- [x] `registry`
- [x] `signalKit`
- [x] `eventKit`
- [x] `lifecycleKit`
- [x] `moduleKit`
- [x] `schedulerKit`
- [x] `timerKit`
- [x] `poolKit`
- [x] `clientKit`
- [x] `cacheKit`
- [x] `profileKit`
- [x] `readinessKit`
- [x] `schemaKit`
- [x] `localeKit`
- [x] `hookKit`
- [x] `settingsKit`
- [x] `optionsKit`
- [x] `commandKit`
- [x] `codecKit`
- [x] `interopKit`
- [x] `mediaKit`
- [x] `testKit` (development only)
- [x] `commKit`
- [x] `widgetKit`
- [x] `apiKit`
- [x] `brokerKit`
- [x] `logKit`
- [x] `compatKit`
- [x] `bridgeKit`
- [x] `panelKit` (client suite not yet run)
- [x] `menuKit` (client suite not yet run)
- [x] `launcherKit` (client suite not yet run)
- [x] `tooltipKit` (client suite not yet run)
- [x] `barKit` (client suite not yet run)
- [x] `dialogKit` (client suite not yet run)
- [x] `toastKit` (client suite not yet run)
- [x] `bindingKit` (client suite not yet run)
- [x] `glowKit` (client suite not yet run)
- [x] `editModeKit` (client suite not yet run)
- [x] `rangeKit` (client suite not yet run)
- [x] `unitFrameKit` (client suite not yet run)

These entries describe packages present in this repository snapshot. A checked
item means its implementation is part of the repository; it does not mean the
package can never receive further optimization, fixes, or API refinement.

## Ongoing framework work

Work is sequenced in phases. A phase is finished when every checkbox in it is
ticked; later phases may start early only where they do not depend on an
unfinished item above them.

### Phase 0 — Green

Make every repository gate pass, so that later correctness work has a trustworthy
baseline to measure against.

- [x] Test support modules stop relying on Busted's injected globals: stub
      preconditions raise plain errors, genuine expectations `require("luassert")`.
- [x] Bootstrap specs clear the `package.loaded` sentinel between attempts so
      every bootstrap guard they claim to cover is really executed.
- [x] `tooling/test/run.py` runs every selected package, prints a per-package
      summary table, and exits non-zero when any package failed.
- [x] `tooling/test/run.py` names a concrete Lua 5.1 toolchain source when
      Busted is missing from `PATH`.
- [x] Tooling modules set `__doc__` (docstring above `from __future__ import`).
- [x] Selene reports zero errors and zero warnings; deliberate `_G` access is
      annotated per site with a reason.
- [x] `stylua --check .` passes across the repository.
- [x] `docs/DEVELOPMENT.md` documents the concrete toolchain install path and
      troubleshooting.

### Phase 1 — Correctness fixes per package

Defects and hardening found by review, one package at a time. Every fix carries a
regression test.

- [x] **eventKit** — enforce the World of Warcraft unit-token limit on
      `ConnectUnit`/`OnceUnit` rather than letting the client silently truncate.
- [x] **eventKit** — isolate listeners at the event-bus boundary so one failing
      listener cannot stop delivery to the rest.
- [x] **eventKit** — bound the number of unit-group frames a single addon can
      cause to be created.
- [x] **eventKit** — audit `error` levels so messages point at the caller's line.
- [x] **moduleKit** — track the dispatched phase per module so an in-place
      upgrade never re-enables a module that was explicitly disabled.
- [x] **schedulerKit** — measure the frame budget as CPU time via
      `debugprofilestop` instead of wall-clock elapsed time.
- [x] **schedulerKit** — stop failing cooperating jobs when one job in the same
      frame raises.
- [x] **schedulerKit** — capture a traceback at the point of failure rather than
      after the stack has unwound.
- [x] **schedulerKit** — document the Lua 5.1 rule that a coroutine cannot yield
      across a `pcall` boundary, and make the API shape that rule explicit.
- [x] **registry** — let two API generations of the same package coexist instead
      of the newer one displacing the older.
- [x] **signalKit** — validate receivers at connect time.
- [x] **signalKit** — make disconnect cheaper than the current linear scan.
- [x] **timerKit** — audit `error` levels and correct the documentation that
      describes them.
- [x] **poolKit** — audit `error` levels and correct the documentation that
      describes them.

### Phase 2 — Consumer story

Everything an addon author needs in order to actually embed a package.

- [x] Write `docs/EMBEDDING.md` covering `.toc` entries, required load order,
      supported Interface numbers, coexistence with LibStub-based libraries,
      taint rules, and the combat-log (CLEU) constraints.
- [x] Ship a complete example addon under `examples/`, loaded by its own spec and
      type-checked on every run so the documented instructions cannot rot.
- [x] Add `.pkgmeta` and the packaging metadata the standard addon packagers
      expect.
- [x] Make `docs/RELEASES.md` describe tooling that exists: `tooling/package/build.py`
      assembles a checksummed, reproducible bundle for one Kit or the whole
      framework.
- [x] Give every public surface LuaCATS annotations so editors and the language
      server describe the API correctly, in one `---@` style, with `meta/wow/`
      definitions for the client API the Kits touch.

### Phase 3 — Engineering system

Repository mechanics that keep the above honest as the framework grows.

- [x] Pin every GitHub Action to a commit SHA rather than a moving tag, with the
      release the SHA was taken from in a trailing comment. The StyLua action no
      longer receives `GITHUB_TOKEN`; it only needed one to raise the anonymous
      API rate limit.
- [x] Run Selene over test code too, using a Busted std definition. `busted.yml`
      is selected by `selene-tests.toml`; `tooling/lint.py` lints
      `packages/*/tests`, `examples/tests` and the shared fixture under it, and
      reports zero errors and zero warnings.
- [x] Add a Python version floor row to the CI matrix so the documented minimum
      is actually exercised. `pyproject.toml` declares `requires-python`,
      repository validation enforces it, and CI runs the tooling tests on 3.10
      and 3.13.
- [x] Stop recompiling Selene in CI. It now installs the published
      `selene-light` binary and verifies a recorded SHA-256, which removes the
      build rather than caching it.
- [x] Extract the repeated WoW-API stubs into one shared test-support fixture,
      including the inline stub in `examples/tests/`. `tests/support/FrameworkTestEnv.lua`
      is the one fake client; each package keeps a thin `tests/support/<Kit>TestEnv.lua`.
- [x] Add a `Registry:Bootstrap` helper so packages stop copying the same
      bootstrap preamble. All seven Kits use it; Registry does not, because it
      publishes the facade the helper lives on.
- [x] Write `packages/moduleKit/docs/INTERNALS.md` describing the dependency
      graph and resolution order.
- [x] Repository audit (2026-09-24). CI moved to Python 3.10 and 3.14 and to one
      shared, cached hererocks toolchain (`.github/actions/setup-lua`); it
      gained a LuaCov coverage report (`tooling.test.coverage`), the bundle of
      every `main` commit as an artefact, a lychee link-check workflow and a
      daily mirror-heads workflow (`tooling.api.heads`) that keeps one issue
      open while apiKit metadata is behind the mirror. Repository validation
      now also checks each package's `tests/README.md` and suite environment,
      `.pkgmeta` against every package and root entry, the documentation and
      package indexes, the quoted load order and the Kit lists under
      `.github/`; every tooling command answers `--help`.

### Phase 4 — Growing the framework from what the ecosystem taught

Decided 2026-09-23 after a study of seven references (Ace3 and LibStub,
LibRangeCheck-3.0, LibSpellRange-1.0, WeakAuras_SharedMedia, LibGetFrame-1.0,
and the 309-entry WowAce library directory). Ideas and designs were taken,
never code. The work was sequenced in five packages, A to E, then F and G; each package
ends with an acceptance review before the next begins. Package H, the WoW
API wrapper, was added on 2026-09-23 from the owner's design brief. A new Kit is recorded here
with the nine points of the "Planned package policy" before its code is
written; capabilities added to an existing Kit are checkboxes under that Kit.

Decisions taken for the sequence: one `clientKit` holds both client detection
and compatibility shims; the combat gate lives in `lifecycleKit`; `codecKit`
is three stages (serialise, compress, channel-encode) rather than a bare
serialiser; `schemaKit` is the shared validation core written before the Kits
that use it; `settingsKit` v1 ships profiles, spec-aware profiles and
namespaces follow in v2; event coalescing and scheduler lanes are one design.

#### Package A — the gaps the references exposed in existing Kits

- [x] **eventKit** — owner scopes: `CreateScope`, `scope:Connect/Once/ConnectUnit`,
      `scope:DisconnectAll`, `scope:Close`, mirroring timerKit; bulk teardown
      of an addon's subscriptions in one call.
- [x] **timerKit** — `timer:GetRemaining()` and `timer:GetDeadline()` from the
      monotonic clock, `nil` (never `0`) when the timer is not running.
- [x] **poolKit** — generation stamping: objects built by a superseded factory
      are recognised after an in-place upgrade and retired rather than reused.
- [x] **poolKit** — pools for objects that can never be freed (frames): a
      creation cap, a live limit with a bounded waiting queue, cascading
      release of children, and release deferred until an animation ends.
- [x] **moduleKit** — automatic teardown: what a module registered through the
      framework while enabled (events, timers, scheduler jobs) is released
      when it is disabled, without the module writing an `OnDisable`.
- [x] **moduleKit** — intent versus fact: "wanted enabled" recorded separately
      from "is enabled", so a module blocked by a failed dependency is
      enabled again when the dependency recovers.
- [x] **registry** — `Find(package, api)` (silent lookup for optional
      dependencies) and `Packages()` (sorted enumeration for diagnostics).
- [x] **registry** — retirement and migration: the outgoing copy hands its
      state over and disables its own entry points; the incoming copy runs
      per-revision migrations in order.
- [x] **registry** — sealed facades: an option on `Bootstrap` that refuses
      writes to a published facade from outside its package.
- [x] **docs / meta / tooling** — secret values (`issecretvalue`) and
      restricted frame access (`IsForbidden`, `CanBeAccessedInContext`) in
      the taint section and in `meta/wow`; one validated table of supported
      `## Interface` numbers used by every document, the example and the
      packager; the TOC fields the addon sites read; the `externals` form for
      consumers; a spell-check gate.

#### Package B — foundations every later Kit needs

- [x] `clientKit` — client flavour, build floor, capability flags, normalised
      shims, `IsSecret`, `CanAccessFrame`, event validity probes.
- [x] `cacheKit` — bounded LRU and TTL caches, `Memoize`, diffed `Snapshot`,
      clear-on-event.
- [x] `profileKit` — zero-cost-when-off performance sections with count, total
      and spike, and a report.
- [x] **schedulerKit** — `Debounce`, `Coalesce`, `Watch`, and lanes that
      ration a shared resource (in flight, interval, retry, backoff), designed
      with **eventKit** coalescing and `Derive` as one family.
- [x] `readinessKit` — gates for host data that arrives after load, with
      timeouts and negative caching.
- [x] **lifecycleKit** — the combat gate (one lockdown state, a bounded
      "run when out of combat" queue) and a halted state announced to
      dependents.

#### Package B planned Kits — the nine points

Recorded 2026-09-23, before implementation, as the planned package policy
requires. Sources: the phase 4 reference notes on LibRangeCheck-3.0,
LibSpellRange-1.0 and LibGetFrame-1.0 (client detection, caches, profiling).

| Record | Package | Status |
|---|---|---|
| [clientKit](records/clientKit.md#clientkit) | `clientKit` | implemented (package B1, 0.1.0) |
| [cacheKit](records/cacheKit.md#cachekit) | `cacheKit` | implemented (package B1, 0.1.0) |
| [profileKit](records/profileKit.md#profilekit) | `profileKit` | implemented (package B1, 0.1.0) |
| [readinessKit](records/readinessKit.md#readinesskit) | `readinessKit` | implemented (package B2, 0.1.0) |


#### Package C — the consumer story

- [x] `schemaKit` — sealed schemas with structured failures, shared by
      settings, options and messaging.
- [x] `settingsKit` — saved variables with scopes, wildcard defaults,
      profiles and versioned migrations (v1: profiles; v2: spec-aware profiles
      and namespaces).
- [x] `localeKit` — translations per locale, missing-key reporting, indexed
      format specifiers.
- [x] `hookKit` — secure-first, reversible hooking, released with the module.
- [x] **signalKit** — a named message bus with a validated topic policy.
- [x] **moduleKit** — map a halted LifecycleKit dependency to the blocked
      enable state, and give `module.scope` the `Hooks` and `Messages`
      scopes once hookKit and the signalKit bus exist.
- [x] **lifecycleKit** — close the addon's HookKit scopes and its SignalKit
      bus at shutdown, the two-step already used for EventKit scopes.
- [x] `optionsKit` — typed, validated, introspectable options schema with no
      renderer.
- [x] `commandKit` — slash commands, hyperlink-aware argument parsing,
      output sinks, schema binding, tab completion.

#### Package C planned Kits — the nine points

Recorded 2026-09-23, before implementation. Sources: the phase 4 reference
notes on Ace3 (AceLocale, AceHook, AceEvent messages, AceDB, AceConfig) and
the WowAce directory item W6 (a shared validation core).

| Record | Package | Status |
|---|---|---|
| [schemaKit](records/schemaKit.md#schemakit) | `schemaKit` | implemented (package C1, 0.1.0) |
| [localeKit](records/localeKit.md#localekit) | `localeKit` | implemented (package C2, 0.1.0) |
| [hookKit](records/hookKit.md#hookkit) | `hookKit` | implemented (package C2, 0.1.0) |
| [settingsKit](records/settingsKit.md#settingskit) | `settingsKit` | implemented (package C2, 0.1.0) |
| [optionsKit](records/optionsKit.md#optionskit) | `optionsKit` | implemented (package C3, 0.1.0) |
| [commandKit](records/commandKit.md#commandkit) | `commandKit` | implemented (package C3, 0.1.0) |


#### Package D — interoperability and distribution

- [x] `codecKit` — serialise, compress and channel-encode as three stages
      behind a one-byte header; asynchronous variants under the scheduler
      budget.
- [x] `commKit` — addon messaging: prefixes, chunking, bounded reassembly,
      priority queues that reject rather than grow, content-hash sync sets.
- [x] `mediaKit` — a typed media registry mirroring LibSharedMedia when it is
      present.
- [x] `interopKit` — the LibStub bridge (expose to LibStub, adopt from it);
      its own package because the registry's line budget is spent.
- [x] `testKit` — test suites that run inside the client.
- [x] A publish workflow on tags through the packager to the addon sites, in
      dry-run until the site projects exist.

#### Package D planned Kits — the nine points

Recorded 2026-09-23, before implementation. Sources: the phase 4 reference
notes on Ace3 (AceSerializer C8, AceComm and ChatThrottleLib C9), the WowAce
directory (LibDeflate, LibSerialize, LibCompress, LibMSP, WoWUnit: items W7
and W9) and the WeakAuras media pack (LibSharedMedia).

| Record | Package | Status |
|---|---|---|
| [codecKit](records/codecKit.md#codeckit) | `codecKit` | implemented (package D, 0.1.0) |
| [commKit](records/commKit.md#commkit) | `commKit` | implemented (package D, 0.1.0) |
| [interopKit](records/interopKit.md#interopkit) | `interopKit` | implemented (package D, 0.1.0) |
| [mediaKit](records/mediaKit.md#mediakit) | `mediaKit` | implemented (package D, 0.1.0) |
| [testKit](records/testKit.md#testkit) | `testKit` | implemented (package D, 0.1.0) |


#### Package E — the last and largest

- [x] `widgetKit` — pooled, versioned widgets and layout, consumed by
      `optionsKit`.
- [x] Update `docs/EMBEDDING.md`, the example addon and the package bundle for
      every new Kit; final acceptance review (closing review 2026-09-23:
      accepted, its five documentation and consistency items applied).

#### Package E planned Kit — the nine points

Recorded 2026-09-23, before implementation. Sources: the Ace3 study (AceGUI,
AceConfigDialog: candidate C10) and the WowAce directory (LibWindow,
LibEditModeOverride: item W14).

| Record | Package | Status |
|---|---|---|
| [widgetKit](records/widgetKit.md#widgetkit) | `widgetKit` | implemented (package E, 0.1.0) |


#### Package F — independence and escape hatches

Decided 2026-09-23 after the project owner asked whether every Kit still stands alone and
whether strict defaults can be opened. Two principles are added to the design
constitution (4a bounded by default, opened on purpose; 4b minimal footprint)
and the tree is brought to them. Registry and SignalKit are the accepted core
pair; nothing else is a required dependency unless the Kit cannot work
without it.

- [x] **timerKit** — LifecycleKit becomes optional: the addon scope is closed
      by LifecycleKit calling `TimerKit:CloseAddonScopes` (the two-step
      EventKit already uses); timerKit embeds as two files.
- [x] **schedulerKit** — LifecycleKit becomes optional the same way; the
      chain shrinks to registry and timerKit.
- [x] **readinessKit**, **testKit** — chains follow (testKit keeps
      LifecycleKit, it gates on phases by purpose).
- [x] **lifecycleKit** — calls `TimerKit:CloseAddonScopes` and
      `SchedulerKit:CloseAddonScopes` at shutdown when those Kits are present.
- [x] Every fixed limit becomes an option, a `SetLimits` entry or accepts
      `Kit.UNBOUNDED`, per principle 4a: signalKit (bus, topic and listener
      caps), eventKit (unit-filter frames), hookKit, commandKit, localeKit,
      mediaKit, profileKit, cacheKit (`UNBOUNDED`), schemaKit (depth and
      captures through `SetLimits` with a stated ceiling), optionsKit,
      settingsKit, widgetKit (creation ceiling), codecKit and commKit
      (`UNBOUNDED` where safe), moduleKit and lifecycleKit (dependency and
      queue caps), readinessKit, schedulerKit (lanes, watchers, debounce
      arguments), testKit.
- [x] Addon scopes close at logout whenever the framework can observe logout,
      whatever revisions are paired: LifecycleKit publishes
      `CLOSES_ADDON_SCOPES`; a scope-owning Kit does nothing when that names
      it, subscribes to an older LifecycleKit's `OnShutdown` otherwise, falls
      back to a `PLAYER_LOGOUT` connection through EventKit when LifecycleKit
      is absent, and documents the consumer's own call when neither is
      loaded (decided 2026-09-23).
- [x] Every package README states its minimum footprint; EMBEDDING.md gains a
      footprint table and the dependency graph is redrawn. Acceptance review
      2026-09-23: accepted after its findings (scheduler, test and readiness
      limits, commKit's LifecycleKit dependency removed, footprint lines,
      the dropdown limit) landed.

#### Package G — distribution

Decided 2026-09-23 with the project owner. Two release questions the release
workflow had left open are settled: (1) both kinds of tag exist, a per-package
`<kit>-v<version>` tag that releases one Kit and a bundle `v<version>` tag that
seals a set of Kit versions tested together, the way Ace3 versions each library
and ships as one; (2) the packager's required TOC becomes a real standalone
"MoltenCodes" addon that loads every release Kit, so an addon author may embed
the Kits or depend on the installed addon, and Registry lets both coexist.

- [x] **tooling / workflow** — `release.yml` triggers on `v*.*.*` and on
      `<kit>-v*.*.*`; `check_tag` validates both forms (a package tag against
      that package's manifest and a `### <kit>-v<version>` section); a package
      tag builds and publishes that Kit alone.
- [x] **tooling** — `library_toc` produces the standalone addon's TOC (title,
      notes, version placeholder, the site fields, `## Interface` from the
      supported-client table, every release Kit in load order); the builder
      writes it into the bundle root so the GitHub artifact installs as an
      addon too; the packager job uses the same generator.
- [x] **docs** — RELEASES.md states the two tag kinds and the standalone
      addon; EMBEDDING.md gains "Embed or depend": `## OptionalDeps:
      MoltenCodes`, how Registry picks the newest copy, and what to do when an
      addon embeds Kits while the standalone addon is also installed; the root
      README says the framework installs as an addon or embeds.

#### Package H — apiKit, the WoW API wrapper

Decided 2026-09-23 with the project owner, from the owner's design brief. The
brief is consolidated as [`API_KIT_DESIGN.md`](API_KIT_DESIGN.md), which is
the canonical design; this entry records the nine points and the delivery
sequence. Seven points where the brief and the repository's conventions
differed were settled before anything was written: the package is `apiKit`
(not `api`); the `wow` global is published only when free and the
namespaces are always reachable as `MoltenCodes.wow…`; the source is the
client's own documentation tables through the community mirror at pinned
commits, with only normalised metadata committed; names follow generated
rules with a reviewed alias table; one flavour is populated per session;
the generator is Python under `tooling/api/` with outputs under the package;
the whole documented surface is generated, the hand work is the pipeline,
the rules, the exceptions, the validation and the tests.

Nothing in this package is ticked until its acceptance review closes, the
way packages A to G were handled. Code starts only after the owner's go.

##### Package H planned Kit — the nine points

| Record | Package | Status |
|---|---|---|
| [apiKit](records/apiKit.md#apikit) | `apiKit` | implemented (package H, 0.1.0, 2026-09-24) with all five flavours captured |


##### Delivery sequence

Each step ends with the gates green and a read-only review before the next
begins; H4 to H6 may overlap where they do not share files.

- [x] **H0 — repository prerequisites.** The builder, the TOC generator, the
      standalone-addon TOC and the repository validator list a package's
      additional runtime files (`src/flavours/*.lua`) after its facade in
      load order and in the bundle manifest (`.pkgmeta` needed no change: it
      moves whole `src/` directories); the validator requires exactly one
      top-level facade named after `displayName`; the spell and link gates
      skip generated `docs/reference/` and `docs/changes/` directories;
      `tooling/api/flavours.json` maps each apiKit flavour to its mirror
      branches and detection facts and is checked by the validator. Tooling
      tests for each (2026-09-24).
- [x] **H1 — metadata schema and normaliser.** `tooling/api/SCHEMA.md`
      (the schema lives beside the code that writes and reads it);
      `tooling.api.fetch` (one flavour, one pinned mirror commit, scratch
      directory outside the repository, provenance recorded, newest-build
      branch choice, never fetches a pinned commit twice);
      `tooling.api.lua_tables` (a parser for the documentation tables, which
      turned out to carry a few constants written as references and sums;
      those are kept as text); `tooling.api.naming` with the rules of design
      section 6 and the reviewed data in `naming.json`; `tooling.api.model`
      with the host type table `types.json` (the client types the tables
      reference but never define); `tooling.api.normalize` merging the files
      that describe one namespace, keeping every marker, failing on a shared
      wrapper name; `tooling.api.validate`. Against the Retail tables of
      build 69933: 391 namespaces, 6,338 functions, 1,782 events, 844
      enumerations, 752 structures, 20 callbacks, 60 constants tables, 57
      restriction predicates, no naming collision, every type resolved.
      567 tooling tests (2026-09-24).
- [x] **H2 — generators.** `tooling.api.generate` writes, from one metadata
      directory, the runtime flavour file (`render_runtime`: one direct alias
      per function, bound only when the host has the namespace; Retail is
      about 9,800 lines; load cost in the package's API document),
      the LuaCATS definitions (`render_types`, seven files per flavour), the
      Markdown reference and the search index (`render_reference`, 320 files
      for Retail with every link resolving), and with `--previous` the change
      report and the history entry (`diff`). Generated Lua is checked with
      `luac -p` and StyLua before anything is written, a generated directory
      is replaced as a whole, `--check` refuses stale outputs for CI, and the
      whole run takes under a second for Retail. 752 tooling tests
      (2026-09-24).
- [x] **H3 — the facade.** `packages/apiKit/src/ApiKit.lua` (API 1, revision
      1): `MoltenCodes.wow` with one `api` table per flavour, the `wow`
      global published only when free (`GetGlobalStatus`), flavour detection
      once at load from `WOW_PROJECT_ID`, `IsTestBuild` and `IsBetaBuild`
      (`GetFlavor`, `"unsupported"` for a client matching no row),
      `RegisterFlavor(flavor, install, info?)` running the running flavour's
      installer once with its `api` table and the host, `GetMetadataBuild`,
      the read-only `SUPPORTED_FLAVORS`; state survives an in-place upgrade;
      errors at the caller. Manifest, README, `docs/API.md`, `docs/NAMING.md`,
      CHANGELOG, 41 specs including one that holds the facade's flavour table
      to `tooling/api/flavours.json`. `.pkgmeta` ignores `packages/*/metadata`
      and `packages/*/types` and moves apiKit; the validator derives an
      embedded script's package from its directory; the generated runtime
      file passes the metadata's version and build to `RegisterFlavor`
      (2026-09-24).
- [x] **H4 — Retail.** First capture at `Gethe/wow-ui-source@09b9db79`
      (live, client 12.1.0, build 69933, 612 tables, captured 2026-09-24);
      metadata (7.9 MB with the search index), runtime file (`flavours/
      Retail.lua`, about 9,800 lines), types (7 files, 1.8 MB), reference (320
      files, 4.0 MB) and the first history entry committed together. The
      generated-output check is exhaustive rather than sampled: a tooling
      test builds a stub host from the metadata and proves the committed file
      binds every documented function and nothing else, and a Busted spec
      loads the file against the real facade and the shared fixture. CI runs
      `generate --all --check`. The real tables produced no naming
      collision, so the exception tables stay empty. Load cost recorded in
      `packages/apiKit/docs/API.md`. The reference and the search index (6 MB of the 14 MB the
      capture produced) are not committed: decided with the owner on
      2026-09-24, they are built by `generate --reference-out` and attached
      to releases; the release workflow does so.
- [x] **H5 — Classic Era and Mists of Pandaria Classic.** Classic Era at
      `Gethe/wow-ui-source@33e177d9` (classic_era, 1.15.9, build 69722, 534
      tables: 337 namespaces, 4,589 functions) and Mists at `@cde55d00`
      (classic, 5.5.4, build 69934, 533 tables: 337 namespaces, 4,590
      functions), normalised, generated and checked like Retail; two host
      types the Classic tables reference added to `types.json`; the exhaustive
      binding test and a Busted spec per flavour; flavour isolation made
      visible by a tooling test over every committed pair (each adds
      bindings the other lacks; each file registers only itself). Package
      after three flavours: 20 MB committed (2026-09-24).
- [x] **H6 — PTR and Beta.** Both mirror branches carry the tables. PTR at
      `Gethe/wow-ui-source@5c9363cc` (`ptr2`, chosen over `ptr` for its newer
      build: 12.1.5, build 69952, 622 tables: 397 namespaces, 6,437
      functions; four host types new in 12.1.5 added to `types.json`) and
      Beta at `@078d0cf7` (12.0.1, build 66220, the branch's last export of
      2026-03-03: 374 namespaces, 5,942 functions), normalised, generated and
      checked like the others, each with its Busted spec. The detection
      probes `IsTestBuild` and `IsBetaBuild` were verified as documented
      functions of the Retail client. Package after five flavours: 36 MB
      committed, of which metadata 26 MB and types 8 MB (2026-09-24).
- [x] **H7 — documentation and review.** `packages/apiKit/docs/UPDATING.md`
      (the six-command refresh, the two expected refusals and their fixes,
      adding a flavour); EMBEDDING (load order with the flavour files, the
      footprint row, the second-global rule, the host-requirements row, two
      troubleshooting entries), ARCHITECTURE, `docs/README.md`, the root
      README and RELEASES (how a metadata refresh is versioned) updated; the
      performance review is the "Load cost" section of the package's API
      document; `API_KIT_DESIGN.md` checked against what shipped and its
      definition of done ticked; acceptance review (2026-09-24).

Settled with the project owner on 2026-09-23, before H1: Blizzard's
documentation prose is carried into hover text and the reference with
provenance; a metadata refresh is a minor version with the change report in
the changelog, a removal noted as breaking for that flavour, the API
generation unchanged because the facade contract does not move (design
document, section 12.1). The last question was settled in H4 on 2026-09-24:
the generated reference and search index are not committed but built into a
release asset (design document, section 13). Implementation started on the
owner's go on 2026-09-24.

### Phase 5 — beyond Ace3: capabilities, then developer packages

Decided 2026-09-24 with the project owner. Ace3 parity is complete and phase 4
went past it; what remains for the core is (a) capabilities the phase 4 study
identified for existing Kits (items W10 to W16 of the WowAce survey, plus one
Ace3 gap the survey did not list: AceDBOptions' ready-made profile management
options) and (b) non-UI packages that developers reach for daily and that the
ecosystem still hand-rolls. Everything about user interface beyond widgetKit's
base set (tooltip, menu, bar and dialog sets, the minimap launcher, the
engine-driven ticker, key bindings) is deliberately last, as its own phase,
because the owner wants the developer-facing core finished first. Each step
ends with the gates green and a read-only review; capabilities are checkboxes
under their Kit, new Kits carry nine points.

On 2026-09-25 the owner set the user-interface phase aside for now and moved
the Ace3 migration tools ahead of it: package N, bridgeKit, recorded after
package M below.

#### Package I — capabilities for existing Kits

- [x] **signalKit** (W10, done 2026-09-24) — `SignalKit:New({ onFirst, onLast })` hooks that fire
      on the 0→1 and 1→0 subscriber transitions (a source can activate only
      while observed, CallbackHandler's `OnUsed`/`OnUnused`);
      `SignalKit:NewJournal(capacity)`, a signal that keeps its last firings in
      a preallocated ring for explicit pull through `journal:History()` (no
      replay on connect; default capacity 128, argument-count cap documented);
      `signal:GetGeneration()` incrementing on every fire for cheap
      "changed since I looked" checks. Hooks cost one comparison per connect
      and disconnect and must hold under re-entrant connect and disconnect.
- [x] **cacheKit** (W11, done 2026-09-24) — `Memoize(fn, { cacheable })`: a predicate that
      returns a result without storing it while it is incomplete;
      `cache:PutNegative(key, ttlSeconds)`: a negative entry with its own
      expiry on a TTL cache (a peer that answered "nothing" is not asked again
      for a while); `CacheKit:Lazy(resolve, options)`: a compact resident form
      expanded on demand under a namespace path with recursive parent
      invalidation; `CacheKit:NewQueue(capacity, overflow)`: a bounded ring
      with an explicit `dropOldest`, `dropNewest` or `reject` policy, O(1)
      and allocation-free after construction.
- [x] **eventKit** (W12) — `EventKit:ConnectCombatLog(subEvent, callback)` and
      the scope form: one `CombatLogGetCurrentEventInfo()` read per event,
      O(1) routing by sub-event, listeners receive the multiple returns
      unchanged, a sub-event with no listener costs one lookup; isolation as
      for `Connect`. Also the `"*"` wildcard, one host registration held only
      while a combat-log listener exists and shared with a plain `Connect`;
      EventKit 0.8.0, revision 12 (2026-09-24).
- [x] **moduleKit** (W16) — an `implements` option on `Provide` and on module
      definitions: a list of method names checked once at registration,
      failing at the caller's line with the missing name; a SchemaKit schema
      accepted in its place when SchemaKit is loaded. Done 2026-09-24
      (ModuleKit 0.8.0, revision 15; error levels fixed in 0.8.1, revision 16).
- [x] **optionsKit** (AceDBOptions parity) — `OptionsKit:ProfileOptions(db,
      options?)`: a ready-made options group over a SettingsKit database
      (choose the active profile, create one by name, copy from another,
      reset the current one, delete one, with confirmations and the current
      profile's name in descriptions), built from existing option kinds so
      every renderer shows it; refuses when SettingsKit is absent
      (2026-09-24).
- [x] **clientKit** (W13, the part Registry's spent line budget leaves to it)
      — `ClientKit:GetManifest(addonName)`: a read-only snapshot of an addon's
      `.toc` fields with locale-suffixed fallback (`## Notes-deDE` before
      `## Notes`), read once per addon and cached. Registry's `Deprecate` and
      data-package kinds stay unbuilt until a consumer needs them.
      Done 2026-09-24 (clientKit 0.2.0, revision 2; revised in 0.2.1, revision 3).
- [x] Deferred to the user-interface phase: **timerKit** engine-driven
      pausable ticker (W15, needs an animation host; built in package M on
      `C_Timer` handles instead, see "timerKit pausable timers"), **frameKit** (W14,
      folded into widgetKit's anchors, nothing further to build), Registry
      deprecation warnings (W13; Registry's line budget is spent, so they are
      a ClientKit capability, see "clientKit deprecation warnings" in package
      M; done 2026-11-15, clientKit 0.3.0, revision 6).

#### Package J — brokerKit

| Record | Package | Status |
|---|---|---|
| [brokerKit](records/brokerKit.md#brokerkit) | `brokerKit` | implemented 2026-09-24, 0.1.0, revision 1, 126 specs |


#### Package K — logKit

| Record | Package | Status |
|---|---|---|
| [logKit](records/logKit.md#logkit) | `logKit` | implemented 2026-09-24, 0.1.0, revision 1, 144 specs |


#### Package L — compatKit

| Record | Package | Status |
|---|---|---|
| [compatKit](records/compatKit.md#compatkit) | `compatKit` | implemented 2026-09-24, 0.1.0, revision 1, 114 specs |


#### Package M — the user-interface phase (last, by the owner's decision)

Decided 2026-11-15 with the project owner, after bridgeKit (package N):
Blizzard's own frameworks are wrapped, not rebuilt, where every promised
client ships them (the Settings API and `MenuUtil`); every item below is
needed; each Kit gets its nine points here, agreed with the owner, before
its code. Order:

- [ ] **panelKit** — an OptionsKit tree in Blizzard's settings panel (below):
      implemented, client suite not run.
- [ ] **menuKit** — a thin, bounded wrapper over Blizzard's Menu API
      (`MenuUtil`): implemented, client suite not run.
- [ ] **launcherKit** — the minimap launcher for brokerKit, with an
      AddonCompartment entry on Retail: implemented, client suite not run.
- [ ] **tooltipKit** — multi-column tooltips pooled through PoolKit:
      implemented, client suite not run.
- [x] widgetKit — AceConfigDialog's tab, tree and drop-down group layouts
      in the renderer. A capability of three existing Kits, agreed with the
      owner on 2026-11-15, and delivered the same day (optionsKit 0.5.0,
      widgetKit 0.3.0, bridgeKit 0.5.0; bridgeKit design decision 23):
      - **optionsKit**: a `group` accepts the renderer hint `childGroups`,
        `"tab"`, `"tree"` or `"select"`, as Ace3 names them; `Describe`
        carries it; the facade publishes `CHILD_GROUPS` so other Kits can
        tell an OptionsKit that knows the hint.
      - **widgetKit**: `RenderOptions` shows the non-inline child groups of
        a group with `childGroups` one page at a time: a row of buttons
        (`tab`), a list beside the page (`tree`, one level; a page's own
        `childGroups` opens the next) or a dropdown (`select`). Options and
        inline groups stay above the pages. The selected page is kept per
        group while the rendering lives, and choosing one rebuilds the
        rendering. A group without the hint renders as before.
      - **bridgeKit**: `ConvertAceConfig` carries `childGroups` over when
        the registered OptionsKit publishes `CHILD_GROUPS`, and reports it
        dropped as before otherwise.
      Review fix 2026-11-15 (decision 17): bridgeKit 0.5.1, revision 6: a
      `childGroups` value is carried over only when it is one of Ace's three
      layouts as well as listed in OptionsKit's published `CHILD_GROUPS`,
      which a consumer can write to; 2 specs (291 in all).
- [ ] **barKit** (status and timer bars), **dialogKit**, **toastKit**,
      **bindingKit**, **glowKit** and **editModeKit** (Edit Mode
      integration): implemented, client suites not run.
- [x] **timerKit** pausable timers (W15): `Pause`, `Resume`, `IsPaused` on
      `C_Timer` handles, revision 12 (2026-11-15).

| Record | Package | Status |
|---|---|---|
| [panelKit](records/panelKit.md#panelkit) | `panelKit` | implemented 2026-11-15 after the owner's go, 0.1.0, revision 1, 48 specs |
| [menuKit](records/menuKit.md#menukit) | `menuKit` | implemented 2026-11-15 after the owner's go, 0.1.0, revision 1, 45 specs |
| [launcherKit](records/launcherKit.md#launcherkit) | `launcherKit` | implemented 2026-11-15 after the owner's go, 0.1.0, revision 1, 39 specs |
| [tooltipKit](records/tooltipKit.md#tooltipkit) | `tooltipKit` | implemented 2026-11-15 after the owner's go, 0.1.0, revision 1, 43 specs |
| [barKit](records/barKit.md#barkit) | `barKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 29 specs |
| [dialogKit](records/dialogKit.md#dialogkit) | `dialogKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 26 specs |
| [toastKit](records/toastKit.md#toastkit) | `toastKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 23 specs |
| [bindingKit](records/bindingKit.md#bindingkit) | `bindingKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 21 specs |
| [glowKit](records/glowKit.md#glowkit) | `glowKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 22 specs |
| [editModeKit](records/editModeKit.md#editmodekit) | `editModeKit` | implemented 2026-11-15 under core decision 15, 0.1.0, revision 1, 28 specs |
| [timerKit pausable timers (W15)](records/timerKit.md#timerkit-pausable-timers-w15) | `timerKit` | implemented 2026-11-15 under core decision 15, 0.8.0, revision 12, 12 specs |
| [clientKit deprecation warnings (W13)](records/clientKit.md#clientkit-deprecation-warnings-w13) | `clientKit` | implemented 2026-11-15 under core decision 16, 0.3.0, revision 6, 44 new specs (176 in all) |
| [settingsKit spec profiles](records/settingsKit.md#settingskit-spec-profiles) | `settingsKit` | implemented 2026-11-15 under core decision 16, settingsKit 0.4.0, revision 11, 33 specs (268 in all), with two additions decided while building |
| [widgetKit virtualised lists](records/widgetKit.md#widgetkit-virtualised-lists) | `widgetKit` | implemented 2026-11-15 under core decision 16, 0.4.0, revision 12, 30 specs in `ScrollList_spec.lua` |
| [rangeKit](records/rangeKit.md#rangekit) | `rangeKit` | implemented 2026-11-15 under core decision 16, 0.1.0, revision 1, 41 specs |
| [unitFrameKit](records/unitFrameKit.md#unitframekit) | `unitFrameKit` | implemented 2026-11-15 under core decision 16, 0.1.0, revision 1, 65 specs |
| [codecKit native DEFLATE](records/codecKit.md#codeckit-native-deflate) | `codecKit` | implemented 2026-11-15 under core decision 16, 0.2.0, revision 7, 146 specs |


#### Package O — memory, performance and ease of use (decisions 18 and 19)

Decided 2026-11-15 with the project owner after the decision 17 review
compared the framework with Ace3: memory and performance must be much better
than Ace3's and usability and ease of learning better too. The measured
diagnosis (memory, the settings Kits, the runtime Kits, usability, Ace3's
feature gaps, maturity and architecture) found the causes; the owner then
decided that Kits are split into a core file plus optional parts, that
secret-value checks guarding what the client already refuses are removed,
that method-name callbacks are allowed, checked at registration, and that a
new optional Kit, addonKit, holds the single entry point. The decisions are
recorded in `docs/decisions/`. Each record below is written before its code.

| Record | Package | Status |
|---|---|---|
| [Kit parts and the embeds generator (core decision 19a)](records/tooling.md#kit-parts-and-the-embeds-generator-core-decision-19a) | `tooling` | implemented 2026-11-15 under core decisions 18 and 19 |
| [Lua limits gate and version check (architecture plan items 1 and 2)](records/tooling.md#lua-limits-gate-and-version-check-architecture-plan-items-1-and-2) | `tooling` | implemented 2026-11-15 |
| [addonKit](records/addonKit.md#addonkit) | `addonKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.1.0, revision 1, parts Database and Composition revision 1, 72 specs (98.0% line coverage) |


---

| Record | Package | Status |
|---|---|---|
| [settingsKit read-through views, lazy Open, client-refused secret probes removed](records/settingsKit.md#settingskit-read-through-views-lazy-open-client-refused-secret-probes-removed) | `settingsKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.5.0, revision 14, node layout 4, 298 specs (25 new in `ReadThrough_spec.lua`) |


---

| Record | Package | Status |
|---|---|---|
| [schemaKit sparse compiled nodes and `GetLimit`](records/schemaKit.md#schemakit-sparse-compiled-nodes-and-getlimit) | `schemaKit` | implemented 2026-11-15 under core decision 18, 0.2.0, revision 6, node layout 2, 139 specs |


---

| Record | Package | Status |
|---|---|---|
| [optionsKit smaller records, labels on failure, cheaper `ProfileOptions`](records/optionsKit.md#optionskit-smaller-records-labels-on-failure-cheaper-profileoptions) | `optionsKit` | implemented 2026-11-15 under core decision 18, 0.6.2, revision 13, 208 specs |


---

| Record | Package | Status |
|---|---|---|
| [commandKit secret question without a per-call Registry lookup](records/commandKit.md#commandkit-secret-question-without-a-per-call-registry-lookup) | `commandKit` | implemented 2026-11-15 under core decision 18, 0.2.10, revision 10, 176 specs |
| [timerKit (package O): fixed-cost trims, the probe rule, scope reopening and method-name callbacks](records/timerKit.md#timerkit-package-o-fixed-cost-trims-the-probe-rule-scope-reopening-and-method-name-callbacks) | `timerKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.9.0, revision 14, 145 specs |
| [eventKit (package O): fixed-cost trims, smaller connections, scope reopening and method-name callbacks](records/eventKit.md#eventkit-package-o-fixed-cost-trims-smaller-connections-scope-reopening-and-method-name-callbacks) | `eventKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.10.0, revision 21, 271 specs |
| [signalKit (package O): publish and subscribe trims, smaller connections, bus scope reopening and method-name callbacks](records/signalKit.md#signalkit-package-o-publish-and-subscribe-trims-smaller-connections-bus-scope-reopening-and-method-name-callbacks) | `signalKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.8.0, revision 11, 266 specs |
| [hookKit (package O): counted hook bound, inline isolation, scope reopening and method-name handlers](records/hookKit.md#hookkit-package-o-counted-hook-bound-inline-isolation-scope-reopening-and-method-name-handlers) | `hookKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.4.0, revision 8, 151 specs |
| [schedulerKit (package O): the probe rule, one-pass key validation, receiver checks and scope reopening](records/schedulerKit.md#schedulerkit-package-o-the-probe-rule-one-pass-key-validation-receiver-checks-and-scope-reopening) | `schedulerKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.9.0, revision 21, 289 specs |
| [lifecycleKit (package O): the probe rule and the halted field as a record field](records/lifecycleKit.md#lifecyclekit-package-o-the-probe-rule-and-the-halted-field-as-a-record-field) | `lifecycleKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.6.9, revision 18, 202 specs |
| [moduleKit (package O): kept module scopes, cheaper enables, the probe rule and an opt-in missing-Kit error](records/moduleKit.md#modulekit-package-o-kept-module-scopes-cheaper-enables-the-probe-rule-and-an-opt-in-missing-kit-error) | `moduleKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.9.0, revision 22, 264 specs |
| [commKit send fast path and cheaper checks](records/commKit.md#commkit-send-fast-path-and-cheaper-checks) | `commKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.5.3, revision 10, 12 specs (275) |
| [localeKit fast unneeded-locale path](records/localeKit.md#localekit-fast-unneeded-locale-path) | `localeKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.1.7, revision 5, 5 specs (124) |
| [registry cheaper lookups](records/registry.md#registry-cheaper-lookups) | `registry` | implemented 2026-11-15 under core decisions 18 and 19, 0.6.11, revision 16, plain indexing on the owner's decision (Registry's state carries no metatable |
| [codecKit key descriptions, lazy tables and cheaper scans](records/codecKit.md#codeckit-key-descriptions-lazy-tables-and-cheaper-scans) | `codecKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.2.2, revision 9, 16 specs (165) |
| [bridgeKit AceSerializer speed and SettingsKit's character key](records/bridgeKit.md#bridgekit-aceserializer-speed-and-settingskits-character-key) | `bridgeKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.5.2, revision 7, 11 specs (302) |
| [clientKit probe fallback and value descriptions](records/clientKit.md#clientkit-probe-fallback-and-value-descriptions) | `clientKit` | implemented 2026-11-15 under core decisions 18 and 19, 0.3.2, revision 8, 4 specs (182) |
| [widgetKit (package O): a core and parts, pools on first use, no upgrade residue, and widget cycles at AceGUI's cost](records/widgetKit.md#widgetkit-package-o-a-core-and-parts-pools-on-first-use-no-upgrade-residue-and-widget-cycles-at-aceguis-cost) | `widgetKit` | implemented 2026-11-15, 0.5.0, revision 14, 320 specs |


---

| Record | Package | Status |
|---|---|---|
| [settingsKit AceDB scopes, profile lifecycle signals, `missingOk`, and the core side of namespaces](records/settingsKit.md#settingskit-acedb-scopes-profile-lifecycle-signals-missingok-and-the-core-side-of-namespaces) | `settingsKit` | implemented 2026-11-15, 0.6.0, revision 15, 72 specs (370 in all) |


---

| Record | Package | Status |
|---|---|---|
| [settingsKit Namespaces part: AceDB namespaces in the saved layout](records/settingsKit.md#settingskit-namespaces-part-acedb-namespaces-in-the-saved-layout) | `settingsKit` | implemented 2026-11-15, part revision 1, 33.9 KB held only by addons that embed it |
| [moduleKit (package O): the AceAddon conveniences: intended state, module defaults and prototypes, finding addons, a module-created notice](records/moduleKit.md#modulekit-package-o-the-aceaddon-conveniences-intended-state-module-defaults-and-prototypes-finding-addons-a-module-created-notice) | `moduleKit` | implemented 2026-11-15, 0.10.0, revision 23, 288 specs |
| [commandKit (package O): parts for options binding and completion; the command list, a prefix, dispatch, the AceConfigCmd path syntax and general tab completion](records/commandKit.md#commandkit-package-o-parts-for-options-binding-and-completion-the-command-list-a-prefix-dispatch-the-aceconfigcmd-path-syntax-and-general-tab-completion) | `commandKit` | implemented 2026-11-15, 0.3.0, revision 11, 209 specs |
| [signalKit (package O): bucketed bus messages, AceBucket's RegisterBucketMessage, as a part](records/signalKit.md#signalkit-package-o-bucketed-bus-messages-acebuckets-registerbucketmessage-as-a-part) | `signalKit` | implemented 2026-11-15, 0.9.0, revision 12, 281 specs |
| [addonKit (package O): the module defaults and the created notice on the facade](records/addonKit.md#addonkit-package-o-the-module-defaults-and-the-created-notice-on-the-facade) | `addonKit` | implemented 2026-11-15, 0.2.0, revision 2, 79 specs |
| [optionsKit option fields, model side](records/optionsKit.md#optionskit-option-fields-model-side) | `optionsKit` | implemented 2026-11-15 together with the next record as optionsKit 0.8.0, revision 15 (revision 14 never released alone), 270 specs |


---

| Record | Package | Status |
|---|---|---|
| [optionsKit dynamic trees](records/optionsKit.md#optionskit-dynamic-trees) | `optionsKit` | implemented 2026-11-15 in optionsKit 0.8.0, revision 15 |


---

| Record | Package | Status |
|---|---|---|
| [bridgeKit carries option fields over and rebuilds converted trees](records/bridgeKit.md#bridgekit-carries-option-fields-over-and-rebuilds-converted-trees) | `bridgeKit` | implemented 2026-11-15, 0.6.0, revision 8, 317 specs |
| [Shared helper blocks and their gate (architecture plan item 4)](records/tooling.md#shared-helper-blocks-and-their-gate-architecture-plan-item-4) | `tooling` | implemented 2026-11-15 |
| [Kit conformance suite (architecture plan item 5)](records/tooling.md#kit-conformance-suite-architecture-plan-item-5) | `tooling` | implemented 2026-11-15 |
| [One-command client sessions (architecture plan item 7)](records/tooling.md#one-command-client-sessions-architecture-plan-item-7) | `tooling` | implemented 2026-11-15 |
| [Lists generated from the manifests (architecture plan item 8)](records/tooling.md#lists-generated-from-the-manifests-architecture-plan-item-8) | `tooling` | implemented 2026-11-15 |
| [A required `docs/API.md` skeleton and its checker (architecture plan item 9)](records/tooling.md#a-required-docsapimd-skeleton-and-its-checker-architecture-plan-item-9) | `tooling` | implemented 2026-11-15 in warning mode |
| [Benchmark smoke profile, login and saved-variables cases, AceConfigDialog pinned (architecture plan item 10)](records/tooling.md#benchmark-smoke-profile-login-and-saved-variables-cases-aceconfigdialog-pinned-architecture-plan-item-10) | `tooling` | implemented 2026-11-15 |
| [apiKit's flavour files loaded only on their own client (architecture plan item 14)](records/tooling.md#apikits-flavour-files-loaded-only-on-their-own-client-architecture-plan-item-14) | `tooling` | implemented 2026-11-15 |
| [ROADMAP split into a status table and one record file per package (architecture plan item 12)](records/tooling.md#roadmap-split-into-a-status-table-and-one-record-file-per-package-architecture-plan-item-12) | `tooling` | implemented 2026-11-15 and run |


---

| Record | Package | Status |
|---|---|---|
| [schedulerKit (package O): the coalescing family in three parts](records/schedulerKit.md#schedulerkit-package-o-the-coalescing-family-in-three-parts) | `schedulerKit` | implemented 2026-11-15, 0.10.0, revision 22, 307 specs |


---

| Record | Package | Status |
|---|---|---|
| [eventKit (package O): Coalesce and Derive as a part, timed by TimerKit](records/eventKit.md#eventkit-package-o-coalesce-and-derive-as-a-part-timed-by-timerkit) | `eventKit` | implemented 2026-11-15, 0.11.0, revision 22, 309 specs |


---

| Record | Package | Status |
|---|---|---|
| [codecKit (package O): compression as a part](records/codecKit.md#codeckit-package-o-compression-as-a-part) | `codecKit` | implemented 2026-11-15, 0.3.0, revision 10, 184 specs |


---

| Record | Package | Status |
|---|---|---|
| [commKit (package O): SyncSet as a part, ChatThrottle, a new part for chat and Battle.net sends, and SchedulerKit optional](records/commKit.md#commkit-package-o-syncset-as-a-part-chatthrottle-a-new-part-for-chat-and-battlenet-sends-and-schedulerkit-optional) | `commKit` | implemented 2026-11-15, 0.6.0, revision 11, 591 specs (267 rerun the driver without SchedulerKit) |


#### Package N — bridgeKit, migrating from Ace3

Decided 2026-09-25 with the project owner, from the external review that
compared the framework with Ace3 and asked for migration from Ace3 as a
product feature (worklist items 15 to 18). The owner named the package
`bridgeKit` (not `aceBridge`, not a part of interopKit) and moved it ahead of
the user-interface phase. Package letter N is the next free letter after M.
The canonical design is [`BRIDGE_KIT_DESIGN.md`](BRIDGE_KIT_DESIGN.md), which
cites Ace3 file and line at commit `5e2e0d3b` for every format and behaviour it
reproduces; the recipes that need no BridgeKit code (item 17) are
[`MIGRATING_FROM_ACE3.md`](MIGRATING_FROM_ACE3.md), written in this step.

Nothing in this package is ticked until its acceptance review closes. Code
starts only after the owner has answered the design's open questions (section
16) and said go.

| Record | Package | Status |
|---|---|---|
| [bridgeKit](records/bridgeKit.md#bridgekit) | `bridgeKit` | delivered (2026-11-15) |


#### Package P — minimal cores (2026-11-16)

Decided 2026-11-16 with the project owner: measure what each Kit's core
holds, keep in the core only what every user of the Kit needs, at Ace3's size
or below where the documented guarantees allow, move the rest into parts
([ADR 0001](decisions/0001-kit-core-and-parts.md)), bind the helper copies
to their single source in `tooling/shared/lua/`, then run every test.
Records are written before their code.

| Record | Package | Status |
|---|---|---|
| [Shared helper blocks in 27 Kits](records/shared-helpers.md#shared-helper-blocks-in-27-kits) | 27 packages | recorded 2026-11-16; code follows |

### Standing obligations

These apply to every phase rather than being completed once.

- [ ] Keep public APIs documented and version-aware.
- [ ] Add a regression test for every fixed defect.
- [ ] Preserve deterministic lifecycle and ownership semantics.
- [ ] Preserve bounded-by-default retention, caching, scheduling, and pooling.
- [ ] Keep hot paths allocation-conscious and avoid unnecessary table/function creation.
- [ ] Maintain explicit cleanup and teardown paths for long-lived runtime objects.
- [ ] Keep package dependencies minimal, explicit, and acyclic.
- [ ] Maintain manifest, Registry key, package ID, and runtime facade naming consistency.
- [ ] Keep LuaLS/LuaCATS-facing documentation useful for autocomplete and editor tooling.
- [ ] Validate behavior against supported World of Warcraft environments as packages evolve.
- [ ] Keep CI, linting, formatting, repository validation, and test tooling current.

## Planned package policy

Future Kits should be added to this section **when their scope and name are
accepted**, before or together with implementation. The record itself is a
file of its own, `docs/records/<package>.md` (repository tooling in
`docs/records/tooling.md`), and this roadmap carries one table row per record
with its status. Each planned Kit should record:

1. package ID and runtime facade name;
2. purpose and non-goals;
3. dependencies;
4. public API surface;
5. lifecycle/ownership model;
6. performance and memory constraints;
7. test plan;
8. documentation requirements;
9. implementation status.

This prevents speculative package names from becoming accidental architecture.

## Definition of done for a Kit

A Kit is considered complete for its initial release when:

- [ ] its responsibility and boundaries are documented;
- [ ] its manifest and Registry integration are correct;
- [ ] its public API follows framework naming and documentation conventions;
- [ ] normal, error, edge-case, re-entrant, and teardown paths are reviewed;
- [ ] ownership and lifecycle behavior are explicit;
- [ ] retained state is bounded by default where applicable;
- [ ] performance-sensitive paths avoid unnecessary allocation and work;
- [ ] escape hatches are explicit, documented, and observable where applicable;
- [ ] automated tests cover core behavior and regressions;
- [ ] repository validation passes;
- [ ] package documentation and changelog are current.

## Roadmap maintenance

`docs/ROADMAP.md` is the canonical roadmap in repository artifacts. Whenever a
Kit is added, completed, renamed, split, or removed, this file should be updated
in the same change. The nine-point records live in [`records/`](records/), one
file per package; a record's status changes in its file and in its row here.
Repository validation holds every record file to being linked from this file
and every record to having points 1 to 9. Architecture decisions belong in the architecture/design
documents; this roadmap tracks sequencing and delivery status rather than
duplicating those specifications.

---

Last roadmap baseline update: 2026-11-15, later the same day (package M's
twelve Kits implemented, decision 16's capabilities delivered: 41 packages,
40 of them release packages; every unticked item of package M waits only for its
real-client run, which comes last by the owner's decision; the standing
obligations continue).
Previous baseline: 2026-11-15 (phases 0 through 4 and packages F,
G and H complete; phase 5 packages I, J, K and L complete; package N, bridgeKit,
delivered: steps N0 to N5 done, so 29 packages, 28 of them release
packages, every gate green; the user-interface phase (package M) follows
package N by the owner's decision; the standing obligations continue), and before
it 2026-09-25.
