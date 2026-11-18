# BridgeKit

Migration from Ace3 to the MoltenCodes Kits, without breaking what players
already have: data an Ace3 addon wrote stays readable, and peers still running
the Ace3 version still understand the new one.

```lua
local BridgeKit = MoltenCodes.Registries[2]:Get("bridgeKit", 1)

-- Read an export string or a message an Ace3 version of the addon wrote.
local ok, kind, payload = BridgeKit:AceDeserialize(text)

-- Write one an Ace3 version can read.
local written, exportText = BridgeKit:AceSerialize("profile", settings)

-- Keep an AceConfig options table working in OptionsKit.
local tree, report = BridgeKit:DefineAceConfig("MyAddon", aceOptions, { db = db })

-- Speak AceComm-3.0 with peers still running the Ace3 version.
local channel = BridgeKit:OpenAceComm(CommKit:ForAddon("MyAddon"), "MyAddon", onMessage)
channel:Send({ text = exportText, distribution = "GUILD" })

-- Carry an AceDB saved variable over to SettingsKit, with a backup.
local imported = BridgeKit:ImportAceDB("MyAddonDB", "MyAddonSettings", {
  schema = schema,
  aceDefaults = aceDefaults,
  version = 1,
  backup = "MyAddonDB_Backup",
})
```

## What it ships

| Part | Status | Files an addon embeds |
|---|---|---|
| **AceSerializer-3.0**: `AceSerialize` and `AceDeserialize`, byte for byte with Ace3 | revision 1 | 2: `Registry.lua`, `BridgeKit.lua` |
| **AceConfig-3.0**: options tables to OptionsKit trees, the Ace callbacks wrapped, with a report; `childGroups` layouts kept since revision 5; every field the registered OptionsKit accepts carried over, and trees rebuilt on `NotifyChange` with OptionsKit's Dynamic part, since revision 8 | revision 2 | 2 for `ConvertAceConfig`; 5 with OptionsKit for `DefineAceConfig` (6 with its Dynamic part for rebuilds) |
| **AceDB-3.0**: saved variables rebuilt in the SettingsKit layout, checked against the schema, with a backup; namespaces and AceDB's four extra scopes copied as they are into SettingsKit revision 15's layout since revision 8 | revision 3 | 3: Registry, SchemaKit, BridgeKit (SettingsKit is the addon's own) |
| **AceComm-3.0**: messages framed and reassembled as AceComm does, through CommKit's queue, with bounds | revision 4 | 2 plus CommKit (which the addon embeds for its own traffic) |

The current release is 0.5.1, implementation revision 6.

The plan and every format are in
[`docs/BRIDGE_KIT_DESIGN.md`](../../docs/BRIDGE_KIT_DESIGN.md); the migration
recipes in [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md).

## Migrating from Ace3

| Ace3 | BridgeKit |
|---|---|
| `AceSerializer:Serialize(...)` | `BridgeKit:AceSerialize(...)` → `true, text` or `false, reason` |
| `AceSerializer:Deserialize(text)` | `BridgeKit:AceDeserialize(text)` → `true, ...` or `false, reason` |
| `AceConfig:RegisterOptionsTable(appName, options)` | `BridgeKit:DefineAceConfig(appName, options[, { db = db }])` → OptionsKit tree and report |
| `AceConfigRegistry:NotifyChange(appName)` after editing the table | `tree:NotifyChange()` on the tree `DefineAceConfig` returned, with OptionsKit's Dynamic part loaded |
| `width`, `confirm`, `image`, `dialogHidden` and AceConfig's other presentation fields | carried over when the registered OptionsKit accepts them (revision 14 and later, with its Presentation and Handlers parts loaded since 0.9.0), reported dropped otherwise |
| `db:RegisterNamespace(name, defaults)` data already saved | copied as it is by `ImportAceDB` when SettingsKit is revision 15 or later; read with `db:RegisterNamespace(name, schema)` |
| `AceDB:New("MyAddonDB", defaults)` with data already saved | `BridgeKit:ImportAceDB(...)` into a new saved variable, or `BridgeKit:AceDBMigration(plan)` as a SettingsKit migration step |
| `AceComm:RegisterComm(prefix, handler)` / `SendCommMessage` | `BridgeKit:OpenAceComm(scope, prefix, callback)` / `channel:Send(request)` |

[`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md) has the
recipes, and `docs/API.md` every field, reason and limit.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\bridgeKit\BridgeKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `bridgeKit/BridgeKit.lua`.

Direct runtime dependency: Registry API 2. OptionsKit, SchemaKit, SettingsKit
and CommKit are optional and found through `Registry:Find` when the method
that needs them is called; the table above lists what each part needs.

## Why it is safe

- **The same bytes as Ace3.** The writer produces what AceSerializer-3.0
  produces for the same values on the same client, and the reader accepts
  what it accepts. The specs hold BridgeKit to output recorded from Ace3
  itself, at the commit `BridgeKit.ACE_BASELINE` names.
- **No crash on bad input.** Malformed text is `false, reason`, never an
  error. Depth, value count, string length, text size and top-level values are
  bounded, where Ace3 has no bound; so are the AceComm streams other players
  make BridgeKit hold.
- **Refusals where Ace3 would break.** NaN, cycles and functions are refused
  with a reason instead of raising, overflowing the stack or writing undefined
  bytes.
- **Nothing lost silently.** A conversion reports every field it drops,
  changes or renames, and `strict` turns any of it into an error; an import
  reports every value it drops or writes from a default, and never touches
  the source.
- **No Ace3 code.** BridgeKit is written from the format description; Ace3 is
  only run, outside the repository, to record what it does.

## Stop embedding it

BridgeKit is for the migration period. Once every player's data has been
converted and no peer runs the Ace3 version any more, remove it from the
addon's `embeds.xml`.

## Documentation

- [`docs/API.md`](docs/API.md): the contract, every reason with its Ace3
  counterpart, the limits and the deviations.
- [`CHANGELOG.md`](CHANGELOG.md).
- [`tests/README.md`](tests/README.md): what the specs cover.
