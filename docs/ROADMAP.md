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

**clientKit** — facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1.
2. Purpose: one place that answers "which client is this and what can it
   do", and normalised shims for the few host calls whose name or shape
   differs between flavours. Non-goals: gameplay data, range or spell logic,
   anything a domain library should own; no polyfill of missing features.
3. Dependencies: registry API 2 only.
4. Surface: `GetFlavor()` (`"mainline" | "mists" | "tbc" | "classic"`),
   `GetBuild()` and `GetInterfaceNumber()`, `IsAtLeast(interfaceNumber)`,
   `Has(capability)` over a fixed, documented capability table
   (`C_AddOns`, `C_Spell`, `C_Item`, `C_Timer`, `secretValues`,
   `restrictedFrames`, `spellbookApi`, ...), `IsSecret(value)`,
   `CanAccessFrame(frame)`, `IsEventValid(eventName)`, and shims
   `GetAddOnMetadata`, `IsAddOnLoaded`, `GetSpellInfo`, `GetItemInfo`
   returning one shape on every flavour. Every flag reads `false` when the
   host does not expose the feature; an absent `WOW_PROJECT_ID` yields the
   most conservative flavour, never "everything true".
5. Ownership: stateless facade; the capability table is computed once at
   bootstrap and re-read on upgrade. Nothing to tear down.
6. Performance: each probe is a table read after bootstrap; shims add one
   call. No allocation after bootstrap, except the legacy `GetSpellInfo`
   shim, which builds the result table modern clients return ready made.
7. Tests: one fixture profile per supported flavour (four), the
   `WOW_PROJECT_ID` absent case, the secret-value and forbidden-frame stubs,
   `IsEventValid` for a known, an unknown and an invalid name, upgrade.
8. Docs: README, API.md with the capability table and the shim shapes,
   EMBEDDING.md host-requirements row, CHANGELOG.
9. Status: implemented (package B1, 0.1.0).

**cacheKit** — facade `CacheKit`

1. Package `cacheKit`, facade `CacheKit`, API generation 1.
2. Purpose: bounded caches for consumers so "bounded by default" is a
   structure they reach for instead of a rule they remember: LRU by count,
   TTL by age, memoisation, snapshots with diffs, and clearing on a host
   event. Non-goals: persistence (settingsKit), cross-addon sharing.
3. Dependencies: registry API 2; eventKit API 1 optional (clear-on-event
   resolved through `Registry:Find`); a clock through the same fallback as
   timerKit (absent clock disables TTL, documented).
4. Surface: `CacheKit:NewLru{ maxEntries }`, `CacheKit:NewTtl{ maxEntries,
   ttlSeconds }` with `Get`, `Set`, `Peek`, `Delete`, `Clear`, `GetCount`,
   `GetStats()` (hits, misses, evictions); `CacheKit:Memoize(fn, options)`
   for one string-or-number key; `CacheKit:NewSnapshot(read, options)` where
   `read(fill)` calls `fill(key, value)`, with `Refresh()` returning added, removed and changed keys without
   allocating per unchanged key; `cache:ClearOn(eventName)` when eventKit
   is present.
5. Ownership: caches are owned by their creator and closed with `Close()`;
   clear-on-event connections are released on `Close`. An upgrade keeps
   entries.
6. Performance: LRU is an intrusive doubly linked list over a hash; `Get`
   and `Set` are O(1) and allocate only for a new entry; eviction reuses
   entry tables from a bounded free list. `maxEntries` is required on LRU
   and TTL caches and defaults to 128 for `Memoize` and 1024 for a snapshot,
   so no cache is unbounded.
7. Tests: eviction order, TTL expiry with the clock stub, memoise hit and
   miss, snapshot diff, clear-on-event, `Close`, allocation guard, upgrade.
8. Docs: README, API.md, INTERNALS.md (list and free-list layout),
   CHANGELOG.
9. Status: implemented (package B1, 0.1.0).

**profileKit** — facade `ProfileKit`

1. Package `profileKit`, facade `ProfileKit`, API generation 1.
2. Purpose: measure the framework and its consumers inside the client:
   named sections with call count, total time, worst spike and last time;
   a report; zero cost when off. Non-goals: memory profiling, per-frame
   graphs, anything shipped enabled.
3. Dependencies: registry API 2; `debugprofilestop` for CPU time (the
   measurement is disabled, not failing, when absent).
4. Surface: `ProfileKit:Enable()` / `Disable()` / `IsEnabled()`,
   `ProfileKit:Section(name)` returning a section with `Begin()` and
   `End()`; `ProfileKit:Measure(name, fn, ...)` returning fn's results;
   `ProfileKit:Report()` returning a sorted array of `{ name, count,
   total, max, last }`; `ProfileKit:Reset()`. When disabled, `Begin`,
   `End` and `Measure` are no-ops bound at enable time so callers pay a
   table read and a call.
5. Ownership: package-level state, bounded by the `maxSections` limit
   (default `DEFAULT_MAX_SECTIONS`, 256; opened with `ProfileKit:SetLimits`
   or `ProfileKit.UNBOUNDED`; further sections refused with a reason).
6. Performance: `Begin` and `End` allocate nothing; `Report` allocates by
   design and says so. Enabled overhead is two clock reads per section.
7. Tests: disabled path is a no-op, enable and measure with the clock stub,
   nested sections, spike and last, `Measure` passing results and errors
   through, cap refusal, `Reset`, upgrade.
8. Docs: README, API.md, CHANGELOG; a DEVELOPMENT.md paragraph on
   measuring a Kit change.
9. Status: implemented (package B1, 0.1.0).

**readinessKit** — facade `ReadinessKit`

1. Package `readinessKit`, facade `ReadinessKit`, API generation 1.
2. Purpose: gates for host data that arrives after load and is `nil` or
   wrong until then (spell and item information, the spellbook, talents,
   the guild roster), so consumers wait for a fact instead of a timer.
   Non-goals: the data itself, retries of the consumer's own work, anything
   the lifecycle phases already express.
3. Dependencies: registry API 2, timerKit API 1 (polling); eventKit API 1
   optional through `Registry:Find` (re-probe on a host event).
4. Surface: `ReadinessKit:Gate(name, probe, options)` where `probe()`
   returns `true` when the data is usable; options `intervalSeconds`
   (default 0.5), `timeoutSeconds` (default 30, `false` for none),
   `maxWaiters` (default 64); gate methods `IsReady()`, `Await(callback)`
   (runs at once when ready, else queued up to `maxWaiters` and refused
   with `"full"` beyond), `Probe()` (re-run now, negative result cached
   until the next interval), `Invalidate()` (ready → not ready, polling
   resumes), `ReprobeOn(eventName)` (eventKit present), `Close()`;
   `ReadinessKit:WhenAll(gates, callback)` and `ReadinessKit:Get(name)`.
   A timeout calls waiters with `false, "timeout"` once and stops polling
   until `Probe()` or `Invalidate()`.
5. Ownership: gates are named per package state, one per name, closed by
   `Close()`; polling uses a timerKit scope owned by the Kit; upgrades keep
   gates and waiters.
6. Performance: no polling while a gate is ready or timed out; one timer
   per polling gate; waiters stored in a bounded array reused across
   rounds; `IsReady` is a field read.
7. Tests: ready at once, ready after N polls with the timer stub, timeout,
   Invalidate resumes polling, negative cache (probe not re-run within the
   interval), waiter cap, ReprobeOn with and without eventKit, WhenAll,
   Close, upgrade, manifest, error levels.
8. Docs: README, API.md, CHANGELOG; EMBEDDING.md host row.
9. Status: implemented (package B2, 0.1.0).

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

**schemaKit** — facade `SchemaKit`

1. Package `schemaKit`, facade `SchemaKit`, API generation 1.
2. Purpose: one validation core for the values a Kit receives from outside
   its own code: API arguments, saved variables, options, received messages.
   A schema is built once, sealed, and then validates values with structured
   failures (path, rule, expected, found) that never print the offending
   value. Non-goals: type inference from Lua, coercion beyond what a schema
   declares, JSON Schema compatibility.
3. Dependencies: registry API 2 only.
4. Surface: builders `S.string{...}`, `S.number{min,max,integer}`,
   `S.boolean()`, `S.enum{...}`, `S.table{fields, open}`, `S.array{of, min,
   max}`, `S.map{keys, values, max}`, `S.optional(schema, default)`,
   `S.oneOf{...}`, `S.any()`, `S.custom(check, description)`;
   `SchemaKit:Seal(schema)` (deep-freezes and pre-compiles); `schema:Check(value)`
   → `true` or `false, failure` (failure is a reused table per schema unless
   `options.freshFailures`); `schema:Assert(value, argumentName, level)`
   raises at the caller with a message built from the failure;
   `schema:Apply(value)` fills defaults into a copy (allocating, documented);
   `schema:Describe()` for documentation and options UIs; secret values are
   refused with rule `"secret"` before any comparison when `issecretvalue`
   exists.
5. Ownership: schemas are immutable after Seal and safe to share across
   addons; nothing to tear down.
6. Performance: `Check` allocates nothing for a valid value and reuses one
   failure table per schema for an invalid one; nested checks recurse without
   closures; depth bounded (`maxDepth` 16) and array/map sizes bounded by the
   schema, so a hostile message cannot make validation unbounded.
7. Tests: every builder's accept and reject cases, nested paths in failures,
   defaults applied, sealed immutability, depth and size bounds, secret
   refusal, allocation guard on valid checks, Describe output, upgrade,
   manifest, error levels pinned.
8. Docs: README, API.md with a schema cookbook, INTERNALS.md (compiled form),
   CHANGELOG; EMBEDDING.md host row.
9. Status: implemented (package C1, 0.1.0); deviations recorded in
   `packages/schemaKit/docs/API.md`.

**localeKit** — facade `LocaleKit`

1. Package `localeKit`, facade `LocaleKit`, API generation 1.
2. Purpose: translations per addon and locale with the cost of one table on
   any client, missing-key reporting once per key, a coverage report, and
   indexed format specifiers so translators can reorder arguments. Non-goals:
   plural rules, gender, shipping any translations.
3. Dependencies: registry API 2 only.
4. Surface: `LocaleKit:NewLocale(addonName, locale, options)` → a write
   proxy for that locale, or `nil` when the client does not need it
   (`options.isDefault` marks the fallback locale; a per-call proxy, never a
   shared one; the default proxy never overwrites a translated key);
   `LocaleKit:GetLocale(addonName, options)` → the read table for the
   running client, `__index` returning the key and reporting once through
   the host error handler (`options.missing = "report" | "silent" |
   "raw"`); `LocaleKit:Format(template, ...)` supporting `%1$s`-style
   indexed specifiers; `LocaleKit:MissingKeys(addonName)` → sorted array;
   `LocaleKit:SetLocaleOverride(locale)` for translators; `enGB` folded to
   `enUS`.
5. Ownership: locale tables are package state keyed by addon name; nothing
   to tear down; upgrades keep them.
6. Performance: a translation lookup is one table read; a missing key is
   `rawset` on first use so it costs the report once; `Format` allocates only
   strings (each formatted piece and the result), no tables.
