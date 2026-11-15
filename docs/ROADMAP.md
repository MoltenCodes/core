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
- [x] Deferred to the user-interface phase: **timerKit** engine-driven
      pausable ticker (W15, needs an animation host; built in package M on
      `C_Timer` handles instead, see "timerKit pausable timers"), **frameKit** (W14,
      folded into widgetKit's anchors, nothing further to build), Registry
      deprecation warnings (W13; Registry's line budget is spent, so they are
      a ClientKit capability, see "clientKit deprecation warnings" in package
      M; done 2026-11-15, clientKit 0.3.0, revision 6).

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 1
   (documentation and tests only), 50 specs.

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2 (entry
   fields read with `rawget` when building, as when checking), 48 specs.

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2
   (`SetLimits` read `maxLaunchers` through the table's metatable), 41
   specs.

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 46 specs
   (cells measured with `GetUnboundedStringWidth`; both `GetCenter`
   coordinates checked for secrets).

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 33 specs
   (`releaseOnFinish` kept a bar restarted by `onFinished`; `ClearText`
   before plain text over a secret and on release).

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 32 specs
   (a parent's hide no longer cancels the dialog; secret button texts
   refused without naming allowSecret, a secret `cancel` before it is
   compared; a secret `text` drawn unconverted).

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, documentation only.

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 23 specs
   (a function-key button given up in combat is not reused until combat
   ends).

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, documentation only.

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
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 32 specs
   (a drag under way ends at `Unregister` and at Edit Mode's exit; the
   user-placed flag is cleared after `StartMoving`).

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
   `timer:Resume()` → `true`, or `false` unless it was paused (a closed
   scope has cancelled its paused timers, so `Resume` then answers
   `false`); `timer:IsPaused()`. `GetState` may answer
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
   resume after a closed scope, receiver errors at the caller, an upgrade from
   revision 11 keeping timers and a timer paused after it.
8. Docs: API.md (pausing, the state table, the methods), INTERNALS.md (the
   `_deadline` field while paused, the resume closure), CHANGELOG, README,
   tests/README; Package I's deferred item and package M's checklist.
9. Status: implemented 2026-11-15 under core decision 15, 0.8.0, revision
   12, 12 specs. No client suite: pausing uses only `C_Timer` handles the
   existing TimerKit client suite already proves.
   Reviewed 2026-11-15 under core decision 17: 0.8.1, documentation only;
   the client suite gains a `pause` test.

**Further work, decided 2026-11-15 under core decision 16.** The owner asked
to finish the remaining roadmap work before the real-client runs, which come
last: the LibDualSpec counterpart, a ScrollBox list, range checking, a unit
frame finder, and `C_EncodingUtil` where it gains performance, plus W13's
deprecation warnings (W14's frameKit is folded into widgetKit's anchors).
Each record below was researched from Blizzard's UI source, the client API
documentation and the libraries it replaces (ideas only), written before its
code and treated as agreed as under decision 15.

- [x] **clientKit** deprecation warnings (W13) (2026-11-15; client suite not run).
- [x] **settingsKit** spec profiles, with OptionsKit's `ProfileOptions` choice: settingsKit 0.4.0 revision 11, optionsKit 0.6.0 revision 11 (2026-11-15; client suites not run).
- [x] **widgetKit** virtualised lists (`ScrollList`): widgetKit 0.4.0 revision 12 (2026-11-15; client suite not run).
- [x] **rangeKit** — unit range estimates (2026-11-15; client suite not run).
- [x] **unitFrameKit** — the unit frame shown for a unit (2026-11-15; client suite not run).
- [x] **codecKit** native DEFLATE through `C_EncodingUtil`: compression only, codecKit 0.2.0 revision 7 (2026-11-15; client suite not run).

**clientKit deprecation warnings (W13)** — an addition to facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1 (additive),
   version 0.3.0, implementation revision 6.
2. Purpose: a Kit marks one of its own things as deprecated (an API
   generation, a facade method, an option) with a replacement and a
   removal plan, and the addon that still uses it is told once per call
   site (or once per addon, when the Kit knows the addon) for the
   session, never once per call. This is the part of W13 Registry's spent
   line budget leaves to ClientKit, as `GetManifest` was; Registry is not
   touched. A Kit finds ClientKit through `Registry:Find("clientKit", 1)`
   at its first deprecated call and checks for `Deprecate`, so no Kit
   gains a load-order edge and a session without ClientKit, or with an
   older revision, simply reports nothing. Nothing is raised unless a
   developer asks for it. Today no Kit has anything deprecated (no
   `docs/API.md`, CHANGELOG or README marks a member deprecated), so the
   capability ships with its specs and documentation and its first
   consumer is the first Kit that deprecates. Non-goals: Blizzard's
   deprecated globals (`Blizzard_Deprecated*`, switched by the
   `loadDeprecationFallbacks` CVar), wrapping or replacing the deprecated
   function for the Kit, removal scheduling, persisting reports across
   sessions, Registry's data-package kinds.
3. Dependencies: unchanged, registry API 2. Host requirements:
   `debugstack` names the call site (all three flavours; without it the
   site is unknown and reports fall back to once per addon given, else
   once per deprecation); `geterrorhandler` carries the report (`print`
   without it). The `debug` library is not used: the Retail client
   publishes no `debug` global.
4. Surface: `ClientKit:Deprecate(spec)` → reporter, with `name` (what is
   deprecated, for example `"TimerKit:After"`, `"EventKit API 1"`,
   `"SettingsKit:Open option legacy"`), `removal` (required: when or in
   what it goes, for example `"TimerKit API 2"`) and `replacement`
   (optional); a second `Deprecate` under the same name returns the same
   reporter with the newer spec's text, so an upgraded Kit re-declaring
   at load adds nothing. `reporter:Warn(level?, addonName?)`: `level` as
   for `error` (default 2, the caller of the Kit's method); `addonName`,
   when the Kit knows the consuming addon (a scope's owner), makes the
   addon the once-key and skips `debugstack` after the first report.
   `ClientKit:GetDeprecationReports()` → fresh array of fresh rows
   `{ name, replacement, removal, addon, site }` in report order, for a
   developer listing what this session used. `ClientKit:SetDeprecationMode(mode)`
   and `GetDeprecationMode()`, one switch for the session: `"report"`
   (default: record and hand to the error handler), `"silent"` (record
   only), `"raise"` (development: raise the report at the consumer's line
   on every call, unrecorded). `SetLimits{ maxDeprecations, maxReports }`
   / `GetLimits()`. Report text: `MoltenCodes: TimerKit:After is
   deprecated; use TimerKit:Delay. Removal: TimerKit API 2. Called from
   MyAddon (Interface/AddOns/MyAddon/Core.lua:42).` The addon is the
   folder after `Interface/AddOns/` in the `debugstack` frame (`/` or
   `\`, bracketed or `[string "@..."]` form), or the `addonName` given,
   or `"unknown"`.
5. Ownership: reporters and their once-keys live for the session in
   ClientKit's state, keyed by name, with the reporter prototype in state
   so an upgraded revision rewrites `Warn` in place. Reports live until
   the session ends; none is saved. A Kit calls `Warn` before it changes
   any state, so `"raise"` leaves the Kit as it was. The mode is shared by
   every addon in the session and is a developer switch, documented as
   such.
6. Performance and memory: nothing runs, and nothing is allocated beyond
   four empty state tables, until a Kit calls `Deprecate`; a Kit that
   deprecates nothing costs nothing. `Warn` on a deprecated path: one
   mode comparison, then with `addonName` one table lookup after the
   first report, otherwise one `debugstack(level + 1, 1, 0)` and one
   lookup of the frame line in the reporter's once-table (no string is
   concatenated before the lookup). Past `maxReports` every reporter stops
   resolving sites and answers after the one comparison. `maxDeprecations`
   defaults to 128 with a ceiling of 1024; a `Deprecate` past it returns
   one shared inert reporter and reports the cap once, never raising at a
   Kit's load. `maxReports` (recorded reports and once-keys for the
   session) defaults to 256 with a ceiling of 4096. No `UNBOUNDED` for
   either.
7. Tests: a report through the error handler once per call site and once
   per addon, a second call from the same site silent, two sites two
   reports, the addon named from a `debugstack` frame in each written form
   and `"unknown"` otherwise, a host without `debugstack` and without
   `geterrorhandler`, the three modes (raise at the consumer's line with
   an explicit level), `GetDeprecationReports` rows and their isolation, a
   re-declared name returning the same reporter with the new text, both
   limits and the inert reporter, the optional-Kit pattern through
   `Registry:Find` with ClientKit absent and with revision 5, secret
   values (spec fields, `addonName`, a secret frame line), receiver and
   argument errors at the caller, an upgrade from revision 5 keeping
   manifests and adding the deprecation state, manifest. A client suite
   addition to `MoltenCodesTest_ClientKit` on Retail, Mists of Pandaria
   Classic and Classic Era: the `debugstack` frame text logged and the
   suite's own addon named in the report.
8. Docs: API.md (a Deprecations section with the Kit-side pattern, the
   modes, the report text; Limits rewritten, since ClientKit gains
   `SetLimits`), CHANGELOG, README, tests/README; ARCHITECTURE's clientKit
   paragraph; package I's deferred item and the clientKit checkbox.
9. Status: implemented 2026-11-15 under core decision 16, 0.3.0, revision
   6, 44 new specs (176 in all); the client suite addition
   (`tests/client/MoltenCodesTest_ClientKit`, part `deprecations`) is
   written and has not been run in a client. Deviations: `debugstack` is a
   guarded local read at every load rather than kept in `state.host` (the
   flavour gate cannot follow a value stored in a table); the deprecation
   state is one `deprecation` table holding a few small tables; the
   one-time `maxDeprecations` notice is not sent in `"silent"` mode; the
   Kit-side pattern remembers a missing ClientKit, so one that loads after
   a Kit's first deprecated call is not used for that deprecation.
   Reviewed 2026-11-15 under core decision 17: 0.3.1, revision 7
   (`IsAtLeast` refuses a secret interface number at the caller before
   comparing it).

**settingsKit spec profiles** — an addition to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.4.0, implementation revision 11.
2. Purpose: a database switches its current profile by itself when the
   player changes specialization, what LibDualSpec-1.0 gives AceDB-3.0
   databases. Each character assigns a profile to a *spec index*; when the
   index changes, the database calls its own `SetProfile` with the
   assigned name, so `db.profile`, getters and `OnProfileChanged` follow
   as for any switch. The spec index is the specialization on Retail and
   Mists of Pandaria Classic (`C_SpecializationInfo.GetSpecialization()`,
   1 to the class's count), and the active talent group on Classic Era,
   Season of Discovery and Hardcore, where dual talent specialization is
   the mechanism (`C_SpecializationInfo.GetActiveSpecGroup()`). Which of
   the two is decided once from `WOW_PROJECT_ID`, with ClientKit's
   literals: `1` and `19` mean specialization, anything else (or no
   constant) means talent group, the answer every client has. This is
   the roadmap's "spec-aware profiles" (settingsKit record, point 2),
   which the saved-table contract lets generation 1 add as a new section.
   Non-goals: the options UI (OptionsKit's `ProfileOptions`, a separate
   capability with its own record), switching on Retail talent loadouts,
   pet specializations, an enabled flag (no assignment means no
   switching), importing LibDualSpec's AceDB namespace (a later bridgeKit
   item).
3. Dependencies: unchanged, registry API 2, schemaKit API 1, signalKit
   API 1; EventKit API 1 stays optional through `Registry:Find` and is what
   makes the switch automatic (without it, the addon calls
   `db:ApplySpecProfile()` itself). Host requirements: `C_SpecializationInfo`
   with `GetSpecialization`, `GetActiveSpecGroup`, `IsInitialized` and
   `GetNumSpecializationsForClassID`, and `UnitClass` (third return, the
   class ID), all in the generated documentation of `live`, `classic` and
   `classic_era`; `GetNumTalentGroups` (not in the generated
   documentation, used by Blizzard's Classic talent frame) for the
   talent-group count, guarded. Every answer is checked with
   `issecretvalue` first. Without `C_SpecializationInfo` the index is
   unknown and nothing switches.
4. Surface: `SettingsKit:GetSpecIndex()` → `index|nil, count, kind`
   (`kind` is `"specialization"` or `"talentGroup"`; `nil` while the
   client has no data yet or the player has no specialization, for
   example Retail's starter specialization, whose index is above the
   class's count); `db:SetSpecProfile(index, name?)` → `true`, or `false`
   when the character key is unavailable: assigns profile `name` to spec
   index `index` (a positive integer up to 8) for this character, `nil`
   clears it, and applies it at once when `index` is the current one;
   `db:GetSpecProfile(index)` → `name|nil`; `db:ApplySpecProfile()` →
   `true` when it switched. Saved table: a new section `specProfiles`,
   keyed by `"<name> - <realm>"`, each entry `{ [index] = profileName }`;
   `Open` creates the section like the others and refuses a present
   non-table; an entry that is not a usable profile name is ignored.
   `DeleteProfile` removes assignments naming the deleted profile,
   `ResetDatabase` empties the section, a read-only database refuses
   `SetSpecProfile` and never switches. A manual `SetProfile` changes no
   assignment; the next spec change applies the assignment again.
5. Ownership: assignments live in the saved variable. One shared listener
   for the session, in state and calling through the dispatch table,
   connected to `PLAYER_ENTERING_WORLD`, `ACTIVE_TALENT_GROUP_CHANGED` and
   `PLAYER_SPECIALIZATION_CHANGED` (`ConnectUnit`, `"player"`) the first
   time a database has an assignment (at `Open` or `SetSpecProfile`), so an
   addon that never uses spec profiles costs EventKit nothing. On each
   event it reads the index once and applies it to every open database
   with an assignment for that index; an unchanged index does nothing.
   Databases opened by revision 10 or earlier gain the methods and the
   switching through the rewritten prototype; the section is created at
   their first `SetSpecProfile`.
6. Performance and memory: nothing per frame and nothing on the read and
   write paths of a view. A spec event costs two or three client calls and
   one table lookup per open database; the switch itself is
   `SetProfile`'s existing cost. No allocation until the first assignment
   of a character (its entry table). The main chunk sits at 197 of Lua
   5.1's 200 slots, so the new code goes in one `do` block with its own
   locals.
7. Tests: stand-ins for `C_SpecializationInfo`, `GetNumTalentGroups`,
   `UnitClass`, `WOW_PROJECT_ID` and the three events through EventKit's
   test environment; both kinds of index, a switch on each event, the
   starter specialization and uninitialised data answering `nil`, no
   switch without an assignment or for an unchanged index, assignment
   applied at once, clearing, `DeleteProfile` and `ResetDatabase` removing
   assignments, read-only refusal, no character key, without EventKit
   (`ApplySpecProfile` only), the listener connected once and only when
   used, a corrupted section and entries, secret answers from the client,
   argument error levels, an upgrade from revision 10 keeping databases
   and switching afterwards, manifest. A client-suite case on Retail (switch
   specialization, see the profile follow) is written and not run.
8. Docs: API.md (*Spec profiles*, the new saved-table section in *The
   saved table*, *Embedded copies and upgrades* for revision 11),
   INTERNALS.md (the shared listener and the section), README (a
   migration table from LibDualSpec-1.0), CHANGELOG, tests/README;
   ROADMAP's settingsKit record and package M checklist (the maintainer's).
9. Status: implemented 2026-11-15 under core decision 16, settingsKit
   0.4.0, revision 11, 33 specs (268 in all), with two additions decided
   while building: `PLAYER_LEVEL_CHANGED` is listened to as well
   (documented on all three flavours), and OptionsKit's `ProfileOptions`
   carries the per-spec choice in the same work (optionsKit 0.6.0, revision
   11, 13 specs: selects `spec1` to `spec8` over
   `db:SetSpecProfile`/`GetSpecProfile`, shown while
   `SettingsKit:GetSpecIndex()` counts more than one index). Deviations:
   the kind is read from `WOW_PROJECT_ID` on every call (same answer, one
   table read); each database remembers the index it last applied, and
   `Open` applies the assignment at once, so after `/reload` the assignment
   wins over a manual choice, as LibDualSpec does; an in-place upgrade also
   connects the listener for characters whose saved table already holds
   assignments. Client-suite tests are written in
   `MoltenCodesTest_SettingsKit` (suite `specProfiles`) and
   `MoltenCodesTest_OptionsKit` and have not been run in a client.
   Review fix 2026-11-15 (decision 17): settingsKit 0.4.1, revision 12: a
   spec event records the index for a database without an assignment,
   switches over a snapshot so databases opened by profile listeners during
   the event never make it skip one, and an in-place upgrade applies
   assignments only to databases revision 10 or earlier opened; 3 specs
   (271 in all). optionsKit 0.6.1, revision 12: a `ProfileOptions` group
   cached without spec selects is replaced once SettingsKit offers spec
   profiles; 1 spec (203 in all).

**widgetKit virtualised lists** — an addition to facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1 (additive),
   version 0.4.0, implementation revision 12. One new base widget type,
   `ScrollList`, at version 1; every other base type keeps its version.
2. Purpose: a list that stays cheap however long it is. Only the rows the
   list shows exist as frames; scrolling points them at other elements.
   Built on Blizzard's ScrollBox framework (`Blizzard_SharedXML/Shared/Scroll`
   and `DataProvider.lua`): a `WowScrollBoxList` frame, a `MinimalScrollBar`,
   `CreateScrollBoxListLinearView`, `ScrollUtil.InitScrollBoxListWithScrollBar`
   and `CreateDataProvider`. Retail, Mists of Pandaria Classic and Classic Era
   ship these with the same code (branches `live` 12.1.5, `classic` 5.5.4 and
   `classic_era` 1.15.9, read 2026-11-15; the only differences are Retail's
   narration hooks and a return value in the tree view, neither used here).
   What WidgetKit adds over calling the framework directly: a pooled widget
   that lays out and releases like every other one, checked arguments, a
   bounded element count, standard rows built once per row frame, a row
   formatter that raises reported and never breaking Blizzard's update, and
   single selection kept by WidgetKit. Recorded deviation: selection does not
   use `ScrollUtil.AddSelectionBehavior`, because every select there walks the
   whole data provider and allocates (`DeselectByPredicate`), and it reads an
   element's own `selected` field as selected. Non-goals: grid, tree and
   horizontal views; drag and drop; multi-selection; variable row heights
   (`SetElementExtentCalculator` recomputes every element's extent on each
   data change); custom row frames (a pooled list's rows go to the next
   consumer of the widget, so rows built by one addon would carry their
   children into another's list; such a list uses Blizzard's ScrollBox
   directly); sorting (sort the array before handing it over); secret texts
   in rows.
3. Dependencies: unchanged (registry API 2, poolKit API 1, signalKit API 1).
   Host requirement: `CreateFrame` with the templates `WowScrollBoxList`
   (a `Frame`) and `MinimalScrollBar` (an `EventFrame`), and the globals
   `CreateScrollBoxListLinearView`, `ScrollUtil` and `CreateDataProvider`.
   Without them `Create("ScrollList")` raises at the caller before any frame
   is made; the other widgets are unaffected.
4. Surface: `WidgetKit:Create("ScrollList")` → list.
   `list:SetRowHeight(pixels)` (a number of at least 8; default 20);
   `list:SetFormatter(callback|nil)`, `callback(element, index)` → text,
   icon? (default: `element.text` and `element.icon`);
   `list:SetElements(elements, retainScroll?)`, an array of tables, copied,
   at most `maxListElements`, every element checked before anything changes;
   `list:Insert(element, index?)`, `list:Remove(element)` → `true` or `false`,
   `list:Clear()`; `list:GetNumElements()`, `list:GetElement(index)`;
   `list:Refresh()` (draw the shown rows again after elements changed in
   place); `list:ScrollToElement(element, alignment?)` → `true` or `false`,
   with `alignment` `"begin"`, `"center"` (default), `"end"` or `"nearest"`;
   `list:SetValue(element|nil)`, `list:GetValue()`. Callbacks: a left click
   selects the row's element and fires `OnValueChanged(element)` when it
   changed; every click fires `OnClick(element, mouseButton)`. `SetDisabled`
   ignores clicks and greys the rows. `WidgetKit:SetLimits{ maxListElements }`
   joins the package limits.
5. Ownership: the widget's frame, its `WowScrollBoxList`, its
   `MinimalScrollBar` and its view are made once by the constructor and kept
   for the widget's life. Row frames are made by the view's own frame pool
   (`CreateFrameFactory`, keyed by the frame type `Button`), parented to the
   scroll target and reused by the next use of the widget; each row's parts
   (text, icon, highlight and selected textures) are made the first time the
   view hands WidgetKit that frame and kept in a table of the widget, never
   on the frame. Row click scripts call through the dispatch table, so an
   upgraded revision takes them over. On release the view is flushed (every
   row back to its pool, the data provider removed), row texts are cleared,
   and the formatter, the value and every element reference are dropped.
6. Performance and memory: frames per list are the rows its height shows,
   plus one, made once and pooled by the view; with the 8-pixel minimum a
   1080-pixel list holds at most 136. Row frames are the view's, not
   WidgetKit's, so they do not count against the frame cap. An element costs
   one array slot. Every data change costs one pass over the elements in
   Blizzard's code (`RecalculateExtent` walks the provider even with a fixed
   row height), so `Insert` and `Remove` are O(n) and many changes belong in
   one `SetElements`. `SetElements` allocates one data provider; scrolling
   allocates in Blizzard's view (a few tables per range change and accessor
   closures per acquired row), nothing in WidgetKit. Selection is one field.
   `maxListElements` defaults to 16384 and opens to `UNBOUNDED`: elements are
   the consumer's tables, never frames.
7. Tests: a package-local stand-in for the ScrollBox framework in
   `tests/support/WidgetKitTestEnv.lua` (templates, view, data provider and
   scroll bar recording what WidgetKit calls, and acquiring rows for a
   visible range); acquire and release with rows back in the view's pool and
   no element kept; standard rows built once per frame and reused across
   uses; the formatter (default, custom, raising, a non-string or secret
   text reported and shown empty); `SetElements` checks and limits
   (`UNBOUNDED` included), selection kept when the selected element is in
   the new list; `Insert`, `Remove`, `Clear`, `Refresh`; `ScrollToElement`
   and each alignment; clicks, selection, both callbacks and a callback that
   releases the list; `SetDisabled`; the refusal without the framework;
   secret arguments refused; error levels; an upgrade from revision 11 that
   keeps live widgets and adds the new limit; manifest. The existing client
   suite (`tests/client/MoltenCodesTest_WidgetKit`) gains a Retail case: a
   10000-element list shown, scrolled, a row clicked, a scroll to an
   element, the list released with the view's frame count unchanged on the
   next use, and the same in combat.
8. Docs: README, API.md (the `ScrollList` section, the limit row, the
   performance rows, the selection deviation), INTERNALS.md (rows in the
   view's pool, the row-parts table), CHANGELOG, tests/README, the client
   suite's EXPECTED.md; EMBEDDING's host-requirements row and package M's
   checklist (the maintainer).
9. Status: implemented 2026-11-15 under core decision 16, 0.4.0, revision
   12, 30 specs in `ScrollList_spec.lua`; the client cases
   (`widgetKit.scrollList` and the combat suite `widgetKit.scrollListCombat`
   in `tests/client/MoltenCodesTest_WidgetKit`) are written and have not been
   run in a client. Deviations: the base constructors moved into one table
   (the main chunk's 200-local limit); duplicate elements are refused,
   because Blizzard's view tells rows apart by their element; the formatter
   may return a number as the text; `ScrollToElement` finds the index and
   scrolls by it; a released `ScrollList` is not allocation-free in the
   client, since Blizzard's `Flush` allocates one table.
   Review fix 2026-11-15 (decision 17): widgetKit 0.4.1, revision 13,
   `ScrollList` version 2 (the formatter is asked again with the new index
   after `Insert` before the end and after `Remove`).

**rangeKit** — facade `RangeKit`

1. Package `rangeKit`, facade `RangeKit`, API generation 1, version 0.1.0,
   implementation revision 1.
2. Purpose: an estimate of how far a unit is from the player, in whole
   yards, and whether it is within a given distance: what
   LibRangeCheck-3.0 gives unit frames, nameplates and range displays. The
   client has no distance query for arbitrary units, so the estimate comes
   from yes-or-no checks of known reach, sorted by range: the player's own
   spells (`C_Spell.IsSpellInRange`, their reach read from
   `C_Spell.GetSpellInfo` `minRange`/`maxRange`, never hard-coded) and the
   interact distances of `CheckInteractDistance` (index 3, 7 yards, and
   index 4, 28 yards, as warcraft.wiki.gg documents them). A small built-in
   list per class names candidate spell IDs in four kinds, `harm`, `friend`,
   `resurrect` and `pet`; only those `C_SpellBook.IsSpellInSpellBook` reports
   are used, so one list serves every flavour and a spell missing from a
   flavour simply drops out. The unit's kind picks the list: attackable
   (`UnitCanAttack`), dead and assistable (`resurrect`), the pet (`pet`, then
   `friend`), assistable (`friend`), anything else interact distances only.
   A spell with a minimum range counts as in range when the client says so
   or when a checker at or below that minimum says the unit is closer;
   without such a checker it is left out. Spells whose `maxRange` is 0
   (melee) are left out, since melee reach depends on both units' combat
   reach, which the client does not expose. The checkers are rebuilt when
   the spellbook or talents change, and listeners hear when the lists
   change. The client refuses `CheckInteractDistance` from addon code in
   combat for units the player cannot attack (protected by the 10.2.0
   hotfix of 2023-11-16, enemy units allowed again by the hotfix of
   2023-12-11); the Kit skips interact checkers for such units while
   `InCombatLockdown()` is true, on every flavour. Non-goals: item-based
   checkers (`C_Item.IsItemInRange`: the same combat refusal, item data that
   must be requested from the server, and large per-flavour item lists),
   race-specific interact distances, `UnitInRange` (group members only, a
   single 40-yard answer, and secret on Retail), `UnitDistanceSquared`,
   a result cache (a call is a handful of client checks; callers throttle),
   handing out checker functions, and action-bar range
   (`C_ActionBar.IsActionInRange`).
3. Dependencies: registry API 2 only. EventKit is not used: one event frame
   of the package's own listens to a few events, as EditModeKit does. Host
   requirement: `CreateFrame`, `UnitClass`, `UnitExists`, `UnitCanAttack`,
   `UnitCanAssist`, `UnitIsDeadOrGhost`, `InCombatLockdown`,
   `C_Spell.GetSpellInfo`, `C_Spell.IsSpellInRange`,
   `C_SpellBook.IsSpellInSpellBook` and `Enum.SpellBookSpellBank`, all
   present on Retail 12.1.5, Mists of Pandaria Classic 5.5.4 and Classic Era
   1.15.9 (apiKit's generated tables of the 2026-11-14 captures;
   `UnitIsDeadOrGhost` is not in the Classic generated docs but Blizzard's
   own `CompactUnitFrame.lua` on `classic_era` calls it). Without them
   `GetRange` and `IsInRange` answer `nil`. `CheckInteractDistance` is
   optional (no interact checkers without it). The rebuild events are
   registered only when `C_EventUtils.IsEventValid` accepts them:
   `SPELLS_CHANGED`, `LEARNED_SPELL_IN_SKILL_LINE`, `PLAYER_TALENT_UPDATE`,
   `CHARACTER_POINTS_CHANGED` (all four in the generated docs of all three
   flavours) and `UNIT_PET` for the player (pet spells).
   `LEARNED_SPELL_IN_TAB` is not in any of the three captures and is not
   used.
4. Surface: `RangeKit:GetRange(unit)` → `minRange, maxRange` in yards
   (`nil, nil` when the unit does not exist or no checker answers;
   `maxRange` `nil` when the unit is beyond the longest checker; `0` as
   `minRange` when the shortest checker says in range);
   `RangeKit:IsInRange(unit, yards)` → `true` when `maxRange <= yards`,
   `false` when `minRange >= yards`, `nil` when the estimate cannot decide;
   `RangeKit:DescribeCheckers(kind)` → a fresh array of
   `{ range, minRange, source }` (`source` such as `"spell:589"` or
   `"interact:4"`) for `"harm"`, `"friend"`, `"resurrect"`, `"pet"` or
   `"interact"`; `RangeKit:OnCheckersChanged(callback)` → connection
   (`connection:Disconnect()`, `connection:IsConnected()`), called with no
   arguments after a rebuild that changed any list;
   `SetLimits{ maxListeners }` / `GetLimits()`. A unit token that is not a
   string, or a secret value, raises at the caller; a client answer that is
   a secret value counts as no answer.
5. Ownership: the checker lists belong to the Kit, built at the first query
   and rebuilt (and compared) on each rebuild event; nothing is kept per
   unit. A connection belongs to its caller until `Disconnect`; a listener
   that raises is reported through `geterrorhandler()` and the others still
   run. An upgraded revision takes over the event frame and the listeners
   through the stable closures in `_state`.
6. Performance and memory: nothing runs per frame and no timer runs.
   `GetRange` makes `UnitExists`, `UnitCanAttack`, `UnitCanAssist`,
   `UnitIsDeadOrGhost` and `InCombatLockdown` calls plus a binary search of
   the sorted list (at most four range checks for 16 entries, a `nil`
   answer counted as out of range) and allocates nothing. A rebuild walks
   the class's candidate list (at most 16 spells per kind) once. Each kind
   holds at most 16 checkers plus the two interact entries; duplicate
   ranges keep the first. `maxListeners` defaults to 32 with a ceiling of
   256 and no `UNBOUNDED`.
7. Tests: stand-ins for the spell, spellbook, unit and interact functions,
   `InCombatLockdown` and the events; lists built per kind from known spells
   only and sorted, ranges rounded, a duplicate range dropped, melee spells
   left out, a minimum-range spell joined with a closer checker and left out
   without one; `GetRange` brackets at both ends and between checkers, each
   unit kind picking its list, a dead friendly unit, a missing unit;
   interact checkers skipped in combat for a non-attackable unit and kept for
   an attackable one; `IsInRange` true, false and undecided; rebuild on each
   event with listeners called only on a change, a raising listener
   isolated, disconnecting; missing host functions; limits and ceilings;
   secret arguments and secret client answers; upgrade; manifest; error
   levels. A client suite on Retail: the player's target bracketed by
   `GetRange` while walking away, and the lists rebuilt after a talent
   change.
8. Docs: README (with the migration table from LibRangeCheck-3.0:
   `GetRange`, the `Get*Checker` family to `IsInRange`, `CHECKERS_CHANGED`
   to `OnCheckersChanged`, what is not carried over: items, `checkVisible`,
   `noItems`, `maxCacheAge`), API.md (the per-class candidate list with its
   source, the combat rule, the yard values), CHANGELOG, tests/README;
   EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 16, 0.1.0, revision
   1, 41 specs; the client suite (`tests/client/MoltenCodesTest_RangeKit`)
   is written and has not been run in a client. Deviations from the points
   above: a spell with a minimum range is joined with a checker, without a
   minimum of its own, whose range lies from that minimum up to the spell's
   range (a checker below the minimum would leave a gap); the pet list holds
   the pet spells and the friend spells together; at equal range a spell is
   kept over an interact checker, since it stays usable in combat; no cap on
   checkers in code, because the built-in data holds at most four spells per
   kind; without the spell functions RangeKit still answers from interact
   checks (`nil` only without `UnitExists`); the event frame is made at
   load, or at the first query when `CreateFrame` appears later.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 43 specs
   (a change of a spell's minimum range alone now notifies listeners).

Candidate spell IDs (the built-in list; reach is read from the client).
Taken from LibRangeCheck-3.0 minor 39 (MIT), which the Kit's code does not
copy; spells absent from a flavour or from the player's spellbook drop out:

| Class | `harm` | `friend` | `resurrect` | `pet` |
|---|---|---|---|---|
| Death Knight | 49576, 47541 | | 61999 | |
| Demon Hunter | 185123, 183752 | | | |
| Druid | 5176, 8921, 339, 33786 | 8936, 774, 5185 | 50769, 20484 | |
| Evoker | 362969 | 361469, 355913 | 361227 | |
| Hunter | 75, 466930, 2764 | | | 136 |
| Mage | 133, 116, 118, 5019 | 1459, 475 | | |
| Monk | 117952, 115546, 115078 | 116670, 115450 | 115178 | |
| Paladin | 20271, 62124, 853, 20473 | 19750, 635, 85673 | 7328 | |
| Priest | 589, 585, 8092, 5019 | 2061, 2050, 17, 527 | 2006 | |
| Rogue | 2094, 921, 185565, 2764 | | | |
| Shaman | 403, 188196, 370, 8042 | 331, 8004, 546 | 2008 | |
| Warlock | 686, 5782, 172, 5019 | 5697 | 20707 | 755 |
| Warrior | 355, 100, 5246, 2764 | | | |

**unitFrameKit** — facade `UnitFrameKit`

1. Package `unitFrameKit`, facade `UnitFrameKit`, API generation 1, version
   0.1.0, implementation revision 1.
2. Purpose: find the unit frame shown on screen for a unit token, what
   LibGetFrame-1.0 gives WeakAuras to anchor an aura or a glow to a party or
   raid member's frame. A scan walks the client's frames with
   `EnumerateFrames`, in slices, and keeps every visible `Button` whose
   `unit` attribute is set (with `unitsuffix` appended, as Blizzard's
   `SecureButton_GetUnit` does), under its name or, for an unnamed frame,
   its parent's name and parent key (`PartyFrame.MemberFrame1`). A query
   reads each kept frame's `unit` attribute again, compares it with
   `UnitIsUnit`, drops hidden frames, and ranks the matches: the caller's
   patterns first, then frames of other addons, then Blizzard's frames
   (`CompactRaidFrame%d`, `CompactRaidGroup%dMember%d`,
   `CompactPartyFrameMember%d`, `PartyFrame.MemberFrame%d`,
   `Boss%dTargetFrame`, then `PlayerFrame`, `TargetFrame`, `FocusFrame`).
   Frames are sorted into kinds (`raid`, `party`, `boss`, `player`,
   `target`, `targettarget`, `focus`); by default only `raid`, `party` and
   `boss` frames answer, and a solo kind answers when the token asked for
   is that kind's own token (`"target"` finds `TargetFrame`). Kinds of
   other addons come from a short pattern table, each entry checked in that
   addon's own published source and cited in `docs/API.md`; an entry that
   cannot be checked is left out, and such an addon's frames are still
   found, without a kind, ranked after the known ones. A nameplate is
   `C_NamePlate.GetNamePlateForUnit(unit)` and its `UnitFrame` child. Every
   name used exists on Retail, Mists of Pandaria Classic and Classic Era
   (Blizzard's `Blizzard_UnitFrame`, `Blizzard_CompactRaidFrames` and
   `Blizzard_NamePlates`, branches `live`, `classic` and `classic_era`,
   read 2026-11-15). Non-goals: names or GUIDs in place of unit tokens,
   per-addon workarounds (ElvUI's health bar, Cell's override hook),
   third-party nameplate addons, arena frames, frame creation or anchoring
   (the caller anchors), profiling.
3. Dependencies: registry API 2 only. It keeps one event frame of its own,
   so EventKit is not needed. Host requirement: `CreateFrame`,
   `EnumerateFrames`, `UnitIsUnit`, `UnitExists`; without `EnumerateFrames`
   nothing is kept and every query answers `nil`. `C_NamePlate` for
   `GetNamePlate` (`nil` without it). `issecretvalue` where the client has
   it: a secret `unit` attribute or a secret `UnitIsUnit` answer (Retail's
   `Attributes` aspect and restricted unit comparisons) makes that frame no
   match.
4. Surface: `UnitFrameKit:GetUnitFrame(unit, options?)` → frame or `nil`,
   with `kinds` (array of kinds in rank order), `priorities` (array of name
   patterns ranked before everything else), `ignore` (array of name
   patterns never answered); `UnitFrameKit:GetUnitFrames(unit, options?)`
   → a new array of every match in rank order; `UnitFrameKit:GetNamePlate(unit)`
   → frame or `nil`; `UnitFrameKit:Rescan()` (a scan starts on the next
   client frame); `UnitFrameKit:IsScanning()`;
   `UnitFrameKit:OnChange(callback)` → connection (`Disconnect()`,
   `IsConnected()`), called after a scan once per frame whose unit
   changed, with `(frame, unit, previousUnit)` (`previousUnit` `nil` for a
   frame new to the cache, `unit` `nil` for one gone from it), which is
   LibGetFrame's `FRAME_UNIT_ADDED`, `FRAME_UNIT_UPDATE` and
   `FRAME_UNIT_REMOVED` in one; `UnitFrameKit:GetKindPatterns(kind)` → a
   copy of the kind's patterns; `SetLimits{ maxFrames, scanFramesPerStep,
   maxListeners }` / `GetLimits()`. A unit that is secret or not a
   non-empty string, an unknown option or kind, a pattern list over 64
   entries, or a callback that is not a function raise at the caller.
5. Ownership: the Kit owns one event frame for the session. It scans on
   first use, on `PLAYER_ENTERING_WORLD`, `GROUP_ROSTER_UPDATE`,
   `PLAYER_REGEN_DISABLED`, `PLAYER_REGEN_ENABLED`,
   `INSTANCE_ENCOUNTER_ENGAGE_UNIT` and `UNIT_PET` of a group member, each
   coalesced into one scan one second later; a request during a scan
   queues exactly one more. The cache holds frames, which the client never
   frees, so it holds them strongly and replaces the whole cache at the end
   of each scan. A connection lives until `Disconnect`; a callback that
   raises is reported through `geterrorhandler` and the others still run.
   Scanning and queries only read frames, so both run in combat.
6. Performance and memory: the event frame's `OnUpdate` runs only while a
   scan is waiting or running. A scan visits at most `scanFramesPerStep`
   frames per client frame and keeps its place in `EnumerateFrames`, which
   is safe because frames are never deleted and the walk follows creation
   order; frames made during the scan come later in the walk and are seen.
   Per frame visited it calls `IsForbidden`, `GetObjectType` and, for a
   `Button`, `GetAttribute` and `IsVisible`, and allocates only for a kept
   frame (its name and kind). The cache and the scan's working table swap
   and are wiped, so a scan allocates no tables. A query reads at most
   `maxFrames` entries, one attribute and one `UnitIsUnit` each, and
   allocates nothing (`GetUnitFrames` allocates its result). Limits:
   `maxFrames` (frames kept) 512, ceiling 4096; `scanFramesPerStep` 400,
   ceiling 4000; `maxListeners` 64, ceiling 512; none `UNBOUNDED`. A scan
   that reaches `maxFrames` keeps the first ones and reports once through
   `geterrorhandler`. The cost of a full scan on a loaded Retail interface
   is measured in the benchmark harness before the first release and
   written into `docs/API.md`.
7. Tests: stand-ins for `EnumerateFrames`, frames with attributes,
   visibility and names, `UnitIsUnit`, `C_NamePlate` and the events; frames
   found by attribute and by `unitsuffix`, unnamed frames named through
   their parent key, forbidden, hidden and non-button frames skipped, aura
   buttons (`type` `"cancelaura"`) skipped, the scan sliced per client frame
   and resumed in place, frames created during a scan, rescans coalesced
   and queued, ranking by caller patterns, other addons and Blizzard's
   frames, kinds and the solo-token rule, `ignore`, `GetUnitFrames` order,
   `OnChange` with added, changed and removed frames and a callback that
   raises, nameplates, limits and ceilings, the `maxFrames` report, secret
   arguments, secret attributes and secret `UnitIsUnit` answers, a host
   without `EnumerateFrames`, upgrade, manifest, error levels. A client
   suite on Retail: in a party with Blizzard's frames, `GetUnitFrame("party1")`
   answers the shown party frame, and after `Rescan` with raid-style party
   frames answers the compact one.
8. Docs: README (with the migration from LibGetFrame-1.0), API.md (the
   ranking, the kinds and their cited patterns, the measured scan cost),
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 16, 0.1.0, revision
   1, 65 specs; the client suite (`tests/client/MoltenCodesTest_UnitFrameKit`)
   is written and has not been run in a client. Third-party patterns shipped
   only where checked in the addon's own source: ElvUI, Cell, Grid2 and
   Shadowed Unit Frames (commits cited in `docs/API.md`); the rest of
   LibGetFrame's list is left out, and those frames are found without a
   kind. Deviations: a query allocates one string for a frame with a
   `unitsuffix` attribute; a scan reads up to three attributes per button
   (`unit`, `unitsuffix`, `type`, to skip secure aura buttons); a frame
   matching a caller's `priorities` answers whatever its kind, and `ignore`
   wins over `priorities`; a scan that raises is dropped and reported once;
   `IsScanning` is also true while a scan waits to start; the client suite
   accepts whichever Blizzard party style is shown rather than switching it.
   The full-scan cost is to be measured in the benchmark harness before the
   first release.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 68 specs
   (Blizzard's `PetFrame` and `FocusFrameToT` rank as Blizzard's and answer
   only for their own token; frames `CanBeAccessedInContext` refuses are
   skipped).

**codecKit native DEFLATE** — a change inside facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1 (no change to
   the surface), version 0.2.0, implementation revision 7, wire format
   version 1 (unchanged). Minor version because what a client with
   `C_EncodingUtil` writes changes (different, equally valid DEFLATE
   bytes), even though no member is added.
2. Purpose: run the compression stage, and only that stage, through the
   client's `C_EncodingUtil.CompressString` and `DecompressString` with
   `Enum.CompressionMethod.Deflate` where the client has them, because that
   is the one stage whose format the client implements exactly: raw DEFLATE
   (RFC 1951), which the Retail client suite already proved interoperates
   with CodecKit in both directions. Frames keep version 1 and the same
   flags; every frame any revision wrote still decodes, and a frame written
   through the native compressor decodes in revisions 1 to 6, whose inflater
   reads any conforming raw DEFLATE stream. Non-goals, each because the
   bytes would change: the serialiser (`SerializeCBOR`/`DeserializeCBOR` and
   the JSON pair write other formats and cannot carry CodecKit's exact
   doubles, `-0`, `nil` list entries, the argument-list type or the refusal
   vocabulary), the print channel (CodecKit's base 85 over its own
   85-character alphabet is not `EncodeBase64` in either RFC 4648 variant),
   the addon channel (no native counterpart; it is one `gsub`), and the hex
   functions (CodecKit has no hex stage). Also not a goal: byte-identical
   compressed output across clients, which `docs/API.md` already disclaims
   ("Encoded bytes are not a content hash").
3. Dependencies: unchanged, registry API 2 and poolKit API 1, schedulerKit
   API 1 optional. Host facility, optional: `C_EncodingUtil.CompressString`
   and `C_EncodingUtil.DecompressString`, documented identically on `live`
   since 11.1.5 (60428), `classic` since 5.5.0 (61767) and `classic_era`
   since 1.15.8 (63829), so on every promised client (12.1.5, 5.5.4,
   1.15.9); and `Enum.CompressionMethod.Deflate` (0) and
   `Enum.CompressionLevel` (`Default` 0, `OptimizeForSpeed` 1,
   `OptimizeForSize` 2), with the documented values used when `Enum` lacks
   them. Both functions are looked up with `rawget(_G, "C_EncodingUtil")` at
   every call, as `issecretvalue` is, each guarded with
   `type(...) == "function"` for the flavour gate. Without them, or on the
   host, every call takes the Lua path exactly as revision 6 does.
4. Surface: none added. Which path ran is internal; the package test
   environment's stand-in counts native calls, which is how the specs tell.
   The level option keeps its 1 to 9 range and maps onto the client's
   three: 1 to 3 to `OptimizeForSpeed`, 4 to 6 to `Default`, 7 to 9 to
   `OptimizeForSize`. What stays on the Lua path, and why:
   - compressing an input under 64 bytes (the existing literal or stored
     block, which allocates nothing and is what addon messages mostly are);
   - inflating an input larger than `maxOutputBytes / 64` bytes (16 KiB at
     the default limit): DEFLATE expands at most about 1032 to 1, and the
     native inflater only stops at its own 100 MiB cap
     (`Constants.EncodingLimits.EncodingDecompressSizeLimit` = 104857600),
     after which CodecKit can only measure the result. Below that bound the
     worst native output is no larger than the 16 bytes per output byte the
     Lua inflater already claims for an honest frame at the limit, so "a
     DEFLATE bomb costs at most this much" keeps its meaning. A consumer that
     raises `maxOutputBytes` raises the bound with it.
   - any native failure. `DecompressString` raises on invalid data and both
     functions may return nothing (`MayReturnNothing`), so each native call
     runs under `pcall`; a raise, no result or a non-string result reruns the
     stage on the Lua path, which returns the documented reason
     (`"malformedDeflate"`, `"truncated"`, `"trailingData"`,
     `"maxOutputBytes"`). Decoders still never raise, and every refusal
     keeps the reason revision 6 returns.
   - a native result is still measured against `maxOutputBytes` on both
     stages, as the Lua path's is.
   `EncodeAsync` and `DecodeAsync` use the native stage in one call when it
   applies (it cannot yield, and host C zlib measured 20 to 150 times
   cheaper than the Lua stage it replaces; see 6), and keep the sliced Lua
   path above an internal `ASYNC_NATIVE_MAXIMUM_BYTES` of 256 KiB of stage
   input, to be confirmed by the client measurement in 7.
   Gate before the inflate half ships: the client suite must show what
   `DecompressString` does with bytes after the final block. If it refuses
   them, native inflation is adopted as above; if it accepts them, a frame
   the Lua path refuses with `"trailingData"` would decode, so only native
   compression ships and inflation stays Lua until the owner decides.
5. Ownership: nothing new is held. No state field is added; the host
   functions are read per call and never cached in `_state`, so a revision 6
   copy upgraded in place and a revision 7 copy share the same state table,
   limits, `UNBOUNDED` and pool. A string the client returns belongs to the
   caller like any stage output.
6. Performance and memory. Measured on the host (Apple M5 Pro, Lua 5.1.5,
   load average about 30 to 40 during the runs, so read the ratios, not the
   absolute times), CodecKit revision 6, per KiB of input: compress level 6
   0.57 ms (prose, 10 and 50 KiB) and 0.48 ms (random); level 1 0.30 to
   0.44 ms; level 9 0.57 to 0.64 ms; inflate 0.13 to 0.18 ms (prose) and
   0.035 ms (stored blocks); print encode 0.09 ms, decode 0.12 ms; addon
   escape 0.010 ms, unescape 0.016 ms. The same inputs through host C zlib
   raw DEFLATE (window bits −15): compress level 6 0.013 to 0.032 ms, level
   9 0.015 to 0.054 ms, inflate 0.001 to 0.002 ms; that is 18 to 43 times
   cheaper to compress prose at level 6 and 110 to 150 times cheaper to
   inflate it, with output within 0.3% of CodecKit's size at levels 6
   and 9 (4508 against 4508 bytes, 18261 against 18237). Inferred, not
   measured: the client's functions perform like host zlib; Blizzard does
   not say which DEFLATE implementation they use, and the Retail client
   suite logs `CompressString` and `DecompressString` timings beside
   CodecKit's on a 50 KB roster, but that log was not kept in
   `tests/client/results.json`. Published: WeakAuras issue 5835 calls the
   native functions "substantially faster than LibDeflate+LibSerialize";
   no adopter published numbers. Memory: the Lua compressor's working arrays
   (a few tens of bytes per input byte and 35 to 40 KiB of code tables per
   32 KiB block) and the Lua inflater's output array (about 16 bytes per
   output byte) are not allocated on the native path; the native path
   allocates its result string, and `pcall` is given the host function
   and its arguments directly, so no closure is made per call. What does not
   change: serialising (the `codec` host benchmark, 0.82 ms to encode and
   0.65 ms to decode the large payload) and the print channel, which
   together are the whole cost of an uncompressed frame.
7. Tests, in the package's specs with a stand-in in
   `tests/support/CodecKitTestEnv.lua`: a `C_EncodingUtil` whose
   `CompressString` and `DecompressString` are a second, independent raw
   DEFLATE (CodecKit's own Lua stages loaded as a separate copy, with stored
   blocks forced for compression so its bytes differ) and count calls;
   modes that raise, return nothing, return a non-string, accept trailing
   bytes and refuse them. Specs: with the stand-in, `Compress`, `Encode`
   with `compress = "deflate"` and both asynchronous variants call it at and
   above 64 bytes and not below; its output decodes on the Lua path (stand-in
   removed) and Lua output decodes through it; every golden compressed frame
   of `FastPath_spec.lua` decodes through it; without it every golden frame
   is written byte for byte as revision 6 wrote it; each failure mode falls
   back and returns revision 6's reason; the inflate bound (an input of
   `maxOutputBytes / 64` bytes goes native, one byte more does not, and a
   raised `maxOutputBytes` moves it); `maxOutputBytes` on native results;
   the level mapping; the async size threshold; a secret string is refused
   before the stand-in is called; `Enum` missing uses the documented values;
   `C_EncodingUtil` present without the two functions takes the Lua path;
   the allocation specs unchanged without the stand-in and for inputs under
   64 bytes with it; an in-place upgrade from revision 6 keeping state and
   pool. Client suite (`tests/client/MoltenCodesTest_CodecKit`, never run by
   tooling): the existing interop tests stay; added, with the facade test
   logging which path runs: an `Encode`/`Decode` round trip of the 50 KB
   roster on the native path that a revision 6 copy loaded beside it
   decodes, and the reverse; `DecompressString` on a valid stream followed
   by trailing bytes, logged and asserted against the gate in 4; a stream
   that inflates past `maxOutputBytes`; the time of a 256 KiB and a 1 MiB
   native compress at `OptimizeForSize` and inflate, to confirm the async
   threshold; and the side-by-side timings of the existing log, written to
   EXPECTED.md this time. Classic Era and Mists of Pandaria Classic runs
   are required before the native path is called proven there.
8. Docs: API.md (the compression section: which encoder runs where, the
   level mapping, the inflate bound, the trailing-data finding, and the Cost
   section with the native rows once measured on the client; the optional
   facilities table gains `C_EncodingUtil`), INTERNALS.md (the native path,
   its fallback and the bound), README (the "Standard compression" line and
   the host facilities in Embedding), CHANGELOG, tests/README,
   EXPECTED.md for the client suite; `docs/EMBEDDING.md` host-requirements
   row for codecKit (applied by the maintainer).
9. Status: implemented 2026-11-15 under core decision 16, 0.2.0, revision
   7, 146 specs. Recorded deviation: native compression only. A frame has
   no declared length, checksum or end marker of its own, so CodecKit
   cannot tell whether the client's inflater accepted a stream its own
   inflater refuses (bytes after the final block); inflating stays in Lua
   on every client, with no native inflate code. A later revision may
   inflate natively, behind the 16 KiB bound of point 4, once the client
   suite's `codecKit.native` trailing-bytes test has shown what
   `DecompressString` does (docs/INTERNALS.md, "Native compressor"). The
   client suite (`tests/client/MoltenCodesTest_CodecKit`, now 36 tests) is
   not run yet.
   Reviewed 2026-11-15 under core decision 17: 0.2.1, revision 8 (a secret
   native result or `Enum` value falls back to Lua or to the documented
   number).

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

**Kit parts and the embeds generator (core decision 19a)** — repository tooling, no facade

1. Tooling for Kits made of a core file plus optional part files, so an
   addon loads only what it uses (core decision 19a). Scope: (`tooling/`, `tests/support/framework/`, `docs/TOOLING.md`,
   `docs/decisions/`, `.github/workflows/`, the manifest schema). No Kit is
   split by this record: every Kit stays single-file and behaves exactly as
   today. Splitting a Kit is its owner's record (a later package O record starts with
   widgetKit).
2. Purpose: the memory diagnosis (the diagnosis prototype, fix 12) measured
   339 KB of resident code in optional sections a typical addon never runs
   (SchedulerKit and EventKit coalescing, CodecKit compression, CommKit
   reassembly and SyncSet, CommandKit options binding, SettingsKit views and
   spec profiles, ModuleKit halted addons, the WidgetKit renderer and widget
   types). It is the only lever that brings a typical addon near Ace3, and it
   needs the tooling first. The usability diagnosis (the diagnosis prototype,
   cause 3 and F6) found that embedding means copying a 46-line load order by
   hand and that the builder writes no `embeds.xml`. This record gives both:
   parts in the manifest and every gate, and a generated `embeds.xml`.
   Non-goals: assembling parts into one release file (architecture plan 5.3,
   superseded by 19a, which ships parts as files); turning apiKit's flavour
   files into parts (possible later, noted as a follow-up); per-flavour
   `.toc` files; comment stripping; publishing releases.
3. Dependencies: Python 3.10+ standard library only, as the rest of
   `tooling/`; host Lua 5.1 and Busted for the runner, LuaCov for coverage,
   as today. No runtime dependency is added to any Kit.
4. Surface.
   - **Layout.** A part is `packages/<id>/src/parts/<Facade>-<Part>.lua`,
     for example `eventKit/src/parts/EventKit-Coalescing.lua`. `<Part>` is
     PascalCase (`^[A-Z][A-Za-z0-9]*$`). The facade prefix gives every part
     one name across the repository: one `require` name in specs, and an
     unambiguous file name in a client error even when the client cuts the
     path short (the Ace3 `AceGUIWidget-Button` spelling authors know).
     `src/` keeps exactly one top-level Lua file, the core. Other
     subdirectories of `src/` (apiKit's `flavours/`) keep today's meaning:
     always loaded after the core.
   - **Manifest.** An optional `parts` object, written last (after the
     top-level `api` and `revision`, so every `Manifest_spec` that reads the
     first `"api"`/`"revision"` keeps working):

     ```json
     "parts": {
       "Coalescing": {
         "description": "Coalesced and bucketed delivery.",
         "revision": 1,
         "dependencies": { "schedulerKit": { "api": 1 } },
         "optionalDependencies": {},
         "parts": ["Throttle"]
       }
     }
     ```

     `revision` is the part's own implementation revision (highest wins at
     runtime, as for a Kit). `parts` names sibling parts it needs; its own
     core is always implied. Any dependency contract, in a part or in the
     core's `dependencies`, may carry `"parts": ["Name", ...]` to require
     parts of another Kit. Validation: names and file exist one to one
     (a file under `src/parts/` with no entry fails, and the reverse);
     required parts exist; no part names its own Kit in `dependencies`; a
     core never requires its own parts; a release Kit never requires a
     development Kit's part; the required graph over cores and parts has no
     cycle; the part file's `PART_REVISION = <n>` literal equals the
     manifest `revision`.
   - **Runtime contract** (written in ADR 0019a; implemented per Kit by its
     owner): a part loads after its core and everything it requires, resolves
     its core through `Registry:Get` at file scope and raises
     `MoltenCodes <Facade> part <Part> requires <Facade> API <n> to be loaded
     first` when it is missing; it keeps its state in the core's state
     (`_state.parts.<Part>`) with its own `PART_REVISION`, so two addons
     embedding different revisions of a part upgrade in place like Kits; a
     core feature whose part is absent fails at the caller's line with an
     error that names the part to embed.
   - **Load order.** One rule for cores and parts: a depth-first walk over
     nodes. A core's needs are its dependency Kits' cores (sorted by name),
     each followed by the parts its contract names; a part's needs are its
     own core, then its dependency cores and named parts, then its sibling
     parts in manifest order. The top level walks the selected Kits in sorted
     order, each core followed by its selected parts in manifest order. With
     no parts in the repository this is exactly today's algorithm, so every
     existing load order, `.toc` and checksum stays byte-identical.
   - **Builder** (`python3 -m tooling.package.build`):
     `--package ID` (repeatable) selects a Kit's core and the parts its
     contracts require; `--part ID/Part` or `ID/*` (repeatable) adds parts and
     implies the core; `--all` is every release Kit with every part (the
     standalone `MoltenCodes` addon). Bundle name: `MoltenCodes` for `--all`;
     `MoltenCodes-<Facade>` when the selection is one Kit (with any of its
     parts); otherwise `MoltenCodes-Custom`, overridable with `--name`
     (`^MoltenCodes(-[A-Za-z0-9]+)?$`). `--embeds` also writes `embeds.xml` in
     the bundle root. Every file is copied, checksummed and listed in the
     bundle `.toc` in load order; `--verify` holds `CHECKSUMS.txt`, the `.toc`
     and `embeds.xml` to the build. `manifest.json` moves to schema 2: each
     package entry gains `parts` (files, revision, contracts) and
     `selectedParts`, and `loadOrder` may interleave packages (a part can load
     after another Kit's core). The release workflow, `tooling.release.
     library_toc --package` and `tooling.release.pkgmeta --package` build a
     single-Kit release as the whole Kit (`--package ID --part 'ID/*'`), since
     the packager moves the whole `src/` folder; unchanged output today.
   - **Embeds generator** (`python3 -m tooling.package.embeds`): positional
     selectors `ID` (core), `ID/Part`, `ID/*`; `--root 'Libs\MoltenCodes-Custom'`
     (the folder the author copies the bundle to); prints `embeds.xml` (one
     `<Script file=...>` per file, backslashes, dependencies deduplicated, a
     comment naming the selection), or with `--toc` the equivalent `.toc`
     lines; `--out FILE` writes it. Unknown Kit, unknown part, development Kit
     and a missing dependency are refused with a message that names the fix
     (`unknown Kit "TimerKit"; did you mean "timerKit"?`). The builder's
     `--embeds` uses the same function, so the two never disagree.
   - **Test runner** (`tooling.test.run`): every source package on a suite's
     path also contributes `src/parts/?.lua`, so a spec loads a part with
     `require("EventKit-Coalescing")`, or names it in its test environment's
     `modules` list after the core. A suite also gets the Kits its parts
     require and optionally use (the same rule as `optionalDependencies`
     today).
   - **Coverage** (`tooling.test.coverage`): a package's figure covers its
     core and its parts; the report and the step summary show one row per
     part; a declared part that no spec of its own package loaded fails the
     run (a file LuaCov never saw is otherwise invisible).
   - **lua-language-server**: a package's expected `src/.luarc.json` library
     list is the dependency-first closure of its core and all of its parts
     (the `src/` workspace already contains the parts). Unchanged for every
     Kit today.
   - **Repository validation**: the part rules above; the quoted load order
     in `docs/EMBEDDING.md` keeps its check (now including part files); the
     "Minimum footprint per Kit" table and a new "Optional parts" table are
     rendered from the manifests and compared between
     `<!-- generated:footprint -->` / `<!-- /generated:footprint -->` and
     `<!-- generated:parts -->` / `<!-- /generated:parts -->` markers; a
     mismatch prints the exact replacement block, as the load-order check
     does. `python3 -m tooling.package.embeds --footprint` prints both.
5. Ownership: the builder owns nothing at runtime. A generated `embeds.xml`
   is the author's file once written; the generator never edits an existing
   file unless `--out` names it. Generated documentation blocks are only the
   marked blocks; the prose around them stays hand-written.
6. Performance and memory, expected from the prototypes: the tooling adds no
   runtime cost; with no Kit split yet, every bundle is byte-identical to
   today's (checked against the checksums of today's `--all` bundle:
   189 files, 45 Lua files in load order). Once Kits are split, an addon
   that embeds no optional part saves up to 339 KB resident (memory.md
   fix 12), and the event-and-timer minimum set drops from about 333 KB to
   about 313 KB without EventKit coalescing alone. For the author: generated
   `embeds.xml` lines 19 to 0 hand-written for the nine-Kit usability
   example (the prototype's 19 files equal the hand list), and every
   additional addon embedding the same Kits compiles less (duplicate
   embedding allocates 4,992 KB transient today, all of it proportional to
   the files loaded).
7. Tests (`tooling/tests/`, temporary repositories as the builder tests use):
   manifest validation of `parts` (each rule above, accept and refuse); load
   order with parts (core before part, part after another Kit's core, a core
   requiring another Kit's part, sibling parts, cycles refused, the walk
   identical to today's without parts, asserted on the real manifests);
   builder selections (`--package` repeated, `--part ID/Part`, `ID/*`,
   `--all`, names, `--name`, `--embeds`, schema 2 manifest, checksums and
   `--verify` catching a stale `embeds.xml`); the embeds generator (XML and
   `.toc` output, deduplication, root prefix, each refusal message); the
   runner's path carrying `src/parts/` and a Busted run of a fixture Kit
   whose spec requires its part; coverage failing for a part no spec
   loaded and reporting part rows; `.luarc.json` expectations with a part
   that adds a dependency; the EMBEDDING footprint and parts blocks;
   `library_toc` and `pkgmeta` single-Kit output unchanged today. The full
   `--all` build is compared with the baseline checksums.
8. Docs: `docs/TOOLING.md` (builder options, the embeds generator, runner
   and coverage notes); `docs/decisions/README.md` (what an ADR is here,
   the template: Status, Date, Context, Decision, Consequences; numbering:
   ADRs are numbered in sequence from 0001 and stand on their own, each
   naming its date and what it decides: `0001-kit-core-and-parts.md`,
   `0002-secret-checks-only-where-the-client-answers.md`,
   `0003-method-name-callbacks.md`, `0004-addon-kit-entry-point.md`, in
   plain project language. Also updated by this work: `docs/PACKAGE_MANIFEST.md` ("Parts" section
   and the layout tree), `docs/RELEASES.md` (options table, bundle names,
   schema 2), `docs/TESTING.md` (loading a part in a spec). Shared files,
   exact text in the phase 2 report: `docs/EMBEDDING.md` (the two marker
   blocks, a "Choosing parts" paragraph, the generator command), `README.md`
   and `docs/README.md` (a link to `docs/decisions/`), `docs/ROADMAP.md`
   (this record).
9. Status: implemented 2026-11-15 under core decisions 18 and 19: the tooling,
   43 unit tests, no Kit split yet, bundles byte-identical to before; the
   release `manifest.json` stays schema 1, with `parts` added only where a
   Kit declares them; ADRs 0001 to 0004 in `docs/decisions/`.

**Lua limits gate and version check (architecture plan items 1 and 2)** — repository tooling, no facade

1. Two repository gates under core decision 18, in the tooling:
   `tooling/validation/lua_limits.py` with its ratchet file
   `tooling/validation/lua_limits.json`, and a manifest-against-CHANGELOG
   version check in `tooling/validation/validate_repository.py`. The second
   replaces the version-string pins of 14 `Manifest_spec.lua` files.
2. Purpose. Lua 5.1 allows 200 active locals and 60 upvalues per function,
   and nothing measures either today: CommKit and CommandKit sit at 198 of
   200 main-chunk locals, which nobody could see until the architecture
   diagnosis counted them (the diagnosis prototype 2.2, 5.4). The
   gate turns that into a number at review time and holds every file to it.
   Separately, 14 specs pin the SemVer string, so every documentation patch
   edits a spec, while the invariant the pin was after (the manifest version
   is the one the changelog releases) is checked nowhere (5.5). Non-goals:
   splitting any file (that is decision 19a's work, which this gate then
   watches); a revision-against-tag history check (later, once tags exist).
3. Dependencies: `luac` from the Lua 5.1.5 toolchain the CI action
   `.github/actions/setup-lua` already builds (hererocks) and
   `docs/DEVELOPMENT.md` installs locally; Python standard library.
4. Surface.
   - `python3 -m tooling.validation.lua_limits [--update] [paths...]`
     compiles every runtime Lua file (`packages/*/src/**/*.lua`, parts
     included) with `luac -p -l -l` and measures, per function: peak active
     locals (the quantity the 200 limit counts; the prototype is calibrated
     so a file at the limit reports exactly 200), upvalues, and constants
     (reported only). Rules: a main chunk above **190** active locals fails,
     above **180** warns; any other function above **190** locals or above
     **50** upvalues fails. A file already over a fail line is allowed only
     at the value its ratchet entry records. The ratchet can only go down: a
     measured value above its entry fails, a value below its entry fails
     with "lower the entry" (so an entry always equals the measurement and
     a raise can never pass unseen), and an entry for a file under the fail
     line fails as stale. `--update` rewrites the entries to the measured
     values and refuses to raise any. Output names the file, the function's
     line, the value, the limit and the headroom left.
   - Ratchet at the start (measured 2026-11-15): CommKit 198, CommandKit 198,
     SettingsKit 196, ModuleKit 195, SchedulerKit 194, EventKit 191 (main
     chunk). Warnings: WidgetKit 189. No function exceeds the per-function
     lines (largest: SchedulerKit `installCoalescingFamily` at 2317, 111
     locals and 43 upvalues; next upvalues WidgetKit and SettingsKit 25).
   - CI: a new `limits` job in `.github/workflows/ci.yml` (checkout, the
     `setup-lua` action, the command), added to the `ci` summary job's
     `needs`. The repository job has no Lua, so it does not run there.
   - Version check in `validate_repository`: for every package, the manifest
     `version` equals the version of the first `## <version> — <date>`
     heading of its `CHANGELOG.md`, and that date is not later than today
     (UTC). All 41 packages pass today.
   - The 14 pins (barKit, bindingKit, brokerKit, compatKit, dialogKit,
     editModeKit, glowKit, launcherKit, menuKit, panelKit, rangeKit,
     tooltipKit, toastKit, unitFrameKit) become the shape assertion mediaKit
     already uses, `'"version"%s*:%s*"%d+%.%d+%.%d+"'`: one line per file,
     nothing else in those specs touched, so spec counts stay the same.
5. Ownership: the ratchet file is data the gate owns; a contributor changes
   it only through `--update` after making a file smaller.
6. Performance and memory: no runtime effect. The gate compiles 45 files;
   expected run time under 5 seconds locally. Headroom becomes visible:
   CommKit and CommandKit 2 locals, SettingsKit 4, ModuleKit 5,
   SchedulerKit 6, EventKit 9. Documentation-only patches no longer edit a
   spec (14 specs freed of a pin).
7. Tests (`tooling/tests/test_lua_limits.py`, `test_validate_repository.py`):
   the parser on real `luac -l -l` output (peak, a zero-length local, nested
   functions, upvalue counts); calibration (a generated file of 196 locals
   plus a numeric `for` reports 200 and compiles; 197 fails to compile);
   each rule (warn, fail, ratchet held, ratchet lowered, ratchet stale,
   `--update` never raises); the gate green on the repository; the version
   check accepting a match and refusing a mismatch, a missing heading and a
   future date. Every package suite still passes after the pin edits.
8. Docs: `docs/TOOLING.md` (the gate, the thresholds and why, the ratchet,
   the version rule); `docs/decisions/` is covered by the Kit parts record.
   Shared files, exact text in the phase 2 report: `docs/ROADMAP.md` (this
   record), `docs/CONTRIBUTING.md` if it lists the gates (`python3 -m
   tooling.validation.lua_limits`).
9. Status: implemented 2026-11-15: the `lua_limits` gate (21 unit tests, CI
   job `limits`, ratchet `tooling/validation/lua_limits.json`); the 14
   version pins in Manifest specs replaced by the manifest-against-
   CHANGELOG check.

**addonKit** — facade `AddonKit`, entry point `MoltenCodes:For(...)`

Status: recorded 2026-11-15 under core decisions 18 and 19; code follows.

Basis: the decision 18 usability diagnosis (the ten-task comparison and a
prototype entry point run against the fake client) and the repository's
Registry, ModuleKit, SettingsKit, SchemaKit, CommandKit, PanelKit,
LauncherKit and BrokerKit references.
Ace3 `AceAddon-3.0.lua:493-579` (module enable and disable order) read at
`ac3d122`, BSD-style licence (`LICENSE.txt`), for behaviour only; nothing
copied.

1. Package `addonKit`, facade `AddonKit`, API generation 1, version 0.1.0,
   implementation revision 1. Optional: no Kit depends on it, and an addon
   that does not embed it loads nothing of it and pays nothing.

2. Purpose: one obvious way in for addon authors, so a first addon takes
   the lines and concepts Ace3 takes or fewer, while every guarantee of the
   Kits underneath stays. It holds no behaviour of its own beyond lookups,
   defaults and fix-it errors: every call it makes is a documented API 1
   call of another Kit, so validation, bounds, secret checks and ownership
   stay the Kits'.

   - **Entry point.** `local MC = MoltenCodes:For(...)` in every file of an
     addon returns that addon's facade (the same table in every file).
     `MC.TimerKit`, `MC.EventKit` and so on resolve on first read through
     `Registry:Find(packageId, generation)` and are cached on the facade
     with `rawset`, so a later read is a plain field read. `MC.S` is
     SchemaKit; `MC.Registry` is `MoltenCodes.Registries[2]`.
     `MC.addonName` is the folder name. The second value of `...` (the
     addon's private table) is accepted and ignored, so `...` can be passed
     as it is.
   - **Where `For` lives (decided here).** AddonKit installs `For` on the
     shared `MoltenCodes` namespace, and the same function is
     `AddonKit:For`. Registry is not touched. Reasons: Registry sits at its
     1000-line budget and its header says new behaviour moves into a
     package of its own; Registry is loaded by every addon that embeds any
     Kit, so a catalogue there would cost addons that never use it; and the
     catalogue changes with every new Kit, which would put Registry
     revisions on every Kit addition. The namespace key is claimed by a
     small protocol: AddonKit writes `MoltenCodes.For` only when it is
     absent or is the stable entry function recorded in `AddonKit._state`;
     an upgraded revision keeps that same function, which dispatches through
     the state, so the newest revision serves every addon. Any other value
     is left alone and reported once through `geterrorhandler()`;
     `MoltenCodes.Registries[2]:Get("addonKit", 1):For(...)` then remains
     the documented one-line alias. The key is reserved in Registry's
     documentation (text in the report).
   - **Generations stay explicit.** The catalogue maps each facade name to
     its package ID and the API generation AddonKit API 1 hands out. An
     entry's generation never changes inside AddonKit API 1; new Kits only
     add entries, and a Kit's next generation is reached with
     `MC:Use("TimerKit", 2)` (before the first read of that name; a pin
     after a read at another generation raises) or by a later AddonKit
     generation. An addon therefore never receives a contract it was not
     written against, even when another addon embeds a newer AddonKit
     revision. A spec reads every `package.manifest.json` and fails when the
     catalogue misses a package or names a generation that does not exist,
     and fails when a published entry's generation changed, against a
     recorded baseline in the spec.
   - **Fix-it errors at the author's line.** A facade name that is not in
     the catalogue raises `MoltenCodes has no Kit named <name>; did you
     mean MC.TimerKit?` (case-insensitive match, a missing `Kit` suffix, or
     an edit distance of at most 2 over catalogue and method names, so a
     misspelt method gets `did you mean MC:Database?`). A Kit that is not
     loaded raises `MyAddon uses MoltenCodes TimerKit (API 1), which is not
     loaded. Add timerKit\TimerKit.lua to embeds.xml after the files it
     needs, or rebuild embeds.xml with the build tool (docs/EMBEDDING.md,
     "Load order")`; the `generation_mismatch` and `retired` reasons of
     `Find` get their own wording. A write to the facade (`MC.db = x`)
     raises `the MC facade holds Kits and helpers only; keep your fields on
     your addon object`. A dot call (`MoltenCodes.For(...)`, `MC.Database(...)`)
     raises with the colon form. Helpers that call another Kit run the call
     under `pcall` and raise its message again at the author's line with
     AddonKit's own position removed, so the line printed is always the
     author's.
   - **Addon object.** `MC:NewAddon(definition?)` is the module `"Main"` of
     the addon's ModuleKit container (`ModuleKit:ForAddon(name)
     :CreateModule("Main", definition)`), not a wrapper: `OnInitialize` runs
     at the loaded phase, `OnEnable` at ready, `OnDisable` on `Disable()`
     and at logout, and `self.scope.Events`, `.Timers`, `.Hooks`,
     `.Commands`, `.Comm`, `.Jobs`, `.Messages` own what the addon
     registers, released on disable. A second `NewAddon` raises with the fix
     (`MC:GetAddon()` or `MC:NewModule(name)`). `MC:NewModule(name,
     definition?)` creates a module that declares `DependsOn("Main")`, so,
     as AceAddon does (`AceAddon-3.0.lua:516-579`), the addon initializes and
     enables before its modules and disabling it disables them; the name
     `"Main"` is refused. `MC:GetAddon()` and `MC:GetModule(name)` answer
     the objects from other files. No mixin methods are added: ModuleKit's
     module metatable stays ModuleKit's, and the addon object is a plain
     receiver, so the method-name callbacks of decision 19c work on it as
     they come from the runtime Kits (for example
     `self.scope.Events:Connect("BAG_UPDATE", self, "OnBagUpdate")`, in
     whatever form the runtime Kits' records fix). The guide, cookbook and
     specs use that form where the loaded revisions support it, detected
     from each Kit's documented capability, and the closure form otherwise.
   - **Database.** `MC:Database(savedVariable, defaults, options?)` opens a
     SettingsKit database from an AceDB-style defaults table, the schema
     inferred: a boolean, number or string becomes `optional(type,
     value)` (strings get `max = 4096`; numbers are not made integers, so
     `scale = 1` accepts 1.5); a table becomes an optional record; `{}`
     becomes a bounded free-form bag (`map` of string or number keys to
     `any`, `max = 1024`); `["*"]` becomes a `map` whose values read the
     wildcard's defaults, as AceDB's do; an array of one primitive type
     becomes an `array` of that type; a SchemaKit node or sealed schema
     written inline passes through, made optional when it is not. Two
     shorthands make ranges and enums one call: `MC.Range(min, max,
     default)` and `MC.Enum(values, default)` return the optional nodes.
     The top-level keys are SettingsKit's scopes (`profile`, `global`,
     `char`, `realm`, `class`, `faction`); `options` is `SettingsKit:Open`'s.
     It refuses, with the fix: a call before the addon's `ADDON_LOADED`
     (`MyAddon opened MyAddonDB before ADDON_LOADED; open it in
     OnInitialize, after the client restored it`), through LifecycleKit's
     `IsLoaded`; an AceDB scope SettingsKit does not have
     (`factionrealm`, `locale`), naming the six it has; `["*"]` beside named
     keys and `["**"]` (no SettingsKit form: the message says to move the
     named keys or write a schema node); a `nil`-shaped or function default;
     a non-string key in a record. A second call for the same saved
     variable answers the same database when given the same defaults table
     and raises otherwise (SettingsKit refuses a second schema for an open
     name; the inferred one would always be new).
   - **Options.** `MC:Options(tree, { db, slash, title })` defines the tree
     with OptionsKit (`db` for `bind`), registers it with PanelKit and, with
     `slash`, registers a CommandKit command on the addon's scope that opens
     the panel; it returns the panel. Unlike the prototype it does not drop
     CommandKit's refusals: `"taken"`, `"emote"` and `"full"` raise at the
     author's line with the fix (`/myaddon is already used by another addon
     or a chat command; pass another slash name to MC:Options`). The command
     is registered first, so a refusal leaves no tree and no panel; a
     failure of `Define` or `Register` after it unregisters the command
     before raising.
   - **Launcher.** `MC:Launcher(definition, db, field?)` creates a BrokerKit
     object named after the addon (`type = "launcher"` unless given),
     registers a LauncherKit button whose storage is `db.profile[field]`
     (`field` defaults to `"minimap"`) and refreshes it on
     `db:OnProfileChanged`; it returns the launcher. It checks with
     `db:Validate` that the profile declares the field and otherwise raises
     `declare minimap = MC.LAUNCHER_DEFAULTS in defaults.profile`.
     `MC.LAUNCHER_DEFAULTS` is LibDBIcon's three fields (`hide = false`,
     `lock = false`, `minimapPos = 225`), a fresh table per facade so one
     addon editing it never changes another's.
   - Non-goals: Ace-style mixins (`self:RegisterEvent`) on the addon
     object, a second options or database implementation, LibStub
     emulation (BridgeKit's), generating `embeds.xml` (the tooling's
     F6), and strict module scopes (a ModuleKit addition, below).

3. Dependencies: registry API 2, required, and nothing else required.
   Optional, found at call time through `Registry:Find` and declared under
   `optionalDependencies` (API 1 each): moduleKit and lifecycleKit (addon
   object, database gate), schemaKit and settingsKit (database), optionsKit,
   panelKit and commandKit (options), brokerKit and launcherKit (launcher).
   Every other Kit is reached only when the author reads `MC.<Kit>`. A
   helper whose Kit is missing raises the same "not loaded" message as a
   read. No host API is called by AddonKit itself, so the flavour gate has
   nothing to guard; the Kits it calls guard their own.
   Parts (decision 18a): the core file `src/AddonKit.lua` holds the
   namespace entry, the catalogue, the lazy lookup, the errors, `Use` and
   the addon object. Two part files hold the rest: `Database.lua` (schema
   inference, `Database`, `Range`, `Enum`) and `Composition.lua`
   (`Options`, `Launcher`, `LAUNCHER_DEFAULTS`), in the runtime
   subdirectory layout `docs/PACKAGE_MANIFEST.md` describes; the exact
   directory and how a part is declared optional follow the Kit parts
   format (the tooling record above). A part installs its methods into
   `AddonKit._state.parts` under its own revision check, so an upgraded
   part takes over. A method of a part that is not loaded raises
   `MC:Database is in AddonKit's Database part, which is not loaded: add
   addonKit\...\Database.lua to embeds.xml`. Until the tooling can mark
   parts optional, the build loads them always, as runtime subdirectories
   are loaded today.

4. Surface:
   - `MoltenCodes:For(addonName, ...)` and `AddonKit:For(addonName, ...)`
     → facade (`MoltenCodesFacade`); `addonName` a non-empty string, not
     secret, raised at the caller otherwise.
   - Facade fields: `MC.addonName`, `MC.<Kit>` for every catalogue name,
     `MC.S`, `MC.Registry`, `MC.LAUNCHER_DEFAULTS` (Composition part).
   - Facade methods: `MC:Use(facadeName, generation)`; `MC:NewAddon(definition?)`,
     `MC:NewModule(name, definition?)`, `MC:GetAddon()`,
     `MC:GetModule(name)`; `MC:Database(savedVariable, defaults, options?)`,
     `MC.Range(min, max, default)`, `MC.Enum(values, default)`;
     `MC:Options(tree, options)`, `MC:Launcher(definition, db, field?)`.
   - Package facade: `AddonKit:For`, `AddonKit:GetCatalogue()` (a fresh
     `{ [facadeName] = { packageId, api } }` copy, for tools and
     diagnostics), `AddonKit:SetLimits{ maxFacades }` / `GetLimits()`,
     `API`, `REVISION`. `maxFacades` (addons with a facade in the session)
     defaults to 256 with a ceiling of 4096 and no `UNBOUNDED`; past it
     `For` raises with the `SetLimits` fix.
   - LuaCATS: `MoltenCodesNamespace` gains `For`; `MoltenCodesFacade` has
     one `---@field <Kit> <Kit>` per catalogue entry (the Kits' own class
     names, all present today), the methods above with full parameter and
     return types (`NewAddon` → `AddonKit.Addon`, a `ModuleKit.Module` with
     a `db` field slot; `Database` → `SettingsKit.Database`), so
     lua-language-server completes `MC.TimerKit:ForAddon(...)` and flags
     a misspelt `scope:After`, as the language-server probe of the
     diagnosis measured. The field block
     disables `undefined-doc-name` locally, because AddonKit's own
     workspace holds only Registry; an addon's workspace holds the Kits it
     embeds.

5. Ownership: the facade of an addon lives for the session in
   `AddonKit._state.facades` (one per addon name, bounded by
   `maxFacades`). It holds cached references to shared Kit tables, which
   Registry's stable-reference guarantee keeps valid across in-place
   upgrades, never a copy. Methods are not cached on the facade: they are
   found through the state's metatable on each call, so an upgraded revision
   serves addons that took their facade earlier. Everything the addon
   object, a database, a panel, a command or a launcher owns belongs to the
   Kit that created it (ModuleKit, SettingsKit, PanelKit, CommandKit,
   LauncherKit) under that Kit's rules; AddonKit keeps one record per
   opened database on the facade (saved-variable name, defaults table,
   database) to answer a repeated `Database` call. An upgraded revision
   takes over the facades, the metatable's `__index` and `__newindex`
   (stable closures in `_state` dispatching through a table), the namespace
   entry and the parts.

6. Performance and memory: no frame, no event, no timer, nothing per frame.
   After the first read, `MC.<Kit>` is one table field read: zero cost per
   call against a hand-written local. Method calls on `MC` go through one
   `__index` function call; they are setup-time calls. Schema inference
   runs once per `Database` call and allocates only the nodes SettingsKit
   needs anyway; the database's own cost is SettingsKit's (and shrinks with
   SchemaKit's sparse nodes). The catalogue is kept compact (one
   string-keyed table of facade name to generation, the package ID derived
   by lower-casing the first letter and the file path built only when an
   error needs it).
   Expected numbers, from the prototype and the diagnosis prototype (host
   Lua 5.1.5, debug info kept, measured 2026-11-15):

   | Measure | Ace3 | MC today | Prototype | AddonKit target (phase 2 measures) |
   |---|---:|---:|---:|---:|
   | Ten tasks, code lines | 62 | 84 | 55 | 55 or fewer |
   | Concepts for the ten tasks | 16 | 25 | 15 | 15 |
   | Resident, entry point and addon object | AceAddon 27.0 KB (+ LibStub 2.6 KB) | 0 (no facade) | 25.6 KB (without inference) | at most 24 KB, core file |
   | Resident, defaults-to-schema | AceDB 33.0 KB | 0 | 4.8 KB | at most 8 KB, Database part |
   | Resident, options and launcher helpers | AceConsole 10.5 KB + AceConfig family | 0 | included above | at most 8 KB, Composition part |
   | Resident, all of AddonKit | 73.1 KB (AceAddon, AceDB, AceConsole, LibStub) | | 30.4 KB | at most 40 KB |
   | Per addon using the facade | | | one table | at most 1 KB plus one field per Kit read |
   | Cost per `MC.<Kit>` read after the first | | | one field read | one field read |

   The prototype's 25.6 KB is mostly its catalogue (three strings and a
   table per Kit); the compact catalogue is what brings the core under the
   target despite the Bootstrap, state validation and limits a real Kit
   adds. Phase 2 measures each file and the per-addon cost with the same
   script and reports them against the rows above. The ten-task line count
   is re-counted with the diagnosis prototype.

   Mistakes a newcomer makes, before and after (messages measured by the
   prototype's specs; phase 2 asserts each):

   | Mistake | MC today | AddonKit |
   |---|---|---|
   | Kit missing from `embeds.xml` | `attempt to index local 'TimerKit' (a nil value)` at first use | names the Kit, the file to add and the rebuild, at the reading line |
   | Misspelt Kit name | `packageName must match ^[a-z][A-Za-z0-9]*$` | `did you mean MC.TimerKit?` |
   | Wrong generation typed | the same `nil` index error | not typed by the author; `Use` checks a pin |
   | AceDB-style defaults passed to the database | refused, schema node required | accepted, schema inferred |
   | Database opened at file scope | no error, saved data lost | raised with the fix |
   | Slash name already taken | `nil, "taken"`, easy to drop | raised with the fix |
   | Minimap storage not declared | write refused and reported later | raised at `MC:Launcher` with the fix |

7. Tests (Busted, `packages/addonKit/tests/`, coverage at least 96%):
   Bootstrap (first load, same revision, in-place upgrade from a revision 1
   copy keeping facades, cached Kits, the namespace entry and the parts; a
   foreign `MoltenCodes.For` left alone and reported; a newer copy loaded by
   a second addon serving the first addon's facade); Manifest (package,
   API, revision, optional dependencies); Catalogue (against every
   `package.manifest.json`, and the generation baseline); Arguments (every
   public call's argument errors and their levels, the `__index` and
   `__newindex` errors at the reading or writing line, dot calls, secret
   values first on every argument); Lookup (lazy resolution, the cache,
   every `Find` reason, did-you-mean for Kits and methods, `Use` before and
   after a read, `maxFacades`); Addon (NewAddon, NewModule with the Main
   dependency and Ace's order, GetAddon, GetModule, a second NewAddon, the
   `"Main"` name refused, method-name callbacks through the scope when the
   runtime Kits provide them); Database (every inference rule, `"*"` reads,
   `{}` bags, arrays, inline nodes, `Range`, `Enum`, wrong-type and
   out-of-range writes refused with SettingsKit's message, the
   `ADDON_LOADED` gate, unsupported scopes and wildcards, the repeated
   call); Options (panel, slash command opening it, each refusal raised,
   nothing left behind on a refusal or a later failure); Launcher (button,
   storage, profile switch refresh, the undeclared-field error); Parts (a
   missing part's message); TenTasks (the prototype's ten-task smoke flow
   over a fixture addon, every task checked); Guide (the final code of the
   getting-started guide runs on the fake client, and each guide snippet
   tagged with a fixture file must equal it; pending until the guide is
   placed in `docs/`); LuaLS (the fixture addons pass
   `lua-language-server --check` at Warning with no diagnostic, and a
   misspelt scope method in a probe file is flagged). A client suite
   `tests/client/MoltenCodesTest_AddonKit` (.toc, suite, EXPECTED.md),
   never run: `MoltenCodes:For` in the real client, the error level through
   `__index` (verified only on host Lua so far), the database gate against
   the real `ADDON_LOADED` and saved variable, the panel opened by the
   slash command, the minimap button placed and kept across a profile
   switch.

8. Docs: `packages/addonKit/README.md` with a "First addon in 10 minutes"
   section (the `.toc`, `embeds.xml`, the eight-line addon, then database,
   options, slash command and launcher, each a step) and a migration table
   from AceAddon-3.0, AceDB-3.0 defaults, AceConfig with AceConsole and
   LibDBIcon-1.0; `docs/API.md`; `CHANGELOG.md`; `tests/README.md`;
   `INTERNALS.md` (state, dispatch, the namespace protocol, parts). Drafts
   for the shared docs:
   `GETTING_STARTED.md` (about 200 lines, ending in exactly the TenTasks
   fixture, every snippet run by the Guide spec) and `COOKBOOK.md` (one
   5-to-15-line recipe per common task: the ten tasks plus bucketed events,
   a window, a confirmation dialog, a tooltip, migrations, spec profiles,
   each linking to the Kit's API). Text for the shared documents: ROADMAP
   placement of this record, ARCHITECTURE's package list, EMBEDDING rows,
   `packages/README.md` row, the README hero snippet and link,
   `docs/README.md` map entries, MIGRATING_FROM_ACE3 "Before you start",
   `meta/MoltenCodes.lua` (`For` on the namespace class), the coverage
   floor, spell words, and a sentence for `registry/docs/API.md` reserving
   the `For` key (Registry's package).

9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.1.0,
   revision 1, parts Database and Composition revision 1, 72 specs (98.0%
   line coverage); the client suite
   (`tests/client/MoltenCodesTest_AddonKit`) is written and has not been run
   in a client. Deviations: resident memory measured 40.6 KB (core), 17.7 KB
   (Database), 9.8 KB (Composition), 68.1 KB in all, against targets of 24,
   8, 8 and 40 KB set from a prototype without Bootstrap, state validation,
   limits or suggestions; still below AceAddon, AceDB and AceConsole
   together (70.6 KB, same session). A facade costs about 450 bytes per
   addon. lua-language-server checks calls through the facade, a Kit and a
   database; a call chained straight through the addon object
   (`self.scope.Timers:After`) is not checked, because the addon object
   accepts the author's fields. `docs/GETTING_STARTED.md` and
   `docs/COOKBOOK.md` ship with it, the guide's code checked by a spec.

Settings records (settingsKit, schemaKit, optionsKit, commandKit), basis: the
decision 18 settings and memory diagnoses (prototypes measured against Ace3
in the same host benchmark run, Lua 5.1.5). "Measured" means a prototype
run; "estimate" means priced from measurements, not run.

Client facts used, read 2026-11-15 from Gethe/wow-ui-source
`Blizzard_APIDocumentationGenerated/UnitDocumentation.lua`:

- `UnitNameUnmodified(unit)` → `unitName, unitServer`, both strings, not
  nilable: `live` 12.1.5 (70783) line 2434 (with
  `SecretWhenUnitIdentityRestricted = true`), `classic` 5.5.4 (70631) line
  1456, `classic_era` 1.15.9 (70576) line 1456. Also in this repository's
  `packages/apiKit/metadata/{retail,classic-mop,classic-era}/namespaces.json`.
- `UnitName` on `live` carries `SecretWhenUnitNameIdentityRestricted = true`
  (line 2400).
- warcraft.wiki.gg `API_UnitNameUnmodified` (redirects to `API_UnitName`):
  `UnitName` reports a changed name under effects such as the Lifegiving Seed effect,
  "`UnitNameUnmodified()` is unaffected by this".
- `RegionalUniqueNamesEnabled()` → `bool` exists only on the `forever` branch
  (1.60.1, 70938, line 536); it is absent from `live`, `classic` and
  `classic_era`. WoW Forever (interface 1.60.x) is not in
  `tooling/validation/supported_clients.json`.
- AceDB-3.0 (BSD-style licence, read only, nothing copied): at `5e2e0d3`
  (`AceDB-3.0.lua:263-282`) it keys characters by `UnitNameUnmodified`, and
  between interface 16000 and 19999 by name, surname and ruleset; at the
  current upstream head `ac3d122` the test is `RegionalUniqueNamesEnabled()`
  and the key is `name .. " " .. surname` with the ruleset as realm key.

---

**settingsKit read-through views, lazy Open, client-refused secret probes removed** — a change to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.5.0 (from 0.4.2), implementation revision 14 (from 13), node
   layout 4 (from 3).
2. Purpose: a `db.profile.x` read costs what AceDB's does, `Open` costs no
   more than AceDB's in memory, and a write costs only what its validation
   needs. Five changes:
   a. **Read-through chains** (perf-settings fix 1, prototype B). Each record
      view keeps its empty proxy (so every write still reaches `__newindex`
      and is validated at the writer's line) but gets its own metatable whose
      `__index` is a table: `proxy → shadow (the child views of record
      fields, only for records that have some) → saved table (given a
      SettingsKit metatable) → scalar defaults`. The VM answers a read with no
      Lua call. A keyed section whose every key answers with an entry view
      reads through its entry cache, with the function path on a miss. The
      function path (`viewIndex`) stays for what a chain cannot answer: a
      saved table with a foreign metatable, a record without a default stored
      as a scalar, and a view with a plain-table default (`READ_COPY`) not yet
      stored (the view reads through `viewIndex` until every such key has its
      copy, then is bound to its chain; a read-only database keeps the
      function path for such a view, so a raw read never stores anything,
      `Getter_spec.lua:209`). The chain record is folded into the proxy's
      metatable (fields beside `__index`/`__newindex`/`__metatable`), and the
      saved-table metatable and defaults table are shared per plan when the
      view's defaults are its plan's own. Chains are rebound by one helper
      called at the end of every mutating method, after the mutation (never
      before: the prototype rebound `Compact` before removing tables and wrote
      into a detached table); a table write rebinds only the written view's
      subtree. The generation scheme stays underneath (writes, `Pairs`,
      `Validate` and getters made by revisions 7 to 13 resolve through it).
      `scanValue` accepts a table carrying SettingsKit's saved-table marker.
   b. **Decision 19b: the read-side secret-key probes are removed** from
      `viewIndex` (`SettingsKit.lua:2033-2039`) and `databaseIndex`
      (`3561-3566`). On the client a secret key raises before `__index` runs
      (docs/EMBEDDING.md "Measured on the client", Retail 12.1.0 b69933), so
      the probes could never fire there. A read with a secret key now raises
      the client's own error, "attempted to index a table that cannot be
      indexed with secret keys", at the reading line; SettingsKit's messages
      "... cannot be read with a secret key" and "SettingsKit databases cannot
      be read with a secret key" are gone. `viewIndex` keeps the `type(value)`
      test (no new exception to the repository rule is needed: the chain does
      the hot read). Every other secret check stays: write keys and values,
      `Getter`, `Validate`, `Compact`, profile names, scope names, client
      answers.
   c. **Lazy Open** (fix 4, prototype C, completed). A scope root is built by
      `databaseIndex` on the first `db.<scope>` read, a view's probe table by
      its first full check. Every site that read `rawget(db, scopeName)`
      goes through one root accessor: `Getter`, `Validate`, `Pairs`,
      `SetProfile`'s republication of `db.profile`, spec profiles, `Compact`
      and the upgrade path (the prototype missed `Getter`, `Validate` and spec
      profiles: 21 spec failures). Record children stay eager when their
      parent is built, because the shadow must hold them. **Layout sections
      stay eager**: `docs/API.md` *The saved table* promises that `Open`
      creates every missing section in a writable database and lets other
      code read the layout, so the prototype's lazy layout is not taken (it
      would save about 1.5 KB and 250 instructions on a new saved variable
      only).
   d. **Non-allocating depth limit** (fix 5): `depthAllows` and
      `readMaxDepth` read `SchemaKit:GetLimit("maxDepth")` (schemaKit record
      below) and keep the depth-probe check as the fallback for a SchemaKit
      revision without it. `SetLimits` still applies at once.
   e. **Fused scalar write path** (fix 8): one function for the common write
      (a verified record view, a non-table value, a field with a compiled fast
      check): read-only and detached tests, the value's secret probe, the fast
      check, the store, the signal. Everything else takes the current path.
      Messages and error levels unchanged.
   f. **Character key from `UnitNameUnmodified`** (ace3-gaps side finding):
      `readScopeKeys` asks `UnitNameUnmodified("player")` first and falls back
      to `UnitName("player")` when it is absent or its answer is not usable
      (secret, empty, not a string), so no client that has a key today loses
      it. The two answer alike except under a name-changing effect, where
      today's key is the effect's name, so existing saved data keeps its key.
   g. **`db:Getter` becomes a thin closure over the chain**: bound to a view,
      `return proxy[key]`; following a scope, `return db[scopeName][key]`.
      Its argument checks and the key's secret probe at creation stay. A call
      cannot cost less than the plain read it performs plus one Lua call;
      that floor is the target. Getters made by revisions 7 to 13 keep their
      closures and keep working (the generation scheme stays). The docs say
      a plain read is now the hot-loop answer and `Getter` is for handing a
      reader around.
   Non-goals: lazy layout sections (above), lazy record children under
   chains, splitting views or spec profiles into a part file (decision 18a,
   a later package O record), WoW Forever's regional unique names (not a supported client; see
   the report), a plan built from SchemaKit's compiled nodes instead of
   `Describe` copies (not measured).
3. Dependencies: registry API 2, schemaKit API 1 (uses `GetLimit` when
   present, falls back without it), signalKit API 1, eventKit API 1 optional;
   all unchanged. Host: `UnitNameUnmodified` added, guarded
   (`type(...) == "function"`), its answer checked with `issecretvalue`
   first; `UnitName` stays as the fallback.
4. Surface: no new method on databases or views. `SettingsKit:GetCharacterKey()`
   → `string|nil`, the `char` key `Open` would use now (an addition so
   BridgeKit computes the same key instead of repeating the rule; the maintainer's
   call, see the report). Behaviour changes, all in CHANGELOG and
   `docs/API.md`: (i) raw saved tables reachable from an open database carry
   a SettingsKit metatable, so `MyAddonDB.profiles.Default.scale` read
   directly answers the default instead of `nil`, as with AceDB; `rawget`,
   `next` and `pairs` are unaffected, nothing on disk changes (the client
   saves no metatables), a table that leaves the tree keeps the harmless
   metatable; (ii) a table assigned through a view gets that metatable;
   (iii) a secret key read raises the client's error (19b); (iv) the `char`
   key row of *The saved table* names `UnitNameUnmodified` with the
   `UnitName` fallback.
5. Ownership: chain metatables, shared per-plan saved metatables and defaults
   live in `state` (weak-keyed where they hang off views), not in file
   locals, so a later revision rebinds them. In-place upgrade from revision
   13: every live view in `state.views` gets its chain; the old shared
   `VIEW_METATABLE` is protected by `__metatable`, which SettingsKit owns, so
   the upgrade clears that field, sets each live proxy's new metatable and
   restores it; databases opened by revision 13 keep their eagerly built
   roots; rebinding then runs once per database. Getters and listeners of
   revision 13 keep working.
6. Performance and memory (host Lua, bench, against AceDB in the same run):

   | Case | Today (rev 13) | Expected | Basis |
   |---|---|---|---|
   | read-default | 29.6x | 3.6x | measured, prototype D |
   | read-saved | 29.8x (33 instructions) | 2.8x (2 instructions, as AceDB) | measured, D |
   | read-nested | 35.9x | 2.1x | measured, D |
   | read-entry-default | 41.6x | 2.3x | measured, D |
   | read-getter | 2.56x (39 ns) | about 1.5x (20 to 25 ns; floor 15.8 ns per call) | estimate from `Floors.lua` |
   | open-empty | 4.87x, 8.3 KB | 2.3x, 2.6 KB (AceDB 3.3 KB) | measured, D (D had lazy layout: add up to 1.5 KB here, estimate) |
   | open-populated | 2.57x, 7.7 KB | 2.8x, 8.4 KB in D; 2.0x or less with per-plan sharing | D measured; sharing an estimate |
   | retained per open DB (AceDB 3 872 B) | 7 192 B | 7 880 B in D; about 5 KB with sharing (400 to 600 B per view) | D measured; sharing an estimate |
   | switch-profile | 0.24x | 0.21x (stays faster than AceDB) | measured, D |
   | write-scalar | 53x (146 instructions) | about 25x (about 70 instructions) | estimate (fix 8) |
   | write-nested | 177x (324 instructions) | 93x (169) measured with the depth read; about 60x with the fused path | C measured; fused an estimate |

   No allocation on a read or a write. Rebinding allocates nothing; building
   a view allocates its metatable (and, without sharing, its defaults and
   saved metatable). "Open below AceDB": in memory yes for a new saved
   variable without reads; in time no (2.3x), the remainder is validation,
   scope keys and plan lookup.
7. Tests: chains for every read kind (default, saved, nested, keyed entry,
   wildcard default, detached view, read-only database, foreign metatable,
   scalar stored where a record is declared, `READ_COPY` before and after its
   copy, read-only `READ_COPY`), rebinding after every mutating method
   (`SetProfile`, `CopyProfile`, `ResetProfile`, `DeleteProfile`,
   `ResetDatabase`, `Compact` including logout, `Resync`, table writes, spec
   switches), a mutation that raises halfway; the nine specs prototype B
   fails, resolved: raw inspections through `rawget` (`Writes_spec.lua:85`,
   `:182`), `Aliasing_spec.lua:44` asserting SettingsKit's marker instead of
   no metatable, the three secret-key read specs rewritten to assert no
   SettingsKit probe and no SettingsKit message (`Aliasing_spec.lua:259`,
   `Writes_spec.lua:331`, `Defaults_spec.lua:122`), `Getter_spec.lua:209`
   (failing first), and the upgrade specs (`Bootstrap_spec.lua:79`,
   `Caching_spec.lua:338`) with an upgrade from revision 13 rebuilding live
   views; lazy roots through `Getter`, `Validate`, `Pairs`, spec profiles
   and `Compact` before any read; `Open_spec.lua:15` unchanged (layout
   stays eager); `Allocation_spec.lua` (nothing on reads and writes, the
   root's cost on its first read); the depth read with and without
   `GetLimit` and after `SetLimits`; the fused write's messages and levels;
   the character key from `UnitNameUnmodified`, the fallback when absent,
   secret or empty; `GetCharacterKey`; getters of revision 13 after the
   upgrade. Client suite (never run): `db.profile[secret]` and `db[secret]`
   raise the client's "cannot be indexed with secret keys" at the reading
   line, before any SettingsKit code; `GetCharacterKey()` equals
   `UnitNameUnmodified("player") .. " - " .. GetRealmName()`.
8. Docs: README (reads cost what AceDB's do; migration table rows for raw
   reads and `UnitNameUnmodified`), `docs/API.md` (*Host facilities* row for
   `issecretvalue` loses reads, *The saved table* `char` row, *Reads*, *Views
   hold their saved tables*, `db:Getter`, *Error behaviour* messages removed,
   *Performance* table, revision 14 under *Embedded copies and upgrades*),
   `docs/INTERNALS.md` (the chain, its rebinding rule, node layout 4, the
   upgrade), CHANGELOG, `tests/README.md`, the client suite's `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.0,
   revision 14, node layout 4, 298 specs (25 new in `ReadThrough_spec.lua`).
   Recorded deviations: record field views are built on their first use too (a
   pending proxy each, which the shadow holds), not with their parent; a
   record view whose plain-table default is not stored yet reads through the
   function path while its saved table exists (a direct read of the saved
   table must never store a copy) and through a tail of its own while nothing
   is saved; a database creates `_signals` with its first profile listener, so
   two scopes keep it to 16 fields. Measured on host Lua 5.1, each against
   AceDB-3.0 in its own run: read-saved 31.7x to 2.8x, read-default 29.3x to
   3.7x, read-nested 34.4x to 1.9x, read-entry-default 40.2x to 1.9x, read-
   getter 2.5x to 1.65x, write-scalar 53x to 35x, write-nested 190x to 102x,
   open-empty 4.7x and 8.3 KB to 3.1x and 3.7 KB (AceDB 3.3 KB), open-
   populated 2.6x to 2.3x, switch-profile 0.24x to 0.19x; an open database
   with one profile read holds 3.0 KB (revision 13: 3.9 KB, AceDB-3.0: 3.4
   KB). The main chunk is down to 195 locals.

---

**schemaKit sparse compiled nodes and `GetLimit`** — a change to facade `SchemaKit`

1. Package `schemaKit`, facade `SchemaKit`, API generation 1 (additive),
   version 0.2.0 (from 0.1.6), implementation revision 6 (from 5), node
   layout 2 (from 1).
2. Purpose: a compiled schema node holds only the fields its kind uses, and a
   consumer on a hot path can read one shared limit without allocating.
   a. **Sparse nodes** (memory.md fix 1, perf-settings fix 3, prototype
      the diagnosis prototype): `newCompiledNode` sets
      `layout`, `kind` and `expected`; every other field is set only by the
      builder that uses it. The seven `~= false` tests become truthiness
      tests, which read old fixed nodes and new sparse nodes alike;
      `Describe` answers `integer = node.integer == true`, so its output is
      unchanged.
   b. **`SchemaKit:GetLimit(name)`** → the current value of one shared limit
      (`maxDepth`, `maxPatternCaptures`, `pathKeyLimit`, `defaultArrayMax`),
      no allocation. `GetLimits` stays as it is (a fresh table).
   Non-goals: changing compiled nodes into another representation, a
   SettingsKit plan built from compiled nodes.
3. Dependencies: registry API 2, unchanged. No host API.
4. Surface: `SchemaKit:GetLimit(name)`; it raises at the caller for a dot
   call, a secret name and a name that is not one of the four limits.
   Compiled nodes stay private; nothing else changes.
5. Ownership: unchanged. In-place upgrade from revision 5: every node in
   `state.nodes` is copied into a sparse table and every reference to it
   (`of`, `inner`, `keys`, `values`, `alternatives`, `fieldNodes`, schema
   records, the proxy map) is re-pointed through an old-to-new map, so
   schemas built before the upgrade give their memory back (Lua 5.1 never
   shrinks a table's hash part in place). A node the walk missed still works,
   since the tests accept both layouts.
6. Performance and memory: a 4-field schema 13 523 B to 4 723 B (−65%,
   measured, memory.md); the bench schema's 38 nodes 49.0 KB to 15.2 KB
   (measured copy, `CompactNodes.lua`); about −1 KB per node in every addon.
   Check speed unchanged (a missing field reads as fast as a `false` one).
   `GetLimit` is one validated lookup; SettingsKit's write-nested drops from
   324 to 169 instructions with it (measured, prototype C).
7. Tests: the 133 existing specs pass on sparse nodes (prototype: 133/133);
   node sizes (at most 8 hash slots for scalars, measured with the existing
   table-size helper); `Describe` output identical for every kind; the
   upgrade from revision 5 (fixed nodes become sparse, references
   re-pointed, old schemas check and describe as before, a schema built
   after the upgrade); `GetLimit` for each limit, after `SetLimits`, no
   allocation, its argument errors at the caller's line.
8. Docs: `docs/API.md` (`GetLimit`, *Limits*), `docs/INTERNALS.md` (node
   layout 2, the upgrade), CHANGELOG, README (memory), `tests/README.md`;
   client suite: `GetLimit` returns the defaults.
9. Status: implemented 2026-11-15 under core decision 18, 0.2.0, revision 6,
   node layout 2, 139 specs. A 4-field schema holds 4,723 B (revision 5:
   13,523 B, −65%); an upgrade from revision 5 rebuilds older nodes as sparse
   ones and re-points every reference.

---

**optionsKit smaller records, labels on failure, cheaper `ProfileOptions`** — an internal change to facade `OptionsKit`

1. Package `optionsKit`, facade `OptionsKit`, API generation 1 (no surface
   change), version 0.6.2 (from 0.6.1), implementation revision 13 (from
   12), record layout bump.
2. Purpose: less memory per option and less work per `ProfileOptions` call.
   a. **Records of at most 8 hash fields** for the common option (name,
      description, get and set, or bind): `_depth` and `_path` derived from
      the parent chain when needed (`Walk`, info, error messages; `Walk`
      carries them down instead of recomputing), `_bind` rebuilt from scope
      and keys on the failure path, `_bindCount` replaced by `#_bindKeys`,
      `_order` and `_hints` stored only when not the default (read as
      `DEFAULT_ORDER` and `NO_HINTS`), the constructor listing at most 8
      fields so Lua sizes an 8-slot hash.
   b. **Labels built only on failure**: `buildOption` and its checks receive
      the parent label and the key and build `label .. ".args." .. key` (and
      `.validate`, `.values`, …) only in the branch that raises. Messages and
      levels unchanged. `Tree:Set` checks with `Check` and builds its
      `Assert` label only on failure.
   c. **`ProfileOptions`**: SettingsKit found through the Registry once and
      kept (a found implementation is stable per package and API; a miss is
      looked up again), and `validateProfileDatabase` skipped when the
      database is already the cache key. With SettingsKit's `databaseIndex`
      no longer probing (settingsKit record, 2b), each remaining `db[method]`
      probe is a plain method lookup.
   Non-goals: lazy records built on first use (memory.md fix 7 main form: an
   author mutating the tree between `Define` and first use would see the
   change), positional records.
3. Dependencies: unchanged (registry API 2, schemaKit API 1, signalKit API 1,
   settingsKit API 1 optional).
4. Surface: none. `Describe`, `Walk`, info tables and every message unchanged.
5. Ownership: records stay immutable after `Define`. In-place upgrade from
   revision 12: records of trees defined before keep their fields; the
   accessors read both layouts (a stored `_path`/`_depth`/`_bindCount` is
   used when present), so no record migration is needed.
6. Performance and memory: about −320 B per option (721 to 401 B per record,
   estimate from measured table sizing); −9% of `Define`'s allocation for the
   `args` label alone (measured), more with the other labels (estimate);
   define-50 time stays below AceConfigRegistry's (0.88x today).
   profile-options-build 6.2x to 4.6x (430 to 290 instructions, measured,
   prototype G) and toward 60 to 100 instructions with the cache-hit skip and
   the kept lookup (estimate); cmd-set-range, toggle, select, refused 10 to
   20% faster with CommandKit's kept lookup (measured, prototype H).
7. Tests: record sizes (8 hash slots for get/set and bind options with a
   description), every Define message unchanged and at the caller's line
   (existing ErrorLevels specs), no label built on success (allocation
   spec), `Walk` and info paths and depths, a bind error naming the bind
   path, `ProfileOptions` on a cache hit asking no `db[method]` and no
   Registry lookup, SettingsKit registered after the first call, the upgrade
   from revision 12 with a tree defined before it.
8. Docs: `docs/INTERNALS.md` (record fields, the derived ones),
   CHANGELOG, `tests/README.md`, README performance note. API.md unchanged
   except its *Performance* notes.
9. Status: implemented 2026-11-15 under core decision 18, 0.6.2, revision 13,
   208 specs. Recorded deviations: `desc`, `order`, `disabled` and `hidden`
   live in the hints table, collected in the unknown-field walk, so a value
   option keeps 8 fields with an order too; SettingsKit is still found on
   every `ProfileOptions` call, because a call must refuse when SettingsKit is
   gone from the Registry, and only the method probes of a database that
   already has a group are skipped. Measured on host Lua 5.1: 589 B held per
   option with a name, description, getter and setter (revision 12: 806 B), a
   20-option tree 18.7 KB (20.8 KB); against Ace3 in the same runs, define-50
   0.92x to 0.78x, profile-options-build 6.4x to 2.0x, cmd-refused 1.34x to
   1.18x.

---

**commandKit secret question without a per-call Registry lookup** — an internal change to facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1 (no surface
   change), version 0.2.10 (from 0.2.9), implementation revision 10 (from 9).
2. Purpose: `isSecret` (`CommandKit.lua:658`) looks ClientKit up through the
   Registry on every call (70 to 100 instructions each, twice per Register,
   also on every options-binding write). It now looks it up on the first
   secret question and keeps the answer, a miss included, in state. A
   ClientKit registered after that first question is not consulted; on the
   client that changes no answer, because ClientKit's `IsSecret` asks the
   same `issecretvalue` (`ClientKit.lua:873`). Alias liveness is kept, by
   the owner's decision: every Register still reads every foreign
   `SLASH_<key><n>` and chat-type alias live (prototype E's alias index is
   not taken).
   Non-goals: the alias index, reading only the next alias slot, any change
   to dispatch or parsing.
3. Dependencies: unchanged; clientKit API 1 stays optional.
4. Surface: none.
5. Ownership: the kept lookup lives in `state`, so an upgraded revision
   starts from it; a ClientKit implementation table is stable per package
   and API across its own upgrades (Registry: "one stable implementation
   table per (package, API) pair"). Upgrade from revision 9: the field is
   created empty and filled on first use.
6. Performance and memory: register-unregister about 3 011 to about 2 840
   instructions (the `isSecret` lookups, 124 to 170 instructions, measured
   share of prototype E), so about 28x instead of 30x (estimate); the scan
   (2 130 instructions, 71%) stays, which is the price of the kept liveness.
   Options command line 10 to 20% faster (measured, prototype H). No new
   allocation.
7. Tests: ClientKit asked when registered before the first question
   (`SecretValues_spec.lua:74` stays), one Registry lookup for many
   questions, a miss kept, the upgrade from revision 9;
   `TakenCheck_spec.lua:123` ("reads every alias live") unchanged.
8. Docs: `docs/INTERNALS.md` (the kept lookup and why a miss may be kept),
   CHANGELOG, `tests/README.md`.
9. Status: implemented 2026-11-15 under core decision 18, 0.2.10, revision 10,
   176 specs. register-unregister 29.9x to 28.3x of AceConsole-3.0; the live
   alias scan stays, by the owner's decision, and `docs/API.md` says why.

**timerKit (package O): fixed-cost trims, the probe rule, scope reopening and method-name callbacks** — a change to facade `TimerKit`

1. Package `timerKit`, facade `TimerKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.2), implementation revision 14 (from 13).
2. Purpose: close the measured gap to AceTimer-3.0 on the start, cancel
   and fire paths (the decision 18 diagnosis,
   section timerKit, prototype the diagnosis prototype),
   apply package O's secret-probe rule, give ModuleKit a way to keep a
   module's timer scope across enable cycles (`Scope:Reopen`, see the
   moduleKit record), and add Ace3's method-name callback form under core
   decision 19c. The fixes:
   - **One-frame start.** `Scope:After` and `Scope:Every`, and the
     package-level `TimerKit:After` and `TimerKit:Every`, test the receiver,
     the closed state, the callback, the delay (`delay >= 0 and delay <
     HUGE`, which also refuses NaN and infinity; `> 0` for `Every`) and the
     probe in one condition, then build, arm and record the timer inline.
     When any test fails they hand over, with a non-tail call, to the
     existing `startTimerInScope`, which raises the same message at the
     caller's line as today.
   - **One-frame cancel.** `Timer:Cancel` holds the cancel body inline.
   - **One-frame fire.** `dispatch.fireStarted` merges the stale-callback
     check with the delivery (no `dispatchFire` → `fireTimer` →
     `deliverTimer` → `detachActive` chain on the hot path).
   - **No `type()` before the private-metatable checks** (`TimerKit.lua`
     `:574`, `:583`, `:1011`, `:1408`, `:1708`): `getmetatable(x) ~=
     METATABLE` already refuses everything but a record, because the
     metatable's `__metatable` field hides it from foreign code.
   - **`_userData` layout.** The constructors stop naming `_userData =
     nil`. A one-shot timer stays at 8 hash nodes either way (a wasted store
     only); a repeating timer drops from 16 nodes to 8, and the first
     `SetUserData` on a repeating timer pays the one rehash instead of every
     repeating timer paying the larger table.
   - **Probe rule.** `issecretvalue` is resolved once at load (today, too,
     at `:445`); when it was absent at load, each check reads
     `rawget(_G, "issecretvalue")` and accepts it only as a function, so a
     probe installed later is honoured (today it never is).
   - **Method-name callbacks (decision 19c).** `After(delay, receiver,
     methodName)` and `Every(interval, receiver, methodName)` on scopes and
     on the facade, the counterpart of AceTimer's
     `self:ScheduleTimer("Method", delay)`. The method is looked up once, at
     the call: `receiver` must be a table, `methodName` a non-empty,
     non-secret string, and `receiver[methodName]` a function, or the call
     raises at the caller's line. The resolved function is wrapped in one
     closure, `function(timer) return method(receiver, timer) end`, which
     becomes the timer's callback, so the method runs as
     `method(receiver, timer)`.
   Non-goals: AceTimer's extra callback argument (`ScheduleTimer(f, delay,
   arg)`; `SetUserData` is the counterpart), late binding (see point 4),
   a method form on `New(options)`, changing the host style (`NewTimer`
   handles stay: they are what lets a cancelled timer leave nothing pending).
3. Dependencies: unchanged, registry API 2. Host requirements unchanged.
4. Surface:
   - `scope:After(delay, receiver, methodName)`,
     `scope:Every(interval, receiver, methodName)`, and the same on the
     facade. The method name is required (AceTimer has no default either).
     Errors, each at the caller's line: `<method> callback must be a
     function, or a receiver table followed by a method name` (replacing
     `<method> callback must be a function`, whose text it still
     contains), `<method> methodName must not be a secret value`,
     `<method> methodName must be a non-empty string`, `<method> receiver
     has no method "<name>"` (also when the field is not a function), and
     `<method> receiver must not be a secret value`.
   - **Recorded deviation from AceTimer: early binding.** AceTimer reads
     `obj[func]` when the timer fires; TimerKit reads it once when the timer
     starts (the decision asks for the check at registration, and the
     resolved function is cheaper per fire). Replacing the method on the
     receiver afterwards does not change a timer already started; `Restart`
     keeps the resolved function too. The docs say so in the migration
     table.
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when the scope was open. A reopened scope is empty and usable
     like a new one; timers cancelled by the close stay cancelled and can
     be started again. An addon scope (`ForAddon`) raises at the caller:
     `TimerKit.Scope:Reopen cannot reopen an addon scope`, because closing
     an addon scope is its addon's teardown and stays terminal.
   - Unchanged: every other method, message, level, state and limit.
5. Ownership: unchanged. A method-name timer is owned by its scope like any
   other; the receiver is held by the wrapper closure while the timer is
   held, exactly as a closure callback holds its upvalues.
6. Performance and memory (host bench, ratios against AceTimer-3.0 from the
   same run, prototype numbers from `perf-runtime.md`):

   | Case | Before | Expected after |
   |---|---:|---:|
   | oneshot-create-cancel | 2.46× | 1.84× |
   | oneshot-create-fire | 1.86× | 1.42× |
   | repeat-tick | 1.08× | 1.01× |

   Instructions per create + cancel 188 → 138, calls 22 → 15. Bytes per
   pending one-shot unchanged at 877 B (AceTimer 629 B, of which 306 B is
   the host stub's `NewTimer` handle on our side); a repeating timer's
   record 704 → 384 B (measured, the decision 18 diagnosis). The probe rule saves one global read and one
   `type` per check in the client; on the bench host, which defines no
   `issecretvalue`, the fallback costs what today's code costs, so the
   table above already excludes any probe gain.
   Method-name form (measured in the diagnosis prototype):
   one closure of two upvalues, 136 B, at start; per fire one extra Lua
   frame, 31.7 ns against 19.2 ns for a closure callback (Ace3's late-bound
   lookup costs 35.1 ns on the same host). The closure form is unchanged:
   the method form leaves the fast path at its callback test and is built
   on the existing slow path. `Reopen` adds nothing to any hot path.
   Not reached by these fixes: a timer well below AceTimer's bytes. The
   remaining 248 B gap is the host handle and the two-upvalue fire closure,
   both bought by documented guarantees; an array-part timer record (176 B
   instead of 384 B, measured) would close most of it and is left for an
   owner decision because every record read changes.
7. Tests: the fast paths keep every existing error message and level
   (Arguments spec gains one case per fast-path test that fails, each
   asserting the caller's line); `fireStarted` stale-callback and repeating
   specs; a repeating timer without user data has 8 hash nodes (internal
   spec through the record layout), and `SetUserData` on it still works;
   the probe rule (a probe installed after load is honoured; a probe present
   at load is called without a global read); receiver checks without `type`
   (a string, a number, a table with a foreign metatable, a table with a
   `__metatable` field all raise the receiver message); method form on
   `After`/`Every` of scope and facade: fires as `method(receiver, timer)`,
   each refusal at the caller's line, missing and non-function method,
   secret method name, early binding (replacing the method after start does
   not change the call), `Restart` keeps it; `Reopen` on a closed and an
   open manual scope, on an addon scope (raises), timers of the closed
   period stay cancelled; an in-place upgrade from revision 13 keeps running
   one-shot and repeating timers firing through the new `fireStarted`, and
   their callbacks created by revision 13 resolve it at fire time. Client
   suite additions (never run): a method-name timer fires; `getmetatable`
   on a secret value does not raise (the receiver checks rely on it for a
   meaningless secret receiver only).
8. Docs: API.md (method form, early binding, `Reopen`, the errors table,
   the revised "allocates nothing" note for `SetUserData` on a repeating
   timer, the probe rule), INTERNALS.md (one-frame paths and their
   hand-over to the validators, record layout), CHANGELOG, README (migration
   table row for `ScheduleTimer("Method", delay)`), tests/README. For the shared documents:
   the `MIGRATING_FROM_ACE3.md` timer row and the closures-only paragraph.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 14, 145 specs. Deviations: the method is checked at registration
   and looked up on the receiver at every fire (late binding, as AceTimer),
   not resolved once; every timer, one-shot and repeating, uses one array-part
   record of nine slots, older named-field timers converted in place (active
   ones at load, the rest on first use); the start is two Lua frames, the
   public method and a shared launcher.

**eventKit (package O): fixed-cost trims, smaller connections, scope reopening and method-name callbacks** — a change to facade `EventKit`

1. Package `eventKit`, facade `EventKit`, API generation 1 (additive),
   version 0.10.0 (from 0.9.8), implementation revision 21 (from 20).
2. Purpose: the measured EventKit fixes of
   the decision 18 diagnosis (sections lifecycleKit
   and moduleKit F1/F4, eventKit and signalKit, schedulerKit P1; prototypes
   the diagnosis prototype,
   the diagnosis prototype, the diagnosis prototype), the memory fix for connection handles from
   `memory.md`, package O's probe rule, and decision 19c's method-name form.
   - **Plain fields in the scope links.** `linkToScope` and
     `unlinkFromScope` use plain indexing: neither metatable has
     `__newindex` and every field written exists on the record.
   - **The second `pcall` only while a channel needs it.** `fireChannel`
     walks unprotected unless the channel holds a legacy signal (connections
     from revision 16 and older) or a one-shot listener, whose release talks
     to the host. A per-channel count `onceCount`, created on first use and
     kept by `Once`/`OnceUnit` connect, disconnect and delivery, says so.
     Listener calls already run through `securecallfunction` or `xpcall`,
     neither of which propagates a listener error
     (`docs/EMBEDDING.md`, "Secure calls and secure variables"), so the
     unprotected walk cannot leave `dispatchDepth` raised.
   - **Smaller connection handles.** A connection becomes an array-part
     record: `[1]` callback, `[2]` connected, `[3]` once, `[4]` fan-out
     (channel or combat-log route), and for a scoped connection `[5]` scope,
     `[6]` previous, `[7]` next. The fan-out kind is told by the fan-out
     record itself. The connection metatable moves into shared state, so
     `Disconnect`/`IsConnected` check the receiver by metatable identity
     (one C call instead of `type`, `rawget`, `type`). Connections an older
     revision made are converted in place when this revision loads (the
     same tables, so handles held by addons keep working), walking every
     channel, unit group, combat-log route and scope list once; the hot
     path then reads one layout only. Any closure of an older revision that
     reads connection fields directly is found and covered before the
     conversion is written (phase 2 audits SchedulerKit's and LifecycleKit's
     uses; only methods are called on handles today, as far as read).
   - **Probe rule.** `isSecret` (`:718`) and the dispatch check (`:1996`)
     use `issecretvalue` resolved at load, and fall back to
     `rawget(_G, "issecretvalue")` per call, accepted only as a function,
     when it was absent at load.
   - **No `type()` before the private-metatable checks** (`:818`, `:2898`).
   - **`Scope:Reopen()`** for ModuleKit's kept scopes (moduleKit record).
   - **Method-name callbacks (decision 19c)**, the counterpart of AceEvent's
     `self:RegisterEvent("X", "OnX")` and `self:RegisterEvent("X")`.
   Non-goals: the method form on `ConnectCombatLog`, `Coalesce` and
   `Derive` (no Ace3 counterpart for the first two besides AceBucket, whose
   coalescing moves to a part in a later package O record and gets the form there); late
   binding; flattening the four-frame regular dispatch (P4, a later package O record with the
   coalescing part).
3. Dependencies: unchanged, registry API 2, signalKit API 1.
4. Surface:
   - `Connect(eventName, receiver[, methodName])`,
     `Once(eventName, receiver[, methodName])` on the facade and on scopes;
     `methodName` defaults to `eventName`, as AceEvent's does.
     `ConnectUnit(eventName, receiver, methodName, unit1[, unit2])` and
     `OnceUnit(...)` the same, with `methodName` required (a unit token in
     its place would be ambiguous). The method runs as
     `method(receiver, eventName, ...)`, what AceEvent passes.
   - Resolved and checked at the call: `receiver` a table, `methodName` a
     non-empty, non-secret string, `receiver[methodName]` a function;
     otherwise raises at the caller's line: `<method> callback must be a
     function, or a receiver table followed by a method name` (still
     containing today's `callback must be a function`), `<method>
     methodName must be a non-empty string`, `<method> methodName must not
     be a secret value`, `<method> receiver has no method "<name>"`.
   - **Recorded deviation from AceEvent: early binding.** AceEvent reads
     `self[method]` on every event; EventKit reads it once at connect.
     Replacing the method on the receiver afterwards (including another
     addon's HookKit `Hook` on that method) is not seen by an existing
     connection; reconnect to pick it up. Stated in API.md and the
     migration table.
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when it was open; empty afterwards; an addon scope raises at
     the caller (`EventKit.Scope:Reopen cannot reopen an addon scope`).
     During a dispatch, a scope closed and reopened in the same dispatch is
     open again at once, and the sweep of its earlier connections still
     runs when the outermost dispatch returns.
5. Ownership: unchanged; a method-form connection is owned like any other.
6. Performance and memory (host bench against AceEvent-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | event dispatch-1 | 1.13× | 1.07× (measured without the `pcall`) |
   | event churn-warm / churn-cold | 1.33× / 1.53× | about 1.2× / 1.4× (estimate: handle 224 → 128 B and fewer C calls on disconnect) |
   | disable-enable-all-listening (moduleKit) | 2.21× | 1.58× with ModuleKit's reuse (6,740 → 6,130 instructions from the links alone) |
   | buckets record-event (via schedulerKit) | 1.90× | 1.73× in the client; on the bench host, which has no `issecretvalue`, the fallback keeps today's cost |

   Connection bytes (measured, the diagnosis prototype):
   unscoped 224 → 128 B, scoped 384 → 176 B. Per marginal connection that is
   still above AceEvent's 71 B on a pre-embedded object, which stores one
   hash entry and returns no handle; an EventKit scope (404 B) stays below
   an AceEvent embed (455 B). Method form: one closure of two upvalues,
   136 B, at connect; one extra Lua frame per delivery (31.7 against
   19.2 ns, Ace3's late-bound 35.1 ns). The closure form's paths are
   unchanged. The conversion of old connections runs once per upgrade.
7. Tests: dispatch with and without a one-shot (`onceCount` kept through
   connect, disconnect, delivery, `DisconnectAll`, close during dispatch);
   a legacy signal still protected; dispatch depth restored after a host
   failure in a one-shot release; array-layout handles: every method, the
   receiver message for a string, a table with a foreign metatable and an
   old-layout imitation; scope links after many connect/disconnect orders;
   the in-place upgrade from revision 20 converting regular, unit,
   combat-log and scoped connections, held handles still disconnecting,
   connection order kept; probe rule (installed after load honoured);
   method form on the four methods of facade and scope (default name,
   required name on the unit forms, each refusal at the caller's line,
   early binding, `method(receiver, eventName, ...)`); `Reopen` (manual,
   open, addon scope, inside a dispatch). Client suite additions (never
   run): a method-name connection on `PLAYER_ENTERING_WORLD`;
   `securecallfunction` does not propagate a listener error.
8. Docs: API.md (method form, early binding, `Reopen`, connection cost,
   errors), INTERNALS.md (handle layout and its conversion, `onceCount`,
   when the walk is protected), CHANGELOG, README (migration rows for
   `RegisterEvent("X", "OnX")` and `RegisterEvent("X")`), tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.10.0,
   revision 21, 271 specs. Deviations: late binding (the method is checked at
   registration and looked up at every delivery; one missing then is reported
   through listener isolation as `EventKit receiver has no method "<name>"`
   and the connection stays); Coalesce and Derive handles keep named scope
   links; the main chunk is down to 187 locals.

**signalKit (package O): publish and subscribe trims, smaller connections, bus scope reopening and method-name callbacks** — a change to facade `SignalKit`

1. Package `signalKit`, facade `SignalKit`, API generation 1 (additive),
   version 0.8.0 (from 0.7.7), implementation revision 11 (from 10).
2. Purpose: the measured SignalKit fixes of
   the decision 18 diagnosis (section eventKit and
   signalKit; prototype the diagnosis prototype), the handle
   memory fix, package O's probe rule, `Scope:Reopen` for ModuleKit's kept
   `Messages` scope, and decision 19c's method-name form.
   - **Fixed cost of `bus:Publish` and `subscribe`.** No `type(self)` in
     front of `getmetatable(self) ~= BUS_METATABLE` (also `:1393`, `:1402`,
     `:1950`); the probe resolved by the rule below; `type(topic)` and
     `topic == ""` only when the topic-table lookup misses (a topic record
     exists only under a validated non-empty string). The validators still
     raise every message at the caller's line.
   - **Probe rule** at `isSecret` (`:1364`), `subscribe` (`:1734`) and
     `busPublish` (`:1888`): resolved at load, per-call
     `rawget(_G, "issecretvalue")` (accepted only as a function) when it was
     absent at load.
   - **Smaller connection handles.** `{ callback, connected, once, signal }`
     in the array part, `[5]` the bus scope for a scope's subscription;
     `_busCallback` (revision 8 and older) is kept by the conversion only.
     Raw signals are not listed anywhere SignalKit can walk, so conversion
     is lazy: a signal created by this revision carries `_layout = 2`, and
     `Fire`, `Connect`, `Once`, `DisconnectAll` and a connection's
     `Disconnect` convert an older signal's listener array in place the
     first time they touch it (the same tables, so held handles keep
     working). `Fire` pays one field read for the marker.
   - **`Scope:Reopen()`** on bus scopes.
   - **Method-name callbacks (decision 19c)**: the counterpart of
     AceEvent's `RegisterMessage("Name", "Method")` / `RegisterMessage("Name")`
     on buses, and of CallbackHandler's `RegisterCallback(self, "event",
     "method")` on raw signals.
   Non-goals: late binding; a method form for `Unsubscribe` (a method-form
   subscription is released by its handle or its scope, since
   `Unsubscribe(topic, callback)` matches functions); journals.
3. Dependencies: unchanged, registry API 2.
4. Surface:
   - `bus:Subscribe(topic, receiver[, methodName])`,
     `bus:SubscribeOnce(topic, receiver[, methodName])`, and the same on bus
     scopes; `methodName` defaults to `topic`, as AceEvent's does. The
     method runs as `method(receiver, ...)` with the published arguments;
     unlike AceEvent, the topic is not passed (a bus subscriber never gets
     it today), which the migration table states.
   - `signal:Connect(receiver, methodName)`, `signal:Once(receiver,
     methodName)`: name required (a raw signal has no name to default to).
   - Checks and errors as in the other runtime Kits, at the caller's line:
     `<method> callback must be a function, or a receiver table followed
     by a method name`, `<method> methodName must be a non-empty string`,
     `<method> methodName must not be a secret value`, `<method> receiver
     has no method "<name>"`.
   - **Early binding** (recorded deviation from AceEvent and
     CallbackHandler, which look the method up per call): the method is
     resolved at subscribe.
   - `scope:Reopen()` → `true` when it reopened a closed bus scope, `false`
     when it was open; refused with `false, "closed"` when its bus is
     closed (an addon bus closed at logout stays closed).
5. Ownership: unchanged.
6. Performance and memory (host bench against AceEvent-3.0 messages, same
   run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | message dispatch-1 | 1.57× | 1.39× in the prototype; 1.42-1.47× expected on the bench host, where the probe fallback keeps its read |
   | message dispatch-10 | 1.06× | 0.98× |
   | message churn-warm / churn-cold | 1.56× / 1.64× | about 1.3× / 1.4× (estimate: handle 224 → 128 B) |

   Subscription bytes (measured): 224 → 128 B, a bus scope's 384 → 144 B.
   Still above AceEvent's 71 B per extra message on a pre-embedded object
   (no handle there). Method form: 136 B closure at subscribe, one extra
   Lua frame per delivery (31.7 against 19.2 ns; Ace3 late-bound 35.1 ns).
7. Tests: publish and subscribe refusals at the caller's line for every
   reordered test (secret topic, non-string, empty, unknown topic, wrong
   receiver: string, number, foreign-metatable table); probe installed
   after load honoured; array-layout handles and every connection method;
   lazy conversion of a revision 10 signal on `Fire`, `Connect` and a held
   handle's `Disconnect`, including a conversion during a dispatch of that
   signal; bus subscriptions converted; the in-place upgrade from revision
   10 keeping order and tombstone counts; method form on bus, bus scope and
   raw signal (default topic name, required name on signals, refusals,
   early binding, the arguments passed); `Reopen` on open, closed, and
   closed-bus scopes.
8. Docs: API.md (method form, `Reopen`, handle cost, conversion note),
   INTERNALS.md (layout, `_layout` marker), CHANGELOG, README (migration
   rows for `RegisterMessage` and `RegisterCallback` with a method name),
   tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.8.0,
   revision 11, 266 specs. Deviations: late binding as above; `Fire` never
   converts: an older signal is converted in place when a connect finds it
   idle, and idle bus topic signals at load, so no signal mixes layouts; no
   secret check on the receiver, which nothing compares.

**hookKit (package O): counted hook bound, inline isolation, scope reopening and method-name handlers** — a change to facade `HookKit`

1. Package `hookKit`, facade `HookKit`, API generation 1 (additive),
   version 0.4.0 (from 0.3.2), implementation revision 8 (from 7).
2. Purpose: the measured HookKit fixes of
   the decision 18 diagnosis (section hookKit;
   prototype the diagnosis prototype), `Scope:Reopen` for
   ModuleKit's kept `Hooks` scope, and decision 19c's method-name form.
   - **Counted upper bound instead of a walk.** `hasRoom` (`:1090`) today
     calls `countRecords` on every install, so installing n hooks is
     quadratic. Each scope keeps `_recordBound`, raised by one at every
     record added and lowered at `removeRecord` (`:819`, the only place a
     record is removed). A real count runs only when the bound reaches
     `maxHooks`; it also forgets records of collected objects and resets the
     bound. A scope an older revision built has no bound and is counted on
     first use.
   - **`pcall` inline in the hook closures.** Pre-hook and secure post-hook
     closures call `pcall(record._handler, ...)` and pass a failure to
     `dispatch.reportFailure`, instead of going through
     `dispatch.isolatedCall`, which stays published for closures older
     revisions installed.
   - **No `type()` before the private-metatable checks** (`:512`, `:967`).
   - Probe: HookKit already follows package O's rule (`isSecret`, `:486`).
   - **`Scope:Reopen()`.**
   - **Method-name handlers (decision 19c)**, the counterpart of AceHook's
     `self:Hook(obj, "Method", "Handler")` and its default handler name.
   Non-goals: AceHook's `hookSecure` flag, late binding, AceHook's
   `self.hooks` table (`scope:Original` is the counterpart).
3. Dependencies: unchanged, registry API 2.
4. Surface: in the handler position of `Hook`, `RawHook`, `SecureHook`,
   `HookScript`, `RawHookScript` and `SecureHookScript`, a receiver table
   followed by an optional handler name:
   - `Hook(object, method, receiver[, handlerName][, options])` and
     `Hook(globalName, receiver[, handlerName][, options])`; the script
     forms `HookScript(frame, script, receiver[, handlerName][, options])`.
     After the receiver, a string is the handler name and anything else is
     the options table. The default handler name is the hooked method's or
     script's name, as in AceHook (`AceHook-3.0.lua:119` at the bench's
     pinned commit, read for behaviour only).
   - The handler runs as `handler(receiver, ...)` with what the closure form
     receives: the call's arguments, and for `RawHook`/`RawHookScript` the
     original first (`handler(receiver, original, ...)`), which differs from
     AceHook (it passes `self` and keeps originals in `self.hooks`); the
     migration table says so.
   - Resolved and checked at the call, errors at the caller's line:
     `<method> handler must be a function, or a receiver table followed by
     an optional handler name` (containing today's `handler must be a
     function`), `<method> handlerName must be a non-empty string`,
     `<method> handlerName must not be a secret value`, `<method> receiver
     has no method "<name>"`.
   - **Early binding** (recorded deviation from AceHook, which looks the
     handler up per call).
   - `scope:Reopen()` → `true` when it reopened a closed manual scope,
     `false` when it was open; its limit is kept; closures left inert by the
     close stay inert (a new hook installs a new closure). An addon scope
     raises at the caller (`HookKit.Scope:Reopen cannot reopen an addon
     scope`).
5. Ownership: unchanged.
6. Performance and memory (host bench against AceHook-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | call through a pre-hooked script / method | 1.89× / 1.81× | 1.47× / 1.39× |
   | call through a post-hooked method | 1.64× | 1.31× |
   | install with 200 hooks resident | 11,331 ns | 1,298 ns, flat in n |
   | install with 0 resident | 1,341 ns | 1,276 ns |

   One number field per scope for the bound, no per-hook bytes. Method
   form: a 136 B closure per hook and one extra Lua frame per hooked call
   (about 12.5 ns, measured in the diagnosis prototype).
7. Tests: installs up to `maxHooks` and the refusal past it with the bound;
   the bound after `Unhook`, `UnhookAll`, `Close`, and with records of
   collected objects (recount frees room); a revision 7 scope without a
   bound; inline isolation reports a handler error and still runs the
   original, results and `nil` counts unchanged; closures installed by
   revision 7 keep working after the in-place upgrade; receiver checks
   without `type`; method form on all six methods with and without a
   handler name and with options, refusals at the caller's line, the raw
   form's `original` argument, early binding; `Reopen`.
8. Docs: API.md (method form, raw-form argument order, `Reopen`, the install
   cost), INTERNALS.md (`_recordBound`, inline isolation), CHANGELOG, README
   (migration rows for `Hook(obj, "Method", "Handler")` and the default
   handler), tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.4.0,
   revision 8, 151 specs. Deviations: the handler is looked up on the receiver
   at every call (late binding); the counted bound lives in the weak-keyed
   state table `recordBounds`, not a `_recordBound` scope field, so the scope
   stays at eight fields.

**schedulerKit (package O): the probe rule, one-pass key validation, receiver checks and scope reopening** — a change to facade `SchedulerKit`

1. Package `schedulerKit`, facade `SchedulerKit`, API generation 1
   (additive), version 0.9.0 (from 0.8.9), implementation revision 21
   (from 20).
2. Purpose: the SchedulerKit items of
   the decision 18 diagnosis (section schedulerKit
   coalescing, P1 and P2), package O's probe rule, the private-metatable
   checks, `Scope:Reopen` for ModuleKit's kept `Jobs` scope, and the
   decision 19b removals that fall in this file.
   - **Probe rule.** `issecretvalue` is resolved at load (today at `:530`,
     inside a `do` block, with no fallback). The resolved probe moves out of
     the block so the hot paths see it, and when it was absent at load each
     check reads `rawget(_G, "issecretvalue")`, accepted only as a function.
   - **One-pass key validation in a coalesce handle's `__call`**
     (`coalesceCall`, `:3640`): the probe, the `nil` test and the NaN test
     run in one inline condition, and the existing validator raises the
     message (unchanged, same level) only when that condition fails. One Lua
     call fewer per key; no message string is built on success.
   - **No `type()` before the private-metatable checks** (`:1299`, `:1307`,
     `:1315`, `:2406`, `:2415`, `:3105`, `:5387`).
   - **Decision 19b.** The two option-name checks that only keep a secret
     key away from an internal table read (`:1150`, `:2362`, "a secret key
     would raise at the table read below") guard what the client already
     refuses. They go only if the maintainer confirms the reading below; see point 7.
   - **`Scope:Reopen()`.**
   Non-goals, a later package O record with the coalescing part (decision 19a): EventKit
   calling a trusted SchedulerKit entry that skips the key re-check (P3),
   slimming the coalesce member to 8 fields or fewer (P5, about −376 B per
   bucket), the method-name form for buckets (AceBucket's
   `RegisterBucketEvent(events, interval, "Method")`) and the move of
   `Debounce`/`Coalesce`/`Watch`/lanes into a part file. SchedulerKit gets
   no method-name form in (package O): Ace3 has no counterpart to its jobs.
3. Dependencies: unchanged, registry API 2, timerKit API 1.
4. Surface: `scope:Reopen()` → `true` when it reopened a closed manual scope,
   `false` when it was open; an addon scope raises at the caller
   (`SchedulerKit.Scope:Reopen cannot reopen an addon scope`). Jobs and
   handles the close cancelled or closed stay so. Nothing else changes.
5. Ownership: unchanged.
6. Performance and memory (host bench against AceBucket-3.0, same run):

   | Case | Before | Expected after |
   |---|---:|---:|
   | buckets record-event | 1.90× | 1.73× in the client from the probe (EventKit and SchedulerKit); about 1.85× on the bench host, whose missing `issecretvalue` keeps the fallback's read, minus P2's call |
   | buckets burst | 1.93× | 1.79× in the client, as above |
   | buckets register-remove | 2.34× | unchanged (P5 is a later package O record) |

   No bytes change. `Reopen` adds nothing to any hot path.
7. Tests: coalesce key refusals unchanged in text and level (secret, `nil`,
   NaN) through the one-pass check, including `SecretValues_spec:241`,
   which needs the probe visible outside the `do` block; probe installed
   after load honoured on every path that checks one; receiver checks
   without `type` for scopes, jobs, contexts, members and lanes; `Reopen`;
   in-place upgrade from revision 20 keeping queued jobs and coalesce
   handles. Decision 19b: removing the option-name checks assumes that no
   caller table can hold a secret key. The measurement in
   `docs/EMBEDDING.md` shows that reading `t[secret]` raises; that writing
   one raises too, so `pairs` never yields one, is not measured. Until the
   client suite asserts `t[secretwrap(1)] = true` raises, these two checks
   stay; with the maintainer's yes they go and the client suite gains that test.
8. Docs: API.md (`Reopen`, the probe rule), INTERNALS.md (the one-pass key
   check), CHANGELOG, tests/README; the README's scope table.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 21, 289 specs. The option-name key checks stay (decision 19b
   covers read-side checks only).

**lifecycleKit (package O): the probe rule and the halted field as a record field** — a change to facade `LifecycleKit`

1. Package `lifecycleKit`, facade `LifecycleKit`, API generation 1,
   version 0.6.9 (from 0.6.8, internal fix and documentation), implementation
   revision 18 (from 17).
2. Purpose: the LifecycleKit side of the moduleKit fix F3 in
   the decision 18 diagnosis (section lifecycleKit
   and moduleKit) and package O's probe rule.
   - **`_halted` becomes a documented, stable generation-1 field of an
     instance.** ModuleKit reads it on every enable instead of calling
     `IsHalted` twice. It is exact because LifecycleKit writes
     `_halted = true` before it notifies anyone (`LifecycleKit.lua:1973`),
     and every instance gets `_halted = false` at creation (`:674`). An
     instance of a revision older than the halted state has no field and
     reads as not halted, which is what it is. INTERNALS-level promise in
     API.md: the field is written only by LifecycleKit, is `true` from the
     moment the halt begins, and keeps its name and meaning for API 1.
   - **Probe rule.** `isSecret` (`:344`) reads `rawget(_G,
     "issecretvalue")` on every call today. It resolves it once at load and
     falls back to the per-call read, accepted only as a function, when it
     was absent at load.
   - **Decision 19b candidate.** `describeKey` (`:358`) checks a caller
     table's key for a secret before naming it; a table cannot be indexed
     with a secret key on Retail 12.1.0 (`docs/EMBEDDING.md`). The check
     stays until the client suite proves a secret key cannot be written
     either (see the schedulerKit record, point 7), then goes.
   Non-goals: any change to phases, halts, the combat gate or their costs.
3. Dependencies: unchanged, registry API 2, signalKit API 1, eventKit API 1.
4. Surface: no new methods. API.md documents the `_halted` field as above.
5. Ownership: unchanged.
6. Performance and memory: one global read and one `type` fewer per secret
   check in the client; nothing on the bench host, which has no probe. The
   ModuleKit gain the field enables is in the moduleKit record (about 22
   instructions per halt check, twice per enable). No bytes change.
7. Tests: a probe installed after load is honoured; `_halted` is `true`
   inside the first halt listener and before `OnHalted` subscribers run;
   in-place upgrade from revision 17 keeps instances, phases and halts.
8. Docs: API.md (the field, under "Halted state"), CHANGELOG, tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.9,
   revision 18, 202 specs.

**moduleKit (package O): kept module scopes, cheaper enables, the probe rule and an opt-in missing-Kit error** — a change to facade `ModuleKit`

1. Package `moduleKit`, facade `ModuleKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.8), implementation revision 22 (from 21).
2. Purpose: the moduleKit fixes F1-F3 of
   the decision 18 diagnosis (section lifecycleKit
   and moduleKit; prototype the diagnosis prototype),
   package O's probe rule, decision 19b where it applies here, and the
   AddonKit's request for an opt-in error when a module reads a
   scope field whose Kit is not loaded (2026-11-15).
   - **F1, kept scopes.** A module's Kit scopes are closed on disable, as
     today, but kept on the module (`_parkedScopes`, created on first use).
     On the next enable, the first read of a field reopens the kept scope
     with its Kit's `Scope:Reopen()` when the Kit has it (TimerKit, EventKit,
     SignalKit bus scopes, HookKit and SchedulerKit after this package), and
     otherwise creates a new one as today (CommKit and CommandKit until
     their owners add `Reopen`; any older revision). This skips the
     Registry lookup (`findOptionalPackage`) and the construction on every
     enable after the first. A kept scope whose `Reopen` answers `false` or
     raises is dropped and a new one created, so a reopen failure never
     reaches the module.
   - **F2, flag before the blocked-dependents scan.** `recoverBlockedDependents`
     (`:2357`) scans every module on every `Enable` and nearly always finds
     nothing. The container keeps `_mayHaveBlocked`, set to `true` at each of
     the 12 places `_enableBlockedBy` is written and to `false` when a scan
     finds nothing; `false` skips the scan, and `nil` (a container an older
     revision made) scans as today.
   - **F3, halt read from the record.** The two halt checks per enable read
     `rawget(lifecycle, "_halted") == true` instead of calling `IsHalted`;
     LifecycleKit documents the field in its own record of package O.
   - **Probe rule.** `issecretvalue` stays resolved at load (`:342`) and
     gains the per-call fallback (`rawget(_G, ...)`, accepted only as a
     function) when it was absent at load.
   - **Decision 19b.** `scopeIndex` (`:1777`), the scope's `__index`,
     refuses a secret key before `SCOPE_PACKAGES[key]`. The client raises on
     `scope[secret]` before `__index` runs (`docs/EMBEDDING.md`, measured on
     Retail 12.1.0), so the check never runs there; it goes. The checks on
     keys of caller tables read with `next` (`:1355`, `:1530`, `:3259`,
     `:3316`, `:4047`) wait for the client proof described in the
     schedulerKit record, point 7.
   - **Missing scope Kits as an error, opt-in.** See point 4.
   Non-goals: one `pcall` per transition in whole-addon passes (F5, at most
   5%), the other AceAddon conveniences of the Ace3 gap list (a later package O record), any
   method-name form (AceAddon calls `OnInitialize`/`OnEnable`/`OnDisable` by
   name already, as ModuleKit does through definitions).
3. Dependencies: unchanged, registry API 2, lifecycleKit API 1; the scope
   Kits stay optional and are found through `Registry:Find`.
4. Surface:
   - **Scope identity (behaviour change).** `module.scope.Events` (and every
     field whose Kit has `Reopen`) is the same object across enable cycles;
     today it is a new one each time. A reference kept from an earlier
     enabled period raises while the module is disabled, as now, and works
     again after re-enable. The module-scope rules in API.md change from
     "the next enable starts with fresh scopes" to "the next enable starts
     with empty scopes, the same objects where the Kit can reopen them".
   - **`addon:SetMissingScopePolicy(policy)`** → previous policy, and
     **`addon:GetMissingScopePolicy()`**; `policy` is `"nil"` (default,
     today's behaviour) or `"raise"`. Under `"raise"`, reading a scope
     field whose Kit is not loaded, or is a revision without owner scopes,
     raises at the reading line (the `__index` raises at level 2):
     `ModuleKit module "<module>" scope.Timers needs TimerKit API 1, which is
     not loaded; add timerKit/TimerKit.lua to your embeds.xml`. The file
     named is the Kit's facade file under the release layout's package
     folder; phase 2 takes the folder names from `.pkgmeta` and, if the
     tooling's generated `embeds.xml` changes them, from its output.
     `Messages` with SignalKit loaded but its bus full or closed keeps
     reading `nil` under either policy: that is a runtime state, not a
     missing file. A secret or non-string policy raises at the caller.
     AddonKit sets `"raise"` on its addon objects. A definition field
     `missingScopePolicy` is not added (one way to set it).
5. Ownership: a disabled module retains its kept, closed, empty scopes until
   the module is collected with its container (containers live for the
   session, as today).
6. Performance and memory (host bench `addonModules` against AceAddon-3.0,
   same run; the host's Lua `xpcall` stand-in flatters AceAddon, see the
   diagnosis):

   | Case | Before | Expected after |
   |---|---:|---:|
   | disable-enable-module | 1.54× | 1.21× (F2 + F3: 323 → 253 instructions per cycle) |
   | disable-enable-all | 1.31× | 1.18× |
   | disable-enable-all-listening | 2.21× | 1.58× (with EventKit's plain links); 7,784 → 3,944 B per cycle, to fall further when every scope Kit reopens |
   | create-addon / load-addon | 0.77× / 0.99× | unchanged |

   Held memory: a disabled module keeps up to 7 empty scopes (a TimerKit
   scope 308 B, an EventKit scope 404 B), where today it keeps none; an
   enable cycle allocates nothing for a reopened scope instead of a new
   scope each time. The policy is one field on the container, written only
   when set; its test runs only on the branch that answers `nil` today, so
   the default costs nothing.
7. Tests: the same scope object across enable cycles for each reopening Kit,
   a fresh one for a Kit without `Reopen` (a stand-in), a `Reopen` that
   raises or answers `false`; a reference kept across a disable raising,
   then working after re-enable; scopes still closed in the fixed order on
   every way out (disable, failed `OnEnable`, shutdown, halt);
   `_mayHaveBlocked` through each of the 12 writes (blocked dependencies,
   strict policy, halts, late modules) and a container of revision 21
   scanning; halt checks through `_halted`, and a LifecycleKit stand-in
   without it; probe installed after load honoured; the missing-scope
   policy: default `nil` unchanged, `"raise"` raising at the reader's line
   with the file name for each of the seven fields, `Messages` with a full
   bus still `nil`, policy argument errors; in-place upgrade from revision
   21 keeping modules, states and open scopes.
8. Docs: API.md (module scopes: identity and kept scopes, the missing-scope
   policy, the surface table, errors), INTERNALS.md (`_parkedScopes`,
   `_mayHaveBlocked`, the halt read), CHANGELOG, README, tests/README. For
   the shared documents: `MIGRATING_FROM_ACE3.md`'s module-scope paragraph if it says
   scopes are new per enable.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.9.0,
   revision 22, 264 specs. The policy methods are `SetMissingScopePolicy` and
   `GetMissingScopePolicy` as recorded; the error names the file as
   `<packageId>\<Facade>.lua` from MoltenCodes.

**commKit send fast path and cheaper checks** — an internal change to facade `CommKit`

1. Package `commKit`, facade `CommKit`, API generation 1 (unchanged),
   version 0.5.3, implementation revision 10 (from 0.5.2, revision 9).
   Patch: no public surface is added or removed.
2. Purpose: bring a send down towards AceComm-3.0 with ChatThrottleLib
   without dropping a documented guarantee, following the runtime
   performance diagnosis of 2026-11-15 (commKit, fixes F1 to F4, R1) and the
   memory diagnosis (fix 8).
   - F1. The forbidden-byte refusal (`CommKit.lua:4004`, pattern
     `"[%z\n\r|]"` at `:144`) becomes four plain `string.find(text, byte,
     1, true)` calls. Same refusal set, same reason code. Lua 5.1 tries a
     character class at every start position; plain finds do not.
   - F2. Send at once: a message of one chunk with no `onProgress` or
     `onComplete`, sent while the driver is not running, no deferred flush
     is under way, no driver job is scheduled and nothing is queued, is
     handed to the client straight away. One bucket check (refill and cost
     with one mode reading), then one client call under `pcall` with
     `sendingOwnTraffic` set. No record, pipe, ring entry or driver run is
     created, and the handle comes back already `sent`. When the bucket
     cannot pay, the message takes the queue path as today. When the client
     refuses or raises, the message is enqueued and then set aside
     (throttled) or completed as failed, exactly as the driver would, so a
     refusal never causes a second attempt within the same call.
   - F3. Host reads: `SendAddonMessage` and `SendAddonMessageLogged` are
     read once per driver run (not once per send and again per chunk), the
     `Enum.SendAddonMessageResult.Success` value once at load (the client's
     `Enum` is fixed for the session; the built-in fallback stays for a
     client without it). A function another addon replaces between two runs
     is used from the next run. One replaced from inside a hook on the send
     function itself takes effect from the next run, not the next chunk.
   - F4. Driver loop: the mode and rate are computed once per run, the
     rotation walk is skipped while exactly one message is queued and its
     pipe is still at the ring index served last (the guard that keeps the
     throttle specs passing), and `assignStreamId` runs for a message's
     first chunk only.
   - R1, by the secret-probe rule (one rule for every Kit):
     `issecretvalue` and `securecallfunction` are resolved once at load. A
     function absent at load is looked up again on each call, so a probe
     installed later is still honoured. That covers the three specs that
     install the probe after load and that pure load-time caching broke.
   - F5. Send handles drop `_schema`, which nothing reads (the handle
     layout is 1 and has never changed). Absent means layout 1 to any
     future migration. A fast-path handle has four fields and fits a
     four-slot hash.
   - Memory fix 8: the reassembly key-suffix tables (`WIRE.plain.keySuffix`,
     `WIRE.logged.keySuffix`, 128 and 75 strings, `:162-168`) are built on
     first use. Correction to the memory diagnosis, which says "first send": they are
     read only by the receive path (`:3161`), so they are built on the
     first chunk of a multi-chunk message received.
   Kept, by the owner's decision: "nothing armed when idle". The reassembly
   expiry timer is still cancelled when the last stream closes (R2, lazy
   disarm, is not taken). Not in this record: R3 (a no-wipe stream-pool
   reset, one isolation layer on receive), and anything that changes the
   wire format or the request-table API.
3. Dependencies: unchanged (registry API 2, signalKit, eventKit, poolKit,
   timerKit as today). Host functions as today: `C_ChatInfo.SendAddonMessage`
   and `SendAddonMessageLogged` (or the legacy globals), `Enum`,
   `issecretvalue`, `securecallfunction`; no new client API.
4. Surface: unchanged. Same errors at the same caller lines, same reasons,
   handle states, statistics, limits and throttle behaviour. One observable
   difference: a fast-path send is already `sent` when `Send` returns (today
   the inline driver run gives the same state before `Send` returns, so
   callers already see it). `SendHandle` fields are private; `_schema` was
   never documented.
5. Ownership: unchanged. The fast path counts `messagesQueued`,
   `chunksSent`, `bytesSent` and the terminal statistic as the queued path
   does. The suffix tables and the load-time host values are file-local and
   rebuilt by each revision's load; nothing new goes into `_state`, so an
   in-place upgrade from revision 9 takes over queues, pipes, streams and
   timers as before. The main chunk holds 198 of 200 locals: the new
   load-time values are fields of an existing file-local table, not new
   locals.
6. Performance and memory, host bench (`comm` workload), MoltenCodes ÷ Ace3
   in the same run. Before: the unmodified tree. After: the diagnosis
   prototype (F1 to F5, R1) with the expiry disarm restored, rerun
   2026-11-15:

   | Case | Before | After (expected) | B/op before → after (Ace3) |
   |---|---:|---:|---|
   | send-200 | 7.37× | 2.85× | 834 → 674 (104) |
   | send-1000 | 5.50× | 2.59× | 2,493 → 2,493 (2,086) |
   | send-8000 | 4.68× | 1.41× | 19,276 → 19,276 (21,679) |
   | receive-200 | 3.20× | 2.98× | 225 (0) |
   | receive-1000 | 3.53× | 3.47× | 2,014 (1,703) |
   | receive-8000 | 2.52× | 2.39× | 30,188 (29,848) |

   Calls per send-200: 121 → 63; per send-8000: 1,320 → 571 (Ace3: 647).
   Resident memory: −19.2 KB (memory diagnosis, exact drop) for a session that
   never receives a multi-chunk message.
   The target "at or below ChatThrottleLib/AceComm cost" is met on calls
   for large sends and on allocation for send-8000, not on time. What is
   left on send-200 is the request validation (about 186 instructions:
   unknown-key refusal and secret checks), the handle object and the
   one-byte control header (wire format). Each buys a documented
   guarantee. Receive stays above 2× without R2: the expiry timer cancel and
   restart per multi-chunk message (about 130 instructions, 20 calls) is
   the price of "nothing armed when idle".
7. Tests, failing first where a spec can observe the change:
   - the forbidden bytes NUL, LF, CR and `|` each refused with the same
     reason, at the start, the middle and the last byte, and a 255-byte
     clean message accepted;
   - fast path: one-chunk send while idle sends once and returns a `sent`
     handle with no record, pipe or driver run left behind; the same send
     with a queued message, a running driver, a scheduled job, a deferred
     flush, callbacks or two chunks takes the queue; an empty bucket takes
     the queue; a client refusal enqueues and sets the pipe aside without a
     second attempt; a raising client completes the handle as failed and
     reports through the error handler once; statistics match the queued
     path;
   - host functions read once per run: a `C_ChatInfo` function replaced
     between runs is used by the next run;
   - the probe rule: a probe present at load is used, a probe installed
     after load is honoured (the three existing specs keep passing),
     `securecallfunction` likewise;
   - the suffix tables absent after load and built by the first multi-chunk
     receive, keys unchanged;
   - the expiry timer still disarms when the last stream closes (existing
     spec kept);
   - `Bootstrap_spec:322` (one spare record) is rewritten for the fast path,
     which leaves no spare record;
   - in-place upgrade from revision 9 with a message queued and a stream
     open: both finish under revision 10.
   Client suite (`tests/client/MoltenCodesTest_CommKit/`, never run here):
   a fast-path send on the real channel reports `sent`, and a three-chunk
   message to the player still arrives whole.
8. Docs: `docs/API.md` (the send path and when a message is sent at once,
   cost notes), `INTERNALS.md` (the fast path, per-run host reads, the lazy
   suffix tables, the handle without `_schema`), `CHANGELOG.md` 0.5.3,
   `README.md` performance note, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.3,
   revision 10, 12 specs (275). Raw messages' NUL check is a plain find as
   well; reassembly key suffixes are made per stream id on first receipt
   rather than all on the first receive.

**localeKit fast unneeded-locale path** — an internal change to facade `LocaleKit`

1. Package `localeKit`, facade `LocaleKit`, API generation 1 (unchanged),
   version 0.1.7, implementation revision 5 (from 0.1.6, revision 4).
   Patch.
2. Purpose: make `NewLocale` for a locale the client does not need cost
   what AceLocale-3.0's does, and win back the revision 4 regression
   (123 → 180 ns), following the runtime performance diagnosis of
   2026-11-15 (localeKit).
   - Fast path: when `options` is `nil`, `NewLocale` asks the probe about
     `addonName` and `locale`, then looks up `addons[addonName]` and
     `CLIENT_LOCALE_CODES[locale]`. When both hit and the locale is not the
     record's, it returns `nil` at once. `addons` holds only validated
     non-empty names and `CLIENT_LOCALE_CODES` only valid codes, so the two
     hits prove what the `type` checks proved. Everything else (a first
     call for an addon, options given, a miss, a secret) takes today's full
     path with its messages and levels.
   - The secret-probe rule: `issecretvalue` resolved once at load, looked
     up per call only when it was absent at load, in `refuseSecret`,
     `validateLimit`, `NewLocale` and `Format`
     (`LocaleKit.lua:294`, `:372`, `:819`, `:1014`).
   - Decision 19b: `readMissing` (`:626-640`) drops its probe check on the
     key. The client refuses a secret key at the index, before `__index`
     runs (measured on Retail 12.1.0 b69933, docs/EMBEDDING.md), so
     `L[secretKey]` raises at the caller's line and the branch never runs
     in the client.
3. Dependencies: unchanged (registry API 2).
4. Surface: unchanged. Same messages and levels on every path. On a host
   that lets a secret key reach `__index` (none in the client), the key is
   now treated like any other key.
5. Ownership: unchanged; the load-time probe is file-local. An in-place
   upgrade from revision 4 keeps every addon record.
6. Performance and memory, host bench `locale` workload, MoltenCodes ÷
   AceLocale-3.0 in the same run (the diagnosis prototype):

   | Case | Before | After (expected) |
   |---|---:|---:|
   | unneeded-locale | 190 / 52 ns = 3.64× | 82 / 53 ns = 1.56× |
   | direct timing | 152 ns | 54 ns |
   | with a probe present at load (the client case) | | 35 ns |

   `lookup` is already at parity (1.02×). Not changed: first-miss (2.4×,
   the missing-key set `MissingKeys` needs) and register (1.35×, per-string
   validation). No memory change.
7. Tests: the fast path returns `nil` for an unneeded locale of a known
   addon; a first call, options, an unknown locale code, a non-string or
   empty name, and a secret name or locale each take the full path with
   today's messages at the caller's line; the probe rule (present at load,
   installed after load: `SecretValues_spec:26` keeps passing); the
   `SecretValues_spec:60` case for the defensive `readMissing` branch is
   replaced by a client suite assertion; in-place upgrade from revision 4.
   Client suite (`tests/client/MoltenCodesTest_LocaleKit/`, never run
   here): `L[secretwrap("x")]` raises at the reading line, and nothing is
   recorded as missing.
8. Docs: `docs/API.md` (cost note, the secret-key read), `INTERNALS.md`,
   `CHANGELOG.md` 0.1.7, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.1.7,
   revision 5, 5 specs (124).

**registry cheaper lookups** — an internal change to facade `Registry`

1. Package `registry`, facade `Registry`, API generation 2 (unchanged),
   version 0.6.11, implementation revision 16 (from 0.6.10, revision 15).
   Patch. The file stays within its 1000-line budget.
2. Purpose: bring `Get`, `Find` and `Register` lookups closer to LibStub's,
   following the runtime performance diagnosis of 2026-11-15 (registry).
   - The secret-probe rule: `issecretvalue` resolved once at load, looked
     up per call only when it was absent at load, in `isSecret`
     (`Registry.lua:74`) and `lookUp` (`:250`).
   - Owner decision needed: plain indexing on the hit path. `lookUp` reads
     the package bucket, the entry and its two fields with `rawget` and
     checks each with `type`. Indexing them plainly is where the gain is
     (item 6), but `docs/API.md` ("Lookup cost") promises that a hit "reads
     the state with raw access". Plain indexing keeps every shape check
     (the corruption checks stay, and `Corruption_spec` and `FastPath_spec`
     pass). It drops that promise, though: a metatable that foreign code
     puts on the shared state could then answer a missing bucket or field.
     No form of plain indexing keeps the promise for less: a `getmetatable`
     test on the three tables costs what the `rawget`s cost. Unless the
     owner drops the sentence, the hit keeps raw reads and takes only the
     probe rule.
   - Decision 19b: none applies. The secret checks in Registry guard
     arguments before they are compared or used as keys, so the error is
     raised at the caller's line; the client's own refusal would raise
     inside Registry. The sealed facade's `__newindex` (`:712`) asks about
     the key it describes. Whether the client refuses a secret key on
     assignment before `__newindex` runs has not been measured, so that
     check stays.
3. Dependencies: none (Registry is the root).
4. Surface: unchanged. With plain indexing, the "Lookup cost" paragraph
   loses "reads the state with raw access" on the hit. The bootstrap and
   facade checks keep raw access in either case.
5. Ownership: unchanged. The load-time probe is file-local to each
   embedded copy. An in-place upgrade from revision 15 keeps every entry.
6. Performance and memory, host bench `libraryRegistry` workload,
   MoltenCodes ÷ LibStub in the same run (two runs on 2026-11-15, the
   unmodified file against each variant):

   | Case | Before | Probe rule only | Probe rule and plain indexing |
   |---|---:|---:|---:|
   | lookup | 3.54× | 3.35-3.38× | 2.53-2.60× |
   | silent-miss | 5.00-5.05× | 4.84-4.97× | 4.02-4.09× |
   | stale-copy | 1.77-1.83× | 1.74× | 1.44-1.45× |
   | upgrade | 1.18-1.20× | 1.20× | 0.96-1.01× |
   | new-library | 1.91-2.12× | 1.93-2.08× | 1.56-1.81× |

   The target "Ace3/LibStub level" is not reached by either form: a hit
   still runs the probe and the shape check, and a miss runs the name
   pattern. No memory change. Registry lookups happen mostly at load. The
   hot-path cost is the call-time lookups other Kits make, which those
   Kits should resolve once.
7. Tests: the probe rule (present at load, installed after load); a hit
   with a malformed entry still raises the corruption error at the caller;
   a secret name or API still refused before use as a key. With plain
   indexing: the rewritten "Lookup cost" claim, and a spec that a bucket
   carrying a foreign metatable is refused, not read through. In-place
   upgrade from revision 15. Line budget: the file stays at or under 1000
   lines. Client suite (`tests/client/MoltenCodesTest_Registry/`, never run
   here): unchanged.
8. Docs: `docs/API.md` ("Lookup cost"), `CHANGELOG.md` 0.6.11,
   `tests/README.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.11,
   revision 16, plain indexing on the owner's decision (Registry's state
   carries no metatable; the docs/API.md "Lookup cost" sentence replaced), 2
   specs (143), 999 lines.

**codecKit key descriptions, lazy tables and cheaper scans** — a fix and an internal change to facade `CodecKit`

1. Package `codecKit`, facade `CodecKit`, API generation 1 (unchanged),
   version 0.2.2, implementation revision 9 (from 0.2.1, revision 8).
   Patch: a defect fix and internal changes, no public surface added.
2. Purpose: fix the last live `tostring(key)` refusals, cut the memory held
   by tables a session may never use, and bring encode and decode down to
   AceSerializer-3.0's cost, following the architecture plan (item 3), the
   memory diagnosis (fix 2) and the runtime performance diagnosis of
   2026-11-15 (codecKit).
   - Defect: `validateOptionKeys` (`CodecKit.lua:3530`) and
     `validateLimitUpdate` (`:3672`) build their refusal with
     `tostring(key)`. A table key with `__tostring` therefore runs the
     caller's code inside CodecKit. Both take a `describeKey` that names a
     string as itself, a number or boolean through `tostring`, a secret as
     `<secret>` and anything else by type (`<table>`), the convention of
     ApiKit, CacheKit, CompatKit and EventKit. A secret key is refused
     first ("must not have a secret key"), before `known[key]` would raise
     inside CodecKit, as BridgeKit's `SetLimits` does.
   - Lazy tables: the DEFLATE tables (`:1523-1859`: length and distance
     bases and extras, the fixed codes and decoders) are built on the
     first Lua compression or decompression, never when the client's
     native path serves it. The print tables `PRINT_CODES` and
     `PRINT_DIGITS` (`:3033`) are built on the first print-safe encode or
     decode. `BYTE_TEXT` and `ADDON_BYTE_TEXT` (`:739-746`) are built on
     the first encode. After the first call the hot paths allocate nothing,
     as today.
   - A bounded clean-string cache: up to 256 strings of at most 32 bytes
     that the addon-channel escape scan found clean, filled once and never
     wiped. The secret check in `writeValue` (`:1069`) still runs before
     the lookup.
   - Plain finds: the escape and forbidden-byte scans over a whole frame
     (`:3000` in `decodeForAddon`, `:3360` in the frame reader) and over a
     string the cache does not hold (`:1101`) use one plain
     `string.find(text, byte, start, true)` per byte (four for the
     forbidden set, five with the escape byte) instead of a character
     class, which Lua 5.1 tries at every start position. This one was not
     in the diagnosis: it was measured for this record (item 6).
   - Options in one pass: `readEncodeOptions` checks unknown keys,
     `compress`, `channel` and `level` inline, in the same order and with
     the same messages and levels, reading the probe once. That probe is
     passed to `openWork`, which no longer reads it again. A handoff to a
     raising helper is never a tail call, so errors stay at the caller's
     line. The prototype's second copy of this reader for clients without
     a probe is not taken: one reader is easier to keep right.
   - The secret-probe rule: `readSecretProbe` (`:325`, read on every call
     today) answers the probe resolved at load, and looks it up again only
     when it was absent at load.
3. Dependencies: unchanged (registry API 2, poolKit API 1, schedulerKit
   API 1 for the asynchronous calls).
4. Surface: unchanged methods, reasons and limits. Messages change only
   for a non-string key: `options.<table> is not a recognised option` and
   `limits.<table> is not a recognised limit`, not the address `tostring`
   printed. A secret key is refused at the caller's line.
5. Ownership: the lazily built tables and the cache are file-local and
   built by each revision on first use. They hold constant data derived
   from code, so a copy in `_state` would need validation for nothing, and
   an upgraded revision builds its own once. Nothing is saved. The cache
   holds up to about 14 KB of caller strings for the session. The main
   chunk holds 180 of 200 locals; the lazy tables become fields of one
   table each.
6. Performance and memory, host bench `codec` workload (compression off,
   addon channel), MoltenCodes ÷ AceSerializer-3.0 in the same run, rerun
   2026-11-15. "Prototype" is the diagnosis prototype (cache, one-pass
   options); "this record" adds the plain finds:

   | Case | Before | Prototype | This record (expected) |
   |---|---:|---:|---:|
   | encode small | 1.59× | 1.28× | 1.28× |
   | encode medium | 1.53× | 1.25× | 1.25× |
   | encode large | 1.22× | 1.05× | 1.10× (noise) |
   | decode small | 1.26× | 1.28× | 1.08× |
   | decode medium | 1.15× | 1.12× | 0.95× |
   | decode large | 0.87× | 0.87× | 0.76× |

   The scan alone, clean text, best of 7: 32 B 237 → 96 ns, 200 B
   1,383 → 113 ns, 2,000 B 14,269 → 296 ns, 20,000 B 134,965 → 1,565 ns.
   Resident memory: −86.8 KB until used (memory diagnosis, exact drop:
   DEFLATE 59.0 KB, byte text 18.5 KB, print 9.3 KB), up to +14 KB for the
   cache. Decode reaches the target "below AceSerializer" on medium and
   large, and small comes within 8%. Encode does not: the remaining fixed
   cost per call is the facade check, the work record and the counting pass
   the wire format needs (the count comes before the entries). Two more
   items will be tried and kept only if they measure faster: a flat
   `Encode` for the synchronous uncompressed case, and an inline common
   path in `appendNumber`.
7. Tests, failing first for the defect:
   - a table key with a `__tostring` that counts its calls, given to
     `Encode` options and to `SetLimits`: refused, the message names
     `<table>`, the metamethod never ran; a function key likewise; a
     secret key refused at the caller's line;
   - lazy tables: absent after load, built by the first Lua compression,
     decompression or print-safe call, not built when the native path
     serves the call; round trips unchanged;
   - output byte for byte equal to revision 8 on the bench payloads and on
     strings holding each forbidden and escape byte at the first, middle
     and last position;
   - frames with a forbidden byte or a bad escape after the header refused
     with the same reasons;
   - the cache: as BridgeKit's, the cap respected, a secret refused before
     the lookup;
   - option errors in the same order, messages and levels (the ErrorLevels
     specs);
   - the probe rule: present at load, installed after load;
   - in-place upgrade from revision 8, with an asynchronous job running.
   Client suite (`tests/client/MoltenCodesTest_CodecKit/`, never run here):
   a `SetLimits` with a table key carrying `__tostring` is refused without
   running it.
8. Docs: `docs/API.md` (key descriptions in the refusals, cost notes),
   `INTERNALS.md` (lazy tables, the cache, plain finds, one-pass options),
   `CHANGELOG.md` 0.2.2, `README.md` performance and memory notes,
   `tests/README.md`, the client suite's `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.2.2,
   revision 9, 16 specs (165). A flat `Encode` and an inline number path were
   not tried: the profile puts the remaining cost per value.

**bridgeKit AceSerializer speed and SettingsKit's character key** — an internal change to facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API generation 1 (unchanged),
   version 0.5.2, implementation revision 7 (from 0.5.1, revision 6).
   Patch: no public method is added or removed.
2. Purpose: bring the AceSerializer-3.0 format closer to AceSerializer's
   own cost, byte for byte the same output, following the runtime
   performance diagnosis of 2026-11-15 (codecKit and bridgeKit, causes 1
   and 4), and key the current character the way SettingsKit does.
   - Writer: `append` (`BridgeKit.lua:648`) inlined on the string and
     number paths, one bound check for the tag and its text together.
   - Limits read as numbers once per call: `UNBOUNDED` becomes `math.huge`
     in `serialize` and the reader's entry point, so `exceeds()` (`:616`)
     is no longer called per value on either side.
   - Reader: `nextToken()` (`:841`) inlined, one Lua call less per token.
   - `unescape` (`:846`) without a closure per escaped string: one
     replacement function for every call, its refusal flag an upvalue reset
     per string (`string.gsub` cannot re-enter it).
   - The open-table set `onPath` (`:701`) becomes a stack indexed by depth,
     compared with `rawequal`, so it no longer rehashes as tables open and
     close. The walk is bounded by `maxDepth`.
   - A bounded clean-string cache: up to 256 strings of at most 32 bytes,
     recorded only when the escape scan finds nothing to escape, filled
     once and never wiped (a wipe-when-full version thrashed on the large
     payload). The secret check still runs before the lookup.
   - The secret-probe rule: `issecretvalue` resolved once at load (`:381`
     reads it on every call today), looked up per call only when it was
     absent at load.
   - Character key: SettingsKit gains `SettingsKit:GetCharacterKey()`
     (`UnitNameUnmodified("player")` first, then `UnitName("player")`, with
     the realm) in its next revision. `noteCharacterKeys` (`:3694-3735`)
     asks it through the SettingsKit facade that `Registry:Find("settingsKit",
     1)` returns (as `:4258` already does for the profile-name limit) when
     the method is present, and otherwise applies the same rule itself.
     The `characterKeyMismatch` entry for "`UnitNameUnmodified` differs
     from `UnitName`" then goes away: AceDB and SettingsKit key that
     character alike. The report for clients whose interface lies between
     16000 and 19999 (`char` and `realm` keyed by name and ruleset) stays.
   Not in this record: plain finds for the escape scan (the pattern
   `"[%c \094\126\127]"` covers 35 bytes, space among them), and the checks
   that refuse a secret key met while walking a caller's table (`:576`,
   `:1493`, `:1762`, `:2450`, `:2933`, `:4155`, `:4946`, `:5091`). Decision
   19b covers a secret used to index a table, which the client refuses at
   the read. It has not been measured that the client also refuses to store
   a secret key, or never hands out a table holding one, so those checks
   stay until a client suite shows it.
3. Dependencies: unchanged. SettingsKit stays optional:
   `GetCharacterKey` is used when the loaded SettingsKit has it.
   `UnitNameUnmodified`, `UnitName` and `GetRealmName` are read as today
   through `askClient`.
4. Surface: unchanged methods, errors, limits and reasons. The preview
   report no longer carries `characterKeyMismatch` for a character whose
   unmodified name differs from its name. It still reports
   `currentCharacterMissing` when the key SettingsKit will use is absent
   from `char`, and keeps the ruleset `characterKeyMismatch` and
   `realmKeyMismatch` entries.
5. Ownership: the clean-string cache, the replacement function and the
   depth stack are file-local and rebuilt by each revision's load; nothing
   is saved and nothing new goes into `_state`. The cache holds up to about
   14 KB of caller strings for the session (Lua 5.1 never collects strings
   from weak tables, so the size cap is the bound). An in-place upgrade from
   revision 6 needs no migration.
6. Performance and memory, host bench, MoltenCodes ÷ Ace3 in the same run
   (the diagnosis prototype, `aceSerializer` workload; output compared
   byte for byte with `cmp`):

   | Case | Before | After (expected) |
   |---|---:|---:|
   | encode small / medium / large | 1.78 / 1.75 / 1.73× | 1.37 / 1.27 / 1.37× |
   | decode small / medium / large | 1.50 / 1.40 / 1.37× | 1.28 / 1.16 / 1.15× |

   Decode allocation: small 832 → 720 B, medium 26,110 → 20,510 B, large
   93,919 → 71,459 B (Ace3: 600, 20,384, 71,050 B). Held memory: up to
   +14 KB for the cache. The target "below AceSerializer" is not reached by
   any measured change. What remains is the documented work AceSerializer
   does not do: limits, cycle refusal, secret checks and the re-entrancy
   guard.
7. Tests:
   - byte-identical output against the current revision for payloads with
     escapes, floats, negatives, 2^40, `math.huge` and nested tables;
   - each limit at its bound and one past it, bounded and `UNBOUNDED`, on
     both sides;
   - a cycle refused at every depth up to `maxDepth`, and a table met twice
     on different branches accepted;
   - every escape and every refused escape through the closure-free
     `unescape`, including a refused one followed by a valid string (the
     flag resets);
   - the cache: a clean short string written twice, a string that needs
     escaping never recorded, strings over 32 bytes never recorded, the
     cap respected, a secret refused before the lookup;
   - the probe rule: present at load, installed after load;
   - character key: `GetCharacterKey` used when SettingsKit has it; the
     same key without it; no `characterKeyMismatch` for an unmodified name
     that differs; the ruleset entries unchanged; `currentCharacterMissing`
     against the new key;
   - in-place upgrade from revision 6.
   Client suite (`tests/client/MoltenCodesTest_BridgeKit/`, never run
   here): the preview names the current character under the key
   `UnitNameUnmodified` gives.
8. Docs: `docs/API.md` (the preview's character-key paragraph, the
   AceSerializer cost notes), `INTERNALS.md` (the inlined writer and
   reader, the cache, the depth stack), `CHANGELOG.md` 0.5.2, `README.md`
   performance note, `tests/README.md`, the client suite's `EXPECTED.md`.
   `docs/BRIDGE_KIT_DESIGN.md` section 7.3 ("Scope by scope", the `char`
   row) follows the new rule; that file is outside the package, so its text
   is supplied for the owner to apply.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.2,
   revision 7, 11 specs (302); the store-side key checks stay on the owner's
   decision; docs/BRIDGE_KIT_DESIGN.md 7.3 updated.

**clientKit probe fallback and value descriptions** — a fix to facade `ClientKit`

1. Package `clientKit`, facade `ClientKit`, API generation 1 (unchanged),
   version 0.3.2, implementation revision 8 (from 0.3.1, revision 7).
   Patch.
2. Purpose: bring ClientKit to the secret-probe rule every Kit follows, and
   fix a `tostring` on caller values.
   - The secret-probe rule: `bindHostFunctions` (`ClientKit.lua:703`)
     already resolves `issecretvalue` at load, but without a fallback. When
     it was absent at load, `IsSecret`, `validateNotSecret` and
     `describeValue` (`:751`, `:779`, `:874`) now look it up on each call,
     so a probe installed later is honoured. `Has("secretValues")` stays
     the load-time answer it documents.
   - Defect: `describeValue` (`:750`) ends in `tostring(value)`, so a table
     with `__tostring` given as a capability name (`Has`), a limit key
     (`SetLimits`, `:1716`) or a key written to a manifest snapshot
     (`:1067`) runs the caller's code inside ClientKit. It now names a
     table, function, thread or userdata by type (`<table>`), and keeps
     `%q` for strings and `tostring` for numbers, booleans and `nil`.
   - Decision 19b: none applies. ClientKit's secret checks guard arguments
     and the client's own answers. The manifest snapshot's `__newindex`
     describes the key it refuses, and that check stays until a client
     suite shows that a secret key is refused on assignment before
     `__newindex` runs.
3. Dependencies: unchanged (registry API 2).
4. Surface: unchanged methods. Messages that named a table by its address
   now name it `<table>`. `IsSecret` honours a probe installed after load.
5. Ownership: unchanged; the host table in state keeps the load-time
   binding. An in-place upgrade from revision 7 rebinds as today.
6. Performance and memory: with the probe present at load (every client
   with secret values), nothing changes. Without it, each check makes one
   `rawget(_G)` more, about 14 ns. No memory change.
7. Tests, failing first for the defect: a `__tostring` table given to
   `Has`, as a `SetLimits` key and as a manifest field name, each refused
   naming `<table>` with the metamethod never run; the probe installed
   after load honoured by `IsSecret`; in-place upgrade from revision 7.
   Client suite (`tests/client/MoltenCodesTest_ClientKit/`, never run
   here): assigning `manifest[secretwrap("x")] = 1` either raises at the
   assigning line before `__newindex` runs or is refused with
   `<secret>` (the suite records which, for decision 19b).
8. Docs: `docs/API.md` (value descriptions in errors, the probe rule),
   `CHANGELOG.md` 0.3.2, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.3.2,
   revision 8, 4 specs (182); the client suite records whether a secret key is
   refused on assignment before `__newindex`.

**widgetKit (package O): a core and parts, pools on first use, no upgrade residue, and widget cycles at AceGUI's cost** — a change to facade `WidgetKit`

1. Package `widgetKit`, facade `WidgetKit`, API generation 1 (additive),
   version 0.5.0 (from 0.4.1), implementation revision 14 (from 13). The
   package becomes a core file `src/WidgetKit.lua` plus eleven part files
   `src/parts/WidgetKit-<Part>.lua`, each at part revision 1 (ADR 0001).

2. Purpose: an addon pays only for the widgets it uses, and the widget
   cycles cost no more than AceGUI-3.0's.

   Measured today (host Lua 5.1.5, debug information kept, shared fake
   client): WidgetKit holds 355.1 KB resident, and an addon that embeds it
   also loads PoolKit (78.9 KB) and SignalKit (80.8 KB), whatever it draws.
   Of the 355.1 KB, the widget types are 73.5 KB in their six largest
   sections alone, the renderer 37.5 KB, thirteen empty PoolKit pools built
   at load 34.6 KB (2.7 KB each), and an older copy upgraded in place leaves
   14.1 KB of its code reachable. The main chunk holds 189 of Lua 5.1's 200
   locals. On the bench, the `Button` cycle costs 1.41× AceGUI's and the
   `Slider` cycle 1.62× (456 against 269 VM instructions and 56 against 39
   calls per `Button` cycle; 882 against 601 and 113 against 75 per
   `Slider` cycle).

   The changes:

   - **Core and parts (ADR 0001).** The core keeps what every widget needs:
     constants, the shared prototypes, Registry bootstrap, host helpers,
     argument checks, widget records, the widget base, the container base,
     the `List`, `Fill` and `Flow` layouts, the type registry with pooling,
     focus, statistics, limits, the shared widget helpers (text checks,
     `showText`, label colours) and the part machinery. Everything else
     moves into parts:

     | Part | Holds | Needs |
     |---|---|---|
     | `Containers` | `Frame`, `Group`, `ScrollFrame` | the core |
     | `Text` | `Label`, `Heading`, `Spacer` | the core |
     | `Button` | `Button`, key capture included | the core |
     | `CheckBox` | `CheckBox` | the core |
     | `Slider` | `Slider` | the core |
     | `EditBox` | `EditBox`, single and multi-line | the core |
     | `Dropdown` | `Dropdown`, its list catcher, `CreateMediaPicker` | the core; MediaKit API 1 optional |
     | `ColorPicker` | `ColorPicker` | the core |
     | `ScrollList` | `ScrollList` | the core |
     | `Position` | `WidgetKit.Anchor`, `BindPosition`, the binding methods | the core; SignalKit API 1; SchedulerKit API 1 optional |
     | `Renderer` | `RenderOptions`, the rendering methods, `childGroups` pages | parts `Containers`, `Text`, `Button`, `CheckBox`, `Slider`, `EditBox`, `Dropdown`, `ColorPicker`; OptionsKit, SchedulerKit, MediaKit API 1 optional |

     Controls get a part each, as AceGUI gives each widget a file, so a
     window with a button does not carry a slider. The three small display
     types share `Text` and the three containers share `Containers`,
     because a part has a fixed cost (its record, its bind function and
     its stubs, at most 1 KB) that one tiny type would not repay. An addon
     that embeds every part behaves as today.

   - **The core needs only Registry.** PoolKit and SignalKit leave the
     core's dependencies: SignalKit carries only a binding's `OnMoved`
     listeners and moves to the `Position` part; PoolKit is replaced as
     below.

   - **Pooling inside the core, pools on first use.** Each type keeps its
     own free list (an array of idle widgets), its cap, its created,
     borrowed and discarded counts, and its version as the generation, in
     its type record. The array is created by the first `Create` of the
     type, never at load or at registration. This removes the second layer
     of pool bookkeeping (WidgetKit's records plus PoolKit's maps, 105 VM
     instructions and 8 calls per cycle measured in PoolKit alone) and the
     34.6 KB of empty pools. Behaviour is PoolKit's as WidgetKit used it:
     the cap counts every frame a type ever built, every released widget is
     kept, a raised version retires idle widgets of older versions at once
     and borrowed ones when they come back, the cap grows by what an
     upgrade retires within `maxCreatedCeiling`, a constructor that raises
     or breaks the author contract is raised at the caller of `Create`. The
     constructor runs under `pcall` only when a widget is built; taking an
     idle widget calls nothing protected. Layout scratch tables become one
     retained table per layout depth (at most `MAX_LAYOUT_DEPTH`, 32) in
     the core's state, replacing the PoolKit table pool.

   - **No upgrade residue.** Two causes, both measured (a revision 11 copy
     upgraded by revision 13 keeps 174 of its functions reachable): pool
     callbacks created by the older file, and base types whose version did
     not change keeping the older file's constructor, through which the
     older copy's helpers stay alive. Fixes: the free lists need no
     per-type callbacks at all; a built-in type registered by WidgetKit's
     own part at an equal version replaces the constructor (only the public
     `RegisterType` keeps answering `false, "current"`), so the older
     constructor is unreferenced; and parts reach core helpers through a
     bind step (below) instead of capturing an older core's functions.
     Widgets an older revision built and pooled keep that revision's type
     methods for their life, as the versioning rule has always said; an
     addon builds its widgets after loading, so a session upgraded during
     load has none.

   - **Part machinery.** The core's state gains `parts`: part name to
     `{ revision, bind, members }`. A part file resolves its core through
     `Registry:Get("widgetKit", 1)` at file scope and raises
     `MoltenCodes WidgetKit part <Part> requires WidgetKit API 1 to be loaded
     first` without it; it returns at once when an equal or newer revision
     of itself is installed. Otherwise it registers its types through the
     core's internal registration, installs its members, and records itself.
     Core helpers reach a part through `bind(helpers)`, which assigns the
     part's local upvalues from `state.helpers`; the core calls every
     installed part's `bind` again when a newer core revision loads, so
     every part runs the newest helpers with no per-call lookup and no
     older helper kept alive. `state.helpers` is additive inside API 1: a
     helper's arguments and meaning never change; a change is a new name.
     A part may rely on a core at least as new as the one it shipped with,
     because an addon's own core file loads before its parts.

   - **Members of parts that are not loaded.** The facade and the shared
     prototypes stay complete, so every revision's surface check (Registry
     calls an older copy's check on a newer facade) passes whichever parts
     are loaded. For each member a part provides, the core installs, in
     order of preference: the loaded part's function; a function an older
     single-file revision installed (an upgrade from revision 13 or older
     with the part absent keeps that copy's renderer, bindings, anchors and
     media pickers working); a stub that raises at the caller's line
     `WidgetKit:RenderOptions is in WidgetKit's Renderer part, which is not
     loaded: add widgetKit\parts\WidgetKit-Renderer.lua to embeds.xml (or
     rebuild it with python3 -m tooling.package.embeds)`. `Create` of a base
     type whose part is absent raises the same form
     (`WidgetKit:Create Slider is in WidgetKit's Slider part, ...`) instead
     of answering `nil, "unknownType"`; names WidgetKit does not ship still
     answer `nil, "unknownType"`. `GetTypeVersion` answers `nil` for an
     absent type, so code can ask without raising. `Frame:BindPosition`
     raises the `Position` form when that part is absent; the `Containers`
     part does not require `Position`.

   - **Renderer extension points, for the AceConfigDialog work that follows
     on this split.** The `Renderer` part keeps, in its part state, four
     registries a later part fills without editing the renderer:
     `kinds` (option kind to the widget type, configure, apply and write
     functions; a custom-control part such as `dialogControl` picks another
     type per option), `decorators` (an ordered list called after a node's
     widget is built and at every refresh; tooltips for `desc`, `width`,
     inline descriptions and images attach here), `pageStyles`
     (`childGroups` value to the page builder; a widget-set part registers
     real tab, tree and select containers and the renderer prefers them)
     and `confirm` (the provider asked before a confirmed write or execute;
     the inline question is the default, a DialogKit part replaces it). Each
     entry carries its part's revision and the highest wins. The dialog
     layer (`OpenOptions` and its family) is a later part that adds facade
     members, with core stubs added in that revision. Constructor changes
     the later work needs (`OnEnter`/`OnLeave`, images, value limits,
     radio, multiselect) are revisions of the type parts that raise those
     types' versions, not new parts.

   - **Cycles at or below AceGUI's.** On top of the pooling change:
     - *The probe rule.* `issecretvalue` is read once at load; when it was
       absent at load, each check reads `rawget(_G, "issecretvalue")` and
       accepts it only as a function, so a probe installed later is
       honoured. Today `Create`, `isSecret`, `validateNumber` and the text
       checks read `_G` on every call (5 `rawget` per `Button` cycle, 9 per
       `Slider` cycle).
     - *Setters without repeated `type()` calls.* Today 16 `type` calls per
       `Button` cycle and 27 per `Slider` cycle. A checked value is typed
       once: the probe first, then one `type` test, then plain comparisons
       (`validateNumber`, `checkText`, `readDisabled`, the slider's `step`).
       Under ADR 0002 the checks that guard only a table index of a caller's
       value go: `type(widget) == "table" and records[widget]` becomes
       `records[widget]` (`Release`, `IsWidget`, `SetFocus`, `activeRecord`),
       `Create` and `GetTypeVersion` index `types[name]` before testing the
       name for their error message, and user-data keys are not probed
       before `userData[key]`. `docs/API.md` "Secret values" lists each,
       with the client's message (`attempted to index a table that cannot be
       indexed with secret keys`) as what a secret key now meets.
     - *Built-in hooks unprotected.* The `OnAcquire` and `OnRelease` hooks
       of WidgetKit's own types are called directly (the type record
       carries `trusted = true`, set only by the internal registration);
       custom types keep both `pcall`s and their documented behaviour. With
       the free list this takes the built-in cycle from three `pcall`s to
       none; a consumer's `OnRelease` callback stays protected.
     - *Slider text rewritten only on change.* The low and high labels are
       written only when `SetSliderValues` changes the range; the value
       text is formatted only when the value or the percent mode changed
       (the widget keeps the value and the text it formatted), and the box
       is written with that text at every store, because the user may have
       typed into it. Today four `string.format("%.10g")` calls per cycle.
     Non-goals: `x == nil` in place of `type(x) == "nil"` on values that
     may be secret (whether a secret compares with `nil` is not verified in
     the client; the guards that stay are the ones before such a
     comparison); removing the consumer callback's `pcall`; any change to
     what a widget draws.

   Non-goals of the whole record: new widgets, new option fields or any
   AceConfigDialog feature (the renderer round that follows builds on the
   extension points above); a second API generation; assembling parts into
   one file; changing PoolKit or SignalKit.

3. Dependencies:
   - Core: Registry API 2, required. Nothing else. PoolKit and SignalKit
     leave `dependencies`; SettingsKit stays an optional dependency in name
     only (a documented storage shape for `BindPosition`), moved to the
     `Position` part's `optionalDependencies`. OptionsKit, SchedulerKit and
     MediaKit move to the parts that use them.
   - Parts, as the table in point 2; manifest `parts` entries carry them
     (`Position`: `dependencies` signalKit API 1, `optionalDependencies`
     schedulerKit and settingsKit; `Dropdown`: `optionalDependencies`
     mediaKit; `Renderer`: `optionalDependencies` optionsKit,
     schedulerKit, mediaKit, and `parts` as listed).
   - Host requirements unchanged; the flavour gate keeps guarding every
     client call, now per file.
   - Dependents: PanelKit renders through `RenderOptions` and creates
     `Label` and `ScrollFrame`. Its manifest contract becomes
     `"widgetKit": { "api": 1, "parts": ["Renderer"] }` (the renderer's
     parts include `Containers` and `Text`), and its load check asks
     `WidgetKit:GetPartRevision("Renderer")` rather than the type of
     `RenderOptions`, which the stub always satisfies. The exact text goes
     to PanelKit's owner; until it lands PanelKit keeps loading because the
     stub is a function, and fails at its first render with the stub's
     message, which names the part.
   - Load order (generated by `tooling.package.embeds`): Registry, the core,
     then the selected parts, `Renderer` after its sibling parts, `Position`
     after SignalKit.

4. Surface:
   - Unchanged: every API 1 member, argument error and level, every
     `docs/API.md` behaviour, the base type versions (`Frame` 4, `Group` 3,
     `ScrollFrame` 1, `Label` 3, `Button` 3, `CheckBox` 4, `Slider` 4,
     `EditBox` 4, `Dropdown` 4, `ColorPicker` 4, `Heading` 3, `Spacer` 1,
     `ScrollList` 2; no constructor changes what it builds), and
     `GetStatistics` per type (`maxCreated`, `created`, `active`,
     `available`, `discarded`; a type registered but never created reports
     zeros and its cap).
   - Added: `WidgetKit:GetPartRevision(partName)` → the installed part's
     revision, or `nil`. `partName` must be a non-empty string; a name
     WidgetKit does not ship answers `nil`.
   - Changed, only where a part is missing (impossible before this
     revision): the stubs' errors and `Create`'s error for a base type
     whose part is absent, as in point 2. Loading the core without PoolKit
     or SignalKit no longer raises; loading the `Position` part without
     SignalKit raises `MoltenCodes WidgetKit part Position requires
     SignalKit API 1 to be loaded first`.
   - Changed by ADR 0002: a secret used as a widget receiver, a type or
     layout name, or a user-data key meets the client's own refusal instead
     of WidgetKit's message. Every other secret check stays.
   - `WidgetKit.Anchor.POINTS` is `nil` until `Position` loads (the four
     anchor functions are stubs).
   - Files: `src/WidgetKit.lua` and `src/parts/WidgetKit-Containers.lua`,
     `-Text`, `-Button`, `-CheckBox`, `-Slider`, `-EditBox`, `-Dropdown`,
     `-ColorPicker`, `-ScrollList`, `-Position`, `-Renderer`, each with the
     file header and Contents list, `PART_REVISION = 1`, LuaCATS types and
     doc comments. Main-chunk locals: the core at most 120, each part at
     most 60 (the `lua_limits` ratchet entry for `WidgetKit.lua`, 189
     today, goes down).

5. Ownership:
   - The core's state keeps everything shared: types (with their free
     lists), records, layouts, prototypes, metatables, limits, focus,
     scratch tables, `helpers`, `parts` and `dispatch`. A part keeps its own
     data under `state.parts.<Part>` (the renderer's extension registries,
     the dropdown catcher, the list's dispatch entries) and never a copy of
     core state.
   - Frame scripts and long-lived callbacks call through `dispatch`
     (already true for the dropdown catcher, binding saves and list rows),
     so the newest revision of the part that wrote the entry serves widgets
     an older one built.
   - Upgrade from revision 13 or older, in place: the state is kept; for
     each type that has a PoolKit pool, the idle widgets are taken out of it
     (`Acquire` while `GetAvailableCount() > 0`, which never builds), put on
     the new free list, and the created, discarded and cap counts copied;
     the pool is then dropped and collected with its maps; borrowed widgets
     return to the free list when released. `state.scratch` (the PoolKit
     table pool) is dropped. Older revisions' members for absent parts are
     kept, as in point 2. Upgrade of a part: the higher part revision
     replaces members, constructors at equal versions and its extension
     entries. Upgrade of the core with parts loaded: the new core re-binds
     each part.
   - Known limit, documented in `docs/API.md` "Embedded copies and
     upgrades": when a core of revision 14 or later loads first and a
     single-file copy of revision 13 or older loads after it, the older
     copy yields (Registry selects the newer) and registers nothing; that
     addon's widgets whose parts no addon loaded raise the not-loaded error
     naming the part. Only a newer embedding of the older addon fixes it,
     as for any Kit whose newer revision a session selects. The opposite
     order (older first) keeps working.

6. Performance and memory. Today's figures measured 2026-11-15; the
   targets are estimates (each section's resident prototypes times 1.39,
   WidgetKit's measured ratio of resident bytes to prototype bytes without
   the pools) that phase 2 measures with the same scripts and reports
   against this table.

   | Resident (debug info kept) | Today | Target | AceGUI-3.0 counterpart |
   |---|---:|---:|---|
   | Core | 355.1 KB (everything) | at most 95 KB | AceGUI-3.0.lua 44.0 KB |
   | `Containers` | | at most 26 KB | Frame 18.0 + InlineGroup 4.8 + SimpleGroup 2.7 + ScrollFrame 11.3 = 36.8 KB |
   | `Text` | | at most 15 KB | Label 8.2 + Heading 3.8 = 12.0 KB |
   | `Button` | | at most 9 KB | Button 4.7 + Keybinding 13.1 = 17.8 KB |
   | `CheckBox` | | at most 8 KB | CheckBox 13.0 KB |
   | `Slider` | | at most 15 KB | Slider 15.4 KB |
   | `EditBox` | | at most 16 KB | EditBox 14.5 + MultiLineEditBox 20.1 = 34.6 KB |
   | `Dropdown` | | at most 24 KB | DropDown 36.4 + DropDown-Items 19.6 = 56.0 KB |
   | `ColorPicker` | | at most 13 KB | ColorPicker 11.2 KB |
   | `ScrollList` | | at most 29 KB | none |
   | `Position` | | at most 30 KB | none in Ace3 |
   | `Renderer` | | at most 53 KB | AceConfigDialog-3.0 91.6 KB (with AceConfigRegistry 25.7 KB) |
   | Core and every part | 355.1 KB | at most 335 KB | AceGUI-3.0.xml as shipped (core and 22 widget files) 347.5 KB |
   | Empty pools at load | 34.6 KB | 0 | none |
   | Upgrade residue | 14.1 KB | 0 (no widget built before the upgrade) | 0.2 KB |
   | Main-chunk locals | 189 | core at most 120, parts at most 60 | |

   What an addon holds, with the Kits it must embed (Registry 31.3 KB,
   PoolKit 78.9 KB, SignalKit 80.8 KB today):

   | Addon | Today | Target | Ace3 |
   |---|---:|---:|---:|
   | Core only (custom types) | 546.1 KB | at most 127 KB | LibStub + AceGUI core 46.6 KB; as shipped 350.1 KB |
   | A window: `Containers`, `Text`, `Button`, `CheckBox`, `EditBox` | 546.1 KB | at most 201 KB | the same five files by hand 109.8 KB; AceGUI-3.0.xml as shipped 350.1 KB |
   | Options rendering: `Renderer` and its parts | 546.1 KB | at most 306 KB (OptionsKit apart) | AceGUI as shipped + AceConfigDialog + AceConfigRegistry + CallbackHandler + LibStub 477.6 KB |

   Where the target stays above Ace3: the core is about twice AceGUI's
   core (validation, limits, secret checks and records that buy the
   documented guarantees), and Registry is twelve times LibStub. Against
   AceGUI as addons embed it (AceGUI-3.0.xml loads every widget file), every
   addon in the table holds less; against an AceGUI trimmed by hand to the
   same files, the window addon holds about 1.8× as much. Closing that is
   the shared-helper and shorter-prose work, not this record.

   Compile: an addon that embeds the window set compiles about a third of
   today's source (WidgetKit allocates 910 KB transient while loading
   today), and each further addon embedding it pays the same smaller
   amount.

   Widget cycles against AceGUI-3.0, same run (bench `widgets`, fake
   client, indicative):

   | Case | Today | Target |
   |---|---:|---:|
   | `cycle-label` | 0.79× | at most 0.75× |
   | `cycle-button` | 1.41× | at most 1.00× |
   | `cycle-checkbox` | 0.67× | at most 0.65× |
   | `cycle-slider` | 1.62× | at most 1.00× |
   | `cycle-editbox` | 1.02× | at most 0.95× |
   | Bytes per cycle | 0 | 0 |

   Basis: in the `Button` cycle the PoolKit layer is 105 of 456 VM
   instructions and 8 of 56 calls, the probe 5 `rawget` and 5 `type`
   calls, the three `pcall`s about 35 ns each beyond their bodies; the
   earlier prototype of the probe rule and the slider text alone reached
   1.32× on both. Phase 2 reports instruction and call counts per cycle
   beside the ratios, and names the remaining cost of any case that stays
   above its target.

7. Tests (Busted, `packages/widgetKit/tests/`; every existing spec keeps
   passing with the core and every part loaded; coverage floor kept, every
   part loaded by a spec of its own):
   - `Parts_spec.lua`: each part loaded alone after the core (types
     registered, members installed, `GetPartRevision`), a part before its
     core (the ADR message), `Position` without SignalKit, `Renderer`
     without one of its parts, every stub's message and level at the
     caller's line, `Create` of each absent base type naming its part,
     `GetTypeVersion` answering `nil`, `Frame:BindPosition` without
     `Position`, a part loaded twice (same revision returns), a higher part
     revision replacing members, constructors and extension entries, and a
     newer core re-binding loaded parts (a synthetic revision 15 copy).
   - `Pooling_spec.lua`: no free list before the first `Create`; cap,
     reuse, `exhausted`, version raise retiring idle and borrowed widgets,
     the cap grown within the ceiling, `GetStatistics` before and after first
     use, a raising and a contract-breaking constructor, the borrowed
     counts, layout scratch tables reused per depth with nothing allocated.
   - `Bootstrap_spec.lua` additions: upgrade from a revision 13 copy with
     every part (pooled widgets moved off PoolKit and reused, live widgets
     released into the free list, renderings and bindings kept, counts
     kept), upgrade from a revision 13 copy with the core only (its
     renderer, bindings, anchors and media pickers still serving), the
     revision 13 copy loading after a revision 14 core (yields; surface
     check passes; the not-loaded error for an absent part), and the
     residue: no function of the older file reachable after an upgrade with
     every part loaded (a reachability walk over `_G` and the registry, as
     the residue measurement does).
   - `Manifest_spec.lua`: runtime `REVISION`, every `PART_REVISION` and the
     manifest agree; the core's dependencies are Registry alone.
   - `RendererExtensions_spec.lua`: a test part registering a decorator, a
     kind override and a page style, each used by the renderer and replaced
     by a higher revision; the inline confirm as the default provider.
   - `FastPaths_spec.lua` additions: the probe resolved at load and a probe
     installed after load honoured; ADR 0002 receivers and keys (a secret
     reaches the index, modelled by the fixture's client rules); built-in
     hooks called without `pcall` and custom ones protected as before; the
     slider's labels written only on a range change and its text formatted
     only on a value change, the box written each time.
   - `Allocation_spec.lua` additions: zero bytes per warm cycle of the five
     bench types after the pooling change.
   - `ErrorLevels_spec.lua`: every stub and part-loading error at the
     caller's line.
   - The test environment loads the core and every part by default
     (`WidgetKitTestEnv`), with loaders for core-only and chosen parts.
   - Client suite `tests/client/MoltenCodesTest_WidgetKit` (never run):
     `GetPartRevision` for each part in the full bundle; a secret receiver
     and a secret user-data key meet the client's refusal (ADR 0002,
     consequence 3); the five bench widgets acquired, filled and released
     on real frames; `EXPECTED.md` updated.
   - Gates: stylua, `tooling.test.run widgetKit`, `tooling.test.coverage
     widgetKit`, lua-language-server on `src` and on the client suite,
     `tooling.lint`, `flavour_api --package widgetKit`, `tooling.spell`,
     `lua_limits` (ratchet lowered), `validate_repository` for the package.

8. Docs: `README.md` (what each part holds, the embeds command for the
   common selections, the AceGUI migration table mapping each
   `AceGUIWidget-*.lua` and `AceConfigDialog-3.0` to the part to embed),
   `docs/API.md` (Loading with parts, the parts table, `GetPartRevision`,
   the not-loaded errors, "Secret values" under ADR 0002, "Embedded copies
   and upgrades" for revision 14 and the known limit, the Deviations entry
   "One runtime file" replaced by the parts), `docs/INTERNALS.md` (free
   lists and generations, the part machinery, `bind`, stubs and inherited
   members, the renderer's extension points and their contract),
   `CHANGELOG.md` (0.5.0, revision 14), `tests/README.md`,
   `package.manifest.json` (`parts`, dependencies). Outside the package,
   with exact text in the phase 2 report: the `docs/EMBEDDING.md` footprint
   and parts blocks (generated), `docs/MIGRATING_FROM_ACE3.md` (AceGUI and
   AceConfigDialog rows naming parts), the ROADMAP placement of this
   record, the `packages/README.md` row, the coverage floor if parts change
   it, spell words, PanelKit's manifest contract and load check (its
   owner), and `tooling/bench` (`workloads.py` package list and the
   `Widgets.lua` adapter loading the parts; the client window workload).

9. Status: recorded 2026-11-15; code follows. Decided here and departing
   from widgetKit's first nine points: widgets are pooled by the core's own
   free lists rather than PoolKit pools (the measured cost of the second
   layer and of empty pools is what keeps the cycles and a core-only addon
   above AceGUI); PoolKit and SignalKit stop being required by the core.
   Depends on PanelKit's owner for its manifest contract and load check
   (point 3); nothing else blocks.

**SettingsKit namespaces, the four AceDB scopes and the remaining AceDB callbacks** (two records)

Basis: the decision 18 Ace3 gap diagnosis (namespaces, scopes and callbacks;
usage counted in sixteen open-source Ace3 addons), ADRs 0001 and 0003, and
AceDB-3.0's behaviour, read for behaviour only (nothing copied). Measurements:
host Lua 5.1.5 on a loaded machine, so ratios, not absolute times, are the
evidence. "Measured" means run; "estimate" means priced from measurements.

**Client facts used**

Read 2026-11-15 from Gethe/wow-ui-source, branches `live` `297d7aa` (12.1.5,
70783), `classic` `e5d9b3a` (5.5.4, 70631), `classic_era` `4192ac6` (1.15.9,
70576), the commits `packages/apiKit/metadata/*/provenance.json` was captured
from.

| Function | `live` | `classic` (Mists) | `classic_era` | Notes |
|---|---|---|---|---|
| `UnitRace(unit)` → `localizedRaceName, englishRaceName, raceID` | documented, `UnitDocumentation.lua:2836`, `SecretWhenUnitIdentityRestricted = true`, `MayReturnNothing = true` | not documented; called by Blizzard's own UI: `Blizzard_CharacterFrame/Cata/PaperDollFrame.lua:3896` (`local race, fileName = UnitRace(unit)`) | not documented; called by Blizzard's own UI: `Blizzard_CharacterFrame/Vanilla/PaperDollFrame.lua:91` | AceDB keys `race` by the second result |
| `UnitFactionGroup(unit)` → `factionGroupTag, localized` | `UnitDocumentation.lua:1179`, no secret flag | `:689` | `:689` | already used by SettingsKit |
| `GetRealmName()` | in `metadata/retail/namespaces.json` | in `classic-mop` | in `classic-era` | already used |
| `GetCurrentRegion()` → `region` (number) | `LocaleDocumentation.lua:40` | `:38` | `:38` | |
| `GetCurrentRegionName()` → `regionName` (string) | `ExpansionDocumentation.lua:46` | absent from `ExpansionDocumentation.lua` | absent | AceDB calls it unguarded on every client (`AceDB-3.0.lua:285`), which suggests the classic clients have it undocumented; **not verified**, so SettingsKit guards it and falls back as AceDB does |
| `GetLocale()` → `localeName` | `LocaleDocumentation.lua:49` | `:47` | `:47` | |

The flavour gate was run on a scratch copy of the repository with the four
reads added through SettingsKit's existing `callHost` helper (which returns
nothing unless the global is a function): `python3 -m
tooling.validation.flavour_api --package settingsKit` passes, with `UnitRace`
and `GetCurrentRegionName` reported as **guarded** on `classic-mop` and
`classic-era`. An allow-list entry for them would therefore be stale, and the
gate fails stale entries. See the report for the shared-file text this leads
to (a `host_names.json` entry instead).

AceDB-3.0's rules, read at `ac3d122`:

- Scope keys (`AceDB-3.0.lua:255-291`), read once when the library loads:
  `race` = second result of `UnitRace("player")`; `factionrealm` =
  `UnitFactionGroup("player") .. " - " .. GetRealmName()`;
  `factionrealmregion` = that `.. " - " ..` region, where the region is
  `({ "US", "KR", "EU", "TW", "CN" })[GetCurrentRegion()]`, else
  `GetCurrentRegionName()` unless it is `""`, else `"TR"`;
  `locale` = `GetLocale():lower()`.
- Callbacks: `OnNewProfile(db, key)` when a profile section is first created
  (`:215`, lazily, on the first `db.profile` access after `New`, `SetProfile`
  or `ResetDB`); `OnProfileShutdown(db)` at the start of `SetProfile`, before
  anything changes (`:502`); `OnDatabaseShutdown(db)` at `PLAYER_LOGOUT`, for
  every database, before defaults are stripped (`:397`); `OnDatabaseReset(db)`
  in `ResetDB`, followed by `OnProfileChanged` (`:731-733`).
- Namespaces (`:743-786`, `initdb` `:296-384`, logout `:391-440`): a child
  database over `sv.namespaces[name]` in AceDB's own layout minus
  `profileKeys`; it shares the parent's profile key; `SetProfile`,
  `CopyProfile`, `ResetProfile` and `DeleteProfile` cascade to every
  registered child (each child fires its own callbacks) and, for copy, reset
  and delete, to the raw `profiles` of namespaces nobody registered this
  session; `ResetDB` rebuilds every child; children expose only
  `RegisterDefaults` and `ResetProfile` of the profile methods; at logout
  empty sections and empty profiles inside namespaces, then empty namespaces,
  are removed. `RegisterNamespace` raises for a name already registered;
  `GetNamespace(name, silent)` raises for a missing one unless `silent`.

Corpus facts that shaped the design (`ace3-gaps/corpus`):

- Namespaces: 8/16 addons, 63 registrations, 145 `GetNamespace` calls.
  `Bartender4/Options/PresetsForever.lua:40` and 25 more sites write presets
  through `db:GetNamespace("ActionBars").profile`, so a child's views must
  take validated writes like a database's.
- Callbacks registered **on a namespace**: `oRA3/modules/Cooldowns/Cooldowns.lua:1118`
  (`self.db` is the namespace from `:1042`) listens to `OnProfileShutdown`.
  So children carry their own profile signals; the parent's alone is not
  enough (the gap report's "fire the parent's signals once" is refined below).
- `OnNewProfile`: `Bartender4/Bartender4.lua:49` and `:112-118` rely on it
  firing for the **first** profile of a new character, created right after
  `New`. SettingsKit's `Open` creates that profile before any listener can
  connect, hence `db:IsNewProfile()` below.
- `BigWigs/Core/Core.lua:609` registers one namespace per boss module it
  loads, which is why the namespace bound defaults well above the gap
  report's 64.

Baseline measured for this record (one run, `bench-before.json`, against
AceDB-3.0 in the same run; MoltenCodes `ad2626a`, SettingsKit revision 14):

| Case | SettingsKit ns/op | AceDB ns/op | Ratio | SettingsKit B/op | AceDB B/op |
|---|---:|---:|---|---:|---:|
| open-empty | 6,624 | 2,190 | 3.03x | 3,691 | 3,299 |
| open-populated | 9,580 | 4,195 | 2.28x | 4,704 | 3,792 |
| switch-profile | 590 | 3,040 | 0.19x | 0 | 496 |
| read-default | 14.6 | 3.9 | 3.76x | 0 | 0 |
| read-saved | 10.4 | 3.5 | 2.95x | 0 | 0 |
| read-nested | 13.2 | 6.8 | 1.95x | 0 | 0 |
| read-entry-default | 21.0 | 10.9 | 1.93x | 0 | 0 |
| read-getter | 25.5 | 15.4 | 1.65x | 0 | 0 |
| write-scalar | 319 | 8.5 | different work | 0 | 0 |
| write-nested | 557 | 5.2 | different work | 0 | 0 |
| retained per open database | 4,400 B | 3,872 B | 1.14x | | |

Namespace costs measured outside the bench (scripts above, same host):

| Measurement | Value |
|---|---|
| AceDB `RegisterNamespace` with a small profile default, then one `child.profile` read | 2,696 ns, 3,297 B allocated, 3,294 B held per namespace |
| AceDB `SetProfile` between two existing profiles, no namespaces / 10 namespaces | 444 ns, 0 B / 10,524 ns, 2,044 B allocated |
| SettingsKit `Open` with a small profile-only schema, then one read (upper bound of a child's registration: it also creates the global, nine layout sections, runs the migration check and joins the logout list) | 6,900 ns, 4,764 B allocated, 4,472 B held |
| SettingsKit `SetProfile` between two existing profiles, one database | 780 ns, 0 B |
| Held by compiled chunks (`compile_held.lua`) | SettingsKit.lua 186.1 KB (5,390 lines); AceDB-3.0 36.4 KB; CallbackHandler-1.0 10.8 KB |

---

**settingsKit AceDB scopes, profile lifecycle signals, `missingOk`, and the core side of namespaces** — a change to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.6.0 (from 0.5.0), implementation revision 15 (from 14), database
   layout 4 and node layout 4 unchanged (no new field on a database or node
   that does not use the new features; see 5).
2. Purpose: close the settingsKit items of the gap report's work package 10
   in the core, and give the Namespaces part (next record) the hooks it needs,
   without touching a read or write path.
   a. **Four declarable scopes with AceDB's keys**: `race`, `factionrealm`,
      `factionrealmregion`, `locale`, in sections of the same names. Keys as
      AceDB computes them (client facts above), so data BridgeKit imports
      from AceDB keeps its keys verbatim. Each key is read **only when the
      schema declares its scope**, once per `Open` (as the existing four are),
      through `callHost`, every answer probed with `issecretvalue` first; a
      database that declares none of them makes no new host call. A scope
      whose key cannot be read is unavailable, with the existing message
      form: `race` needs `UnitRace("player")`; `factionrealm` and
      `factionrealmregion` need `UnitFactionGroup("player")` and
      `GetRealmName()` (the region always resolves, falling back to `"TR"` as
      AceDB does); `locale` needs `GetLocale()`. They are keyed sections like
      `realm` and `class`: views, `OnChange`, `Getter`, `Validate`, `Pairs`,
      `Compact` (an emptied entry is removed) and logout compaction treat
      them alike. The new sections are created by `Open` (writable database)
      only when declared, and their layout check (present but not a table is
      refused) runs only when declared, so saved data that holds an
      unrelated top-level `race` key, which SettingsKit never read, still
      opens.
      **Core, not a part (weighed, 0/16 use):** the four scopes are rows in
      the scope tables plus about 40 lines of key reading (about 1.5 KB held,
      estimate at 35 KB per 1,000 lines). A part would need the core's scope
      lists made extensible from outside (they are walked by `Open`,
      compaction, rebinding and `findRoot`), which costs about as much in the
      core as the rows themselves, plus the part's own header and bootstrap
      (about 1 KB) and an embed line. Not loading them would save almost
      nothing, so they stay in the core and cost nothing at run time unless
      declared.
   b. **Four more profile lifecycle signals**, through the existing lazy
      design (`_signals`, created by the first connection, so `Open`
      allocates nothing more and a database nobody listens to keeps its 16
      hash slots):
      - `db:OnNewProfile(callback)` → `callback(db, name)`, when SettingsKit
        creates the current profile's table: `SetProfile` (spec switches
        included), `ResetDatabase`, and `CopyProfile`/`ResetProfile` when
        the current profile's table was missing. Fires after the operation's
        changes, before its other signals (so a listener that fills the new
        profile runs before `OnProfileChanged` listeners read it, as in
        AceDB).
      - `db:OnProfileShutdown(callback)` → `callback(db, name)`, at the start
        of a `SetProfile` that will switch (not for the current name, not on
        a read-only database), **before anything changes**: `db.profile` is
        still the old profile. A raising listener stops the switch before
        anything changed (the error reaches the caller's line, as every
        SettingsKit signal's does). AceDB passes no name; the name of the
        profile being left is added because the listener otherwise has to
        call `db:GetProfile()`.
      - `db:OnDatabaseShutdown(callback)` → `callback(db)`, at
        `PLAYER_LOGOUT` (with EventKit, as logout compaction), for every
        database on the logout list in the order opened, **before** that
        database is compacted, so a listener's final writes are compacted
        too. Fires for a read-only database as well (which is then not
        compacted). A raising listener is reported through the host error
        handler and never stops another database's shutdown or compaction.
        Without EventKit nothing fires; the docs keep pointing to
        LifecycleKit's `OnShutdown` for that case.
      - `db:OnDatabaseReset(callback)` → `callback(db)`, from
        `ResetDatabase`, first, before its existing `OnProfileReset` and
        `OnProfileChanged` (whose behaviour is unchanged).
      Callbacks are functions, like the four existing `On*` methods; the
      method-name form of decision 0003 is not extended to SettingsKit here
      (0003 names the runtime Kits; adding it to every `On*` method of
      SettingsKit is a separate record if wanted).
   c. **`db:IsNewProfile()`** → whether the current profile's table was
      created during this session (by `Open`, `SetProfile`, a spec switch or
      `ResetDatabase`). Needed because `Open` creates a new character's
      first profile before any `OnNewProfile` listener can connect, and the
      corpus relies on hearing about that profile
      (`Bartender4/Bartender4.lua:49`). Kept in a weak-keyed table in
      `state`, not on the database, so a database keeps its hash size.
   d. **`missingOk`** (gap report 3.6 last row): `db:CopyProfile(from,
      options?)` and `db:DeleteProfile(name, options?)` accept
      `{ missingOk = true }` and then return `false` instead of raising when
      the named profile does not exist; both now return `true` when they
      did their work (they returned nothing). The options table is checked
      like `Open`'s: unknown fields, a secret key or value, and a
      non-boolean `missingOk` are refused at the caller's line. Every other
      refusal (copying the current profile onto itself, deleting the current
      profile, too deep) is unchanged.
   e. **Core side of namespaces** (the part does the rest, next record):
      - `state.parts` (decision 0001, point 4) for part state, created by
        this revision and by the upgrade from 14.
      - A database that has namespaces holds one extra field, `_namespaces`
        (created by the part's first `RegisterNamespace`). The profile
        methods ask `rawget(db, "_namespaces")` once and, only when present,
        call the part's cascade through `state.dispatch`, at three fixed
        points: before the change (refusals and `OnProfileShutdown`), after
        the parent's change and before the parent's post signals (the
        children's changes and signals), and from compaction (manual and
        logout) and `Resync`. A database without namespaces pays one
        `rawget` per profile operation, nothing on reads or writes.
      - A namespace child is a database table with the same private layout
        and the same metatable (so views, `OnChange`, `Getter`, `Validate`,
        `Pairs` work unchanged and at the same speed), marked by `_parent`.
        The core's `SetProfile`, `CopyProfile`, `DeleteProfile`,
        `ResetDatabase`, `SetSpecProfile` and `ApplySpecProfile` refuse a
        child at the caller's line, naming the parent:
        `SettingsKit.Database:SetProfile cannot be called on namespace Bars of MyAddonDB; call it on MyAddonDB's database`.
        `ResetProfile` on a child empties only that namespace's current
        profile (AceDB's child behaviour). `GetProfiles` and
        `GetSpecProfile` on a child answer the parent's. `GetSavedVariable`
        on a child answers the parent's global name; messages name the
        namespace (`SettingsKit (MyAddonDB namespace Bars) db.class is unavailable: ...`).
      - `RegisterNamespace` and `GetNamespace` read on a database while the
        part is not loaded raise at the reading line (decision 0001, point
        5), built only on that miss path of `databaseIndex`:
        `SettingsKit.Database:RegisterNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\parts\SettingsKit-Namespaces.lua`.
      - `Open` accepts `maxNamespaces` (a positive integer or
        `SettingsKit.UNBOUNDED`, default 256, checked like
        `maxScannedEntries`), stored on the database only when passed, so the
        default costs no field. It is accepted without the part and bounds
        `RegisterNamespace`.
   Non-goals: AceDB's `RegisterDefaults` (the schema is fixed at `Open` by
   design), `GetProfiles(tbl)` reuse, method-name callbacks on SettingsKit's
   `On*` methods (above), WoW Forever's ruleset keys (not a supported
   client), reading scope keys again when the faction changes mid-session (a
   Neutral Pandaren keeps `Neutral` keys until the next `Open`, as AceDB
   keeps them until reload), lazy layout sections for the existing scopes.
3. Dependencies: registry API 2, schemaKit API 1, signalKit API 1, eventKit
   API 1 optional; all unchanged. Host: `UnitRace`, `GetCurrentRegion`,
   `GetCurrentRegionName`, `GetLocale`, read through `callHost` (guarded by
   `type(...) == "function"`), each answer checked with `issecretvalue`
   first; `GetCurrentRegion`'s answer must be a non-secret number to index
   the region table.
4. Surface: `db:OnNewProfile`, `db:OnProfileShutdown`, `db:OnDatabaseShutdown`,
   `db:OnDatabaseReset`, `db:IsNewProfile`; the `options` argument of
   `CopyProfile` and `DeleteProfile` and their `true`/`false` returns; the
   `maxNamespaces` option of `Open`; scopes `race`, `factionrealm`,
   `factionrealmregion`, `locale` (`db.race` and the rest, and the scope
   names accepted by `OnChange`, `Getter`, `Validate`); four sections in *The
   saved table*. Every `On*` returns a SignalKit connection and refuses a
   non-function callback and a non-database receiver at the caller's line.
   Behaviour changes, all in CHANGELOG and `docs/API.md`: `CopyProfile` and
   `DeleteProfile` return a boolean; the `namespaces` row of *The saved
   table* stops being "reserved" (next record).
5. Ownership: signals live in the database's lazily created `_signals` (as
   today); `createdProfiles` (weak-keyed database to a set of names) and
   `parts` in `state`; the cascade entry points in `state.dispatch`, set by
   the part, never overwritten by a core revision. Main-chunk locals: the
   four scope tables (`SCOPE_NAMES`, `SCOPE_SECTIONS`, `SCOPE_SET`,
   `UNAVAILABLE_REASONS`) fold into one `Scopes` table, freeing three locals;
   every new helper lives in a table or a `do` block, so the main chunk ends
   at or below today's 195 (the ratchet only goes down). In-place upgrade
   from revision 14: `state.parts` and `state.createdProfiles` are created;
   databases opened by revision 14 gain the new methods through the shared
   prototype, keep their scopes (the new ones were never declared there) and
   their signals; a database whose current profile revision 14 created reads
   `IsNewProfile() == false` (not recorded then, documented).
6. Performance and memory (host Lua; against AceDB in the same bench run):

   | Case | Today (rev 14) | Expected | Basis |
   |---|---|---|---|
   | read-default, read-saved, read-nested, read-entry-default, read-getter | 3.76x, 2.95x, 1.95x, 1.93x, 1.65x | unchanged (no code added on a read) | by construction; bench re-run in phase 2 |
   | write-scalar, write-nested | 319 ns, 557 ns | unchanged (no code added on a write) | by construction |
   | open-empty, open-populated | 3.03x / 3,691 B, 2.28x / 4,704 B | within noise; bytes unchanged (no new field, no new table unless a new scope is declared) | the scope loop walks 10 rows instead of 6: about 20 to 40 ns, under 1% (estimate) |
   | switch-profile | 590 ns, 0 B (0.19x) | at most 620 ns, 0 B | three more `rawget`s (shutdown signal, namespaces, new-profile record) per switch (estimate) |
   | Open declaring all four new scopes | — | about +4 host calls and four small tables in a new saved variable (about 160 B) | estimate |
   | core held memory | 186.1 KB | about 191 KB (+5 KB: scopes 1.5 KB, signals and `IsNewProfile` 2 KB, `missingOk` 0.5 KB, namespace hooks 1 KB) | estimate at 35 KB per 1,000 lines |

   No allocation on reads, writes or switches. `OnDatabaseShutdown` costs
   one `rawget` per database at logout when nobody listens.
7. Tests: each new scope declared and read, its key from the stubbed host
   (race file name; faction and realm; the region table, then
   `GetCurrentRegionName`, then `"TR"`, with `GetCurrentRegion` absent,
   secret, out of range, and `GetCurrentRegionName` absent, empty, secret;
   `GetLocale():lower()`), unavailable when its host call is absent,
   secret, empty or `nil`, with the message; no host call for an undeclared
   new scope (a counting stub); the new sections created only when
   declared, a present non-table one refused only when declared;
   compaction removing an emptied entry of a new scope; `OnNewProfile` from
   `SetProfile`, a spec switch, `ResetDatabase`, and not from switching to
   an existing profile; `OnProfileShutdown` before the change (the listener
   sees the old `db.profile`), not for the current name, a raising listener
   leaving the profile not switched; `OnDatabaseShutdown` at logout before
   compaction (its write compacted), for a read-only database, a raising
   listener reported and the next database still compacted; `OnDatabaseReset`
   first in `ResetDatabase`; `IsNewProfile` after `Open` of a new character,
   after `Open` of an existing one, after `SetProfile`; `missingOk` for both
   methods, the options refusals at the caller's line (ErrorLevels), the new
   return values; a child refused by each profile method with the message
   naming the parent; the not-loaded message for `RegisterNamespace` and
   `GetNamespace`; `maxNamespaces` option checks; the upgrade from revision
   14 with an open database, its listeners and getters; `Allocation_spec`
   unchanged for reads, writes and switches; main-chunk locals at or below
   195. Client suite (never run): the four keys equal AceDB's rule computed
   in the suite from the client calls; `OnProfileShutdown` and `OnNewProfile`
   order around `SetProfile`.
8. Docs: README (migration table rows for the four scopes, the callbacks,
   `silent`), `docs/API.md` (*Host facilities* rows for the four calls,
   *Public surface*, *The saved table* rows, *Profiles* (`missingOk`,
   returns), *Change signals* (the four signals and their order), *Error
   behaviour*, *Performance*, revision 15 under *Embedded copies and
   upgrades*; also fix the stale "Implementation revision: **13**" line at
   the top, which still reads 13 at revision 14), `docs/INTERNALS.md` (the
   `Scopes` table, lazy key reads, `createdProfiles`, `state.parts`, the
   cascade hook points and their order), CHANGELOG 0.6.0, `tests/README.md`,
   the client suite's `EXPECTED.md`.
9. Status: recorded 2026-11-15; code follows.

---

**settingsKit Namespaces part: AceDB namespaces in the saved layout** — a new part `Namespaces` of facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, part `Namespaces`, file
   `src/parts/SettingsKit-Namespaces.lua`, part revision 1 (`PART_REVISION`),
   needs the core at revision 15 or later (it requires `state.parts` and
   raises `MoltenCodes SettingsKit part Namespaces requires SettingsKit API 1 to be loaded first`
   without it, decision 0001 point 3). Manifest `parts.Namespaces`:
   `{ "description": "db:RegisterNamespace and db:GetNamespace: child databases with their own schema over the saved variable's namespaces section, in AceDB's layout, following the parent's profile.", "revision": 1, "dependencies": {}, "optionalDependencies": {} }`.
2. Purpose: AceDB's most used runtime gap (8/16 addons, 63 registrations,
   145 `GetNamespace` calls) without costing an addon that does not use it.
   a. **`db:RegisterNamespace(name, schema)`** → a child database over
      `MyAddonDB.namespaces[name]`. `name`: a non-secret string of 1 to 64
      bytes with a character other than whitespace. `schema`: what `Open`
      takes (scope names to SchemaKit `table` nodes or sealed schemas, every
      field optional), sealed and compiled the same way and sharing `Open`'s
      plan cache, so namespaces registered with the same schema share one
      plan. Registering a name again with the same schema table returns the
      same child (as `Open` does for a saved variable); a different schema
      raises. Refused at the caller's line: a child receiver (namespaces do
      not nest), more than the database's `maxNamespaces` (default 256),
      `namespaces[name]` or one of its sections present but not a table.
      The child reads the scope keys at registration, as `Open` reads them,
      except `char`, which is the parent's key so both agree.
   b. **The saved layout is AceDB's namespace layout**: inside
      `namespaces[name]`, the sections of the scopes the child declares
      (`profiles`, `global`, `char`, `realm`, `class`, `faction`, `race`,
      `factionrealm`, `factionrealmregion`, `locale`), keyed exactly as the
      parent's sections are; no `profileKeys`, `specProfiles`, `version` or
      nested `namespaces`. A writable parent gets `namespaces[name]`, the
      declared sections and the current profile's table at registration; a
      read-only parent gets none and the child reads what is saved or its
      defaults. This replaces the `namespaces` row's "Reserved: SettingsKit
      writes nothing here" (the row was reserved for exactly this; the
      contract allows filling a reserved section additively). BridgeKit can
      then import AceDB namespaces verbatim (see the report).
   c. **`db:GetNamespace(name, options?)`** → the registered child; a name
      nobody registered raises at the caller's line
      (`SettingsKit.Database:GetNamespace name names no registered namespace`)
      unless `options` is `{ missingOk = true }`, which answers `nil`
      (AceDB's `silent`, in the `missingOk` form of the previous record).
   d. **The child** is a database (previous record, 2e): views and their
      read-through chains, `OnChange`, `Getter`, `Validate`, `Pairs`,
      `Compact` (this namespace only), `Resync` (re-resolves its saved table
      from the parent), `IsReadOnly` (the parent's), `GetProfile`,
      `GetProfiles`, `IsNewProfile`, `ResetProfile` (this namespace's current
      profile only), and the eight profile signals of its own. The profile
      mutators of the parent are refused on it, naming the parent.
   e. **Cascading profile operations.** Every refusal is decided before
      anything changes, the namespaces' copy depth included, so an operation
      either changes the parent and every child or nothing. Then, for the
      parent's `SetProfile`, `CopyProfile`, `ResetProfile`, `DeleteProfile`
      and `ResetDatabase`:
      - signals that announce a change (`OnProfileShutdown`) fire on the
        parent, then on each child in registration order, before anything
        changes;
      - the parent changes, then every child changes (no user code runs in
        between): `SetProfile` points each child at the profile (creating
        its table when the child declares `profile`); `CopyProfile` copies
        each child's `profiles[from]` (an absent one empties the child's
        current profile, as AceDB does); `ResetProfile` empties each child's
        current profile; `DeleteProfile` removes each child's
        `profiles[name]` and detaches its views of it; `ResetDatabase`
        recreates each registered namespace's table and declared sections
        in the wiped saved variable, re-points each child at it, detaches
        every child profile view and republishes `child.profile`;
      - the namespaces nobody registered this session (`namespaces[x]`
        tables with a `profiles` table) get the raw part of the operation
        AceDB gives them: copy (bounded by SchemaKit's `maxDepth`), reset
        (removes `profiles[current]`) and delete (removes `profiles[name]`);
        `SetProfile` and `ResetDatabase` need nothing for them;
      - signals that report a change fire on each child, in registration
        order, then on the parent, each with its usual arguments
        (`OnNewProfile` first when that child's table was created). A
        listener that raises stops the remaining signals and reaches the
        caller's line with every change already made, as for any SettingsKit
        signal.
      Spec switches go through `SetProfile` and cascade with it.
   f. **Compaction**: the parent's `Compact` also compacts every registered
      child and returns the total. At logout, after the parent's
      `OnDatabaseShutdown`, each child's `OnDatabaseShutdown` fires (in
      registration order), then the parent and its children are compacted,
      then, AceDB's logout cleanup inside `namespaces` only: empty profiles
      and empty sections of every namespace table and then empty namespace
      tables are removed. The parent's own layout stays eager, as `Open`
      promises.
   Non-goals: nested namespaces, per-namespace `version`/`migrations` (the
   parent's migrations receive the whole saved table, `namespaces`
   included), `GetNamespaces`/iteration of registered children, OptionsKit
   `bind` to a namespace (`"ns:<name>.profile.key"`, work package 6's
   optionsKit item: optionsKit's owner records it), an AddonKit form
   building a namespace from plain defaults (addonKit's owner), BridgeKit's
   import (bridgeKit's owner; text in the report).
3. Dependencies: the SettingsKit core (API 1, revision 15 or later), found
   through the Registry at file scope; nothing else. No host API of its own.
4. Surface: `db:RegisterNamespace(name, schema)`, `db:GetNamespace(name,
   options?)`, installed on the shared `Database` prototype, so databases
   opened before the part loaded (or by an older core revision upgraded in
   place) have them; the `namespaces` section's documented layout.
5. Ownership: part state in `state.parts.Namespaces` (`revision`); the
   cascade, compaction and resync entry points in `state.dispatch`, called by
   the core only for a database holding `_namespaces`; a parent's children
   in its `_namespaces` (`order`, an array in registration order, and
   `byName`). Children are built by the active part revision through the
   shared prototype and metatable, so a later core revision (in-place
   upgrade) cascades to children registered before it, and a later part
   revision takes over the dispatch entries for every existing parent
   (the gap report's risk 6). The highest part revision wins: an equal or
   older copy loaded later returns at once.
6. Performance and memory (host Lua):

   | Case | AceDB (measured) | Expected SettingsKit | Basis |
   |---|---|---|---|
   | register a namespace with one small profile default and read it | 2,696 ns, 3,294 B held | about 3,500 to 4,500 ns (1.3x to 1.7x), at most 3,300 B held | estimate: a whole `Open` of the same schema measures 6,900 ns and 4,472 B, and a child skips the global, seven of nine layout sections, the migration check, the profile-key lookup and the logout list |
   | `SetProfile` with 10 namespaces | 10,524 ns, 2,044 B allocated | about 4,000 to 6,000 ns (0.4x to 0.6x), 0 B | estimate: one database's switch measures 780 ns; a child's share skips validation and `profileKeys` |
   | reads and writes through a child's views | as the parent's | as the parent's | same code, same chains |
   | a database without namespaces | — | one `rawget` per profile operation | by construction |
   | part held memory | — | about 16 to 18 KB, only in addons that embed it | estimate: about 450 lines at 35 to 40 KB per 1,000 |

   Proposed bench cases (shared tooling, see the report):
   `register-namespace` and `switch-profile-namespaces` (10 children), both
   with an AceDB side.
7. Tests (`Namespaces_spec.lua` and additions to `Bootstrap_spec`,
   `Manifest_spec`, `ErrorLevels_spec`, `Allocation_spec`, `Compact_spec`,
   `SpecProfiles_spec`): registration and its refusals at the caller's line
   (name, schema, nesting, bound, `UNBOUNDED`, a non-table namespace or
   section, same schema returns the child, a different one raises); the
   saved layout created (and nothing on a read-only parent);
   `GetNamespace` with and without `missingOk`; child views read and write
   with validation and `OnChange`; every profile method refused on a child
   naming the parent, `ResetProfile` on a child; each cascading operation on
   registered and unregistered namespaces, its signal order (shutdown parent
   first; reports children first), a refusal leaving parent and children
   unchanged, a raising child listener leaving every change made; spec
   switches cascading; `ResetDatabase` re-pointing children and detaching
   their profile views; parent `Compact` including children; logout:
   shutdown order, compaction, removal of empty profiles, sections and
   namespaces; the part loaded before and after a database is opened; the
   part not loaded (the core's message); the part loaded twice (same and
   older revision); a later core revision upgraded in place over a parent
   with children still cascading; `Allocation_spec`: no allocation reading
   or writing through a child, no allocation in a cascaded switch between
   existing profiles. Client suite (never run): a namespace survives
   `/reload` in the documented layout; `PLAYER_LOGOUT` removes an empty
   namespace.
8. Docs: README (namespaces, the AceDB migration rows `RegisterNamespace`,
   `GetNamespace`), `docs/API.md` (*Loading* with the part's file, *Public
   surface*, a *Namespaces* section, *The saved table* `namespaces` row and
   the namespace layout, *Error behaviour*, *Performance*), `docs/INTERNALS.md`
   (the child's fields, the cascade phases, the dispatch entries, the
   upgrade rules), CHANGELOG (in the 0.6.0 entry), `tests/README.md`, the
   client suite's `EXPECTED.md` and `.toc` (the part's file).
9. Status: recorded 2026-11-15; code follows.

**moduleKit (package O): the AceAddon conveniences: intended state, module defaults and prototypes, finding addons, a module-created notice** — a change to facade `ModuleKit`

1. Package `moduleKit`, facade `ModuleKit`, API generation 1 (additive),
   version 0.10.0 (from 0.9.0), implementation revision 23 (from 22).
   No part: see point 6 for why these stay in the core.
2. Purpose: close the AceAddon-3.0 gaps the Ace3 feature-gap diagnosis
   measured (section "AceAddon", work package 7), so an Ace addon ports
   without restructuring. Corpus use (16 open-source Ace3 addons):
   `SetEnabledState` 5/16 (39 sites), `SetDefaultModulePrototype` 5/16,
   `NewModule(name, prototype)` 3/16 (9 sites), `GetAddon` 5/16 (49 sites),
   `OnModuleCreated` 3/16, `SetDefaultModuleState` 1/16, `IterateAddons`
   0/16.
   - **Intended state without running hooks.** `module:SetEnabledState(enabled)`
     writes the module's intent (`wanted`, `docs/API.md` *Intent versus
     fact*) and nothing else: no hook runs, the fact does not change, and
     `blockedBy` is cleared when `enabled` is `false`, as `Disable` clears
     it. Before the addon is ready, `false` keeps the module out of the
     `ready` pass (the pass already skips modules that are not wanted).
     After ready it changes what recovery and `GetEnableState` see; `Enable`
     and `Disable` still change the fact. AceAddon's `SetEnabledState` is
     the same: a flag the next enable pass reads.
   - **Default state.** `addon:SetDefaultModuleState(enabled)` sets the
     starting intent of modules created afterwards. AceAddon refuses the call
     once a module exists; ModuleKit applies it forward instead, because an
     AddonKit addon object is itself the module `"Main"` and always exists
     first. A definition field `enabledState` (boolean) overrides it per
     module: a definition-table module catches up inside `CreateModule`, so
     its intent must be known before that.
   - **Catch-up honours intent.** The implicit catch-up of a definition-table
     module created after ready enables it only when it is wanted, as the
     `ready` pass does. Today every such module starts wanted, so no existing
     behaviour changes. `module:Activate()` is an explicit request and still
     enables, as today.
   - **Module prototypes.** `addon:SetDefaultModulePrototype(prototype)` (or
     `nil` to clear) and a definition field `prototype` (a table, or `false`
     for none when a default is set). A module's lookup order is: its own
     fields, then ModuleKit's `Module` methods (framework methods win and
     stay upgradable in place), then the prototype. A prototype chosen at
     creation stays the module's prototype; changing the default later
     affects later modules only, as in AceAddon. Hooks (`OnInitialize`,
     `OnEnable`, `OnDisable`) are found on the prototype too, so AceAddon's
     "prototype carries a shared `OnEnable`" ports unchanged (AdiBags' use).
     Refused at the caller: a prototype that is not a table or is secret, and
     a prototype whose own key (read with `next`, keys checked for secrets
     first, ADR 0002 point 2) names a `Module` method, `scope`, or begins
     with `_` (ModuleKit's private fields).
     Implementation: one **layer** table per distinct prototype, kept in the
     package state in a weak-keyed map. The layer holds a copy of the
     `Module` methods and has `{ __index = prototype }` as its metatable;
     a prototyped module's metatable is `{ __index = layer }`, shared by
     every module with that prototype. A lookup is therefore table hops
     only (own, layer, prototype), no function `__index`. Modules without a
     prototype keep today's `MODULE_METATABLE` and pay nothing. An in-place
     upgrade refreshes every layer from the new `Module` table (copy the
     current methods, drop names that are no longer methods), so prototyped
     modules gain the new revision's methods as plain modules do.
   - **Finding addons.** `ModuleKit:FindAddon(name)` returns the container or
     `nil` and never creates one (`ForAddon` creates). A raising form is not
     added: `nil` plus the caller's own `assert` already raises at the
     caller's line. `ModuleKit:GetAddons()` returns a new sorted array of
     container names (diagnostics; it allocates). Status per addon is
     `addon:GetModules()` and each module's `IsEnabled` / `GetEnableState`.
   - **Module-created notice.** `addon:OnModuleCreated(callback)` or
     `addon:OnModuleCreated(receiver[, methodName])` (method name defaults to
     `"OnModuleCreated"`, checked when registered, ADR 0003) subscribes to the
     topic `"ModuleKit.ModuleCreated"` on the addon's SignalKit bus
     (`SignalKit:ForAddon(addonName)`), declaring it once with
     `arguments = 1`. It returns the bus subscription (a SignalKit
     connection: `Disconnect`, `IsConnected`), or `nil, "full"` at the bus
     limits. `CreateModule` publishes `(module)` after the module is
     published in the container and before its catch-up, so a listener can
     still give a late definition module fields before it initializes. A
     listener error is isolated and reported by the bus (AceAddon uses
     `safecall` the same way); `CreateModule` still returns the module. The
     bus is only touched once someone subscribed: until then `CreateModule`
     pays one `rawget`. A module's own `scope.Messages` can subscribe to
     the same topic and is released on disable like any subscription.
   - **Locals.** The main chunk stays at or under 195 active locals (the
     `lua_limits` ratchet only goes down): the new functions are fields of
     one table, `addonConveniences`, into which `missingScopePolicyMethods`
     and the two dependency-policy methods move (net 195 to 193; the ratchet
     entry is lowered to the measured value).
   Non-goals: `NewAddon(object, name)`, mixins, `IterateEmbeds`,
   `SetDefaultModuleLibraries`, `OnEmbedEnable` (kept different, Ace3
   feature-gap diagnosis section 4, items 3 and 4); a raising `GetAddon`;
   moving "Halted addons" (18.0 KB of prototypes) into a part (worth its own
   record).
3. Dependencies: registry API 2 and lifecycleKit API 1, unchanged.
   `signalKit` API 1 is added to `optionalDependencies` and found through
   `Registry:Find` on the first `OnModuleCreated`. In practice it is always
   loaded: LifecycleKit requires it. A host without it raises at the caller:
   `ModuleKit.Addon:OnModuleCreated needs SignalKit API 1, which is not loaded`.
4. Surface (all additive):

   | Member | Returns | Notes |
   |---|---|---|
   | `module:SetEnabledState(enabled)` | previous intent (boolean) | refused after shutdown, like `Enable`; a non-boolean or secret raises at the caller |
   | `addon:SetDefaultModuleState(enabled)` | previous default | default `true` |
   | `addon:GetDefaultModuleState()` | boolean | |
   | `addon:SetDefaultModulePrototype(prototype)` | previous prototype or `nil` | `nil` clears |
   | `addon:GetDefaultModulePrototype()` | table or `nil` | |
   | `addon:OnModuleCreated(callback)` / `(receiver[, methodName])` | SignalKit connection, or `nil, "full"` | |
   | `ModuleKit:FindAddon(name)` | container or `nil` | |
   | `ModuleKit:GetAddons()` | new sorted array of names | |
   | definition `enabledState` | | boolean |
   | definition `prototype` | | table or `false` |

   Error messages follow the Kit's form, for example
   `ModuleKit.Addon:SetDefaultModulePrototype prototype key "Enable" shadows ModuleKit's Module:Enable`
   and `ModuleKit.Module:SetEnabledState enabled must be a boolean`.
5. Ownership: a prototype is referenced by the modules created with it and,
   while it is the default, by the container; its layer lives as long as the
   prototype (weak key). The module-created subscription belongs to the
   addon's bus: it ends with `Disconnect`, or when the bus closes at logout.
   Containers still live for the session.
6. Performance and memory. Host bench `addonModules` against AceAddon-3.0,
   one run on 2026-11-15 (Lua 5.1.5, 3 rounds):

   | Case | Before | Expected after |
   |---|---:|---:|
   | create-addon | 0.78× | 0.78× (± noise: one `rawget` per `CreateModule`) |
   | load-addon | 1.02× | 1.02× |
   | disable-enable-module | 1.23× | 1.23× (a hook missing on a plain module costs one extra `rawget` for `_prototype`) |
   | disable-enable-all | 1.14× | 1.14× |
   | disable-enable-all-listening | 1.62× | 1.62× |

   New measurement in phase 2 (host micro-benchmark beside the bench, same
   run, both sides): a method call through a prototype, target at most 1.3×
   AceAddon's (two table hops against one); `GetEnableState`-free paths
   unchanged.
   Held memory (load-and-execute footprint, debug information kept, one
   process): ModuleKit 137,205 B today against AceAddon-3.0 27,041 B. The
   additions are about 330 lines, about 13 KB at the measured 35 to 44 KB per
   1,000 lines: expected about 150 KB. Why not a part: the two largest pieces,
   prototypes (about 4.5 KB) and the created notice (about 2 KB), both hook
   into `CreateModule` and `invokeHook`, so the core would keep forwarders
   and checks for them, and a part's fixed cost (header, bootstrap, state
   checks, about 1.5 KB) would take a third of the saving. Per object: a
   module without a prototype is unchanged (933 B); a prototype costs one
   layer (about 1.3 KB, the `Module` methods' hash part) per distinct
   prototype, not per module; a container gains at most three fields, written
   only when set.
7. Tests: `SetEnabledState` before load, before ready (the module stays
   off, its dependents are blocked as for a `Disable`), after ready (fact
   unchanged; recovery skips it), after shutdown (refused), argument errors at
   the caller; default state applied to later modules only, overridden by
   `enabledState`; a late definition module with `enabledState = false`
   initialized but not enabled, and `Activate` still enabling a mutable one;
   prototypes: lookup order (own, framework, prototype), hooks from the
   prototype in all three phases and in `implements`, a per-module prototype,
   `prototype = false` against a default, refusals (non-table, secret,
   secret key, framework name, `scope`, `_` key) leaving no module, layer
   sharing between modules, a prototype with its own metatable; an in-place
   upgrade from revision 22 that keeps every container and module and
   refreshes layers (a method added by the new revision reaches a prototyped
   module); `FindAddon` never creating, `GetAddons` sorted and fresh;
   `OnModuleCreated`: function and method forms, missing method refused at
   registration, order (published, then catch-up), a raising listener
   reported while `CreateModule` returns the module, `nil, "full"` at the bus
   limit, `Disconnect`, nothing published before the first subscription, the
   missing-SignalKit refusal with a stand-in Registry; the lua_limits
   measurement of the main chunk (195 to 193).
8. Docs: API.md (surface tables, *Intent versus fact*: `SetEnabledState`,
   defaults and catch-up; a new *Module prototypes* section; *Creating
   modules*: the two definition fields; a *Finding addons* section; the
   created notice; *Argument and state errors*; *Cost*), INTERNALS.md (layers
   and their upgrade, the `_prototype` field, the hook fallback, the bus
   topic), README migration table (`SetEnabledState`, `SetDefaultModuleState`,
   `SetDefaultModulePrototype`, `NewModule(name, prototype)`, `GetAddon`,
   `IterateAddons`, `OnModuleCreated`), CHANGELOG 0.10.0, tests/README, the
   client suite (two tests: a prototype hook at login, `SetEnabledState(false)`
   keeping a module off through `ready`). For the shared migration guide:
   the AceAddon rows above leave "What has no equivalent yet".
9. Status: recorded 2026-11-15 under ADR 0001 and ADR 0003; code follows.

**commandKit (package O): parts for options binding and completion; the command list, a prefix, dispatch, the AceConfigCmd path syntax and general tab completion** — a change to facade `CommandKit`

1. Package `commandKit`, facade `CommandKit`, API generation 1, version
   0.3.0 (from 0.2.10), implementation revision 11 (from 10). Two parts
   (ADR 0001): `CommandKit-Options` (`src/parts/CommandKit-Options.lua`,
   part revision 1) and `CommandKit-Completion`
   (`src/parts/CommandKit-Completion.lua`, part revision 1).
2. Purpose: the CommandKit items of the Ace3 feature-gap diagnosis (section
   "AceBucket, AceConsole, AceConfigCmd, AceTab", work package 10), placed
   so an addon that only registers commands stops paying for options binding
   and completion.
   - **The split, along existing sections.** The "Options binding" section
     (20.0 KB of prototypes, 19 main-chunk locals) moves to the `Options`
     part and the "Completion" section (7.1 KB, 8 locals) to the
     `Completion` part, measured with the section walk on revision 10. The
     new options features join the first, AceTab's counterpart the second.
     The core keeps `BindOptions`, `EnableCompletion` and
     `DisableCompletion` (and the new part methods) on the scope prototype as
     forwarders: each calls its part through `_state.parts.<Part>` with an
     explicit error level, and raises at the caller's line when the part is
     not loaded: `CommandKit.Scope:BindOptions needs CommandKit's Options
     part, which is not loaded: add commandKit\parts\CommandKit-Options.lua
     to your embeds.xml`. A forwarder in the core, rather than a method the
     part writes onto the prototype, survives any load order of core and
     part revisions. The core shares what the parts need (tokenizer,
     sub-command walk, frames, contexts, output, secret probe, host
     readers, the error reporter, limits, `activeByName`) through
     `_state.helpers`, read at call time, so an upgraded core's helpers
     serve parts loaded before it (AddonKit's pattern). Freeing 27 locals
     takes the main chunk from 198 to about 175, below the gate's fail line,
     so its `lua_limits.json` entry is removed.
   - **This changes embedding.** An addon that calls `BindOptions` or
     `EnableCompletion` must embed the part; a hand-written file list that
     names only `CommandKit.lua` gets the error above at the call, with the
     file to add. A single-Kit release ships both parts, and
     `tooling.package.embeds` adds them when selected. This is the
     consequence ADR 0001 states for every split.
   - **The command list** (AceConsole `IterateChatCommands`, 0/16).
     `scope:GetCommands()`: a new sorted array of the scope's active
     top-level slash names; `CommandKit:GetCommands()`: every active name
     CommandKit serves in the session (AceConsole's iterator is global too).
     Diagnostics; both allocate.
   - **A prefix and printing outside a handler** (AceConsole `Print`).
     `scope:SetPrefix(text)` (or `nil`) returns the previous prefix;
     `scope:GetPrefix()`. With a prefix, every line the scope writes (handler
     output, usage, refusals, option listings, completion lists) starts with
     `text`; colour codes are the author's choice (Ace's form is
     `"|cff33ff99Name|r: "`). Default none, so today's output is unchanged.
     `scope:Print(...)` and `scope:Printf(template, ...)` write to the
     scope's sink outside any handler, with the same argument rules as
     `context:Print`/`Printf` (`Printf` through LocaleKit when present).
   - **Dispatch from code** (AceConfigCmd `HandleCommand`, 2/16).
     `scope:Dispatch(name, text)` runs the scope's command `name` with
     `text` exactly as the client's slash handler would (same dispatcher,
     same frames, same failure reporting): `true` when it ran, `false` when
     the scope has no such command. A secret `text` or `name`, and a closed
     scope, raise at the caller. It works for bound and ordinary commands.
   - **AceConfigCmd's syntax** (every `BindOptions` user who knows Ace).
     `BindOptions(tree, name, { syntax = "path" })`, in the Options part.
     `/cmd group option value`: each word selects a child of the current
     group by key, without case and with `_` matching a space in the key
     (AceConfigCmd's rule), until a non-group is reached; the rest of the
     line is the value. Then: a group with nothing after it is listed (as
     `list path`); a `toggle` without a value flips (as `set path toggle`);
     an `execute` runs (with the `confirm` word rule of `exec`); any other
     value option prints `path = value` without a value and is set with one
     (as `set path value...`, same parsing and refusals). An empty line lists
     the root, or runs `options.onEmpty(context)` when given (Ace addons open
     their options window there). The five verbs stay available: they are
     the command's sub-commands, so `/cmd set a.b 1` keeps working and a root
     option keyed `get`, `set`, `reset`, `list` or `exec` is reached through
     the verbs (`/cmd set list on`). Resolution uses one `tree:Walk` per typed
     line with a visitor kept per binding (OptionsKit's walk allocates
     nothing) and then the one `DescribeOption` today's verbs make, so a
     typed line describes one option, never a group subtree. A group that a
     future OptionsKit marks inline for the command line is still a path
     step until OptionsKit reports that flag in its walk (ace3-gaps WP 1/2).
     `syntax = "verbs"` is the default, today's behaviour.
   - **The bound tree** (AceConfigCmd `GetChatCommandOptions`, 0/16).
     `scope:GetBoundTree(name)` returns the tree a command was bound to, or
     `nil`. Kept in a per-scope map created on the first bind and cleared by
     `Unregister` and `Close`.
   - **General tab completion** (AceTab-3.0, 1/16, Prat-3.0's five uses).
     The migration guide marks AceTab "not planned" without a technical
     reason; the hook it needs is the one CommandKit already installs.
     Verified in Blizzard's UI source (`Gethe/wow-ui-source`,
     `Interface/AddOns/Blizzard_ChatFrameBase/Shared/ChatFrameEditBox.lua`,
     `live` `297d7aa` line 444, `classic` `e5d9b3a` line 442, `classic_era`
     `4192ac6` line 442): `ChatEdit_CustomTabPressed(editBox)` is an empty
     global "left intentionally global ... to enable secure tab completion
     hooks in addons", and `ChatFrameEditBoxMixin:OnTabPressed` calls it
     through `securecall` only after `AutoCompleteEditBox_OnTabPressed`
     declined, skipping `SecureTabPressed` when it returns true. In the
     Completion part:
     `scope:RegisterCompletion(name, pattern, provider)` → `true`, or
     `nil, "full"` at `maxCompletionProviders`, or `nil, "taken"` when the
     scope already has `name`. `pattern` is a Lua pattern tested with
     `string.find` against the text before the word being completed
     (AceTab's "prematch"); `""` matches anywhere. `provider(partial,
     before, editBox)` returns an array of candidates, or `nil`. On Tab, when
     the cursor is at the end: the scope commands' own completion runs first
     (today's behaviour); otherwise every provider whose pattern matches is
     asked, in registration order, and their candidates are merged through
     today's filter (start of word without case, secrets skipped,
     `maxCompletions`), insertion, common prefix and listing. A provider that
     raises is reported through the host error handler and the others still
     run. `scope:UnregisterCompletion(name)` → `true`/`false`;
     `scope:IsCompletionRegistered(name)`; `Close` releases every provider of
     the scope. The tab chain is installed while any scope has completion
     enabled or a provider registered, and uninstalled as today when neither
     remains. Only chat edit boxes are covered (the client calls the hook
     from them alone); other edit boxes are not, because completing there
     needs the frame's own `OnTabPressed`, which a `HookScript` cannot stop,
     so the guide's row becomes "chat edit boxes: `RegisterCompletion`;
     other edit boxes: not planned (the client offers no hook there)".
     The client's own name auto-complete (`AutoCompleteEditBox_OnTabPressed`)
     runs before the hook and wins while its list is shown.
   Non-goals: honouring `cmdHidden`/`cmdInline`/`confirm` beyond today
   (WP 2); dynamic trees (WP 3); `Reopen` for CommandKit scopes (a separate
   small record would let ModuleKit keep `scope.Commands`); the live taken
   scan (kept by the owner's decision); a raising `GetBoundTree`.
3. Dependencies: core unchanged (registry API 2, schemaKit API 1; optional
   localeKit, clientKit, eventKit, lifecycleKit). `optionsKit` API 1 moves
   from the core's `optionalDependencies` to the Options part's
   `dependencies` (the part cannot work without it, and the embeds
   generator then brings it along). The Completion part has none beyond its
   core. Manifest:

   ```json
   "parts": {
     "Options": {
       "description": "Drive an OptionsKit tree from a slash command: the get, set, reset, list and exec verbs and AceConfigCmd's path syntax.",
       "revision": 1,
       "dependencies": { "optionsKit": { "api": 1 } }
     },
     "Completion": {
       "description": "Tab completion in chat edit boxes: the scopes' own commands and AceTab-style completion providers.",
       "revision": 1
     }
   }
   ```
4. Surface (additive apart from the split): core `CommandKit:GetCommands()`,
   `scope:GetCommands()`, `scope:SetPrefix(text)`, `scope:GetPrefix()`,
   `scope:Print(...)`, `scope:Printf(template, ...)`,
   `scope:Dispatch(name, text)`; forwarders `BindOptions`, `GetBoundTree`
   (Options), `EnableCompletion`, `DisableCompletion`,
   `RegisterCompletion`, `UnregisterCompletion`, `IsCompletionRegistered`
   (Completion); `BindOptions` option fields `syntax` (`"verbs"` or
   `"path"`) and `onEmpty` (function); package limit
   `maxCompletionProviders` (default 32, ceiling 256, `UNBOUNDED` refused:
   every Tab press walks the list). Scope fields, all absent until written:
   `_prefix`, `_bound`, `_completionProviders` (a count); the provider list
   lives in the shared `completion` state table, which keeps its revision-10
   field names so the part adopts it.
5. Ownership: providers and bound-tree entries belong to their scope and go
   with `Unregister`/`Close`; the tab chain belongs to the package as today.
   The parts keep their state inside the core's (`_state.parts.<Part>`, with
   `revision`); the highest part revision wins and upgrades in place.
   Upgrade from revision 10: the state gains `parts` and `helpers`; scopes,
   records and dispatchers are kept. A revision-10 `dispatch.tabPressed`
   keeps serving completion until a Completion part loads and replaces it,
   so an addon that enabled completion under revision 10 keeps it working
   across a core-only upgrade.
6. Performance and memory. Host bench, one run on 2026-11-15 (Lua 5.1.5,
   3 rounds), ratios against Ace3 from the same run:

   | Case | Before | Expected after |
   |---|---:|---:|
   | slashCommands register-unregister | 30.41× | unchanged (the taken scan) |
   | slashCommands dispatch-words | 2.14× | unchanged (one `rawget` for the prefix per written line only) |
   | slashCommands dispatch-subcommand | 2.97× | unchanged |
   | options cmd-set-range / toggle / select | 1.69× / 1.96× / 1.47× | unchanged in verb syntax |
   | new: the same typed line as AceConfigCmd (`/cmd g1 scale 1.25`) in path syntax | n/a | at most 2.0× (one allocation-free walk plus today's describe) |

   The new case needs a line in the `options` workload (text in
   the report). Completion runs only on a Tab press.
   Held memory (load-and-execute footprint, debug information kept):
   CommandKit 141,088 B today; AceConsole-3.0 10,483 B, AceConfigCmd-3.0
   32,779 B, AceTab-3.0 20,398 B (63,660 B together). Expected after:

   | Embedded | Expected | Ace3 it replaces | Ratio |
   |---|---:|---|---:|
   | core only (register, dispatch, print) | about 116 KB (−31 KB moved, +6 KB new) | AceConsole 10.5 KB | about 11× (today 13.5×) |
   | core + Options | about 147 KB | AceConsole + AceConfigCmd 43.3 KB | about 3.4× |
   | core + both parts | about 164 KB | all three, 63.7 KB | about 2.6× (today 2.2× without path syntax or providers) |

   The core-only figure is the one most addons pay; what stays above
   AceConsole is the parser, the schema arguments, sub-commands and the
   taken check, outside this record. Per object: a scope with a prefix
   +1 field; a provider entry about 100 B; a bound tree one map entry.
7. Tests: the split (core alone: every forwarder raises at the caller with
   the file to embed; the part loaded before and after another core
   revision; a part revision upgrade in place; the part loaded without its
   core raising the ADR 0001 message), the upgrade from revision 10 with
   completion enabled and a bound command (both keep working with and
   without the parts), all existing BindOptions and Completion specs moved
   to load the parts; `GetCommands` (both, sorted, fresh); prefix on every
   kind of line, `nil` clearing, argument errors; `scope:Print`/`Printf`
   outside a handler; `Dispatch` (ran, unknown name, closed scope, secret
   text, a raising handler reported not raised); path syntax for every kind
   (group listing, toggle flip and set, tristate, range, select by key and
   label, multiselect, color, input, execute with and without confirm),
   case and `_` matching, unknown word, verbs still reachable, a root option
   named like a verb, empty line with and without `onEmpty`, hidden and
   disabled options, `syntax` refusals; `GetBoundTree`; providers: pattern
   match and miss, merge order, filter and limit, one candidate, common
   prefix, listing with prefix, a raising provider, `"taken"`, `"full"`,
   unregister, release on `Close`, chain installed by a provider alone and
   uninstalled after the last, cursor not at end, secret text; limits
   `maxCompletionProviders`; lua_limits below the fail line.
8. Docs: API.md (*Loading*: the two parts; surface; a *Prefix and printing*
   section; *Dispatch from code*; `BindOptions` path syntax and `onEmpty`;
   *Tab completion*: providers and the client hook with the source
   reference; *Limits*; *Error behaviour*; *Embedded copies and upgrades*),
   INTERNALS.md (helpers, forwarders, part state, the walk visitor), README
   (migration table rows `IterateChatCommands`, `Print`, `HandleCommand`,
   `GetChatCommandOptions`, AceConfigCmd syntax, `RegisterTabCompletion`),
   CHANGELOG 0.3.0, tests/README, `src/.luarc.json` covering the parts, the
   client suite (a provider completing in a real chat edit box; path syntax
   `/cmd group option value`). For the shared files: the AceTab row of the
   migration guide, the embedding guide's parts table (generated), the bench
   workload line.
9. Status: recorded 2026-11-15 under ADR 0001; code follows.

**signalKit (package O): bucketed bus messages, AceBucket's RegisterBucketMessage, as a part** — a change to facade `SignalKit`

1. Package `signalKit`, facade `SignalKit`, API generation 1 (additive),
   version 0.9.0 (from 0.8.0), implementation revision 12 (from 11). New
   part (ADR 0001) `SignalKit-Coalescing`
   (`src/parts/SignalKit-Coalescing.lua`, part revision 1).
2. Purpose: AceBucket-3.0's `RegisterBucketMessage` (Ace3 feature-gap
   diagnosis, section "AceBucket, AceConsole, AceConfigCmd, AceTab", work
   package 10; corpus 1/16, 1 site). Today an author pairs a SchedulerKit
   `Coalesce` handle with a bus subscription by hand, and the host bench
   leaves the message form out for that reason.
   - **Where it belongs.** In SignalKit, as a part. EventKit set the
     pattern: the subscribing Kit owns the subscription half and SchedulerKit
     the timing half (`EventKit:Coalesce` over `SchedulerKit:Coalesce`,
     SchedulerKit's *Coalescing and lanes*). SchedulerKit needs no change:
     its `Coalesce` (revision 7 and later) is used as published. SignalKit
     is required by LifecycleKit, so nearly every addon loads its core; a
     part keeps the feature out of the addons that do not use it.
   - **The calls.** `bus:Coalesce(topics, intervalSeconds, callback[, options])`
     and the same on a bus scope, `scope:Coalesce(...)`, so a module's
     `scope.Messages:Coalesce(...)` is released on disable. `callback` may be
     a function or a receiver table followed by a method name
     (`bus:Coalesce(topics, 0.5, self, "OnBucket")`), checked when the call is
     made (ADR 0003); there is no default method name, as AceBucket takes an
     explicit one. `topics` is a topic or an array of at most 32 distinct
     topics; subscribing needs no declaration, as for `Subscribe`.
   - **Semantics, those of `EventKit:Coalesce`.** The first message starts
     the interval; at its end `callback(set)` runs once. The set is keyed by
     the first published argument, every value `true`; a first argument that
     is `nil`, NaN or a secret value is keyed by the topic (a secret would
     raise as a key, ADR 0002). Options: `byTopic` (key by topic instead),
     `maxKeys` (SchedulerKit's default 256; past it new keys are refused and
     counted), `lane` (a SchedulerKit lane). The set is reused (copy what you
     keep). A raising callback is reported through the host error handler.
     AceBucket's per-key counts and its `"nil"` key stay deliberately
     different (diagnosis section 4, item 5).
   - **The handle**, as EventKit's: `Flush()`, `IsPending()`, `GetStats()`,
     `Close()`, `IsClosed()`.
   - **How it is built.** One listener closure per handle, subscribed to each
     topic through the bus (or through the scope, so the scope's sweep
     disconnects it); one SchedulerKit `Coalesce` handle in one SchedulerKit
     scope private to the part. A scope `Close`, `DisconnectAll` or a bus
     closing disconnects the subscriptions; the next delivery then sees its
     first subscription disconnected, drops the set and closes the handle,
     so nothing is delivered after the owner let go and no change is needed
     in the bus scope's member bookkeeping. If any topic's subscription is
     refused (`nil, "full"`), the ones already made are disconnected and the
     call returns `nil, "full"`.
   - **Core forwarders.** The core's bus and bus-scope prototypes carry
     `Coalesce` forwarders that call `_state.parts.Coalescing` and raise at
     the caller when it is absent:
     `SignalKit.Bus:Coalesce needs SignalKit's Coalescing part, which is not
     loaded: add signalKit\parts\SignalKit-Coalescing.lua to your embeds.xml`.
     SchedulerKit is found with `Registry:Find("schedulerKit", 1)` at each
     call that creates a handle (a found facade is kept, a miss is not);
     a missing or pre-coalescing SchedulerKit raises at the caller.
   Non-goals: arrival counts; a facade-level `SignalKit:Coalesce` over raw
   signals (a raw signal's owner already holds it and can feed a SchedulerKit
   handle directly); any SchedulerKit change.
3. Dependencies: core unchanged (registry API 2; optional eventKit,
   lifecycleKit). The part declares `"dependencies": { "schedulerKit":
   { "api": 1 } }`, so the embeds generator brings SchedulerKit and TimerKit
   along; the required graph has no cycle (SchedulerKit needs only TimerKit
   and Registry). Manifest:

   ```json
   "parts": {
     "Coalescing": {
       "description": "Bucketed bus messages: collect a burst of publishes and deliver them once per interval.",
       "revision": 1,
       "dependencies": { "schedulerKit": { "api": 1 } }
     }
   }
   ```
4. Surface: `bus:Coalesce(topics, intervalSeconds, callback[, options])`,
   `bus:Coalesce(topics, intervalSeconds, receiver, methodName[, options])`,
   the same two on a bus scope; the handle methods above. `BUS_METHODS` and
   `BUS_SCOPE_METHODS` gain `Coalesce`. Refusals at the caller: a closed
   bus or scope, a bad topic (as `Subscribe`), more than 32 topics, a bad
   interval, an unknown option (named with `describeKey`), a bad callback or
   missing method, a secret argument.
5. Ownership: a handle belongs to whoever holds it, and through its
   subscriptions to the bus or scope it was made on; it ends at `Close`, or
   at the first delivery after its subscriptions were disconnected. The
   part's state (`revision`, the found SchedulerKit, its private
   SchedulerKit scope) lives in `_state.parts.Coalescing`; the highest part
   revision wins and upgrades in place. Upgrade from revision 11: the state
   gains `parts`; nothing else changes.
6. Performance and memory. Host bench `buckets` (EventKit `Coalesce` against
   AceBucket-3.0's `RegisterBucketEvent`), one run on 2026-11-15: record-event
   1.80×, burst 1.70×, register-remove 2.30×. Expected for the message form
   in phase 2, with a new case pair against `RegisterBucketMessage`
   (a `buckets` workload addition): record-message and burst within 1.1× of the event
   form's ratios (a bus publish to one subscriber is 1.58× of AceEvent's
   `SendMessage`, documented), register-remove about the event form's.
   Publish paths of topics without a bucket are untouched: the core gains
   only two forwarders, not on any publish or subscribe path.
   Held memory (load-and-execute footprint, debug information kept):
   SignalKit 89,324 B today; the core gains about 40 lines (the forwarders
   and the `parts` field, about 1.5 KB). The part is about 260 lines, about
   11 KB, against AceBucket-3.0's 9,788 B (AceBucket also covers events,
   which EventKit's `Coalesce` does here). Per handle: one closure (136 B
   with the method form, less for a function), one subscription handle per
   topic (161 B, or 194 B through a scope), and SchedulerKit's coalesce handle
   with its two sets.
7. Tests (`Coalescing_spec.lua`): one delivery per interval with the first
   message starting it; keys by first argument, `nil`/NaN/secret keyed by
   topic, `byTopic`; several topics; `maxKeys` refusal counted; lane
   delivery; `Flush`, `IsPending`, `GetStats`, `Close`; method form and its
   registration check; scope `Close`, `DisconnectAll`, `Reopen` and the bus
   closing all stopping delivery and closing the handle; partial
   subscription refusal; a raising callback reported; argument errors at the
   caller; the forwarders without the part; the part without its core (ADR
   0001 message); no SchedulerKit, and one without `Coalesce`; upgrade from
   revision 11 keeping buses and subscriptions; a part revision upgrade in
   place.
8. Docs: API.md (a *Bucketed messages* section, surface tables, errors,
   *Embedded copies and revision upgrades*), INTERNALS.md (the forwarders,
   part state, the lazy close), README (AceBucket `RegisterBucketMessage` and
   `UnregisterBucket` migration rows), CHANGELOG 0.9.0, tests/README,
   `src/.luarc.json`, the client suite (one bucket fed by `Publish` across
   two frames). For the shared files: the migration guide's
   `RegisterBucketMessage` row; SchedulerKit's *Coalescing and lanes* can
   name the bus form beside EventKit's when its owner next edits it.
9. Status: recorded 2026-11-15 under ADR 0001 and ADR 0003; code follows.

**addonKit (package O): the module defaults and the created notice on the facade** — a change to facade `AddonKit`

1. Package `addonKit`, facade `AddonKit`, API generation 1 (additive),
   version 0.2.0 (from 0.1.0), implementation revision 2 (from 1). Core
   only; no part changes.
2. Purpose: surface the ModuleKit conveniences of this round where an
   AddonKit author meets them, `MC`, the way AceAddon offers them on the
   addon (`MyAddon:SetDefaultModuleState(false)`). Kept minimal: AddonKit
   only forwards (ADR 0004: a layer over ModuleKit, no behaviour of its own).
   - `MC:SetDefaultModuleState(enabled)`, `MC:SetDefaultModulePrototype(prototype)`
     and `MC:OnModuleCreated(callback | receiver[, methodName])` call the
     addon container's methods of the same names at the caller's line
     (`callAtCaller`), and return what they return.
   - `MC:NewModule(name, definition)` already passes the definition through,
     so the new definition fields `enabledState` and `prototype` work with
     no change; the `"Main"` dependency is still added.
   - The addon object stays on: when the container's default state is
     `false` and `MC:NewAddon()` is called after it, the new `"Main"`
     module's intent is set back to `true` with `SetEnabledState(true)`
     (unless its definition says `enabledState = false`), so an addon whose
     author changed the module default first still enables at login.
     AceAddon's default never applies to the addon object either. A default
     prototype set before `MC:NewAddon()` does apply to `"Main"`;
     the documentation says to set defaults after `MC:NewAddon()`, as in
     AceAddon.
   - A ModuleKit revision without these methods (before 23) is refused at
     the caller: `MC:SetDefaultModuleState needs ModuleKit revision 23 or
     later; update the copy of moduleKit your addon embeds`.
   Non-goals: `MC:FindAddon` (`MoltenCodes:For(name):GetAddon()` and
   `ModuleKit:FindAddon` cover it); an Ace-style `OnModuleCreated` field on
   the addon object (a method-name subscription
   `MC:OnModuleCreated(addon)` after defining `addon:OnModuleCreated` is the
   port).
3. Dependencies: unchanged (registry API 2; moduleKit API 1 optional, found
   lazily as today).
4. Surface: three facade methods added to `CORE_METHODS`; facade LuaCATS
   types updated. Errors: the forwarded ModuleKit refusals at the author's
   line, and the revision refusal above.
5. Ownership: nothing new is held by AddonKit; the container holds the
   defaults and the bus holds the subscription.
6. Performance and memory: about 50 lines, about 2 KB held (AddonKit 42.3 KB
   compiled today); no change on any read path of the facade. Nothing
   per object.
7. Tests: each forwarder (result, error level at the author's line, the
   revision refusal with a ModuleKit stand-in), `MC:NewAddon()` after
   `MC:SetDefaultModuleState(false)` enabling at login while a later
   `MC:NewModule` stays off, a module from `MC:NewModule(name, { prototype =
   ... })`, `MC:OnModuleCreated` seeing a later `MC:NewModule`, the upgrade
   from revision 1.
8. Docs: API.md (facade methods, *Modules*), README (AceAddon rows),
   CHANGELOG 0.2.0, tests/README, GETTING_STARTED-style example in the
   README for a prototype. For the shared files: none beyond the moduleKit
   record's migration rows.
9. Status: recorded 2026-11-15 under ADR 0004; code follows.

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
