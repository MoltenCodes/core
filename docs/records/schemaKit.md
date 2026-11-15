# schemaKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## schemaKit

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

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## schemaKit sparse compiled nodes and GetLimit

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

**schemaKit Rules and Apply parts: the heavy builders out of the core** — a change to facade `SchemaKit` and two new parts

1. Package `schemaKit`, facade `SchemaKit`, API generation 1, version 0.3.0
   (from 0.2.0), implementation revision 7 (from 6), node layout 2
   unchanged (a requirement: nodes built by revision 6 builders must stay
   valid for revision 7, point 5). New parts, each part revision 1, each
   needing the core at revision 7 or later:
   - `Rules`, `src/parts/SchemaKit-Rules.lua`, manifest
     `{ "description": "The builders whose rules need more than a type and bounds: string patterns (validated when built), SchemaKit.custom and SchemaKit.oneOf.", "revision": 1, "dependencies": {}, "optionalDependencies": {} }`;
   - `Apply`, `src/parts/SchemaKit-Apply.lua`, manifest
     `{ "description": "schema:Apply: a checked copy of a value with every declared default filled in.", "revision": 1, "dependencies": {}, "optionalDependencies": {} }`.
2. Purpose: the core keeps what every schema user runs: building the common
   kinds, sealing, checking every kind, describing, asserting, limits.
   a. **Rules part**: `isValidPattern`, `patternClassEnd`, the `pattern`
      branch of `buildString`, `buildCustom`, `buildOneOf`. The core's
      `string` builder hands a `pattern` spec field to
      `state.dispatch.compilePattern`; `custom` and `oneOf` on the facade
      call the part's builders. The checker keeps the pattern match
      (`string.find`), the custom call and `checkOneOf`, so a schema built
      while the part was loaded, or by an older copy, checks the same in
      any session.
   b. **Apply part**: `schemaApply` and `copyNode`, `copyTable`, `copyArray`,
      `copyMap`, `copyOneOf`, `countEntries`. `copyPlain` and
      `plainDepthWithin` stay in the core (`buildOptional` and
      `describeNode` use them).
   c. **Without a part** the member raises at the caller's line:
      `SchemaKit.custom is in SchemaKit's Rules part, which is not loaded: add schemaKit\parts\SchemaKit-Rules.lua`,
      the same for `SchemaKit.oneOf` and for `SchemaKit.string pattern`, and
      `SchemaKit.Schema:Apply is in SchemaKit's Apply part, which is not loaded: add schemaKit\parts\SchemaKit-Apply.lua`.
   d. `SchemaKit:HasPart(name)` answers without raising (the form EventKit,
      SchedulerKit, CodecKit and CommKit use).
   **Value, stated plainly**: OptionsKit needs Rules (patterns, custom) and
   CommandKit needs Apply, so an addon with both pays about 1.5 KB more than
   today (two part residues); SchemaKit users without them (ModuleKit,
   CommKit, BridgeKit, SettingsKit schema users, addons' own argument
   schemas) save about 14 KB. The database-only goal does not depend on
   this record (settingsKit record 1 takes SchemaKit out of that set). If
   the owner prefers fewer parts, this record can be skipped without
   affecting the settingsKit records.
   Non-goals: a smaller node model (for example `optional` as a field of the
   inner node instead of a wrapper node, about a third of a typical schema's
   nodes; unmeasured, a later record), shortening messages, moving
   `Describe` (2.5 KB, five Kits use it).
3. Dependencies: registry API 2, unchanged; parts: the core only. No host
   API (`issecretvalue` through the shared probe, as today).