7. Tests: proxy for the running locale versus `nil`, default proxy not
   overwriting, missing-key modes, report once, MissingKeys sorted,
   indexed format including reordering and repeated arguments, override,
   enGB folding, upgrade, manifest, error levels pinned.
8. Docs: README, API.md, CHANGELOG; a translation-file example.
9. Status: implemented (package C2, 0.1.0).

**hookKit** — facade `HookKit`

1. Package `hookKit`, facade `HookKit`, API generation 1.
2. Purpose: reversible hooking with the three semantics named and the taint
   consequences spelled out: secure post-hook (default, wraps
   `hooksecurefunc` and `frame:HookScript`, made reversible by an active
   flag on a closure that stays installed), safe pre-hook (handler first,
   original always runs, returns untouched) and raw replacement (original
   handed to the handler). Non-goals: hooking secure functions insecurely
   without an explicit override, hooking protected scripts on protected
   frames.
3. Dependencies: registry API 2; clientKit API 1 optional through
   `Registry:Find` for `IsSecret` and capability flags.
4. Surface: `HookKit:CreateScope()` / `HookKit:ForAddon(addonName)` →
   scope with `SecureHook(object, method, handler)`, `SecureHookScript(frame,
   script, handler)`, `Hook(object, method, handler, options)`,
   `RawHook(object, method, handler, options)`, `HookScript(frame, script,
   handler, options)`, `Unhook(object, method)`, `UnhookAll()`, `IsHooked`,
   `Hooks()` (enumeration for diagnostics), `Close()`; `options.forceSecure`
   is the explicit override for a non-secure hook of a secure target and the
   target's secure status is remembered from before the first hook.
5. Ownership: hooks belong to a scope; moduleKit's `module.scope` gains
   `Hooks` lazily; restoration on unhook happens only when the installed
   function is still ours, otherwise the closure stays and turns inert.
6. Performance: one record per hook keyed by object and method in a
   weak-keyed table (no auto-vivifying registry); the installed closure
   reads one flag before dispatching; bounded hooks per scope
   (`maxHooks` 256).
7. Tests: each of the three semantics, unhook with and without a later
   foreign hook, secure target refusal and override, protected script
   refusal, scope Close, IsHooked and Hooks, secret argument passing through
   untouched, upgrade, manifest, error levels pinned.
8. Docs: README, API.md leading with the taint model, CHANGELOG;
   EMBEDDING.md host row and a taint-section cross-reference.
9. Status: implemented (package C2, 0.1.0); deviations recorded in
   `packages/hookKit/docs/API.md`.

**settingsKit** — facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1.
2. Purpose: saved variables done once: a database opened over the addon's
   SavedVariables table with scopes (`global`, `char`, `realm`, `class`,
   `faction`, `profile`), defaults applied without being written back
   (including wildcard defaults for keyed sections), profiles with copy,
   reset and delete, change notifications, and versioned migrations.
   v1 ships profiles; spec-aware profiles and namespaces are v2 (recorded
   here so the state layout leaves room: a `namespaces` table and a
   `profileKeys` table exist from v1). Non-goals: an options UI, storage
   outside SavedVariables, encryption.
3. Dependencies: registry API 2, schemaKit API 1 (defaults and validation),
   signalKit API 1 (change and profile signals); lifecycleKit API 1
   optional through `Registry:Find` (flush hook at shutdown is the host's
   job; nothing to do — documented).
4. Surface: `SettingsKit:Open(savedVariable, schema, options)` where
   `savedVariable` is the global name from the TOC (the table is created if
   missing), `schema` a `SchemaKit.table` per scope (`{ global = ..., profile
   = ..., char = ... }`), options `defaultProfile` (`"Default"` or `"char"`
   for one profile per character), `version` and `migrations = { [n] = fn(db) }`;
   the returned `db` exposes `db.global`, `db.char`, `db.realm`, `db.class`,
   `db.faction`, `db.profile` as live tables whose reads fall back to
   defaults through a metatable and whose writes are validated against the
   schema at the writer's line; `db:GetProfile()`, `db:SetProfile(name)`,
   `db:GetProfiles()` (sorted, allocating), `db:CopyProfile(from)`,
   `db:ResetProfile()`, `db:DeleteProfile(name)`, `db:ResetDatabase()`,
   `db:OnChange(scope, callback)` / `db:OnProfileChanged(callback)` returning
   SignalKit connections; `db:Compact()` removes values equal to defaults
   before logout (called automatically on `PLAYER_LOGOUT` when EventKit is
   present, documented).
5. Ownership: one `db` per saved-variable name in package state; connections
   are the consumer's; upgrades keep databases and their listeners.
6. Performance: a read is one table read or one default lookup; a write is
   one schema check plus one table write; no per-read allocation; default
   fallback never writes into the saved table, so files stay small; scopes
   are resolved once at `Open` from `UnitName`, `GetRealmName`,
   `UnitClass`, `UnitFactionGroup` (stubbed in tests).
7. Tests: defaults not written back, wildcard defaults, validated writes at
   the caller's line, each scope key, profile switch with signal, copy,
   reset, delete (current profile refused), migrations in order once,
   Compact, OnChange, upgrade keeping the db, manifest, error levels.
8. Docs: README, API.md with a full addon example (TOC `## SavedVariables`,
   schema, Open in OnLoaded), INTERNALS.md (layout of the saved table),
   CHANGELOG; EMBEDDING.md host row and a saved-variables section.
9. Status: implemented (package C2, 0.1.0); deviations recorded in
   `packages/settingsKit/docs/API.md`.

**optionsKit** — facade `OptionsKit`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1.
2. Purpose: a typed, validated, introspectable options tree with no
   renderer: what an addon exposes as configurable, how each option is
   read and written, and what a UI or a command line needs to present it.
   Non-goals: widgets, a dialog, slash parsing (commandKit binds to it).
3. Dependencies: registry API 2, schemaKit API 1 (value validation),
   signalKit API 1 (change signals); settingsKit API 1 optional through
   `Registry:Find` (binding an option to a database path).
