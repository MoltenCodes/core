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
   → `"published" | "taken"`; `ApiKit:RegisterFlavor(flavour, install)` (the
   entry point the generated flavour files call; the installer runs only when
   `flavour` is the running one, otherwise it is dropped and nothing is
   retained); `ApiKit:GetMetadataBuild(flavour)` → the build string the
   committed metadata was captured from, so an addon can compare it with
   `GetBuildInfo()`; the namespace root `MoltenCodes.wow` with `retail`,
   `classic.era`, `classic.mop`, `ptr`, `beta` each holding an `api` table
   (populated for the running flavour, empty for the others); the `wow` global
   under the publication rule; per flavour `api.<namespace>.<function>`,
   `api.events.<name>` string constants and `api.enums.<name>` aliases.
   `API`, `REVISION` and `SUPPORTED_FLAVORS` (a read-only proxy) on the
   facade. No `SetLimits`: the package holds no growing state, and its docs
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
   file for another flavour returns after its guard. Parse time and retained
   memory per flavour file are measured and recorded before the first release
   (the brief's performance review).
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
   procedure); `metadata/SCHEMA.md`; generated reference and change reports;
   CHANGELOG naming the captured build per flavour; EMBEDDING.md gains the
   second-global rule, the footprint row and the load-order entries;
   ARCHITECTURE.md and `docs/README.md` list the package; the design document
   stays current.
9. Status: planned; recorded 2026-09-23. Nothing implemented.

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
- [ ] **H1 — metadata schema and normaliser.** `metadata/SCHEMA.md`;
      `tooling.api.fetch` (one flavour, one pinned mirror commit, scratch
      directory outside the repository, provenance recorded);
      `tooling.api.normalize` with a Lua-literal parser for the documentation
      tables, the naming rules from `tooling/api/naming.json`, the alias
      table and collision failure; `tooling.api.validate` for the checks in
      the design document; tests over project-written fixtures.
- [ ] **H2 — generators.** `tooling.api.generate` writes the runtime flavour
      file, the LuaCATS definitions, the Markdown reference, the search index
      and the change report from one metadata capture; StyLua formats the
      Lua outputs; `luac -p` and the validator gate every output;
      determinism test; `tooling.api.diff` and the history model.
- [ ] **H3 — the facade.** `packages/apiKit/src/ApiKit.lua` with the surface
      in point 4, its specs, manifest, README, `docs/API.md`, `docs/NAMING.md`,
      CHANGELOG; the `wow` publication rule; error levels at the caller.
- [ ] **H4 — Retail.** First capture at a pinned mirror commit and build;
      metadata, runtime file, types, reference and search index committed
      together; the sampled generated-output spec; the naming exception table
      filled from the real collisions; load-cost measurement recorded.
- [ ] **H5 — Classic Era and Mists of Pandaria Classic.** Same as H4 per
      flavour; flavour-isolation checks across the three captures.
- [ ] **H6 — PTR and Beta.** Same as H4 when the mirror branches carry the
      documentation tables; until then the flavours exist as empty surfaces
      and the README says so.
- [ ] **H7 — documentation and review.** `docs/UPDATING.md`; EMBEDDING,
      ARCHITECTURE, `docs/README.md`, RELEASES (how a metadata refresh is
      versioned) updated; performance review written; acceptance review;
      `API_KIT_DESIGN.md` checked against what shipped.

Settled with the project owner on 2026-09-23, before H1: Blizzard's
documentation prose is carried into hover text and the reference with
provenance; a metadata refresh is a minor version with the change report in
the changelog, a removal noted as breaking for that flavour, the API
generation unchanged because the facade contract does not move (design
document, section 12.1). Still open: whether the generated Markdown reference
stays committed, decided in H4 once the Retail capture shows its size.
Implementation starts only on the owner's explicit go.

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

Last roadmap baseline update: 2026-09-23 (phases 0 through 4 and packages F
and G complete: 24 packages, every gate green; package H, `apiKit`, planned
and awaiting the owner's go; the standing obligations continue).
