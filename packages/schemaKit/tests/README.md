# SchemaKit Tests

The SchemaKit suite covers:

- every builder's accept and reject cases, including the spec errors each builder raises, a colon call refused, a metatable on a checked value ignored, and composition of nodes and sealed schemas;
- failures: exact `{ path, rule, expected, found }` for nested fields, elements and map entries, sorted field order, map key failures named as keys, `oneOf` reported at the `oneOf`, unusual keys rendered briefly and safely, the reused failure table versus `freshFailures`, a custom check re-entering its own schema, and no checked value ever appearing in a failure;
- `Apply`: defaults filled into a copy, `false` kept, table defaults copied freshly each call, per-entry defaults of maps and arrays (the wildcard default), root defaults, open-table extras kept, `oneOf` alternatives, and failures reported like `Check`;
- sealed immutability: writes to schemas and nodes refused, both metatables protected, later edits to spec tables, defaults and descriptions without effect, forged schemas refused, re-sealing;
- bounds: 16 nested tables accepted and 17 refused with rule `depth` (by `Check` and `Apply`), an array over the default 1024 and over an explicit `max` refused with rule `max`, a map over its `max`, counting stopped one past the bound, and a closed table stopping at its first undeclared key;
- secret values through a local `issecretvalue` stub installed after load: every kind refuses a secret with rule `secret` before touching it (the stand-in secret raises on any use), nested secrets, `Assert` messages and `Apply`;
- allocation guards (`collectgarbage("count")` with the collector stopped) on a valid `Check` of a nested table with and without the secret probe, a passing `Assert`, and a failing root `Check` reusing its failure table;
- `Describe` output for every kind, freshness, and an optional root;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, an incomplete facade, and an in-place upgrade (the source patched to revision 2) that keeps nodes, schemas and failure tables;
- `error` levels: builder, `Seal`, receiver, `Assert` (default level and level 2) and sealed-write errors report the caller's own line;
- the three cookbook schemas from `docs/API.md`, run as written;
- manifest/runtime API and revision consistency, and the dependency list.

SchemaKit is pure Lua, so `support/SchemaKitTestEnv.lua` builds its environment with `wowApi = false` and installs the `issecretvalue` stub only in the specs that need it.
