# SettingsKit

SettingsKit gives World of Warcraft addons their saved variables done once: a database opened over the addon's `## SavedVariables` table, with scopes, defaults that are never written back, writes validated at the writer's line, profiles, change signals and versioned migrations.

The shortest form takes AceDB-style defaults (with the Defaults part, no SchemaKit needed); the write rules are inferred from each default:

```lua
local SettingsKit = MoltenCodes.Registries[2]:Get("settingsKit", 1)

lifecycle:OnLoaded(function()
  local db = SettingsKit:Open("MyAddonDB", {
    global = { firstRun = true },
    profile = { scale = 1, anchor = "CENTER", auras = { ["*"] = { shown = true } } },
  })
  db.profile.scale = 1.25   -- a number, as the default is
  db.profile.scale = "big"  -- raises here: "expected number, found string"
end)
```

A SchemaKit schema says more (ranges, choices, integers) and works without the Defaults part:

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
- **Scopes.** `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` and `db.profile`, keyed from `UnitNameUnmodified` (else `UnitName`), `GetRealmName`, `UnitClass` and `UnitFactionGroup` read once at `Open`; `SettingsKit:GetCharacterKey()` answers the character key. AceDB-3.0's other four, `db.race`, `db.factionrealm`, `db.factionrealmregion` and `db.locale`, with AceDB's keys, cost nothing unless the schema declares them.
- **Profiles.** `SetProfile`, `GetProfiles` (sorted), `CopyProfile`, `ResetProfile`, `DeleteProfile`, `ResetDatabase`, with a signal for each change, and AceDB-3.0's other callbacks: `OnNewProfile`, `OnProfileShutdown` (before a switch), `OnDatabaseShutdown` (at logout, before compaction) and `OnDatabaseReset`. `db:IsNewProfile()` says whether this session created the current profile, so an addon learns its first profile is new.
- **Plain defaults or schemas.** With the optional `settingsKit\parts\SettingsKit-Defaults.lua`, a scope may be a plain defaults table as AceDB-3.0 takes them; a SchemaKit node inside one (a range, a choice) is kept as written. SchemaKit is only needed for scopes given as schemas.
- **Pay for what you use.** The core is 185 KB resident; the Defaults (21 KB), SpecProfiles (15 KB) and Namespaces (29 KB) parts are loaded only by the addons that use them, and `SettingsKit:HasPart(name)` asks without raising.
- **Namespaces.** With the optional `settingsKit\parts\SettingsKit-Namespaces.lua`, `db:RegisterNamespace(name, schema)` gives a module its own database over `MyAddonDB.namespaces[name]`, in AceDB-3.0's namespace layout, following the parent's profile: every profile operation of the parent reaches every namespace.
- **Spec profiles.** With the optional `settingsKit\parts\SettingsKit-SpecProfiles.lua`, `db:SetSpecProfile(index, name)` assigns a profile to a specialization (Retail, Mists of Pandaria Classic) or a talent group (Classic Era, Season of Discovery, Hardcore), and the database switches to it when the player changes specialization, while EventKit is embedded; `db:ApplySpecProfile()` does it by hand. See *Spec profiles* in the API.
- **Change notifications.** `db:OnChange(scope, callback)` returns a SignalKit connection called after every validated write.
- **Versioned migrations.** `options.migrations[n]` runs once, in ascending order, from the stored version to `options.version`, each on a copy of the saved table that replaces it only when the step returns, so a failing step leaves nothing half-applied and is retried on untouched data.
- **Newer data is read-only.** A saved table a newer version of the addon wrote (stored version above `options.version`) opens read-only: reads work, every write raises at the writer's line, and `db:IsReadOnly()` says so. `allowNewerData = true` opts in to writing it.
- **Compaction at logout.** When EventKit is embedded, every database compacts itself on `PLAYER_LOGOUT`.
- **Views hold their saved tables.** A view keeps the table it reads until a SettingsKit mutation may have changed it. After editing the saved variable yourself once the database is open, call `db:Resync()`.
- **Reads cost what AceDB's do.** A view reads through chained tables, so `db.profile.scale` is answered by the VM without a SettingsKit call (about 10 ns against AceDB-3.0's 3.5 ns on host Lua; revision 13 took 110 ns), and views are built on first use, so `Open` holds less than AceDB-3.0's database. While a database is open its saved tables read their defaults, as AceDB's do; use `rawget` to test what is saved. `db:Getter("profile", "scale")` returns a function answering exactly what `db.profile.scale` does, for handing a reader around.
- **Bounded by default, opened on purpose.** The secret-value scan of a written table (`maxScannedEntries`, an `Open` option that accepts `SettingsKit.UNBOUNDED`), the namespaces a database registers (`maxNamespaces`, 256, the same), profile-name length and path-key length (`SettingsKit:SetLimits`) each have a documented default; see *Limits* in the API.

