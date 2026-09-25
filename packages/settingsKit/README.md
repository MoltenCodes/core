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
- **Change notifications.** `db:OnChange(scope, callback)` returns a SignalKit connection called after every validated write.
- **Versioned migrations.** `options.migrations[n]` runs once, in ascending order, from the stored version to `options.version`, each on a copy of the saved table that replaces it only when the step returns, so a failing step leaves nothing half-applied and is retried on untouched data.
- **Newer data is read-only.** A saved table a newer version of the addon wrote (stored version above `options.version`) opens read-only: reads work, every write raises at the writer's line, and `db:IsReadOnly()` says so. `allowNewerData = true` opts in to writing it.
- **Compaction at logout.** When EventKit is embedded, every database compacts itself on `PLAYER_LOGOUT`.
- **Bounded by default, opened on purpose.** The secret-value scan of a written table (`maxScannedEntries`, an `Open` option that accepts `SettingsKit.UNBOUNDED`), profile-name length and path-key length (`SettingsKit:SetLimits`) each have a documented default; see *Limits* in the API.

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
to compact it on `PLAYER_LOGOUT`. Without it, call `db:Compact()` yourself at
logout. Load EventKit before your addon opens its database if you want the
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