4. Surface: `OptionsKit:Define(addonName, tree)` where the tree is nested
   groups of typed options: `group`, `toggle`, `range { min, max, step }`,
   `select { values }`, `multiselect { values }`, `input { pattern,
   multiline }`, `color { alpha }`, `keybinding`, `execute { func }`,
   `header`, `description`; each with `name`, `desc`, `order`, `get`/`set`
   or `bind = "profile.path.to.value"` (settingsKit), `disabled`/`hidden`
   as booleans or predicates, `validate`; `options:Get(path)`,
   `options:Set(path, value)` (validated through the option's schema at the
   caller's line, then the setter, then a change signal), `options:Walk(fn)`
   in order, `options:Describe()` (plain table for renderers, allocating),
   `options:OnChange(callback)`, `options:Reset(path)` to the bound default;
   `OptionsKit:Get(addonName)`.
5. Ownership: one tree per addon name in package state; the tree is sealed
   at `Define`; upgrades keep trees.
6. Performance: `Get` and `Set` are path lookups on a pre-indexed map (no
   string splitting per call after Define); `Walk` allocates nothing;
   `Describe` allocates by design.
7. Tests: every option type validated, bind to settingsKit and to
   getters, order, disabled/hidden predicates, change signal, Reset,
   unknown path errors at the caller, Describe shape, Walk order, upgrade,
   manifest, error levels.
8. Docs: README, API.md with a complete options tree example, CHANGELOG;
   a note on how a renderer (widgetKit, package E) consumes Describe.
9. Status: implemented (package C3, 0.1.0); deviations recorded in
   `packages/optionsKit/docs/API.md`.

**commandKit** — facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1.
2. Purpose: slash commands done once: registration that follows the module
   that owns it, an argument parser that understands quotes and WoW
   hyperlinks so a shift-clicked item does not break a command, sub-commands
   with usage and help generated from their declarations, output sinks
   (chat frame, a custom frame, a capture for tests), tab completion, and a
   binding that drives an optionsKit tree from the command line. Non-goals:
   a console UI, macros, anything that sends chat to other players.
3. Dependencies: registry API 2, schemaKit API 1 (argument schemas);
   optionsKit API 1 optional through `Registry:Find` (binding), localeKit
   API 1 optional (localised help), clientKit API 1 optional (`IsSecret`).
4. Surface: `CommandKit:CreateScope()` / `ForAddon(addonName)` → scope
   with `Register(name, spec)` where `spec` has `handler(context, ...)`, an
   optional `arguments` schema (a `SchemaKit.array` or per-position list),
   `usage`, `description`, `subcommands = { name = spec }`, `complete(text)`
   for custom completion; the slash global `SLASH_<KEY>1` and
   `SlashCmdList[<KEY>]` are written through `rawset` with a key derived
   from the addon and command names, refused when the slash name is already
   taken by another owner (`nil, "taken"`); `Unregister(name)`, `Close()`
   removes every command of the scope (the slash global is left pointing at
   an inert function because the client's table cannot be cleaned;
   documented); `CommandKit:Parse(text)` → arguments array honouring
   `"quoted strings"` and `|H...|h[...]|h` hyperlinks as single tokens,
   allocating one array per call (documented) plus `CommandKit:ParseInto(text,
   array)` for the allocation-free form; `context:Print(...)`,
   `context:Printf(format, ...)`, `context:Usage()`, `context:Fail(reason)`
   to the scope's sink; `scope:SetSink(sink)` where a sink is
   `{ AddMessage = fn }`; `CommandKit:CaptureSink()` for tests;
   `scope:BindOptions(optionsTree, commandName)` generating `get`, `set`,
   `reset`, `list` sub-commands over an optionsKit tree with values parsed
   through the option's schema; tab completion through `ChatEdit` hooks when
   `ChatEdit_CustomTabPressed` exists (optional, documented).
5. Ownership: commands belong to a scope; moduleKit's `module.scope` gains
   `Commands` lazily; lifecycleKit closes the addon's command scopes at
   shutdown through `CloseAddonScopes` (two-step, as for EventKit).
6. Performance: dispatch is one table lookup on the slash key and one on
   the sub-command; parsing allocates only in the `Parse` form; bounded
   commands per scope (`maxCommands` 64) and sub-command depth 3.
7. Tests: registration writes the two globals, taken slash refused, parse
   with quotes, hyperlinks, mixed and malformed input, sub-command dispatch
   and usage, schema-validated arguments refused with a message, sink
   capture, BindOptions get/set/reset/list against a real optionsKit tree,
   completion with a stubbed ChatEdit, Close leaves an inert global,
   upgrade, manifest, error levels.
8. Docs: README, API.md with a full slash-command example, CHANGELOG;
   EMBEDDING.md host row (`SlashCmdList`, `SLASH_*`, `DEFAULT_CHAT_FRAME`,
   `ChatEdit_CustomTabPressed`).
9. Status: implemented (package C3, 0.1.0); deviations recorded in
   `packages/commandKit/docs/API.md`.

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

**codecKit** — facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1.
2. Purpose: turn Lua values into transport-safe strings and back in three
   composable stages behind one self-describing header byte: serialise
   (strings, numbers including floats that do not survive `tostring`,
   booleans, nil, acyclic tables), compress (a DEFLATE-class codec written
   in pure Lua, yielding in blocks when run under a scheduler), and
   channel-encode (escape for the addon channel, or printable 7-bit for
   chat and export strings). Decoding never raises on malformed input.
   Non-goals: functions, userdata, metatables, shared-reference
   preservation (cycles are detected and refused), encryption,
   cross-language formats.
3. Dependencies: registry API 2; poolKit API 1 (leased fragment buffers);
   schedulerKit API 1 optional through `Registry:Find` (asynchronous
   variants).
4. Surface: `CodecKit:Encode(value, options)` → `true, string` or `false,
   reason` with `options.compress` (`"none" | "deflate"`), `options.channel`
   (`"addon" | "print"`); `CodecKit:Decode(string, options)` → `true, value`
   or `false, reason` (the header says which stages to reverse; an unknown
   header version is refused with a clear reason); the stages alone:
   `Serialize` / `Deserialize`, `Compress` / `Decompress`, `EncodeForAddon`
   / `EncodeForPrint` and their inverses; `CodecKit:EncodeAsync(value,
   options, scope, callback)` and `DecodeAsync` running in blocks on a
   schedulerKit scope under the frame budget; `CodecKit:SetLimits{ maxDepth,
   maxValues, maxStringLength, maxOutputBytes, maxListValues }` /
   `GetLimits()`, all bounded by default and documented as shared by every
   consumer, with `UNBOUNDED` accepted for `maxValues` and `maxStringLength`
   (still bounded by `maxOutputBytes`);
   `CodecKit.FORMAT_VERSION`.
5. Ownership: stateless apart from limits; buffers are leased from a poolKit
   table pool per call and returned, so calls are re-entrant.
6. Performance: one `table.concat` per encode; single-pass decode; every
   limit named in the refusal; compression cost documented per kilobyte
   and yielding in the asynchronous form so a large export never freezes a
   frame.
7. Tests: round-trip of every type and edge (control bytes, the escape
   byte, empty and long strings, integers past 2^53, `math.huge`, NaN,
   subnormal numbers), nested and mixed tables, nil in the middle of an argument
   list, cycle refusal, every limit, malformed input of every shape never
   raising, a fuzz pass over random bytes, compression round-trips against
   known vectors, asynchronous encode under a budget with the scheduler
   stub, allocation guard, upgrade, manifest, error levels.
8. Docs: README, API.md specifying the wire format byte by byte with the
   header and extension rules, the type matrix and the security note that
   decoded data is untrusted; INTERNALS.md (compressor design); CHANGELOG.
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/codecKit/docs/API.md`.

**commKit** — facade `CommKit`

1. Package `commKit`, facade `CommKit`, API generation 1.
2. Purpose: addon messaging of arbitrary length with prefix registration,
   chunking and reassembly, priority queues that refuse rather than grow, a
   bandwidth budget shared with everything else in the session (including
   traffic sent outside the Kit, measured through a secure hook), bounded
   per-sender reassembly with expiry, payload-driven channel selection, and
   a content-hash `SyncSet` for versioned fields with delta replies.
   Non-goals: serialisation (codecKit), encryption, guaranteed delivery or
   ordering across priorities, exceeding the client's rate limits.
3. Dependencies: registry API 2, signalKit API 1, eventKit API 1
   (`CHAT_MSG_ADDON`), schedulerKit API 1 (the send driver is a lane that
   exists only while something is queued), poolKit API 1 (message and chunk
   records); codecKit API 1 and hookKit API 1 optional through
   `Registry:Find` (hashing for SyncSet, the outside-traffic hook);
   lifecycleKit API 1 for addon scopes.
4. Surface: `CommKit:ForAddon(addonName)` / `CreateScope()`;
   `scope:Register(prefix, callback)` → connection (callback receives
   `prefix, text, distribution, sender` and never a partial message);
   `scope:Send{ prefix, text, distribution, target, priority, constraints,
   onProgress, onComplete }` → send handle or `nil, reason` when a bound
   would be exceeded (`"queueFull"`, `"tooLarge"`, `"closed"`); handle
   `Cancel()`, `GetState()`, `GetBytesSent()`, `GetBytesTotal()`;
   `CommKit.Priority.ALERT | NORMAL | BULK`; `scope:SyncSet(prefix, {
   fields, schema })` → `Set(field, value)`, `Request(target)`,
   `OnChanged(callback)`; package `GetQueueDepth(priority)`, `GetBudget()`,
   `SetLimits{ maxQueuedBytes, maxQueuedMessages, maxReassemblyStreams,
   maxReassemblyBytesPerSender, maxInFlightPerSender, reassemblyTimeout }`,
   `GetStatistics()`.
5. Ownership: a registration belongs to a scope, released on close and at
   shutdown; reassembly streams keyed by prefix, distribution and sender,
   bounded in count, bytes and time, evicted on peer departure; an evicted
   stream is reported once per stream.
6. Performance: every queue bounded in messages and bytes with a named
   refusal; the single-chunk receive path allocates no table; per-destination
   round-robin inside a priority; no per-frame handler while idle; frame
   rate sampled on a timer, never on the hot path; adaptive degradation of
   the budget below 20 frames per second and for five seconds after login or
   zoning.
7. Tests: chunking at every boundary, reassembly in and out of order, a
   missing chunk, interleaved streams from one sender, a stream that never
   completes and expires, a hostile chunk header refused at quota, every
   bound reached with the refusal surfaced, priority fairness and
   round-robin, the throttled result putting a pipe aside, budget accounting
   with a simulated outside sender, cancel while queued and mid-send, scope
   close and shutdown mid-send, SyncSet delta and ack, statistics, all
   against the stubbed client and clock; upgrade; manifest; error levels.
8. Docs: README, API.md specifying the chunk protocol byte by byte, the
   bounds and their defaults, the priority model, the shared-bandwidth
   statement and the security note that received data is untrusted;
   INTERNALS.md; CHANGELOG; EMBEDDING.md host row (`C_ChatInfo`).
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/commKit/docs/API.md`.

**interopKit** — facade `InteropKit`

1. Package `interopKit`, facade `InteropKit`, API generation 1. The
   roadmap first placed the LibStub bridge inside `registry`; the registry
   file's 1000-line budget is spent, and its header says the bridge goes into
   its own package in that case, so it does.
2. Purpose: let a MoltenCodes package be found by LibStub consumers, and let
   a LibStub library be found through the Registry as a foreign, read-only
   entry, so an addon that embeds our Kits can also use LibDataBroker,
   LibSharedMedia and their kind without two lookup idioms. Non-goals: a
   LibStub replacement, upgrading LibStub libraries, changing LibStub.
3. Dependencies: registry API 2; LibStub optional at runtime (found through
   `rawget(_G, "LibStub")`).
4. Surface: `InteropKit:ExposeToLibStub(package, api, major)` registers
   the package's facade under `major` (default `"MoltenCodes-<Facade>-<api>"`)
   with the minor derived from the revision, idempotent, `false, "absent"`
   when LibStub is not loaded, refused when the major is already held by a
   table that is not ours; `InteropKit:AdoptFromLibStub(major)` → the
   library table and its minor, or `nil, reason`, and records it in the
   Registry as a foreign entry readable through `InteropKit:Find(major)` (and, if the registry
   budget allows, listed by `Registry:Packages()`) that `Registry:Packages()` lists with
   status `foreign`; `InteropKit:IsLibStubPresent()`;
   `InteropKit:ExposeAll(options)` exposing every loaded Kit for an addon
   that wants to publish the framework to LibStub consumers.
5. Ownership: load-time registrations kept in package state; upgrades keep
   them; nothing to tear down (LibStub entries are permanent by design).
6. Performance: load-time only; no per-call cost after registration.
7. Tests: with and without a LibStub stub, expose idempotence, foreign major
   refusal, minor from revision, adopt success and absence, foreign entry
   visible through Find and Packages, ExposeAll, upgrade, manifest, error
   levels.
8. Docs: README, API.md, CHANGELOG; EMBEDDING.md "Coexisting with LibStub"
   gains the shipped bridge.
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/interopKit/docs/API.md`.

**mediaKit** — facade `MediaKit`

1. Package `mediaKit`, facade `MediaKit`, API generation 1.
2. Purpose: a typed registry of named media (font, statusbar, border,
   background, sound, texture, icon), each entry a path or a FileDataID,
   fonts carrying the scripts they cover, with deterministic sorted listing,
   per-consumer defaults and change signals; mirrors registrations into
   LibSharedMedia when it is present and adopts its entries read-only so
   existing packs stay visible. Non-goals: shipping media, global user
   overrides (a consumer's saved variables do that).
3. Dependencies: registry API 2, signalKit API 1; LibStub and
   LibSharedMedia-3.0 optional at runtime through the LibStub bridge.
4. Surface: `MediaKit:Register(type, name, data, options)` (`options.scripts`
   for fonts, refused for a duplicate name with `nil, "taken"`),
   `Fetch(type, name)`, `Has(type, name)`, `List(type)` (cached sorted
   array rebuilt after a registration, documented as shared and read-only),
   `OnRegistered(type, callback)`, `AdoptLibSharedMedia()`, `IsFileDataID(data)`.
5. Ownership: one session-wide registry in package state; connections belong
   to their creator; upgrades keep entries.
6. Performance: registration at load time; `Fetch` one table read; `List`
   rebuilt only after a registration; entries bounded per type
   (`maxEntriesPerType` 1024).
7. Tests: sorted listing determinism, script filtering by client locale,
   FileDataID and path both typed, duplicate refusal, mirror both ways with
   a LibSharedMedia stub, no allocation on `Fetch`, upgrade, manifest,
   error levels.
8. Docs: README, API.md, CHANGELOG; EMBEDDING.md host row.
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/mediaKit/docs/API.md`.

**testKit** — facade `TestKit`

1. Package `testKit`, facade `TestKit`, API generation 1. A development-only
   package, excluded from release bundles by `.pkgmeta`.
2. Purpose: run suites inside the client against LifecycleKit phases, which
   is the only way to test real event order and payload shapes, combat
   lockdown, taint (asserting `issecurevariable` after our code runs) and
   the fidelity of the shared test fixture. Non-goals: replacing Busted.
3. Dependencies: registry API 2, lifecycleKit API 1, schedulerKit API 1.
4. Surface: `TestKit:Suite(name, { phase })` → suite with `Test(name, fn)`
   whose context offers `Replace(table, key, value)` (restored after each
   test, also on failure), `Yield()`, `WaitFor(event, timeoutSeconds)`,
   `Expect(...)` assertions that never print secret values; `TestKit:Run(filter)`,
   `TestKit:Report()` → structured results a slash command can dump for
   comparison with the Busted run; a fixture-fidelity suite shipped in
   `tests/` that runs the same assertions in both environments.
5. Ownership: every replacement restored per test; suites bounded
   (`maxSuites` 64, `maxTests` 256 per suite).
6. Performance: zero cost unless loaded; never in a release bundle.
7. Tests: Busted specs for the harness itself (restore on error, tallying,
   async timeouts, filter), plus the fixture-fidelity suite.
8. Docs: README, API.md, CHANGELOG; a TESTING.md layer "in-client suites".
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/testKit/docs/API.md`.

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

**widgetKit** — facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1. A core
   package; widget sets beyond the base set become their own packages later
   so that independent publication holds.
2. Purpose: a versioned registry of pooled, acquire-and-release widget types
   with a small base contract, named callbacks, registered layout functions,
   a normalised anchor value type with position persistence, and an
   options renderer that consumes `optionsKit`'s `Describe`. Non-goals: a
   theming system, animation, wrapping every client template, replacing
   plain frames where they are simpler.
3. Dependencies: registry API 2, poolKit API 1 (pools for objects that
   cannot be freed, with generation stamps), signalKit API 1 (callbacks);
   optionsKit API 1, settingsKit API 1, schedulerKit API 1 and mediaKit
   API 1 optional through `Registry:Find` (the renderer, position
   persistence with a debounced save, media pickers).
4. Surface: `WidgetKit:RegisterType(name, constructor, version)`,
   `GetTypeVersion(name)`, `Create(name)` → widget, `Release(widget)`,
   `RegisterLayout(name, layoutFunction)` / `GetLayout(name)`,
   `SetFocus(widget)` / `ClearFocus()`, `GetStatistics()`; widget base:
   `OnAcquire` / `OnRelease` hooks, `SetCallback(name, callback)` /
   `Fire(name, ...)`, `SetUserData` / `GetUserData`, size, anchor and
   visibility pass-through methods, `IsReleasing()`; container base: `AddChild`,
   `AddChildren`, `ReleaseChildren`, `SetLayout`, `PauseLayout`,
   `ResumeLayout`, `PerformLayout`, the upward `LayoutFinished` size report;
   layouts in generation 1: `List`, `Fill`, `Flow`; base widgets in
   generation 1: `Frame` (window with title and close), `Group`,
   `ScrollFrame`, `Label`, `Button`, `CheckBox`, `Slider`, `EditBox`,
   `Dropdown`, `ColorPicker`, `Heading`, `Spacer`; anchors:
   `WidgetKit.Anchor.FromRect(rect, parentRect)` (pure, elects the nearest
   point), `Normalize(frame, ...)`, `Apply(frame, anchor)`, `Read(frame)`,
   `WidgetKit:BindPosition(frame, storageTable, options)` → binding with
   `OnMoved(callback)` and `Release()`; renderer:
   `WidgetKit:RenderOptions(optionsTree, container)` → a released-together
   set of widgets driving `Get` / `Set` / `Execute`, honouring `disabled`,
   `hidden`, `order` and `validate` refusals shown inline.
5. Ownership: one bounded pool per widget type; a widget built by an older
   registered version is discarded rather than reused; `Release` fires
   `OnRelease`, releases children first, clears user data, callbacks and
   anchors, hides and re-parents, then returns to the pool; the number of
   frames ever created per type is capped with a named refusal;
   `IsReleasing` is ancestor-aware.
6. Performance: bounded pools with `Trim` reachable through PoolKit; LIFO
   acquire; layout is an explicit operation, never a reaction to
   `OnSizeChanged`; layout scratch tables from a pool; a documented cap on
   children per container (256); callback errors isolated and reported;
   position saves debounced through SchedulerKit when present.
7. Tests: type versioning incl. a lower version ignored, acquire and
   release round-trip, pooled reuse, stale-generation discard after a type
   upgrade, double release refused, foreign widget refused, container add
   and release incl. nested order, `IsReleasing` through an ancestor chain,
   each layout against the frame fixture with recorded anchor calls (the
   shared fixture gains sizes and anchors), layout recursion refusal, frame
   cap, anchor election table cases, position binding save and restore,
   renderer against a real optionsKit tree for every option kind,
   allocation guard on acquire and release cycles, upgrade, manifest, error
   levels.
8. Docs: README, API.md with the widget author contract stated as
   requirements, the release contract, the layout contract, the versioning
   rule, the frame cap, the anchor model and a worked custom widget and
   layout; INTERNALS.md for the layout algorithms and the renderer;
   CHANGELOG; EMBEDDING.md host row and a UI section.
9. Status: implemented (package E, 0.1.0); deviations recorded in
   `packages/widgetKit/docs/API.md`.

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

**apiKit** — facade `ApiKit`

1. Package `apiKit`, facade `ApiKit`, API generation 1.
2. Purpose: a complete, typed, documented, flavour-aware developer interface
   over the public World of Warcraft addon API. Per flavour (Retail, Classic
   Era, Mists of Pandaria Classic, PTR, Beta) a generated file binds every
   documented `C_*` function and documented global function to a readable
   name (`api.addOnProfiler.measureCall`, alias `api.profiler`), exposes
   event names and enum tables, and ships LuaCATS definitions so an editor
   completes exactly what that flavour has. Metadata normalised from the
   client's documentation tables is the single source of truth for the
   runtime file, the types, the reference and the change reports.
   Non-goals: replacing or emulating the Blizzard API, flattening flavours,
   hiding protected or taint behaviour, ergonomic helpers in the initial
   release, wrappers for undocumented FrameXML functions.
3. Dependencies: registry API 2. No other Kit; flavour detection is a few
   host reads inside the facade. Development-time only: the Python tooling
   under `tooling/api/` and the pinned StyLua for generated Lua.
4. Surface: `ApiKit:GetFlavor()` → `"retail" | "classic-era" |
   "classic-mop" | "ptr" | "beta" | "unsupported"`; `ApiKit:GetGlobalStatus()`
   → `"published" | "taken"`, read live; `ApiKit:RegisterFlavor(flavour,
   install, info?)` (the entry point the generated flavour files call; the
   installer runs once, only when `flavour` is the running one, otherwise
   only the small `info` table is retained); `ApiKit:GetMetadataBuild(flavour)`
   → the client version and build the registered metadata was captured from,
   so an addon can compare them with `GetBuildInfo()`; the namespace root
   `MoltenCodes.wow` with `retail`,
   `classic.era`, `classic.mop`, `ptr`, `beta` each holding an `api` table
   (populated for the running flavour, empty for the others); the `wow` global
   under the publication rule; per flavour `api.<namespace>.<function>`,
   `api.events.<name>` string constants and `api.enums.<name>` aliases.
   `API`, `REVISION`, `SUPPORTED_FLAVORS` (a read-only view, walked by index
   up to `SUPPORTED_FLAVOR_COUNT`) on the facade. No `SetLimits`: the package holds no growing state, and its docs
   say so.
5. Ownership: the facade is bootstrapped through Registry and upgraded in
   place; a flavour installer runs once per session, at file load, writing
   into package state that Registry hands to a newer compatible revision; an
   addon owns nothing and closes nothing. The `wow` global is written once,
   only when `nil`, and is never reclaimed or overwritten.
6. Performance: the normal call path is one table index over a raw call;
   bindings are direct aliases, never forwarding functions; no closures,
   temporary tables, string work, reflection or retained tooling metadata at
   runtime. Load cost is one pass over the running flavour's bindings; a
   file for another flavour costs its parse and one registration call, and
   the facade drops its installer. Parse time and retained memory per
   flavour file are measured and recorded before the first release (the
   brief's performance review).
7. Tests: Python tests for the Lua-literal parser, normalisation, every naming
   rule, initialism and exception, aliases, flavour partitioning, version
   comparison and history, each generator, the validator, and byte-identical
   output on a second run, over project-written fixtures in the documentation
   format; Busted specs for bootstrap and upgrade, flavour detection on stubbed
   hosts including PTR and Beta probes and an unsupported client, the `wow`
   rule in both states, `RegisterFlavor` for the running and for another
   flavour, alias resolution preserving multiple returns and `nil`, no
   argument transformation, absent host functions absent from the wrapper,
   error levels, manifest; a sampled spec per committed flavour that loads the
   generated file against a metadata-built stub host; a regression test for
   every generation or mapping defect.
8. Docs: README (what it is, the three access paths, the `.luarc.json` entry
   for types, footprint); `docs/API.md` (the facade contract, the wrapper
   function exceptions, the raw escape hatch); `docs/NAMING.md` (rules,
   initialisms, exceptions, aliases); `docs/UPDATING.md` (new-build
   procedure); `tooling/api/SCHEMA.md`; generated reference and change reports;
   CHANGELOG naming the captured build per flavour; EMBEDDING.md gains the
   second-global rule, the footprint row and the load-order entries;
   ARCHITECTURE.md and `docs/README.md` list the package; the design document
   stays current.
9. Status: implemented (package H, 0.1.0, 2026-09-24) with all five flavours
   captured. What shipped beyond this record is documented in
   `packages/apiKit/docs/API.md`: the `info` argument of `RegisterFlavor`,
   `SUPPORTED_FLAVOR_COUNT`, `GetGlobalStatus` read live, and the build facts
   consulted for Retail's project id alone so Classic test realms run their
   Classic flavour's surface. The reference is a release asset rather than a
   committed file (design document, section 13).

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
- [ ] Deferred to the user-interface phase: **timerKit** engine-driven
      pausable ticker (W15, needs an animation host; built in package M on
      `C_Timer` handles instead, see "timerKit pausable timers"), **frameKit** (W14,
      folded into widgetKit's anchors), Registry deprecation warnings (W13).

#### Package J — brokerKit

**brokerKit** — facade `BrokerKit`

1. Package `brokerKit`, facade `BrokerKit`, API generation 1.
2. Purpose: data objects for display addons, compatible with the
   LibDataBroker-1.1 contract every display addon already consumes (Titan,
   Bazooka, ChocolateBar): typed data objects with `text`, `label`, `icon`,
   `value`, `suffix` and the callbacks `OnClick`, `OnEnter`, `OnLeave`,
   `OnTooltipShow`; attribute-change notification per object and per
   attribute through SignalKit; enumeration; and a bridge that publishes
   MoltenCodes objects into a foreign LibDataBroker when one is loaded and
   adopts foreign objects read-only, so an addon written against BrokerKit is
   seen by every display addon and sees theirs. Non-goals: rendering a
   display, the minimap launcher (UI phase), persisting anything.
3. Dependencies: registry API 2, signalKit API 1; interopKit API 1 optional
   through `Registry:Find` (finding LibStub's LibDataBroker).
4. Surface: `BrokerKit:New(name, definition)` → object; `BrokerKit:Get(name)`;
   `BrokerKit:Objects()` sorted; `object:Set(attribute, value)` /
   `object:Get(attribute)`; `object:OnChange(attribute?, callback)`;
   `BrokerKit:OnObjectAdded(callback)`; `BrokerKit:ExposeToLibDataBroker()` /
   `AdoptFromLibDataBroker()`; `SetLimits{ maxObjects, maxAttributes }`.
5. Ownership: objects live for the session (a display addon keeps
   references); attributes are plain fields for LibDataBroker readers and
   change through `Set` for notification; foreign objects are read-only.
6. Performance: `Set` is one comparison and one signal fire when the value
   changed; reads are field reads; no allocation per update.
7. Tests: attribute change signals, per-attribute subscriptions, callbacks
   invoked with the object, enumeration order, the bridge both ways with a
   fake LibDataBroker, limits, upgrade, manifest, error levels.
8. Docs: README, API.md (the LibDataBroker mapping field by field), CHANGELOG;
   EMBEDDING footprint and host-requirements rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 126 specs.

#### Package K — logKit

**logKit** — facade `LogKit`

1. Package `logKit`, facade `LogKit`, API generation 1.
2. Purpose: levelled, structured logging for addons and Kits with lazy
   formatting (arguments are formatted only when a sink is listening at that
   level), per-addon loggers with a tri-state override (addon, global,
   default), a bounded in-memory journal readable after the fact (built on
   SignalKit's journal), and sinks: chat frame, the journal, a callback; the
   sink contract ProfileKit reports can share. Non-goals: log files (the
   client has none), remote shipping, a viewer window (UI phase).
3. Dependencies: registry API 2, signalKit API 1; commandKit API 1 optional
   (`/log <addon> <level>`), settingsKit API 1 optional (persisting the
   per-addon level).
4. Surface: `LogKit:ForAddon(addonName)` → logger with `Trace`, `Debug`,
   `Info`, `Warn`, `Error`, each `(message, ...)` formatted lazily, and
   `logger:SetLevel(level)`, `logger:GetLevel()`, `logger:IsEnabled(level)`;
   `LogKit:SetGlobalLevel(level|nil)`; `LogKit:AddSink(sink)` /
   `RemoveSink`; `LogKit:History(addonName?)` → iterator over the journal;
   `SetLimits{ journalCapacity, maxSinks, maxMessageLength }`.
5. Ownership: loggers are per addon and live for the session; sinks are
   removed by their handle; the journal is a ring.
6. Performance: a disabled level costs one comparison; formatting happens
   once per enabled message; secret values are never formatted.
7. Tests: level gating, lazy formatting (the formatter is not called when
   disabled), override precedence, journal ring order, sinks and their
   removal, secret-safe formatting, limits, upgrade, manifest, error levels.
8. Docs: README, API.md, CHANGELOG; EMBEDDING rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 144 specs; deviations
   recorded in `packages/logKit/docs/API.md`.

#### Package L — compatKit

**compatKit** — facade `CompatKit`

1. Package `compatKit`, facade `CompatKit`, API generation 1.
2. Purpose (W17): named, independently versioned shims with a host opt-out
   table (TaintLess's model: the newest version of a shim wins across
   embedded copies, a shim can be skipped by name); a provider registry with
   liveness probes and a deterministic fallback cascade that output-routing
   consumers share (LibSink's model); and a documented catalogue of
   taint-hostile Blizzard subsystems with their sanctioned replacements. The
   apiKit metadata is used to state, per flavour, which documented function
   a shim covers and where it moved, so the catalogue is data, not memory.
   Non-goals: flavour detection (clientKit), rewriting Blizzard behaviour,
   the wrapper itself (apiKit).
3. Dependencies: registry API 2; clientKit API 1 optional (flavour facts),
   apiKit API 1 optional (presence checks).
4. Surface: `CompatKit:Shim(name, version, implementation)`,
   `CompatKit:SkipShim(name)`, `CompatKit:GetShims()`, `CompatKit:Apply()`;
   `CompatKit:Providers(kind)` → registry with `Register(name, implementation,
   probe, priority)`, `Resolve(preferred?)`, `List()`; `SetLimits{ maxShims,
   maxProviders }`.
5. Ownership: shims are process-wide and applied once; providers are
   memoised per kind and re-validated by their probe.
6. Performance: load-time apart from `Resolve`.
7. Tests: shim version convergence across two embedded copies, skip honoured,
   apply idempotent, cascade order, a dead preferred provider falls through,
   limits, upgrade, manifest, error levels.
8. Docs: README, API.md, CHANGELOG; the catalogue in EMBEDDING's taint
   section; EMBEDDING rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 114 specs; deviations
   recorded in `packages/compatKit/docs/API.md`.

#### Package M — the user-interface phase (last, by the owner's decision)

Decided 2026-11-15 with the project owner, after bridgeKit (package N):
Blizzard's own frameworks are wrapped, not rebuilt, where every promised
client ships them (the Settings API and `MenuUtil`); every item below is
needed; each Kit gets its nine points here, agreed with the owner, before
its code. Order:

- [ ] **panelKit** — an OptionsKit tree in Blizzard's settings panel (below).
- [ ] **menuKit** — a thin, bounded wrapper over Blizzard's Menu API
      (`MenuUtil`).
- [ ] **launcherKit** — the minimap launcher for brokerKit, with an
      AddonCompartment entry on Retail.
- [ ] **tooltipKit** — multi-column tooltips pooled through PoolKit.
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
- [ ] **barKit** (status and timer bars), **dialogKit**, **toastKit**,
      **bindingKit**, **glowKit** and **editModeKit** (Edit Mode
      integration): implemented, client suites not run; timerKit's
      engine-driven ticker (W15).

**panelKit** — facade `PanelKit`

1. Package `panelKit`, facade `PanelKit`, API generation 1.
2. Purpose: put an addon's OptionsKit tree in Blizzard's settings panel
   (the AddOns tab), as a category or a subcategory of one, drawn by
   WidgetKit's renderer only while the page is shown — Ace3's
   `AceConfigDialog:AddToBlizOptions`. It wraps `Settings.RegisterCanvasLayoutCategory`,
   `Settings.RegisterCanvasLayoutSubcategory`, `Settings.RegisterAddOnCategory`
   and `Settings.OpenToCategory`, which Retail, Mists of Pandaria Classic and
   Classic Era ship with the same code (Blizzard's `Blizzard_Settings_Shared`,
   branches `live`, `classic` and `classic_era`, read 2026-11-15).
   Non-goals: building widgets or laying them out (WidgetKit), the option
   model (OptionsKit), Blizzard's own vertical-layout controls, a standalone
   window, the old `InterfaceOptions_AddCategory` API (no promised client
   lacks `Settings`).
3. Dependencies: registry API 2, widgetKit API 1 and optionsKit API 1, all
   required (panelKit has nothing to draw without them). Host requirement:
   the client's `Settings` table.
4. Surface: `PanelKit:Register(treeName, options?)` → panel, with
   `options.name` (the title in the list; default the tree's name) and
   `options.parent` (a panel, for a subcategory); `panel:Open()` → `true`,
   or `nil` and a reason; `panel:GetCategoryID()`; `panel:GetRendering()`
   (`nil` while hidden); `panel:SetDefaultHandler(callback|nil)`, run by the
   panel's Defaults button; `PanelKit:Get(name, parent?)`;
   `SetLimits{ maxPanels }` / `GetLimits()`. (A sorted `Panels()` was
   dropped while building: names are unique per level, so `Get` with the
   parent finds every panel, and nothing needed the list.)
5. Ownership: Blizzard cannot unregister a category, so a panel lives for
   the session, with one plain frame created at `Register`. The tree is
   found by name with `OptionsKit:Get` each time the page is shown, so
   redefining it is picked up and an undefined tree shows one line saying
   so. On show a WidgetKit `ScrollFrame` is acquired and the tree rendered
   into it; on hide both go back to their pools. Blizzard's `OnRefresh`
   refreshes the rendering, `OnDefault` runs the default handler (nothing
   without one), and `OnCommit` has nothing to do: OptionsKit writes at
   once. The frame's scripts call through the facade, so an upgraded
   revision runs its own code.
6. Performance and memory: no widget exists while a page is hidden;
   `Register` costs one frame and one category; showing a page costs one
   render. `maxPanels` defaults to 64; it has a ceiling (1024) and no
   `UNBOUNDED`, because neither frames nor categories are ever freed.
7. Tests: a stand-in `Settings` that records categories and fires
   `OnShow`, `OnHide`, `OnRefresh` and `OnDefault`; top-level and
   subcategory registration, name and parent validation, duplicate names
   refused, the limit and its ceiling, render on show and every widget back
   in its pool on hide, refresh, an undefined and a redefined tree, a
   raising default handler reported and not raised, `Open` and its reasons,
   secret names refused, upgrade, manifest, error levels. A client suite on
   Retail: register, open by category ID (a subcategory included), show and
   hide with the pools balanced, and what `Open` does in combat
   (`C_SettingsUtil.OpenSettingsPanel` is flagged `HasRestrictions`, which
   Blizzard does not document).
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING footprint and
   host-requirements rows; ARCHITECTURE's package list; the
   `AddToBlizOptions` recipe in `MIGRATING_FROM_ACE3.md`.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   48 specs; the client suite (`tests/client/MoltenCodesTest_PanelKit`) is
   written and has not been run in a client. Ticked once it has.

**menuKit** — facade `MenuKit`

1. Package `menuKit`, facade `MenuKit`, API generation 1.
2. Purpose: menus an addon describes as plain, checked tables, shown by
   Blizzard's Menu API (`Blizzard_Menu`, 11.0, which replaces the deprecated
   UIDropDownMenu): a context menu at the cursor, the menu of a dropdown
   button, and entries an addon adds to Blizzard's own tagged menus (the
   unit right-click menus, `MENU_UNIT_<TYPE>`) and removes again. Retail,
   Mists of Pandaria Classic and Classic Era ship `Blizzard_Menu` with the
   same `Menu.lua` and `MenuUtil.lua` (branches `live`, `classic` and
   `classic_era`, read 2026-11-15), except `MenuUtil.CreateHighlightButton`,
   which only Retail has and menuKit does not use. What menuKit adds over
   calling `MenuUtil` directly: entries checked at the caller's line (kind,
   text, callbacks, a secret refused), bounded size and depth, callbacks run
   so that one that raises is reported and never breaks Blizzard's menu, and
   menu extensions an addon can remove (Blizzard's `Menu.ModifyMenu` handle).
   Non-goals: drawing a menu (Blizzard does), UIDropDownMenu, WidgetKit's own
   `Dropdown` widget, grid and scroll modes, custom element templates.
3. Dependencies: registry API 2 only. Host requirement: `MenuUtil` and
   `Menu` (`Blizzard_Menu`); without them every call raises at the caller.
4. Surface: an entry is a table `{ kind, text, ... }` with `kind` one of
   `"button"`, `"checkbox"`, `"radio"`, `"title"`, `"divider"`, `"spacer"`;
   a button takes `onClick(data)`, a checkbox or radio `isSelected(data)`
   and `setSelected(data)`, any of them `data`, `disabled` (a boolean or a
   function), `tooltip` (a string), and `entries` for a submenu. A menu is
   an array of entries, or a function returning one, called each time the
   menu opens. `MenuKit:OpenContextMenu(owner, menu)`;
   `MenuKit:SetupDropdown(dropdownButton, menu)`;
   `MenuKit:ExtendMenu(tag, menu)` → extension with `Remove()`;
   `MenuKit:CloseMenus()`; `SetLimits{ maxEntries, maxDepth,
   maxExtensions }` / `GetLimits()`.
5. Ownership: menuKit keeps nothing for a context menu or a dropdown once
   the description is handed to Blizzard; Blizzard owns the open menu. An
   extension is kept until `Remove()`, bounded by `maxExtensions`.
6. Performance and memory: a menu is translated when it opens, never
   before, so a closed menu costs only its table; nothing is cached between
   openings. Defaults: 256 entries per menu, depth 4, 64 extensions; the
   first two open to `UNBOUNDED`, the last to a ceiling (each extension is a
   Blizzard callback registration).
7. Tests: a stand-in `MenuUtil` and `Menu` that records the description
   built (kinds, texts, callbacks, submenus, tooltips, enabled state) and
   clicks it; every entry kind and its checks, dynamic menus, nested
   submenus at the depth limit, limits and `UNBOUNDED`, a raising callback
   reported and not raised, extensions added and removed, secret texts
   refused, upgrade, manifest, error levels. A client suite on Retail: a
   context menu and a dropdown opened and closed again, a unit menu
   extension added and removed (verified by its tag being reached), and
   each callback run on the client.
8. Docs: README, API.md (the entry table field by field, and how each maps
   to `MenuUtil`), CHANGELOG, tests/README; EMBEDDING footprint and
   host-requirements rows; ARCHITECTURE's package list; EMBEDDING's user
   interface section. (The Ace3 migration guide gets no section: Ace3 has no
   menu library.)
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   45 specs; the client suite (`tests/client/MoltenCodesTest_MenuKit`) is
   written and has not been run in a client. Ticked once it has.

**launcherKit** — facade `LauncherKit` (the minimap launcher)

1. Package `launcherKit`, facade `LauncherKit`, API generation 1.
2. Purpose: a minimap button for a BrokerKit object, what LibDBIcon-1.0
   gives every addon with a LibDataBroker launcher: the object's icon on the
   edge of the minimap, dragged around it (a round minimap, or the shape
   `GetMinimapShape` reports when an addon makes it square), its `OnClick`
   on a click, its `OnTooltipShow` in `GameTooltip` on hover, its icon
   following the object's `icon` attribute. Position, hidden and locked
   state live in a table the addon gives (a SettingsKit view or any table),
   in LibDBIcon's field names (`minimapPos`, `hide`, `lock`), so a saved
   LibDBIcon table keeps working. On Retail the same object can also be put
   in Blizzard's AddonCompartment (the addons drop-down by the minimap,
   `AddonCompartmentFrame:RegisterAddon`), which exists only there (checked
   in Blizzard's source on `live`, `classic` and `classic_era`, 2026-11-15)
   and has no way to remove an entry. Non-goals: adopting or driving other
   addons' LibDBIcon buttons, a broker display bar, changing the minimap.
3. Dependencies: registry API 2 and brokerKit API 1, both required (a
   launcher shows a BrokerKit object); SignalKit comes with BrokerKit. Host
   requirement: `Minimap`, `CreateFrame`, `GameTooltip`.
4. Surface: `LauncherKit:Register(objectName, storage)` → launcher (the
   `options` argument was dropped while building: nothing needed one); `launcher:Show()`, `Hide()`, `IsShown()`, `Lock()`,
   `Unlock()`, `IsLocked()`, `Refresh()` (read the storage again, after a
   profile switch), `GetButton()` (its icon texture is `button.icon`); `LauncherKit:Get(objectName)`;
   `LauncherKit:AddToCompartment(objectName)` → `true`, or `nil` and
   `"unavailable"` (no AddonCompartment) or `"already"`;
   `SetLimits{ maxLaunchers }` / `GetLimits()`.
5. Ownership: one button frame per launcher, created at `Register` and kept
   for the session, because the client never frees a frame; a launcher
   follows its object until logout. The storage stays the addon's:
   LauncherKit writes only the three fields, and only on a drag, `Show`,
   `Hide`, `Lock` or `Unlock`. A compartment entry is the client's until
   logout.
6. Performance and memory: nothing runs per frame except while a button is
   dragged; an icon change is one BrokerKit signal. `maxLaunchers` defaults
   to 64 with a ceiling of 256 and no `UNBOUNDED` (each is a frame for the
   session).
7. Tests: stand-ins for `Minimap`, `GameTooltip`, the cursor and
   `AddonCompartmentFrame`; placement at an angle on a round minimap and on
   every `GetMinimapShape` shape, dragging that saves `minimapPos`, a
   locked button that does not move, `hide` honoured at `Register` and
   written by `Show`/`Hide`, `Refresh` after the storage changed, clicks and
   tooltips through the object's callbacks with one that raises reported,
   the icon following the object, a LibDBIcon-shaped table read as it is,
   the compartment `"unavailable"` and `"already"`, limits and the ceiling,
   secret values, upgrade, manifest, error levels. A client suite on Retail:
   a button on the real minimap, shown, hidden and moved, its tooltip filled
   and hidden again, and a compartment entry.
8. Docs: README (with the migration from LibDBIcon), API.md, CHANGELOG,
   tests/README; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   39 specs; the client suite (`tests/client/MoltenCodesTest_LauncherKit`)
   is written and has not been run in a client. Ticked once it has.

**tooltipKit** — facade `TooltipKit`

1. Package `tooltipKit`, facade `TooltipKit`, API generation 1.
2. Purpose: tooltips laid out in columns, what LibQTip-1.0 gives addons
   that show a table on hover (a guild or friends list on a broker
   display, a currency or cooldown summary): a tooltip with a fixed number
   of columns, each with its own justification, lines added as rows of
   cells, a header and a separator, a cell spanning several columns, a
   colour per line or cell, a click or hover callback per line, a height
   limit past which the tooltip scrolls with the mouse wheel, smart
   anchoring to the frame that opened it (the side with room on screen),
   and an auto-hide delay once the cursor has left both. Each tooltip is
   keyed by its owner's name, so a second `Acquire` with the same key
   returns the open one. Tooltips, lines and cells come from PoolKit pools,
   because the client never frees a frame or a font string. Non-goals:
   changing `GameTooltip` (an addon keeps using it for one-column text),
   icons or custom widgets inside cells (later, if an addon needs them),
   sorting or filtering the rows.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent` and the client's font objects
   (the auto-hide check asks each frame's `IsMouseOver`, so
   `GetCursorPosition` turned out not to be needed).
4. Surface: `TooltipKit:Acquire(key, columns, ...justify)` → tooltip (an
   open tooltip under `key` is returned as it is); `TooltipKit:Release(
   tooltip)`; `TooltipKit:IsAcquired(key)`; on a tooltip: `AddHeader(...)`
   and `AddLine(...)` → line index, `AddSeparator(height?, r, g, b, a)`,
   `SetCell(line, column, text, options?)` (`span`, `justify`, `font`,
   `allowSecret`), `SetLineColor` (the line's background) and
   `SetCellTextColor` (a cell's text; it replaced the planned
   `SetCellColor`, because lists colour names, not boxes), `SetLineScript(line,
   script, handler, arg)` for `OnMouseUp`, `OnEnter`, `OnLeave`, `Clear()`,
   `SetMaxHeight(pixels|nil)`, `SmartAnchorTo(frame)`,
   `SetAutoHideDelay(seconds|nil, alternateFrame?)`, `Show()`, `Hide()`,
   `IsShown()`, `GetLineCount()`, `GetColumnCount()`, `GetFrame()`; `SetLimits{ maxTooltips, maxLines, maxColumns }` /
   `GetLimits()`.
5. Ownership: a tooltip is borrowed from the moment `Acquire` returns it
   until `Release` (or its auto-hide, which releases it); a released
   tooltip and every line and cell go back to their pools, cleared, so no
   text, colour or script survives into the next use. A tooltip whose
   owner key is released while hidden is gone; `IsAcquired` says so.
6. Performance and memory: layout runs once per change batch, when the
   tooltip is shown or a line is added while it is shown, never per frame;
   only an auto-hiding tooltip runs code per frame (one cursor check), and
   only while shown. Defaults: 16 tooltips acquired at once, 256 lines per
   tooltip, 16 columns; lines and columns have ceilings (1024, 32) and no
   `UNBOUNDED`, because every line and cell is a region the session keeps;
   `maxTooltips` has a ceiling of 64.
7. Tests: a stand-in for the client's frames and font metrics through the
   shared frame stub; acquire by key and reuse, release and reuse with
   nothing left behind, columns and justification, headers, separators,
   spans, colours, line scripts and one that raises reported, the height
   limit and wheel scrolling, smart anchoring on each side of the screen,
   auto-hide timing and the alternate frame, limits and ceilings, secret
   texts refused without `allowSecret` and drawn with it, upgrade,
   manifest, error levels. A client suite on Retail: a tooltip with a
   header, three columns and a span drawn and measured with the client's
   fonts, scrolled, anchored and auto-hidden, and released with every pool
   back to its count.
8. Docs: README (with the migration from LibQTip-1.0), API.md, CHANGELOG,
   tests/README; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 after the owner's go, 0.1.0, revision 1,
   43 specs; the client suite (`tests/client/MoltenCodesTest_TooltipKit`)
   is written and has not been run in a client. Ticked once it has.

**barKit** — facade `BarKit`

1. Package `barKit`, facade `BarKit`, API generation 1.
2. Purpose: status and timer bars, what LibCandyBar-3.0 gives boss-timer
   and cooldown addons and what unit-frame addons build by hand: a bar with
   a label, an icon, a value text and a colour, either showing a value
   between a minimum and a maximum (health, a resource, a cast) or counting
   a duration down with the remaining time drawn as `1:23` or `9.4`,
   pausable, with a callback when it runs out. Built on the client's
   `StatusBar`, which takes a Retail 12.x secret value (health, power) as it
   is, so a bar can show what an addon may not read. Bars come from a
   PoolKit pool, because the client never frees a frame. Non-goals: laying
   bars out in groups (an addon anchors them; WidgetKit's layouts exist),
   unit-frame logic, reading unit data.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent`, `GetTime`.
4. Surface: `BarKit:Acquire(options?)` → bar (`width`, `height`,
   `texture`, `parent`); `BarKit:Release(bar)`; on a bar `SetLabel(text,
   options?)`, `SetValueText(text, options?)` (`allowSecret` for both),
   `SetIcon(texture|nil)`, `SetColor(r, g, b, a?)`, `SetBackgroundColor`,
   `SetMinMax(min, max)` and `SetValue(value)` (secrets passed through),
   `Start(duration, options?)` (`onFinished`, `fill` to fill instead of
   drain, `releaseOnFinish`), `Pause()`, `Resume()`, `Stop()`,
   `IsRunning()`, `IsPaused()`, `GetRemaining()`, `GetFrame()`;
   `SetLimits{ maxBars }` / `GetLimits()`.
5. Ownership: a bar is borrowed from `Acquire` until `Release` (or the end
   of a timer started with `releaseOnFinish`); a released bar is cleared of
   every text, icon, colour, value, timer and callback.
6. Performance and memory: a status bar runs nothing per frame; a running
   timer bar runs one `OnUpdate` that sets the fill every frame and the
   time text only when the shown text changes; a paused or stopped one runs
   nothing. `maxBars` (bars acquired at once) defaults to 64 with a ceiling
   of 512 and no `UNBOUNDED`.
7. Tests: a stand-in clock; status values and ranges, secret values passed
   to the bar untouched, labels and value texts with and without
   `allowSecret`, icon, colours; a timer draining and filling, its text
   formats, pause and resume keeping the remaining time, stop, the finished
   callback (one that raises reported), `releaseOnFinish`; pooling and
   reuse cleared; limits and the ceiling; upgrade; manifest; error levels.
   A client suite on Retail: a bar with a secret health value from the
   client, and a timer bar run to its end.
8. Docs: README (with the migration from LibCandyBar-3.0), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 29 specs; the client suite (`tests/client/MoltenCodesTest_BarKit`) is
   written and has not been run in a client.

**dialogKit** — facade `DialogKit`

1. Package `dialogKit`, facade `DialogKit`, API generation 1.
2. Purpose: confirmation and input dialogs without `StaticPopupDialogs`.
   An addon that adds entries to Blizzard's `StaticPopupDialogs` table and
   calls `StaticPopup_Show` runs its code inside Blizzard's popup system and
   can taint it; DialogKit draws its own dialog on one frame of its own, with
   the client's button and input-box templates: a text, one or two buttons,
   an optional input line, an optional timeout. One dialog is shown at a
   time; the others wait in a bounded queue. Escape closes it through
   `UISpecialFrames`, the client's list of frames Escape hides, which every
   promised client has (checked in Blizzard's source, branches `live`,
   `classic`, `classic_era`, 2026-11-15). Non-goals: changing Blizzard's
   own popups, arbitrary widgets in a dialog (WidgetKit), several dialogs
   on screen at once.
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `UIParent`, `GetTime` (timeouts); `UISpecialFrames` (Escape) when present.
4. Surface: `DialogKit:Show(options)` → dialog, with `text`,
   `accept` (default `"OK"`), `cancel` (default `"Cancel"`, `false` for one
   button), `onAccept(data, inputText)`, `onCancel(data, reason)`, `data`,
   `input` and `inputText`, `maxLetters`, `timeout`, `key` (a dialog shown or
   waiting under the same key is returned instead of a second one),
   `allowSecret`; `dialog:Hide()`, `IsShown()`, `IsQueued()`, `GetInput()`;
   `DialogKit:HideAll()`; `SetLimits{ maxQueued }` / `GetLimits()`.
5. Ownership: a dialog lives from `Show` until it is accepted, cancelled
   (its button, Escape, the timeout, `Hide`, `HideAll`) or, while waiting,
   removed; the callback that ends it runs once, protected. The frame is the
   package's, created once and kept for the session.
6. Performance and memory: one frame for every dialog; nothing runs per
   frame except a shown dialog with a timeout. `maxQueued` defaults to 16
   and opens to `UNBOUNDED` (a waiting dialog is a Lua table).
7. Tests: the frame's texts, buttons and input line; accept, cancel, Escape
   (hiding the frame), timeout, `Hide` and `HideAll` each calling the right
   callback once with its reason; the queue's order, its limit and
   `UNBOUNDED`; keys; Enter and Escape in the input line; callbacks that
   raise reported; secret texts; upgrade; manifest; error levels. A client
   suite on Retail: a dialog shown and accepted, one closed with Escape
   through `UISpecialFrames`, and a queued one shown after it.
8. Docs: README (with the migration from `StaticPopup_Show`), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 26 specs; the client suite (`tests/client/MoltenCodesTest_DialogKit`)
   is written and has not been run in a client.

**toastKit** — facade `ToastKit`

1. Package `toastKit`, facade `ToastKit`, API generation 1.
2. Purpose: short notifications that appear, stay a few seconds and fade:
   "profile copied", "a new version is out", a loot or achievement-style
   note from an addon. A toast has a title, an optional text and icon, and
   an optional click handler; toasts stack at one anchor on the screen,
   growing down or up, at most a few at a time, the rest waiting in a
   bounded queue. The cursor resting on a toast holds it. Toasts are frames
   of the package's own, from a PoolKit pool. Non-goals: Blizzard's alert
   system (`AlertFrame`, whose queue and taint rules belong to Blizzard),
   chat messages, sounds.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent`; `GetTime` is not needed (a
   toast counts its own `OnUpdate` time).
4. Surface: `ToastKit:Show(options)` → toast, with `title`, `text`,
   `icon`, `duration` (default 5 seconds), `onClick(data)`, `data`, `key`
   (a toast shown or waiting under the same key is updated and starts
   again), `allowSecret`; `toast:Dismiss()`, `IsShown()`, `IsQueued()`;
   `ToastKit:DismissAll()`; `ToastKit:SetAnchor(point, x, y, direction)`;
   `SetLimits{ maxVisible, maxQueued }` / `GetLimits()`.
5. Ownership: a toast lives from `Show` until it fades out, is clicked or
   dismissed; its frame then goes back to the pool cleared.
6. Performance and memory: each shown toast runs one `OnUpdate` that
   counts its time and, in its last half second, its fade; nothing runs
   once it is gone. `maxVisible` defaults to 5 with a ceiling of 20 (the
   frames are kept for the session); `maxQueued` defaults to 32 and opens
   to `UNBOUNDED` (a waiting toast is a Lua table).
7. Tests: texts, icon, anchor and stacking both ways, the life and the
   fade, holding under the cursor, clicks (one that raises reported),
   `Dismiss`, `DismissAll`, keys updating and restarting, the queue and its
   limit, pooling, secret texts, upgrade, manifest, error levels. A client
   suite on Retail: toasts shown, stacked, faded on the client's frames and
   their frames reused.
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 23 specs; the client suite (`tests/client/MoltenCodesTest_ToastKit`) is
   written and has not been run in a client.

**bindingKit** — facade `BindingKit`

1. Package `bindingKit`, facade `BindingKit`, API generation 1.
2. Purpose: key bindings an addon sets at run time without touching the
   player's own: override bindings (`SetOverrideBinding`,
   `SetOverrideBindingClick`), which the client drops at logout and never
   saves, owned by a named scope so an addon clears only its own. A key can
   run a binding command (`"TOGGLEWORLDMAP"`), click a named button, or call
   a Lua function through a hidden named button of the package's own. The
   client refuses binding changes from addon code in combat, so a change made
   then is kept and applied when combat ends (`PLAYER_REGEN_ENABLED`); a
   scope says whether it waits. Non-goals: the player's saved bindings
   (`SetBinding`, `SaveBindings`), the Key Bindings panel, secure action
   buttons (a function key runs insecure code and cannot cast).
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `SetOverrideBinding`, `SetOverrideBindingClick`,
   `ClearOverrideBindings`, `InCombatLockdown`; without the binding
   functions `CreateScope` raises at the caller.
4. Surface: `BindingKit:CreateScope(name, options?)` → scope (the scope of
   that name when it exists; `priority` makes its bindings win over other
   override bindings); `scope:BindCommand(key, command)`,
   `scope:BindClick(key, buttonName, mouseButton?)`,
   `scope:BindFunction(key, func)`, `scope:Unbind(key)`, `scope:ClearAll()`,
   `scope:GetBinding(key)`, `scope:IsPending()`, `scope:GetName()`;
   `BindingKit:GetScope(name)`; `SetLimits{ maxScopes, maxFunctionKeys }` /
   `GetLimits()`.
5. Ownership: a scope lives for the session with one owner frame; its
   bindings are the client's until logout or until the scope clears them.
   A function key's hidden button goes back to a free list when the key is
   unbound, so buttons are reused.
6. Performance and memory: a change rebuilds the scope's override bindings
   (clear, then set each), never per frame; one event frame listens for the
   end of combat only while a scope waits. `maxScopes` defaults to 32
   (ceiling 256) and `maxFunctionKeys` to 64 (ceiling 512): both count
   frames the session keeps, so neither opens to `UNBOUNDED`.
7. Tests: stand-ins for the override binding functions and combat; each
   kind of binding set on the scope's owner with its priority, unbinding
   and clearing, a function key calling its function (one that raises
   reported) and its button reused, changes in combat kept and applied at
   the end of combat, scopes by name, limits and ceilings, secret values,
   upgrade, manifest, error levels. A client suite on Retail: a function key
   set, pressed through the button it binds, and cleared.
8. Docs: README, API.md, CHANGELOG, tests/README; EMBEDDING rows;
   ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 21 specs; the client suite (`tests/client/MoltenCodesTest_BindingKit`)
   is written and has not been run in a client.

**glowKit** — facade `GlowKit`

1. Package `glowKit`, facade `GlowKit`, API generation 1.
2. Purpose: glows that draw the eye to a frame (an action button, an aura
   icon, a unit frame), what LibCustomGlow-1.0 gives WeakAuras and
   action-bar addons. Two effects drawn with plain textures on an overlay
   frame of the package's own: `pixel`, short lines running round the
   frame's edge, and `pulse`, a border whose opacity breathes. Several glows
   can sit on one frame under different keys. Overlays come from a PoolKit
   pool. Non-goals: Blizzard's spell-activation overlay
   (`ActionButton_ShowOverlayGlow`, Blizzard code on Blizzard buttons),
   particle or model effects.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`.
4. Surface: `GlowKit:Start(frame, options?)` → glow, with `kind`
   (`"pixel"` by default, or `"pulse"`), `key` (default `"default"`; a glow
   already under that key on that frame is restarted with the new options),
   `color`, `lines`, `thickness`, `frequency`; `glow:Stop()`,
   `glow:IsActive()`; `GlowKit:Stop(frame, key?)`,
   `GlowKit:IsGlowing(frame, key?)`, `GlowKit:StopAll(frame)`;
   `SetLimits{ maxGlows }` / `GetLimits()`.
5. Ownership: a glow lives from `Start` until it is stopped; its overlay is
   then released to the pool cleared. A glow on a frame that is hidden stays
   and resumes when the frame shows.
6. Performance and memory: one `OnUpdate` per active glow, only while its
   frame is visible, setting a few texture points or one alpha; lines are
   textures on the overlay, made the first time a count needs them.
   `maxGlows` (active at once) defaults to 64 with a ceiling of 512 and no
   `UNBOUNDED`.
7. Tests: both effects drawn and moved with time, colours, line counts,
   thickness, keys side by side and restarting, stop paths, pooling and
   reuse cleared, a frame resized while glowing, limits, secret values,
   upgrade, manifest, error levels. A client suite on Retail: a glow on a
   frame on screen, animated by the client's frames, and stopped.
8. Docs: README (with the migration from LibCustomGlow-1.0), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 22 specs; the client suite (`tests/client/MoltenCodesTest_GlowKit`) is
   written and has not been run in a client.

**editModeKit** — facade `EditModeKit`

1. Package `editModeKit`, facade `EditModeKit`, API generation 1.
2. Purpose: an addon's frames take part in Blizzard's Edit Mode, what
   LibEditMode gives addons on Retail: while Edit Mode is open, each
   registered frame shows a labelled selection overlay that drags the frame,
   and its position is saved per Edit Mode layout and put back when the
   player switches layout. Edit Mode, its `EventRegistry` events
   (`EditMode.Enter`, `EditMode.Exit`), `C_EditMode` and the event
   `EDIT_MODE_LAYOUTS_UPDATED` exist on Retail, Mists of Pandaria Classic
   and Classic Era alike (Blizzard's `Blizzard_EditMode`, branches `live`,
   `classic` and `classic_era`, read 2026-11-15). Non-goals: Blizzard's
   own Edit Mode systems and settings dialog, snapping and grids, frame
   settings other than the position.
3. Dependencies: registry API 2 only. Host requirement: `CreateFrame`,
   `UIParent`, `EventRegistry`; `EditModeManagerFrame` for the active
   layout's name (`"default"` without it).
4. Surface: `EditModeKit:Register(frame, storage, options?)` → registration
   (`label` on the overlay); `registration:Unregister()`, `Refresh()`,
   `GetFrame()`; `EditModeKit:IsEditing()`, `EditModeKit:GetLayoutName()`;
   `SetLimits{ maxRegistrations }` / `GetLimits()`. The storage is a table,
   or a function returning one, holding `{ x, y }` per layout name: the
   frame's centre offset from `UIParent`'s centre.
5. Ownership: a registration lives until `Unregister`; its overlay goes
   back to a pool. A position change of a protected frame in combat waits
   for `PLAYER_REGEN_ENABLED`.
6. Performance and memory: nothing runs per frame; the work happens when
   Edit Mode opens or closes, a layout changes or a drag ends. One callback
   owner for the session. `maxRegistrations` defaults to 64 with a ceiling
   of 256 (each holds an overlay frame), no `UNBOUNDED`.
7. Tests: stand-ins for `EventRegistry`, `EditModeManagerFrame` and the
   layouts event; overlays shown and hidden with Edit Mode, dragging that
   saves the centre offset per layout, positions put back on a layout
   switch and on `Refresh`, a frame with no saved position left where it
   is, a storage function, protected frames in combat waiting, unregistering,
   limits, secret values, upgrade, manifest, error levels. A client suite on
   Retail: a frame registered, its overlay shown in Edit Mode, its position
   saved and restored.
8. Docs: README (with the migration from LibEditMode), API.md, CHANGELOG,
   tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 28 specs; the client suite (`tests/client/MoltenCodesTest_EditModeKit`)
   is written and has not been run in a client. Overlays given back by
   `Unregister` are kept on a free list of the state rather than a PoolKit
   pool, so the dependency stays registry only.

**timerKit pausable timers (W15)** — an addition to facade `TimerKit`

1. Package `timerKit`, facade `TimerKit`, API generation 1 (additive),
   version 0.8.0, implementation revision 12.
2. Purpose: pause a running timer and resume it later with what was left
   of its delay, what worklist item W15 asked of an "engine-driven
   pausable ticker". Recorded deviation: it is built on `C_Timer` handles,
   not on an animation host. `Pause` cancels the host handle and keeps the
   remainder; `Resume` asks the host for a fresh one-shot of that
   remainder, and a repeating timer returns to its interval after that
   first fire. TimerKit therefore stays registry only, with no frame and
   no per-frame work. Non-goals: frame-accurate ticks, per-frame updates
   (BarKit draws timer bars), pausing a whole scope.
3. Dependencies: unchanged, registry API 2. `GetTimePreciseSec` measures
   the remainder; without it a paused timer keeps its full delay.
4. Surface: `timer:Pause()` → `true`, or `false` unless it was running;
   `timer:Resume()` → `true`, or `false` unless it was paused, raising at
   the caller in a closed scope; `timer:IsPaused()`. `GetState` may answer
   the new state `"paused"`; `GetRemaining` answers the kept remainder
   while paused, `GetDeadline` `nil`, `IsPending` `false`. `Start` on a
   paused timer answers `false`; `Cancel`, `Restart`, `CancelAll` and
   `Close` treat a paused timer as running.
5. Ownership: a paused timer stays in its scope's active set, so
   `GetActiveCount` counts it and `CancelAll` and `Close` cancel it. Pausing
   unbinds the host callback first, so a stale callback never fires a paused
   timer.
6. Performance and memory: `Pause` is one host `Cancel`, `Resume` one host
   constructor and one closure. The remainder is kept in the timer's
   existing `_deadline` field, so pausing adds no field and never rehashes
   the timer. Nothing new on the start, cancel or fire paths of a timer
   that is never paused.
7. Tests: pause and resume of one-shot and repeating timers with exact
   remainders, a repeating timer back on its interval, a stale callback of
   the paused handle ignored, pause without a clock, the methods' `false`
   answers, cancel, restart, `CancelAll` and `Close` of a paused timer,
   resume in a closed scope, receiver errors at the caller, an upgrade from
   revision 11 keeping timers and a timer paused after it.
8. Docs: API.md (pausing, the state table, the methods), INTERNALS.md (the
   `_deadline` field while paused, the resume closure), CHANGELOG, README,
   tests/README; Package I's deferred item and package M's checklist.
9. Status: recorded 2026-11-15 under core decision 15; code follows.

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

**bridgeKit** — facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API generation 1.
2. Purpose: the three migration tools an Ace3 addon cannot write safely by
   hand. (a) An AceConfig-3.0 options table (or table function) converted into
   an OptionsKit tree for a documented subset, the addon's Ace
   `get`/`set`/`func`/`validate` handlers kept and called with an Ace-shaped
   `info`, inheritance resolved at conversion, and a per-field report of every
   field dropped, renamed or changed in meaning. (b) An AceDB-3.0 saved
   variable imported into the SettingsKit layout: profiles, profile choices,
   every AceDB scope (`char`, `realm`, `class`, `race`, `faction`,
   `factionrealm`, `factionrealmregion`, `locale`, `global`, `profile`) and
   namespaces, validated against the SettingsKit schema, with AceDB defaults
   that differ from SettingsKit's written as values so every field reads what
   it read before; copy-based (the source is never mutated), previewed, backed
   up. (c) A wire adapter that writes and reads AceComm-3.0's multipart format
   and AceSerializer-3.0's text format byte for byte, bounded where Ace3 is
   not, versioned, so an addon can move to CommKit and CodecKit while its peers
   still run the Ace3 version. Non-goals: running or embedding Ace3 code,
   emulating Ace3 method calls, rendering (WidgetKit, CommandKit), AceGUI and
   AceConfigDialog layouts and the Blizzard settings panel (the
   user-interface phase), keeping two databases in sync, ChatThrottleLib.
3. Dependencies: registry API 2, nothing else required. Optional through
   `Registry:Find`: optionsKit API 1 (`DefineAceConfig`), schemaKit API 1
   (the importer's probe checks), commKit API 1 in a revision with raw addon
   messages (`OpenAceComm`). The serializer
   and the plain AceConfig conversion embed two files. Two prerequisites in
   other Kits, not made in this step: CommKit gains `RegisterRaw` and
   `SendRaw` (P1), and SettingsKit's saved-table layout becomes a documented
   contract (P2, documentation only).
4. Surface: `BridgeKit:ConvertAceConfig(appName, source, options?)` →
   conversion `{ tree, report, paths, maxDepth, optionCount }`;
   `BridgeKit:DefineAceConfig(addonName, source, options?)` → tree, report;
   `BridgeKit:PreviewAceDB(source, plan)` → report;
   `BridgeKit:ImportAceDB(source, targetName, plan)` → report or `nil,
   reason`; `BridgeKit:AceDBMigration(plan)` → a SettingsKit migration step;
   `BridgeKit:AceSerialize(...)` → `true, text` or `false, reason`;
   `BridgeKit:AceDeserialize(text)` → `true, ...` or `false, reason`, never
   raising on malformed text; `BridgeKit:OpenAceComm(scope, prefix, callback,
   options?)` → channel (`Send`, `Close`, `IsClosed`, `GetPrefix`,
   `GetPriority`, `GetWireVersion`) or `nil, reason`;
   `BridgeKit:FormatReport(report, maxLines?)`; `GetStatistics()`;
   `SetLimits{ maxReportEntries, maxImportEntries, maxDepth, maxValues,
   maxStringLength, maxTextBytes, maxListValues, maxAceStreams,
   maxAceStreamsPerSender, maxAceStreamBytes, maxAceSpoolBytes,
   aceStreamTimeout, maxDropReportSenders }`, `GetLimits()`, `UNBOUNDED`,
   `ACE_WIRE_VERSION`, `ACE_BASELINE`, `API`, `REVISION`. Programming errors
   raise at the caller's line; data problems are report entries or returned
   reasons.
5. Ownership: conversions, reports and previews are plain tables the caller
   owns. The importer writes only the target global and the backup global the
   caller names, and refuses either when it already holds data. A wire channel
   lives in the CommKit scope the caller passes and closes with it; AceComm
   reassembly belongs to the prefix, shared by every channel on it, and is
   dropped when the last channel of the prefix closes. BridgeKit owns no
   per-addon scope and needs no logout close.
6. Performance: conversion and import are one-time walks that allocate by
   design; a wrapped Ace accessor adds one call and allocates nothing, except
   the `color` and `multiselect` getters (one table per `Get`, an options
   screen being no hot path); the serializer reuses its fragment array and
   allocates only its result and the values it decodes; a single-part AceComm
   message costs one table read beyond CommKit's raw delivery; reassembly
   holds at most `maxAceSpoolBytes` (1 MB) with no polling (streams expire at the
   next receive, design decision 20). Costs are measured and recorded before the first release,
   and the benchmark compares them with Ace3 fetched at run time, never
   redistributed.
7. Tests: Busted specs for every row of the design's field, scope, defaults
   and format tables, inheritance resolution, report vocabularies, `strict`,
   limits, secrets, error levels, upgrade and manifest; a source table
   snapshot equal before and after every import; hostile serializer input
   truncated at every byte never raising; AceSerializer and AceComm fixtures
   recorded from Ace3 over the project's own inputs, with provenance, and no
   Ace3 source or tests copied; a client suite proving wire compatibility
   with real Ace3 over whisper-to-self, what bytes the client's addon channel
   carries, the AceDB import across `/reload` in both modes, a converted tree
   rendered by WidgetKit and CommandKit, and the secret refusals.
8. Docs: README (the three parts, footprint per part, when to stop embedding
   it), `docs/API.md` (the contract, every reason with its Ace3 citation,
   costs, deviations), CHANGELOG; `docs/MIGRATING_FROM_ACE3.md` updated from
   planned to current API; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE, `docs/README.md` and `README.md` list the package; the design
   document kept current.
9. Status: delivered (2026-11-15). Design and migration guide written. The
   owner answered the design's five open questions on 2026-11-15, accepting
   every recommendation (design decisions 9 to 13). Delivery sequence N0
   (prerequisites P1, P2) to N5 in the design, section 15. N0 is done
   (2026-11-15): CommKit 0.5.0 carries raw addon messages and SettingsKit
   0.3.2 publishes its saved-table layout. N1 is done (2026-11-15):
   bridgeKit 0.1.0 writes and reads AceSerializer-3.0 text, held to output
   recorded from Ace3. N2 is done (2026-11-15): bridgeKit 0.2.0 converts
   AceConfig-3.0 tables to OptionsKit trees. N3 is done (2026-11-15):
   bridgeKit 0.3.0 imports AceDB-3.0 saved variables into the SettingsKit
   layout. N4 is done (2026-11-15): bridgeKit 0.4.0 speaks AceComm-3.0
   through CommKit's raw addon messages; streams expire lazily instead of on
   a TimerKit timer (design decision 20). N5 is done (2026-11-15): the
   real-client suites (written, not yet run in a client), the
   `aceSerializer` benchmark workload, the measured costs and the
   acceptance review, accepted after fixes; package N is closed.

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
accepted**, before or together with implementation. Each planned Kit should
record:

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
in the same change. Architecture decisions belong in the architecture/design
documents; this roadmap tracks sequencing and delivery status rather than
duplicating those specifications.

---

Last roadmap baseline update: 2026-11-15 (phases 0 through 4 and packages F,
G and H complete; phase 5 packages I, J, K and L complete; package N, bridgeKit,
delivered: steps N0 to N5 done, so 29 packages, 28 of them release
packages, every gate green; the user-interface phase (package M) follows
package N by the owner's decision; the standing obligations continue).
Previous baseline: 2026-09-25.
