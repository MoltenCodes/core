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
| `unbounded` | The `OptionsKit.UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `profileGroups` | Weak-keyed: the group table `ProfileOptions` returned to its link record (below). Revision 2. |

The tree prototype is published as `OptionsKit.Tree`. OptionsKit hands out no closures that outlive a call except the dynamic key checks inside schemas (below) and the callbacks of a profile group, so it needs no dispatch table: an upgrade replaces the prototype's methods and every existing tree sees them at once. A profile group's callbacks close over its link record and the database, not over any method, so they too keep working after an upgrade.

## Tree layout

A tree is one table created by `define`:

| Field | Meaning |
|---|---|
| `_schema` | The tree layout version, `2`. Layout 1 (revision 1) had no `_profileLinks`. |
| `_addonName` | The addon the tree belongs to. |
| `_defined` | `true` from the end of `Define` until `Undefine`. Every method refuses a tree without it. |
| `_db` | The SettingsKit database, or `false`. |
| `_root` | The root group's record. |
| `_records` | The path index: dotted path to record, for every option below the root. |
| `_walk` | Every record below the root, in walk order. |
| `_changed` | The SignalKit signal behind `OnChange`. |
| `_profileLinks` | The link records of the profile groups the tree holds, attached at the end of `Define` and detached by `Undefine`; usually empty. |
| `_maxOptions`, `_maxDepth`, `_maxDynamicEntries` | The limits the tree was defined under, `math.huge` for `UNBOUNDED`. Only `Define` enforces them; the multiselect schemas built from `_maxDynamicEntries` keep it in force afterwards. |

A tree is registered in `state.trees` only after the whole tree was built, so a `Define` that raises leaves nothing behind.

## Record layout

One record per option, created by `buildOption`:

| Field | Present for | Meaning |
|---|---|---|
| `_kind`, `_key`, `_path`, `_depth` | all | Identity. The root has `_key = false`, `_path = ""`, `_depth = 0`. |
| `_parent` | all | The parent record, or `false` for the root. `IsDisabled` and `IsHidden` follow it. |
| `_info` | all | The option's `info` table (below). |
| `_name`, `_desc`, `_order` | all | Sort keys and labels; `_desc` is the string, the `desc` function, or `false` when absent. Only `Describe` reads `_desc`, which is why a function is allowed there and not for `_name`, which `compareRecords` reads. |
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

The write itself runs as `pcall(assignField, container, key, value)`. `assignField` is a file-level function, so the protected call allocates nothing on success. The protected call also catches an error from a SettingsKit `OnChange` listener, which runs after SettingsKit stored the value, so on failure `writeBound` asks `db:Validate` with the same keys and the unwrapped value: when the database accepts it, the write was not refused and the listener's error is re-raised unchanged (level `0`); otherwise the refusal is re-raised at the caller's level with the `file:line:` prefix of SettingsKit's message (which points into OptionsKit) removed and the rest kept. The extra check runs on the failure path only.

`validateBound` hands SettingsKit the same `_bindKeys` array for `db:Validate`, so `Validate` of a bound option allocates nothing once SettingsKit's entry views on the path are alive.

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

## Describe

`describeRecord` builds a fresh node per record. A value option's current value goes through `snapshotValue`, which first passes a secret through untouched (at every level, before `type`, `getmetatable` or `pairs` sees it: a copy would touch the secret and hide it from a consumer's own secret check), then copies a table, replacing a table deeper than `MAX_DEPTH` (always 8, whatever the tree's `maxDepth`) with `"<depth exceeded>"` and a table already being copied above it with `"<cycle>"`, so no original table reaches the description, and, for a bound option whose value is a SettingsKit view (`getmetatable` answers `"SettingsKit.View"`), iterates it with `db:Pairs` so the copy holds the view's defaults as well as its saved keys. A view is an empty proxy to `pairs` and writes through to the saved variable, so handing one out would break both "plain" and "safe to edit".

## Profile groups

`ProfileOptions` builds an ordinary group spec whose callbacks close over one **link** record, and registers `state.profileGroups[group] = link`. The link holds:

| Field | Meaning |
|---|---|
| `db`, `SettingsKit`, `characterProfile` | The database, the facade `Registry:Find` returned (for `GetLimits`), and the `"<name> - <realm>"` profile read once from `UnitName`/`GetRealmName`, or `false`. |
| `name`, `order`, `description`, `localize` | The `ProfileOptions` options, `false` when absent. |
| `copySource`, `deleteTarget` | The profiles chosen in the two selects, `false` for none. They live here, not in the database: they are UI state. The getters answer them only while `isOtherProfile` still holds, so a stale choice reads as `nil` without anyone clearing it. |
| `suppress` | `true` while the `current` select's own `Set` is switching the profile, so the link's listener stays quiet and `Set` fires `OnChange` once. Cleared under `pcall` so a failing switch cannot leave it set. The `new` input switches unsuppressed: the current profile changed, and only the link can announce `current`. |
| `tree`, `path`, `connections` | Set by `attachProfileLink` at the end of `Define`: the four SignalKit connections to the database's profile signals are made first, one `pcall` each so a connect that raises disconnects the ones before it, and the tree and the group's path (`""` at the root) are recorded last. `false` while the group is in no tree. |

`buildOption` recognises the group by identity (`rawget(profileGroups, spec)`) when it meets it — which is why the consumer must pass the returned table as it is — refuses one whose `link.tree` is set or that already appears in the current build, and records it in the build context. `define` attaches every collected link after the whole tree was built, so a refused `Define` leaves no link pointing at a half-built tree; when one link fails to attach, the links attached before it in the same tree are detached before the error is raised again. `undefine` detaches them. The listener fires `tree._changed` with the `current` option's path and `db:GetProfile()`; it reaches into the tree's private signal, which is legitimate here because the closure is OptionsKit's own.

The `desc` fields of the group are functions, evaluated by `describeRecord`, and its `values` are functions, evaluated by `describeValues` and the schema's dynamic key check: the group holds no copy of the profile list, so it is never stale at `Describe`.

## Upgrades

A newer revision inherits `state` as it is: the tree metatable, the prototype and every tree. It rewrites the prototype's methods and `runtimeRevision`. Records carry no methods and no behaviour of their own beyond the consumer's functions and the schema closures, so nothing else needs migrating. A revision that changes the record or tree layout reads `_schema` to upgrade old trees: revision 2 adds `state.profileGroups` when it is missing and gives every layout 1 tree an empty `_profileLinks` (a revision 1 tree cannot hold a profile group), then stamps it layout 2. `validateStateBase` checks the fields every revision shares; `validateCurrentState` also requires `profileGroups`, which is what tells a finished revision 2 state from one still being committed.
