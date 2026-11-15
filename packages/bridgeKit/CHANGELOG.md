# Changelog

## 0.4.0 — unreleased

### Fixed (from step N3's read-only review)

- AceDB defaults are read as AceDB reads them: `"**"` merges into an explicit
  table default at every depth; a saved table is merged with its table
  default; an open record takes the keys only its defaults name; a map's own
  SettingsKit default keys are compared with AceDB's wildcard; a field
  SettingsKit defaults where AceDB had none is reported once per field
  (`defaultDiffers`), also in scopes AceDB has no defaults for.
- Renamed keys that collide (profiles, profile choices, characters, namespace
  sections) keep the key that keeps its name, otherwise the first in sorted
  order; the others are reported `keyCollision`, which replaces
  `profileNameCollision`. Before, a renamed character could overwrite the
  character already under that name.
- A namespace or mapped scope landing on a field that already holds an entry
  keeps the entry (`keyCollision`) and stops at a map's `max` (`mapFull`); an
  explicit AceDB default past a map's `max` is reported too.
- A map entry holding only defaults is kept instead of dropped.
- Secret keys are filtered before sorting and a secret profile choice is never
  used as a key; every source key is counted once against
  `maxImportEntries`, as it is met.
- `plan.schema` refusals are raised at the method's caller; a migration step
  that runs more than once starts each walk afresh.

## 0.3.0 — 2026-11-15

Delivery step N3 of `docs/BRIDGE_KIT_DESIGN.md`: the AceDB-3.0 importer. API
generation 1, implementation revision 3. AceSerializer and AceConfig behaviour
is unchanged.

- `BridgeKit:PreviewAceDB(source, plan)`, `BridgeKit:ImportAceDB(source,
  targetName, plan)` and `BridgeKit:AceDBMigration(plan)` rebuild an AceDB-3.0
  saved variable in the SettingsKit layout (SettingsKit 0.3.2's public
  contract): profiles, profile choices, `char`, `realm`, `class`, `faction`
  and `global` where SettingsKit reads them; `race`, `factionrealm`,
  `factionrealmregion` and `locale` into global map fields the plan names;
  namespaces under fields the plan names. Every value is checked against the
  addon's schema through a probe table; an AceDB default that differs from
  the SettingsKit default is written as a value, wildcards included, so every
  field reads what it read under AceDB, also after compaction. Profiles and
  characters can be renamed; names SettingsKit refuses are dropped.
- `ImportAceDB` refuses a target or backup global that holds data, writes the
  backup first and never writes the source; `AceDBMigration` runs inside
  `SettingsKit:Open` as a migration step and moves the old contents into the
  backup only once the new layout is built, so a failing step leaves nothing
  behind.
- Import reports (`kind = "aceDB"`, actions `imported`, `materialised`,
  `dropped`, `changed`, `renamed`, `unsupported`), entries with a `detail`
  for `schemaRefused`; the `maxImportEntries` limit (65536, `UNBOUNDED`
  allowed). SchemaKit and SettingsKit join OptionsKit as optional
  dependencies.
- 238 specs (was 199): new `AceDB_spec.lua`, including a round trip through
  SettingsKit itself (every field read before and after compaction), the
  migration inside `SettingsKit:Open`, a failing migration leaving the saved
  table and the backup untouched, every reason and plan error.
- Implementation revision 3: no state changes; an in-place upgrade adds the
  `maxImportEntries` default to the inherited limits.

## 0.2.0 — 2026-11-15

Delivery step N2 of `docs/BRIDGE_KIT_DESIGN.md`: the AceConfig-3.0 adapter.
API generation 1, implementation revision 2. AceSerializer behaviour is
unchanged.

- `BridgeKit:ConvertAceConfig(appName, source[, options])` converts an
  AceConfig-3.0 options table, or a function returning one, into a table for
  `OptionsKit:Define`, with `paths` (converted path to original keys),
  `maxDepth`, `optionCount` and a report. Inheritance of `get`, `set`, `func`,
  `confirm`, `validate`, `disabled`, `hidden` and `handler` is resolved as
  AceConfigDialog resolves it; every Ace callback is wrapped and called with
  an Ace `info` in Ace's shape, method names looked up at call time; keys that
  are not identifiers are renamed deterministically. Options: `uiType`,
  `uiName`, `bind`, `replace`, `strict`, `maxOptions`, `maxDepth`.
- `BridgeKit:DefineAceConfig(addonName, source[, options])` converts and
  defines the tree in OptionsKit, found through `Registry:Find`; OptionsKit
  becomes an optional dependency.
- `BridgeKit:FormatReport(report[, maxLines])` and the report shape shared
  with the coming AceDB importer; the `maxReportEntries` limit (1024,
  `UNBOUNDED` allowed).
- Fixed before release, from the read-only review of the step: a `replace`
  group deeper than the rest of the tree, keys longer than 32 bytes in
  `paths`, `bind` and `replace`, truthy `hidden` answers once flags combine,
  `validate` answers Ace accepts, secret multiselect states, sorting keys and
  font sizes, fields OptionsKit would refuse (now `malformedField` entries),
  plugins merged in name order, non-string keys and malformed `args` reported,
  `missingMethod` for every callback kind, and values tables larger than 1024.
- 199 specs (was 142): new `AceConfig_spec.lua`, every reason of the
  vocabulary, inheritance, the callback shapes, renaming, `bind`, `replace`,
  `strict`, the limits, the errors, and a converted tree defined in OptionsKit
  and driven through `Get`, `Set`, `Validate`, `Execute` and `Describe`.
- Implementation revision 2: no state changes; an in-place upgrade from
  revision 1 adds the `maxReportEntries` default to the inherited limits.

## 0.1.0 — 2026-11-15

The first revision, delivery step N1 of `docs/BRIDGE_KIT_DESIGN.md`: the
AceSerializer-3.0 wire format. API generation 1, implementation revision 1.

- `BridgeKit:AceSerialize(...)` writes the text Ace3's AceSerializer-3.0
  (`MINOR` 5, Ace3 `5e2e0d3b`) writes for the same values, and refuses with a
  reason where Ace3 would raise or write undefined bytes: `unsupportedType`,
  `cycle`, `nan`, and the limits.
- `BridgeKit:AceDeserialize(text)` reads what Ace3 reads, within the limits,
  and never raises on malformed text: `notAceSerializer`, `missingTerminator`,
  `invalidNumber`, `invalidFloat`, `invalidEscape`, `unknownControl`,
  `tableFormat`, `invalidKey` and the limits. Where `2^exponent` alone
  underflows, a `^F` number is scaled with `ldexp`, so a subnormal number
  Ace3's own reader reads as `0` reads back exactly; everywhere else the
  arithmetic is Ace3's. A tilde is read before `@` to `}` only, as Ace3 reads
  it.
- `SetLimits` and `GetLimits` for `maxDepth`, `maxValues`, `maxStringLength`,
  `maxTextBytes` and `maxListValues`; `UNBOUNDED`; `ACE_WIRE_VERSION`; the
  read-only `ACE_BASELINE`.
- 142 specs, 91 of them generated from output recorded from Ace3 (one of them
  over every byte that can follow a tilde) by
  `python3 -m tooling.fixtures.ace_serializer`
  (`tests/fixtures/AceSerializerFixtures.lua`).
