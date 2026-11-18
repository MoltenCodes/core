# SettingsKit API

SettingsKit API generation **1** opens a database over an addon's saved variable: scoped views whose reads fall back to schema defaults and whose writes are validated at the writer's line, profiles (also switched by specialization), change signals, versioned migrations and compaction.

Implementation revision: **16**. Parts `Namespaces`, `SpecProfiles` and `Defaults`: revision **1** each.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
SchemaKit.lua               (only for scopes given as SchemaKit schemas)
SettingsKit.lua
parts/SettingsKit-Defaults.lua      (optional: plain AceDB-style defaults)
parts/SettingsKit-SpecProfiles.lua  (optional: spec profiles)
parts/SettingsKit-Namespaces.lua    (optional: namespaces)
```

SettingsKit's core (revision 16) needs Registry and SignalKit. SchemaKit is optional: it is found through `Registry:Find("schemaKit", 1)` when a scope is a SchemaKit schema, so a database-only addon with plain defaults embeds Registry, SignalKit, SettingsKit and `SettingsKit-Defaults.lua`, and one with SchemaKit schemas embeds SchemaKit as before. Three optional parts ([ADR 0001](../../../docs/decisions/0001-kit-core-and-parts.md)) load after the core; `python3 -m tooling.package.embeds settingsKit/Defaults` writes the list:

| Part | File | Adds |
|---|---|---|
| `Defaults` | `parts/SettingsKit-Defaults.lua` | `Open` and `RegisterNamespace` from plain defaults (see [Plain defaults](#plain-defaults)) |
| `SpecProfiles` | `parts/SettingsKit-SpecProfiles.lua` | [spec profiles](#spec-profiles): `GetSpecIndex`, `SetSpecProfile`, `GetSpecProfile`, `ApplySpecProfile` |
| `Namespaces` | `parts/SettingsKit-Namespaces.lua` | [namespaces](#namespaces): `RegisterNamespace`, `GetNamespace` |

A member of a part that is not loaded stays on the facade or the database prototype and raises at the caller's line with the file to add, for example `SettingsKit:GetSpecIndex is in SettingsKit's SpecProfiles part, which is not loaded: add settingsKit\parts\SettingsKit-SpecProfiles.lua`; a plain defaults scope without the Defaults part raises `SettingsKit:Open plain defaults are in SettingsKit's Defaults part, which is not loaded: add settingsKit\parts\SettingsKit-Defaults.lua`. `SettingsKit:HasPart(name)` answers whether a part is loaded without raising. A part loaded before the core raises `MoltenCodes SettingsKit part <Part> requires SettingsKit API 1 to be loaded first`.

Portable WoW code resolves the package through Registry:

```lua
local SettingsKit = MoltenCodes.Registries[2]:Get("settingsKit", 1)
```

SettingsKit does not rely on `require()` at runtime. Loading it without one of its dependencies raises `MoltenCodes SettingsKit requires Registry API 2 to be loaded first` (or `SignalKit API 1`).

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `UnitNameUnmodified("player")` (else `UnitName("player")`), `GetRealmName()` | the `char` scope key `"<name> - <realm>"`, also `SettingsKit:GetCharacterKey()`; `realm` needs only `GetRealmName` | The scope is unavailable (below). `defaultProfile = "char"` falls back to `"Default"` and the profile choice is not recorded. |
| `UnitClass("player")` | the `class` scope key, its second result (`"MAGE"`) | The `class` scope is unavailable. |
| `UnitFactionGroup("player")` | the `faction` scope key (`"Alliance"`, `"Horde"`, `"Neutral"`) | The `faction` scope is unavailable. |
| `UnitRace("player")` | revision 15, only for a schema declaring `race`: its second result, the race's file name (`"Scourge"`) | The `race` scope is unavailable. Documented on Retail (`UnitDocumentation.lua`); undocumented on Mists of Pandaria Classic and Classic Era, where Blizzard's own character frame calls it (`Blizzard_CharacterFrame/Cata/PaperDollFrame.lua`, `Vanilla/PaperDollFrame.lua`). |
| `GetCurrentRegion()`, `GetCurrentRegionName()` | revision 15, only for a schema declaring `factionrealmregion`: the region, as AceDB-3.0 names it (`US`, `KR`, `EU`, `TW`, `CN` by `GetCurrentRegion()`, else `GetCurrentRegionName()`, else `TR`) | `TR`. `GetCurrentRegionName` is documented only on Retail and is read only where the client has it. |
| `GetLocale()` | revision 15, only for a schema declaring `locale`: the key is its answer in lower case | The `locale` scope is unavailable. |
| `issecretvalue` | every validated write through a view, the key of `Getter`, `Validate`, `Compact`, profile names, namespace names, `missingOk` options, the scope keys | Nothing is treated as secret, which is correct on clients without secret values. Read at every call. Reads are not probed (revision 14): the client refuses a secret key before any metamethod runs (see [Error behaviour](#error-behaviour)). |
| `geterrorhandler` | reporting a logout compaction that failed | Falls back to `print`, as it does when the handler itself raises (revision 16, the shared `reportError` block). |
| EventKit API 1 | compaction on `PLAYER_LOGOUT`; switching [spec profiles](#spec-profiles) on the spec events | `db:Compact()` and `db:ApplySpecProfile()` are the addon's to call. |
| `C_SpecializationInfo`, `UnitClass`, `GetNumTalentGroups`, `WOW_PROJECT_ID` | [spec profiles](#spec-profiles) (the SpecProfiles part): the current specialization or talent group | No spec index: assignments are kept, nothing switches. |

The character key takes the name from `UnitNameUnmodified("player")` (revision 14), which no name-changing effect alters (`UnitName` reports a changed name under effects such as Lifegiving Seed, warcraft.wiki.gg `API_UnitName`), as AceDB-3.0 keys characters; when the client has no `UnitNameUnmodified` or its answer is not usable, `UnitName("player")` gives it, as before. Both answer alike outside such effects, so saved data keeps its key. Both are documented in `Blizzard_APIDocumentationGenerated/UnitDocumentation.lua` on the `live`, `classic` and `classic_era` branches of Gethe/wow-ui-source.

The identity functions are called once per `Open`, the revision 15 ones only for the scopes the schema declares. A function that is missing, or returns `nil`, an empty string or a secret, makes its scope **unavailable**: reading `db.class` then raises at the reading line, for example `SettingsKit (MyAddonDB) db.class is unavailable: UnitClass("player") returned no class when the database was opened`. The identity is read once, so a database opened before the client knows the player (at file scope, say) stays without those scopes; open it in the loaded phase.

EventKit is found with `Registry:Find("eventKit", 1)` when a database is opened. It is never an edge in the load order, so a bundle that does not ship it still loads SettingsKit.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `Open(savedVariable, schema?, options?)` | Open (or return the open) database over a saved variable. |
| `SetLimits(limits)` | Change any subset of the shared limits (see [Limits](#limits)). |
| `GetLimits()` | A fresh table of the shared limits. |
| `GetSpecIndex()` | The current spec index, the number of indexes and their kind (see [Spec profiles](#spec-profiles)). SpecProfiles part. |
| `HasPart(name)` | Revision 16: whether the part `"Defaults"`, `"SpecProfiles"` or `"Namespaces"` is loaded; `false` for any other name. |
| `GetCharacterKey()` | Revision 14: this character's key in `char`, `profileKeys` and `specProfiles` (`"<name> - <realm>"`), the one `Open` uses now, or `nil` while the client cannot name the character. For an importer that must key data the way SettingsKit reads it. |
| `UNBOUNDED` | Sentinel `maxScannedEntries` accepts to lift the scan bound. |
| `DEFAULT_PROFILE` | `"Default"`, the shared profile's name. |
| `MAX_PROFILE_NAME_LENGTH` | `64`: the default longest profile name, in bytes; `GetLimits().maxProfileNameLength` is the current one. |
| `Database` | The shared prototype of databases, for introspection. |

Databases:

| Member | Purpose |
|---|---|
| `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction`, `db.profile`, and from revision 15 `db.race`, `db.factionrealm`, `db.factionrealmregion`, `db.locale` | Live views of each declared, available scope. |
| `GetProfile()` | The current profile's name. |
| `SetProfile(name)` | Switch profile, creating it when missing. |
| `GetProfiles()` | Every profile name, sorted. Allocates. |
| `CopyProfile(from, options?)` | Replace the current profile with a copy of `from`. |
| `ResetProfile()` | Empty the current profile. |
| `DeleteProfile(name, options?)` | Delete a profile other than the current one. |
| `ResetDatabase()` | Empty the whole saved variable. |
| `OnChange(scope, callback)` | Connect to validated writes of one scope. |
| `OnProfileChanged(callback)`, `OnProfileCopied(callback)`, `OnProfileReset(callback)`, `OnProfileDeleted(callback)` | Connect to the profile signals. |
| `OnNewProfile(callback)`, `OnProfileShutdown(callback)`, `OnDatabaseShutdown(callback)`, `OnDatabaseReset(callback)` | Revision 15: connect to the lifecycle signals (see [Lifecycle signals](#lifecycle-signals)). |
| `IsNewProfile()` | Revision 15: whether this session created the current profile's table. |
| `RegisterNamespace(name, schema)`, `GetNamespace(name, options?)` | With the Namespaces part: a namespace's database (see [Namespaces](#namespaces)). |
| `Compact()` | Remove every saved value equal to its default. |
| `GetSavedVariable()` | The global name the database was opened over. |
| `Pairs(view)` | Iterate a view: keys with defaults, then saved keys. |
| `Validate(scope, path, value)` | Whether a write would be accepted, without writing. |
| `IsReadOnly()` | Whether the database refuses every write because a newer version of the addon saved the data (see [Newer stored data](#newer-stored-data-read-only-databases)). |
| `Resync()` | Make every view see direct edits of the saved variable (see [Views hold their saved tables](#views-hold-their-saved-tables)). |
| `Getter(source, key)` | A function reading one field, to hand a reader around (see [`db:Getter`](#dbgettersource-key)). |
| `SetSpecProfile(index, name?)`, `GetSpecProfile(index)`, `ApplySpecProfile()` | Assign a profile to a specialization or talent group, read it, apply it (see [Spec profiles](#spec-profiles)). |

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

`schema` maps scope names (`global`, `char`, `realm`, `class`, `faction`, `profile`, and from revision 15 `race`, `factionrealm`, `factionrealmregion`, `locale`) to SchemaKit `table` nodes or sealed schemas, or, with the Defaults part (revision 16), to plain AceDB-style defaults tables (see [Plain defaults](#plain-defaults)); a database may mix both. Each scope is optional, at least one is required, and an unknown scope name is refused. SettingsKit seals its own copy of each (sealing a sealed schema gives a new one with its own failure table), so a write never overwrites the failure of a check you run with the same schema. Databases opened with the same schema node or sealed schema share that seal and its compiled plan, which is built by the first of them and reused while SchemaKit's `maxDepth` and revision stay the same (revision 6). Two rules apply:

- a scope schema must be a `SchemaKit.table`;
- **every field of every record read through a view is `optional`** — the scope's own fields, the fields of nested `table` fields, and the fields of records that are the values of a `map`. A saved variable starts empty and fills in one write at a time, so a required field could never be satisfied. `Open` refuses one with its path: `SettingsKit:Open schema.profile.frame.x must be optional: a saved variable starts empty`.

`options`:

| Field | Default | Meaning |
|---|---|---|
| `defaultProfile` | `"Default"` | The profile a character without a recorded choice starts on. `"char"` gives each character its own profile named `"<name> - <realm>"`. Any other name is used as it is. |
| `version` | none | The version of the saved table this addon writes, a positive integer. |
| `migrations` | none | `{ [n] = function(raw) }`, each key from 1 to `version`. Requires `version`. |
| `maxScannedEntries` | `65536` | The most entries the scan of one written table visits (see [Limits](#limits)): a positive integer or `SettingsKit.UNBOUNDED`. |
| `allowNewerData` | `false` | `true` opens a saved table whose stored version is newer than `version` writable instead of read-only (see [Newer stored data](#newer-stored-data-read-only-databases)). A boolean; requires `version`. |
| `maxNamespaces` | `256` | Revision 15: the most namespaces `RegisterNamespace` registers on this database, a positive integer or `SettingsKit.UNBOUNDED` (see [Limits](#limits)). Accepted without the Namespaces part. |

Unknown fields are refused, and so is a secret `version`, `maxScannedEntries`, `allowNewerData` or `migrations` key, before it is compared or tested: `SettingsKit:Open options.version must not be a secret value`, `SettingsKit:Open options.maxScannedEntries must not be a secret value`, `SettingsKit:Open options.allowNewerData must not be a secret value`, `SettingsKit:Open options.migrations must not have a secret key`. A secret option name is reported as `SettingsKit:Open options contains unknown field "<secret>"`. `allowNewerData` that is not a boolean raises `SettingsKit:Open options.allowNewerData must be a boolean`, and without `version` `SettingsKit:Open options.allowNewerData requires options.version`.

Opening a name that is already open returns the same database. `schema` may then be omitted; passing a different schema table raises, and so does a saved variable replaced since the first `Open`. Options passed to a later `Open` are ignored.

### What `Open` does, in order

1. Validates every argument and compiles the schemas (or reuses what an earlier `Open` compiled from the same schema), before anything is written.
2. Reads the scope keys.
3. Creates the global when it is missing.
4. Runs migrations (below). A stored version newer than `options.version` makes the database read-only unless `allowNewerData` is set.
5. Checks the layout (see [The saved table](#the-saved-table)): a section that is present but not a table is refused with `SettingsKit:Open MyAddonDB.global must be a table`. The check runs before anything else is written — before the version is stamped when no migration is pending, and on the last migration's result before that result is committed — so a refused table is never half-changed. A writable database then gets every missing section; a read-only one gets none.
6. Picks the profile: the character's recorded choice when it names a usable profile, otherwise the default profile. In a writable database the profile gets an empty table when it has none.
7. Builds the views and, when EventKit is registered, joins the logout compaction.
8. When this character has [spec profiles](#spec-profiles), connects the shared spec listener (with EventKit) and switches to the profile assigned to the current spec index, if there is one.

### Plain defaults

With the Defaults part loaded (revision 16), a scope may be a plain table of defaults, as AceDB-3.0 takes them. Any table without SchemaKit's metatable tag is one. The write rules are inferred from each default, exactly as AddonKit's `MC:Database` infers a SchemaKit schema, so a database opened either way accepts and refuses the same writes with the same messages:

```lua
local db = SettingsKit:Open("MyAddonDB", {
  profile = {
    enabled = true,                       -- an optional boolean
    scale = 1,                            -- an optional number (1.5 is accepted)
    font = "Friz Quadrata TT",            -- an optional string of at most 4096 characters
    frame = { x = 0, y = 0 },             -- a closed record of those fields
    seen = {},                            -- a free-form bag
    units = { ["*"] = { shown = true } }, -- a keyed section whose entries read the wildcard
    order = { 1, 2, 3 },                  -- an array of numbers
    level = SchemaKit.optional(SchemaKit.number({ min = 1, max = 10 }), 5), -- a SchemaKit leaf
  },
})
```

| Default | Rule |
|---|---|
| `true`, `1`, `"text"` | an optional boolean, number (not integer) or string of at most `max(4096, #default)` characters |
| `{ a = ..., b = ... }` | a closed record of those fields |
| `{}` | a free-form bag: string keys of at most 256 characters or number keys, at most 1024 entries, values unchecked (the secret scan and `maxScannedEntries` still apply) |
| `{ ["*"] = d }` | a keyed section of at most 1024 entries, keys as the bag's, whose entries read `d` |
| `{ 1, 2, 3 }` | an array of one primitive type of at most `max(1024, #default)` elements |
| a SchemaKit node or sealed schema | kept as written and made optional; its subtree is checked by its own `Check`, the path prefixed. Only such a leaf needs SchemaKit. |

`Open` refuses at your line, naming the path: `SettingsKit:Open defaults profile.x uses ["**"], which has no SettingsKit form; ...`, `... puts ["*"] beside named keys, ...`, `... has a number key; record keys are non-empty strings ...`, `... is a list of mixed or table values; write its schema node inline (SchemaKit.array{ of = ... })`, `... is a function; a default is a boolean, number, string, table or schema node` and `... nest deeper than 16 tables` (SchemaKit's `maxDepth` when it is loaded). A scope that is not a table is refused as before: `SettingsKit:Open schema.profile must be a SchemaKit schema node or sealed schema`. A scope given as `{ ["*"] = d }` is refused, as an inferred map is: `SettingsKit:Open schema.profile must be a SchemaKit.table schema`. Not supported, as with `MC:Database`: AceDB's `["**"]`, `RegisterDefaults` (rules are fixed at `Open`), integer numbers and enums inferred from values (write a range or a choice as a leaf). Databases and namespaces opened with the same defaults table share one compiled plan.

## The saved table

The layout of the saved variable is part of the contract of API generation 1
(since 0.3.2): code other than SettingsKit may read it, and may write it
before `Open`, for example an importer that fills an empty saved variable
from another library's data. A later revision of generation 1 may add a
section or a field; it never renames, removes or reinterprets one below.
Changing them needs a new API generation.

```lua
MyAddonDB = {
  version = 2,
  global = { ... },
  profiles = { Default = { ... }, ["Tester - Silvermoon"] = { ... } },
  profileKeys = { ["Tester - Silvermoon"] = "Default" },
  char = { ["Tester - Silvermoon"] = { ... } },
  realm = { Silvermoon = { ... } },
  class = { MAGE = { ... } },
  faction = { Alliance = { ... } },
  race = { Scourge = { ... } },
  factionrealm = { ["Alliance - Silvermoon"] = { ... } },
  factionrealmregion = { ["Alliance - Silvermoon - EU"] = { ... } },
  locale = { enus = { ... } },
  namespaces = { Bars = { profiles = { Default = { ... } }, char = { ... } } },
  specProfiles = { ["Tester - Silvermoon"] = { "Healing", "Damage" } },
}
```

| Section | Type | Keyed by | Holds |
|---|---|---|---|
| `version` | positive integer, optional | — | The saved table's version (`options.version`). Absent means a table no migration has run on: `Open` stamps it, or runs every migration from 1. |
| `global` | table | — | The `global` scope's record. |
| `profiles` | table | profile name | One record per profile, the `profile` scope. |
| `profileKeys` | table | `"<name> - <realm>"` | The profile name each character chose. A character without an entry starts on `options.defaultProfile`; an entry naming a profile `profiles` lacks still selects that profile, and `Open` creates it empty (a read-only database creates nothing and reads its defaults). An entry that is not a usable profile name (not a string, blank, or longer than `maxProfileNameLength`) is ignored. |
| `char` | table | `"<name> - <realm>"`, from `UnitNameUnmodified("player")` (revision 14; `UnitName("player")` without it) and `GetRealmName()`, as `SettingsKit:GetCharacterKey()` answers | One record per character. |
| `realm` | table | `GetRealmName()` | One record per realm. |
| `class` | table | the class file name, the second return of `UnitClass("player")` (`"MAGE"`) | One record per class. |
| `faction` | table | `UnitFactionGroup("player")` (`"Alliance"`, `"Horde"`, `"Neutral"`) | One record per faction. |
| `race` | table | the race's file name, the second return of `UnitRace("player")` (`"Scourge"`) | Revision 15: one record per race. Created and checked by `Open` only when the schema declares `race`. |
| `factionrealm` | table | `"<faction> - <realm>"` (`"Alliance - Argent Dawn"`) | Revision 15: one record per faction and realm. Only when declared. |
| `factionrealmregion` | table | `"<faction> - <realm> - <region>"` (`"Alliance - Argent Dawn - EU"`, the region as [Host facilities](#host-facilities) says) | Revision 15: one record per faction, realm and region. Only when declared. |
| `locale` | table | `GetLocale()` in lower case, as AceDB-3.0 keys it | Revision 15: one record per client language. Only when declared. |
| `namespaces` | table | namespace name | Revision 15: each namespace's data, in AceDB-3.0's namespace layout, written by the [Namespaces](#namespaces) part: inside `namespaces[name]`, one section per scope the namespace declares (`profiles`, `global`, `char`, `realm`, `class`, `faction`, `race`, `factionrealm`, `factionrealmregion`, `locale`), keyed as the sections above are; no `profileKeys`, `specProfiles`, `version` or nested `namespaces`. Without the part SettingsKit writes nothing here. Before revision 15 this section was reserved for exactly this. |
| `specProfiles` | table | `"<name> - <realm>"` | Revision 11: each character's [spec profiles](#spec-profiles), a table from spec index (1 to 8) to profile name. An entry that is not a table, and a value that is not a usable profile name, is ignored. |

Every section is optional in what you write: `Open` creates the missing ones
in a writable database (the four revision 15 scope sections only when
declared). A present section that is not a table is refused, as
step 5 above says. Inside a record, a value is stored under the field name the
schema declares. SettingsKit never validates stored data: `Open` does not
check it, and a read returns a stored scalar as it is (a non-table where the
schema declares a record or keyed section reads as if nothing were saved, see
[Reads](#reads)). Code that writes the table from outside must therefore write
only values the schema accepts; `SchemaKit` or, once the database is open,
[`db:Validate`](#dbvalidatescope-path-value) checks a value before it is
stored. A value equal to its default may be left out, and `db:Compact()`
removes one that is stored. Other top-level keys are never read;
`ResetDatabase` removes them with everything else.

**While the database is open, saved tables read through to their defaults**
(revision 14). A saved table a view reads gets a metatable from SettingsKit,
marked `__settingsKitSaved`, whose `__index` answers the view's scalar
defaults, so `MyAddonDB.profiles.Default.scale` read directly answers the
default when nothing is saved, as AceDB-3.0's tables do. `rawget`, `next` and
`pairs` see only what is saved, a plain-table default (an array) is never
answered this way, and nothing changes on disk: the client saves no
metatables. A table you assign through a view gets the same metatable, and a
table that leaves the saved variable keeps it, harmlessly. Code that tests a
saved field for presence should use `rawget`.

[`INTERNALS.md`](INTERNALS.md#the-saved-table) describes when SettingsKit
itself writes each section.

## Migrations

With `options.version = n`:

- a saved table that is **empty** (a new install) is stamped `version = n` and no migration runs;
- otherwise the stored `version` (`0` when absent) is compared with `n`, and each `migrations[step]` from the stored version + 1 to `n` runs once, in ascending order. Steps without a function are skipped. The stored version is written after each step, so a finished step never runs again;
- **each step is a transaction.** A step receives a deep copy of the saved table's current contents and changes that copy in place. When the step returns, the copy's contents replace the saved table's contents **in place** — the saved-variable global keeps its identity, because that is the table the client saves — and then the version is stored. The tables inside the saved table are the copies from then on;
- a step that raises stops `Open` with `SettingsKit:Open migration <step> of <name> failed: <error>` at your line. The saved table and its version are exactly as they were before that step: whatever the step wrote went to the copy, which is dropped. The steps before it stay committed, and the next `Open` retries only the failing step, on untouched data, so a step is never applied twice;
- the result of the last step with a function must have the layout: when a layout section in it is present but not a table, that step counts as failed (`SettingsKit:Open migration <step> of <name> failed: <name>.global must be a table`) and is not committed. Steps before it may pass through any shape;
- a stored version above `n` (a downgrade: data a newer version of the addon saved) runs nothing, is never lowered, and opens the database **read-only** unless `allowNewerData` is set (see [Newer stored data](#newer-stored-data-read-only-databases));
- a stored version that is not a non-negative integer is refused.

SettingsKit owns the `version` key of the saved table. Migrations run before the layout is created, so a step may restructure a table written by a pre-SettingsKit version of the addon.

**A step must not keep a reference to the table it was given once it returns.** That table is the copy; its contents move into the saved table and the copy itself is dropped, so a write to it afterwards reaches nothing that is saved. The tables inside it are the ones now saved, but they are the database's from then on: change saved data through the views.

The copy keeps the saved table's shape: a table reached through two keys is copied once and both keys hold the copy, cycles are preserved (a reference to the table the step received becomes a reference to the saved table), keys are used as they are, only `next`, `rawget` and `rawset` touch the tables (no metamethod runs, and no metatable is copied: a saved variable cannot hold one), and a secret value is carried over as it is. The walk keeps its own work list, so no nesting depth overflows the Lua stack.

**Cost.** Every pending step with a function costs one deep copy of the saved table and one walk of the result; nothing is copied when no step is pending, which is every `Open` after the first one of a new addon version. Measured on host Lua 5.1 (2026-09-25): a saved table of 10,000 profiles, each holding nested tables (about 50,000 tables and 120,000 entries in all), costs about 26 ms per pending step, 78 ms for three.

## Views: `db.<scope>`

`db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` and `db.profile` are **views**: empty tables whose metatable reads and writes the saved table behind them. `getmetatable(view)` returns `"SettingsKit.View"`.

A view reads through tables (revision 14): its metatable's `__index` is the table of its child views, the saved table and its defaults chained together, so the VM answers `db.profile.scale` without calling any SettingsKit function, as a read of an AceDB-3.0 table is answered. Writes still reach the view's `__newindex`, because the view itself stays empty. A view is built by its first use: `Open` gives each scope its view and nothing behind it, and a record's field views are built when first read or written, so a database whose scopes or sections are never used never pays for their views. A view whose plain-table default (an array) is not stored yet reads through a SettingsKit function until that default's first read stores its copy; see [`INTERNALS.md`](INTERNALS.md#read-through-chains).

### Reads

| Declared field | Saved value present | Nothing saved |
|---|---|---|
| a scalar (string, number, boolean, enum) | the saved value | the default, or `nil` |
| a `table` (record) | a view of the saved table | a view reading the defaults, when the field has a default; otherwise `nil` |
| a `map` (keyed section) | a view of the saved table | a view reading the default entries, when the field has a default; otherwise `nil` |
| an `array`, or `any`, `oneOf`, `custom` holding a table | the saved table itself | **a copy of the default, stored on this first read** — except inside a keyed-section entry that is not saved yet, where the copy is returned without being stored |
| undeclared (on an open or closed record) | the saved value | `nil` |

A saved value that is not a table where the schema declares a `table` or `map` (a hand-edited or corrupted file, `profiles.Default.frame = 5`) reads as if nothing were saved: the default view, or `nil` without a default. It stays in the saved table until the next write through that view replaces it with a table. A plain-table default read below it is returned without being stored, as inside an unsaved keyed-section entry.

A record view reads each field from the saved table, then from the defaults: a record default filled with its own field defaults, the way `schema:Apply` fills it. A keyed-section view reads a key from the saved table, then from the section's own default entries, then from its **wildcard default** — the default of `optional(...)` on the map's `values` — so `db.profile.auras[118].shown` is `true` for a spell ID nothing was ever saved for. A `nil` or NaN key reads `nil`: no saved table can hold either. Views of the same record or entry are the same table every time you read them.

Reading a default never writes, with the one exception in the table: an array (or other plain table) default is copied into the saved table on first read, so that editing it in place cannot change the default for the rest of the session. `Compact` removes the copy again while it still equals the default. A [read-only database](#newer-stored-data-read-only-databases) returns the copy without storing it.

**A read never creates a keyed-section entry.** Reading `db.profile.colors[spellId]` for a key nothing was saved for returns the default (a view for a record, a fresh copy for a plain table, not stored) and stores nothing, whatever the key and however many keys are read: the key may be one the key schema refuses, and the section may be full. Only a validated write creates an entry, after the key and the section's `max` were checked. Edits to such a copy are lost; assign the table to store it.

### Writes

`view[key] = value` runs, in order:

1. **Read-only refusal.** A [read-only database](#newer-stored-data-read-only-databases) refuses every write: `SettingsKit (MyAddonDB) profile.frame is read-only: the saved table has version 9, newer than options.version 2; pass options.allowNewerData = true to SettingsKit:Open to write it`.
2. **Value refusal.** A secret key, a secret value, or a table containing a secret anywhere raises `SettingsKit (MyAddonDB) profile.name refused a secret value: saved variables never hold secret values`. Every table value is scanned (to SchemaKit's `maxDepth` levels, 16 by default, and at most `maxScannedEntries` entries, 65536 by default; a larger table is refused too), on every client, and is also refused when it or any table inside it is a **view** (`db.profile.b = db.profile.a` would alias `a` and let writes through `b` bypass validation) or carries a **metatable** (the client saves neither). Nothing is stored.
3. **Schema check.** The value is checked where it is written, against the scope's schema, and a failure raises with SchemaKit's text: `SettingsKit (MyAddonDB) profile.frame.x: expected number, found string`. An undeclared field of a closed record is refused the same way.
4. **Bounds.** A write that adds an entry to a keyed section already holding `max` entries raises `SettingsKit (MyAddonDB) profile.auras: expected at most 256 entries`.
5. **Store.** Missing tables on the way are created. Writing `nil` removes the saved value, so the field reads its default again.
6. **Signal.** The scope's `OnChange` signal fires.

Every refusal is raised at the writing line and stores nothing. A table you assign is stored as it is, by reference: later changes through your own reference to it are not validated. Read the field back to change it through a view.

### Views hold their saved tables

Each view holds the saved table it reads and writes (revision 7), instead of finding it from the saved variable on every access. Every SettingsKit mutation that can change which table a view finds tells the database, and each view finds its table again on its next access: a write through a view that stores, replaces or removes a table or creates the tables on its path, `SetProfile` to a new profile, `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase`, `Compact` (also at logout), `Resync` and the first read of a plain-table default that creates tables on its way. Migrations run before the views exist. So nothing SettingsKit does is ever answered from a table it replaced, emptied or removed, in any scope, through detached views and in read-only databases too.

**Direct edits of the saved variable after `Open` need `db:Resync()`.** Changing `MyAddonDB` yourself (not through a view or a database method) once the database is open is not something SettingsKit sees:

- a scalar you change inside a table a view already holds is read at once, because the view reads that very table;
- a table you add, replace or remove (`MyAddonDB.profiles.Default.frame = { x = 3 }`), or a metatable you set on a saved table, is **not** seen by views that already found their tables: they keep reading, and writing into, the tables they hold, and a write into a table you detached from the saved variable is not saved.

Call `db:Resync()` after such an edit, before the next access through a view. Edits made before `Open` need nothing. A saved table carrying a metatable of its own when SettingsKit finds it is read with `rawget` and never invokes it; one you give a metatable after the view found it is read through that metatable until `Resync`.

### `db:Resync()`

Makes every view of this database find its saved table again, so the direct edits made since `Open` (or the last `Resync`) show through views, getters and `Pairs`. Allowed on a read-only database; it writes nothing (a saved table it finds gets SettingsKit's metatable, which the client never saves). It costs one lookup per nesting level for each view built so far, now. Not needed after anything SettingsKit does itself.

### What a view cannot do

- `pairs`, `next` and `#` see an empty table: Lua 5.1 has no `__pairs` or `__len` for tables. Use `db:Pairs(view)` instead.
- A view of a deleted profile, or of any profile after `ResetDatabase`, is **detached**: it reads defaults and refuses writes with `... belongs to a profile that was deleted or reset away`.
- Reading a view with a secret key raises at the reading line: the client refuses it (`attempted to index a table that cannot be indexed with secret keys`) before any metamethod runs, so SettingsKit asks nothing (revision 14, core decision 19b).

## Newer stored data: read-only databases

When the stored `version` is greater than `options.version`, a newer version of the addon wrote the saved table, and this one does not know its layout. By default `Open` then opens the database **read-only**:

- nothing is migrated and nothing is written by `Open`: no layout section, no profile table, no profile choice, and the stored version stays as it is;
- reads work as usual, over whatever the newer version saved; a plain-table default is handed out as a copy and not stored;
- every write raises at the writer's line and changes nothing: a write through any view, `SetProfile` (even to the current profile), `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase` and `Compact`. A view write raises `SettingsKit (MyAddonDB) profile.frame is read-only: <reason>`, a method `SettingsKit.Database:SetProfile cannot change MyAddonDB, which is read-only: <reason>`, where `<reason>` is `the saved table has version 9, newer than options.version 2; pass options.allowNewerData = true to SettingsKit:Open to write it`. No signal fires;
- `db:Validate` answers `false` and the same view message;
- the logout compaction skips the database;
- `db:IsReadOnly()` returns `true`.

`Open(name, schema, { version = 2, allowNewerData = true })` opens such a table writable, as revisions before 5 did. Its stored version is still never lowered: nothing is migrated, writes leave `version` as it is, and `ResetDatabase` stamps the newer stored version rather than `options.version`. Opt in only when this version of the addon can write data a newer one reads.

The mode is decided by the first `Open` of the name; a later `Open` returns the same database and ignores its options.

### `db:IsReadOnly()`

`true` when the database was opened over newer data without `allowNewerData`, `false` otherwise. It never changes for the session.

## Profiles

The current profile is chosen per character and recorded in the saved table (`profileKeys`) when `SetProfile` is called. All profile methods work whether or not a `profile` schema is declared; `db.profile` exists only when it is.

### `db:SetProfile(name)`

Switches to profile `name`, creating an empty one when it does not exist, records it for this character (when the character key is available), points `db.profile` at a view of it and fires `OnProfileChanged(db, name, previous)`; from revision 15 it fires `OnProfileShutdown(db, previous)` first, before anything changes, and `OnNewProfile(db, name)` before `OnProfileChanged` when it created the profile. Returns `true`, or `false` without a signal when `name` is already current. `db.profile` is a different table after a switch; a view kept from before keeps reading and writing the profile it was made for.

Profile names are non-empty strings of at most `maxProfileNameLength` bytes (64 by default) with a character other than whitespace, never secret. A stored choice longer than the current limit is ignored at `Open`.

### `db:GetProfiles()`

A fresh array of every profile name, sorted with `<`, always including the current one.

### `db:CopyProfile(from, options?)`

Replaces the current profile's contents with a deep copy of profile `from`, fires `OnProfileCopied(db, from, current)` and returns `true`. The current profile keeps its table, so `db.profile` is unchanged. Copying the current profile onto itself, a profile that does not exist, or one nesting more than SchemaKit's `maxDepth` tables (16 by default, read when `CopyProfile` runs) is refused. Revision 15: `options` may be `{ missingOk = true }` (AceDB-3.0's `silent`), and a `from` that does not exist then returns `false` and changes nothing.

### `db:ResetProfile()`

Empties the current profile in place, so every field reads its default, and fires `OnProfileReset(db, name)`.

### `db:DeleteProfile(name, options?)`

Deletes a profile other than the current one, fires `OnProfileDeleted(db, name)` and returns `true`; with `{ missingOk = true }` (revision 15) a `name` that does not exist returns `false` instead of raising. Characters whose recorded choice was `name` lose it and start on the default profile at their next `Open`. Deleting the current profile or one that does not exist is refused.

### `db:ResetDatabase()`

Empties the saved variable in place, stamps `options.version` again when the database was opened with one, recreates the layout, switches to the default profile, fires `OnDatabaseReset(db)` and `OnNewProfile(db, name)` (revision 15), `OnProfileReset(db, name)` and, when the profile name changed, `OnProfileChanged(db, name, previous)`. Every profile view obtained before is detached, and `db.profile` is a new view. The scope views of `global`, `char` and the rest stay valid.

## Spec profiles

Revision 11, what LibDualSpec-1.0 gives AceDB-3.0 databases. From revision 16 they are the SpecProfiles part (`parts/SettingsKit-SpecProfiles.lua`); without it `GetSpecIndex`, `SetSpecProfile`, `GetSpecProfile` and `ApplySpecProfile` raise the not-loaded message, `Open` applies no assignment, and the core still keeps the `specProfiles` section right: it is created and checked, `ResetDatabase` empties it and `DeleteProfile` forgets the assignments that name the deleted profile. With an EventKit whose unit events are its Units part (EventKit revision 23 and later), switching by itself also needs that part (`EventKit:HasPart("Units")`). A character assigns a profile to a **spec index**; when the index changes, the database switches to that profile with its own `SetProfile`, so `db.profile`, getters and `OnProfileChanged` follow as for any switch.

```lua
db:SetSpecProfile(1, "Healing")  -- the first specialization (Retail), or the first talent group (Classic Era)
db:SetSpecProfile(2, "Damage")
db:SetSpecProfile(2, nil)        -- clear the assignment
```

The spec index is:

| Client (`WOW_PROJECT_ID`) | Index | Read with |
|---|---|---|
| Retail (`1`), Mists of Pandaria Classic (`19`) | the specialization, 1 to the class's count | `C_SpecializationInfo.GetSpecialization()`, count from `C_SpecializationInfo.GetNumSpecializationsForClassID` and the class ID `UnitClass("player")` answers third |
| every other client, also without `WOW_PROJECT_ID`: Classic Era, Season of Discovery, Hardcore, Burning Crusade Classic | the active talent group, where dual talent specialization is the switching mechanism | `C_SpecializationInfo.GetActiveSpecGroup()`, count from `GetNumTalentGroups()` (at least the active group) |

There is no index while `C_SpecializationInfo.IsInitialized()` answers anything but `true`, while the player has no specialization (Retail's starter specialization, whose index is above the class's count), for a talent group above 8, without `C_SpecializationInfo`, or when the client answers a secret value. Without an index nothing switches.

**Switching** needs EventKit (found with `Registry:Find("eventKit", 1)`). One listener for the session is connected the first time a database has an assignment, at `Open` or `SetSpecProfile`, so an addon that never uses spec profiles costs EventKit nothing. It runs on `PLAYER_ENTERING_WORLD`, `ACTIVE_TALENT_GROUP_CHANGED`, `PLAYER_LEVEL_CHANGED` and `PLAYER_SPECIALIZATION_CHANGED` for the unit `player` (all four documented on Retail, Mists of Pandaria Classic and Classic Era), reads the index once and applies it to every open database whose character has an assignment, unless that database already applied that index; a database whose character has no assignment just records the index, so an assignment made later for an index the character comes back to applies then (revision 12). So an event that changes nothing never undoes a manual `SetProfile`; the next change of index applies the assignment again. `Open` applies the assignment for the current index at once, so after `/reload` the assignment wins over a manual choice. A database without an assignment for the new index keeps its profile. A read-only database never switches. Without EventKit, call `db:ApplySpecProfile()` yourself, for example from your own `PLAYER_SPECIALIZATION_CHANGED` handler.

The switch runs the database's `OnProfileChanged` listeners inside the event; a listener that touches protected frames must wait for the end of combat itself.

### `SettingsKit:GetSpecIndex()`

Returns `index|nil, count, kind`: the current index, the number of indexes this character has (`0` when unknown) and `"specialization"` or `"talentGroup"`. An options screen offers one choice per index from 1 to `count`; `OptionsKit:ProfileOptions` does that (see OptionsKit's API).

### `db:SetSpecProfile(index, name?)`

Assigns profile `name` to `index` (an integer from 1 to 8) for this character, or clears the assignment when `name` is `nil`, and applies it at once when `index` is the current index (creating the profile, as `SetProfile` does). Returns `true`, or `false` without recording anything when the character key is unavailable (see [Host facilities](#host-facilities)). Raises at the caller's line for a bad index or profile name, a secret one, a read-only database, and a `specProfiles` section that is not a table. Recording an assignment changes no current profile unless its index is the current one.

### `db:GetSpecProfile(index)`

The profile assigned to `index` for this character, or `nil`. Works on a read-only database.

### `db:ApplySpecProfile()`

Switches to the profile assigned to the current index; returns `true` when it switched, `false` when there is no index, no assignment, the assignment already is the current profile, or the database is read-only.

### Assignments and the other profile methods

`DeleteProfile` removes every character's assignments naming the deleted profile, `ResetDatabase` empties `specProfiles`, `CopyProfile` and `ResetProfile` leave assignments alone, and a manual `SetProfile` changes none.

### Migrating from LibDualSpec-1.0

| LibDualSpec-1.0 | SettingsKit |
|---|---|
| `LibDualSpec:EnhanceDatabase(db, name)` | Nothing to call: every database has the methods. |
| `db:SetDualSpecProfile(name, spec)` | `db:SetSpecProfile(spec, name)` (the order of the arguments differs). |
| `db:GetDualSpecProfile(spec)` | `db:GetSpecProfile(spec)`; `nil` instead of the current profile when nothing is assigned. |
| `db:SetDualSpecEnabled(true)`, `db:IsDualSpecEnabled()` | No flag: an assignment is what enables switching for its index; clear assignments to stop. |
| `db:CheckDualSpecState()` | `db:ApplySpecProfile()`, needed only without EventKit. |
| `LibDualSpec:EnhanceOptions(options, db)` | `OptionsKit:ProfileOptions(db)` shows one choice per index (OptionsKit revision 11). |
| Stored in the AceDB namespace `LibDualSpec-1.0`, `char.enabled` and `char[spec]` | Stored in `specProfiles["<name> - <realm>"][spec]`; not imported automatically. |

## Change signals

### `db:OnChange(scope, callback)`

`scope` names a declared, available scope. After every validated write through that scope's views, `callback(db, scope, key, value, path)` is called with the key and value written (`nil` when a field was reset) and `path`, the path of the table holding the key relative to the scope: `""` for `db.profile.scale`, `"frame"` for `db.profile.frame.x`, `"auras[118]"` for `db.profile.auras[118].shown`.

Keys in `path`, and in every SettingsKit message, are rendered the way SchemaKit renders the keys of its failure paths: an identifier of at most `pathKeyLimit` bytes (32 by default) is joined with a dot, numbers and booleans are bracketed, and any other string is quoted in brackets with `|` doubled (so no World of Warcraft `|T`, `|H` or `|c` escape sequence survives), `\` and `"` backslash-escaped and every other control byte shown as `\ddd`. A longer key is cut at `pathKeyLimit` bytes, never inside a UTF-8 sequence, and marked with `...`, so `path` is for display and logging; use `key` and the view itself to find the value. A key that is a table, a function or userdata appears as its type (`[table]`). The path in a schema refusal (`profile.frame.x: expected number, found string`) is SchemaKit's own failure path, so its keys follow SchemaKit's `pathKeyLimit` rather than this one.

The signal fires after the value is stored. SignalKit's dispatch rules apply: listeners run in connection order, and a listener that raises stops the dispatch and propagates to the writing line.

### Profile signals

| Method | Callback |
|---|---|
| `OnProfileChanged(callback)` | `callback(db, name, previous)` |
| `OnProfileCopied(callback)` | `callback(db, from, name)` |
| `OnProfileReset(callback)` | `callback(db, name)` |
| `OnProfileDeleted(callback)` | `callback(db, name)` |

### Lifecycle signals

Revision 15, AceDB-3.0's other database callbacks. Each signal is created by its first listener, so a database nobody listens to allocates nothing.

| Method | Callback | Fires |
|---|---|---|
| `OnNewProfile(callback)` | `callback(db, name)` | when SettingsKit creates the current profile's table: `SetProfile` (spec switches included), `ResetDatabase`, and `CopyProfile` or `ResetProfile` when the current profile's table was missing; after the change, before the method's other signals. |
| `OnProfileShutdown(callback)` | `callback(db, name)`, `name` the profile being left | at the start of a `SetProfile` that switches, before anything changes: `db.profile` is still the old profile. A listener that raises stops the switch with nothing changed. AceDB-3.0 passes no name. |
| `OnDatabaseShutdown(callback)` | `callback(db)` | at `PLAYER_LOGOUT`, with EventKit, for every database in the order opened, before it is compacted, so a listener's last writes are compacted too; also for a read-only database (not compacted). A listener that raises is reported through the host error handler and stops nothing else. Without EventKit nothing fires: use LifecycleKit's `OnShutdown`. |
| `OnDatabaseReset(callback)` | `callback(db)` | first in `ResetDatabase`, before `OnNewProfile`, `OnProfileReset` and `OnProfileChanged`. |

`Open` creates a new character's first profile before any listener can connect, so it fires no `OnNewProfile`. **`db:IsNewProfile()`** answers it instead: whether this session created the current profile's table (by `Open`, `SetProfile`, a spec switch or `ResetDatabase`). A database opened by revision 14 before an in-place upgrade answers `false` for the profile its `Open` created.

```lua
local db = SettingsKit:Open("MyAddonDB", schema)
if db:IsNewProfile() then applyPreset(db.profile) end
db:OnNewProfile(function(_, name) applyPreset(db.profile) end)
```

## Namespaces

Revision 15, with the part `parts/SettingsKit-Namespaces.lua` loaded after the core: AceDB-3.0's `RegisterNamespace` and `GetNamespace`. A namespace is a database of its own schema over `MyAddonDB.namespaces[name]`, for a module that keeps its own settings, and it follows its parent's profile.

```lua
local bars = db:RegisterNamespace("Bars", {
  profile = S.table({ fields = { size = S.optional(S.number({ min = 1, max = 100 }), 36) } }),
})
bars.profile.size = 40          -- validated, stored in MyAddonDB.namespaces.Bars.profiles.Default
db:SetProfile("Raid")           -- bars:GetProfile() is "Raid" too
```

### `db:RegisterNamespace(name, schema)`

Returns the namespace `name` of this database. `name` is a non-secret string of 1 to 64 bytes with a character other than whitespace; `schema` is what `Open` takes, compiled the same way and sharing its compiled plans. Registering a name again with the same schema table returns the same namespace; another schema raises. It refuses at your line: a namespace receiver (namespaces do not nest), more than `maxNamespaces` namespaces (256 by default), and a saved `namespaces[name]`, or a section of a declared scope inside it, that is not a table. In a writable database it creates `namespaces[name]`, the sections of the scopes it declares and the current profile's table; a read-only database creates nothing, and the namespace reads what is saved or its defaults and refuses every write. The scope keys are read now, as `Open` reads them; `char` is the parent's key.

### `db:GetNamespace(name, options?)`

Returns the registered namespace `name`. A name nobody registered raises `SettingsKit.Database:GetNamespace name names no registered namespace` at your line, unless `options` is `{ missingOk = true }` (AceDB-3.0's `silent`), which returns `nil`.

### What a namespace is

A namespace is a SettingsKit database: views (read at the same cost), validated writes, `OnChange`, `Getter`, `Validate`, `Pairs`, `Compact` (this namespace only), `Resync`, `IsReadOnly` (its parent's), `GetProfile`, `GetProfiles` and `GetSpecProfile` (its parent's), `IsNewProfile`, and every profile and lifecycle signal of its own. `ResetProfile` on a namespace empties only that namespace's current profile, as on an AceDB-3.0 namespace. `GetSavedVariable` answers the parent's global name; messages name the namespace, `SettingsKit (MyAddonDB namespace Bars) ...`. Its parent owns its profile: `SetProfile`, `CopyProfile`, `DeleteProfile`, `ResetDatabase`, `SetSpecProfile` and `ApplySpecProfile` on a namespace raise `SettingsKit.Database:SetProfile cannot be called on MyAddonDB namespace Bars; call it on the database of MyAddonDB`.

### The parent's profile operations

`SetProfile` (spec switches included), `CopyProfile`, `ResetProfile`, `DeleteProfile` and `ResetDatabase` on the parent change every namespace, in three steps:

1. Every refusal is decided before anything changes, the depth of every namespace's copy included, and `OnProfileShutdown` fires on the parent, then on each namespace in registration order.
2. The parent changes, then every namespace (no listener runs in between): a switch points each at the profile, creating its table when the namespace declares `profile`; a copy copies each namespace's `profiles[from]` (an absent one empties the target, as AceDB-3.0 does); a reset empties each namespace's current profile; a delete removes each namespace's `profiles[name]` and detaches its views of it; `ResetDatabase` gives each namespace a new saved table and a new `profile` view. Namespaces saved in `namespaces` that nobody registered this session get the raw part of a copy, reset or delete, as AceDB-3.0 gives them.
3. The namespaces' signals fire, signal by signal, each over every namespace in registration order, then the parent's. A listener that raises reaches your line with every change already made.

The parent's `Compact` compacts every namespace too and returns the total. At logout each namespace's `OnDatabaseShutdown` fires after its parent's, the namespaces are compacted with the parent, and then empty profiles, empty sections and empty namespace tables inside `namespaces` are removed (the parent's own layout stays as `Open` made it).

Without the part, reading `db.RegisterNamespace` or `db.GetNamespace` raises at the reading line `SettingsKit.Database:RegisterNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\parts\SettingsKit-Namespaces.lua`.

## `db:Pairs(view)`

`for key, value in db:Pairs(db.profile) do ... end` iterates a view of this database: first every key that has a default (a record's field defaults, or a keyed section's own default entries — never its wildcard, which covers every possible key), then every saved key without a default, including undeclared ones. Each value is what reading `view[key]` returns, so a record field yields its child view. Order within each phase is `next` order. The iterator is stateless and allocates nothing beyond what the reads themselves do (the first read of a plain-table default stores a copy, as above). As with `pairs`, do not add keys to the view while iterating it. Anything but a view of this database is refused at your line.

## `db:Getter(source, key)`

```lua
local getScale = db:Getter("profile", "scale")       -- follows the current profile
local getX = db:Getter(db.profile.frame, "x")          -- reads that frame view for good
for index = 1, #frames do
  frames[index]:SetScale(getScale())
end
```

Returns a function that reads `key` from a view: every call returns exactly what `view[key]` returns at that moment. `source` is a view of this database, which the getter reads for good (a view of a profile keeps reading that profile after `SetProfile`, as the view itself does), or a scope name, whose current view the getter reads (after `SetProfile`, the new profile's).

Since revision 14 a view read costs what a plain table read costs (see [Views](#views-dbscope)), so a getter is one Lua call plus that read, `view[key]` or `db[scope][key]`, and never faster than reading the view yourself: **in a hot loop, read the view.** A getter is for handing a reader to code that should not hold the view, and keeps every guarantee a view read has: defaults and wildcard defaults, every SettingsKit mutation followed, detached views reading defaults, read-only databases read without any write, the first read of a plain-table default storing its copy, direct edits shown after `Resync`. It reads through the view, so it keeps working across every in-place upgrade; getters made by revisions 7 to 13 keep their own closures and keep working too.

`Getter` refuses at your line a secret key (`SettingsKit.Database:Getter key must not be a secret value`), a `nil` or NaN key, a secret scope, a scope that is not declared and available, and a `source` that is neither a scope name nor a view of this database. It allocates the getter; a call allocates nothing. Measured on host Lua 5.1 (2026-11-15, revision 14): about 26 ns for a getter following a scope and 19 ns for a field of an unsaved keyed-section entry, against 10 to 22 ns for the view read itself and 39 ns and 25 ns for revision 13's getters.

## `db:Validate(scope, path, value)`

```lua
local ok, message = db:Validate("profile", { "auras", 118, "shown" }, false)
local ok, message = db:Validate("profile", "frame.x", 120)
```

Returns `true` when writing `value` at `path` in `scope` would be accepted, and `false, message` otherwise, where `message` is exactly the text the refused write would raise, without the `file:line:` prefix. It runs every check a write through a view runs, in the same order — the read-only refusal, the secret refusal, the view and metatable refusal, the schema check, and the key schema and `max` of every keyed section on the path — and writes nothing: no saved table, no keyed-section entry, no `OnChange`. A `profile` path is checked against the current profile.

`path` is either:

- **an array of keys**, `{ "auras", 118, "shown" }`, used exactly as given. A valid check of a value that is not a table allocates nothing, provided the entry views on the path are alive (a table value costs the one table `SchemaKit:GetLimits()` returns, read to bound its scan): entry views are cached while referenced, and a collection may drop an unreferenced one, which the next check rebuilds;
- **a dotted string**, `"auras.118.shown"`. Each segment is a string key, except that a segment indexing a keyed section whose key schema is a number becomes a number when it reads as one. Splitting the string allocates the segments.

Every step but the last must lead to a record or keyed-section field; otherwise the result is `false, "SettingsKit (MyAddonDB) profile.scale is not a record or keyed section"`. A secret, `nil` or NaN key on the path gives `false` and the matching message. A scope that is not declared and available, an empty array, an empty segment (`"frame..x"`) or a path of another type raises at your line.

## `db:Compact()`

Walks every declared scope — every stored character, realm, class and faction entry and every profile, not only the current ones — and removes:

- each saved value deeply equal to its default (a map entry is compared with the section's own default entry, then with the wildcard default);
- each record or keyed-section table left empty, when it has a default to fall back to. A table without a default stays, because removing it would turn its view into `nil`;
- each empty character, realm, class or faction entry. Empty profiles stay: they are still profiles.

Returns how many values and tables it removed. With EventKit registered, every database compacts itself on `PLAYER_LOGOUT`, through one listener SettingsKit connects once and shares between all databases, in the order they were opened; a compaction that raises there is reported through `geterrorhandler()` rather than raised into EventKit's dispatch, and the other databases are still compacted. Values written after that compaction are saved as they are. A read-only database refuses `Compact` and is skipped at logout.

## Secret values

Every value SettingsKit takes from outside is asked `issecretvalue` before it is compared, indexed, measured or formatted: written keys and values, `Getter` keys, `Validate` and `OnChange` scope names, option values and keys, profile and namespace names, `missingOk`, and every answer of the client (the scope keys, including the revision 15 ones, and the spec index). A secret is refused at the caller's line with a message that names the parameter and never formats the value, or, for a client answer, makes its scope unavailable. Reads are not probed: the client refuses a secret key before any metamethod runs (revision 14, below).

## Limits

Every bound SettingsKit keeps holds unless you open it. A bound on something you create is an option; a bound on text every addon's databases render is a shared limit.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxScannedEntries` | `65536` | `Open(name, schema, { maxScannedEntries = n })` | yes | none: the scanned table is your own data |
| `maxNamespaces` | `256` | `Open(name, schema, { maxNamespaces = n })` (revision 15) | yes | none: the namespaces are your own modules; an addon that registers one per module it loads (a namespace per boss module, say) raises it |
| `maxProfileNameLength` | `64` | `SettingsKit:SetLimits({ maxProfileNameLength = n })` | no | `64` to `1024`: profile names are typed by players and shown in option screens and dropdowns; below 64 a `"<name> - <realm>"` character profile may not fit |
| `pathKeyLimit` | `32` | `SettingsKit:SetLimits({ pathKeyLimit = n })` | no | `1` to `1024`: paths show keys other players can send, and every message must stay short and printable |
| table depth of a scanned, compared or copied value, and of the views a database builds | SchemaKit's `maxDepth` (16 by default) | `SchemaKit:SetLimits{ maxDepth = n }`, read when each scan, comparison, `CopyProfile` or `Open` starts | no | follows SchemaKit's ceiling of 64: every one of these walks recurses once per nested table |

`maxScannedEntries` bounds the scan every table value goes through before it is stored: secret values, views and metatables anywhere inside it. The scan is what keeps a hostile or cyclic table from stalling the writer, so a database opened with `SettingsKit.UNBOUNDED` scans a table of any size to its end; it still stops at the depth bound. A database's views and defaults are built to the `maxDepth` in force when it is opened; writes, compaction and `CopyProfile` use the value in force when they run. It is kept per database, and like every other option it is read by the first `Open` of a name only.

```lua
SettingsKit:SetLimits({ maxProfileNameLength = 128 })
local limits = SettingsKit:GetLimits() -- a fresh table: { maxProfileNameLength = 128, pathKeyLimit = 32 }
```

`SetLimits` accepts any subset and raises at the caller, before changing anything, on a secret value (`SettingsKit:SetLimits limits.pathKeyLimit must not be a secret value`, asked before the key indexes anything or the value is compared), on an unknown name (`SettingsKit:SetLimits limits.maxDepth is not a recognised limit; it accepts maxProfileNameLength, pathKeyLimit`, revision 16; a secret key, which no client can store, is named `limits.<secret>`; a key that is not a string, number or boolean is named by its type, `limits.<table>`, so its `__tostring` never runs), on `SettingsKit.UNBOUNDED` (naming the reason) or on a value outside the range: `SettingsKit:SetLimits limits.pathKeyLimit must be an integer from 1 to 1024`. **The limits are shared by every consumer in the session**: every embedded copy and every addon's databases use one set. A library should rely on the defaults; an addon that raises a limit raises it for everybody. A changed `pathKeyLimit` applies to paths rendered afterwards; the paths of views built earlier keep their rendering.

`SettingsKit.UNBOUNDED` and the shared limits live in the package state, so every embedded copy publishes the same sentinel and an in-place upgrade keeps the limits a consumer set.

## Error behaviour

Argument failures report the line that called SettingsKit, never a line inside it, and name the parameter without formatting the value: `SettingsKit:Open options.version must be a positive integer`, `SettingsKit.Database:DeleteProfile cannot delete the current profile`. Calling `Open`, `SetLimits`, `GetLimits` or `GetSpecIndex` on anything but the facade (`SettingsKit.Open(...)`) raises `SettingsKit:Open must be called on the SettingsKit facade; use SettingsKit:Open(...)`. Calling a method on something that is not a database raises `SettingsKit.Database:SetProfile must be called on a SettingsKit database`. View refusals report the writing (or reading) line and are prefixed with the saved-variable name, `SettingsKit (MyAddonDB) ...`. Writing a field of the database object itself raises `SettingsKit databases are read-only; write through db.<scope> instead`.

Where a value can come from outside SettingsKit (an argument, an option, a saved-variable entry, a schema default), its absence is tested with `type(value) == "nil"`, never by comparing it with `nil`: that is the repository rule, which never compares anything. The one exception, approved by the owner and documented in `docs/CONTRIBUTING.md`, is a getter's fast path (revision 8), which tests the value it reads from the saved table with `value ~= nil` and only returns it. On a client with secret values a secret compared with a value of its own type raises, and so does a secret used as a key; a comparison with `nil` happens not to raise (measured on Retail 12.1.0 b69933). A saved value, a secret included, is read back as it is stored. The secret refusals above, with their exact messages, are the only new errors this adds:

- `SettingsKit:Open options.version must not be a secret value`
- `SettingsKit:Open options.maxScannedEntries must not be a secret value`
- `SettingsKit:Open options.migrations must not have a secret key`
- `SettingsKit:SetLimits limits must not have a secret key` (revisions up to 15; from revision 16 such a key is named `limits.<secret>` in the unknown-name refusal)
- `SettingsKit:SetLimits limits.<name> must not be a secret value`
- `SettingsKit.Database:OnChange scope must not be a secret value` and `SettingsKit.Database:Validate scope must not be a secret value`, asked before the scope name indexes the database's scopes (revision 4 and later)
- `SettingsKit databases cannot be read with a secret key`, raised at the reading line by `db[key]` before the key indexes the method table (revisions 4 to 13; removed in revision 14, see below)
- `SettingsKit:Open options.allowNewerData must not be a secret value` (revision 5 and later)

Revision 5 adds these refusals:

- `SettingsKit:Open options.allowNewerData must be a boolean` and `SettingsKit:Open options.allowNewerData requires options.version`
- `SettingsKit (<name>) <view path> is read-only: <reason>` for a write through a view of a read-only database, and `SettingsKit.Database:<method> cannot change <name>, which is read-only: <reason>` for `SetProfile`, `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase` and `Compact`, each at the caller's line; `<reason>` is `the saved table has version <stored>, newer than options.version <version>; pass options.allowNewerData = true to SettingsKit:Open to write it`
- `SettingsKit.Database:IsReadOnly must be called on a SettingsKit database`
- `SettingsKit:Open migration <step> of <name> failed: <name>.<section> must be a table`, when the last migration step leaves a layout section that is not a table

Revision 7 adds these refusals, each at the caller's line:

- `SettingsKit.Database:Resync must be called on a SettingsKit database` and `SettingsKit.Database:Getter must be called on a SettingsKit database`
- `SettingsKit.Database:Getter key must not be a secret value`, asked before the key is compared or used, and `SettingsKit.Database:Getter key must not be nil or NaN`
- `SettingsKit.Database:Getter scope must not be a secret value`, `SettingsKit.Database:Getter scope must name a declared, available scope` and `SettingsKit.Database:Getter source must be a scope name or a view of this database`

Revision 16 adds these refusals, each at the caller's line:

- `SettingsKit:HasPart must be called on the SettingsKit facade; use SettingsKit:HasPart(...)`, `SettingsKit:HasPart partName must not be a secret value`, `SettingsKit:HasPart partName must be a string`
- `<member> is in SettingsKit's <Part> part, which is not loaded: add settingsKit\parts\SettingsKit-<Part>.lua`, for `SettingsKit:GetSpecIndex` and `SettingsKit.Database:SetSpecProfile`, `GetSpecProfile`, `ApplySpecProfile` (SpecProfiles), and `RegisterNamespace`, `GetNamespace` (Namespaces)
- `SettingsKit:Open plain defaults are in SettingsKit's Defaults part, which is not loaded: add settingsKit\parts\SettingsKit-Defaults.lua` (and `SettingsKit.Database:RegisterNamespace plain defaults ...`)
- the plain-defaults refusals listed under [Plain defaults](#plain-defaults)
- `SetLimits`: the unknown-name refusal names the accepted limits (`...; it accepts maxProfileNameLength, pathKeyLimit`)

A host error handler that raises while a logout compaction failure is reported no longer propagates: the failure is printed (the shared `reportError` block). `Open`'s `savedVariable` and every profile name are asked `issecretvalue` before their type is tested, so a secret is named as secret whatever its type.

Revision 11 adds these refusals, each at the caller's line:

- `SettingsKit:GetSpecIndex must be called on the SettingsKit facade; use SettingsKit:GetSpecIndex(...)`
- `SettingsKit.Database:SetSpecProfile must be called on a SettingsKit database`, and the same for `GetSpecProfile` and `ApplySpecProfile`
- `SettingsKit.Database:SetSpecProfile index must not be a secret value` and `SettingsKit.Database:SetSpecProfile index must be an integer from 1 to 8`, and the same for `GetSpecProfile`
- `SettingsKit.Database:SetSpecProfile name must be a non-empty string`, `... name must not be a secret value`, `... name must contain a character other than whitespace` and `... name must be at most <maxProfileNameLength> bytes long`
- `SettingsKit.Database:SetSpecProfile cannot change <name>, which is read-only: <reason>`
- `SettingsKit.Database:SetSpecProfile <name>.specProfiles must be a table`, when the section was replaced by something other than a table after `Open`

Revision 14 removes the two read refusals, by core decision 19b: `SettingsKit (<name>) <view path> cannot be read with a secret key` (a view read) and `SettingsKit databases cannot be read with a secret key` (a database read). On the client a secret key raises before any `__index` metamethod runs (measured on Retail 12.1.0 build 69933, `docs/EMBEDDING.md`), so neither probe could ever fire there; a read with a secret key now raises the client's own error, `attempted to index a table that cannot be indexed with secret keys`, at the same reading line, and the client suite asserts it. Every other secret refusal stays: written keys and values, `Getter`, `Validate`, `Compact`, profile names, scope names and every answer of the client. Revision 14 adds one refusal at the caller's line: `SettingsKit:GetCharacterKey must be called on the SettingsKit facade; use SettingsKit:GetCharacterKey(...)`.

Revision 15 adds these refusals, each at the caller's line:

- `SettingsKit.Database:OnNewProfile must be called on a SettingsKit database` and `SettingsKit.Database:OnNewProfile callback must be a function`, and the same for `OnProfileShutdown`, `OnDatabaseShutdown`, `OnDatabaseReset`; `SettingsKit.Database:IsNewProfile must be called on a SettingsKit database`
- `SettingsKit.Database:CopyProfile options must be a table`, `... options contains unknown field "<field>"`, `... options.missingOk must be a boolean` and `... options.missingOk must not be a secret value`, and the same for `DeleteProfile` and `GetNamespace`
- `SettingsKit:Open options.maxNamespaces must be a positive integer or SettingsKit.UNBOUNDED` and `SettingsKit:Open options.maxNamespaces must not be a secret value`
- `SettingsKit:Open MyAddonDB.race must be a table` (and `factionrealm`, `factionrealmregion`, `locale`), only when the scope is declared; the read of an unavailable added scope raises `SettingsKit (MyAddonDB) db.race is unavailable: UnitRace("player") returned no race when the database was opened` (`factionrealm` and `factionrealmregion`: `UnitFactionGroup("player") or GetRealmName() returned no faction or realm`; `locale`: `GetLocale() returned no locale`)
- `SettingsKit.Database:<method> cannot be called on <name> namespace <namespace>; call it on the database of <name>` for `SetProfile`, `CopyProfile`, `DeleteProfile`, `ResetDatabase`, `SetSpecProfile` and `ApplySpecProfile` on a namespace
- with the Namespaces part: `SettingsKit.Database:RegisterNamespace name must be a non-empty string`, `... name must not be a secret value`, `... name must contain a character other than whitespace`, `... name must be at most 64 bytes long` (and the same for `GetNamespace`); `SettingsKit.Database:RegisterNamespace cannot be called on a namespace: namespaces do not nest` (and `GetNamespace`); `SettingsKit.Database:RegisterNamespace <name> namespace <namespace> is already registered with a different schema table`; `SettingsKit.Database:RegisterNamespace cannot register more than <n> namespaces in <name>; raise options.maxNamespaces in SettingsKit:Open`; `SettingsKit.Database:RegisterNamespace <name>.namespaces.<namespace> must be a table` (and `.<section> must be a table`); the schema refusals of `Open` with `SettingsKit.Database:RegisterNamespace` in place of `SettingsKit:Open`; `SettingsKit.Database:CopyProfile from nests more than <n> tables in <name> namespace <namespace>`
- without the part, at the reading line: `SettingsKit.Database:RegisterNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\parts\SettingsKit-Namespaces.lua` (and `GetNamespace`)
- loading the part without its core: `MoltenCodes SettingsKit part Namespaces requires SettingsKit API 1 to be loaded first`

SettingsKit never tests a value it did not create as a boolean (`if x`, `x and y`, `x or y`, `not x`), which raises on a secret as well: the host identity returns are type-tested and asked about secrecy before they are used, and the only answers it tests (SchemaKit's `Check`, `pcall`) are its dependencies' own booleans.

A secret stored `version` in the saved table is refused as `SettingsKit:Open MyAddonDB.version must be a non-negative integer`, and a secret profile choice in `profileKeys` is ignored (never compared) by `DeleteProfile`, as `Open` already ignored it.

## Performance

| Operation | Cost |
|---|---|
| Reading a field through a view | No SettingsKit call: the VM follows one to three tables (the child views, the saved table, the scalar defaults). No allocation. On host Lua 5.1 (2026-11-15, revision 14) about 10 ns for a saved `db.profile.scale`, 15 ns for a default, 13 ns for `db.profile.frame.x` and 22 ns for `db.profile.auras[118].shown` with nothing saved, against 3.5 to 11 ns for AceDB-3.0's tables (revision 13: 110 to 440 ns). A view whose plain-table default is not stored yet, or whose saved table carries a foreign metatable, reads through one SettingsKit function, about 60 ns. |
| Calling a getter (`db:Getter`) | One Lua call and one view read. No allocation. About 26 ns following a scope on host Lua 5.1 (2026-11-15, revision 14); see [`db:Getter`](#dbgettersource-key). |
| A mutation that changes saved tables (`SetProfile` to a new profile, `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase`, `Compact`, `Resync`, a write that stores or removes a table) | Rebinds the chains of the views it changed (all built views of the database for the methods, the written view's path and subtree for a write): a few table reads per view. |
| Reading a view the first time | Builds that view: its node, its metatable and chain, and a proxy for each of its record fields. A keyed-section entry's view is cached while referenced. |
| A validated write | The same checks and messages in every case. A value that is not a table, written to a declared `string`, `number`, `boolean` or `enum` field through a view that already took one valid write, takes the fused path: the read-only and detached tests, the secret probe of key and value, the field's own rules, SchemaKit's `maxDepth` read without allocating (`SchemaKit:GetLimit`), the bound of any keyed section above, one table write and, once a listener was connected to the scope, one signal dispatch. Any other write, and every refused one, runs one SchemaKit check of a probe holding only the written path. No allocation when the key already exists and the value is not a table; a table value adds the scan of its contents. On host Lua 5.1 (2026-11-15, revision 14) about 0.3 µs for `db.profile.scale = 1.5` and 0.55 µs for `db.profile.frame.x = 3` (revision 13: 0.41 and 0.91 µs). |
| `Open`, `SetProfile` to a new profile | Validates the schema and options, reads the scope keys, creates the missing layout sections and gives each scope a view with nothing behind it yet. The first `Open` of a schema also seals, describes and compiles it; later ones with the same schema reuse that. Signals are created when a listener first connects. On host Lua 5.1 (2026-11-15, revision 14) an `Open` of the benchmark schema over a new saved variable takes about 6.5 µs and allocates about 3.7 KB (revision 13: 10 µs, 8.3 KB; AceDB-3.0: 2 µs, 3.3 KB); an open database with one profile read holds about 3.0 KB beyond its saved variable (revision 13: 3.9 KB; AceDB-3.0: 3.4 KB). |
| `GetProfiles`, `CopyProfile`, `Compact` | Allocate or walk by design; not for hot paths. |
| `SetProfile` between existing profiles, with namespaces | Revision 15: no allocation; each namespace adds its switch (no validation, no `profileKeys` write). On host Lua 5.1 (2026-11-15) about 4.6 µs with 10 namespaces against AceDB-3.0's 18.6 µs and 1.9 KB (0.25x); without namespaces 0.62 µs (0.21x). |
| `RegisterNamespace` | Revision 15: compiles the schema once (shared like `Open`'s), reads the scope keys and builds the namespace's records and empty views. On host Lua 5.1 (2026-11-15) about 7.8 µs with a profile read; a namespace with its profile view built holds about 4.0 KB (AceDB-3.0: 2.7 µs, 3.3 KB). |
| The revision 15 scopes | Nothing unless declared: their keys are read and their sections created only for a schema that declares them. |
| A pending migration step | One deep copy of the saved table and one walk of the result, once per step with a function, only while the stored version is behind (see [Migrations](#migrations)). |

Defaults are compiled once at `Open` from `schema:Describe()` (or, for plain defaults, from the description the Defaults part builds); nothing on the read path consults SchemaKit. Plans hold only the fields they use, and fast checks only the bounds a field declares (plan layout 3, revision 16).

Resident memory (host Lua 5.1.5, 64-bit, debug information kept, measured 2026-11-18 after a full collection, SchemaKit loaded): the core 185.1 KB (revision 15: 192.1 KB), the Defaults part 20.9 KB, the SpecProfiles part 15.3 KB, the Namespaces part 29.4 KB. Registry, SignalKit, SettingsKit and the Defaults part, a database-only set without SchemaKit, hold 320.8 KB where the same set with SchemaKit held 388.4 KB. The bench-shaped schema plus its first `Open` takes 40.1 KB (revision 15: 49.9 KB); the same defaults as a plain table 27.0 KB.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **EventKit, not LifecycleKit, is the optional dependency.** The plan lists LifecycleKit as optional with nothing to do; compaction at logout needs a `PLAYER_LOGOUT` listener, and EventKit is the Kit that delivers host events. It is found at `Open` through `Registry:Find("eventKit", 1)` and declared under `optionalDependencies`.
- **Migrations receive a copy of the saved table** (`fn(raw)`), not the database. They run before the layout and the views exist, so a step can restructure a table written by an older version of the addon, including one that predates SettingsKit. Each step works on a deep copy that replaces the saved table's contents only when the step returns (revision 5), so a failing step never leaves half-applied writes behind.
- **Newer stored data opens read-only** (revision 5). The plan says nothing about downgrades; writing a newer version's data with an older layout can corrupt it, so writing it is an explicit opt-in (`allowNewerData`).
- **Every field of a record read through a view must be `optional`.** A write is validated by checking a probe that holds only the written path; that is what makes a write one schema check with no allocation, and it is only sound when every other field may be absent.
- **Plain table defaults are copied into the saved table on first read.** Arrays and other tables without their own view would otherwise hand out the shared default to be edited in place. Records and keyed sections, the common case, are never written back.
- **A view holds its saved table until a SettingsKit mutation may have changed it** (revision 7). Revisions 1 to 6 found the table through each nesting level on every access, which also showed direct edits of the saved variable at once; revision 7 finds it again only after a mutation or `db:Resync()`, which halves the cost of a read. Every view stays valid across `ResetProfile`, `CopyProfile`, `ResetDatabase` and the rest; direct edits after `Open` need `Resync` (see [Views hold their saved tables](#views-hold-their-saved-tables)).
- **The profile choice is recorded by `SetProfile`**, not at `Open`, so a character that never switches writes nothing.
- **Saved tables carry a metatable while the database is open** (revision 14), so reads cost what AceDB-3.0's do; see [The saved table](#the-saved-table).
- **Views are refused as values**, together with any table carrying a metatable other than the one SettingsKit gives saved tables. A stored view would alias another view's data and be written through without validation, because Lua 5.1 calls `__newindex` only for absent keys.
- **Spec profiles keep no enabled flag** (revision 11), unlike LibDualSpec-1.0: an assignment is what enables switching for its index, which keeps one rule for the saved table and the options screen.
- **The spec index kind is read on every call**, not once: `WOW_PROJECT_ID` is a constant of the session, so the answer is the same, and a call costs one table read.
- **Additions:** `db:Validate(scope, path, value)`, for an options layer that checks a value before it writes it (optionsKit binds options to database paths); `db:Pairs(view)`, because Lua 5.1 cannot iterate a proxy with `pairs`; `OnProfileCopied`, `OnProfileReset` and `OnProfileDeleted` methods; a fifth `path` argument to `OnChange` listeners; `db:GetSavedVariable()`; `db:Resync()` and `db:Getter(source, key)` (revision 7); `SettingsKit:GetCharacterKey()` (revision 14); `db:IsNewProfile()` and the profile name passed to `OnProfileShutdown` listeners (revision 15); `Compact` returns a count; `SettingsKit.DEFAULT_PROFILE` and `SettingsKit.MAX_PROFILE_NAME_LENGTH`; `SetLimits`, `GetLimits`, `UNBOUNDED` and the `maxScannedEntries` option (principle 4a, *Bounded by default, opened on purpose*).

## Embedded copies and upgrades

Several addons may embed SettingsKit; Registry selects the newest compatible revision and every copy shares one facade. Package state holds one database per saved-variable name, the shared limits and the `UNBOUNDED` sentinel, and an upgrade keeps them: databases, views, their listeners and the logout connection keep working and run the newer implementation, because the database and view metatables and the logout listener's dispatch table are rewritten in place.

Revision 5 gives every database opened by an older revision the fields it reads (database layout 2). Such a database stays writable, as it was opened, even over newer data — turning it read-only in the middle of a session would break an addon already writing through it — but it records the newer stored version, so `ResetDatabase` never lowers it. `IsReadOnly` answers `false` for it. Databases opened after the upgrade follow the read-only rule.

Revision 6 changes no documented behaviour. An in-place upgrade brings the views, plans and databases an older revision built to its own layouts, so they keep working and gain the faster reads and writes; a database an older revision opened keeps the logout listener it connected, and is compacted by it once.

Revision 7 changes one documented behaviour, by the owner's decision: a direct edit of the saved variable after `Open` that adds, replaces or removes a table shows through views only after `db:Resync()` (see [Views hold their saved tables](#views-hold-their-saved-tables)). It adds `Resync` and `Getter`. An in-place upgrade gives every database an older revision opened a generation (database layout 4) and every live view an empty cache (node layout 3), keeping detached views detached; a getter made by revision 7 keeps working under a later revision.

Revision 8 changes no documented behaviour: a getter's fast path compares the saved value with `nil` instead of calling `type` (see [`db:Getter`](#dbgettersource-key)). Getters made by revision 7 keep their own closure and keep working; getters made after the upgrade use the new one.

Revision 9 fixes two faults and changes no other documented behaviour: a keyed-section view read with a NaN key reads `nil` instead of raising `table index is NaN`, and `Open` refuses a receiver other than the facade, as `SetLimits` and `GetLimits` do. An in-place upgrade from any revision builds the depth probes of the nested views an older copy built, so writes through them keep the fast path.

Revision 10 fixes an in-place upgrade over revisions 1 to 6: a view of a deleted or reset-away profile stays detached even when the collector removed that profile's root view before the upgrade ran, so writes through it are still refused.

Revision 11 adds [spec profiles](#spec-profiles): `GetSpecIndex`, `SetSpecProfile`, `GetSpecProfile`, `ApplySpecProfile` and the `specProfiles` section. A database an older revision opened gains the methods through the shared prototype; its section is created at its first `SetSpecProfile`, and a character whose saved table already holds assignments (written by a newer copy in an earlier session) gets the listener and its assignment when the upgrade runs.

Revision 12 fixes two faults of spec profiles. A database whose character's assignments were all cleared went on remembering the index it last applied, so after a change of index and back, an assignment made meanwhile for that index was never applied; every spec event now records the index for such a database too. And an in-place upgrade applied the current index's assignment again to every database, also to those a revision with spec profiles opened, undoing a manual `SetProfile` whenever a newer copy loaded in the middle of the session; only databases revision 10 or earlier opened get it now. A spec event also switches every database with an assignment when a profile listener opens databases during the event; the walk over the open databases used to skip some once the listener made their table grow.

Nothing survives `/reload` except the saved variable itself: open the database again in the loaded phase.

Revision 14 changes four documented behaviours, recorded in `docs/ROADMAP.md` package O, "settingsKit read-through views": views read through chained tables, so an open database's saved tables carry SettingsKit's metatable and read their defaults (see [The saved table](#the-saved-table)); a read with a secret key raises the client's own error instead of SettingsKit's (core decision 19b); views are built by their first use; and the `char` key comes from `UnitNameUnmodified("player")`. It adds `SettingsKit:GetCharacterKey()`. An in-place upgrade from an earlier revision gives every live view its own metatable and chain (the shared view metatable is SettingsKit's, so its protection is lifted for the swap and put back), moves every keyed section's entry cache to the shared entry-cache metatable, and keeps every database, view, listener and getter; a database an older revision opened builds its profile view at once from then on, because a getter that revision made expects one. An upgrade from revision 14 on gives every view's metatable the newer file's functions and rebinds its chain.

Revision 16 moves spec profiles into the SpecProfiles part and adds the Defaults part and `HasPart`; SchemaKit becomes optional. An in-place upgrade from revision 15 keeps every database, view and plan: plans revision 15 compiled (layout 2, `false` fields) stay on their databases and are read by the same truthiness tests, new plans are layout 3. With the SpecProfiles part absent, revision 15's `GetSpecIndex`, `SetSpecProfile`, `GetSpecProfile`, `ApplySpecProfile` and its `onSpecEvent` and `onDatabaseOpened` entries are kept instead of the stubs, so an addon that embedded revision 15 keeps switching; the part replaces them when it loads. The reverse order cannot be served: with revision 16 loaded first, a revision 15 copy loaded after it yields, and that addon's spec calls raise the not-loaded message until some addon embeds the part. The depth probes revisions 6 to 15 built for a SchemaKit older than revision 6 are gone: without `SchemaKit:GetLimit` a nested write takes the full check, where SchemaKit enforces its own depth.

Revision 15 adds the four AceDB-3.0 scopes, the lifecycle signals, `IsNewProfile`, `missingOk`, the `maxNamespaces` option and the hooks of the [Namespaces](#namespaces) part, and changes one documented behaviour: `CopyProfile` and `DeleteProfile` return a boolean. An in-place upgrade from revision 14 adds the shared tables these use; databases revision 14 opened gain every new method through the prototype, keep their listeners and getters, and answer `IsNewProfile() == false` for the profile their `Open` created. The part keeps no copy of core functions and its namespaces share the prototype and metatable, so a later core revision loaded in place keeps cascading to namespaces registered before it; a copy of the part whose revision is not higher than the loaded one returns at once.
