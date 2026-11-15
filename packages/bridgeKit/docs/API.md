# BridgeKit API

BridgeKit is the MoltenCodes package that moves an addon from Ace3 to the Kits
without breaking what its players already have. Its canonical design is
[`docs/BRIDGE_KIT_DESIGN.md`](../../../docs/BRIDGE_KIT_DESIGN.md); this
document is the contract of what the current revision ships.

**Revision 4 ships all four parts**: the AceSerializer-3.0 wire format
(design step N1, revision 1), the AceConfig-3.0 adapter (step N2, revision 2),
the AceDB-3.0 importer (step N3, revision 3) and the AceComm-3.0 channel
(step N4, revision 4).

Everything here reproduces Ace3 at commit
`5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773`, AceSerializer-3.0 `MINOR` 5. The
implementation is written from the format description in the design, never
from Ace3's source, and is checked against output recorded from Ace3 itself
(see [Testing](#testing)).

## Loading

BridgeKit needs Registry API 2 and nothing else: an addon that only reads and
writes AceSerializer text, or converts an AceConfig table to a plain tree,
embeds two files. `DefineAceConfig` finds OptionsKit API 1 through
`Registry:Find` when it is called, so defining the converted tree needs
OptionsKit's files too (Registry, SignalKit, SchemaKit, OptionsKit). The AceDB
importer finds SchemaKit API 1 the same way (SettingsKit requires it, so an
addon with a SettingsKit schema has it), and reads SettingsKit's profile-name
limit when SettingsKit API 1 is loaded.

```xml
<Script file="Libs\MoltenCodes\registry\Registry.lua" />
<Script file="Libs\MoltenCodes\bridgeKit\BridgeKit.lua" />
```

```lua
local BridgeKit = MoltenCodes.Registries[2]:Get("bridgeKit", 1)
```

## Public surface

| Member | Returns | Purpose |
|---|---|---|
| `AceSerialize(...)` | `true, text` or `false, reason` | AceSerializer-3.0 text for a list of values. |
| `AceDeserialize(text)` | `true, ...` or `false, reason` | The values of AceSerializer-3.0 text. Never raises on malformed text. |
| `ConvertAceConfig(appName, source[, options])` | conversion | An AceConfig-3.0 options table (or a function returning one) as a table for `OptionsKit:Define`, and a report. |
| `DefineAceConfig(addonName, source[, options])` | tree, report | `ConvertAceConfig`, then `OptionsKit:Define`. |
| `FormatReport(report[, maxLines])` | array of strings | Display lines for a report, safe to print. |
| `PreviewAceDB(source, plan)` | report, or report and `"maxImportEntries"` | What an import would write, materialise and drop. Writes nothing. |
| `ImportAceDB(source, targetName, plan)` | report, or `nil, reason` | Build the SettingsKit layout in an empty target global, before `SettingsKit:Open`. |
| `AceDBMigration(plan)` | function | A SettingsKit migration step that turns an AceDB table into the SettingsKit layout in place of the same saved variable. |
| `OpenAceComm(scope, prefix, callback[, options])` | channel, or `nil, reason` | Send and receive AceComm-3.0 messages on `prefix` through a CommKit scope. |
| `GetStatistics()` | a fresh table | The AceComm counters and the streams held now. |
| `SetLimits(limits)` | nothing | Change any subset of the [limits](#limits). |
| `GetLimits()` | a fresh table | The limits. |
| `UNBOUNDED` | table | Sentinel for the limits that accept it. |
| `ACE_WIRE_VERSION` | `1` | The newest AceComm wire version this revision speaks (design section 8.5). |
| `ACE_BASELINE` | read-only table | `{ commit = "5e2e0d3b…", AceComm = 14, AceSerializer = 5, AceDB = 37, AceConfigRegistry = 22 }`: what BridgeKit reproduces. Read its fields by name: it is a proxy, so a write raises and `pairs` sees no fields. The newest revision loaded writes its values into it. |
| `API`, `REVISION` | integers | API generation `1`, implementation revision. |

Every method is called with a colon on the facade. A dot call, a wrong type or
a secret argument raises **at the caller's line**, named after the method:
`BridgeKit:AceDeserialize text must be a string`. Everything that depends on
the data is a return value.

## `BridgeKit:AceSerialize(...)`

```lua
local ok, text = BridgeKit:AceSerialize("profile", { scale = 1.25, shown = true })
-- ok == true, text == "^1^Sprofile^T^Sscale^N1.25^Sshown^B^t^^" (pair order follows next)
```

Writes what Ace's `Serialize` writes for the same values on the same client:
the start code `^1`, one token per value, the end code `^^`. Strings escape
their control bytes, space, caret, tilde and DEL; numbers use `tostring` when
it reads back as the same number, otherwise a mantissa and an exponent;
tables write their pairs in `next` order, as Ace walks them with `pairs`, so
two equal tables with more than one entry may be written in different orders
by either implementation. The number spelling follows the client's
`tostring`, as Ace's does.

Returns `true, text`, or `false` and one of these reasons, where Ace would
raise or write undefined bytes:

| Reason | When | Ace3 |
|---|---|---|
| `"unsupportedType"` | a function, userdata or coroutine | raises (`AceSerializer-3.0.lua:106`) |
| `"cycle"` | a table that contains itself, directly or further down | overflows the stack |
| `"nan"` | NaN, as a value or inside a table | writes bytes that depend on the client (`29`, `65`, `152`) |
| `"maxDepth"` | tables nest deeper than `maxDepth` | no bound |
| `"maxValues"` | more than `maxValues` values, keys included | no bound |
| `"maxStringLength"` | a string longer than `maxStringLength` bytes, counted before escaping | no bound |
| `"maxTextBytes"` | the text would pass `maxTextBytes` | no bound |

A table referenced twice (not a cycle) is written twice, as Ace writes it, and
reads back as two tables. **A secret value anywhere**, a table key included,
raises at the caller: `BridgeKit:AceSerialize value must not contain a secret
value`.

## `BridgeKit:AceDeserialize(text)`

```lua
local ok, kind, settings = BridgeKit:AceDeserialize(text)
if not ok then
  -- kind is the reason
end
```

Reads every text Ace's `Deserialize` reads, within the limits, and returns
`true` and the values, their count kept (`nil`s included), or `false` and a
reason. It never raises on any string; it raises at the caller only for a
`text` that is not a string or is secret. As Ace's reader does, it:

- removes every control byte and space from the text before reading it;
- reads tokens as a caret, one code character, and the data up to the next
  caret, starting at the first caret (bytes before it are ignored);
- ignores the data after `^1`, `^B`, `^b`, `^Z`, `^T`, `^t` and `^^`, and
  everything after the end code;
- accepts the infinity spellings `1.#INF`, `inf`, `-1.#INF` and `-inf`, and
  every number `tonumber` reads, hexadecimal included;
- lets a repeated table key overwrite the earlier one;
- reads `nan` as NaN.

| Reason | When | Ace3's message |
|---|---|---|
| `"notAceSerializer"` | the first token is not `^1` | "Supplied data is not AceSerializer data (rev 1)" (`253`) |
| `"missingTerminator"` | the text ends before the end code `^^` | "Supplied data misses AceSerializer terminator ('^^')" (`179`) |
| `"invalidNumber"` | a `^N` token `tonumber` cannot read | "Invalid serialized number" (`194`) |
| `"invalidFloat"` | a `^F` token not followed by `^f`, or either part not a number | "Invalid serialized floating-point number" (`199`, `204`) |
| `"invalidEscape"` | a tilde before any character but `@` (64) to `}` (125): `~~`, `~0` and every high byte included | Ace's reader fails inside its escape helper or `string.char` |
| `"unknownControl"` | an unknown code, or `^t`, `^f` or `^1` where a value is expected | "Invalid AceSerializer control code" (`232`) |
| `"tableFormat"` | a table key or value that reads as `nil`, or the end code inside a table | "Invalid AceSerializer table format (no table end marker)" (`222`, `227`) |
| `"invalidKey"` | a NaN table key | Lua's "table index is NaN" |
| `"maxDepth"` | tables nest deeper than `maxDepth` | no bound |
| `"maxValues"` | more than `maxValues` values, keys included | no bound |
| `"maxStringLength"` | a string longer than `maxStringLength` bytes once unescaped | no bound |
| `"maxTextBytes"` | `text` is longer than `maxTextBytes` bytes | no bound |
| `"maxListValues"` | more than `maxListValues` top-level values | no bound |

### Deviations from Ace3

- **NaN key, invalid escape:** Ace raises inside its own `pcall` and returns
  `false` with Lua's message; BridgeKit returns the named reason. Which
  escapes Ace accepts is pinned byte by byte by the recorded fixtures.
- **One `^F` case reads back where Ace reads `0`.** Both compute
  `mantissa * 2^exponent`, except where `2^exponent` alone underflows to zero
  (an exponent below -1074): there Ace reads `0`, although the product is
  representable, and BridgeKit scales a finite mantissa with `ldexp` instead.
  Some subnormal numbers Ace's own writer produces are written that way, so
  BridgeKit reads them back exactly. Overflow to infinity and NaN come out as
  in Ace.
- **The limits** below, which Ace does not have.

## `BridgeKit:ConvertAceConfig(appName, source[, options])`

```lua
local conversion = BridgeKit:ConvertAceConfig("MyAddon", options, {
  bind = { ["general.scale"] = "profile.scale" },
  replace = { profiles = OptionsKit:ProfileOptions(db) },
})
for _, line in ipairs(BridgeKit:FormatReport(conversion.report)) do
  print(line)
end
local tree = OptionsKit:Define("MyAddon", conversion.tree, { db = db })
```

`appName` is a non-empty string: it becomes `info.appName` and `info[0]` in
every Ace callback. `source` is the options table, or a function, which is
called once with `(uiType, uiName, appName)` as AceConfigRegistry calls it
(`AceConfigRegistry-3.0.lua:331-341`); its result is converted and the report
notes the snapshot. The source is never modified.

Returns a **conversion**:

| Field | Holds |
|---|---|
| `tree` | The table for `OptionsKit:Define`. |
| `report` | What changed (see [Reports](#reports)). |
| `paths` | Every converted option path to the original Ace keys, `{ ["general.my_key"] = { "general", "my key" } }`, so an addon can translate paths it stored or prints. |
| `maxDepth` | The longest option path, in keys (at least 1). |
| `optionCount` | The options the converted tree holds, groups and every option inside a `replace` table included, the root excluded: what `Define` counts against `maxOptions`. |

| Option | Default | Meaning |
|---|---|---|
| `uiType` | `"dialog"` | `"dialog"`, `"dropdown"` or `"cmd"`: passed to a source function, set as `info.uiType`, and which per-interface flags fold into `hidden` and `inline`. |
| `uiName` | `"BridgeKit-1"` | `info.uiName`; must have the shape AceConfigRegistry requires (`[A-Za-z]%-[0-9]`, `AceConfigRegistry-3.0.lua:307`). |
| `bind` | none | `{ [path] = "<scope>.<key>..." }`: that option is bound to the SettingsKit database instead of calling its Ace `get` and `set`. Paths are the converted ones. |
| `replace` | none | `{ [path] = option }`: that option or group is replaced by the OptionsKit option given, used as it is: `replace = { profiles = OptionsKit:ProfileOptions(db) }` in place of an AceDBOptions-3.0 group. `ProfileOptions` returns one cached group per database and options, and `Define` refuses a group another defined tree holds. |
| `strict` | `false` | Raise after converting when the report holds any `dropped`, `changed` or `unsupported` entry: `BridgeKit:ConvertAceConfig strict: 3 fields changed or dropped; first: general.scale min (defaultBound)`. |
| `maxOptions` | 1024, OptionsKit's default | The most options converted, groups included; one more raises. `BridgeKit.UNBOUNDED` accepted. |
| `maxDepth` | 8 | The most keys in an option path, 1 to 32, as OptionsKit's `Define`; deeper raises, which also stops a cyclic table. |

A `bind` or `replace` path that names no converted option raises.

### How an option is converted

**Inheritance is resolved.** AceConfigDialog resolves `get`, `set`, `func`,
`confirm`, `validate`, `disabled`, `hidden` and `handler` by taking the
deepest definition on the path from the root (`AceConfigDialog-3.0.lua:131-139`,
`164-185`, `192-199`, `668-694`). OptionsKit has no inheritance, so every
converted option carries the definitions Ace would find for it. OptionsKit
also applies every ancestor's `disabled` and `hidden`, so an option that sets
`false` below a group that sets `true` stays disabled or hidden (reported).

**Callbacks are wrapped.** Each option gets one Ace `info` table, built at
conversion and reused for every call, with the fields AceConfigDialog fills
(`AceConfigDialog-3.0.lua:201-209`): the original keys at `1..n`, `[0]` and
`appName`, `options` (the source root), `arg`, `handler`, `option` (the
original option table), `type`, `uiType` and `uiName`. A function is called
with it and the arguments in Ace's shape; a method name is looked up on the
handler in force **at call time** and called with the handler as its first
argument, then `info` and the rest, and a method still missing then raises
Ace's own message,
`Method <name> doesn't exist in handler for type <field>`
(`AceConfigDialog-3.0.lua:218-221`).

| OptionsKit callback | Calls the Ace callback as |
|---|---|
| `get` | `get(info)`, its first result; `color`: `r, g, b, a = get(info)`, returned as a new `{ r, g, b[, a] }`, or `nil` when `r` is `nil`; `multiselect`: `get(info, key)` for every key of the current values, returned as a new map of booleans (a secret state placed unexamined) |
| `set(value)` | `set(info, value)`; `color`: `set(info, r, g, b, a)`; `multiselect`: `set(info, key, state)` for each key whose state differs from what `get(info, key)` answers, or whose current state is secret |
| `validate(value)` | `validate(info, <the value in set's shape>)`; for a `multiselect`, once per changed key. A string refuses with that message, `false` or `nil` with the option's `usage` or `"invalid value"`, and any other answer accepts, as in Ace (`741-750`); a secret answer refuses without being compared |
| `func` | `func(info)` |
| `disabled`, `hidden` | the Ace predicate with `info`; any truthy answer counts, and a secret answer counts as `false` without being tested, as OptionsKit counts it |
| `desc` | the Ace `desc` with `info`; `""` when it gives no string |
| `values` | the Ace `values` with `info`; entries whose key is not a string or number, or whose label is not a string, are left out |

A `color` or `multiselect` getter allocates a table per `Get`, where
OptionsKit's own getters allocate nothing; an options screen is no hot path.

**Fields.** `name` and `order` given as a function or method are called once,
with the option's Ace `info`, and their result kept, because OptionsKit's
`name` is a string and its `order` a number; a name function that gives no
string leaves the option named by its key. `desc` stays live. Fields that only
choose a presentation (`width`, `descStyle`, `icon`, `image`, `style`,
`childGroups`, ...), custom AceGUI controls and fields OptionsKit cannot
express are dropped and reported. A group's `plugins` are merged into its
`args`, a plugin winning a collision as `GetSubOption` searches plugins first
(`AceConfigDialog-3.0.lua:117-127`). A `range` without `min` gets `0`
(`-math.huge` with a `softMin`) and without `max` gets `100` (`math.huge` with
a `softMax`), as the dialog's slider assumes (`877`); its `step` is kept but
not enforced by OptionsKit, where the dialog snaps to it (`880`).

**Keys.** OptionsKit accepts identifiers as keys (`[%a_][%w_]*`); Ace accepts
any string without control characters (`AceConfigRegistry-3.0.lua:197-205`).
A key longer than 32 bytes is cut and marked `...` in report paths only;
`paths`, `bind` and `replace` use the whole key. A key that is not an
identifier is renamed: every byte outside `[%w_]` becomes
`_`, a leading digit gets a leading `_`, an empty key becomes `_`, and a
collision with a sibling gets `_2`, `_3`, ... in the sorted order of the
original keys, so the result is the same every time. Identifiers keep their
names.

### Reasons

| Reason | Action | When | Ace3 |
|---|---|---|---|
| `evaluatedOnce` | changed | a `name`, `order`, `sorting` or `hasAlpha` function or method, or a `fontSize` function, called once | the dialog calls them on every redraw |
| `presentation` | dropped | a field that only chooses a presentation | `AceConfigRegistry-3.0.lua:71-195` |
| `malformedField` | dropped / unsupported | a field of a type or value OptionsKit refuses although Ace draws it: `args` or a plugin that is not a table, a NaN `order`, a `step` or `bigStep` not above 0, a `softMin` or `softMax` outside the bounds or crossed; `unsupported` for a range whose `min` lies above its `max` | |
| `customControl` | dropped | `control`, `dialogControl`, `dropdownControl`, `itemControl` | AceGUI widget names |
| `perInterfaceFlag` | changed / dropped | the `*Hidden` and `*Inline` flags of `uiType`, folded into `hidden` and `inline`; the others dropped | `AceConfigDialog-3.0.lua:923-931` |
| `confirmOnValue` | dropped | `confirm` on a value option: OptionsKit confirms only before `Execute` | `765-803` |
| `dynamicConfirm` | changed | a `confirm` function or method on an `execute`, which becomes `confirm = true` (or `confirmText`) | |
| `cannotOverrideAncestor` | changed | an option clearing a `disabled` or `hidden` an ancestor sets | |
| `noAccessor` | unsupported | a value option without `get` or `set`, or an `execute` without `func`, after inheritance | |
| `missingMethod` | changed | a method name that names nothing on its handler at conversion, for a wrapped callback, one evaluated once and `confirm`; the wrapper raises Ace's message if it is still missing when called | `218-221` |
| `unknownType` | unsupported | an option whose `type` is unknown (`tristate` included, which no dialog draws), that is not a table, or whose key in `args` is not a string (reported once per group, field `args`) | `AceConfigRegistry-3.0.lua:231-235` |
| `unknownField` | dropped | a field no kind knows | Ace's validator refuses it |
| `pluginShadowed` | dropped | an `args` key a plugin key replaces, or a key an earlier plugin defines, plugins merged in the sorted order of their names | `AceConfigDialog-3.0.lua:117-127` |
| `lineCount` | changed | `multiline` given as a line count, which becomes `true` | |
| `defaultBound` | changed | a `range` without `min` or `max` | `877` |
| `stepNotEnforced` | changed | a `range` with a `step` | `880` |
| `valueKey` | dropped | `values` entries with a key that is not a string or number, or a label that is not a string; for a values function, reported once per option when first met | |
| `sortingKey` | dropped | a `sorting` that is not a list of keys of a `values` table | |
| `emptyValues` | unsupported | a `select` or `multiselect` with no usable values | |
| `multiselectTristate` | changed | a `multiselect` with `tristate`: OptionsKit holds booleans, so a third state reads as `false` | |
| `fontSize` | dropped | a `fontSize` other than `"small"`, `"medium"`, `"large"` | |
| `identifier` | renamed | a key that is not an identifier | `AceConfigRegistry-3.0.lua:197-205` |
| `boundToDatabase` | changed | an option `bind` names | |
| `replaced` | changed | an option `replace` names | |
| `sourceFunction` | changed | `source` was a function, converted as one snapshot | `AceConfigRegistry-3.0.lua:331-341` |

### Errors

At the caller's line: a bad `appName` or option, a `source` that is not a
table or a function, a source function that does not return a table
(`BridgeKit:ConvertAceConfig source function did not return a table`), a root
that is not a group (`source.type must be "group" at the root`, the rule of
`AceConfigRegistry-3.0.lua:319-321`), a `bind` or `replace` path that names no
converted option, a limit passed, and a secret anywhere in an option's fields,
keys or results evaluated at conversion, named by its path:
`BridgeKit:ConvertAceConfig source.args.general.disabled must not be a secret
value`. An option whose type is unknown or that is not a table is no error:
it is left out and reported (`unknownType`). An error the addon's own callback
raises during the conversion (a `name` function, the source function)
propagates unchanged.

## `BridgeKit:DefineAceConfig(addonName, source[, options])`

`ConvertAceConfig(addonName, source, options)`, then `OptionsKit:Define(addonName,
conversion.tree, { db = options.db, maxOptions = options.maxOptions, maxDepth =
conversion.maxDepth })`, with `maxDynamicEntries` raised to the largest
`values` table when one holds more than 1024 entries (the addon's own data,
which Ace accepted). Returns the tree handle and the report. Accepts
every conversion option plus `db`, the SettingsKit database `bind` needs.
Without OptionsKit: `BridgeKit:DefineAceConfig requires OptionsKit API 1,
which is not loaded (absent)`. An error `Define` raises (a pattern it refuses,
`min` above `max`, a `bind` into an undeclared scope) reaches the caller's line
with OptionsKit's message after `BridgeKit:DefineAceConfig `.

What the adapter deliberately does not do: re-validate the table per interface
type (OptionsKit checks once at `Define`), reproduce
`AceConfigRegistry:NotifyChange` (a renderer refreshes from `tree:OnChange`),
or convert an AceDBOptions-3.0 group (pass `replace` with
`OptionsKit:ProfileOptions(db)` instead).

## The AceDB importer

An AceDB-3.0 saved variable and SettingsKit's saved table
([`settingsKit/docs/API.md`](../../settingsKit/docs/API.md#the-saved-table))
name most of their sections alike and key them alike, which is what makes a
faithful import possible. The importer rebuilds the SettingsKit layout from
the AceDB table: every value checked against the schema the addon will open
with, every AceDB default that differs from the SettingsKit default written as
a value, and everything it cannot carry over reported.

### The plan

`source` is the AceDB table, or the name of the global holding it. `plan`:

| Field | Required | Meaning |
|---|---|---|
| `schema` | yes | The schema table the addon passes to `SettingsKit:Open`: scope name (`global`, `profile`, `char`, `realm`, `class`, `faction`) to a SchemaKit `table` node or sealed schema. |
| `aceDefaults` | no, recommended | The defaults table the addon passed to `AceDB:New`. Without it, a value AceDB stripped because it equalled its default cannot be told from one never set; the report says so once (`aceDefaultsUnknown`) and nothing is materialised. |
| `scopes` | no | `{ race = { into = "global", field = "byRace" } }`: an AceDB scope SettingsKit lacks (`race`, `factionrealm`, `factionrealmregion`, `locale`) lands in a declared `map` field of the global scope, each AceDB key a map key. Without an entry the scope is dropped. |
| `namespaces` | no | `{ Bars = { field = "bars", defaults = <that namespace's AceDB defaults> } }`: each section of the namespace lands under `field` of the same SettingsKit section (`profiles[p].bars`, `char[k].bars`, `global.bars`, ...). Without an entry the namespace is dropped. |
| `renameProfile` | no | `function(name) -> string|nil`, called for every profile: its name in SettingsKit, or `nil` to drop it. |
| `renameCharacter` | no | `function(key) -> string|nil`: a character's key in SettingsKit, or `nil` to drop it; applied to `char` and `profileKeys`. |
| `version` | `ImportAceDB` only | The `options.version` the addon passes to `SettingsKit:Open`, stamped into the target so no migration runs over imported data. |
| `backup` | `AceDBMigration`: yes; `ImportAceDB`: no | The name of a global listed in `## SavedVariables` that receives the backup. |
| `replaceBackup` | no | `true` lets the backup overwrite a backup global that holds data. |
| `onReport` | `AceDBMigration` only | `function(report)`, called once the new layout is built. |

An unknown field, a missing `schema`, a scope SettingsKit does not know, a
scope schema that is not a SchemaKit `table`, a `scopes` destination other than
a declared `map` field of the global scope, a namespace `field` declared in no
scope as a record or map, a field of the wrong type, a secret plan field or
source argument, and SchemaKit absent raise at the caller. An error a rename
function raises propagates unchanged.

### The three methods

- **`PreviewAceDB(source, plan)`** returns the report an import would
  produce, with the same entries and counts, and writes nothing. When the
  source is larger than `maxImportEntries` it returns the report so far and
  `"maxImportEntries"`.
- **`ImportAceDB(source, targetName, plan)`** writes into `targetName`, a
  global that must be `nil` or an empty table (`nil, "targetNotEmpty"`
  otherwise; an empty table is filled in place). With `plan.backup` it first
  writes the backup (`nil, "backupTaken"` when that global holds data and
  `replaceBackup` is not set). It returns the report, or `nil,
  "maxImportEntries"` and the report so far, having written nothing. The
  source is never written. The addon then calls `SettingsKit:Open(targetName,
  schema, { version = plan.version, ... })`.
- **`AceDBMigration(plan)`** returns a step for `SettingsKit:Open(name, schema,
  { version = n, migrations = { [n] = BridgeKit:AceDBMigration(plan) } })`, for
  an addon that keeps its saved-variable name. SettingsKit hands the step a
  copy of the saved table and commits it only when the step returns. The step
  builds the new layout, calls `onReport`, and only then moves the old
  contents into the backup global and leaves the new layout in the table it
  was given, so a step that raises (a backup global already holding data, a
  source past `maxImportEntries`, an `onReport` that raises) leaves the saved
  table untouched and no backup behind. SettingsKit's own `version` key is
  neither imported nor backed up.

```lua
-- A new saved variable, MyAddonSettings, next to the old MyAddonDB.
if type(MyAddonSettings) == "nil" then
  local report, reason = BridgeKit:ImportAceDB("MyAddonDB", "MyAddonSettings", {
    schema = schema,
    aceDefaults = aceDefaults,
    version = 1,
    backup = "MyAddonDB_Backup",
  })
end
local db = SettingsKit:Open("MyAddonSettings", schema, { version = 1 })
```

The backup is `{ bridgeKit = <REVISION>, source = <the source global's name or
"table">, commit = ACE_BASELINE.commit, data = <a copy of the source> }`,
bounded by `maxImportEntries`, a table reached twice copied once.

### Section by section

| AceDB section | SettingsKit destination | Notes |
|---|---|---|
| `profiles[name]` | `profiles[name]` | `renameProfile` first; a name longer than SettingsKit's `maxProfileNameLength` (64 bytes unless SettingsKit says otherwise) is dropped (`profileNameTooLong`), so is a blank one (`profileNameBlank`). Profiles renamed onto one name collide (`keyCollision`, below). An empty profile stays a profile. |
| `profileKeys[key]` | `profileKeys[key]` | Kept when it names an imported profile, under its new name; otherwise dropped (`danglingProfileKey`), and that character starts on the default profile. A secret choice is dropped (`secretValue`) without being looked up. |
| `char[key]`, `realm[key]`, `class[key]`, `faction[key]` | the same | `char` keys through `renameCharacter`. |
| `global` | `global` | |
| `race`, `factionrealm`, `factionrealmregion`, `locale` | the map field `plan.scopes` names, or dropped | `unsupportedScope`. |
| `namespaces[n]` | each section under `plan.namespaces[n].field`, or dropped | `unmappedNamespace`; a section whose scope does not declare the field is dropped (`undeclaredScope`). Where the field already holds an entry (from the main sections or another namespace), the entry already there is kept and the newcomer dropped (`keyCollision`); a map field stops at its `max` (`mapFull`). |
| a scope the schema does not declare | dropped | `undeclaredScope`. |
| any other top-level key | dropped | `unknownTopLevelKey`; the backup keeps it. |

Keys of `profiles`, `profileKeys`, `char` and namespace sections that land on
one layout key after `renameProfile` or `renameCharacter` collide: the key that
keeps its own name wins, otherwise the first in sorted key order, and every
other is dropped (`keyCollision`). Which entry survives never depends on the
order the client saved them in.

The preview also reports the current character's SettingsKit key missing from
`char` (`currentCharacterMissing`), a character whose `UnitNameUnmodified`
differs from its `UnitName`, as AceDB and SettingsKit key it apart
(`characterKeyMismatch`), and, on a client whose interface lies between 16000
and 19999, where AceDB keys characters and realms by name and ruleset, the
`char` and `realm` sections (`characterKeyMismatch`, `realmKeyMismatch`).

### Values and defaults

Every value is checked before it is written: a probe table holding only the
path to the value is checked with the scope's sealed schema, which is sound
because every field of a SettingsKit record is optional. Records and maps are
walked into; every other kind (scalars, arrays, `any`, `oneOf`, `custom`) is
checked whole. A refused value is dropped (`schemaRefused`) with a `detail`
holding SchemaKit's path, rule and expectation, never the value; an undeclared
field of a closed record is refused the same way, and one of an open record is
kept, its AceDB default merged in. A map past its `max` keeps its first keys
in sorted key order, then the keys only defaults name (`mapFull` for every key
it cannot take, a default's included). A map entry the source holds stays an
entry even when nothing in it differs from the defaults. A function, userdata, coroutine or a table with a metatable is
dropped (`notStorable`), a secret key or value too (`secretValue`), and the
walk stops at SchemaKit's `maxDepth` (`tooDeep`).

Where the source holds nothing, with `A` the AceDB default (resolved with its
`"*"` and `"**"` wildcards; `"**"` also merges, at every depth, into the table
a key the defaults name holds) and `S` the SettingsKit default (the record's
own default first, then the field's):

| Source holds | `A` versus `S` | Written | Report |
|---|---|---|---|
| a value | — | the value, if the schema accepts it | counted as `imported` |
| a table, `A` a table | — | the table with `A` merged in as AceDB reads it, if the schema accepts it | `materialised` when the merge added anything, otherwise `imported` |
| nothing | equal | nothing: both read `S` | — |
| nothing | `A` absent, `S` present | nothing: the field reads `S` where it read nothing | `changed`, `defaultDiffers`, once per field |
| nothing | different | `A`, if the schema accepts it | `materialised`, `defaultDiffers` |

A materialised `A` the schema refuses is dropped (`schemaRefused`) and the
field reads `S`. A map's `"*"`/`"**"` default is applied to every key the map
holds; when it differs from the map's wildcard default, the report says so once
per map (`changed`, `wildcardDefaultDiffers`), because every key never saved
reads `S` from now on. A key the AceDB defaults name explicitly is materialised
when the source lacks it and the defaults differ; so is a key the map's own
SettingsKit default names, read against AceDB's wildcard. An AceDB default for
a key a closed record does not declare cannot be written (`changed`,
`defaultDiffers`). For a scope whose AceDB defaults differ from SettingsKit's
(a scope AceDB has no defaults for included), an entry the source lacks entirely (a
character that never saved anything) reads `S` where it read `A`; the report
says so once per field (`changed`, `defaultDiffers`, path `<scope>.<field>`).
After the import SettingsKit's compaction removes only values equal to `S`, so
it never changes what a field reads.

### Import reasons

| Reason | Action | When |
|---|---|---|
| `defaultDiffers` | materialised / changed | an AceDB default written as a value; or, per field of a scope, entries the source lacks read SettingsKit's default |
| `wildcardDefaultDiffers` | changed | a map's AceDB wildcard default differs from its SettingsKit wildcard default |
| `aceDefaultsUnknown` | changed | no `plan.aceDefaults` |
| `schemaRefused` | dropped | the schema refuses the value (`detail` says why) |
| `mapFull` | dropped | a map past its `max` |
| `notStorable` | dropped | a function, userdata, coroutine, a table with a metatable, or a section or entry that is not a table |
| `secretValue` | dropped | a secret key or value |
| `tooDeep` | dropped | nesting past SchemaKit's `maxDepth` |
| `profileNameTooLong`, `profileNameBlank` | dropped | a profile name SettingsKit refuses |
| `keyCollision` | dropped | a key renamed onto one another key kept, or an entry a namespace brings where the field already holds one |
| `renamedProfile`, `renamedCharacter` | renamed / dropped | `renameProfile` or `renameCharacter` gave another name, or `nil` |
| `danglingProfileKey` | dropped | a profile choice naming no imported profile |
| `currentCharacterMissing`, `characterKeyMismatch`, `realmKeyMismatch` | changed | character and realm keys that will not line up |
| `unsupportedScope`, `unmappedNamespace`, `undeclaredScope`, `unknownTopLevelKey` | dropped | sections the plan or the schema gives no destination |

## The AceComm channel

```lua
local CommKit = Registry:Get("commKit", 1)
local comm = CommKit:ForAddon("MyAddon")

local channel = BridgeKit:OpenAceComm(comm, "MyAddon", function(prefix, message, distribution, sender)
  -- `message` is whole: AceComm's multipart framing is already undone.
end)
channel:Send({ text = text, distribution = "GUILD" })
```

A channel writes the addon messages AceComm-3.0 writes for a text and reads
what AceComm-3.0 peers send, with AceComm's rules (design section 8.3). It
needs CommKit API 1 with raw addon messages (`RegisterRaw`, `SendRaw`,
CommKit 0.5.0 or later); without it `OpenAceComm` raises at the caller. Its
traffic leaves through CommKit's queue and bandwidth budget, like the addon's
own CommKit messages.

### `BridgeKit:OpenAceComm(scope, prefix, callback[, options])`

- `scope`: an open CommKit scope (`CommKit:ForAddon(name)`,
  `CommKit:CreateScope()`, a module's `scope.Comm`). The channel's raw
  registration belongs to it: closing the scope closes the channel.
- `prefix`: 1 to 16 bytes, not secret.
- `callback(prefix, message, distribution, sender)`: AceComm's
  `OnCommReceived` signature, called once per whole message. An error it
  raises goes to the client's error handler, and the next channel on the
  prefix is still called.
- Returns the channel, or `nil` and CommKit's registration refusal
  (`"full"`, `"closed"`, `"invalidPrefix"`, `"maxPrefixes"`,
  `"framingConflict"` when the prefix carries CommKit's own framing).

| Option | Default | Meaning |
|---|---|---|
| `priority` | `"NORMAL"` | `"ALERT"`, `"NORMAL"` or `"BULK"`, mapped to `CommKit.Priority`. Fixed per prefix while a channel is open on it: a later channel stating another raises, and `Close` cancels a channel's queued sends, so the parts of different texts on one prefix never interleave. |
| `wire` | `1` | The wire version; any other raises. |
| `ambiguate` | `true` | Pass `sender` through `Ambiguate(sender, "none")` before the callback, as AceComm does. Streams are always keyed by the unmodified sender. |

### The channel

| Method | Returns | Purpose |
|---|---|---|
| `Send(request)` | CommKit's send handle, or `nil, reason` | Send `request.text` (`distribution`, `target`, `onProgress`, `onComplete` as CommKit's `SendRaw` takes them). |
| `Close()` | `true`, or `false` when already closed (by `Close` or with its scope) | End the raw registration and cancel the channel's queued sends; the prefix's held streams go with its last channel. |
| `IsClosed()` | boolean | Closed by `Close` or with its scope. |
| `GetPrefix()`, `GetPriority()`, `GetWireVersion()` | string, string, integer | What the channel was opened with. |

`Send` returns `nil` and `"closed"`, `"nulByte"` (AceComm forbids NUL),
`"tooLarge"` (more than 4096 messages, about 1 MB) or CommKit's own refusal
(`"badDistribution"`, `"queueFull"`, `"unavailable"`, ...). A request that is
not a table, an unknown field, a `text` that is not a non-empty string or is
secret, and an argument CommKit raises for raise at the caller.

**Sending.** A text of at most 255 bytes whose first byte is not `01`-`09`
leaves as one message, unchanged. One whose first byte is `01`-`09` gets the
escape byte `04` in front while that still fits in 255 bytes. Anything longer
is split into 254-byte parts after a control byte: `01` first, `02` for each
middle part, `03` last. All parts of one text leave through `SendRaw` as one
message of parts, so they stay in order.

**Receiving.** `01` opens a stream for the prefix, distribution and sender,
replacing one already held; `02` adds to it; `03` adds and delivers it; a
`02` or `03` with no stream is dropped. `04` delivers the rest of the message,
`05`-`09` are reserved and ignored, anything else is a whole message.
Several channels on one prefix share one reassembly: only the first channel
still open reads the raw messages, and each whole message goes to every open
channel on the prefix in the order they were opened. A callback may close or
open channels: the message in flight goes to the channels open when it
arrived (one closed meanwhile is skipped, one opened meanwhile receives the
next message), and it is read once however the reading channel closes. When
the last channel on a prefix closes, with `Close` or with its scope, the
prefix's held streams are released (for a scope, at the next message,
`OpenAceComm` or `GetStatistics`).

**Bounds Ace lacks.** At most `maxAceStreams` streams are held, at most
`maxAceStreamsPerSender` per sender, at most `maxAceStreamBytes` bytes in one
stream and `maxAceSpoolBytes` in all. A stream past a bound is dropped and
counted; drops are reported through the client's error handler at most once
per sender per minute, and past `maxDropReportSenders` senders the others
share one report. A stream whose last part is older than `aceStreamTimeout`
seconds is dropped when the next message on any AceComm prefix arrives; a
quiet session keeps its stale streams until then, within `maxAceSpoolBytes`.

### `BridgeKit:GetStatistics()`

A fresh table: `aceMessagesSent`, `acePartsSent`, `aceMessagesReceived`,
`aceBytesReceived`, `aceStreamsOpened`, `aceStreamsCompleted`,
`aceStreamsReplaced` (a new `01` while one was held), `aceStreamsExpired`,
`aceStreamsOversize`, `aceStreamsRefusedQuota`, `aceOrphanParts` (`02`/`03`
without a stream), `aceReservedControl` (`05`-`09`), and the current
`openStreams` and `spoolBytes`. The counters are shared by every embedded copy
and survive an in-place upgrade.

## Reports

```lua
report = {
  kind = "aceConfig",
  entries = { { path = "general.scale", field = "step", action = "changed", reason = "stepNotEnforced" } },
  counts = { converted = 41, dropped = 6, changed = 3, renamed = 1, unsupported = 0 },
  truncated = 0,
}
```

A plain table the caller owns, `kind = "aceConfig"` for a conversion and
`"aceDB"` for an import. `entries` are in walk order, at most
`maxReportEntries`; `path` is the converted option path or the saved-variable
path (`""` for the root), `field` the Ace field the entry is about when there
is one, and `detail`, when present, text BridgeKit wrote. **No entry holds a
value from the source**: an option path is made of converted keys, which are
identifiers; a saved-variable path renders keys as SchemaKit does (identifiers
dotted, numbers and booleans bracketed, other strings quoted with `|` doubled
and control bytes escaped); keys longer than 32 bytes are cut and marked
`...`. `counts` holds every action of the kind, `0` included: `converted`,
`dropped`, `changed`, `renamed`, `unsupported` for a conversion, `imported`,
`materialised`, `dropped`, `changed`, `renamed`, `unsupported` for an import. A
converted option and an imported value are counted, never listed; `truncated`
counts the entries past the limit, whose counts are still included.

`FormatReport(report[, maxLines])` returns `"<path> <field>: <action>
(<reason>)"` lines, `(root)` for the root's path, at most `maxLines` (50 by
default), then one summary line: `41 converted, 6 dropped, 3 changed, 1
renamed`, with `N more not shown` when entries were left out.

## Limits

The limits are shared by every embedded copy and every consumer in the
session, kept across an in-place upgrade, set with `SetLimits` and read with
`GetLimits`. Each call reads them when it starts.

| Limit | Default | `UNBOUNDED`? | Ceiling and reason |
|---|---|---|---|
| `maxDepth` | 16 | no: the reader and writer recurse on the Lua call stack | 128 |
| `maxValues` | 65536 | yes: `maxTextBytes` still bounds it | 2^24 |
| `maxStringLength` | 65536 | yes: `maxTextBytes` still bounds it | 2^30 |
| `maxTextBytes` | 1048576 | no: a peer chooses the size of the text a reader is given | 2^26 |
| `maxListValues` | 4096 | no: `AceDeserialize` returns its values through `unpack` | 7900 |
| `maxReportEntries` | 1024 | yes: a report is the caller's own memory | 2^24 |
| `maxImportEntries` | 65536 | yes: the source is the addon's own data | 2^30 |
| `maxAceStreams` | 64 | no: other players grow it | 1024 |
| `maxAceStreamsPerSender` | 4 | no: other players grow it | 64 |
| `maxAceStreamBytes` | 65536 | no: a peer chooses it | 1048576 |
| `maxAceSpoolBytes` | 1048576 | no: other players grow it | 2^26 |
| `aceStreamTimeout` | 30 (seconds) | no: a stream a peer never finishes would be held forever | 600 |
| `maxDropReportSenders` | 64 | no: other players grow it | 1024 |

A top-level table is depth 1. `SetLimits` raises at the caller, before
changing anything, on a table that is not one, an unknown name, a secret key
or value, a value that is not an integer from 1 to the ceiling, or `UNBOUNDED`
where the table says no, naming why:
`BridgeKit:SetLimits limits.maxDepth cannot be BridgeKit.UNBOUNDED because the
reader and writer recurse on the Lua call stack; use an integer from 1 to 128`.

Lowering a stream limit does not drop streams already held; it applies to
the next part received. A conversion's own bounds, `maxOptions` and `maxDepth`, are
options of the call, because the tree belongs to one call, as OptionsKit's
are.

## Secret values

`issecretvalue` is read at every call. A secret argument, a secret value or
key inside the values given to `AceSerialize`, a secret `text`, a secret
`SetLimits` key or value, a secret option field, key or option of an AceConfig
source, and a secret result of a `name`, `order` or `hasAlpha` evaluated at
conversion raise at the caller. A secret answer of a wrapped `validate`
refuses without being compared; a secret `disabled` or `hidden` answer counts
as `false`, as OptionsKit counts it. A secret `OpenAceComm` scope, prefix or
option, and a secret `Send` field or text raise at the caller. Error messages
never format a
secret: the one caller value a message names, an unknown limit name, is
checked first, and only a string is named.

## Cost

`AceSerialize` writes into one piece array it reuses from call to call (a
token and its data as separate pieces) and allocates only the result:
198 bytes for a small record, where AceSerializer-3.0 allocates 201.
`AceDeserialize` first copies the text without its control bytes and spaces,
as Ace does, then cuts each token with one pattern match and allocates the
tables and strings it returns. Both are linear in the text and recurse once
per table level.

Measured on host Lua 5.1 against AceSerializer-3.0 itself
([`docs/BENCHMARKS.md`](../../../docs/BENCHMARKS.md), "AceSerializer-3.0
text", the run of 2026-11-15 on a machine that was not idle), over the
`codec` workload's payloads:

| Operation | BridgeKit ÷ Ace3 | Bytes per operation (BridgeKit against Ace3) |
|---|---|---|
| encode a small, medium and large payload | 1.71×–1.79× | 198 / 201, 4.8 KB / 4.8 KB, 28 KB / 28 KB |
| decode them | 1.36×–1.58× | 832 / 600, 26 KB / 20 KB, 94 KB / 71 KB |

The gap is the work Ace3 does not do: the secret probe of every value and the
value-count, string-length and depth bounds on both sides, cycle detection on
write, and on read the refusal of every input Ace would raise on.

`ConvertAceConfig`, the importer and the channel are measured by the specs'
shape, not timed: a conversion and an import run once per load or install,
and a channel's per-message cost is CommKit's (`docs/BENCHMARKS.md`,
"Multipart addon messages") plus one table read per message and one
`table.concat` per reassembled stream.

## Upgrades

The package state (`_state`) holds the limits, the `UNBOUNDED` sentinel, the
read-only baseline and the AceComm state (open prefixes, held streams,
counters, the channel prototype), so every embedded copy and every revision
publishes the same tables, and a channel opened before an upgrade uses the
new revision's methods and, through a trampoline in the state, its receive
code. A newer compatible revision loaded over an older one keeps
that state and replaces the methods; an older copy loaded later steps aside.
A limit a later revision adds starts at its default over an inherited state.

## Testing

`tests/fixtures/AceSerializerFixtures.lua` is output recorded from Ace3 at the
pinned commit by `python3 -m tooling.fixtures.ace_serializer`, over this
project's own inputs: what `Serialize` wrote for each value and what
`Deserialize` answered for each text, malformed ones included. The specs
require BridgeKit to write the same bytes for every recorded value and to read
the same values, or the reason matching Ace's error, for every recorded text.
No Ace3 source or test is in the repository (design section 3.2).
