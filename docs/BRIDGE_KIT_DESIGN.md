# BridgeKit design baseline

> **Status:** design baseline, written 2026-09-25 for review; **not
> implemented**. Package N in
> [`ROADMAP.md`](ROADMAP.md#package-n--bridgekit-migrating-from-ace3). Code
> starts only after the owner has answered the
> [open questions](#16-open-questions-for-the-owner) and said go.
>
> This document is the canonical design of `bridgeKit`, the MoltenCodes
> package that makes migrating an addon from Ace3 a product feature: an
> adapter from AceConfig-3.0 options tables to OptionsKit trees, an importer
> from AceDB-3.0 saved variables into SettingsKit databases, and a wire
> adapter that speaks AceComm-3.0 and AceSerializer-3.0 so an addon can move
> while its peers still run the Ace3 version. The recipes that need no
> BridgeKit code are in [`MIGRATING_FROM_ACE3.md`](MIGRATING_FROM_ACE3.md).
> When a decision recorded here changes, this document changes in the same
> commit.

## Contents

1. [Overview](#1-overview)
2. [Goals and non-goals](#2-goals-and-non-goals)
3. [Sources, citations and licence](#3-sources-citations-and-licence)
4. [Position in the repository](#4-position-in-the-repository)
5. [Facade API](#5-facade-api)
6. [AceConfig adapter](#6-aceconfig-adapter)
7. [AceDB importer](#7-acedb-importer)
8. [Wire adapter: AceSerializer and AceComm](#8-wire-adapter-aceserializer-and-acecomm)
9. [Limits](#9-limits)
10. [Secret values](#10-secret-values)
11. [Errors](#11-errors)
12. [Performance](#12-performance)
13. [Testing](#13-testing)
14. [Documentation deliverables](#14-documentation-deliverables)
15. [Delivery sequence](#15-delivery-sequence)
16. [Open questions for the owner](#16-open-questions-for-the-owner)
17. [Decisions summary](#17-decisions-summary)

## 1. Overview

An addon written on Ace3 carries three things it cannot rewrite by hand
without risk: an options table the UI is built from, a saved variable its
players' settings live in, and a wire format its peers speak. Everything else
Ace3 offers (AceAddon, AceEvent, AceTimer, AceHook, AceConsole, AceLocale,
AceGUI and the rest) maps onto existing Kits line by line, and
`MIGRATING_FROM_ACE3.md` gives those recipes. The three remaining pieces need
code that runs once or runs for a transition period:

| Piece | What BridgeKit does | Where it lands |
|---|---|---|
| AceConfig-3.0 options table | Converts a documented subset into an OptionsKit tree, calling the addon's existing Ace `get`/`set`/`func`/`validate` handlers, with a report of every field it dropped or whose meaning changed. | OptionsKit, rendered by WidgetKit and CommandKit |
| AceDB-3.0 saved variable | Copies profiles, profile choices, every AceDB scope and namespaces into a SettingsKit layout, validated against the SettingsKit schema, preserving what each value read under AceDB's defaults; previews first, keeps a backup, never mutates the source. | SettingsKit |
| AceComm-3.0 / AceSerializer-3.0 traffic | Sends and receives AceComm's multipart format through CommKit's queue and budget, and serialises and decodes AceSerializer's text format, so old and new peers talk during a staged migration. | CommKit |

BridgeKit is a migration tool. An addon uses it for as long as it has Ace3
data or Ace3 peers, and then stops embedding it.

## 2. Goals and non-goals

**Goals.**

- **Never silent loss.** Every field, value or byte BridgeKit cannot carry
  over, or carries over with a different meaning, appears in a report entry
  with a machine-readable reason. `strict` mode turns any such entry into an
  error at the caller's line.
- **Copy, never mutate.** The AceDB source table is read with `next` and
  `rawget` only. A backup is written before anything replaces it.
- **Wire-compatible by construction.** The bytes BridgeKit writes are the
  bytes AceComm-3.0 and AceSerializer-3.0 write for the same input on the
  same client; everything they accept, BridgeKit accepts, within documented
  bounds.
- **Minimal footprint** (constitution principle 4b). Each of the three parts
  requires only the Kits it cannot work without: the serializer and the
  AceConfig conversion need Registry alone.
- **Bounded** (principle 4a). Reassembly, reports, imports and decoding are
  bounded by default and opened through `SetLimits` or an option.

**Non-goals.**

- Running Ace3 code, embedding Ace3, or emulating Ace3 APIs (`LibStub("AceDB-3.0")`
  keeps meaning Ace3). BridgeKit converts data and speaks formats; it is not
  a compatibility shim for Ace3 method calls.
- Rendering. OptionsKit trees are rendered by WidgetKit and CommandKit.
- AceGUI widgets, AceConfigDialog layouts (`childGroups` tabs and trees),
  and the Blizzard settings panel registration (`AddToBlizOptions`); those
  belong to the user-interface phase (package M).
- Keeping two databases in sync. The import is one-way and happens once.
- ChatThrottleLib. CommKit's budget replaces it; BridgeKit never loads or
  calls it.

## 3. Sources, citations and licence

### 3.1 The pinned source

Every format and behaviour below was read from Ace3 at commit
`5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773` of
`https://github.com/WoWUIDev/Ace3` (2026-09-25, the commit the external
review used). Citations are `file:line` at that commit, relative to the
repository root. The library revisions at that commit:

| Library | `MINOR` | Cited file |
|---|---|---|
| AceComm-3.0 | 14 | `AceComm-3.0/AceComm-3.0.lua:23` |
| AceSerializer-3.0 | 5 | `AceSerializer-3.0/AceSerializer-3.0.lua:14` |
| AceDB-3.0 | 37 | `AceDB-3.0/AceDB-3.0.lua:44` |
| AceConfigRegistry-3.0 | 22 | `AceConfig-3.0/AceConfigRegistry-3.0/AceConfigRegistry-3.0.lua:14` |

The clone used for this design lives outside the repository. **No Ace3 code
is copied into the repository, now or later.** The formats are described in
this document in our own words, and the implementation is written from these
descriptions. BridgeKit publishes the table above as
`BridgeKit.ACE_BASELINE` so a report can say what it reproduces.

### 3.2 The licence

Ace3's `LICENSE.txt` is a BSD-style licence with two conditions beyond the
usual three-clause text: redistributions of source must retain the notice,
binary redistributions must reproduce it, **"Redistribution of a stand alone
version is strictly prohibited without prior written authorization from the
Lead of the Ace3 Development Team"**, and the names may not be used to
endorse derived products. LibStub (`LibStub/LibStub.lua:2`) and
ChatThrottleLib (`AceComm-3.0/ChatThrottleLib.lua:23`) are public domain.
MoltenCodes is MIT.

What that means here (an engineering reading, not legal advice; the owner
confirms it, [question 5](#16-open-questions-for-the-owner)):

| Artefact | Conclusion |
|---|---|
| BridgeKit source | Written from the format descriptions in this document. Copying or translating Ace3 functions would make the file a derivative under Ace3's licence, which an MIT package cannot carry. Reviewers check this. |
| Format descriptions and citations in this document | Facts about a data format with pointers to where it is defined; no code is reproduced. |
| Test fixtures: recorded AceSerializer strings and AceComm chunk sequences | Output of Ace3 run over **our own input values**, not Ace3 source. Short, factual, and fully determined by the format. Kept under `packages/bridgeKit/tests/fixtures/` with a provenance header (Ace3 commit, library `MINOR`, the input that produced each line, the date and client). Ace3's own `tests/` directory (`tests/serialize.lua`, `tests/AceSerializer-3.0.lua`, `tests/AceComm-3.0.lua`) is **not** copied or adapted. |
| A benchmark or client test that downloads Ace3 at run time | Allowed: fetching Ace3 at the pinned commit into a temporary directory (or a player's own AddOns folder, at the player's request) to measure or to test against is use, not redistribution. The downloaded files must never be committed, packaged into a MoltenCodes bundle or release asset, or uploaded as a public CI artefact or cache, because that would redistribute a standalone Ace3. The tool verifies the commit it fetched and records it in its output. Results may name Ace3; they may not suggest Ace3 endorses MoltenCodes. |

## 4. Position in the repository

### 4.1 Package identity

| Field | Value |
|---|---|
| Package ID | `bridgeKit` |
| Facade | `BridgeKit` |
| API generation | 1 |
| Location | `packages/bridgeKit/` (facade `BridgeKit.lua`, specs, fixtures, docs) |
| Release package | yes: addons embed it for the migration period, and the standalone MoltenCodes addon loads it |

### 4.2 Dependencies

| Dependency | Kind | Used by | Without it |
|---|---|---|---|
| Registry API 2 | required | everything | BridgeKit refuses to load |
| OptionsKit API 1 | optional (`Registry:Find`) | `DefineAceConfig` | `DefineAceConfig` raises at the caller; `ConvertAceConfig` works and returns a plain tree table |
| SchemaKit API 1 | optional | `PreviewAceDB`, `ImportAceDB`, `AceDBMigration` (probe checks against the SettingsKit schema) | those three raise at the caller. SettingsKit requires SchemaKit, so an addon with a SettingsKit schema always has it |
| CommKit API 1, revision with raw addon messages ([prerequisite P1](#43-prerequisites-in-other-kits)) | optional | `OpenAceComm` | `OpenAceComm` raises at the caller naming the revision it needs |
| TimerKit API 1 | optional | expiring AceComm reassembly streams | a stream expires at the next receive on its prefix instead of on time. CommKit requires TimerKit, so a wire channel always has it |

BridgeKit does **not** depend on SettingsKit: the importer writes the saved
table SettingsKit reads ([prerequisite P2](#43-prerequisites-in-other-kits)),
and a SettingsKit database is opened by the addon afterwards. It does not
depend on SignalKit (a channel has exactly one callback, a report is a plain
table), nor on LifecycleKit: BridgeKit owns no per-addon scope. A wire channel
lives inside the CommKit scope the caller passes and dies with it.

**Footprint** (constitution 4b), the files an addon embeds for each part:

| Part | Files |
|---|---|
| AceSerializer only | 2: `Registry.lua`, `BridgeKit.lua` |
| AceConfig conversion to a plain tree | 2 |
| AceConfig straight into OptionsKit | 5: Registry, SignalKit, SchemaKit, OptionsKit, BridgeKit |
| AceDB import | 3: Registry, SchemaKit, BridgeKit (SettingsKit itself is the addon's) |
| AceComm channel | 8: CommKit's seven, BridgeKit |

### 4.3 Prerequisites in other Kits

Two changes to existing Kits are needed before the parts that use them can
ship. Neither is made in this phase.

**P1 — CommKit: raw addon messages.** CommKit frames every message with its
own control byte and header ([`commKit/docs/API.md`](../packages/commKit/docs/API.md#wire-protocol)),
refuses NUL, CR, LF and `|` in text, and parses every message on a
registered prefix as CommKit chunks. AceComm writes bare text and its own
control bytes `01`–`04` (section 8.3), so it cannot travel through
`Send`/`Register`. The addition, additive within CommKit API 1:

- `scope:RegisterRaw(prefix, callback)`: `callback(prefix, text,
  distribution, sender)` for **every** addon message on `prefix`, unparsed,
  with CommKit's isolation, secret dropping and counters. A prefix holds raw
  or framed registrations, never both (`nil, "framingConflict"`), because the
  two readings of the first byte contradict each other.
- `scope:SendRaw({ prefix, parts, distribution, target?, priority?,
  onProgress?, onComplete? })`: `parts` is an array of 1 to 4096 strings of
  1 to 255 bytes without NUL, queued **as one message** in one pipe and sent
  part after part, through the same queue, bucket, throttle backoff and send
  states as `Send`. Refusals as `Send`, plus `"nulByte"`. Cancelling stops
  the remaining parts (no abort exists in AceComm's format; receivers time
  the stream out).

The alternative, BridgeKit calling `C_ChatInfo.SendAddonMessage` itself,
would put a second sender beside CommKit's session-wide budget, which
CommKit's design exists to prevent ([question 1](#16-open-questions-for-the-owner)).

**P2 — SettingsKit: the saved-table layout as a public contract.** The
layout SettingsKit writes (`version`, `global`, `profiles`, `profileKeys`,
`char`, `realm`, `class`, `faction`, reserved `namespaces`) is documented in
[`settingsKit/docs/INTERNALS.md`](../packages/settingsKit/docs/INTERNALS.md#the-saved-table),
which says it is not a public contract for code. The importer writes exactly
that layout, so it must become one: a section of SettingsKit's `API.md`
stating the layout of API generation 1, which a later SettingsKit revision may
extend but not change. Documentation only; no SettingsKit code changes
([question 2](#16-open-questions-for-the-owner)).

## 5. Facade API

Every method is called with a colon on the facade. A dot call, a wrong type,
an unknown option field, a secret argument or a missing optional Kit raises
**at the caller's line** with `BridgeKit:<Method> ...`. Everything that
depends on the data being converted, imported or decoded is a return value or
a report entry, never an error.

### 5.1 Surface

| Member | Returns | Purpose |
|---|---|---|
| `ConvertAceConfig(appName, source[, options])` | conversion | AceConfig table (or function) to a plain OptionsKit tree table and a report. Section 6. |
| `DefineAceConfig(addonName, source[, options])` | tree, report | `ConvertAceConfig`, then `OptionsKit:Define`. |
| `PreviewAceDB(source, plan)` | report | What an import would write, materialise and drop. Writes nothing. Section 7. |
| `ImportAceDB(source, targetName, plan)` | report, or `nil, reason` | Build the SettingsKit layout in an empty target global, before `SettingsKit:Open`. |
| `AceDBMigration(plan)` | function | A SettingsKit migration step (`migrations[n]`) that turns an AceDB table into the SettingsKit layout in place of the same saved variable. |
| `AceSerialize(...)` | `true, text` or `false, reason` | AceSerializer-3.0 text for a list of values. Section 8.1. |
| `AceDeserialize(text)` | `true, ...` or `false, reason` | The values of AceSerializer text. Never raises on malformed text. |
| `OpenAceComm(scope, prefix, callback[, options])` | channel, or `nil, reason` | Send and receive AceComm-3.0 messages on `prefix` through a CommKit scope. Section 8.3. |
| `FormatReport(report[, maxLines])` | array of strings | Display lines for a report, safe to print in chat. |
| `GetStatistics()` | fresh table | Wire counters (section 8.4). |
| `SetLimits(limits)`, `GetLimits()` | nothing; fresh table | Section 9. |
| `UNBOUNDED` | table | Sentinel for the limits that accept it. |
| `ACE_WIRE_VERSION` | `1` | The newest wire version this revision speaks (section 8.5). |
| `ACE_BASELINE` | read-only table | `{ commit = "5e2e0d3b…", AceComm = 14, AceSerializer = 5, AceDB = 37, AceConfigRegistry = 22 }`. |
| `API`, `REVISION` | integers | |

Channel methods: `Send(request)`, `Close()`, `IsClosed()`, `GetPrefix()`,
`GetPriority()`, `GetWireVersion()`.

### 5.2 Reports

Conversion and import share one report shape, a plain table the caller owns:

```lua
report = {
  kind = "aceConfig",        -- or "aceDB"
  entries = {                -- at most maxReportEntries, in walk order
    { path = "general.scale", field = "width", action = "dropped", reason = "presentation" },
    { path = "profiles.Raid Leader", action = "dropped", reason = "profileNameTooLong" },
  },
  counts = { converted = 41, dropped = 6, changed = 3, renamed = 1, unsupported = 0 },
  truncated = 0,             -- entries not stored because maxReportEntries was reached
}
```

- `action` is one of `"dropped"` (the field or value is not carried over),
  `"changed"` (carried over with a different meaning), `"renamed"` (carried
  over under another key), `"unsupported"` (the option or value is left out
  entirely), and, for AceDB, `"materialised"` (a default written as a value,
  section 7.6) and `"imported"` (counted, never listed).
- `reason` is a fixed vocabulary per part (sections 6.5 and 7.9); `detail`,
  when present, is text BridgeKit wrote. **No entry ever contains a value
  from the source**: paths render keys the way SettingsKit and SchemaKit
  render them (identifiers dotted, other keys bracketed and escaped, long
  keys cut), so a report is safe to print and to paste into a bug report.
- `counts` always holds every action, `0` included; `truncated` counts the
  entries past `maxReportEntries`, whose counts are still included.
- `FormatReport(report, maxLines)` returns `"<path> <field>: <action>
  (<reason>)"` lines, at most `maxLines` (default 50), then one summary line.

### 5.3 `ConvertAceConfig(appName, source[, options])`

- `appName`: a non-empty string. It becomes `info.appName` and `info[0]` in
  every Ace callback, as AceConfigDialog passes it
  (`AceConfigDialog-3.0.lua:201-203`).
- `source`: the options table, or a function returning it. A function is
  called once with `(uiType, uiName, appName)`, as AceConfigRegistry calls it
  (`AceConfigRegistry-3.0.lua:331-341`), and the result is converted; the
  report notes the snapshot (`sourceFunction`).
- Returns a **conversion**: `{ tree = <table for OptionsKit:Define>, report =
  <report>, paths = { [optionsPath] = { <original Ace keys> } }, maxDepth = n,
  optionCount = n }`.

| Option | Default | Meaning |
|---|---|---|
| `uiType` | `"dialog"` | `"dialog"`, `"dropdown"` or `"cmd"`: passed to a function `source` and set as `info.uiType`; also selects which per-interface flags fold into `hidden` and `inline` (section 6.2). |
| `uiName` | `"BridgeKit-1"` | `info.uiName`. Must match Ace's own check `[A-Za-z]%-[0-9]` (`AceConfigRegistry-3.0.lua:307`). |
| `bind` | none | `{ [optionsPath] = "<scope>.<key>..." }`: that option is bound to the database instead of calling its Ace `get`/`set`; the report notes it (`boundToDatabase`). Paths are the converted ones (after renaming). |
| `replace` | none | `{ [optionsPath] = optionTable }`: that option or group is replaced by the given OptionsKit option, used as it is. The use: `replace = { profiles = OptionsKit:ProfileOptions(db) }` in place of an AceDBOptions-3.0 group. `ProfileOptions` returns one cached group per database and options (OptionsKit revision 8), as AceDBOptions keeps one group per database, and `Define` refuses a profile group another defined tree holds, so the converted tree must be the only defined tree holding that group (or pass other options, such as another `order`, to get a group of its own). |
| `strict` | `false` | Raise at the caller, after converting, when the report holds any `dropped`, `changed` or `unsupported` entry: `BridgeKit:ConvertAceConfig strict: 3 fields changed or dropped; first: general.scale step (stepNotEnforced)`. |
| `maxOptions` | 1024, OptionsKit's `MAX_OPTIONS` | The most options converted; one more raises at the caller, naming the limit. `BridgeKit.UNBOUNDED` accepted. |
| `maxDepth` | `8` | The most keys in an option path, 1 to 32, as OptionsKit's `Define`; deeper raises at the caller. It also stops a cyclic table. |

Errors at the caller: `source` not a table or function, a function that
raises or returns a non-table (`BridgeKit:ConvertAceConfig source function
did not return a table`), a root that is not `type = "group"` (the same rule
as `AceConfigRegistry-3.0.lua:319-321`), a limit passed, a secret anywhere in
an option's fields.

### 5.4 `DefineAceConfig(addonName, source[, options])`

`ConvertAceConfig(addonName, source, options)`, then
`OptionsKit:Define(addonName, conversion.tree, { db = options.db, maxOptions =
..., maxDepth = conversion.maxDepth })`. Returns the tree handle and the
report. Accepts every conversion option plus `db`, the SettingsKit database
`bind` paths need. Without OptionsKit: `BridgeKit:DefineAceConfig requires
OptionsKit API 1, which is not loaded (absent)`. An error OptionsKit raises
(a pattern it refuses, a `bind` into an undeclared scope) reaches the caller's
line with OptionsKit's message after `BridgeKit:DefineAceConfig `.

### 5.5 `PreviewAceDB(source, plan)`, `ImportAceDB(source, targetName, plan)`, `AceDBMigration(plan)`

`source` is the AceDB saved-variable table or the name of its global.

`plan` fields (unknown fields raise):

| Field | Required | Meaning |
|---|---|---|
| `schema` | yes | The SettingsKit schema table the addon passes to `SettingsKit:Open`: scope name to a SchemaKit `table` node or sealed schema. |
| `aceDefaults` | no, recommended | The defaults table the addon passed to `AceDB:New`. Without it, a value AceDB stripped because it equalled its default cannot be told from a value never set; the report says so once (`aceDefaultsUnknown`). |
| `scopes` | no | Destinations for AceDB scopes SettingsKit lacks: `{ race = { into = "global", field = "byRace" } }`. `into` is a declared SettingsKit scope, `field` a declared `map` field of it; each AceDB key (`"Human"`) becomes a map key. Without an entry the scope is dropped with a report entry. |
| `namespaces` | no | `{ [namespaceName] = { field = "bars", defaults = <that namespace's AceDB defaults> } }`: each section of the namespace lands under `field` of the same SettingsKit section. Without an entry the namespace is dropped with a report entry. |
| `renameProfile` | no | `function(name) -> string|nil`: a new name for a profile SettingsKit would refuse (too long, blank); `nil` drops it. Called for every profile. |
| `renameCharacter` | no | `function(aceKey) -> string|nil`: a new `char` key; for clients where AceDB's key format differs from SettingsKit's (section 7.3). |
| `version` | `ImportAceDB` only | The `options.version` the addon will pass to `SettingsKit:Open`, stamped into the target so no SettingsKit migration runs over imported data. |
| `backup` | `AceDBMigration`: yes; `ImportAceDB`: no | The name of a global listed in the TOC's `## SavedVariables` that receives the backup (section 7.8). |
| `replaceBackup` | no | `true` lets a new backup overwrite a non-empty backup global; by default that is refused. |
| `onReport` | `AceDBMigration` only | `function(report)`, called once the step has run. |

- `PreviewAceDB` returns the report an import would produce, with the same
  entries and counts, and writes nothing anywhere.
- `ImportAceDB` requires `targetName` to name a global that is `nil` or an
  empty table (`nil, "targetNotEmpty"` otherwise), writes the backup when
  `plan.backup` is given (`nil, "backupTaken"` when that global holds data and
  `replaceBackup` is not set), then writes the layout, and returns the
  report. The addon then calls `SettingsKit:Open(targetName, schema, {
  version = plan.version, ... })`.
- `AceDBMigration` returns `function(raw)` for `SettingsKit:Open(name, schema,
  { version = n, migrations = { [n] = BridgeKit:AceDBMigration(plan) } })`,
  for an addon that keeps its saved-variable name. SettingsKit hands the step
  a deep copy of the saved table and commits it only when the step returns
  ([`settingsKit/docs/API.md`](../packages/settingsKit/docs/API.md#migrations)),
  so a step that raises leaves the saved table untouched.

Errors at the caller: a `source` that is not a table (or names a global that
is not one), a `plan` without `schema`, a `schema` scope SettingsKit would
refuse, a `scopes` or `namespaces` destination that is not a declared `map`
or record field, a non-function `renameProfile`, SchemaKit absent.

### 5.6 `AceSerialize(...)` and `AceDeserialize(text)`

`AceSerialize` returns `true, text` or `false, reason` with reason one of
`"unsupportedType"` (a function, userdata or thread), `"cycle"`, `"nan"`,
`"maxDepth"`, `"maxValues"`, `"maxStringLength"`, `"maxTextBytes"`. A secret
anywhere raises at the caller.

`AceDeserialize` returns `true` and every value (their count preserved,
`nil`s included), or `false, reason` with reason one of `"notAceSerializer"`,
`"missingTerminator"`, `"invalidNumber"`, `"invalidFloat"`,
`"unknownControl"`, `"tableFormat"`, `"invalidKey"`, `"maxDepth"`,
`"maxValues"`, `"maxStringLength"`, `"maxTextBytes"`, `"maxListValues"`. It
raises only for a non-string or secret argument. Section 8.2 maps these to
Ace's own messages.

### 5.7 `OpenAceComm(scope, prefix, callback[, options])`

- `scope`: an open CommKit scope (`CommKit:ForAddon(name)`,
  `CommKit:CreateScope()`, or a module's `scope.Comm`). The channel's raw
  registration belongs to it, so closing the scope closes the channel.
- `prefix`: 1 to 16 bytes, as CommKit and AceComm require
  (`AceComm-3.0.lua:61-63`).
- `callback(prefix, message, distribution, sender)`: AceComm's
  `OnCommReceived` signature (`AceComm-3.0.lua:214, 218, 254, 260`), called
  once per whole message, isolated like a CommKit callback.
- Returns the channel, or `nil` and CommKit's registration refusal
  (`"full"`, `"closed"`, `"invalidPrefix"`, `"maxPrefixes"`,
  `"framingConflict"`).

| Option | Default | Meaning |
|---|---|---|
| `priority` | `"NORMAL"` | `"ALERT"`, `"NORMAL"` or `"BULK"`, AceComm's names (`AceComm-3.0.lua:84-89`), mapped to `CommKit.Priority`. **Fixed per prefix**: the first channel opened on a prefix sets it and a later channel stating another raises, so every message on a prefix leaves through one CommKit pipe per destination and multipart messages never interleave (section 8.3). |
| `wire` | `1` | The wire version (section 8.5). A version this revision does not know raises. |
| `ambiguate` | `true` | Pass `sender` through `Ambiguate(sender, "none")` before the callback, as AceComm does (`AceComm-3.0.lua:244`). The reassembly key always uses the unmodified sender. |

`channel:Send(request)` takes `{ text, distribution, target?, onProgress?,
onComplete? }` and returns CommKit's send handle or `nil, reason`:
`"closed"`, `"nulByte"` (AceComm forbids NUL, `AceComm-3.0.lua:77`),
`"badDistribution"`, `"tooLarge"`, `"queueFull"`, `"unavailable"`. A
distribution and target follow CommKit's rules; `onComplete` receives
CommKit's send states.

## 6. AceConfig adapter

### 6.1 Conversion model

The conversion walks the Ace table once, depth first, in key order, and
builds a new table in OptionsKit's vocabulary. It never modifies the source
and keeps no reference to it except through the Ace `info` tables (below),
which Ace callbacks expect.

**Inheritance is resolved at conversion.** AceConfigDialog resolves `get`,
`set`, `func`, `confirm`, `validate`, `disabled` and `hidden` by walking from
the root to the option and taking the deepest definition
(`AceConfigDialog-3.0.lua:131-139`, `164-185`, `668-694`), and resolves the
`handler` the same way (`192-199`, `677-687`). OptionsKit has no inheritance: every value
option names its own reader and writer. The conversion therefore gives each
option the definition AceConfigDialog would find for it, and the handler in
force at that option.

**One Ace `info` table per option**, built at conversion, with the fields
AceConfigDialog fills (`AceConfigDialog-3.0.lua:201-209`): the option's
original keys at `1..n`, `[0]` and `appName`, `options` (the source root),
`arg`, `handler`, `option` (the original option table), `type`, `uiType`,
`uiName`. It is reused for every call, as OptionsKit reuses its own `info`;
AceConfigDialog recycles its tables through a pool (`new`/`del`, released at
`224`), so a correct Ace callback already does not keep it.

**Callbacks are wrapped, not rewritten.** A function is called with the Ace
`info` and the arguments in Ace's shape; a method name is looked up on the
resolved handler **at call time**, as Ace does, and called as
`handler[name]` with the arguments `(handler, info, ...)`. A method missing at conversion is
reported (`missingMethod`); if it is still missing at call time the wrapper
raises Ace's message (`Method <name> doesn't exist in handler for type
<member>`, `AceConfigDialog-3.0.lua:218-221`).

| OptionsKit callback | Calls the Ace callback as |
|---|---|
| `get(info)` for `toggle`, `range`, `select`, `input`, `keybinding` | `get(aceInfo)`, first result |
| `get(info)` for `color` | `r, g, b, a = get(aceInfo)` (four results, `AceConfigDialog-3.0.lua:211-215`); returns a new `{ r, g, b[, a] }` table, or `nil` when `r` is `nil` |
| `get(info)` for `multiselect` | `get(aceInfo, key)` for each key of the current `values` (`1333`, `1353`); returns a new map of the booleans |
| `set(info, value)` | `set(aceInfo, value)`; `color`: `set(aceInfo, r, g, b, a)`; `multiselect`: `set(aceInfo, key, state)` for each key whose state differs from what `get(aceInfo, key)` answers (Ace calls it per key, `893`) |
| `validate(info, value)` | `validate(aceInfo, <value in the same shape as set>)`: `true` accepts; a string refuses with that message; anything else refuses with the option's `usage`, or `"invalid value"` (Ace composes the same choices, `741-750`); a secret result refuses without being compared |
| `func(info)` | `func(aceInfo)` |
| `disabled(info)`, `hidden(info)` | the Ace predicate with `aceInfo`; OptionsKit tests the answer secret-safely |
| `desc(info)` (a function) | the Ace `desc` with `aceInfo` |
| `values(info)` (a function) | the Ace `values` with `aceInfo`; entries whose key is not a string or number are left out of the result and counted in the report once per option (`valueKey`) |

Allocation: `color` and `multiselect` getters allocate a table per `Get`,
where OptionsKit's own getters allocate nothing. An options screen is not a
hot path; the design accepts it and says so in the API.

### 6.2 Base fields

Every Ace field an option may carry (`AceConfigRegistry-3.0.lua:71-96`),
and what the conversion does with it:

| Ace field | Ace types | Result | Report |
|---|---|---|---|
| `type` | string | The kind, per section 6.3. An unknown type is refused by Ace's own validator (`231-235`) and by the conversion (`unsupported`, `unknownType`). | as noted |
| `name` | string, function, method | A string is kept. A function or method is **called once** at conversion with the option's Ace `info` and its string result kept, because OptionsKit's `name` is a string. | `changed`, `evaluatedOnce` |
| `desc` | string, function, method | Kept: a string as is, a function wrapped (OptionsKit accepts a `desc` function). | — |
| `descStyle` | string | Dropped: a dialog presentation choice. | `dropped`, `presentation` |
| `order` | number, function, method | A number is kept. A function or method is called once and its number kept. | `changed`, `evaluatedOnce` |
| `validate` | function, method, `false` | Resolved (inherited) and wrapped; `false` means none. Ignored for `execute`, as Ace does (`727`). | — |
| `confirm` | boolean, function, method | On `execute`: `true` becomes `confirm = true`, or the `confirmText` string when one is set; a function or method becomes `confirm = true` with the static question. On any other kind: dropped, because OptionsKit asks for confirmation only before `Execute` and Ace also confirms value changes (`765-803`). | function: `changed`, `dynamicConfirm`; other kinds: `dropped`, `confirmOnValue` |
| `confirmText` | string | Merged into `confirm` as above. | — |
| `disabled`, `hidden` | boolean, function, method | Resolved to the nearest definition (Ace's rule) and set on the option. OptionsKit also applies every ancestor's flag, so an option that sets `false` below a group that sets `true` stays disabled or hidden. | that case: `changed`, `cannotOverrideAncestor` |
| `guiHidden`, `dialogHidden`, `dropdownHidden`, `cmdHidden` | boolean, function, method | The flags for `options.uiType` (`dialogHidden` and `guiHidden` for `"dialog"`, as `CheckOptionHidden` reads them, `AceConfigDialog-3.0.lua:923-931`) are folded into `hidden` for every renderer; the others are dropped. | folded: `changed`, `perInterfaceFlag`; others: `dropped`, `perInterfaceFlag` |
| `tooltipHyperlink` | string, function | Dropped. | `dropped`, `presentation` |
| `icon`, `iconCoords` | | Dropped. | `dropped`, `presentation` |
| `handler` | table | Consumed: resolved per option and placed in the Ace `info`. | — |
| `get`, `set`, `func` | function, method, `false` | Resolved and wrapped (section 6.1). A value option left with no `get` or no `set` cannot exist in OptionsKit. | that option: `unsupported`, `noAccessor` |
| `arg` | anything | Kept in the Ace `info.arg`. | — |
| `width`, `relWidth` | | Dropped: WidgetKit renders every option full width. | `dropped`, `presentation` |

### 6.3 Kinds and their fields

Per kind (`AceConfigRegistry-3.0.lua:98-195`). `control`, `dialogControl`,
`dropdownControl` and `itemControl` name custom AceGUI widgets and are
dropped everywhere (`dropped`, `customControl`).

| Ace kind | OptionsKit kind | Fields |
|---|---|---|
| `group` | `group` | `args` converted. `plugins` (a table of plugin name to extra args, searched **before** `args` by `GetSubOption`, `AceConfigDialog-3.0.lua:117-127`) is merged into `args`; a plugin key that collides with an `args` key wins, as in Ace, and the loser is reported (`dropped`, `pluginShadowed`). `inline` kept; `guiInline`/`dialogInline` for `uiType = "dialog"` (`dropdownInline`, `cmdInline` for the others) fold into `inline` (`changed`, `perInterfaceFlag`). `childGroups` (`"tree"`, `"tab"`, `"select"`) dropped (`dropped`, `presentation`). |
| `execute` | `execute` | `func` wrapped; `confirm` as above; `image`, `imageCoords`, `imageWidth`, `imageHeight` dropped (`presentation`). |
| `input` | `input` | `pattern` kept: both test it with `string.match`/`string.find` on the typed text (`AceConfigDialog-3.0.lua:718-724`; OptionsKit's `SchemaKit.string{ pattern }`); a pattern SchemaKit refuses as malformed makes `DefineAceConfig` raise with OptionsKit's message. `usage` kept. `multiline`: `true` kept; a number (Ace's line count) becomes `true` (`changed`, `lineCount`). |
| `toggle` | `toggle` | `tristate` kept (both use `nil` as the third state). `image*` dropped. |
| `tristate` | — | A kind the validator lists with no fields (`149-150`) and no dialog draws: `unsupported`, `unknownType`. |
| `range` | `range` | `min`, `max`, `softMin`, `softMax`, `step`, `bigStep`, `isPercent` kept. OptionsKit requires `min` and `max`: a missing `min` becomes `0` when there is no `softMin`, as the dialog's slider assumes (`AceConfigDialog-3.0.lua:877`), and `-math.huge` otherwise; a missing `max` becomes `100` or `math.huge` the same way (`changed`, `defaultBound`). Ace's dialog snaps a value to `step` before `set` (`880`); OptionsKit's `step` is a renderer hint that `Set` does not enforce, so every range with a `step` is reported (`changed`, `stepNotEnforced`). |
| `select` | `select` | `values`: a table is copied with its string and number keys (others dropped, `valueKey`); a function or method is wrapped. `sorting`: a table kept when every entry is a key of a table `values` (otherwise dropped, `sortingKey`); a function or method is called once (`changed`, `evaluatedOnce`). `style` (`"dropdown"`, `"radio"`) dropped (`presentation`). An empty `values` table: `unsupported`, `emptyValues`. |
| `multiselect` | `multiselect` | `values` as for `select`. `tristate`: OptionsKit's multiselect holds booleans, so an Ace third state (`nil`) reads as `false` (`changed`, `multiselectTristate`). `style` dropped. |
| `color` | `color` | `hasAlpha`: a boolean kept; a function or method called once (`changed`, `evaluatedOnce`). |
| `keybinding` | `keybinding` | — |
| `header` | `header` | — |
| `description` | `description` | `fontSize`: `"small"`, `"medium"`, `"large"` kept, a function called once, anything else dropped (`dropped`, `fontSize`). `image`, `imageCoords`, `imageWidth`, `imageHeight` dropped (`presentation`). |

### 6.4 Keys and paths

Ace accepts any string key without control characters
(`AceConfigRegistry-3.0.lua:197-205`); OptionsKit accepts identifiers
(`[%a_][%w_]*`). A key that is not an identifier is renamed: every byte
outside `[%w_]` becomes `_`, a leading digit gets a leading `_`, and a
collision with a sibling appends `_2`, `_3`, ... in the sorted order of the
original keys, so the result is deterministic (`renamed`, `identifier`). The
conversion's `paths` map gives, for every converted OptionsKit path, the
original Ace keys, so an addon can translate paths it stored or prints.

### 6.5 Reasons

`evaluatedOnce`, `presentation`, `customControl`, `perInterfaceFlag`,
`confirmOnValue`, `dynamicConfirm`, `cannotOverrideAncestor`, `noAccessor`,
`missingMethod`, `unknownType`, `pluginShadowed`, `lineCount`,
`defaultBound`, `stepNotEnforced`, `valueKey`, `sortingKey`, `emptyValues`,
`multiselectTristate`, `fontSize`, `identifier`, `boundToDatabase`,
`replaced`, `sourceFunction`. Each is documented with its Ace citation in the
package's `API.md`.

### 6.6 What the adapter deliberately does not do

- It does not keep Ace's re-validation of the table per interface type
  (`AceConfigRegistry-3.0.lua:35-41`): OptionsKit checks once at `Define`.
- It does not reproduce `AceConfigRegistry:NotifyChange`. A renderer
  refreshes from `tree:OnChange`; changes made outside the tree call
  `rendering:Refresh()` (see `MIGRATING_FROM_ACE3.md`).
- It does not convert an AceDBOptions-3.0 group. Such a group calls AceDB
  methods; after an import the addon passes `replace = { profiles =
  OptionsKit:ProfileOptions(db) }`, the database's one cached profile group,
  which one defined tree holds at a time (see the `replace` option).

## 7. AceDB importer

### 7.1 The source layout

An AceDB-3.0 saved variable (`AceDB-3.0.lua:291-386`) is a table with:

| Key | Content | Keyed by |
|---|---|---|
| `profileKeys` | character key to profile name, written for every character that loaded the addon (`300-318`) | char key |
| `profiles` | profile name to the profile's table | profile name |
| `char`, `realm`, `class`, `race`, `faction`, `factionrealm`, `factionrealmregion`, `locale` | one table per key of that scope (`330-342`) | the scope key |
| `global` | one table (`221-227`) | — |
| `namespaces` | namespace name to a table of the same layout, without `profileKeys` (`319-325`, `740-762`) | namespace name |

The keys (`255-288`): `char` is `UnitNameUnmodified("player") .. " - " ..
GetRealmName()` (`277-278`), except on clients whose build number lies
between 16000 and 20000, where it is `"<name> <surname> - <ruleset>"` and
`realm` is the ruleset name (`264-275`); `class` and `race` are the second
results of `UnitClass` and `UnitRace` (`260-261`); `faction` is
`UnitFactionGroup("player")` (`255`); `factionrealm` is `"<faction> -
<realm>"` and `factionrealmregion` adds `" - <region>"` (`281-287`); `locale`
is `GetLocale():lower()` (`256`).

**Defaults are not stored.** AceDB copies defaults into sections as they are
read (`copyDefaults`, `89-132`) and strips every value equal to its default,
then every table left empty, at `PLAYER_LOGOUT` (`removeDefaults`, `135-179`;
`logoutHandler`, `391-437`). `"*"` and `"**"` defaults apply to every key of a
table; `"**"` also applies below keys the defaults name explicitly
(`93-124`, `140-157`).

### 7.2 The target layout

The SettingsKit layout of API generation 1 (prerequisite P2): `version`,
`global`, `profiles`, `profileKeys`, `char`, `realm`, `class`, `faction`,
`namespaces` (reserved, written empty). Its sections have the same names and
the same keys as AceDB's for `profiles`, `profileKeys`, `char`, `realm`,
`class`, `faction` and `global` (`settingsKit/docs/INTERNALS.md`, "The saved
table"), which is what makes a faithful import possible.

### 7.3 Scope by scope

| AceDB section | SettingsKit destination | Notes |
|---|---|---|
| `profiles[name]` | `profiles[name]` | Name rules differ: AceDB allows 1 to 50 UTF-8 characters, not all spaces (`307-309`, `486-489`); SettingsKit allows at most `maxProfileNameLength` bytes (64 by default) with a non-whitespace character. A longer name goes through `renameProfile`, else is dropped (`profileNameTooLong`). |
| `profileKeys[charKey]` | `profileKeys[charKey]` | Kept when it names an imported profile; one naming a dropped or missing profile is dropped (`danglingProfileKey`), and that character starts on the default profile at its next `Open`, as SettingsKit documents. |
| `char[key]` | `char[key]` | Same key format (`"<name> - <realm>"`) except on the 16000–20000 clients above; `renameCharacter` maps keys. The preview reports whether the current character's SettingsKit key is present (`currentCharacterMissing` when not). SettingsKit reads the name with `UnitName`, AceDB with `UnitNameUnmodified`; where the two differ for a character, its entry is reported (`characterKeyMismatch`). |
| `realm[key]` | `realm[key]` | Both use `GetRealmName()`; ruleset keys from 16000–20000 clients are reported (`realmKeyMismatch`). |
| `class[key]` | `class[key]` | Identical keys (`"MAGE"`). |
| `faction[key]` | `faction[key]` | Identical keys. |
| `global` | `global` | — |
| `race`, `factionrealm`, `factionrealmregion`, `locale` | a declared map field named by `plan.scopes`, or dropped | SettingsKit has no such scopes ([question 3](#16-open-questions-for-the-owner)). `factionrealmregion` exists at the pinned commit though AceDB's header does not list it (`285-287`, `337`). |
| `namespaces[n]` | each section under `plan.namespaces[n].field` in the same SettingsKit section, or dropped | A namespace's `profiles[p]` lands in `profiles[p][field]`, its `char[k]` in `char[k][field]`, and so on. Its defaults are `plan.namespaces[n].defaults`. |
| any other top-level key | dropped | `unknownTopLevelKey`; the backup keeps it. |

A SettingsKit scope the schema does not declare receives nothing: its AceDB
section is dropped (`undeclaredScope`).

### 7.4 Validation

Every value is checked against the scope schema before it is written, the way
SettingsKit checks a write: a probe table holding only the path to that value
is checked with the scope's schema, which is sound because every field of a
SettingsKit record is optional
([`settingsKit/docs/API.md`](../packages/settingsKit/docs/API.md#settingskitopensavedvariable-schema-options)).
`schema:Describe()` tells the walk which fields are records and maps (walked
into) and which are values (checked whole: scalars, arrays, `any`, `oneOf`,
`custom`). A refused value is dropped and reported with SchemaKit's `path`,
`rule` and `expected`, never the value (`schemaRefused`). A map past its
`max` keeps its first `max` keys in sorted key order (`mapFull`). A value
SettingsKit could never store — a function, a table with a metatable, a
secret — is dropped (`notStorable`, `secretValue`). The walk keeps its own
stack and stops at SchemaKit's `maxDepth` (`tooDeep`) and at
`maxImportEntries` entries (the import then refuses as a whole:
`nil, "maxImportEntries"`, with the report so far).

### 7.5 Profiles and profile choices

AceDB records a profile choice for every character that loaded the addon
(`300-318`); SettingsKit records one only when `SetProfile` runs. Importing
every recorded choice keeps each character on its profile. AceDB's
`defaultProfile` argument maps to SettingsKit's `defaultProfile` option:
`true` is `"Default"` in both (`295`), `nil` is the character's own profile in
AceDB and `"char"` in SettingsKit. The addon keeps that choice in its `Open`
call; the importer does not write it.

### 7.6 Defaults: how the two meet

AceDB strips a value equal to its AceDB default; SettingsKit's `Compact`
(and its logout compaction) removes a value deeply equal to its SettingsKit
default. The two defaults need not agree, and after an import every field
must read in SettingsKit what it read in AceDB. The rule, per field of every
imported entry (every profile, every stored character, realm, class, faction
and mapped key), with `A` the AceDB default and `S` the SettingsKit schema
default:

| Source holds | `A` versus `S` | Written | Report |
|---|---|---|---|
| a value | — | the value (if the schema accepts it) | — |
| nothing | `A` equal to `S`, or `A` absent | nothing: both read `S` | — |
| nothing | `A` differs from `S` | `A`, materialised as a value | `materialised`, `defaultDiffers` |

- A materialised `A` that the schema refuses is dropped
  (`schemaRefused`) and the field reads `S`: the one case where meaning
  changes, always reported.
- **Wildcards.** An AceDB `"*"`/`"**"` default is compared with the map's
  wildcard default (the default of `optional(...)` on the map's `values`) for
  every key the source holds. For keys the source does not hold, nothing can
  be materialised: when the two wildcards differ, the report says so once per
  map (`changed`, `wildcardDefaultDiffers`), because every key never saved
  will read `S` from now on.
- **Entries the source lacks entirely** (a character that never saved
  anything in `char`) read `S` after the import where they read `A` before;
  when `A` and `S` differ for a field of that scope, the report says so once
  per field (`changed`, `defaultDiffers`).
- **After the import**, SettingsKit's compaction removes only values equal to
  `S`. A materialised `A` differs from `S` by construction and stays, so
  compaction never changes what a field reads. Values that equal `S` in the
  source are written and compacted away at the next logout, which is also
  meaning-preserving.
- Without `plan.aceDefaults`, `A` is unknown: nothing is materialised and the
  report carries one `aceDefaultsUnknown` entry.

### 7.7 The two modes

**Different saved variable** (`ImportAceDB`). The addon adds a new global to
`## SavedVariables` (and keeps the old one listed for the transition), then,
in its loaded phase:

```lua
-- Planned API (this design); nothing below exists yet.
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

The source is never written; the old global keeps its data until the addon
removes it from the TOC.

**Same saved variable** (`AceDBMigration`). The addon keeps `## SavedVariables:
MyAddonDB`, adds `MyAddonDB_Backup`, and opens with a migration:

```lua
-- Planned API (this design); nothing below exists yet.
local db = SettingsKit:Open("MyAddonDB", schema, {
  version = 2,
  migrations = { [2] = BridgeKit:AceDBMigration({
    schema = schema,
    aceDefaults = aceDefaults,
    backup = "MyAddonDB_Backup",
    onReport = function(report) MyAddon.importReport = report end,
  }) },
})
```

An AceDB table has no `version`, so SettingsKit reads version 0 and runs the
step once. The step receives SettingsKit's deep copy: it **moves** the copy's
contents into the backup global (they are private to the step, so no second
copy is needed), builds the new layout from them with its own copies, and
leaves the new layout in the table it was given. If the step raises,
SettingsKit discards the copy and the saved table is untouched; the backup
global is written only after the new layout was built, so a failed step leaves
no backup behind either.

### 7.8 The backup

`backup` names a global the addon lists in `## SavedVariables`, so the client
writes it to disk at logout. BridgeKit writes `{ bridgeKit = <REVISION>,
source = <source global name or "table">, commit = ACE_BASELINE.commit, data =
<the source table's copy> }`. A backup global that holds anything but `nil` or
an empty table is refused (`nil, "backupTaken"`; in the migration, the step
raises `BridgeKit:AceDBMigration backup global "X" already holds data`)
unless `replaceBackup` is set. The copy is bounded by `maxImportEntries` and
keeps tables reached twice shared. Restoring is the addon's decision: the
migration guide shows the three lines that put the backup back.

### 7.9 Reasons

`profileNameTooLong`, `profileNameBlank`, `danglingProfileKey`,
`currentCharacterMissing`, `characterKeyMismatch`, `realmKeyMismatch`,
`unsupportedScope`, `unmappedNamespace`, `undeclaredScope`,
`unknownTopLevelKey`, `schemaRefused`, `mapFull`, `notStorable`,
`secretValue`, `tooDeep`, `defaultDiffers`, `wildcardDefaultDiffers`,
`aceDefaultsUnknown`, `renamedProfile`, `renamedCharacter`.

## 8. Wire adapter: AceSerializer and AceComm

### 8.1 AceSerializer-3.0 format

A serialised string is a start code, the values, and an end code. Every
token is a caret (`^`, byte `5E`) followed by one type character and the
token's data, which runs up to the next caret.

| Token | Meaning | Source |
|---|---|---|
| `^1` | start: "data of AceSerializer protocol revision 1"; the reader ignores anything after the `1` up to the next caret | `AceSerializer-3.0.lua:114`, `250-254` |
| `^^` | end; the reader ignores everything after it | `130`, `182-185` |
| `^S<escaped>` | a string | `58-61` |
| `^N<text>` | a number written as `tostring` gives it, when `tonumber` of that text gives the same number back | `63-69` |
| `^N1.#INF`, `^N-1.#INF` | positive and negative infinity, when `tostring` did not round-trip | `27-31`, `70-73` |
| `^F<mantissa>^f<exponent>` | any other number: with `m, e = frexp(v)`, the mantissa is `m * 2^53` written with `%.0f`, the exponent `e - 53` written with `tostring`; the reader computes `mantissa * 2^exponent` | `75-80`, `196-206` |
| `^B`, `^b` | `true`, `false` | `93-99` |
| `^Z` | `nil` | `101-103` |
| `^T` ... `^t` | a table: key, value, key, value, ... in `pairs` order, then the end marker | `83-91`, `213-230` |

**String escaping** uses the tilde (`7E`) as escape byte and applies to the
bytes the pattern `[%c \94\126\127]` matches (`60`): control bytes, space,
caret, tilde and DEL.

| Byte | Written as | Source |
|---|---|---|
| `1E` (30) | `~z` — the general rule would give `~^`, which is a caret | `39-40`, `139-140` |
| `00`–`20` except `1E` | `~` followed by the byte plus 64 (`00` is `~@`, `20` is `` ~` ``) | `41-42`, `137-138` |
| `5E` (`^`) | `~}` | `43-44`, `145-146` |
| `7E` (`~`) | `~|` | `45-46`, `143-144` |
| `7F` | `~{` | `47-48`, `141-142` |

Bytes `80`–`FF` pass unescaped, and so does `|` (`7C`).

**Reading** (`246-257`): the reader first deletes every control byte and
every space from the whole input (`247`), then reads tokens as "a caret,
one character, then everything up to the next caret" (`249`). The first
token must be `^1`, or the result is `false, "Supplied data is not
AceSerializer data (rev 1)"`. Data after `^B`, `^b`, `^Z`, `^T`, `^t` and
`^^` is ignored (`207-219`). A table's key or value decoding to `nil` is an
error (`220-228`); a repeated key overwrites; input that ends without `^^` is
an error (`178-180`); an unknown type character is an error (`231-232`). The
reader returns `true` and the values, or `false` and a message
(`pcall`, `256`).

**NaN** is not handled by the writer (`29`, `65`, `152`): its bytes depend
on the client's `tostring` and `string.format`, and the reader's result is
undefined.

### 8.2 BridgeKit's serializer

- **Writer**: the same algorithm, so the bytes equal Ace's for the same
  values on the same client (the number spelling follows the client's
  `tostring`, as Ace's does). Tables are walked with `next`, as Ace walks with
  `pairs`; two equal tables may therefore serialise differently in both
  implementations, and fixtures compare decoded values except for scalars and
  single-entry tables. Deviations, each a refusal where Ace would raise or
  write undefined bytes: NaN (`"nan"`), a cycle (`"cycle"`; Ace overflows the
  stack), a function, userdata or thread (`"unsupportedType"`; Ace raises,
  `106`), and the limits.
- **Reader**: accepts everything Ace's reader accepts within the limits,
  including the ignored data portions, the four infinity spellings (`1.#INF`,
  `inf`, `-1.#INF`, `-inf`, `30-31`, `154-157`), numbers Lua's `tonumber`
  reads (hexadecimal included, as `tonumber` is what Ace calls), and repeated
  keys (last wins). It never raises on any string. Deviations: a NaN key is
  refused (`"invalidKey"`; Ace raises inside its `pcall` and returns `false`
  too), and the limits apply.
- **Reasons** map to Ace's messages: `"notAceSerializer"` (`253`),
  `"missingTerminator"` (`179`), `"invalidNumber"` (`194`),
  `"invalidFloat"` (`199`, `204`), `"unknownControl"` (`232`),
  `"tableFormat"` (`222`, `227`).
- **Not CodecKit.** AceSerializer text is not a CodecKit frame; the migration
  moves from one to the other (section 8.6), and neither Kit reads the other's
  format.

### 8.3 AceComm-3.0 framing

**Sending** (`AceComm-3.0.lua:83-138`). One addon message carries at most 255
bytes (`95`).

- A text of at most 255 bytes whose first byte is not `01`–`09` is sent as one
  message, unchanged (`115-117`).
- A text whose first byte is `01`–`09` gets the escape byte `04` in front when
  the result still fits in 255 bytes (`106-113`); otherwise it is sent as a
  multipart message (`108-109`).
- Anything longer is multipart (`118-137`): 254 text bytes per message, the
  first message starting with `01`, each middle message with `02`, the last
  with `03` and the remainder (1 to 254 bytes).
- Every message of a text uses the same prefix, distribution, target and
  priority, and ChatThrottleLib queues all messages of one prefix in one
  queue (`96`), so the parts of one text arrive in order and never interleave
  with another text on that prefix.

**Receiving** (`141-265`).

- The sender name is passed through `Ambiguate(sender, "none")` (`244`).
- A message whose first byte is `01`–`09` is a control message (`245`): `01`
  starts a stream, **replacing** any stream held for the same prefix,
  distribution and sender (`164-176`); `02` appends to a held stream and is
  dropped when there is none (`178-197`); `03` appends, delivers the whole
  text and forgets the stream, or is dropped when there is none (`199-220`);
  `04` delivers the rest of the message (`253-254`); `05`–`09` are ignored
  without a warning, reserved for extensions (`255-256`).
- Any other message is delivered as it is (`258-260`).
- Streams are keyed by prefix, distribution and sender (`165`) and never
  expire: AceComm keeps them forever and has no bound (the author's note at
  `16`).

**BridgeKit** writes exactly these bytes and reads with exactly these rules,
with bounds Ace lacks (section 9): at most `maxAceStreams` streams, at most
`maxAceStreamsPerSender` per sender, at most `maxAceStreamBytes` bytes in one
stream and `maxAceSpoolBytes` across all, and a stream expires
`aceStreamTimeout` seconds after its last part. A stream that passes a bound
is dropped and counted; drops are reported through the host error handler at
most once per sender per minute, as CommKit does. A channel's messages leave
through `SendRaw` as one message of parts (P1), so they cannot interleave
within CommKit's pipe; the per-prefix priority (section 5.7) keeps all of a
prefix's messages in one pipe per destination, which is the ordering guarantee
ChatThrottleLib's per-prefix queue gave.

Streams belong to the prefix, not to a channel: two addons that open channels
on one prefix share one reassembly, and each completed message is delivered to
every channel on the prefix in the order they were opened.

### 8.4 Statistics

`GetStatistics()` returns a fresh table: `aceMessagesSent`,
`acePartsSent`, `aceMessagesReceived`, `aceBytesReceived`,
`aceStreamsOpened`, `aceStreamsCompleted`, `aceStreamsReplaced` (a new `01`
while one was held), `aceStreamsExpired`, `aceStreamsOversize`,
`aceStreamsRefusedQuota`, `aceOrphanParts` (`02`/`03` without a stream),
`aceReservedControl` (`05`–`09`), `openStreams`, `spoolBytes`.

### 8.5 Versioning

`wire = 1` names what BridgeKit reproduces: AceComm-3.0 framing as of `MINOR`
14 and AceSerializer-3.0 protocol revision 1 as written by `MINOR` 5, at the
pinned commit. Within BridgeKit API generation 1 the bytes of wire version 1
never change. If a later Ace3 revision changes either format (a new control
byte among `05`–`09`, a new serializer revision code), BridgeKit adds wire
version 2 beside it; a channel keeps the version it was opened with, so an
update of BridgeKit never changes what an addon sends. `ACE_WIRE_VERSION`
names the newest version a revision knows; `channel:GetWireVersion()` the one
in use.

### 8.6 Staged migration

An addon moves its peers from AceComm plus AceSerializer to CommKit plus
CodecKit in three releases, with the two protocols on **different prefixes**
(a CommKit prefix cannot carry AceComm traffic, P1):

| Release | Sends | Receives |
|---|---|---|
| v1 (Ace3) | `"MyAddon"`: AceComm + AceSerializer | `"MyAddon"` |
| v2 (bridge) | `"MyAddon"` through BridgeKit for every peer not yet known to speak CommKit; `"MyAddonMC"` through CommKit + CodecKit for peers that do | both; a sender seen on `"MyAddonMC"` is recorded (bounded) as a CommKit peer, and its `"MyAddon"` messages are ignored from then on |
| v3 (native) | `"MyAddonMC"` only | `"MyAddonMC"`; `"MyAddon"` only to tell a v1 peer to update, or not at all |

For group and guild broadcasts v2 sends on both prefixes until the addon's
own telemetry says v1 peers are gone; the extra bytes are charged to the same
CommKit budget. The complete v2 code is in `MIGRATING_FROM_ACE3.md`, marked
as planned API until BridgeKit ships.

## 9. Limits

All limits are package-wide, set with `BridgeKit:SetLimits{}` and read with
`BridgeKit:GetLimits()`, shared by every embedded copy and kept across an
in-place upgrade. `SetLimits` raises at the caller, before changing anything,
on an unknown name, a secret key or value, a value outside its range, or
`UNBOUNDED` where the table says no.

| Limit | Default | `UNBOUNDED`? | Ceiling and reason |
|---|---|---|---|
| `maxReportEntries` | 1024 | yes: a report is the caller's own memory | 2^24 as an integer |
| `maxImportEntries` | 65536 (SettingsKit's `maxScannedEntries`) | yes: the source is the addon's own data | 2^30 |
| `maxDepth` (serializer, both ways) | 16 | no: a hostile peer chooses the nesting | 128: writer and reader recurse on the Lua stack, as CodecKit's |
| `maxValues` (serializer) | 65536 | yes: `maxTextBytes` still bounds it | 2^24 |
| `maxStringLength` (serializer) | 65536 | yes: `maxTextBytes` still bounds it | 2^30 |
| `maxTextBytes` (serializer input and output) | 1048576 | no: a hostile peer chooses it | 2^26 |
| `maxListValues` (top-level values) | 4096 | no | 7900: `AceDeserialize` returns through `unpack`, as CodecKit's `DecodeMany` |
| `maxAceStreams` | 64 | no: other players grow it | 1024 |
| `maxAceStreamsPerSender` | 4 | no | 64 |
| `maxAceStreamBytes` | 65536 | no | 1048576 |
| `maxAceSpoolBytes` | 1048576 | no | 2^26 |
| `aceStreamTimeout` | 30 seconds | no | 600 |
| `maxDropReportSenders` | 64 | no | 1024 |

`maxAceStreamBytes` defaults to 64 KB, four times CommKit's per-sender
reassembly, because Ace3 addons do send whole profiles and export strings
over AceComm; a receiver that expects more opens it on purpose. Per-call
bounds of the AceConfig conversion are options (`maxOptions`, `maxDepth`)
because the tree belongs to one call, as OptionsKit's are.

## 10. Secret values

Retail 12.x hands addon code secret values, which raise when compared,
tested for truth or used as a table key
([`EMBEDDING.md`](EMBEDDING.md#secret-values-retail-12x)). BridgeKit asks
`issecretvalue` (read at every call) before it compares, tests or indexes
with anything it did not create, and tests absence with `type(x) == "nil"`,
the repository rule.

| Where | A secret |
|---|---|
| Any argument, option field, plan field or `SetLimits` value | Raises at the caller, before any comparison, with the parameter named: `BridgeKit:OpenAceComm prefix must not be a secret value`. |
| A field of an AceConfig option table | Raises at the caller with its path: `BridgeKit:ConvertAceConfig source.args.general.disabled must not be a secret value`. |
| The answer of a wrapped Ace `disabled`, `hidden` or `validate` | `disabled`/`hidden`: returned to OptionsKit, which counts a secret as `false`; `validate`: a refusal, never compared. |
| A value an Ace getter returns | Passed through as OptionsKit passes getter results. A secret colour component or multiselect state is placed in the table unexamined. |
| A key or value in the AceDB source | Dropped and reported (`secretValue`) without formatting; saved variables never hold secrets. |
| A value given to `AceSerialize` | Raises at the caller: `BridgeKit:AceSerialize value must not contain a secret value`. |
| The text given to `AceDeserialize` | Raises at the caller. |
| A received prefix, message, distribution or sender | Dropped by CommKit before the raw callback (P1), counted in CommKit's `secretsDropped`; BridgeKit never sees it. |

Error messages never format a value BridgeKit did not create.

## 11. Errors

Programming errors raise at the caller's line (the repository rule), named
after the method and the parameter:

```text
MyAddon/Options.lua:12: BridgeKit:ConvertAceConfig source must be a table or a function
MyAddon/Options.lua:12: BridgeKit:ConvertAceConfig source.type must be "group" at the root
MyAddon/Options.lua:12: BridgeKit:ConvertAceConfig options.maxDepth must be an integer from 1 to 32
MyAddon/Settings.lua:30: BridgeKit:ImportAceDB plan.schema is required
MyAddon/Settings.lua:30: BridgeKit:ImportAceDB plan.scopes.race.field "byRace" is not a declared map field of scope "global"
MyAddon/Comm.lua:8: BridgeKit:OpenAceComm requires CommKit API 1 with raw addon messages (RegisterRaw, SendRaw), which is not loaded
MyAddon/Comm.lua:8: BridgeKit:OpenAceComm options.priority "ALERT" differs from "NORMAL", which the first channel on prefix "MyAddon" set
```

Data problems are results: report entries (conversion and import),
`false, reason` (serializer), `nil, reason` (channel sends, import
preconditions). Errors raised by the addon's own Ace callbacks propagate from
the OptionsKit call that ran them, unchanged, as OptionsKit documents for its
own callbacks.

## 12. Performance

| Operation | Cost |
|---|---|
| `ConvertAceConfig` | One walk of the table; allocates the new tree, one Ace `info` and one wrapper closure per callback. Load-time only. |
| A wrapped `get`/`set` | One extra function call and the Ace callback; no allocation, except `color` and `multiselect` getters (one table per call). |
| `PreviewAceDB`, `ImportAceDB`, migration | One walk of the source plus one probe check per value; allocates the new layout, the probes and the report. Once per install. |
| `AceSerialize` | Fragments in an array reused between calls, one `table.concat`; no allocation beyond the result string for scalars. |
| `AceDeserialize` | One `gsub` to strip control bytes and spaces (Ace does the same), one pass over the tokens; allocates the tables and strings it returns. |
| Receiving a single-part AceComm message | No allocation beyond what CommKit hands the raw callback; one table read for the prefix. |
| A multipart stream | One array per stream, one `table.concat` at the end; stream records are reused. |

These are the measurements the implementation must record in `API.md` before
the first release, and the external-review benchmark (worklist item 19)
compares against Ace3 downloaded at run time (section 3.2).

## 13. Testing

### 13.1 Host specs (Busted)

- Conversion: every row of sections 6.2 and 6.3 with its report entry;
  inheritance resolution against hand-written trees (a `set` on a grand-parent,
  a `handler` switch half way down, `false` stopping inheritance); method
  names resolved at call time; the Ace `info` fields; `color` and
  `multiselect` shapes both ways; `validate` answers (`true`, string, `false`,
  secret); renaming and collisions deterministic; `bind` and `replace`;
  `strict`; limits; a converted tree accepted by OptionsKit and driven through
  `Set`, `Validate`, `Execute` and `Describe`.
- Import: every row of section 7.3; the defaults table of section 7.6 row by
  row, wildcards included; a round trip "AceDB layout written by a host AceDB
  stand-in, imported, opened with SettingsKit, every field read" asserting
  equal reads; compaction after the import changes no read; the source
  compared byte for byte (a deep snapshot) before and after; backup refusal
  and `replaceBackup`; the migration step failing half way leaves the saved
  table and the backup global untouched; limits; secrets.
- Serializer: every token and escape of section 8.1; the four infinity
  spellings; `^F` numbers at the edges (subnormal numbers, `2^53 + 1`, large
  exponents); ignored data portions; every reason; hostile inputs (deep
  nesting, huge counts, truncated at every byte) never raise; a round trip of
  random values; **fixtures recorded from Ace3** (section 3.2) decoded to the
  recorded values and, for scalars and single-entry tables, re-encoded byte
  for byte.
- Channel (with a CommKit P1 stand-in): the send rules of section 8.3 at the
  boundaries (254, 255, 256 bytes; a first byte `01`–`09` at 254 and 255
  bytes; 254 × k and 254 × k + 1), receive rules including replacement,
  orphans and reserved controls, every bound and the drop report rate,
  priority fixed per prefix, two channels on one prefix, closing with the
  scope.

### 13.2 Real-client tests (`tests/client`)

What they would prove on Retail (Classic stays a recorded gap without game
time, decision 29):

1. **Wire compatibility with real Ace3.** A test addon that loads Ace3 at the
   pinned commit, fetched by the installer at install time and never
   committed (section 3.2), exchanges whisper-to-self messages with a
   BridgeKit channel in both directions: single messages, the `04` escape,
   the multipart boundaries above, a 64 KB message, and every byte `01`–`FF`
   in text. Expected: identical text on both sides, identical AceSerializer
   bytes for scalar values, equal values for tables.
2. **What the client carries.** Whether addon messages carry `|` (`7C`),
   LF, CR and bytes `80`–`FF` unchanged on Retail 12.1 — a client fact
   AceComm relies on and CommKit's and CodecKit's forbidden-byte rules are
   based on; the result is recorded either way.
3. **AceDB import across `/reload`.** Run 1: an AceDB addon (Ace3 fetched as
   above) writes profiles, choices, every scope and a namespace; `/reload`.
   Run 2: the SettingsKit version imports in both modes; the backup file
   appears in `WTF`, the source is unchanged, every field reads as before;
   logout compaction; run 3 reads the same values again.
4. **AceConfig conversion rendered.** A converted table rendered by
   WidgetKit's `RenderOptions` and driven by CommandKit's `BindOptions`;
   every write reaches the addon's Ace handlers with the Ace `info` shape.
5. **Secrets.** `secretwrap` values refused at the documented lines.

The coexistence test of worklist item 20 (Ace3 and MoltenCodes loaded
together) waits for the MoltenSession experiment to end (decision 31) and
shares the Ace3 fetch step.

## 14. Documentation deliverables

- `packages/bridgeKit/README.md`: what it is, the three parts, footprint per
  part, "stop embedding it when the migration is over".
- `packages/bridgeKit/docs/API.md`: sections 5 to 11 as a contract, every
  reason with its Ace citation, measured costs, deviations.
- `packages/bridgeKit/CHANGELOG.md`, manifest, LuaCATS on every public
  surface.
- `docs/MIGRATING_FROM_ACE3.md`: the planned-API markers removed and the
  BridgeKit recipes made current.
- `docs/EMBEDDING.md`: footprint and host-requirements rows; `docs/README.md`,
  `README.md`, `ARCHITECTURE.md` list the package.
- This document kept current until the package closes.

## 15. Delivery sequence

Each step ends with the gates green and a read-only review.

- [ ] **N0 — prerequisites**, after the owner's answers: CommKit raw addon
      messages (P1, a CommKit minor version with specs and a client suite
      update) and SettingsKit's layout section (P2, documentation).
- [ ] **N1 — serializer**: `AceSerialize`, `AceDeserialize`, limits, fixtures.
- [ ] **N2 — AceConfig adapter**: `ConvertAceConfig`, `DefineAceConfig`,
      reports, `FormatReport`.
- [ ] **N3 — AceDB importer**: `PreviewAceDB`, `ImportAceDB`,
      `AceDBMigration`, backup.
- [ ] **N4 — AceComm channel**: `OpenAceComm`, reassembly, statistics.
- [ ] **N5 — client suites, benchmark rows, documentation**, then the
      acceptance review; package N closes.

## 16. Open questions for the owner

1. **CommKit raw addon messages (P1).** Approve adding `RegisterRaw` and
   `SendRaw` to CommKit (API 1, additive) so AceComm traffic shares CommKit's
   queue and budget? The alternative is BridgeKit sending through the client
   directly, outside the session budget. *Recommendation: P1.*
2. **SettingsKit layout as a public contract (P2).** Approve promoting the
   saved-table layout from `INTERNALS.md` to `API.md` so the importer may
   write it? The alternative is a SettingsKit `seed` option that lets a
   caller fill an empty table inside `Open`. *Recommendation: P2, no
   SettingsKit code change.*
3. **AceDB scopes SettingsKit lacks** (`race`, `factionrealm`,
   `factionrealmregion`, `locale`). Map them into a declared map field chosen
   by the addon (this design), or add those scopes to SettingsKit?
   *Recommendation: mapping; add scopes only if addons ask.*
4. **Function-valued `name`, `order`, `sorting`, `hasAlpha`, `fontSize`.**
   Evaluate once at conversion and report `evaluatedOnce` (this design), or
   refuse the option? *Recommendation: evaluate once and report.*
5. **Licence reading (section 3.2).** Confirm: recorded Ace3 output as test
   fixtures with provenance, no Ace3 source or tests in the repository, and
   Ace3 fetched at run time (never redistributed) for the benchmark and the
   client tests.

## 17. Decisions summary

| # | Decision | Where |
|---|---|---|
| 1 | Package `bridgeKit`, facade `BridgeKit`, package letter N; the owner named it (2026-09-25). | ROADMAP |
| 2 | Three parts in one package, each requiring only what it uses; Registry is the only required dependency. | 4.2 |
| 3 | Formats described in our words from Ace3 at `5e2e0d3b`; no Ace3 code or tests copied. | 3 |
| 4 | Every loss or change of meaning is a report entry; `strict` makes it an error. | 5.2 |
| 5 | AceConfig inheritance is resolved at conversion; Ace callbacks are wrapped and called with an Ace `info`. | 6.1 |
| 6 | The importer copies, validates with probe checks, materialises AceDB defaults that differ from SettingsKit's, and backs up before replacing. | 7 |
| 7 | Wire bytes equal Ace's; bounds Ace lacks are added; one priority per prefix. | 8.3 |
| 8 | Wire version 1 is frozen within API generation 1. | 8.5 |
