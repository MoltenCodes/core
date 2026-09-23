# SchemaKit Internals

This document describes the private layout behind SchemaKit API generation 1. None of it is a public contract.

## Package state

`SchemaKit._state` holds everything shared by every embedded copy:

| Field | Purpose |
|---|---|
| `schema` | State layout number (`1`). |
| `runtimeRevision` | The revision that last committed its functions. |
| `nodes` | Weak-keyed map from node proxy to compiled node. |
| `records` | Weak-keyed map from sealed schema proxy to its record. |
| `nodeMetatable`, `schemaMetatable` | The two proxy metatables, kept across upgrades. |

Both maps have weak keys: a proxy nobody holds can be collected, while the compiled node behind it stays alive as long as a parent's compiled node refers to it. Receivers and children are recognised by a lookup in these maps, never by `getmetatable`, so a forged table is refused and the lookup cannot be fooled.

## Compiled nodes

A builder validates its spec and compiles it at once into a flat table of fixed shape. Every field exists on every node; a field a kind does not use is `false`, so a node is never rehashed and every check reads fields the same way:

| Field | Used by |
|---|---|
| `layout` | Every node: the node layout number (`1`), so a later revision can recognise old nodes. |
| `kind` | Every node: `string`, `number`, `boolean`, `enum`, `table`, `array`, `map`, `optional`, `oneOf`, `any`, `custom`. |
| `expected` | Every node: the phrase a type or required failure reports. |
| `min`, `max`, `expectedMin`, `expectedMax` | `string`, `number`, `array`, `map` (`max` only). |
| `foundMax` | `array`, `map`: the fixed "table with more than N entries" phrase. |
| `pattern`, `expectedPattern` | `string`. |
| `valueSet`, `valueList`, `expectedEnum` | `enum` and string `oneOf`: a lookup set and the list in declaration order. |
| `integer` | `number`. |
| `fieldNames`, `fieldNodes`, `fieldSet`, `open` | `table`: names sorted, their compiled nodes at the same index, and a name set for the undeclared-key walk. |
| `of` | `array`. |
| `keys`, `values` | `map`. |
| `inner`, `hasDefault`, `default` | `optional`; `default` is a private deep copy. |
| `alternatives` | `oneOf`. |
| `check` | `custom`. |

Compiled nodes refer to their children's compiled nodes directly. Nodes are built bottom-up and never change, so the graph is acyclic by construction and no cycle check is needed. Every phrase a failure can report from the schema is built here, once, so a failure copies string references instead of formatting.

A node proxy is an empty table with `nodeMetatable`; a sealed schema is an empty table with `schemaMetatable`, whose `__index` is the shared `Schema` prototype.

## Schema records

`Seal` creates one record per schema:

| Field | Purpose |
|---|---|
| `layout` | Record layout number (`1`). |
| `root` | The compiled node checked at the top. |
| `failure` | The reused `{ path, rule, expected, found }` table. |
| `segments`, `segmentCount` | The path stack (below). |
| `freshFailures` | Whether a failing call returns a copy of `failure`. |

Re-sealing a schema creates a new record over the same `root`.

## The checker

`checkNode(record, node, value, depth, isSecret)` is one recursive function. It asks `isSecret(value)` first, handles `optional` (return `true` for `nil`, otherwise continue with `inner`) and a required `nil`, then dispatches on `kind` through an `if` chain to one file-local checker per kind. Containers call `checkNode` for their children with `depth + 1`. No closure is created per node or per call, and values are read with `rawget` and `next`, which allocate nothing and cannot run a metatable.

`isSecret` is `rawget(_G, "issecretvalue")`, read once per public call and passed down as an argument.

### Recording a failure

A failure is recorded in two halves:

1. the leaf that fails calls `fail(record, rule, expected, found)`, which writes three string references into `record.failure` and returns `false`;
2. every container on the way back up calls `pushSegment(record, key)` with the key it was checking and returns `false` itself.

Nothing is pushed while a value is valid. At the top, `finishFailure` reads the stack backwards (it was pushed innermost first), formats each key into the path, clears the stack so it retains no key, and returns the failure table, or a copy under `freshFailures`.

`oneOf` remembers the stack height before each alternative and restores it after a failed one, so the reported path ends at the `oneOf`. During descent the stack is always empty, because segments are only pushed while returning from a failure; a custom check that re-enters its own schema therefore cannot disturb the outer call's path.

A failing map key rewrites `expected` to `key <expected>`: the one string built on the failure path besides the path itself and the length phrases (`string of length N`, `array of N elements`).

### Bounds

- **Depth.** `table`, `array` and `map` refuse a table value when `depth > 16`. The root value has depth 1.
- **Size.** `array` and `map` count entries with `next` and fail on entry `max + 1`, before any element is checked. `array` then requires `rawget(value, index)` for every `index` in `1..count`; `count` entries all present at `1..count` means the keys are exactly `1..count`.
- **Closed tables.** The undeclared-key walk returns at the first key missing from `fieldSet`, so it runs at most `#fields + 1` steps.

## Apply

`Apply` runs `copyNode` and then an ordinary check of the result. `copyNode` mirrors `checkNode` but is tolerant: whenever it meets something it cannot copy (a secret, a wrong type, a table too deep, too large or with holes, an undeclared key of a closed table) it keeps the original value and moves on, and the check that follows reports it with the same rule and path `Check` would. A `nil` under an `optional` with a default becomes `copyPlain(default)`, which then goes through the inner schema so its own defaults are filled. For `oneOf`, each alternative's copy is checked in turn and the first that passes is kept; the trial checks restore the path stack.

`copyPlain` deep-copies tables only. It needs no bound at `Apply` time because the `optional` builder refuses a default nesting more than 16 tables (which also refuses a cyclic one).

## Describe

`describeNode` builds a fresh table per node, folding an `optional` wrapper into the description of its inner node (`optional = true`, `default = copyPlain(default)`). Lists and field names are copied, so nothing reachable from a description aliases compiled state.

## Closures and upgrades

SchemaKit hands out no closures: nodes and schemas are proxies whose behaviour comes from the prototype and the metatables, all kept in `_state` and on the facade. A newer revision rewrites `Schema`'s methods and both metatables' `__newindex` in place, and reads the existing compiled nodes and records, which carry `layout` so a revision that changes a layout can upgrade them lazily. The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised to 2 and checks that nodes, schemas and failure tables built before the upgrade keep working and compose with nodes built after it.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Builders and methods pass `3` to helpers they call directly and raise their own errors at `2`. `Assert` raises at `level + 1`, so its public `level` has the meaning `error` gives it in the function that calls `Assert`. The proxy metatables raise at `2`, which is the line that wrote.
