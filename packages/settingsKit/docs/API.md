# SettingsKit API

SettingsKit API generation **1** opens a database over an addon's saved variable: scoped views whose reads fall back to schema defaults and whose writes are validated at the writer's line, profiles, change signals, versioned migrations and compaction.

Implementation revision: **1**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
SchemaKit.lua
SettingsKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local SettingsKit = MoltenCodes.Registries[2]:Get("settingsKit", 1)
```

SettingsKit does not rely on `require()` at runtime. Loading it without one of its dependencies raises `MoltenCodes SettingsKit requires Registry API 2 to be loaded first` (or `SchemaKit API 1`, `SignalKit API 1`).

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `UnitName("player")`, `GetRealmName()` | the `char` scope key `"<name> - <realm>"`; `realm` needs only `GetRealmName` | The scope is unavailable (below). `defaultProfile = "char"` falls back to `"Default"` and the profile choice is not recorded. |
| `UnitClass("player")` | the `class` scope key, its second result (`"MAGE"`) | The `class` scope is unavailable. |
| `UnitFactionGroup("player")` | the `faction` scope key (`"Alliance"`, `"Horde"`, `"Neutral"`) | The `faction` scope is unavailable. |
| `issecretvalue` | every validated write, keyed-section reads, the scope keys | Nothing is treated as secret, which is correct on clients without secret values. Read at every call. |
| `geterrorhandler` | reporting a logout compaction that failed | Falls back to `print`. |
| EventKit API 1 | compaction on `PLAYER_LOGOUT` | `db:Compact()` is the addon's to call. |

The four identity functions are called once per `Open`. A function that is missing, or returns `nil`, an empty string or a secret, makes its scope **unavailable**: reading `db.class` then raises at the reading line, for example `SettingsKit (MyAddonDB) db.class is unavailable: UnitClass("player") returned no class when the database was opened`. The identity is read once, so a database opened before the client knows the player (at file scope, say) stays without those scopes; open it in the loaded phase.

EventKit is found with `Registry:Find("eventKit", 1)` when a database is opened. It is never an edge in the load order, so a bundle that does not ship it still loads SettingsKit.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `Open(savedVariable, schema?, options?)` | Open (or return the open) database over a saved variable. |
| `DEFAULT_PROFILE` | `"Default"`, the shared profile's name. |
| `MAX_PROFILE_NAME_LENGTH` | `64`: the longest profile name, in bytes. |
| `Database` | The shared prototype of databases, for introspection. |

Databases:

| Member | Purpose |
|---|---|
| `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction`, `db.profile` | Live views of each declared, available scope. |
| `GetProfile()` | The current profile's name. |
| `SetProfile(name)` | Switch profile, creating it when missing. |
| `GetProfiles()` | Every profile name, sorted. Allocates. |
| `CopyProfile(from)` | Replace the current profile with a copy of `from`. |
| `ResetProfile()` | Empty the current profile. |
| `DeleteProfile(name)` | Delete a profile other than the current one. |
| `ResetDatabase()` | Empty the whole saved variable. |
| `OnChange(scope, callback)` | Connect to validated writes of one scope. |
| `OnProfileChanged(callback)`, `OnProfileCopied(callback)`, `OnProfileReset(callback)`, `OnProfileDeleted(callback)` | Connect to the profile signals. |
| `Compact()` | Remove every saved value equal to its default. |
| `GetSavedVariable()` | The global name the database was opened over. |

The `On*` methods return SignalKit connections; `connection:Disconnect()` stops the listener.

## A complete addon

`MyAddon.toc`:

```toc
## Title: My Addon
## SavedVariables: MyAddonDB

embeds.xml
Core.lua
```

`embeds.xml` lists Registry, SignalKit, EventKit, LifecycleKit, SchemaKit and SettingsKit in that order (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md)).

`Core.lua`:

```lua
local ADDON_NAME = ...
local Registry = MoltenCodes.Registries[2]
local LifecycleKit = Registry:Get("lifecycleKit", 1)
local SchemaKit = Registry:Get("schemaKit", 1)
local SettingsKit = Registry:Get("settingsKit", 1)
local S = SchemaKit

-- Every field is optional: a saved variable starts empty.
local Aura = S.table({
    fields = {
        shown = S.optional(S.boolean(), true),
        color = S.optional(S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }), { 1, 1, 1 }),
        sound = S.optional(S.string({ max = 64 })),
    },
})

local schema = {
    global = S.table({ fields = { installs = S.optional(S.number({ integer = true, min = 0 }), 0) } }),
    char = S.table({ fields = { lastZone = S.optional(S.string({ max = 64 })) } }),
    profile = S.table({
        fields = {
            scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
            anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), "CENTER"),
            frame = S.optional(S.table({
                fields = { x = S.optional(S.number(), 0), y = S.optional(S.number(), 0) },
            }), {}),
            -- A keyed section: every spell ID reads as the Aura defaults until set.
            auras = S.optional(S.map({
                keys = S.number({ integer = true, min = 1 }),
                values = S.optional(Aura, {}),
                max = 256,
            }), {}),
        },
    }),
}