4. Surface: unchanged when the parts are loaded; `SchemaKit:HasPart`. The
   facade and the `Schema` prototype stay complete without the parts (an
   older copy's surface check runs on the newer facade when it yields), the
   absent members being the raising stubs of 2c. Embedding: OptionsKit's
   manifest names `"schemaKit": { "api": 1, "parts": ["Rules"] }`
   (without the part, its `pcall(SchemaKit.string, { pattern = ... })` would
   report the not-loaded error as "is not a valid Lua pattern"), CommandKit's
   names `["Apply"]`; both are their owners' changes (report).
5. Ownership: part state in `state.parts.Rules` and `state.parts.Apply` with
   their `PART_REVISION`s; dispatch entries `compilePattern`, `buildCustom`,
   `buildOneOf`, `apply` set by the parts and never overwritten by a core
   revision. In-place upgrade from revision 6 with a part absent: revision
   6's facade `string`, `custom` and `oneOf` and its `Schema.Apply` are kept
   instead of the stubs (as WidgetKit revision 14 kept a single-file copy's
   members). They build layout 2 nodes into the shared `state.nodes`, which
   revision 7's checker reads unchanged, and revision 6's `Apply` reads the
   same layout; proved with a byte copy of revision 6 as fixture. Known
   limit, documented: revision 7 loaded first and a revision 6 copy after
   it, the older copy yields and that addon's pattern, custom, oneOf and
   Apply calls raise the not-loaded message until some addon embeds the
   parts.
6. Performance and memory (estimates: function sizes measured, times 1.33,
   SchemaKit's measured resident ratio, plus about 0.7 KB residue per part):

   | Case | Today | Expected | Basis |
   |---|---|---|---|
   | core | 82.7 KB | about 73 KB (Rules -7.4, Apply -6.3, stubs and `HasPart` +1, shared `isSecret` and `describeKey` +0.4; `limits` deferred, +2.6 when converted) | measured function sizes |
   | Rules part | | about 9 KB | 6.2 KB prototypes |
   | Apply part | | about 7.6 KB | 5.2 KB prototypes |
   | Check, Describe, Seal, builders | unchanged | unchanged | same code; one dispatch read only when a spec has `pattern` |
   | nodes | as above | unchanged | node layout 2 |

7. Tests: the 139 specs pass with both parts loaded; without each part,
   every stub raises at the caller's line with its message (ErrorLevels);
   nodes built with the parts then checked with the parts absent (a fresh
   load of the core only, same state); `HasPart`; each part's manifest and
   `PART_REVISION`; loading a part without the core raises; upgrade from
   revision 6 (byte-copy fixture) with the parts absent keeps revision 6's
   builders and `Apply`, then the parts loading take over; the documented
   reverse-order limit; shared `isSecret`, `describeKey` (`--check`);
   KitConformance opt-in (`tests/Conformance_spec.lua`: manifest, limits
   `maxDepth` 16 in 1..64, `maxPatternCaptures` 32 in 1..32, `pathKeyLimit`
   32 in 1..1024, `defaultArrayMax` 1024 with `UNBOUNDED`, receivers for
   `Seal`, `SetLimits`, `GetLimits`, `GetLimit`, the secret arguments ADR
   0002 names, upgrade seeding a sealed schema). Client suite (never run):
   the existing `MoltenCodesTest_SchemaKit` `.toc` lists both parts.
8. Docs: README (parts list, memory), `docs/API.md` (which file each builder
   lives in, `HasPart`, *Embedded copies and upgrades* revision 7, the
   section skeleton of `docs/CONTRIBUTING.md`), `docs/INTERNALS.md` (the
   dispatch entries, why the checker keeps every kind), CHANGELOG 0.3.0,
   `tests/README.md`. Outside, the maintainer's: EMBEDDING.md footprints,
   OptionsKit and CommandKit manifests (their owners').
9. Status: recorded 2026-11-16; code follows.

---

**What SchemaKit gives the AddonKit defaults path**

Today `MC:Database` infers a SchemaKit schema and needs `boolean`, `number`,
`string{max}`, `array`, `map`, `table`, `optional`, `any` and `oneOf` (only
for inferred map keys: string of at most 256 characters or number), plus
`Seal`, `Check` and `Describe` through SettingsKit. With settingsKit record 1
it needs none of it: the Defaults part reads the defaults itself and asks
SchemaKit only for leaves the author wrote as nodes (`MC.Range` is
`number{min,max}` in `optional`, `MC.Enum` is `enum` in `optional`, both
light builders in this core). No SchemaKit change is needed for that path;
`oneOf` leaves the core's set of builders the defaults path relies on.
