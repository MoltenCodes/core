# BridgeKit API

BridgeKit is the MoltenCodes package that moves an addon from Ace3 to the Kits
without breaking what its players already have. Its canonical design is
[`docs/BRIDGE_KIT_DESIGN.md`](../../../docs/BRIDGE_KIT_DESIGN.md); this
document is the contract of what the current revision ships.

**Revision 2 ships the AceSerializer-3.0 wire format** (design step N1, revision
1) **and the AceConfig-3.0 adapter** (step N2). The AceDB importer and the
AceComm channel follow in later revisions (design section 15); until then
their methods do not exist.

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
OptionsKit's files too (Registry, SignalKit, SchemaKit, OptionsKit).

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
| `SetLimits(limits)` | nothing | Change any subset of the [limits](#limits). |
| `GetLimits()` | a fresh table | The limits. |
| `UNBOUNDED` | table | Sentinel for the limits that accept it. |
| `ACE_WIRE_VERSION` | `1` | The newest AceComm wire version this revision speaks (design section 8.5); no channel ships yet. |
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
| `optionCount` | Options converted, groups included, the root excluded. |

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
| `get` | `get(info)`, its first result; `color`: `r, g, b, a = get(info)`, returned as a new `{ r, g, b[, a] }`, or `nil` when `r` is `nil`; `multiselect`: `get(info, key)` for every key of the current values, returned as a new map of booleans |
| `set(value)` | `set(info, value)`; `color`: `set(info, r, g, b, a)`; `multiselect`: `set(info, key, state)` for each key whose state differs from what `get(info, key)` answers |
| `validate(value)` | `validate(info, <the value in set's shape>)`; for a `multiselect`, once per changed key. `true` accepts, a string refuses with that message, anything else with the option's `usage` or `"invalid value"`; a secret answer refuses without being compared |
| `func` | `func(info)` |
| `disabled`, `hidden` | the Ace predicate with `info`; OptionsKit counts a secret answer as `false` |
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
A key that is not an identifier is renamed: every byte outside `[%w_]` becomes
`_`, a leading digit gets a leading `_`, an empty key becomes `_`, and a
collision with a sibling gets `_2`, `_3`, ... in the sorted order of the
original keys, so the result is the same every time. Identifiers keep their
names.

### Reasons

| Reason | Action | When | Ace3 |
|---|---|---|---|
| `evaluatedOnce` | changed | a `name`, `order`, `sorting`, `hasAlpha` or `fontSize` function or method, called once | the dialog calls them on every redraw |
| `presentation` | dropped | a field that only chooses a presentation, or a kept field of a type OptionsKit refuses | `AceConfigRegistry-3.0.lua:71-195` |
| `customControl` | dropped | `control`, `dialogControl`, `dropdownControl`, `itemControl` | AceGUI widget names |
| `perInterfaceFlag` | changed / dropped | the `*Hidden` and `*Inline` flags of `uiType`, folded into `hidden` and `inline`; the others dropped | `AceConfigDialog-3.0.lua:923-931` |
| `confirmOnValue` | dropped | `confirm` on a value option: OptionsKit confirms only before `Execute` | `765-803` |
| `dynamicConfirm` | changed | a `confirm` function or method on an `execute`, which becomes `confirm = true` (or `confirmText`) | |
| `cannotOverrideAncestor` | changed | an option clearing a `disabled` or `hidden` an ancestor sets | |
| `noAccessor` | unsupported | a value option without `get` or `set`, or an `execute` without `func`, after inheritance | |
| `missingMethod` | changed | a method name that names nothing on its handler at conversion; the wrapper raises Ace's message if it is still missing when called | `218-221` |
| `unknownType` | unsupported | an option whose `type` is unknown (`tristate` included, which no dialog draws), or that is not a table | `AceConfigRegistry-3.0.lua:231-235` |
| `unknownField` | dropped | a field no kind knows | Ace's validator refuses it |
| `pluginShadowed` | dropped | an `args` key a plugin key replaces | `AceConfigDialog-3.0.lua:117-127` |
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

At the caller's line: a bad `appName`, a `source` that is not a table or a
function, a source function that does not return a table
(`BridgeKit:ConvertAceConfig source function did not return a table`), a root
that is not a group (`source.type must be "group" at the root`, the rule of
`AceConfigRegistry-3.0.lua:319-321`), an unknown or malformed option, a limit
passed, and a secret anywhere in an option's fields, named by its path:
`BridgeKit:ConvertAceConfig source.args.general.disabled must not be a secret
value`. An error the addon's own callback raises during the conversion (a
`name` function, the source function) propagates unchanged.

## `BridgeKit:DefineAceConfig(addonName, source[, options])`

`ConvertAceConfig(addonName, source, options)`, then `OptionsKit:Define(addonName,
conversion.tree, { db = options.db, maxOptions = options.maxOptions, maxDepth =
conversion.maxDepth })`. Returns the tree handle and the report. Accepts
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

## Reports

```lua
report = {
  kind = "aceConfig",
  entries = { { path = "general.scale", field = "step", action = "changed", reason = "stepNotEnforced" } },
  counts = { converted = 41, dropped = 6, changed = 3, renamed = 1, unsupported = 0 },
  truncated = 0,
}
```

A plain table the caller owns. `entries` are in walk order, at most
`maxReportEntries`; `path` is the converted path (`""` for the root) and
`field` the Ace field the entry is about, when there is one. **No entry holds
a value from the source**: paths are converted keys, which are identifiers,
each longer than 32 bytes cut and marked `...`. `counts` holds every action,
`0` included; a converted option is counted, never listed; `truncated` counts
the entries past the limit, whose counts are still included.

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

A top-level table is depth 1. `SetLimits` raises at the caller, before
changing anything, on a table that is not one, an unknown name, a secret key
or value, a value that is not an integer from 1 to the ceiling, or `UNBOUNDED`
where the table says no, naming why:
`BridgeKit:SetLimits limits.maxDepth cannot be BridgeKit.UNBOUNDED because the
reader and writer recurse on the Lua call stack; use an integer from 1 to 128`.

The design's other limits (imports and AceComm streams) arrive with the parts
that use them. A conversion's own bounds, `maxOptions` and `maxDepth`, are
options of the call, because the tree belongs to one call, as OptionsKit's
are.

## Secret values

`issecretvalue` is read at every call. A secret argument, a secret value or
key inside the values given to `AceSerialize`, a secret `text`, a secret
`SetLimits` key or value, a secret option field, key or option of an AceConfig
source, and a secret result of a `name`, `order` or `hasAlpha` evaluated at
conversion raise at the caller. A secret answer of a wrapped `validate`
refuses without being compared; a secret `disabled` or `hidden` answer counts
as `false`, as OptionsKit counts it. Error messages never format a
secret: the one caller value a message names, an unknown limit name, is
checked first, and only a string is named.

## Cost

`AceSerialize` builds the text from one table of pieces and allocates one
work record per call; `AceDeserialize` first copies the text without its
control bytes and spaces, then cuts one string per token. Both are linear in
the text and recurse once per table level.

## Upgrades

The package state (`_state`) holds the limits, the `UNBOUNDED` sentinel and
the read-only baseline, so every embedded copy and every revision publishes the
same two tables. A newer compatible revision loaded over an older one keeps
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