local migrations = {
    -- Version 2 moved the scale out of the old flat table into the profile.
    [2] = function(raw)
        if raw.scale ~= nil then
            raw.profiles = raw.profiles or {}
            raw.profiles.Default = raw.profiles.Default or {}
            raw.profiles.Default.scale = raw.scale
            raw.scale = nil
        end
    end,
}

local lifecycle = LifecycleKit:ForAddon(ADDON_NAME)

lifecycle:OnLoaded(function()
    local db = SettingsKit:Open("MyAddonDB", schema, {
        defaultProfile = "Default",
        version = 2,
        migrations = migrations,
    })

    db.global.installs = db.global.installs + 1

    db:OnChange("profile", function(_, _, key, value, path)
        -- path is "" for db.profile.scale, "frame" for db.profile.frame.x,
        -- "auras[118]" for db.profile.auras[118].shown.
        MyAddon:ApplySetting(path, key, value)
    end)

    db:OnProfileChanged(function(_, name, previous)
        MyAddon:ApplyAll()
    end)

    MyAddon.db = db
end)

-- Later, anywhere:
local profile = MyAddon.db.profile
profile.frame.x = 120            -- validated, stored as profiles.Default.frame.x
profile.auras[118].shown = false -- validated, stored as profiles.Default.auras[118].shown
profile.anchor = "LEFT"          -- raises at this line:
-- SettingsKit (MyAddonDB) profile.anchor: expected one of "TOP", "CENTER", "BOTTOM", found unlisted string
```

## `SettingsKit:Open(savedVariable, schema?, options?)`

`savedVariable` is the global name from the TOC's `## SavedVariables` line, an identifier. When the global is `nil`, `Open` creates it as `{}`; when it holds anything but a table, `Open` refuses at your line. **Call `Open` in the addon's loaded phase** (`lifecycle:OnLoaded`, or your own `ADDON_LOADED` for your addon): before it, the client has not loaded the saved table yet, and it will replace the one `Open` created.

`schema` maps scope names to SchemaKit `table` nodes or sealed schemas. Each scope is optional, at least one is required, and an unknown scope name is refused. SettingsKit seals its own copy of each (sealing a sealed schema gives a new one with its own failure table), so a write never overwrites the failure of a check you run with the same schema. Two rules apply:

- a scope schema must be a `SchemaKit.table`;
- **every field of every record read through a view is `optional`** — the scope's own fields, the fields of nested `table` fields, and the fields of records that are the values of a `map`. A saved variable starts empty and fills in one write at a time, so a required field could never be satisfied. `Open` refuses one with its path: `SettingsKit:Open schema.profile.frame.x must be optional: a saved variable starts empty`.

`options`:

| Field | Default | Meaning |
|---|---|---|
| `defaultProfile` | `"Default"` | The profile a character without a recorded choice starts on. `"char"` gives each character its own profile named `"<name> - <realm>"`. Any other name is used as it is. |
| `version` | none | The version of the saved table this addon writes, a positive integer. |
| `migrations` | none | `{ [n] = function(raw) }`, each key from 1 to `version`. Requires `version`. |

Unknown fields are refused.

Opening a name that is already open returns the same database. `schema` may then be omitted; passing a different schema table raises, and so does a saved variable replaced since the first `Open`. Options passed to a later `Open` are ignored.

### What `Open` does, in order

