# SettingsKit

SettingsKit gives World of Warcraft addons their saved variables done once: a database opened over the addon's `## SavedVariables` table, with scopes, defaults that are never written back, writes validated against a SchemaKit schema at the writer's line, profiles, change signals and versioned migrations.

```lua
local Registry = MoltenCodes.Registries[2]
local SchemaKit = Registry:Get("schemaKit", 1)
local SettingsKit = Registry:Get("settingsKit", 1)
local S = SchemaKit

local schema = {
  global = S.table({ fields = { firstRun = S.optional(S.boolean(), true) } }),
  profile = S.table({
    fields = {
      scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
      anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), "CENTER"),
      auras = S.optional(S.map({
        keys = S.number({ integer = true }),
        values = S.optional(S.table({ fields = { shown = S.optional(S.boolean(), true) } }), {}),
        max = 256,
      }), {}),
    },
  }),
}

lifecycle:OnLoaded(function()
  local db = SettingsKit:Open("MyAddonDB", schema, { version = 2 })

  print(db.profile.scale)          -- 1, the default; nothing is written
  print(db.profile.auras[118].shown) -- true, the wildcard default
  db.profile.scale = 1.25          -- checked against the schema, then stored
  db.profile.scale = 7             -- raises here: "expected number <= 2, found larger number"
end)
```

What each piece promises:

- **Defaults are a view, not stored data.** A read that finds nothing saved returns the schema's default, including wildcard defaults for every key of a keyed section, and writes nothing. The saved file holds only what the player changed, and `db:Compact()` removes values that were set back to their default.
- **Writes are validated where they happen.** `db.profile.scale = 7` raises at that line with SchemaKit's failure text, and nothing is stored. A secret value is refused the same way: saved variables never hold one.
- **Scopes.** `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` and `db.profile`, keyed from `UnitName`, `GetRealmName`, `UnitClass` and `UnitFactionGroup` read once at `Open`.
- **Profiles.** `SetProfile`, `GetProfiles` (sorted), `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase`, with a signal for each change.
- **Spec profiles.** `db:SetSpecProfile(index, name)` assigns a profile to a specialization (Retail, Mists of Pandaria Classic) or a talent group (Classic Era, Season of Discovery, Hardcore), and the database switches to it when the player changes specialization, while EventKit is embedded; `db:ApplySpecProfile()` does it by hand. See *Spec profiles* in the API.
- **Change notifications.** `db:OnChange(scope, callback)` returns a SignalKit connection called after every validated write.
- **Versioned migrations.** `options.migrations[n]` runs once, in ascending order, from the stored version to `options.version`, each on a copy of the saved table that replaces it only when the step returns, so a failing step leaves nothing half-applied and is retried on untouched data.
- **Newer data is read-only.** A saved table a newer version of the addon wrote (stored version above `options.version`) opens read-only: reads work, every write raises at the writer's line, and `db:IsReadOnly()` says so. `allowNewerData = true` opts in to writing it.
- **Compaction at logout.** When EventKit is embedded, every database compacts itself on `PLAYER_LOGOUT`.
- **Views hold their saved tables.** A view keeps the table it reads until a SettingsKit mutation may have changed it. After editing the saved variable yourself once the database is open, call `db:Resync()`.
- **Getters for hot loops.** `db:Getter("profile", "scale")` returns a function answering exactly what `db.profile.scale` does, defaults included, without the metamethod call or a per-call probe of the key.
- **Bounded by default, opened on purpose.** The secret-value scan of a written table (`maxScannedEntries`, an `Open` option that accepts `SettingsKit.UNBOUNDED`), profile-name length and path-key length (`SettingsKit:SetLimits`) each have a documented default; see *Limits* in the API.

## Migrating from AceDB-3.0

| AceDB-3.0 | SettingsKit |
|---|---|
| `AceDB:New(name, defaults, true)` | `SettingsKit:Open(name, schema, { defaultProfile = "Default" })` |
| `AceDB:New(name, defaults)` (a profile per character) | `SettingsKit:Open(name, schema, { defaultProfile = "char" })` |
| `db.profile`, `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` | The same names, as validated views. |
| `db.race`, `db.factionrealm`, `db.factionrealmregion`, `db.locale` | No scope: declare a keyed `map` in `global` and index it yourself. |
| `["*"]` and `["**"]` defaults | A `map` whose `values` is `S.optional(record, {})`: every key reads the record's defaults until written. |
| `db:GetCurrentProfile()` | `db:GetProfile()` |
| `db:GetProfiles()` (a table and a count) | `db:GetProfiles()` (a new sorted array) |
| `db:SetProfile`, `db:CopyProfile`, `db:ResetProfile`, `db:DeleteProfile` | The same names; deleting a missing profile is refused. |
| `db:ResetDB()` | `db:ResetDatabase()` |
| `db:RegisterNamespace(name, defaults)` | No namespaces in API 1: open a second database. |
| `db:RegisterDefaults(defaults)` | The schema passed to `Open`. |
| Callbacks `OnProfileChanged(event, db, name)` and the other three | `db:OnProfileChanged(function(db, name, previous) end)`, `OnProfileCopied`, `OnProfileReset`, `OnProfileDeleted`. |
| Values equal to their defaults stripped at logout | `db:Compact()`, run at logout while EventKit is embedded. |

Existing AceDB data is imported by BridgeKit (`ImportAceDB`, `AceDBMigration`); the full guide is in [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md).

## Migrating from LibDualSpec-1.0

| LibDualSpec-1.0 | SettingsKit |
|---|---|
| `LibDualSpec:EnhanceDatabase(db, "MyAddon")` | Nothing: every database has spec profiles. |
| `db:SetDualSpecProfile(name, spec)` | `db:SetSpecProfile(spec, name)` |
| `db:GetDualSpecProfile(spec)` | `db:GetSpecProfile(spec)` (`nil` when nothing is assigned) |
| `db:SetDualSpecEnabled(enabled)`, `db:IsDualSpecEnabled()` | No flag: assigning a profile enables switching for that index; clearing it (`db:SetSpecProfile(spec, nil)`) disables it. |
| `db:CheckDualSpecState()` | `db:ApplySpecProfile()`, only needed without EventKit. |
| `LibDualSpec:EnhanceOptions(options, db)` | `OptionsKit:ProfileOptions(db)` already includes one choice per specialization or talent group. |
| The `LibDualSpec-1.0` AceDB namespace | `specProfiles` in the saved variable; existing LibDualSpec choices are not imported. |

See [`docs/API.md`](docs/API.md) for the complete contract with a full addon example, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the layout of the saved table and the view design.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
Libs\MoltenCodes\settingsKit\SettingsKit.lua
```

Minimum footprint: embed 4 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `schemaKit/SchemaKit.lua`, `settingsKit/SettingsKit.lua`.

Direct runtime dependencies: Registry API 2, SchemaKit API 1, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load.

Optional: EventKit API 1, found with `Registry:Find` when a database is opened,
to compact it on `PLAYER_LOGOUT` and to switch spec profiles on the spec
events. Without it, call `db:Compact()` yourself at logout and
`db:ApplySpecProfile()` after a specialization change. Load EventKit before your addon opens its database if you want the
automatic compaction.

Declare the saved variable in your `.toc`, and open the database no earlier than
your addon's loaded phase, which is the first moment the client guarantees the
table exists:

```toc
## SavedVariables: MyAddonDB
```

```lua
local lifecycle = LifecycleKit:ForAddon(ADDON_NAME)
lifecycle:OnLoaded(function()
  addon.db = SettingsKit:Open("MyAddonDB", schema, { defaultProfile = "Default", version = 1 })
end)
```
