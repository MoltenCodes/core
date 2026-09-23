# SchemaKit Tests

The SchemaKit suite covers:

- every builder's accept and reject cases, including the spec errors each builder raises, malformed string patterns refused at build time (including those Lua reports only while matching) and well-formed ones checked exactly like `string.find`, a node refused as `table` fields, a colon call refused, a metatable on a checked value ignored, and composition of nodes and sealed schemas;
- failures: exact `{ path, rule, expected, found }` for nested fields, elements and map entries, sorted field order, map key failures named as keys, `oneOf` reported at the `oneOf`, unusual keys rendered briefly and safely (World of Warcraft `|` escape codes doubled, control bytes shown as `\ddd`, long keys never cut inside a UTF-8 sequence), the reused failure table versus `freshFailures`, a custom check re-entering its own schema, and no checked value ever appearing in a failure;
- `Apply`: defaults filled into a copy, `false` kept, table defaults copied freshly each call, per-entry defaults of maps and arrays (the wildcard default), root defaults, open-table extras kept, `oneOf` alternatives, and failures reported like `Check`;
- sealed immutability: writes to schemas and nodes refused, both metatables protected, later edits to spec tables, defaults and descriptions without effect, forged schemas refused, re-sealing;
- bounds: 16 nested tables accepted and 17 refused with rule `depth` (by `Check` and `Apply`), an array over the default 1024 and over an explicit `max` refused with rule `max`, a map over its `max`, counting stopped one past the bound, and a closed table stopping at its first undeclared key;
- secret values through a local `issecretvalue` stub installed after load: every kind refuses a secret with rule `secret` before touching it (the stand-in secret raises on any use), nested secrets, `Assert` messages and `Apply`;
- allocation guards (`collectgarbage("count")` with the collector stopped) on a valid `Check` of a nested table with and without the secret probe, a passing `Assert`, and a failing root `Check` reusing its failure table;
- `Describe` output for every kind, freshness, and an optional root;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, an incomplete facade, and an in-place upgrade (the source patched to revision 2) that keeps nodes, schemas and failure tables;
- `error` levels: builder, `Seal`, receiver, `Assert` (default level and level 2) and sealed-write errors report the caller's own line;
- limits: the defaults in a fresh table, partial updates, `maxDepth` up to its ceiling of 64, a lowered `maxPatternCaptures`, `pathKeyLimit` in failure paths, `defaultArrayMax` read when a node is built, `UNBOUNDED` lifting the default array bound and refused (with its reason, at the caller's line) by the other three, values past a ceiling and invalid values refused without changing anything, dot calls, and the limits and the sentinel kept across an in-place upgrade;
- the three cookbook schemas from `docs/API.md`, run as written;
- manifest/runtime API and revision consistency, and the dependency list.

SchemaKit is pure Lua, so `support/SchemaKitTestEnv.lua` builds its environment with `wowApi = false` and installs the `issecretvalue` stub only in the specs that need it.

| Spec | Covers |
|---|---|
| `Builders_spec.lua` | every builder's accept, reject and spec-error cases, composition |
| `Failures_spec.lua` | failure fields, paths, key rendering, failure-table reuse |
| `Apply_spec.lua` | defaults filled into a copy |
| `Sealed_spec.lua` | immutability, forged receivers, re-sealing, `Seal` options |
| `Bounds_spec.lua` | depth, array, map and closed-table bounds |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `UNBOUNDED`, ceilings, limits across upgrades |
| `SecretValues_spec.lua` | secret values refused before any use |
| `Allocation_spec.lua` | allocation guards |
| `Describe_spec.lua` | `Describe` output |
| `Cookbook_spec.lua` | the `docs/API.md` cookbook, run as written |
| `ErrorLevels_spec.lua` | errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime metadata |
