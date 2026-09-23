# ApiKit design baseline

> **Status:** design baseline, accepted 2026-09-23. No code exists yet; the
> delivery plan is package H in [`ROADMAP.md`](ROADMAP.md#package-h--apikit-the-wow-api-wrapper).
>
> This document is the canonical design of `apiKit`, the MoltenCodes package
> that gives addon authors a complete, typed, documented and flavour-aware
> interface over the public World of Warcraft addon API. It was consolidated
> from the project owner's design brief and adapted to the conventions this
> repository already follows. When a decision recorded here changes, this
> document changes in the same commit.

## Contents

1. [Overview](#1-overview)
2. [Goals](#2-goals)
3. [Non-goals](#3-non-goals)
4. [Position in the repository](#4-position-in-the-repository)
5. [Public namespace model](#5-public-namespace-model)
6. [Naming rules](#6-naming-rules)
7. [Architecture](#7-architecture)
8. [Semantic preservation](#8-semantic-preservation)
9. [Performance requirements](#9-performance-requirements)
10. [Types for LuaLS](#10-types-for-luals)
11. [Version awareness](#11-version-awareness)
12. [Metadata source and provenance](#12-metadata-source-and-provenance)
13. [Outputs](#13-outputs)
14. [Update pipeline](#14-update-pipeline)
15. [Validation](#15-validation)
16. [Testing strategy](#16-testing-strategy)
17. [Package layout](#17-package-layout)
18. [Developer experience](#18-developer-experience)
19. [Design rules](#19-design-rules)
20. [Definition of done](#20-definition-of-done)
21. [Future capabilities](#21-future-capabilities)
22. [Decisions summary](#22-decisions-summary)
23. [Document maintenance](#23-document-maintenance)

---

## 1. Overview

`apiKit` (facade `ApiKit`) makes the existing Blizzard addon API substantially
easier to discover, read, use, type-check, document, inspect and maintain
across client flavours and game builds. It does not replace that API with a
different platform, and it does not hide what the API does.

A representative goal is to make code such as

```lua
C_AddOnProfiler.MeasureCall(...)
```

available through a readable MoltenCodes surface such as

```lua
local api = wow.retail.api

api.profiler.measureCall(...)
```

without measurable runtime cost and without changing what the call does.

## 2. Goals

### 2.1 Complete public API coverage

The long-term target is coverage of the whole documented public addon API for
every supported flavour and build: global functions, `C_*` namespaces, events
and their payloads, enums, structures, parameters and returns, callback
signatures, documented restrictions, availability by flavour and by build,
deprecations and removals, and the metadata that tooling needs.

Completion is measured by coverage and correctness, never by having a wrapper
for a small curated subset.

### 2.2 Readability

Wrapper names are readable, predictable and close enough to Blizzard's names
that a developer who knows the raw API understands the MoltenCodes name
without learning an unrelated model. Names are produced by documented
transformation rules (section 6), not by hand.

### 2.3 Editor tooling as a product feature

LuaLS / LuaCATS definitions are a first-class output: autocomplete, hover
documentation, parameter and return types, structures, enum values, callback
signatures, flavour-specific availability, build-specific availability where
practical, and deprecation information.

### 2.4 Flavour awareness

Each flavour exposes exactly the API that exists on that client. Differences
between flavours are never flattened into an inaccurate universal typing.

### 2.5 Raw access stays

Direct access to the raw Blizzard API remains a supported and intentional
escape hatch, for exact behaviour, debugging, interoperability, and anything
newer than the captured metadata.

## 3. Non-goals

`apiKit` is not:

- an addon framework (the other Kits are);
- a state-management layer;
- a compatibility layer that pretends flavours are identical;
- a heavy runtime translation layer;
- a source of hidden behaviour or side effects;
- a layer that obscures protected functions, combat restrictions or taint.

Ergonomic helpers (section 7.3) are outside the initial release. They are
added one by one, each with its own record, when a helper proves its value.

## 4. Position in the repository

`apiKit` is one package among the others under `packages/`, and follows every
convention they follow:

- package id `apiKit`, facade `ApiKit`, API generation 1, published through
  `Registry:Bootstrap` like every other Kit, so two addons that embed
  different generation-1 revisions still end up with one copy and the newest
  wins;
- a `package.manifest.json`, `README.md`, `CHANGELOG.md`, `docs/API.md`,
  `src/`, `tests/`;
- the minimum footprint is Registry plus the `ApiKit.lua` facade plus one
  generated file per flavour the addon supports (constitution principle 4b);
- no other Kit is required. Flavour detection is a few host reads and lives
  in the facade itself, so `clientKit` is not a dependency.

The original brief placed the package at `packages/api`; the repository's
naming rule (lowerCamelCase ids ending in `Kit`, PascalCase facades) makes it
`packages/apiKit`. Nothing else about the brief's position changes.

## 5. Public namespace model

| Client | Namespace | Metadata source branch |
|---|---|---|
| Retail | `wow.retail.api` | `live` |
| Classic Era (Hardcore, Season of Discovery) | `wow.classic.era.api` | `classic_era` |
| Mists of Pandaria Classic | `wow.classic.mop.api` | `classic` |
| Public Test Realm | `wow.ptr.api` | `ptr` |
| Beta | `wow.beta.api` | `beta` |

Preferred usage is a file-local alias:

```lua
local api = wow.retail.api
```

### 5.1 Where the tables live

The framework's rule is one global, `MoltenCodes` (see
[`EMBEDDING.md`](EMBEDDING.md#the-registry-first-rule)). The namespaces
above are always reachable without a second global:

```lua
local api = MoltenCodes.wow.retail.api
```

`ApiKit` also publishes the short `wow` global, because the brief's preferred
usage depends on it, under one rule: **`wow` is published only when nothing
else owns it.** At load, if `_G.wow` is `nil`, ApiKit sets it to the same
table `MoltenCodes.wow` names. If `_G.wow` already exists and is not that
table, ApiKit leaves it alone, never overwrites it, and reports the situation
through `ApiKit:GetGlobalStatus()` (`"published"`, `"taken"`) so an addon can
fall back to `MoltenCodes.wow` or warn its user. `wow` is generic enough that
another addon may use it; the framework never fights for it.

### 5.2 One flavour per session

A client runs one flavour. Only the namespace of the running flavour is
populated; the other four names exist as empty tables so that
`wow.classic.era.api` on a Retail client is a table with no entries rather
than a `nil` index error, and `ApiKit:GetFlavor()` says which one is live.
The flavour is derived from the host once, at load: `WOW_PROJECT_ID`
distinguishes Retail, Classic Era and Mists; the test-build and beta probes
the metadata itself documents distinguish PTR and Beta from Retail. A
Burning Crusade Classic client, which the brief does not name, gets no
surface and `GetFlavor()` reports `"unsupported"`.

## 6. Naming rules

Names are generated. The rules are documented in the package
(`packages/apiKit/docs/NAMING.md`) and enforced by the generator; a hand
exception is data, not code.

1. **Namespace.** A `C_` namespace drops the prefix and becomes lowerCamelCase:
   `C_AddOnProfiler` → `addOnProfiler`, `C_Timer` → `timer`. A documented
   global function without a `C_` namespace is grouped under its
   documentation system, lowerCamelCased the same way: the `Unit` system
   becomes `unit`.
2. **Function.** The function name becomes lowerCamelCase:
   `MeasureCall` → `measureCall`. A global function whose name starts with
   its system's name drops that prefix: `UnitName` in system `Unit` →
   `unit.name`; `GetTime` in system `System` keeps its whole name →
   `system.getTime`.
3. **Initialisms** are lowercased as one unit at the start and kept as a unit
   elsewhere: `C_UIWidgetManager` → `uiWidgetManager`, `GetNPCName` →
   `getNPCName`. The initialism list is data in the naming rules file.
4. **Aliases.** A short, hand-chosen alias may point at a generated namespace
   (`profiler` → `addOnProfiler`). Aliases live in one reviewed table, are
   recorded in the metadata, appear in the LuaCATS output as the same table,
   and never replace the systematic name. The systematic name is canonical;
   the alias is convenience.
5. **Events** are exposed as string constants under `api.events`, named by
   lowerCamelCasing the event: `api.events.playerLogin == "PLAYER_LOGIN"`.
   Their payloads are types (section 10), not runtime.
6. **Enums** are direct aliases of Blizzard's `Enum` tables under
   `api.enums`, lowerCamelCased: `api.enums.itemQuality == Enum.ItemQuality`.
7. **Collisions** (two Blizzard names mapping to one wrapper name) fail
   generation. The fix is a documented exception in the naming rules file,
   never a silent suffix.

The goal is not creative renaming. The goal is to remove historical prefix
noise while keeping meaning and discoverability.

## 7. Architecture

Three layers, kept distinct.

### 7.1 Canonical metadata

A machine-readable model, normalised from the source in section 12, is the
single source of truth. Per flavour it records, for every entry: the
canonical Blizzard name, the wrapper name and any alias, namespace or system,
parameters (name, type, nilable, default where documented), returns,
structures, enums and their values, callbacks, events and payloads,
documentation text, restrictions (protected, secure-only, combat), the
build range in which the entry existed with that signature, deprecation
state, and provenance (source commit, build, capture date).

The model supports diffing two captures of one flavour (section 11).

### 7.2 Thin runtime facade

The generated flavour file binds by direct aliasing:

```lua
api.addOnProfiler.measureCall = C_AddOnProfiler.MeasureCall
```

never by a wrapper function that forwards arguments. A direct alias adds no
call, no closure, no allocation, no stack depth and cannot drift from the
host's semantics. A binding is made only when the host actually has the
function: the generated file reads each Blizzard namespace once and copies
what exists, so a function the metadata documents but the running build lacks
is simply absent from the wrapper, which is the truth about that client.

A wrapper function exists only where a direct alias cannot express the
documented contract, and every such case is listed in the package docs.

### 7.3 Optional ergonomic helpers

Helpers with real developer value may exist later, distinct from the mapping
layer, never silently altering Blizzard semantics. None ship in generation 1
of the initial release (section 3).

## 8. Semantic preservation

Unless a documented helper says otherwise, the facade preserves parameter
meaning and order, return order and multiplicity, `nil` behaviour, side
effects, asynchronous and callback behaviour, protected and restricted
behaviour, combat restrictions, taint behaviour and client availability.
Because the normal path is a direct alias, a protected function called
through `api` behaves exactly as when called directly, including the taint
rules in [`EMBEDDING.md`](EMBEDDING.md#taint).

Convenience never costs correctness.

## 9. Performance requirements

`apiKit` must be usable in hot paths. The normal call path is one table index
more than a raw call (`api.timer.after` versus `C_Timer.After`), and nothing
else: no wrapper call, no temporary table, no closure, no string work, no
runtime reflection, no dynamic lookup, no retained metadata that only tooling
needs, no garbage-collector pressure.

Everything that can be computed at build time is computed at build time by
the Python generator. What the client loads is a flat list of bindings for
one flavour. Load cost (parse time and retained memory per flavour file) is
measured and recorded in the package's performance review before the first
release; the standalone `MoltenCodes` addon must not pay for flavours it is
not running beyond parsing their guard line.

`apiKit` holds no growing state, so constitution principle 4a (bounded by
default) has nothing to bound here; the package documents that `SetLimits` is
not applicable.

## 10. Types for LuaLS

Flavour-specific LuaCATS definition files are generated so that
`local api = wow.retail.api` completes to Retail and
`local api = wow.classic.era.api` completes to Classic Era. Definitions
cover scalar and optional parameters, documented union-like values,
structures, tables and arrays, enums, callbacks, return tuples, nullable
values and event payloads. Hover text explains what the API does without
opening the generated implementation.

Types are development files, never loaded by the client. An addon points its
`.luarc.json` workspace library at `packages/apiKit/types/<flavour>`; the
package README shows the entry.

## 11. Version awareness

API availability is versioned data. Each flavour's metadata carries the
build it was captured from and a history that the update pipeline appends
to: when an entry first appeared, when its signature changed, when a field
or enum value changed, when it was deprecated and when it disappeared. The
history starts at the first capture this repository makes; earlier history is
not reconstructed.

Version data drives the generated definitions, the reference, the change
reports and, later, compatibility analysis.

## 12. Metadata source and provenance

The source is the client's own machine-readable API documentation, the Lua
tables shipped under `Blizzard_APIDocumentationGenerated` in the interface
code, as published per flavour branch by the community `wow-ui-source`
mirror. The pipeline fetches one flavour at one pinned mirror commit and
records that commit, the build it corresponds to and the capture date as
provenance in the metadata.

Two rules from the project constraints apply:

- **No Blizzard code in this repository.** The fetch stores the source
  tables outside the repository (a scratch directory); only the normalised
  MoltenCodes metadata is committed. Names, signatures, types, enum values
  and availability are facts about the platform, not code.
- **Undocumented functions are out of scope for generation 1.** Global
  functions that the documentation tables do not describe (a large part of
  the classic FrameXML surface) are not guessed. The metadata may list them
  as "undocumented" for tooling, but no wrapper is generated for them until
  a documented source exists.

Blizzard's documentation prose (the `Documentation` strings in the tables)
is carried into the LuaCATS hover text and the reference, with provenance
recorded beside it (decided 2026-09-23). The same text is republished by the
community references addon authors already use; the wrapper gives it a typed,
flavour-correct home rather than a second wording.

### 12.1 Versioning a metadata refresh

A refresh of one or more flavours to a newer build is at least a **minor**
version of `apiKit`, with the generated change report summarised in the
changelog. An entry Blizzard removed is noted in the changelog as breaking
for that flavour. The API generation stays at 1 as long as the facade contract
in `docs/API.md` does not move: the generated surface is data, not the
contract (decided 2026-09-23).

## 13. Outputs

From one metadata capture per flavour the tooling produces:

| Output | Path | Committed |
|---|---|---|
| Normalised metadata (source of truth) | `packages/apiKit/metadata/<flavour>/*.json` | yes |
| Runtime bindings | `packages/apiKit/src/flavours/<Flavour>.lua` | yes |
| LuaCATS definitions | `packages/apiKit/types/<flavour>/*.lua` | yes |
| Markdown reference | `packages/apiKit/docs/reference/<flavour>/` | yes, provisionally; decided with the owner after the Retail capture (H4) shows its size |
| Search index | `packages/apiKit/metadata/<flavour>/search.json` | yes |
| Build-to-build change report | `packages/apiKit/docs/changes/<flavour>/<from>-<to>.md` | yes |

Every generated file identifies itself as generated in its first lines, names
the generator, the flavour, the source commit and the build, and is never
edited by hand. Generated documentation states flavour and availability.

## 14. Update pipeline

The pipeline is Python standard library under `tooling/api/`, deterministic
and reproducible (same input, same bytes):

1. `fetch` obtains one flavour's documentation tables at a pinned mirror
   commit into a scratch directory.
2. `normalize` parses the Lua literal tables and writes the MoltenCodes
   metadata, applying the naming rules and the alias table.
3. `diff` compares the new capture with the committed one and records
   additions, removals, signature changes, deprecations, enum and structure
   changes into the history and a human-readable change report.
4. `generate` writes the runtime file, the LuaCATS definitions, the reference
   and the search index, and formats the Lua outputs with the pinned StyLua.
5. `validate` runs the checks in section 15; the repository gates then run.
6. Metadata, generated outputs and the change report are committed together,
   with the package changelog entry.

`packages/apiKit/docs/UPDATING.md` is the step-by-step procedure for a new
Blizzard build.

## 15. Validation

Generation fails rather than producing an incomplete or ambiguous package.
The validator checks: duplicate wrapper names, duplicate bindings to one
Blizzard function, missing required metadata, unresolved type, structure or
enum references, flavour leakage (an entry generated for a flavour whose
metadata lacks it), build-range contradictions, malformed Lua (`luac -p`),
malformed JSON, documentation generation failures, and that every runtime
binding maps to exactly the Blizzard name the metadata records.

## 16. Testing strategy

- **Tooling tests** (Python, `tooling/tests/`): parsing, normalisation,
  naming conversion including every initialism and exception, alias
  handling, flavour partitioning, version comparison, each generator, and
  byte-identical output on a second run. Fixtures are small tables written
  by the project in the documentation format, never Blizzard files.
- **Runtime specs** (Busted, `packages/apiKit/tests/`): the facade's
  bootstrap and upgrade, flavour detection on stubbed hosts, the `wow`
  publication rule in both states, registration of a flavour file, that
  aliases resolve to the intended host functions and preserve multiple
  returns and `nil`, that no argument is transformed, that a function absent
  from the stubbed host is absent from the wrapper, error levels, manifest.
- **Generated-output specs**: for each committed flavour, a sampled spec
  loads the generated file against a stub host built from the metadata and
  checks that every sampled binding resolves and that nothing binds outside
  the metadata.
- **Regression**: every generation or mapping defect gains a test.

## 17. Package layout

```text
packages/apiKit/
├── CHANGELOG.md
├── README.md
├── package.manifest.json
├── docs/
│   ├── API.md                 # the facade contract (handwritten)
│   ├── NAMING.md              # the naming rules and the exception table
│   ├── UPDATING.md            # procedure for a new Blizzard build
│   ├── changes/<flavour>/     # generated change reports
│   └── reference/<flavour>/   # generated Markdown reference
├── metadata/
│   ├── SCHEMA.md              # the metadata model, field by field
│   └── <flavour>/             # generated: namespaces, events, enums,
│                              #   structures, history, provenance, search
├── src/
│   ├── ApiKit.lua             # handwritten facade
│   └── flavours/
│       ├── Retail.lua         # generated runtime bindings, one per flavour
│       ├── ClassicEra.lua
│       ├── ClassicMop.lua
│       ├── Ptr.lua
│       └── Beta.lua
├── types/<flavour>/           # generated LuaCATS definitions (development)
└── tests/                     # Busted specs
tooling/api/                   # fetch, normalize, diff, generate, validate
tooling/api/naming.json        # initialisms, exceptions, aliases
```

Differences from the brief's proposed layout: the generator lives with the
other Python tooling under `tooling/`, not inside the package; generated
runtime files sit under `src/` so the builder ships them; the brief's
`generated/` directory is split into `src/flavours/`, `types/`, `docs/` by
what each output is for. Flavour directory names use the flavour ids of the
namespace model (`retail`, `classic-era`, `classic-mop`, `ptr`, `beta`).

The repository's builder, TOC generator and validator currently assume one
runtime file per package; package H starts by teaching them to list a
package's additional runtime files in load order after its facade.

## 18. Developer experience

Retail:

```lua
local api = wow.retail.api

local result = api.profiler.measureCall(myFunction)
```

Classic Era, with Classic Era autocomplete:

```lua
local api = wow.classic.era.api
```

Without the short global, or when another addon owns `wow`:

```lua
local api = MoltenCodes.wow.retail.api
```

The raw escape hatch, always valid:

```lua
local result = C_AddOnProfiler.MeasureCall(myFunction)
```

## 19. Design rules

1. **Truth before convenience.** Never expose an API on a flavour where it
   does not exist.
2. **Thin before clever.** Direct bindings; a wrapper function only where a
   binding cannot express the contract, and then documented.
3. **Generated before duplicated.** Comprehensive coverage needs tooling.
4. **Tooling is part of the product.** Autocomplete, hover, types and
   discovery are features.
5. **Raw access remains available.**
6. **Runtime cost stays low.** Build-time generation, never runtime
   interpretation.
7. **Version differences stay visible.**
8. **Names are predictable.** Documented rules, reviewed exceptions.
9. **Documentation and code agree.** One metadata source feeds both.
10. **The package stays modular.** `apiKit` absorbs no framework
    responsibility; it never owns another Kit's global.

## 20. Definition of done

The first production-ready `apiKit` release needs, in addition to the
repository's [definition of done for a Kit](ROADMAP.md#definition-of-done-for-a-kit):

- [ ] a documented canonical metadata schema;
- [ ] a deterministic generation pipeline;
- [ ] flavour-specific namespaces and the `wow` publication rule;
- [ ] Retail generation;
- [ ] Classic Era generation;
- [ ] Mists of Pandaria Classic generation;
- [ ] PTR generation (when the mirror branch carries the tables);
- [ ] Beta generation (when the mirror branch carries the tables);
- [ ] LuaCATS definitions per flavour;
- [ ] documented naming rules with the exception and alias tables;
- [ ] raw escape-hatch documentation;
- [ ] generated reference documentation;
- [ ] machine-readable metadata and search index;
- [ ] automated validation;
- [ ] build-to-build diff and change reports;
- [ ] regression tests;
- [ ] a performance review of the runtime facade and of load cost;
- [ ] the procedure for updating to a new Blizzard build.

## 21. Future capabilities

Once metadata and generation are mature the same data can feed API search,
change explorers, flavour comparison, deprecation reports, missing-API
detection, editor diagnostics, migration assistance, generated web
documentation, and CI checks that detect use of unavailable APIs, without
adding runtime cost. Each derives from the canonical metadata rather than
becoming a second source of truth. The handwritten `meta/wow/*.lua`
definitions the repository uses today are a candidate for replacement by the
generated types.

## 22. Decisions summary

- Package `apiKit`, facade `ApiKit`, generation 1, bootstrapped through
  Registry like every Kit; Registry is the only dependency.
- Target: the complete documented public addon API, per flavour.
- Namespaces `wow.retail.api`, `wow.classic.era.api`, `wow.classic.mop.api`,
  `wow.ptr.api`, `wow.beta.api`; always reachable as `MoltenCodes.wow…`; the
  `wow` global is published only when free and never overwritten.
- One flavour populated per session, detected once at load.
- Names by documented rules; aliases are reviewed data; collisions fail.
- Direct-alias bindings; wrapper functions are exceptions and listed.
- Metadata from the client's own documentation tables through the community
  mirror at pinned commits; only normalised metadata is committed; no
  Blizzard code in the repository; undocumented functions are not guessed.
- Generator in Python under `tooling/api/`; outputs under the package as in
  section 17.
- Performance: one table index over a raw call; load cost measured.
- Helpers deferred; nothing hides restrictions or taint.

## 23. Document maintenance

This document evolves with `apiKit`. A change to the namespace model, raw
access, the full-coverage objective, metadata as the source of truth,
flavour-specific typing, performance expectations or the naming philosophy is
an architectural decision: it is agreed with the project owner first and
recorded here, in the roadmap and in the package changelog in the same
change.
