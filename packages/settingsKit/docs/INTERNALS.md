# SettingsKit Internals

This document describes the private layout behind SettingsKit API generation 1: the saved table SettingsKit writes, the view design behind `db.<scope>`, and the package state. Only the saved-table layout is visible to players (it is what lands in `WTF/.../SavedVariables/MyAddon.lua`), and since 0.3.2 that layout is the one part that is a public contract for code: [`API.md`](API.md#the-saved-table) states it. Everything else here is private.

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
  race = { Scourge = { ... } },                   -- db.race, only when declared (revision 15)
  namespaces = {                                  -- the Namespaces part (revision 15)
    Bars = { profiles = { Default = { ... } }, char = { ... } },
  },
}
```

| Section | Keyed by | Written when |
|---|---|---|
| `version` | — | A new table is stamped at `Open`; each migration step advances it. Never lowered: a newer stored version stays, also through `ResetDatabase` under `allowNewerData`. |
| `global` | — | A write through `db.global`. |
| `profiles` | profile name | `Open` and `SetProfile` create the current profile's table; writes through `db.profile` fill it. |
| `profileKeys` | `"<name> - <realm>"` | `SetProfile` records the character's choice; `DeleteProfile` removes choices naming the deleted profile. |
| `char`, `realm`, `class`, `faction` | the scope key read at `Open` | The first write through that scope creates the entry. |
| `race`, `factionrealm`, `factionrealmregion`, `locale` | the scope key read at `Open`, AceDB-3.0's | Revision 15. `Open` creates the section only when the schema declares the scope, and checks it only then; the first write through the scope creates the entry. |
| `namespaces` | namespace name | Revision 15, by the Namespaces part: `RegisterNamespace` creates `namespaces[name]`, the sections of the scopes the namespace declares and its current profile's table (writable databases only); the parent's profile operations change it (see [Namespaces](#namespaces)); logout removes empty profiles, sections and namespace tables inside it. Without the part SettingsKit writes nothing here. |
| `specProfiles` | `"<name> - <realm>"` | Revision 11. `SetSpecProfile` writes the character's entry `{ [index] = profileName }` and removes it with its last assignment; `DeleteProfile` removes assignments naming the deleted profile; `ResetDatabase` recreates it empty. A database an older revision opened gets the section at its first `SetSpecProfile`. |

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
| `viewMetatable` | The metatable every view shared before revision 14: `__index`, `__newindex`, `__metatable = "SettingsKit.View"`. Kept, with this revision's functions, for a view an upgrade missed. |
| `chains` | Revision 14: node to its view's own metatable (see [Read-through chains](#read-through-chains)). Weak in keys and values, so neither keeps the other alive; the metatable lives as long as its proxy. |
| `pendingRoots` | Revision 14: a scope root's proxy not built yet, to its database (see [Views built on first use](#views-built-on-first-use)). Weak-keyed. |
| `pendingChildren` | Revision 14: a record field's proxy not built yet, to its parent node. Weak-keyed. |
| `entryOwners` | Revision 14: a keyed section's entry cache to its node, for the cache's `__index`. Weak in keys and values. |
| `planShapes` | Revision 14: a plan to the chain shape every view reading the plan's own defaults shares. Weak-keyed. |
| `pendingMetatable` | Revision 14: the metatable of every proxy not built yet: `__index` and `__newindex` build the view first, `__metatable = "SettingsKit.View"`. |
| `entryCacheMetatable` | Revision 14: the metatable of every keyed section's entry cache: weak values, and an `__index` that reads a missing entry through `readNode`, which builds and caches its view. |
| `databaseMetatable` | The one metatable of every database: `__index` (methods, and the unavailable-scope error), `__newindex` (refuse). |
| `unbounded` | The `SettingsKit.UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `limits` | The shared limits `SetLimits` writes: `maxProfileNameLength` and `pathKeyLimit`. |
| `logoutDatabases` | Revision 6: the databases the shared `PLAYER_LOGOUT` listener compacts, in the order they were opened. An upgrade over an older revision adds it empty. |
| `logoutConnected` | Revision 6: whether the shared listener is connected to EventKit. |
| `specListenerConnected` | Revision 11: whether the one shared spec listener is connected to EventKit. An upgrade over an older revision adds it `false`. |
| `parts` | Revision 15: the state of each loaded part by name (decision 0001); the Namespaces part keeps `{ revision = 1 }` there, and a copy of the part returns at once when an equal or newer revision is installed. |
| `helpers` | Revision 15: the core functions the parts call (schema checks, scope keys, view building, compaction, signals). Every revision fills it at load, and a part reads it at call time, so an upgraded core serves parts loaded before it. |
| `createdProfiles` | Revision 15: weak-keyed database to the profile created this session (a name) or, once there is a second, a set of names; `db:IsNewProfile()` reads it. Kept here, not on the database, so a database keeps its hash size. |

