# SettingsKit Internals

This document describes the private layout behind SettingsKit API generation 1: the saved table SettingsKit writes, the view design behind `db.<scope>`, and the package state. Only the saved-table layout is visible to players (it is what lands in `WTF/.../SavedVariables/MyAddon.lua`); none of it is a public contract for code.

## The saved table

`Open` creates every missing section; nothing else is added unless the player changes something.

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
| `version` | — | A new table is stamped at `Open`; each migration step advances it. |
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
| `dispatch` | `compactOnLogout`, called by the per-database logout listener, so an upgrade replaces its behaviour. |
| `databases` | Saved-variable name to its database. Strong: a database lives for the session, like its saved variable. |
| `views` | Weak-keyed map from view proxy to its node. |
| `viewMetatable` | The one metatable of every view: `__index`, `__newindex`, `__metatable = "SettingsKit.View"`. |
| `databaseMetatable` | The one metatable of every database: `__index` (methods, and the unavailable-scope error), `__newindex` (refuse). |

## Databases

A database is a table carrying its views as plain fields (`global`, `char`, ..., `profile`), so reading `db.profile` is a raw field read with no metamethod, and private fields prefixed with `_`:

| Field | Purpose |
|---|---|
| `_layout` | Database layout number (`1`). |
| `_name` | The saved-variable name. |
| `_raw` | The saved table. |
| `_schemaSource` | The schema table passed to `Open`, to recognise a reopen. |
| `_scopes` | Scope name to scope record (below), for every declared scope. |
| `_unavailable` | Scope name to the message a read of `db.<scope>` raises. |
| `_charKey` | `"<name> - <realm>"`, or `false`. |
| `_defaultProfile` | The resolved default profile name (`"char"` already resolved). |
| `_profile` | The current profile name. |
| `_profileRoots` | Profile name to its cached root view. |
| `_version` | `options.version`, or `false`. |
| `_signals` | The four profile signals. |
| `_logoutConnection` | The EventKit connection, or `false`. |

A scope record holds the scope's `name`, its own sealed `schema`, its compiled `plan`, the `sectionName` and `sectionKey` of its saved table, whether it is `available`, and its `OnChange` `signal`.

A missing scope field falls through to the metatable's `__index`, which looks for a method on the `Database` prototype and otherwise raises the stored `_unavailable` message at the reading line.

## Plans

`Open` describes each scope schema once (`schema:Describe()`) and compiles the description into a plan tree. A plan node records:

| Field | Meaning |
|---|---|
| `kind` | The SchemaKit kind. |
| `proxied` | `"record"` for a `table`, `"map"` for a `map`, `false` for everything else or below depth 16. |
| `fieldNames`, `fields` | Record: sorted names and each field's plan. |
| `ownDefaults` | Record: every field default, filled the way `schema:Apply` fills them. |
| `values`, `max` | Map: the plan of the values and the entry bound. |
| `default` | The declared default, filled. On a map's `values` plan this is the wildcard default. |

`fillDefaults` mirrors `Apply`: a missing value takes a copy of the declared default, then records are filled field by field, maps entry by entry and arrays element by element. `oneOf` defaults are not filled inside, because `Apply` picks the alternative by checking. Plans never change after `Open` and are shared by every view of the scope; the default tables in them are never handed to a consumer.

`compilePlan` is also where the rule "every field of a record read through a view is optional" is enforced, with the schema path of the offender.

## Views

### Why the proxy is empty

Lua 5.1 calls `__newindex` only when the key is absent from the table being written. A view that stored the saved values itself would stop seeing writes to every key it held, so validation would silently stop after the first write of each field. Every view is therefore an **empty** table with the shared view metatable, and the saved data lives behind it.

### Nodes

Each proxy maps, through `state.views`, to a node:

| Field | Meaning |
|---|---|
| `layout` | Node layout number (`1`). |
| `kind` | `"record"` or `"map"`. |
| `plan` | The plan of the value the view shows. |
| `db`, `scope` | The database and the scope record. |
| `parent`, `key` | The parent node and this view's key in the parent's saved table; `false` for a scope root. |
| `root` | The scope root node. |
| `sectionName`, `sectionKey` | Root only: where the root's saved table lives (`profiles`/`"Default"`, `char`/`"Name - Realm"`, `global`/`false`). |
| `dead` | Root only: detached by `DeleteProfile` or `ResetDatabase`. |
| `defaults` | The defaults this view reads: the parent's default for this field, else the record's `ownDefaults`; for a map entry, the section's own default entry, else the wildcard default, else `ownDefaults`. |
| `displayPath`, `path` | `profile.frame` for messages, `frame` for `OnChange`. |
| `probe`, `probeSet`, `probeKey` | The scratch table this view contributes to a write's probe, and the one key set in it. |
| `children` | Record: field name to child view, built with the record. |
| `entries` | Map: key to entry view, weak-valued, built on first access. |

