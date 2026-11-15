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
| **AceConfig-3.0**: options tables to OptionsKit trees, the Ace callbacks wrapped, with a report | revision 2 | 2 for `ConvertAceConfig`; 5 with OptionsKit for `DefineAceConfig` |
| **AceDB-3.0**: saved variables rebuilt in the SettingsKit layout, checked against the schema, with a backup | revision 3 | 3: Registry, SchemaKit, BridgeKit (SettingsKit is the addon's own) |
| AceComm-3.0 messages through CommKit | planned (step N4) | |

The plan and every format are in
[`docs/BRIDGE_KIT_DESIGN.md`](../../docs/BRIDGE_KIT_DESIGN.md); the migration
recipes in [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md).

## Why it is safe

- **The same bytes as Ace3.** The writer produces what AceSerializer-3.0
  produces for the same values on the same client, and the reader accepts
  what it accepts. The specs hold BridgeKit to output recorded from Ace3
  itself, at the commit `BridgeKit.ACE_BASELINE` names.
- **No crash on bad input.** Malformed text is `false, reason`, never an
  error. Depth, value count, string length, text size and top-level values are
  bounded, where Ace3 has no bound.
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