## Databases

A database is a table carrying its views as plain fields (`global`, `char`, ..., `profile`), so reading `db.profile` is a raw field read with no metamethod, and private fields prefixed with `_`:

| Field | Purpose |
|---|---|
| `_layout` | Database layout number (`4`). Layout 1 (revisions 1 to 4) had no `_newerVersion` and `_readOnly`; layout 2 (revision 5) had `_unavailable`, the messages of reading an undeclared or unavailable scope, which `databaseIndex` now builds when such a scope is read; layout 3 (revision 6) had no `_generation`. |
| `_name` | The saved-variable name; for a namespace, `"<saved variable> namespace <name>"`, which every message shows. |
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
| `_maxScannedEntries` | `options.maxScannedEntries`: how many entries the scan of a written table visits before refusing it (65536 by default), or `math.huge` when opened with `SettingsKit.UNBOUNDED`. |
| `_signals` | The profile and lifecycle signals (`profileChanged`, `profileCopied`, `profileReset`, `profileDeleted`, and from revision 15 `newProfile`, `profileShutdown`, `databaseShutdown`, `databaseReset`), each created by the first call that connects to it; a signal nobody connected to is absent and not fired. From revision 14 the table itself is created by that first call too, so a database with two scopes and no listener keeps to 16 fields (a 16-slot table instead of 32). |
| `_buildProfileAtOnce` | Revision 14, set on databases an older revision opened when it upgrades them: `publishProfileView` then builds the new profile view at once, because a getter such a revision made reads the node behind `db.profile`. |
| `_specIndex` | Revision 11, absent until set: the spec index whose assignment the database last applied (at `Open`, `SetSpecProfile`, `ApplySpecProfile` or a spec event), or, from revision 12, the index of the last spec event while its character had no assignment. A spec event skips a database that already applied the event's index, so an event that changes nothing never undoes a manual `SetProfile`. Absent reads as `nil`, so no layout number changed. |
| `_maxNamespaces` | Revision 15, only when `Open` got `maxNamespaces`: the bound of `RegisterNamespace` (`math.huge` for `SettingsKit.UNBOUNDED`). Absent means 256. |
| `_namespaces` | Revision 15, set by the Namespaces part's first `RegisterNamespace`: one table holding the namespaces in registration order (`[1]` to `[n]`) and by name. The core's profile methods hand their phases to the part only for a database holding it. |
| `_parent`, `_namespaceName` | Revision 15, only on a namespace: its parent database and its name. The core's profile methods refuse a database with `_parent` (see [Namespaces](#namespaces)). |
| `_generation` | Revision 7: a counter every SettingsKit mutation that can change which saved table a view resolves to increments (`bumpGeneration`); a node's cached table is current while the node's `generation` equals it (see [Resolution](#resolution)). |

A scope record holds the scope's `name`, SettingsKit's sealed `schema` (shared by every database opened with the same schema node, see [Plans](#plans)), its compiled `plan`, the `sectionName` and `sectionKey` of its saved table, whether it is `available`, and its `OnChange` `signal`: `false` until the first `OnChange` of the scope creates it, so a write nobody listens to fires nothing. An undeclared scope has no record.

A missing scope field falls through to the metatable's `__index`, which looks for a method on the `Database` prototype and otherwise, for a scope name, raises at the reading line the message for a scope without a record (not declared) or with `available = false`, built from the saved-variable name at that moment.

## Namespaces

A namespace is a database table built by the Namespaces part (`src/parts/SettingsKit-Namespaces.lua`) with the private fields above and the one database metatable, so every view, write, signal and compaction path serves it unchanged. Its `_raw` is `namespaces[name]` of the parent's saved table (a table of its own, never stored, for a read-only parent with nothing saved there), its `_profile` follows the parent's, and it never joins `state.databases` or the logout list: its parent reaches it.

The core calls `state.dispatch.namespaces(db, phase, ...)` through `DatabaseHelpers.cascade` only for a database holding `_namespaces` (or, for `resync`, being a namespace). A database without namespaces pays one or two `rawget`s per profile operation and nothing on reads or writes. The phases, in the order a profile method runs them:

| Phase | Called by | What the part does |
|---|---|---|
| `checkCopy` | `CopyProfile`, before any change | Answers a refusal when a namespace's `profiles[from]`, registered or not, nests deeper than SchemaKit's `maxDepth`; the core raises it at the caller's line. |
| `shutdown` | `SetProfile`, before any change, after the parent's `OnProfileShutdown` | Fires each namespace's `OnProfileShutdown`, in registration order. |
| `setProfile`, `copyProfile`, `resetProfile`, `deleteProfile`, `resetDatabase` | the method of that name, after the parent changed and before the parent's signals | Changes every namespace (no user code runs in between), applies the raw part of a copy, reset or delete to the namespaces nobody registered this session, then fires the namespaces' signals, signal by signal, each over every namespace in registration order. |
| `compact` | `compactDatabase` | Compacts every namespace and answers the count. |
| `shutdownDatabase`, `logout` | `compactOnLogout` | Fires each namespace's `OnDatabaseShutdown` (each under `pcall`, failures reported); after compaction removes empty profiles, sections and namespace tables inside `namespaces`. |
| `resync` | `Resync` | Finds each namespace's saved table again (or a namespace's own, on its `Resync`). |

A namespace's views of a deleted profile are detached exactly as the parent's are. After `ResetDatabase` each namespace gets a new saved table in the new `namespaces` section, its profile roots are detached and `child.profile` is published again.

Upgrades: the part keeps no copies of core functions (it reads `state.helpers` at call time) and its children use the shared prototype and metatable, so a newer core revision loaded in place keeps cascading to namespaces registered before it (`Namespaces_spec.lua`, "keeps cascading after a later core revision upgrades in place").

## Plans

`Open` seals each scope schema and describes it once (`schema:Describe()`), and compiles the description into a plan tree. A plan node records:

| Field | Meaning |
|---|---|
| `layout` | Plan layout number (`3`, revision 16; `2` for plans revisions 6 to 15 compiled). Plans revision 5 compiled have none, and get the fields below from an upgrade. Layout 3 holds only the fields a plan uses (absent instead of `false`), and a fast check only `kind` and the bounds the field declares; every reader tests them for truth, so it reads both layouts. |
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

**Plain defaults** (revision 16, the Defaults part). `compileScope` hands a scope that is not a SchemaKit node or schema to `state.dispatch.compileDefaults(defaults, scopeName, level, label)`, which the part installs (the core's default raises the not-loaded message). The part answers two things: the description `schema:Describe()` would give for the schema AddonKit's inference builds from those defaults, which `compilePlan` compiles unchanged, and a checker object (metatable `state.defaultsCheckerMetatable`, whose `__index` the newest part sets) that takes the sealed schema's place in `scope.schema`. Its `Check(value)` walks the description itself, with SchemaKit's rules, failure shape and wording for the kinds the inference produces (closed records, bags and keyed sections with the `string of at most 256 characters or number` key rule, arrays, scalars, `any`), and hands a SchemaKit leaf's subtree to the leaf's own sealed `Check` (`leaves[description]`), prefixing the leaf's path. It reuses one failure table and one segment stack per checker, so a valid check allocates nothing. Defaults compile through the same `compiledScopes` cache, keyed by the defaults table.

**SchemaKit is optional** (revision 16). `findSchemaKit` asks `Registry:Find("schemaKit", 1)` until it answers, and keeps the facade (Registry hands out one per session). `readMaxDepth` reads `SchemaKit:GetLimit("maxDepth")`, or `DEFAULT_MAX_DEPTH` (16) without SchemaKit or with one older than revision 6. `depthAllows`, the write fast path's depth test, compares with `GetLimit`, with 16 without SchemaKit, and answers "not known" (`false`, so the full check runs) for a SchemaKit without `GetLimit`; the sealed depth probes revisions 6 to 15 built for that case are gone.

**Compiled once per schema.** `compileScope` keeps what it built for a scope schema in `compiledScopes`, a file-local weak-keyed table keyed by the schema node or sealed schema `Open` received: the seal and the plan, with SchemaKit's `maxDepth` and revision at the time. A node is immutable from birth, so a later `Open` with the same node, under the same `maxDepth` and SchemaKit revision, reuses both and skips `Seal`, `Describe` and the compilation. The seal is shared only between SettingsKit's databases, never with the consumer, so a write still cannot overwrite the failure of a check the consumer runs. The cache is per copy: an upgraded copy compiles its own.

## Views

### Why the proxy is empty

Lua 5.1 calls `__newindex` only when the key is absent from the table being written. A view that stored the saved values itself would stop seeing writes to every key it held, so validation would silently stop after the first write of each field. Every view is therefore an **empty** table with the shared view metatable, and the saved data lives behind it.

### Nodes

Each proxy maps, through `state.views`, to a node. A node has at most 16 fields, so Lua 5.1 gives it a 16-slot table instead of a 32-slot one: what only a scope root needs lives on the root, reached through `root`, and nothing derivable is stored.

| Field | On | Meaning |
|---|---|---|
| `layout` | every node | Node layout number (`4`). Layout 4 (revision 14) is layout 3 with `probe` built on the first full check (`false` until then) and a view metatable of its own in `state.chains`. Layout 1 (revisions 1 to 5) carried `db`, `scope`, `sectionName`, `dead` and `sectionKey` on every node, a `displayPath`, a `probeSet` flag and a map's entry cache in `entries`, and none of `depth`, `pathKeys`, `kinds`, `ownEntries`, `valuesProxied` and `verified`. Layout 2 (revision 6) carried `kind` (`"record"` or `"map"`), `depth` below a root and `dead` on a root, and no `cache` or `generation`. |
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
| `probe`, `probeKey` | every node | The scratch table this view contributes to a write's probe (`false` until the first full check builds it, revision 14), and the one key set in it, or the file-local `NO_PROBE_KEY` when none is. |
| `children` | every node | Record: field name to child view, a proxy for each built with the record and built itself on first use. Map: key to entry view, weak-valued, built on first access, carrying `entryCacheMetatable`. |

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

A table with a foreign metatable (a direct edit) is returned by `refreshContainer` but never cached, so every access to it walks again and uses `rawget`; a table with the metatable SettingsKit gave it (`SAVED_MARK`) is cached like one without. Every read of a saved table uses `rawget` (revision 14). A detached root keeps its `DETACHED` generation, so it never serves a cached table, its walk answers `nil`, and a stale view reads defaults and cannot resurrect a deleted profile; the views below it cache `false`.

A node's 16-field budget is kept by deriving what revision 6 stored: the kind of view from `kinds`, the depth from `pathKeys`, and a root's detached state from its `generation`. The database gained `_generation` as its fifteenth private field; with two scope views it has 17 fields and a 32-slot table (640 bytes more per database).

Views are built recursively down to SchemaKit's `maxDepth` limit (16 by default) as it stood when the database was opened, the deepest value SchemaKit follows; scans, comparisons and `CopyProfile` read the limit again each time they start (`readMaxDepth`, through `SchemaKit:GetLimit`, which allocates nothing, or `GetLimits` with an older SchemaKit), so `SchemaKit:SetLimits{ maxDepth }` reaches them without reopening; a record or map below that is read as a plain value. Views are built on first use (see [Views built on first use](#views-built-on-first-use)); keyed-section entry views on the first read of each key.

### Read-through chains

Revision 14 answers a read without a SettingsKit call. Each view has a metatable of its own (`state.chains[node]`), and its `__index` is a table:

```
proxy (empty: every write reaches __newindex)
  -> shadow          the views of record fields, for a record that has any
  -> saved table     given a metatable marked SAVED_MARK ("__settingsKitSaved")
  -> scalar defaults the view's defaults that are not tables
```

The view's metatable holds the chain too: `shape` (the scalar defaults, the saved-table metatable whose `__index` they are, the plain-table default keys and the optional record keys) and `shadow`. A view reading its plan's own defaults shares its plan's shape (`state.planShapes`); one with other defaults (a keyed-section entry with its own default) builds its own. Fields with a default always answer with their view from the shadow; an optional record field (no default) is in the shadow only while its saved value is a table.

A keyed section whose values are records or keyed sections and which has a wildcard default answers every key with an entry view, so its chain is its entry cache: a cached entry answers at once, a missing one reaches `entryCacheIndex`, which calls `readNode` (building and caching the view). A keyed section of plain values reads through its saved table to a table of its own default entries, which answers the wildcard (a scalar) through a small function. Every other keyed section reads through `viewIndex`.

The function path, `viewIndex` → `readNode`, remains for what a chain would answer wrongly:

- a saved table with a metatable SettingsKit did not give it;
- an optional record field stored as something other than a table (it must read `nil`);
- a record with a plain-table default (`READ_COPY`) not stored yet. A copy must be stored by its first read, and a direct read of the saved table must never store one, so the saved table's metatable cannot answer it. Once every such default is stored (`materialise` rebinds), the view reads through its chain. While nothing is saved for the view at all, it reads through a tail of its own (`copyTail`: its scalar defaults, then `readNode`), so only the plain-table defaults cost a call; an unsaved keyed-section entry is the common case.

`readNode` is the revision 13 read without the secret probe: the client refuses a secret key at the reading line before any `__index` runs (core decision 19b, `docs/EMBEDDING.md`), so no secret key reaches it. It reads saved tables with `rawget`, since a cached table may carry SettingsKit's metatable.

**Rebinding.** The generation scheme is lazy and robust against a mutation that raises halfway; chains are eager, so every mutation rebinds what it changed after it mutated, never before (binding before a removal would point a chain at the table about to be detached):

| Mutation | Rebinds |
|---|---|
| a write that bumped the generation (`storeWrite`): a table stored or replaced, tables created on the way | `Chain.rebindPath`: every view from the scope root to the written one, then the subtree of the written key's view |
| `materialise` storing a copy | the same path when it created tables, else the view alone |
| `SetProfile` that created a profile table, `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase`, `Resync` | `Chain.rebindDatabase`: every built view of every scope root and every profile root the database keeps |
| `Compact`, at logout too | the same, after the compaction, also when it raised halfway (the compaction runs in a `pcall`, the error is raised again after the rebind) |
| detaching a profile root | its subtree, to read defaults, since the database stops keeping the root |

Binding a view resolves its saved table (the generation cache), gives the table the view's saved metatable when it has none or another of SettingsKit's, and points the view's `__index`, and its shadow's, at what it reads now. It allocates nothing.

**Upgrades.** Revision 13 views shared `viewMetatable`, which is protected by `__metatable`. That metatable is SettingsKit's own table, so `Chain.setProxyMetatable` clears its `__metatable` field, sets the proxy's new metatable and puts the field back; every view's own metatable is protected and swapped the same way. The upgrade from revision 13 gives every live view its metatable and chain and moves every entry cache to `entryCacheMetatable`; an upgrade from revision 14 on gives each view's metatable the newer file's `__newindex` and rebinds it, since the functions are file locals.

### Views built on first use

`Open` gives each available scope a proxy with `pendingMetatable` and nothing behind it, kept in `state.pendingRoots` with its database; the scope is found again from the database field holding the proxy, or from the profile name `_profileRoots` keeps it under (a profile root in neither was detached before it was built). Building a record view gives each record field a pending proxy, kept in `state.pendingChildren` with its parent node; the key is found again in the parent's `children`. The first read or write through a pending proxy builds its node and chain (`Chain.completeView`) and swaps its metatable, so the proxy is the view from the start: `db.profile` is a raw field of the database (an older OptionsKit reads scopes with `rawget`), and a field view keeps its identity. Every SettingsKit function that takes a view goes through `nodeOf`, which builds a pending one. A keyed-section entry's view is built when it is first read, as before. The probe table of a view is built by its first full check.

### Getters

`db:Getter(source, key)` probes the key once and returns `function() return proxy[key] end`, or `function() return db[scope][key] end` for a scope, `db.<scope>` being a raw field of the database that only `SetProfile` and `ResetDatabase` change. A call is one Lua call plus a view read, so it is never faster than reading the view; it reads through the view, so it keeps every guarantee of a view read and works across every later revision.

Getters made by revisions 7 to 13 keep their closures: they read `node.generation`, `node.cache` and `db._generation`, whose meaning revision 14 keeps, and on their slow path call `dispatch.readView`, which is `viewIndex`. A cached table may now carry SettingsKit's metatable, so their plain read of a missing key answers the scalar default instead of `nil`; they then return it, which is the answer they would have computed. A plain-table default is never answered by that metatable, so their copy path is unchanged. A scope getter such a revision made reads `views[db.profile]`, so a database an older revision opened builds each new profile view at once (`_buildProfileAtOnce`).

**The nil-rule exception (revision 8)** applied to `plainGetter`, which revision 14 no longer has; the closures revisions 8 to 13 made still use it.

A saved value that is not a table under a record or map plan (hand-edited or corrupted data) reads as absent: the read falls through to the default, so the child view stays usable, `refreshContainer` already skips a non-table on the way down, and `resolveForWrite` replaces it on the next write.

A saved value, a key from the caller's path and a default from the caller's schema did not originate in SettingsKit, so their absence is tested with `type(value) == "nil"`, the repository rule, which never compares anything.

### Iteration

`db:Pairs(view)` returns the file-local `pairsNext`, the view and `nil`. `pairsNext` is stateless: phase one walks `node.defaults` (a record's field defaults or a keyed section's own default entries), phase two walks the resolved saved table and skips keys that have a default. The previous key tells the phases apart, because a key with a default always belongs to phase one. A phase-one read may store a plain-table default, which only adds a key phase two skips, so the saved table never changes while phase two walks it.

### A write

`viewNewIndex` takes the **fused write** (revision 14) when the value is not a table and the view is a `verified` record view: `fusedWrite` runs, for that case, exactly the checks below in the same order (read-only and detached database, the secret probe of key and value before the key indexes anything, the field's fast check, the depth limit read through `SchemaKit:GetLimit` without allocating, the bound of any keyed section above) and stores through `storeWrite`; the moment one check would refuse, it answers `false` and `writeView` runs them again to raise the refusal with its message. Otherwise `viewNewIndex` → `writeView`:

1. Refuse on a read-only database (`_readOnly`), then on a detached root.
2. Refuse a secret key, then a secret value, then a table value that contains a secret, is or contains a view (`state.views` lookup), or is or contains a table with a metatable (`scanValue`, bounded by SchemaKit's `maxDepth` read when the write starts and the database's `_maxScannedEntries`, 65536 by default and `math.huge` when opened with `SettingsKit.UNBOUNDED`). The scan runs on every client: a view stored in a saved table would be a non-empty proxy, so later writes to its keys would skip `__newindex` and validation, and it would alias the other view's data on disk.
3. **Schema check** (`checkWrite`), on the fast path or by the full probe check:
   - **Full probe check.** Each view from the written one up to the root sets its key in its parent's probe to its own probe, the written view sets `key = value` in its probe, and the scope's sealed schema checks the root probe. The probe holds exactly the path to the written value, and every other field of every record on the path is optional (`compilePlan` guarantees it), so the check passes exactly when the value is valid where it is written. The probes are cleared again before any error is raised. A valid check allocates nothing; the reported path is SchemaKit's own, relative to the scope, and the message is built only on failure. When it passes, the view is marked `verified`.
   - **Fast path.** A value that is not a table, written to a record view that is `verified`, under a field with a fast check, is accepted without asking SchemaKit when the value passes the field's own rules (`passesFastCheck`) and the chain is within SchemaKit's `maxDepth` (`depthAllows`). That is exactly when the full check would pass: the full check of such a write depends on the value's rules, on the keys of the chain (declared fields, keyed-section keys the key schema accepts, sections whose `max` allows one entry), which cannot change for a view once a full check through it passed, and on the chain's depth. The fast check reproduces SchemaKit's rules for `string` (type, `oneOf`, length, pattern), `number` (type, NaN, `integer` with infinities, bounds), `boolean` and `enum` exactly as `Describe` states them, and a field described with anything else gets none, so a rule a later SchemaKit adds is never skipped. SchemaKit's `maxDepth` can change at any time; `depthAllows` reads it through `SchemaKit:GetLimit` (SchemaKit revision 6), which allocates nothing. With an older SchemaKit, whose `GetLimits` allocates, `depthAllows` answers "not known" and the write takes the full check (revision 16; revisions 6 to 15 checked a sealed depth probe instead); without SchemaKit it compares with 16. A root needs none, since `maxDepth` is at least 1. Anything else, and every value the fast path refuses, goes to the full check, so every refusal and its message still come from SchemaKit. `FastPaths_spec.lua` writes every candidate value to every kind of scalar field, at the top, in a nested record and in an entry, before and after the view is verified, and requires SchemaKit's verdict and message each time.
4. Refuse a write that would add an entry to a keyed section already holding `max` entries (the probe holds one entry, so the bound is counted against the saved table, stopping at `max`).
5. Store with `rawset` into the resolved (or created) table, bumping the generation when the value stored or the value replaced is a table, then rebind the chains the store changed (`storeWrite`).
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

`compactRecord`, `compactMap` and `compactValue` walk a saved table together with its plan and defaults. A value deeply equal to its default is removed (`deepEqual` treats a secret as unequal to everything and stops at SchemaKit's `maxDepth`, read when the compaction starts). A record or map table is compacted first and then removed when it is empty and has a default to fall back to. The walk follows the plan, which `compilePlan` stops at the `maxDepth` in force at `Open`, so it carries no depth counter of its own; keys the plan does not declare are never visited, so undeclared data survives. `compactScope` walks every entry of a section, removes empty entries of the keyed scopes (character, realm, class, faction and, from revision 15, race, faction-realm, faction-realm-region and locale), and keeps empty profiles. At logout, the one shared listener calls `dispatch.compactAllOnLogout()`, which calls `compactOnLogout(db)` for every database on `state.logoutDatabases`, in the order they were opened; `compactOnLogout` fires the database's `OnDatabaseShutdown` and its namespaces' (revision 15), then skips a read-only database, runs `compactDatabase` under `pcall`, then the namespace cleanup, and reports every failure through `geterrorhandler()`, so one database's failure never stops another's shutdown or compaction.

## Closures and upgrades

SettingsKit hands out no closure per database; the only closures it hands out are the getters a consumer asks for (see [Getters](#getters)). The first database opened while EventKit is registered connects the one shared `PLAYER_LOGOUT` listener, a file-local function that calls through `state.dispatch`, and sets `state.logoutConnected`; every database opened while EventKit is registered joins `state.logoutDatabases`. The connection EventKit returns is not kept: databases live for the session and are never disconnected. Revisions 1 to 5 connected one listener per database, calling `dispatch.compactOnLogout(db)`; those keep working after an upgrade, and their databases are not on the shared list, so none is compacted twice. Views and databases get their behaviour from the two metatables in `_state` and the `Database` prototype, which a newer revision rewrites in place. Databases, nodes and plans carry layout numbers so a revision that changes a layout can upgrade them lazily. The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised by one and checks that a database opened before the upgrade, its views, its `OnChange` and profile listeners and its logout compaction keep working.

Revision 1 gave an entry view of a keyed section declared without a default `false` for its `defaults`, and handed that `false` down to the record views below it, so a saved entry read `nil` where the wildcard or a field default applied. Revision 2 builds every node's `defaults` through `viewDefaults`, and an upgrade over revision 1 walks `state.views` once and recomputes the `defaults` of every live node, parents first; a node revision 1 built correctly gets the same table back. A spec leaves two nodes in the revision 1 shape, reloads, and checks that they read their defaults.

Revision 5 added database layout 2 (`_newerVersion`, `_readOnly`) and the `IsReadOnly` method. An upgrade over revisions 1 to 4 walks `state.databases` once and brings every layout 1 database to layout 2: `_readOnly` is `false`, because the database was opened writable and an addon may already be writing through it, and `_newerVersion` is read from the saved table's current `version` when that is an integer above the database's `_version`, so `ResetDatabase` never lowers it. A spec leaves two databases and the prototype in the revision 4 shape, reloads, and checks the fields, the writes, `ResetDatabase` and that a database opened afterwards is read-only over newer data.

Revision 6 added node layout 2, plan layout 2 and database layout 3 (see the tables above) and the shared logout list. An upgrade over revisions 1 to 5 runs after the revision 2 and revision 5 repairs: it removes `_unavailable` from every database, brings the plan of every scope of every database to layout 2 (read kinds and default kinds recomputed from what the plan kept, and no fast checks, since revision 5 kept no description: writes through such a plan run SchemaKit's check, as they did), and walks `state.views` once, parents first, giving every live node the layout 2 fields and removing the ones that moved. A probe key a node recorded as set is kept, so the next write still clears it; `verified` starts over. Every node is recomputed, whatever its layout, because the revision 2 repair may just have changed its defaults, from which its read kinds follow. Old nodes keep their 32-slot tables; nodes built afterwards are smaller. The package state gains an empty `logoutDatabases`. A spec leaves a database, its scope plan, every node, its signals and the package state in the revision 5 shape (with a wrong `displayPath` and a stale probe key), reloads, and checks the layouts, reads, writes through the full check and the fast path, listeners connected before the upgrade, `Validate`, the undeclared-scope message, profile signals, and that the old database (with its own logout listener) and one opened afterwards (on the shared list) are each compacted once.

Revision 7 added database layout 4 (`_generation`) and node layout 3 (`cache` and `generation`; `kind`, `depth` and the root's `dead` derived instead), the `Resync` and `Getter` methods and `dispatch.readView`. An upgrade over revisions 1 to 6 runs after the revision 6 upgrade (which reads `kind` and sets `depth` on older nodes, and derives the kind from `kinds` on a node that has no `kind`): it gives every database `_generation = 0` and walks `state.views` once, giving every node an empty cache and `NEVER_RESOLVED`, or `DETACHED` for a root that was `dead`, and removing `kind`, `depth` and `dead`. `Caching_spec.lua` leaves a database and every node in the revision 6 shape, including a detached profile root and a nested view below it, reloads, and checks the layouts, reads, the detached views, structural writes, a getter and `Resync`; `Getter_spec.lua` checks that getters made before an upgrade keep working. With the new main-chunk locals the file keeps four locals of headroom under Lua 5.1's 200 (revision 6 had three): the dependency lookups and the upgrade loops moved into blocks and functions.

Revision 8 changes no layout: only the closure `plainGetter` returns (see [The nil-rule exception](#getters)). Getters revision 7 made keep their own closure, which reads the same fields, and keep working; `Getter_spec.lua` makes getters under revision 7, upgrades in place and checks them and a getter made afterwards.

Revision 9 changes no layout. Every in-place upgrade, from any revision, walks `state.views` once and builds the depth probe of every live record view below a scope root: `depthProbes` is file-local, so a newer copy starts without the probes the older one built, and before revision 9 only an upgrade over revisions 1 to 5 rebuilt them, which sent writes through nested views to the full check after an upgrade over revisions 6 to 8. `FastPaths_spec.lua` upgrades in place and counts SchemaKit checks of nested writes.

Revision 15 changes no node, plan or database layout number: every field it adds to a database is absent unless used (`_maxNamespaces`, `_namespaces`, `_parent`, `_namespaceName`). The scope tables are one `Scopes` table (names, sections, the set, the added scopes, the region names and the unavailable reasons), which frees three main-chunk locals; the added scopes come last in `Scopes.names`, and the walks over a schema stop once they have seen every scope it declares, so a schema of the original six costs no more than before. The keys of the added scopes are read only for a schema that declares them (`Scopes.readAddedKeys`). The helpers of the methods revision 15 added live in the `DatabaseHelpers` table. An upgrade over revision 14 adds `state.parts`, `state.helpers` and `state.createdProfiles`; databases revision 14 opened gain the new methods through the prototype and answer `IsNewProfile() == false` for the profile their `Open` created. `Bootstrap_spec.lua` removes the three tables after loading revision 14, reloads, and checks the signals and a namespace on the old database.

Revision 16 adds plan layout 3 (sparse plans and fast checks), moves spec profiles into the SpecProfiles part and adds the Defaults part. It changes no database or node layout. Plans revision 15 compiled stay on their databases and are read by the truthiness tests; `depthProbes` built by revision 15 go with that copy's file-local table. The helpers the parts call are `state.helpers`, rewritten by every revision; the dispatch entries a part installs (`compileDefaults`, `onSpecEvent`, `onDatabaseOpened`, `namespaces`) are never overwritten by a core revision while the part is loaded. The shared helper blocks (`isSecret`, `reportError`, `describeKey`, `validateFacade`, `limits`, from `tooling/shared/lua/`) replace the hand-written copies; `readIsSecret` stays for the hot paths that pass a probe along. `LIMIT_RULES` replaces the four limit tables, so the main chunk stays at 193 locals.

Revision 13 changes no layout: an unknown `SetLimits` key that is not a string, number or boolean is named by its type instead of being passed to `tostring`, and an upgrade over revision 12 replaces the methods only. `Limits_spec.lua` checks it.

## Spec profiles

Spec profiles are the SpecProfiles part (`parts/SettingsKit-SpecProfiles.lua`, revision 16; inside the core in revisions 11 to 15). The part publishes `GetSpecIndex` on the facade, `SetSpecProfile`, `GetSpecProfile` and `ApplySpecProfile` on the prototype, and two dispatch entries: `onDatabaseOpened(db)`, which `Open` calls last, and `onSpecEvent()`, which the shared listener calls, so the listener any revision connected calls the newest entry. The core keeps what keeps the saved table right without the part: the `specProfiles` layout section, `ResetDatabase` emptying it, and `DatabaseHelpers.forgetSpecProfiles(raw, name)`, which `DeleteProfile` calls. Without the part the core installs stubs for the four members and no-op entries; after an upgrade from revision 15 it keeps revision 15's members and entries instead (`state.legacySpecProfiles`), which the part drops when it loads. An upgrade from revision 10 or earlier sets `state.specProfilesCatchUp`, and the part applies those databases' assignments once when it loads. The part connects the listener only when EventKit can deliver unit events: `EventKit:HasPart("Units")`, or, for an EventKit before revision 23 (unit events in its core), `ConnectUnit` on the facade.

`readSpecIndex` decides the kind from `WOW_PROJECT_ID` (`1` and `19`, the literals ClientKit uses, mean specialization), asks `C_SpecializationInfo.IsInitialized`, and then reads either the specialization (refused above the class's count, which is Retail's starter specialization) or the active talent group (refused above 8). Every answer is tested with `issecretvalue` before it is compared. The facts behind these choices (which functions and events each flavour documents, and why Classic Era keys by talent group: there `GetSpecialization` stands for the primary talent tree, which moves with talent points) are in `docs/ROADMAP.md`, "settingsKit spec profiles".

The shared listener is connected the first time a database has an assignment; `state.specListenerConnected` records it, and the connections EventKit returns are not kept, as for the logout listener. `onSpecEvent` reads the index once and walks `state.databases`, applying it to each database with an assignment whose `_specIndex` differs, and writing it into the `_specIndex` of each database without one (revision 12: an index kept from before the last assignment was cleared would otherwise match the index the character comes back to, and an assignment made meanwhile would never apply). The walk only collects the databases to switch, into an array allocated when there is at least one, and the switches run over that array afterwards, each checked again (revision 12): a switch runs profile listeners, which may open databases, and adding a key to `state.databases` during a `next` walk is undefined in Lua 5.1. A database opened meanwhile applied its assignment at `Open`. Applying calls the prototype's `SetProfile`, so the switch is exactly a `SetProfile`. After an upgrade over revision 10 or earlier the part runs `onDatabaseOpened` once for every open database (`state.specProfilesCatchUp`), which connects the listener and applies the assignment for a character whose saved table already holds one. An upgrade over revision 11 or later does not: those databases applied their assignment at `Open`, and applying it again would undo a manual `SetProfile` whenever a newer copy loads in the middle of the session (the revision 12 fix).

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass `3` to helpers they call directly and raise their own errors at `2`. The functions behind the view metatable are called by the writing or reading line, so `viewNewIndex` passes through to `writeView`, which raises at `3`, `viewIndex` raises a secret read key through `raiseSecretRead` at `3`, and `databaseIndex` and `databaseNewIndex` raise at `2`. Lua 5.1 refuses a `nil` or NaN key while looking for the slot, before any metamethod runs, so those never reach SettingsKit.

Revision 14 adds the read-through chains, views built on first use, lazy probe tables and the fused write (node layout 4, see [Read-through chains](#read-through-chains)). Revision 16 removed the depth probes (see [Plans](#plans)).