No node refers to its own proxy. `state.views` has weak keys, and Lua 5.1 weak tables are not ephemeron tables, so a node that referenced its proxy would keep the proxy alive forever; without that reference an entry view nobody holds can be collected, and the weak-valued `entries` cache drops it.

### Resolution

A view never holds its saved table. `resolveContainer(node)` walks from the root: the root reads `raw[sectionName]` (then `[sectionKey]`), and each child reads its `key` from its parent's table, returning `nil` as soon as something is missing or not a table. `resolveForWrite(node)` does the same walk but creates each missing table. The walk costs one `rawget` per nesting level and allocates nothing.

Resolving on every access is what keeps views valid when saved tables are replaced or emptied: `ResetProfile` and `CopyProfile` empty and refill the profile's table in place, `ResetDatabase` empties the whole saved variable in place and recreates its sections, and a view resolves whatever is there now. A detached root (`dead`) resolves to `nil`, so a stale view reads defaults and cannot resurrect a deleted profile.

Views are built recursively down to SchemaKit's `MAX_DEPTH` (16), the deepest value SchemaKit follows; a record or map below that is read as a plain value. Record child views are built when their parent is built (at `Open`, and when a profile view is first built by `SetProfile`); keyed-section entry views on the first read of each key.

### A read

`viewIndex` finds the node and dispatches on `kind`:

- **record**: read the key from the resolved saved table. A value is returned as is, except that a table under a record or map field returns the child view. Nothing saved: a record or map field returns its child view when it has a default, a scalar returns its default, and a plain table default is copied into the saved table (`materialise`) and returned.
- **map**: the same, with the default taken from the section's default entries and then the wildcard default, and entry views built on demand. A secret key is refused before it is used to index anything.

### A write

`viewNewIndex` → `writeView`:

1. Refuse on a detached root.
2. Refuse a secret key, then a secret value or a table containing one (`scanForSecrets`, bounded by depth 16 and 65536 entries).
3. **Probe check.** Each view from the written one up to the root sets its key in its parent's probe to its own probe, the written view sets `key = value` in its probe, and the scope's sealed schema checks the root probe. The probe holds exactly the path to the written value, and every other field of every record on the path is optional (`compilePlan` guarantees it), so the check passes exactly when the value is valid where it is written. The probes are cleared again before any error is raised. A valid check allocates nothing; the reported path is SchemaKit's own, relative to the scope, and the message is built only on failure.
4. Refuse a write that would add an entry to a keyed section already holding `max` entries (the probe holds one entry, so the bound is counted against the saved table, stopping at `max`).
5. Store with `rawset` into the resolved (or created) table.
6. Fire the scope's signal with `(db, scope, key, value, path)`.

A probe key left behind by a custom check that raised mid-check is cleared by the next write that uses that probe (`probeSet` / `probeKey`), so a stale key can never leak into a later check.

## Compaction

`compactRecord`, `compactMap` and `compactValue` walk a saved table together with its plan and defaults. A value deeply equal to its default is removed (`deepEqual` treats a secret as unequal to everything and stops at depth 16). A record or map table is compacted first and then removed when it is empty and has a default to fall back to. `compactScope` walks every entry of a section, removes empty character, realm, class and faction entries, and keeps empty profiles. The logout listener calls `dispatch.compactOnLogout(db)`, which runs `compactDatabase` under `pcall` and reports a failure through `geterrorhandler()`.

## Closures and upgrades

SettingsKit hands out one closure per database: the `PLAYER_LOGOUT` listener, which calls through `state.dispatch`. Views and databases get their behaviour from the two metatables in `_state` and the `Database` prototype, which a newer revision rewrites in place. Databases, nodes and plans carry layout numbers so a revision that changes a layout can upgrade them lazily. The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised to 2 and checks that a database opened before the upgrade, its views, its `OnChange` and profile listeners and its logout compaction keep working.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass `3` to helpers they call directly and raise their own errors at `2`. The functions behind the view metatable are called by the writing or reading line, so `viewNewIndex` passes through to `writeView`, which raises at `3`, `readMap` raises at `3`, and `databaseIndex` and `databaseNewIndex` raise at `2`. Lua 5.1 refuses a `nil` or NaN key while looking for the slot, before any metamethod runs, so those never reach SettingsKit.