1. Validates every argument and compiles the schemas, before anything is written.
2. Reads the scope keys.
3. Creates the global when it is missing.
4. Runs migrations (below).
5. Creates every missing section of the layout (see [`INTERNALS.md`](INTERNALS.md#the-saved-table)); a section that is not a table is refused.
6. Picks the profile: the character's recorded choice when it names a usable profile, otherwise the default profile. The profile gets an empty table when it has none.
7. Builds the views and, when EventKit is registered, connects the logout compaction.

## Migrations

With `options.version = n`:

- a saved table that is **empty** (a new install) is stamped `version = n` and no migration runs;
- otherwise the stored `version` (`0` when absent) is compared with `n`, and each `migrations[step]` from the stored version + 1 to `n` runs once, in ascending order, receiving the raw saved table to change in place. Steps without a function are skipped. The stored version is written after each step, so a finished step never runs again;
- a step that raises stops `Open` with `SettingsKit:Open migration <step> of <name> failed: <error>` at your line. The steps before it stay done, and the next `Open` retries from the failing step;
- a stored version above `n` (a downgrade) is left alone and nothing runs;
- a stored version that is not a non-negative integer is refused.

SettingsKit owns the `version` key of the saved table. Migrations run before the layout is created, so a step may restructure a table written by a pre-SettingsKit version of the addon.

## Views: `db.<scope>`

`db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` and `db.profile` are **views**: empty tables whose metatable reads and writes the saved table behind them. `getmetatable(view)` returns `"SettingsKit.View"`.

### Reads

| Declared field | Saved value present | Nothing saved |
|---|---|---|
| a scalar (string, number, boolean, enum) | the saved value | the default, or `nil` |
| a `table` (record) | a view of the saved table | a view reading the defaults, when the field has a default; otherwise `nil` |
| a `map` (keyed section) | a view of the saved table | a view reading the default entries, when the field has a default; otherwise `nil` |
| an `array`, or `any`, `oneOf`, `custom` holding a table | the saved table itself | **a copy of the default, stored on this first read** |
| undeclared (on an open or closed record) | the saved value | `nil` |

A record view reads each field from the saved table, then from the defaults: a record default filled with its own field defaults, the way `schema:Apply` fills it. A keyed-section view reads a key from the saved table, then from the section's own default entries, then from its **wildcard default** — the default of `optional(...)` on the map's `values` — so `db.profile.auras[118].shown` is `true` for a spell ID nothing was ever saved for. Views of the same record or entry are the same table every time you read them.

Reading a default never writes, with the one exception in the table: an array (or other plain table) default is copied into the saved table on first read, so that editing it in place cannot change the default for the rest of the session. `Compact` removes the copy again while it still equals the default.

### Writes

`view[key] = value` runs, in order:

1. **Secret refusal.** A secret key, a secret value or a table containing one anywhere (scanned to 16 levels and at most 65536 entries; a larger table is refused too) raises `SettingsKit (MyAddonDB) profile.name refused a secret value: saved variables never hold secret values`. Nothing is stored.
2. **Schema check.** The value is checked where it is written, against the scope's schema, and a failure raises with SchemaKit's text: `SettingsKit (MyAddonDB) profile.frame.x: expected number, found string`. An undeclared field of a closed record is refused the same way.
3. **Bounds.** A write that adds an entry to a keyed section already holding `max` entries raises `SettingsKit (MyAddonDB) profile.auras: expected at most 256 entries`.
4. **Store.** Missing tables on the way are created. Writing `nil` removes the saved value, so the field reads its default again.
5. **Signal.** The scope's `OnChange` signal fires.

Every refusal is raised at the writing line and stores nothing. A table you assign is stored as it is, by reference: later changes through your own reference to it are not validated. Read the field back to change it through a view.

### What a view cannot do

- `pairs`, `next` and `#` see an empty table: Lua 5.1 has no `__pairs` or `__len` for tables. Iterate the schema's fields, or read the saved variable itself for diagnostics.
- A view of a deleted profile, or of any profile after `ResetDatabase`, is **detached**: it reads defaults and refuses writes with `... belongs to a profile that was deleted or reset away`.
- Reading a keyed section with a secret key raises at the reading line.

## Profiles

The current profile is chosen per character and recorded in the saved table (`profileKeys`) when `SetProfile` is called. All profile methods work whether or not a `profile` schema is declared; `db.profile` exists only when it is.

### `db:SetProfile(name)`

Switches to profile `name`, creating an empty one when it does not exist, records it for this character (when the character key is available), points `db.profile` at a view of it and fires `OnProfileChanged(db, name, previous)`. Returns `true`, or `false` without a signal when `name` is already current. `db.profile` is a different table after a switch; a view kept from before keeps reading and writing the profile it was made for.

Profile names are non-empty strings of at most 64 bytes with a character other than whitespace, never secret.

### `db:GetProfiles()`

A fresh array of every profile name, sorted with `<`, always including the current one.

### `db:CopyProfile(from)`

Replaces the current profile's contents with a deep copy of profile `from` and fires `OnProfileCopied(db, from, current)`. The current profile keeps its table, so `db.profile` is unchanged. Copying the current profile onto itself, a profile that does not exist, or one nesting more than 16 tables is refused.

### `db:ResetProfile()`

Empties the current profile in place, so every field reads its default, and fires `OnProfileReset(db, name)`.

### `db:DeleteProfile(name)`

Deletes a profile other than the current one and fires `OnProfileDeleted(db, name)`. Characters whose recorded choice was `name` lose it and start on the default profile at their next `Open`. Deleting the current profile or one that does not exist is refused.

### `db:ResetDatabase()`

Empties the saved variable in place, keeps its `version`, recreates the layout, switches to the default profile, fires `OnProfileReset(db, name)` and, when the profile name changed, `OnProfileChanged(db, name, previous)`. Every profile view obtained before is detached, and `db.profile` is a new view. The scope views of `global`, `char` and the rest stay valid.

## Change signals

### `db:OnChange(scope, callback)`

`scope` names a declared, available scope. After every validated write through that scope's views, `callback(db, scope, key, value, path)` is called with the key and value written (`nil` when a field was reset) and `path`, the path of the table holding the key relative to the scope: `""` for `db.profile.scale`, `"frame"` for `db.profile.frame.x`, `"auras[118]"` for `db.profile.auras[118].shown`.

The signal fires after the value is stored. SignalKit's dispatch rules apply: listeners run in connection order, and a listener that raises stops the dispatch and propagates to the writing line.

### Profile signals

| Method | Callback |
|---|---|
| `OnProfileChanged(callback)` | `callback(db, name, previous)` |
| `OnProfileCopied(callback)` | `callback(db, from, name)` |
| `OnProfileReset(callback)` | `callback(db, name)` |
| `OnProfileDeleted(callback)` | `callback(db, name)` |

## `db:Compact()`

Walks every declared scope — every stored character, realm, class and faction entry and every profile, not only the current ones — and removes:

- each saved value deeply equal to its default (a map entry is compared with the section's own default entry, then with the wildcard default);
- each record or keyed-section table left empty, when it has a default to fall back to. A table without a default stays, because removing it would turn its view into `nil`;
- each empty character, realm, class or faction entry. Empty profiles stay: they are still profiles.

Returns how many values and tables it removed. With EventKit registered, every database compacts itself on `PLAYER_LOGOUT`; a compaction that raises there is reported through `geterrorhandler()` rather than raised into EventKit's dispatch. Values written after that compaction are saved as they are.

## Error behaviour

Argument failures report the line that called SettingsKit, never a line inside it, and name the parameter without formatting the value: `SettingsKit:Open options.version must be a positive integer`, `SettingsKit.Database:DeleteProfile cannot delete the current profile`. Calling a method on something that is not a database raises `SettingsKit.Database:SetProfile must be called on a SettingsKit database`. View refusals report the writing (or reading) line and are prefixed with the saved-variable name, `SettingsKit (MyAddonDB) ...`. Writing a field of the database object itself raises `SettingsKit databases are read-only; write through db.<scope> instead`.

## Performance

| Operation | Cost |
|---|---|
| Reading a field through a view | One table lookup per nesting level to find the saved table, then one read or one default lookup. No allocation. |
| Reading a keyed-section entry the first time | Builds that entry's view (cached while referenced). |
| A validated write | One schema check of a probe holding only the written path, one table write, one signal dispatch. No allocation when the key already exists. |
| `Open`, `SetProfile` to a new profile | Build the views of the scope: one proxy and node per record and keyed section in the schema. |
| `GetProfiles`, `CopyProfile`, `Compact` | Allocate or walk by design; not for hot paths. |

Defaults are compiled once at `Open` from `schema:Describe()`; nothing on the read path consults SchemaKit.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **EventKit, not LifecycleKit, is the optional dependency.** The plan lists LifecycleKit as optional with nothing to do; compaction at logout needs a `PLAYER_LOGOUT` listener, and EventKit is the Kit that delivers host events. It is found at `Open` through `Registry:Find("eventKit", 1)` and declared under `optionalDependencies`.
- **Migrations receive the raw saved table** (`fn(raw)`), not the database. They run before the layout and the views exist, so a step can restructure a table written by an older version of the addon, including one that predates SettingsKit.
- **Every field of a record read through a view must be `optional`.** A write is validated by checking a probe that holds only the written path; that is what makes a write one schema check with no allocation, and it is only sound when every other field may be absent.
- **Plain table defaults are copied into the saved table on first read.** Arrays and other tables without their own view would otherwise hand out the shared default to be edited in place. Records and keyed sections, the common case, are never written back.
- **A read resolves the saved table through each nesting level** instead of holding it. That keeps every view valid across `ResetProfile`, `CopyProfile` and `ResetDatabase`, which replace or empty saved tables, at the cost of one lookup per level.
- **The profile choice is recorded by `SetProfile`**, not at `Open`, so a character that never switches writes nothing.
- **Additions:** `OnProfileCopied`, `OnProfileReset` and `OnProfileDeleted` methods; a fifth `path` argument to `OnChange` listeners; `db:GetSavedVariable()`; `Compact` returns a count; `SettingsKit.DEFAULT_PROFILE` and `SettingsKit.MAX_PROFILE_NAME_LENGTH`.

## Embedded copies and upgrades

Several addons may embed SettingsKit; Registry selects the newest compatible revision and every copy shares one facade. Package state holds one database per saved-variable name, and an upgrade keeps it: databases, views, their listeners and the logout connection keep working and run the newer implementation, because the database and view metatables and the logout listener's dispatch table are rewritten in place.

Nothing survives `/reload` except the saved variable itself: open the database again in the loaded phase.
