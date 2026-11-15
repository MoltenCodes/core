# Changelog

## 0.5.2 — 2026-11-15

- Character keys: the AceDB preview and import key the current character the way SettingsKit does. BridgeKit asks `SettingsKit:GetCharacterKey()` when the loaded SettingsKit has it, and otherwise applies the same rule: `UnitNameUnmodified("player")`, then `UnitName("player")` when that is absent or unusable, `" - "`, `GetRealmName()`. AceDB keys characters by `UnitNameUnmodified` too, so the `characterKeyMismatch` entry for a character whose unmodified name differs from its name is gone; `currentCharacterMissing` is checked against that key, and the reports for clients whose interface lies between 16000 and 19999 are unchanged. `docs/API.md` (*Section by section*) and the design's section 7.3 follow.
- Performance of the AceSerializer-3.0 format, byte for byte the same text: the writer appends a token and its data with one bound check, reads a lifted limit as `math.huge` once per call instead of testing for the sentinel per value, keeps the open tables as a stack by depth for the cycle check, and remembers up to 256 short strings (32 bytes or less, recorded once, up to about 14 KB held) it found clean; the reader moves to the next token inline and unescapes without a closure per string. Host benchmark against AceSerializer-3.0, same session (2026-11-15): encode 1.86, 1.80, 1.82× → 1.39, 1.36, 1.39× (small, medium, large); decode 1.48, 1.38, 1.38× → 1.26, 1.13, 1.12×, allocating 720 B, 20.5 KB and 71.5 KB instead of 832 B, 26.1 KB and 93.9 KB (Ace3: 600 B, 20.4 KB, 71.1 KB).
- The secret probe follows the rule every Kit follows: `issecretvalue` is resolved once when the file loads, and read at every call only when it was absent then.
- Implementation revision 7. No state changed: an upgrade over revision 6 keeps every limit, channel and counter (`Bootstrap_spec.lua`, "upgrades a revision 6 copy in place ...").
- Specs: 291 → 302. `Serializer_spec.lua` ("revision 7 writer and reader"): the clean-string cache and its cap, a secret refused first, cycles at every depth and a table met on two branches, the refused-escape flag reset per string, the probe rule. `AceDB_spec.lua`: the unmodified-name key, the `UnitName` fallback, `GetCharacterKey` asked when present.

## 0.5.1 — 2026-11-15

- Fixed: a `childGroups` value is carried over only when it is one of Ace's three layouts (`"tab"`, `"tree"`, `"select"`) as well as listed in OptionsKit's published `CHILD_GROUPS`. Revision 5 trusted the published table alone, which is a copy a consumer can write to: a value written there was kept, and `DefineAceConfig` then raised because `OptionsKit:Define` still refuses it. Such a value is now dropped and reported as `presentation`.
- Implementation revision 6. No state changed: an upgrade over revision 5 keeps every limit, channel and counter.
- Specs: `keeps only Ace's three layouts when a consumer writes to CHILD_GROUPS` and `checks childGroups against Ace's layouts after an in-place upgrade from revision 5`.
- Docs: the source header and the limits comment named the parts and limits of revision 1; API.md gave revision 4 as the current one; the README gains the Ace3 migration table and the embedding block; API.md says LibDualSpec-1.0's assignments are not imported and points at SettingsKit's spec profiles.

## 0.5.0 — 2026-11-15

- Added: `ConvertAceConfig` and `DefineAceConfig` keep a group's `childGroups` (`"tab"`, `"tree"` or `"select"`) when the registered OptionsKit publishes `CHILD_GROUPS` (OptionsKit revision 10 and later), so WidgetKit's renderer draws Ace's tabs, tree and drop-down groups as pages. With an older OptionsKit or none, and for any other value, the field is dropped and reported as `presentation`, as before. Design decision 23.
- Implementation revision 5. No state changed: an upgrade over revision 4 keeps every channel and counter.
- Specs: the field kept and described, an unknown value dropped, and an OptionsKit without `CHILD_GROUPS`. The AceComm upgrade spec loads `REVISION + 1` instead of a fixed revision.

## 0.4.0 — 2026-11-15

Delivery step N4 of `docs/BRIDGE_KIT_DESIGN.md`: the AceComm-3.0 channel. API
generation 1, implementation revision 4.

- `BridgeKit:OpenAceComm(scope, prefix, callback[, options])` opens a channel
  on a CommKit scope's raw addon messages (CommKit 0.5.0): `channel:Send`
  writes the messages AceComm-3.0 writes (one message, the escape byte, or
  254-byte parts), and the callback receives whole messages reassembled with
  AceComm's rules, `Ambiguate`d by default. Several channels on one prefix
  share one reassembly and each receives every message once, also when a
  callback closes or opens channels; the priority is fixed per prefix and
  `Close` cancels the channel's queued sends; the channel closes with its
  scope, and the prefix's streams are released with its last channel.
- Bounds Ace lacks: `maxAceStreams`, `maxAceStreamsPerSender`,
  `maxAceStreamBytes`, `maxAceSpoolBytes`, `aceStreamTimeout` (streams
  expire at the next message received, design decision 20) and
  `maxDropReportSenders`; drops are reported through the error handler at
  most once per sender per minute.
- Step N5: real-client suites (`tests/client/MoltenCodesTest_BridgeKit`,
  not yet run in a client), the `aceSerializer` benchmark workload against
  AceSerializer-3.0 and the measured costs in API.md; the package's
  acceptance review closes package N.
- `BridgeKit:GetStatistics()`: the AceComm counters, open streams and spool
  bytes. CommKit joins the optional dependencies.
- Implementation revision 4: the AceComm state lives in `_state`, and the
  raw handlers call through it, so channels opened before an in-place
  upgrade run the newer receive code; an upgrade adds the state and the new
  limits' defaults.

- `AceSerialize` and `AceDeserialize` keep their state in reused upvalues
  instead of a record per call, write a token and its data as separate
  pieces, and cut tokens with one pattern match each: a small encode allocates
  198 bytes (Ace3: 201) instead of 1655, and both run closer to Ace3's speed
  (docs/BENCHMARKS.md). Every check stays; the recorded Ace3 fixtures pass
  byte for byte.
- The writer empties its state when a replaced `issecretvalue` raises, and
  refuses a call that `issecretvalue` makes back into `AceSerialize` (step
  N5's acceptance review).
- Every channel method raises at the caller for a dot call, and the channel,
  its options, its send request and the statistics have LuaCATS classes.

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
