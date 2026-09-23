# OptionsKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`OptionsKit._state` is shared by every embedded copy:

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `runtimeRevision` | The revision that last committed its functions. |
| `treeMetatable` | The metatable every tree shares; its `__index` is `OptionsKit.Tree`. |
| `trees` | Addon name to that addon's tree. At most one per addon name. |

The tree prototype is published as `OptionsKit.Tree`. OptionsKit hands out no closures that outlive a call except the dynamic key checks inside schemas (below), so it needs no dispatch table: an upgrade replaces the prototype's methods and every existing tree sees them at once.

## Tree layout

A tree is one table created by `define`:

| Field | Meaning |
|---|---|
| `_schema` | The tree layout version, `1`. |
| `_addonName` | The addon the tree belongs to. |
| `_defined` | `true` from the end of `Define` until `Undefine`. Every method refuses a tree without it. |
| `_db` | The SettingsKit database, or `false`. |
| `_root` | The root group's record. |
| `_records` | The path index: dotted path to record, for every option below the root. |
| `_walk` | Every record below the root, in walk order. |
| `_changed` | The SignalKit signal behind `OnChange`. |

A tree is registered in `state.trees` only after the whole tree was built, so a `Define` that raises leaves nothing behind.

## Record layout

One record per option, created by `buildOption`:

| Field | Present for | Meaning |
|---|---|---|
| `_kind`, `_key`, `_path`, `_depth` | all | Identity. The root has `_key = false`, `_path = ""`, `_depth = 0`. |
| `_parent` | all | The parent record, or `false` for the root. `IsDisabled` and `IsHidden` follow it. |
| `_info` | all | The option's `info` table (below). |
| `_name`, `_desc`, `_order` | all | Sort keys and labels; `_desc` is `false` when absent. |
| `_disabled`, `_hidden` | all | `false`, `true` or the predicate. |
| `_hints` | all | A copy of the kind's plain fields for `Describe` (`min`, `pattern`, `confirm`, …). |
| `_children` | `group` | Child records, sorted. |
| `_schema` | value kinds | The sealed SchemaKit schema. |
| `_setArgument` | value kinds | `"OptionsKit.Tree:Set <path>"`, the argument name `Assert` reports, built once so a valid `Set` builds no string. |
| `_validate` | value kinds | The `validate` function, or `false`. |
| `_get`, `_set` | unbound value kinds | The accessors. |
| `_bind`, `_bindScope`, `_bindKeys`, `_bindCount` | bound value kinds | The bind path as written, its scope, its remaining keys as an array, and their count. |
| `_values`, `_sorting` | `select`, `multiselect` | The copied values table or the values function; the copied sorting array or `false`. |
| `_func` | `execute` | The function `Execute` calls. |

Records are never modified after `Define`, which is what "the tree is sealed at Define" means here: the consumer's tables are read once and nothing refers back to them except the functions they contained.

## The path index

`_records` maps every dotted path to its record. It is filled while the tree is built — each record's path is its parent's path, a dot and its key — so a lookup at `Get` or `Set` is one `rawget` and no string is split or built per call. Keys are restricted to identifiers at `Define`, which is what makes the dotted form unambiguous.

The bind path is split once at `Define` into `_bindScope` and `_bindKeys`. `walkBound` reads the scope view with `rawget(db, _bindScope)` on every call — SettingsKit replaces `db.profile` on a profile switch, and reading an undeclared scope through the database's metatable would raise inside OptionsKit — then walks `_bindKeys[1 .. _bindCount - 1]` with ordinary indexing, so SettingsKit's views supply defaults. It returns the deepest table reached and the index of the key to use there: the last key, or the first key whose record is missing, because SettingsKit reads a record without a default and without saved data as `nil`. `readValue` answers `nil` for a missing record; `writeBound` wraps the value in nested tables for the missing keys (the only allocating `Set`) and does nothing for a `nil` write.

The write itself runs as `pcall(assignField, container, key, value)`. `assignField` is a file-level function, so the protected call allocates nothing on success; a SettingsKit refusal is re-raised at the caller's level with the `file:line:` prefix of SettingsKit's message (which points into OptionsKit) removed and the rest kept.

## Sorted arrays

Siblings are sorted once, at `Define`, by `compareRecords`: `_order`, then `_name`, then `_key`. Keys are unique among siblings, so the order is total and does not depend on `pairs`. The comparator reads plain fields only: no consumer code runs inside `table.sort`, which is what lets AceConfig's `order` functions corrupt its `info` or make `table.sort` raise "invalid order function".

`_walk` is the pre-order flattening of the sorted children, built by `flatten` after the whole tree exists. `Walk` is therefore a single loop over one array that reads three fields per record and allocates nothing. `Describe` recurses over `_children`, which are in the same order.

`select` keys are sorted (numbers before strings) before they become an `enum`, so the schema and its `Describe` do not depend on hash order either.

## `info` reuse

`newInfo` builds one `info` table per record at `Define`: the parent's key array plus the record's key, and `path`, `kind` and `tree`. Every callback for that option receives this same table, which is why `Get` and `Set` allocate nothing. The price is the documented rule that a consumer must neither keep nor modify it. OptionsKit never writes to an `info` after `Define`; a consumer that does corrupts only its own option's later calls.

Per-option tables were chosen over one table rewritten per call because callbacks re-enter: a `get` that calls `info.tree:Get(otherPath)` would otherwise have its own `info` rewritten under it.

A `select` or `multiselect` whose values are a function gets a `SchemaKit.custom` check created at `Define`, closing over the values function and the option's `info`; it is the only closure OptionsKit creates per option.

## Level bookkeeping

`Define` checks a tree recursively, and every refusal must still report the line that called `Define`. Each helper that can raise takes `level`, the value `error` needs inside that helper, and passes `level + 1` to every helper it calls. `ErrorLevels_spec.lua` pins refusals several groups deep, bound reads under `Describe`'s recursion, and every tree method. The one refusal SchemaKit would report itself — an invalid `input` pattern — is caught with `pcall` around the builder and raised again at the right level.

## Upgrades

A newer revision inherits `state` as it is: the tree metatable, the prototype and every tree. It rewrites the prototype's methods and `runtimeRevision`. Records carry no methods and no behaviour of their own beyond the consumer's functions and the schema closures, so nothing else needs migrating. A future revision that changes the record or tree layout reads `_schema` to upgrade old trees.
