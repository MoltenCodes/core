# SettingsKit Internals

This document describes the private layout behind SettingsKit API generation 1: the saved table SettingsKit writes, the view design behind `db.<scope>`, and the package state. Only the saved-table layout is visible to players (it is what lands in `WTF/.../SavedVariables/MyAddon.lua`); none of it is a public contract for code.

## The saved table

`Open` creates every missing section of a writable database; nothing else is added unless the player changes something. A read-only database (stored version newer than `options.version`) is left exactly as the client loaded it.

```lua
MyAddonDB = {
  version = 2,                                    -- options.version, owned by SettingsKit
  global = { ... },                               -- db.global
  profiles = {                                    -- db.profile is profiles[<current>]
    Default = { ... },
    ["Tester - Silvermoon"] = { ... },
  },
  profileKeys = { ["Tester - Silvermoon"] = "Default" }, -- written by SetProfile
  char = { ["Tester - Silvermoon"] = { ... } },   -- db.char
  realm = { Silvermoon = { ... } },               -- db.realm
  class = { MAGE = { ... } },                     -- db.class
  faction = { Alliance = { ... } },               -- db.faction
  namespaces = {},                                -- reserved for v2 module namespaces
}
```

| Section | Keyed by | Written when |
|---|---|---|
| `version` | — | A new table is stamped at `Open`; each migration step advances it. Never lowered: a newer stored version stays, also through `ResetDatabase` under `allowNewerData`. |
| `global` | — | A write through `db.global`. |
| `profiles` | profile name | `Open` and `SetProfile` create the current profile's table; writes through `db.profile` fill it. |
| `profileKeys` | `"<name> - <realm>"` | `SetProfile` records the character's choice; `DeleteProfile` removes choices naming the deleted profile. |
| `char`, `realm`, `class`, `faction` | the scope key read at `Open` | The first write through that scope creates the entry. |
| `namespaces` | module name | Nothing in v1. It exists from v1 so v2 (spec-aware profiles and namespaces) adds data without a layout change. |

Inside a scope, values are stored by field name exactly as the schema declares them; a keyed section is a table keyed by the consumer's keys. Defaults are never stored, except the first-read copy of a plain table default (an array, say), which `Compact` removes while it is unchanged.

## Package state

`SettingsKit._state` holds everything shared by every embedded copy:

| Field | Purpose |
|---|---|
| `schema` | State layout number (`1`). |
| `runtimeRevision` | The revision that last committed its functions. |
| `dispatch` | `compactAllOnLogout`, called by the one shared logout listener, `compactOnLogout`, called for each database (and by the per-database listeners revisions 1 to 5 connected), and `readView` (revision 7), the view `__index` that getters call on their slow path, so an upgrade replaces their behaviour. |
| `databases` | Saved-variable name to its database. Strong: a database lives for the session, like its saved variable. |
| `views` | Weak-keyed map from view proxy to its node. |
| `viewMetatable` | The one metatable of every view: `__index`, `__newindex`, `__metatable = "SettingsKit.View"`. |
| `databaseMetatable` | The one metatable of every database: `__index` (methods, and the unavailable-scope error), `__newindex` (refuse). |
| `unbounded` | The `SettingsKit.UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `limits` | The shared limits `SetLimits` writes: `maxProfileNameLength` and `pathKeyLimit`. |
| `logoutDatabases` | Revision 6: the databases the shared `PLAYER_LOGOUT` listener compacts, in the order they were opened. An upgrade over an older revision adds it empty. |
| `logoutConnected` | Revision 6: whether the shared listener is connected to EventKit. |

## Databases

A database is a table carrying its views as plain fields (`global`, `char`, ..., `profile`), so reading `db.profile` is a raw field read with no metamethod, and private fields prefixed with `_`:

| Field | Purpose |
|---|---|
| `_layout` | Database layout number (`4`). Layout 1 (revisions 1 to 4) had no `_newerVersion` and `_readOnly`; layout 2 (revision 5) had `_unavailable`, the messages of reading an undeclared or unavailable scope, which `databaseIndex` now builds when such a scope is read; layout 3 (revision 6) had no `_generation`. |
| `_name` | The saved-variable name. |
| `_raw` | The saved table. |
| `_schemaSource` | The schema table passed to `Open`, to recognise a reopen. |
| `_scopes` | Scope name to scope record (below), for every declared scope. |
| `_charKey` | `"<name> - <realm>"`, or `false`. |
| `_defaultProfile` | The resolved default profile name (`"char"` already resolved). |
| `_profile` | The current profile name. |
| `_profileRoots` | Profile name to its cached root view. |
| `_version` | `options.version`, or `false`. |
| `_newerVersion` | The stored version when it was newer than `options.version` at `Open`, else `false`. `ResetDatabase` stamps it instead of `_version`, and the read-only messages name it. |
| `_readOnly` | `true` when `_newerVersion` is set and `allowNewerData` was not. Read with `rawget` by every write path. |
| `_signals` | The four profile signals, each created by the first `OnProfile*` call that connects to it; a signal nobody connected to is absent and not fired. |
| `_generation` | Revision 7: a counter every SettingsKit mutation that can change which saved table a view resolves to increments (`bumpGeneration`); a node's cached table is current while the node's `generation` equals it (see [Resolution](#resolution)). |

A scope record holds the scope's `name`, SettingsKit's sealed `schema` (shared by every database opened with the same schema node, see [Plans](#plans)), its compiled `plan`, the `sectionName` and `sectionKey` of its saved table, whether it is `available`, and its `OnChange` `signal`: `false` until the first `OnChange` of the scope creates it, so a write nobody listens to fires nothing. An undeclared scope has no record.

A missing scope field falls through to the metatable's `__index`, which looks for a method on the `Database` prototype and otherwise, for a scope name, raises at the reading line the message for a scope without a record (not declared) or with `available = false`, built from the saved-variable name at that moment.

## Plans

`Open` seals each scope schema and describes it once (`schema:Describe()`), and compiles the description into a plan tree. A plan node records:

| Field | Meaning |
|---|---|
| `layout` | Plan layout number (`2`). Plans revision 5 compiled have none, and get the fields below from an upgrade. |
| `proxied` | `"record"` for a `table`, `"map"` for a `map`, `false` for everything else or below SchemaKit's `maxDepth` as it stood at `Open` (16 by default). |
| `fieldNames`, `fields` | Record: sorted names and each field's plan. |
| `ownDefaults` | Record: every field default, filled the way `schema:Apply` fills them. |
| `ownKinds` | Record: how each field reads with `ownDefaults`, one of the `READ_*` kinds (below). |
| `fastChecks` | Record: for each field that is a `string`, `number`, `boolean` or `enum` described only by fields the fast path knows, the rules the write fast path checks (`compileFastCheck`); empty for a plan revision 5 compiled. |
| `values`, `max` | Map: the plan of the values and the entry bound. |
| `keyKind` | Map: the SchemaKit kind of the keys, so `Validate` can turn a dotted-path segment into a number key. |
| `default` | The declared default, filled. On a map's `values` plan this is the wildcard default. |
| `defaultKind` | How a read of `default` answers: `READ_NIL` (none), `READ_COPY` (a table, copied) or `READ_DEFAULT` (the value). |

`fillDefaults` mirrors `Apply`: a missing value takes a copy of the declared default, then records are filled field by field, maps entry by entry and arrays element by element. `oneOf` defaults are not filled inside, because `Apply` picks the alternative by checking. Plans never change after `Open` and are shared by every view of the scope; the default tables in them are never handed to a consumer.

`compilePlan` is also where the rule "every field of a record read through a view is optional" is enforced, with the schema path of the offender.

**Compiled once per schema.** `compileScope` keeps what it built for a scope schema in `compiledScopes`, a file-local weak-keyed table keyed by the schema node or sealed schema `Open` received: the seal and the plan, with SchemaKit's `maxDepth` and revision at the time. A node is immutable from birth, so a later `Open` with the same node, under the same `maxDepth` and SchemaKit revision, reuses both and skips `Seal`, `Describe` and the compilation. The seal is shared only between SettingsKit's databases, never with the consumer, so a write still cannot overwrite the failure of a check the consumer runs. The cache is per copy: an upgraded copy compiles its own.

## Views

### Why the proxy is empty

Lua 5.1 calls `__newindex` only when the key is absent from the table being written. A view that stored the saved values itself would stop seeing writes to every key it held, so validation would silently stop after the first write of each field. Every view is therefore an **empty** table with the shared view metatable, and the saved data lives behind it.

### Nodes

Each proxy maps, through `state.views`, to a node. A node has at most 16 fields, so Lua 5.1 gives it a 16-slot table instead of a 32-slot one: what only a scope root needs lives on the root, reached through `root`, and nothing derivable is stored.

| Field | On | Meaning |
|---|---|---|
| `layout` | every node | Node layout number (`3`). Layout 1 (revisions 1 to 5) carried `db`, `scope`, `sectionName`, `dead` and `sectionKey` on every node, a `displayPath`, a `probeSet` flag and a map's entry cache in `entries`, and none of `depth`, `pathKeys`, `kinds`, `ownEntries`, `valuesProxied` and `verified`. Layout 2 (revision 6) carried `kind` (`"record"` or `"map"`), `depth` below a root and `dead` on a root, and no `cache` or `generation`. |
| `plan` | every node | The plan of the value the view shows. |
| `parent`, `key` | every node; `key` below a root | The parent node and this view's key in the parent's saved table; `parent` is `false` for a scope root. |
| `root` | every node | The scope root node (a root is its own). |
| `db`, `scope` | root | The database and the scope record. |
| `sectionKey` | root | Where the root's saved table lives in its scope's section (`"Default"` in `profiles`, `"Name - Realm"` in `char`); `false` for `global`. The section name is the scope's `sectionName`. |
| `defaults` | every node | The defaults this view reads, built by `viewDefaults`: the parent's default for this key (a record's field default, or a keyed section's own default entry), else the plan's declared `default` (for a map entry, the wildcard default), else the record's `ownDefaults`. A map declared without a default has `false` here, and the entries below it still fall back to the wildcard. |
| `path` | every node | Where the view is, relative to its scope: `frame`, `auras[118]`, `""` for a root; the `path` of `OnChange`. Each key is rendered by `formatKey` with SchemaKit's rule for failure-path keys (`|` doubled, control bytes as `\ddd`, cut at the shared `pathKeyLimit`, 32 bytes by default, between UTF-8 characters). Messages show `displayPathOf(node)`, the scope name joined to it (`profile.frame`). |
| `pathKeys` | below a root | The keys from the root's saved table down to this view's, for `refreshContainer`. The view's depth (a root is 1) is one more than their count. |
| `kinds` | record | How each declared field reads (below): the plan's `ownKinds` when this view's defaults answer the same way, which is the common case, else a table of its own. A node with `kinds` is a record view; a node without is a keyed section's. |
| `ownEntries`, `valuesProxied` | map | The section's own default entries (`false` when it has none, so a read of a missing entry skips the lookup), and whether its values are read through views. |
| `cache`, `generation` | every node | The saved table this view resolved (`false` when there was none) and the database `_generation` it resolved it in; `NEVER_RESOLVED` (`-1`) before the first access. A root detached by `DeleteProfile` or `ResetDatabase` has `generation = DETACHED` (`false`), which never equals a database generation, and no cached table. |
| `verified` | every node | Whether a full check of a write through this view has passed (always `true` for a root), which the write fast path relies on (below). |
| `probe`, `probeKey` | every node | The scratch table this view contributes to a write's probe, and the one key set in it, or the file-local `NO_PROBE_KEY` when none is. |
| `children` | every node | Record: field name to child view, built with the record. Map: key to entry view, weak-valued, built on first access. |

No node refers to its own proxy. `state.views` has weak keys, and Lua 5.1 weak tables are not ephemeron tables, so a node that referenced its proxy would keep the proxy alive forever; without that reference an entry view nobody holds can be collected, and a keyed section's weak-valued `children` cache drops it.

### Resolution

`refreshContainer(node)` walks down from the saved variable: the root's section (`raw[scope.sectionName]`), its entry (`[sectionKey]`), then each of the view's `pathKeys`, stopping at anything missing or not a table. It costs one `rawget` and one `type` per level and allocates nothing. It stores the answer in the node (`cache`, `false` for none) with the database's current `_generation`; `resolveContainer(node)` returns the cached table while the two generations are equal and refreshes otherwise. `resolveForWrite(node)` uses the cached table when there is one, and otherwise walks creating each missing table (replacing a non-table value in the way), which bumps the generation.

The cache is sound because every SettingsKit mutation that can change which table some view resolves to bumps `_generation`, so every node refreshes on its next access:

| Mutation | Why it bumps |
|---|---|
| a write storing a table value, or over a table value (`writeView`), `nil` included | the views below that key resolve to a different table, or to none |
| a write or a materialising read that creates missing tables (`resolveForWrite`) | views that cached `false` on that path now have a table |
| `SetProfile` to a profile without a table (`ensureProfile` created it) | a root of that name that cached `false` now has a table; switching to an existing profile changes no table |
| `CopyProfile`, `ResetProfile` | the profile's table is emptied in place and its nested tables replaced or removed |
| `DeleteProfile`, `ResetDatabase` | roots are detached, and `ResetDatabase` empties the saved variable and recreates its sections |
| `Compact`, at logout too | removes nested tables equal to their defaults; bumped first, so a compaction that raises leaves no stale cache |
| `Resync` | the consumer edited the saved variable directly |

A scalar written over a scalar changes no table, so it leaves every cache current; that keeps the hot write path from forcing every view to resolve again. Migrations run inside `Open` before any view exists. Direct edits of the saved variable after `Open` are not seen until `Resync`: a view keeps the table it holds (scalar edits inside it show at once).

A table with a metatable (a direct edit) is returned by `refreshContainer` but never cached, so every access to it walks again and uses `rawget`. Reads through a cached table use plain indexing, which is a raw lookup exactly because the cached table has no metatable; that saves a C call per read. A detached root keeps its `DETACHED` generation, so it never serves a cached table, its walk answers `nil`, and a stale view reads defaults and cannot resurrect a deleted profile; the views below it cache `false`.

A node's 16-field budget is kept by deriving what revision 6 stored: the kind of view from `kinds`, the depth from `pathKeys`, and a root's detached state from its `generation`. The database gained `_generation` as its fifteenth private field; with two scope views it has 17 fields and a 32-slot table (640 bytes more per database).

Views are built recursively down to SchemaKit's `maxDepth` limit (16 by default) as it stood when the database was opened, the deepest value SchemaKit follows; scans, comparisons and `CopyProfile` read the limit again through `SchemaKit:GetLimits()` each time they start (`readMaxDepth`), so `SchemaKit:SetLimits{ maxDepth }` reaches them without reopening; a record or map below that is read as a plain value. Record child views are built when their parent is built (at `Open`, and when a profile view is first built by `SetProfile`); keyed-section entry views on the first read of each key.

### A read

Every read through a view is one call of `viewIndex`. It finds the node, asks `issecretvalue` about the key before comparing it or using it to index anything (a secret key raises at the reading line), reads the saved value (with plain indexing through the cached table while the node's generation is current, else with `rawget` after `refreshContainer`), and answers:

- **record**, in `viewIndex` itself: the key's `READ_*` kind comes from `kinds`, worked out when the view was built from its plan and defaults, so a read tests the type of no default. A saved value is returned as it is, except that a table under a record or map field returns the child view. Nothing saved: `READ_DEFAULT` returns the default, `READ_VIEW` the child view (a record or map field with a default), `READ_COPY` a plain-table default copied into the saved table (`materialise`), `READ_NIL` and `READ_VIEW_OR_NIL` `nil`, and an undeclared key (no kind) `nil`.
- **map**, in `readMap`: the same, with the default taken from the section's own default entries (`ownEntries`) and then the wildcard default, whose kind the plan's `defaultKind` gives, and entry views built on demand. A plain-table default of a missing entry is returned as a fresh copy and never stored, and `materialise` stores nothing when the view sits inside an entry that is not saved yet (`wouldCreateEntry`), so reads never grow a keyed section past its `max` or store a key its key schema refuses.

A read therefore costs the `__index` call, the secret probe (one `rawget` of the global and one `type`), one generation comparison, one plain table read and one `type` of the value found, and a few field reads of SettingsKit's own tables. The first two are what an empty proxy and the secret-key refusal cost. After a bump, the first access through each view adds the walk (one `rawget` and one `type` per level) and one `getmetatable`.

### Getters

`db:Getter(source, key)` probes the key once and returns a closure. For a field whose answer is a plain value (`READ_DEFAULT`, `READ_NIL`, or an undeclared key of a record view), `plainGetter` captures the node, the key and the default: while `node.generation == db._generation` it reads `node.cache[key]` directly and falls back to the default; otherwise it calls `dispatch.readView(proxy, key)`, the newest revision's `viewIndex`, which refreshes the cache. A getter made from a scope name compares `db[scopeName]` (a raw field) with the view it last read and takes the new view's node when `SetProfile` or `ResetDatabase` changed it; every profile view shares the scope's plan and defaults, so the captured default holds. Every other getter calls `dispatch.readView` on each call.

A getter is a closure a later revision cannot rewrite, so its fast path reads only `node.generation`, `node.cache` and `db._generation`. A later revision keeps their meaning, or sets every `db._generation` to a value no node holds (and keeps its own counter elsewhere), so old getters always take the dispatched path. The upgrade over revision 6 gives every database `_generation = 0` and every node `NEVER_RESOLVED`, which is equal to no generation.

A saved value that is not a table under a record or map plan (hand-edited or corrupted data) reads as absent: the read falls through to the default, so the child view stays usable, `refreshContainer` already skips a non-table on the way down, and `resolveForWrite` replaces it on the next write. `wouldCreateEntry` counts such a keyed-section entry as not saved, so a materialising read below it never overwrites it.

A saved value, a key from the caller's path and a default from the caller's schema did not originate in SettingsKit, so their absence is tested with `type(value) == "nil"`, the repository rule, which never compares anything. In the client a secret compared with a value of its own type raises, as does a secret used as a key; a comparison with `nil` happens not to raise (measured on Retail 12.1.0 b69933). Only values SettingsKit built (its nodes, plans, caches and the results of its own lookups) are compared with `nil` directly.

### Iteration

`db:Pairs(view)` returns the file-local `pairsNext`, the view and `nil`. `pairsNext` is stateless: phase one walks `node.defaults` (a record's field defaults or a keyed section's own default entries), phase two walks the resolved saved table and skips keys that have a default. The previous key tells the phases apart, because a key with a default always belongs to phase one. A phase-one read may store a plain-table default, which only adds a key phase two skips, so the saved table never changes while phase two walks it.

### A write

`viewNewIndex` → `writeView`:

1. Refuse on a read-only database (`_readOnly`), then on a detached root.
2. Refuse a secret key, then a secret value, then a table value that contains a secret, is or contains a view (`state.views` lookup), or is or contains a table with a metatable (`scanValue`, bounded by SchemaKit's `maxDepth` read when the write starts and the database's `_maxScannedEntries`, 65536 by default and `math.huge` when opened with `SettingsKit.UNBOUNDED`). The scan runs on every client: a view stored in a saved table would be a non-empty proxy, so later writes to its keys would skip `__newindex` and validation, and it would alias the other view's data on disk.
3. **Schema check** (`checkWrite`), on the fast path or by the full probe check:
   - **Full probe check.** Each view from the written one up to the root sets its key in its parent's probe to its own probe, the written view sets `key = value` in its probe, and the scope's sealed schema checks the root probe. The probe holds exactly the path to the written value, and every other field of every record on the path is optional (`compilePlan` guarantees it), so the check passes exactly when the value is valid where it is written. The probes are cleared again before any error is raised. A valid check allocates nothing; the reported path is SchemaKit's own, relative to the scope, and the message is built only on failure. When it passes, the view is marked `verified`.
   - **Fast path.** A value that is not a table, written to a record view that is `verified`, under a field with a fast check, is accepted without asking SchemaKit when the value passes the field's own rules (`passesFastCheck`) and the chain is within SchemaKit's `maxDepth` (`depthAllows`). That is exactly when the full check would pass: the full check of such a write depends on the value's rules, on the keys of the chain (declared fields, keyed-section keys the key schema accepts, sections whose `max` allows one entry), which cannot change for a view once a full check through it passed, and on the chain's depth. The fast check reproduces SchemaKit's rules for `string` (type, `oneOf`, length, pattern), `number` (type, NaN, `integer` with infinities, bounds), `boolean` and `enum` exactly as `Describe` states them, and a field described with anything else gets none, so a rule a later SchemaKit adds is never skipped. SchemaKit's `maxDepth` can change at any time and `GetLimits` reads it only by allocating, so `depthAllows` checks a Kit-owned chain of `depth` nested tables against a sealed schema of the same shape (`depthProbes`, one per depth, built with the first view of that depth); a root needs none, since `maxDepth` is at least 1. Anything else, and every value the fast path refuses, goes to the full check, so every refusal and its message still come from SchemaKit. `FastPaths_spec.lua` writes every candidate value to every kind of scalar field, at the top, in a nested record and in an entry, before and after the view is verified, and requires SchemaKit's verdict and message each time.
4. Refuse a write that would add an entry to a keyed section already holding `max` entries (the probe holds one entry, so the bound is counted against the saved table, stopping at `max`).
5. Store with `rawset` into the resolved (or created) table, bumping the generation when the value stored or the value replaced is a table.
6. Fire the scope's signal with `(db, scope, key, value, path)`, when the scope has one: it is created by the first `OnChange`.

The checks of steps 1 to 4 live in `refuseWrite`, which returns the refusal message or `nil`; `writeView` raises the message at the writing line, and `db:Validate` returns it. `Validate` reaches the node holding the last key the way reads do (`descendPath`: a record's child view, or a keyed section's entry view) and calls `refuseWrite`, so it uses the same probe chain, sets and clears it the same way, and never stores anything.

A probe key left behind by a custom check that raised mid-check is cleared by the next write that uses that probe (`probeKey`), so a stale key can never leak into a later check.

## Migrations

`migrate` compares the stored version with `options.version`. A newer stored version is returned to `Open` untouched (`_newerVersion`) and nothing runs. Otherwise every pending step with a function runs through `runMigrationStep`:

1. `copySavedTable` deep-copies the saved table. It walks with its own work list (no recursion, so no depth limit), keeps a memo from each original table to its copy so a table reached twice is copied once and cycles close on the copies, uses keys as they are, and touches tables only with `next`, `rawget` and `rawset`. A secret is carried over without being indexed or used as a memo key.
2. The step runs on the copy under `pcall`. A failure returns before anything touched the saved table.
3. For the last step with a function, `findLayoutProblem` checks the copy: a layout section present but not a table fails the step without committing it.
4. `adoptMigrated` empties the saved table in place and moves the copy's top-level entries into it, then walks the result once and points every reference to the copy's root at the saved table, so a cycle through the root survives and the saved-variable global keeps its identity.
5. The version is stored.

When no step with a function is pending, the layout is validated before the version is stamped, so a refused table is never written. `Open` validates the layout again (`validateLayout`) after `migrate`, which is where a table without a version, a current one and a read-only one are checked, and only then creates the missing sections (`createLayout`) of a writable database.

The cost is one copy and one walk per pending step, each visiting every table and entry once. The saved table of 10,000 nested profiles measured in `docs/API.md` (about 50,000 tables) costs about 26 ms per step on host Lua 5.1.

## Compaction

`compactRecord`, `compactMap` and `compactValue` walk a saved table together with its plan and defaults. A value deeply equal to its default is removed (`deepEqual` treats a secret as unequal to everything and stops at SchemaKit's `maxDepth`, read when the compaction starts). A record or map table is compacted first and then removed when it is empty and has a default to fall back to. The walk follows the plan, which `compilePlan` stops at the `maxDepth` in force at `Open`, so it carries no depth counter of its own; keys the plan does not declare are never visited, so undeclared data survives. `compactScope` walks every entry of a section, removes empty character, realm, class and faction entries, and keeps empty profiles. At logout, the one shared listener calls `dispatch.compactAllOnLogout()`, which calls `compactOnLogout(db)` for every database on `state.logoutDatabases`, in the order they were opened; `compactOnLogout` skips a read-only database, runs `compactDatabase` under `pcall` and reports a failure through `geterrorhandler()`, so one database's failure never stops another's compaction.

## Closures and upgrades

SettingsKit hands out no closure per database; the only closures it hands out are the getters a consumer asks for (see [Getters](#getters)). The first database opened while EventKit is registered connects the one shared `PLAYER_LOGOUT` listener, a file-local function that calls through `state.dispatch`, and sets `state.logoutConnected`; every database opened while EventKit is registered joins `state.logoutDatabases`. The connection EventKit returns is not kept: databases live for the session and are never disconnected. Revisions 1 to 5 connected one listener per database, calling `dispatch.compactOnLogout(db)`; those keep working after an upgrade, and their databases are not on the shared list, so none is compacted twice. Views and databases get their behaviour from the two metatables in `_state` and the `Database` prototype, which a newer revision rewrites in place. Databases, nodes and plans carry layout numbers so a revision that changes a layout can upgrade them lazily. The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised by one and checks that a database opened before the upgrade, its views, its `OnChange` and profile listeners and its logout compaction keep working.

Revision 1 gave an entry view of a keyed section declared without a default `false` for its `defaults`, and handed that `false` down to the record views below it, so a saved entry read `nil` where the wildcard or a field default applied. Revision 2 builds every node's `defaults` through `viewDefaults`, and an upgrade over revision 1 walks `state.views` once and recomputes the `defaults` of every live node, parents first; a node revision 1 built correctly gets the same table back. A spec leaves two nodes in the revision 1 shape, reloads, and checks that they read their defaults.

Revision 5 added database layout 2 (`_newerVersion`, `_readOnly`) and the `IsReadOnly` method. An upgrade over revisions 1 to 4 walks `state.databases` once and brings every layout 1 database to layout 2: `_readOnly` is `false`, because the database was opened writable and an addon may already be writing through it, and `_newerVersion` is read from the saved table's current `version` when that is an integer above the database's `_version`, so `ResetDatabase` never lowers it. A spec leaves two databases and the prototype in the revision 4 shape, reloads, and checks the fields, the writes, `ResetDatabase` and that a database opened afterwards is read-only over newer data.

Revision 6 added node layout 2, plan layout 2 and database layout 3 (see the tables above) and the shared logout list. An upgrade over revisions 1 to 5 runs after the revision 2 and revision 5 repairs: it removes `_unavailable` from every database, brings the plan of every scope of every database to layout 2 (read kinds and default kinds recomputed from what the plan kept, and no fast checks, since revision 5 kept no description: writes through such a plan run SchemaKit's check, as they did), and walks `state.views` once, parents first, giving every live node the layout 2 fields and removing the ones that moved. A probe key a node recorded as set is kept, so the next write still clears it; `verified` starts over. Every node is recomputed, whatever its layout, because the revision 2 repair may just have changed its defaults, from which its read kinds follow. Old nodes keep their 32-slot tables; nodes built afterwards are smaller. The package state gains an empty `logoutDatabases`. A spec leaves a database, its scope plan, every node, its signals and the package state in the revision 5 shape (with a wrong `displayPath` and a stale probe key), reloads, and checks the layouts, reads, writes through the full check and the fast path, listeners connected before the upgrade, `Validate`, the undeclared-scope message, profile signals, and that the old database (with its own logout listener) and one opened afterwards (on the shared list) are each compacted once.

Revision 7 added database layout 4 (`_generation`) and node layout 3 (`cache` and `generation`; `kind`, `depth` and the root's `dead` derived instead), the `Resync` and `Getter` methods and `dispatch.readView`. An upgrade over revisions 1 to 6 runs after the revision 6 upgrade (which reads `kind` and sets `depth` on older nodes, and derives the kind from `kinds` on a node that has no `kind`): it gives every database `_generation = 0` and walks `state.views` once, giving every node an empty cache and `NEVER_RESOLVED`, or `DETACHED` for a root that was `dead`, and removing `kind`, `depth` and `dead`. `Caching_spec.lua` leaves a database and every node in the revision 6 shape, including a detached profile root and a nested view below it, reloads, and checks the layouts, reads, the detached views, structural writes, a getter and `Resync`; `Getter_spec.lua` checks that getters made before an upgrade keep working. With the new main-chunk locals the file keeps four locals of headroom under Lua 5.1's 200 (revision 6 had three): the dependency lookups and the upgrade loops moved into blocks and functions.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass `3` to helpers they call directly and raise their own errors at `2`. The functions behind the view metatable are called by the writing or reading line, so `viewNewIndex` passes through to `writeView`, which raises at `3`, `viewIndex` raises a secret read key through `raiseSecretRead` at `3`, and `databaseIndex` and `databaseNewIndex` raise at `2`. Lua 5.1 refuses a `nil` or NaN key while looking for the slot, before any metamethod runs, so those never reach SettingsKit.
