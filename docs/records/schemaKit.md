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