## Migrating from AceDB-3.0

| AceDB-3.0 | SettingsKit |
|---|---|
| `AceDB:New(name, defaults, true)` | `SettingsKit:Open(name, schema, { defaultProfile = "Default" })` |
| `AceDB:New(name, defaults)` (a profile per character) | `SettingsKit:Open(name, schema, { defaultProfile = "char" })` |
| `db.profile`, `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` | The same names, as validated views. |
| `db.race`, `db.factionrealm`, `db.factionrealmregion`, `db.locale` | The same names (revision 15), keyed as AceDB keys them; declare them in the schema. |
| `["*"]` and `["**"]` defaults | A `map` whose `values` is `S.optional(record, {})`: every key reads the record's defaults until written. |
| `db:GetCurrentProfile()` | `db:GetProfile()` |
| `db:GetProfiles()` (a table and a count) | `db:GetProfiles()` (a new sorted array) |
| `db:SetProfile`, `db:CopyProfile`, `db:ResetProfile`, `db:DeleteProfile` | The same names; copying or deleting a missing profile is refused. |
| `db:CopyProfile(name, true)`, `db:DeleteProfile(name, true)` (`silent`) | `db:CopyProfile(name, { missingOk = true })`, `db:DeleteProfile(name, { missingOk = true })`, which answer `false`. |
| `db:ResetDB()` | `db:ResetDatabase()` |
| `db:RegisterNamespace(name, defaults)` | `db:RegisterNamespace(name, schema)` with the Namespaces part; the saved layout is AceDB's. |
| `db:GetNamespace(name)`, `db:GetNamespace(name, true)` | `db:GetNamespace(name)`, `db:GetNamespace(name, { missingOk = true })`. |
| `db:RegisterDefaults(defaults)` | The schema passed to `Open`. |
| Defaults copied into the saved tables, so `MyAddonDB.profiles.Default.scale` reads the default | The same while the database is open: saved tables read their scalar defaults through a metatable (revision 14); `rawget` sees only what is saved, and nothing is written. |
| Character key from `UnitNameUnmodified("player") .. " - " .. GetRealmName()` | The same key (revision 14), `SettingsKit:GetCharacterKey()`; `UnitName` only where the client has no `UnitNameUnmodified`. AceDB's ruleset keys on WoW Forever (interface 1.60) are not followed: that client is not supported. |
| Callbacks `OnProfileChanged(event, db, name)` and the other three | `db:OnProfileChanged(function(db, name, previous) end)`, `OnProfileCopied`, `OnProfileReset`, `OnProfileDeleted`. |
| Callbacks `OnNewProfile`, `OnProfileShutdown`, `OnDatabaseShutdown`, `OnDatabaseReset` | `db:OnNewProfile(function(db, name))`, `db:OnProfileShutdown(function(db, name))` (also passes the profile being left), `db:OnDatabaseShutdown(function(db))` (with EventKit), `db:OnDatabaseReset(function(db))`. `OnNewProfile` for the profile `Open` created: `db:IsNewProfile()`. |
| Values equal to their defaults stripped at logout | `db:Compact()`, run at logout while EventKit is embedded. |

Existing AceDB data is imported by BridgeKit (`ImportAceDB`, `AceDBMigration`); the full guide is in [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md).

## Migrating from LibDualSpec-1.0

| LibDualSpec-1.0 | SettingsKit |
|---|---|
| `LibDualSpec:EnhanceDatabase(db, "MyAddon")` | Embed `settingsKit\parts\SettingsKit-SpecProfiles.lua`: every database then has spec profiles. |
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
Libs\MoltenCodes\settingsKit\SettingsKit.lua
Libs\MoltenCodes\settingsKit\parts\SettingsKit-Defaults.lua
```

Minimum footprint: embed 3 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `settingsKit/SettingsKit.lua`.

Optional parts, after the core (`python3 -m tooling.package.embeds settingsKit/Defaults` writes the list):
`settingsKit/parts/SettingsKit-Defaults.lua` for plain defaults,
`settingsKit/parts/SettingsKit-SpecProfiles.lua` for spec profiles and
`settingsKit/parts/SettingsKit-Namespaces.lua` for `db:RegisterNamespace` and
`db:GetNamespace`. Without a part its members raise a message naming the file
to add. Scopes given as SchemaKit schemas need `schemaKit/SchemaKit.lua`
before SettingsKit.

Direct runtime dependencies: Registry API 2, SignalKit API 1. Both are
required; omitting one makes this package raise at load.

Optional: SchemaKit API 1, found with `Registry:Find` when a scope is a
SchemaKit schema. Optional: EventKit API 1, found with `Registry:Find` when a database is opened,
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
