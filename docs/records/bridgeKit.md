# bridgeKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## bridgeKit AceSerializer speed and SettingsKit's character key

**bridgeKit AceSerializer speed and SettingsKit's character key** — an internal change to facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API generation 1 (unchanged),
   version 0.5.2, implementation revision 7 (from 0.5.1, revision 6).
   Patch: no public method is added or removed.
2. Purpose: bring the AceSerializer-3.0 format closer to AceSerializer's
   own cost, byte for byte the same output, following the runtime
   performance diagnosis of 2026-11-15 (codecKit and bridgeKit, causes 1
   and 4), and key the current character the way SettingsKit does.
   - Writer: `append` (`BridgeKit.lua:648`) inlined on the string and
     number paths, one bound check for the tag and its text together.
   - Limits read as numbers once per call: `UNBOUNDED` becomes `math.huge`
     in `serialize` and the reader's entry point, so `exceeds()` (`:616`)
     is no longer called per value on either side.
   - Reader: `nextToken()` (`:841`) inlined, one Lua call less per token.
   - `unescape` (`:846`) without a closure per escaped string: one
     replacement function for every call, its refusal flag an upvalue reset
     per string (`string.gsub` cannot re-enter it).
   - The open-table set `onPath` (`:701`) becomes a stack indexed by depth,
     compared with `rawequal`, so it no longer rehashes as tables open and
     close. The walk is bounded by `maxDepth`.
   - A bounded clean-string cache: up to 256 strings of at most 32 bytes,
     recorded only when the escape scan finds nothing to escape, filled
     once and never wiped (a wipe-when-full version thrashed on the large
     payload). The secret check still runs before the lookup.
   - The secret-probe rule: `issecretvalue` resolved once at load (`:381`
     reads it on every call today), looked up per call only when it was
     absent at load.
   - Character key: SettingsKit gains `SettingsKit:GetCharacterKey()`
     (`UnitNameUnmodified("player")` first, then `UnitName("player")`, with
     the realm) in its next revision. `noteCharacterKeys` (`:3694-3735`)
     asks it through the SettingsKit facade that `Registry:Find("settingsKit",
     1)` returns (as `:4258` already does for the profile-name limit) when
     the method is present, and otherwise applies the same rule itself.
     The `characterKeyMismatch` entry for "`UnitNameUnmodified` differs
     from `UnitName`" then goes away: AceDB and SettingsKit key that
     character alike. The report for clients whose interface lies between
     16000 and 19999 (`char` and `realm` keyed by name and ruleset) stays.
   Not in this record: plain finds for the escape scan (the pattern
   `"[%c \094\126\127]"` covers 35 bytes, space among them), and the checks
   that refuse a secret key met while walking a caller's table (`:576`,
   `:1493`, `:1762`, `:2450`, `:2933`, `:4155`, `:4946`, `:5091`). Decision
   19b covers a secret used to index a table, which the client refuses at
   the read. It has not been measured that the client also refuses to store
   a secret key, or never hands out a table holding one, so those checks
   stay until a client suite shows it.
3. Dependencies: unchanged. SettingsKit stays optional:
   `GetCharacterKey` is used when the loaded SettingsKit has it.
   `UnitNameUnmodified`, `UnitName` and `GetRealmName` are read as today
   through `askClient`.
4. Surface: unchanged methods, errors, limits and reasons. The preview
   report no longer carries `characterKeyMismatch` for a character whose
   unmodified name differs from its name. It still reports
   `currentCharacterMissing` when the key SettingsKit will use is absent
   from `char`, and keeps the ruleset `characterKeyMismatch` and
   `realmKeyMismatch` entries.
5. Ownership: the clean-string cache, the replacement function and the
   depth stack are file-local and rebuilt by each revision's load; nothing
   is saved and nothing new goes into `_state`. The cache holds up to about
   14 KB of caller strings for the session (Lua 5.1 never collects strings
   from weak tables, so the size cap is the bound). An in-place upgrade from
   revision 6 needs no migration.
6. Performance and memory, host bench, MoltenCodes ÷ Ace3 in the same run
   (the diagnosis prototype, `aceSerializer` workload; output compared
   byte for byte with `cmp`):

   | Case | Before | After (expected) |
   |---|---:|---:|
   | encode small / medium / large | 1.78 / 1.75 / 1.73× | 1.37 / 1.27 / 1.37× |
   | decode small / medium / large | 1.50 / 1.40 / 1.37× | 1.28 / 1.16 / 1.15× |

   Decode allocation: small 832 → 720 B, medium 26,110 → 20,510 B, large
   93,919 → 71,459 B (Ace3: 600, 20,384, 71,050 B). Held memory: up to
   +14 KB for the cache. The target "below AceSerializer" is not reached by
   any measured change. What remains is the documented work AceSerializer
   does not do: limits, cycle refusal, secret checks and the re-entrancy
   guard.
7. Tests:
   - byte-identical output against the current revision for payloads with
     escapes, floats, negatives, 2^40, `math.huge` and nested tables;
   - each limit at its bound and one past it, bounded and `UNBOUNDED`, on
     both sides;
   - a cycle refused at every depth up to `maxDepth`, and a table met twice
     on different branches accepted;
   - every escape and every refused escape through the closure-free
     `unescape`, including a refused one followed by a valid string (the
     flag resets);
   - the cache: a clean short string written twice, a string that needs
     escaping never recorded, strings over 32 bytes never recorded, the
     cap respected, a secret refused before the lookup;
   - the probe rule: present at load, installed after load;
   - character key: `GetCharacterKey` used when SettingsKit has it; the
     same key without it; no `characterKeyMismatch` for an unmodified name
     that differs; the ruleset entries unchanged; `currentCharacterMissing`
     against the new key;
   - in-place upgrade from revision 6.
   Client suite (`tests/client/MoltenCodesTest_BridgeKit/`, never run
   here): the preview names the current character under the key
   `UnitNameUnmodified` gives.
8. Docs: `docs/API.md` (the preview's character-key paragraph, the
   AceSerializer cost notes), `INTERNALS.md` (the inlined writer and
   reader, the cache, the depth stack), `CHANGELOG.md` 0.5.2, `README.md`
   performance note, `tests/README.md`, the client suite's `EXPECTED.md`.
   `docs/BRIDGE_KIT_DESIGN.md` section 7.3 ("Scope by scope", the `char`
   row) follows the new rule; that file is outside the package, so its text
   is supplied for the owner to apply.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.2,
   revision 7, 11 specs (302); the store-side key checks stay on the owner's
   decision; docs/BRIDGE_KIT_DESIGN.md 7.3 updated.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## bridgeKit carries option fields over and rebuilds converted trees

**bridgeKit carries option fields over and rebuilds converted trees** — a change to facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API generation 1 (additive),
   version 0.6.0 (from 0.5.2), implementation revision 8 (from 7).

2. Purpose: a converted AceConfig table keeps every field the registered
   OptionsKit accepts instead of dropping it; a converted tree follows
   later changes to the Ace table, as AceConfigRegistry's `NotifyChange`
   does; and an AceDB import keeps namespaces (8/16 corpus addons register
   one, 63 registrations) and the four extra scopes in their own layout once
   SettingsKit has them.

   a. **Carry-over by `GetFields`.** The conversion asks
      `OptionsKit:GetFields(kind)` once per kind and conversion (when
      `Registry:Find("optionsKit", 1)` has it; otherwise today's behaviour
      in full, as for `childGroups` before revision 10). A field the
      registered OptionsKit lists is carried over in OptionsKit's form;
      everything else keeps today's rule and report entry:

      | Ace field | Carried as | Report today | After |
      |---|---|---|---|
      | `width`, `relWidth` | the value; an unknown `width` string or a `relWidth` outside `0 < x <= 1` dropped | dropped `presentation` | none; `malformedField` for a bad value |
      | `descStyle` | `"inline"`, `"tooltip"`; another string dropped (Ace shows no description then) | dropped `presentation` | none; `presentation` for another string |
      | `confirm`, `confirmText` on value kinds | a wrapper `fun(info, value)` keeping Ace3's rules (method or function, string answer, `true`, `confirmText`); a multiselect asks for the first key that changes, a colour passes its four numbers | dropped `confirmOnValue` | none |
      | `confirm` function or method on `execute` | the same wrapper | changed `dynamicConfirm` | none |
      | `name`, `order` functions or methods | wrapped live (called by `Describe`) when the kind's `name`/`order` accepts `function` | changed `evaluatedOnce` | none |
      | `fontSize`, `sorting` functions | wrapped live when accepted | changed `evaluatedOnce` | none |
      | `image`, `imageCoords`, `imageWidth`, `imageHeight`, `icon`, `iconCoords`, `tooltipHyperlink` | the value, or a wrapper for a function or method (an `image` wrapper returns Ace3's three values) | dropped `presentation` | none |
      | `guiHidden`, `dialogHidden`, `cmdHidden` | themselves, as wrapped predicates | folded into `hidden` for `uiType`, others dropped (`perInterfaceFlag`) | none |
      | `guiInline`, `dialogInline`, `cmdInline` | themselves | folded into `inline` for `uiType` | none |
      | `style` on `select` | `"radio"`/`"dropdown"` | dropped `presentation` | none |
      | `multiline` as a count | the count | changed `lineCount` | none |
      | `tristate` on `multiselect` | `true` | changed `multiselectTristate` | none |
      | `control`, `dialogControl`, `itemControl` (on `select`) | the string | dropped `customControl` | none |
      | `dropdownHidden`, `dropdownInline`, `dropdownControl` | not carried | dropped (`perInterfaceFlag`, `customControl`) | dropped without a report line, unless `uiType` is `"dropdown"` (today's folding stays for that case) |

      Kept as today: BridgeKit resolves inheritance and `handler` itself and
      wraps every Ace callback with Ace3's own `info` (`arg`, `handler`,
      `options`, `option`, `uiType`), so `arg` and `handler` are not carried;
      `plugins` keep Ace3's "plugin wins" merge with `pluginShadowed`;
      `hasAlpha` functions stay evaluated once.
   b. **Rebuilt conversions.** When the registered OptionsKit has the
      Dynamic part (`type(OptionsKit.Tree.NotifyChange) == "function"`),
      `DefineAceConfig` defines the tree with a builder that runs the same
      conversion again on the same source (a table or a function) with the
      same options, so `tree:NotifyChange()` after the addon edits its Ace
      table, or with a source function, shows the change. The report the
      first conversion produced is returned as today; a function source
      then no longer gets `sourceFunction`. A later conversion's report is
      not kept; under `strict`, a rebuild that would report raises inside
      the builder, which OptionsKit reports and survives (record 2, 2f).
      Without the part, today's single snapshot and `sourceFunction` stay.

   c. **AceDB namespaces and scopes imported natively.** When the loaded
      SettingsKit reports `REVISION >= 15` (read from the facade
      `Registry:Find("settingsKit", 1)` answers), the importer writes:
      - each `sv.namespaces[n]` into the destination's `namespaces[n]` in
        AceDB's own layout: its ten scope sections (`profiles`, `char`,
        `realm`, `class`, `race`, `faction`, `factionrealm`,
        `factionrealmregion`, `locale`, `global`) copied as they are, with
        `char` keys renamed as `SettingsKit:GetCharacterKey` names
        characters (the rule `noteCharacterKeys` already applies to the
        main `char` section), every table bounded by the importer's
        `maxDepth` and secret values refused as everywhere else;
      - the main `race`, `factionrealm`, `factionrealmregion` and `locale`
        sections copied as they are into same-named sections.
      Values are copied, not checked against a schema: a namespace's schema
      is registered by the addon at runtime (`RegisterNamespace`), and
      SettingsKit checks what it opens. `plan.namespaces` and
      `plan.scopes` remain accepted and keep today's mapping for a
      SettingsKit before revision 15; with revision 15 an entry for a
      namespace or scope that is imported natively is ignored and reported
      once (`changed`, `nativeNamespace` / `nativeScope`), so a plan written
      for both revisions keeps working. The reasons `unmappedNamespace` and
      `unsupportedScope` then appear only with an older SettingsKit.
      Preview (`PreviewAceDB`) reports the same as the import.

   Non-goals: carrying `arg`/`handler` natively; changing the plugin rule;
   an AceConfigRegistry-shaped `NotifyChange(appName)` shim; checking
   namespace values against a schema at import; LibDualSpec-1.0's saved
   assignments (unchanged: still dropped).

3. Dependencies: unchanged (registry API 2; optionsKit API 1 and
   settingsKit API 1 optional, as today). No client function. Item 2c reads
   SettingsKit's published `REVISION` and its revision 15 layout as that
   record announces it; the exact section names are checked against
   SettingsKit's code before implementation.

4. Surface: no method added or removed. Conversion output gains the fields
   above when OptionsKit offers them; the report reasons `confirmOnValue`,
   `dynamicConfirm`, `lineCount`, `multiselectTristate` and the carried
   cases of `presentation`, `customControl`, `perInterfaceFlag`,
   `evaluatedOnce` and `sourceFunction` no longer appear with an OptionsKit
   of revision 14 (15 for the last), and still do with an older one. The
   reason names stay valid values. The AceDB report gains `nativeNamespace`
   and `nativeScope` (`changed`); `unmappedNamespace` and `unsupportedScope`
   appear only with a SettingsKit before revision 15.

5. Ownership: the per-conversion field cache lives in the conversion's work
   table and is dropped with it; the builder closure holds the source and
   the read options for the tree's lifetime (only with the part, as
   AceConfigRegistry holds the table). Nothing goes into `_state`. In-place
   upgrade from revision 7: no state change; trees defined by revision 7
   stay snapshots.

6. Performance and memory: a conversion asks `GetFields` at most 11 times
   (about 11 small tables of garbage per conversion, once at load) and
   wraps more callbacks (one closure per carried function field, about 100
   B each, only for fields the source uses). A `NotifyChange` on a converted
   tree costs one conversion plus one OptionsKit rebuild (bench `bridge`
   conversion case: within its current ratio, measured before release).
   BridgeKit resident: +4 to +6 KB (about 120 lines). Main chunk at or
   below 175 locals (173 today), new helpers in `do` blocks.

7. Tests: every row of the table with an OptionsKit stand-in that has
   `GetFields` (carried, form, report) and one without (today's output and
   report unchanged, the existing specs); the confirm wrapper for each Ace
   form and kind (multiselect key, colour values, method missing at call);
   live `name`/`order` wrappers against the real OptionsKit's `Describe`;
   `dropdown*` silent for `"dialog"` and `"cmd"`, folded for `"dropdown"`;
   rebuilt conversions: table edited then `NotifyChange`, function source,
   strict failure on rebuild reported and survived, without the part
   (snapshot and `sourceFunction`); AceDB import and preview with a
   SettingsKit stand-in reporting revision 15 (namespaces copied with their
   ten sections, `char` keys renamed, depth bound, secrets refused, the four
   scopes copied, plan entries ignored and reported) and with revision 14
   (today's mappings and reports unchanged); in-place upgrade from
   revision 7.
   Client suite (never run here): a converted table with `width`,
   `confirm` on a toggle and a runtime-added option after `NotifyChange`.

8. Docs: `docs/API.md` (the AceConfig field table, *Reasons* with the
   "only with an older OptionsKit" note, `DefineAceConfig` rebuilds),
   `INTERNALS.md` if it exists for the adapter, else the adapter notes in
   API.md, README migration table, CHANGELOG 0.6.0, `tests/README.md`, the
   client suite's `EXPECTED.md`. `docs/BRIDGE_KIT_DESIGN.md` section 6.2
   (the per-interface folding) is outside the package; its text is supplied
   with the code.

9. Status: implemented 2026-11-15, 0.6.0, revision 8, 317 specs; AceDB
   namespaces and the four new scopes imported natively with SettingsKit 15,
   round-tripped through its real namespaces. Held memory 276.9 KB (252.1 KB
   before, over the 4 to 6 KB estimated).

Moved from `docs/ROADMAP.md` (Package N — bridgeKit, migrating from Ace3).

## bridgeKit

**bridgeKit** — facade `BridgeKit`

1. Package `bridgeKit`, facade `BridgeKit`, API generation 1.
2. Purpose: the three migration tools an Ace3 addon cannot write safely by
   hand. (a) An AceConfig-3.0 options table (or table function) converted into
   an OptionsKit tree for a documented subset, the addon's Ace
   `get`/`set`/`func`/`validate` handlers kept and called with an Ace-shaped
   `info`, inheritance resolved at conversion, and a per-field report of every
   field dropped, renamed or changed in meaning. (b) An AceDB-3.0 saved
   variable imported into the SettingsKit layout: profiles, profile choices,
   every AceDB scope (`char`, `realm`, `class`, `race`, `faction`,
   `factionrealm`, `factionrealmregion`, `locale`, `global`, `profile`) and
   namespaces, validated against the SettingsKit schema, with AceDB defaults
   that differ from SettingsKit's written as values so every field reads what
   it read before; copy-based (the source is never mutated), previewed, backed
   up. (c) A wire adapter that writes and reads AceComm-3.0's multipart format
   and AceSerializer-3.0's text format byte for byte, bounded where Ace3 is
   not, versioned, so an addon can move to CommKit and CodecKit while its peers
   still run the Ace3 version. Non-goals: running or embedding Ace3 code,
   emulating Ace3 method calls, rendering (WidgetKit, CommandKit), AceGUI and
   AceConfigDialog layouts and the Blizzard settings panel (the
   user-interface phase), keeping two databases in sync, ChatThrottleLib.
3. Dependencies: registry API 2, nothing else required. Optional through
   `Registry:Find`: optionsKit API 1 (`DefineAceConfig`), schemaKit API 1
   (the importer's probe checks), commKit API 1 in a revision with raw addon
   messages (`OpenAceComm`). The serializer
   and the plain AceConfig conversion embed two files. Two prerequisites in
   other Kits, not made in this step: CommKit gains `RegisterRaw` and
   `SendRaw` (P1), and SettingsKit's saved-table layout becomes a documented
   contract (P2, documentation only).
4. Surface: `BridgeKit:ConvertAceConfig(appName, source, options?)` →
   conversion `{ tree, report, paths, maxDepth, optionCount }`;
   `BridgeKit:DefineAceConfig(addonName, source, options?)` → tree, report;
   `BridgeKit:PreviewAceDB(source, plan)` → report;
   `BridgeKit:ImportAceDB(source, targetName, plan)` → report or `nil,
   reason`; `BridgeKit:AceDBMigration(plan)` → a SettingsKit migration step;
   `BridgeKit:AceSerialize(...)` → `true, text` or `false, reason`;
   `BridgeKit:AceDeserialize(text)` → `true, ...` or `false, reason`, never
   raising on malformed text; `BridgeKit:OpenAceComm(scope, prefix, callback,
   options?)` → channel (`Send`, `Close`, `IsClosed`, `GetPrefix`,
   `GetPriority`, `GetWireVersion`) or `nil, reason`;
   `BridgeKit:FormatReport(report, maxLines?)`; `GetStatistics()`;
   `SetLimits{ maxReportEntries, maxImportEntries, maxDepth, maxValues,
   maxStringLength, maxTextBytes, maxListValues, maxAceStreams,
   maxAceStreamsPerSender, maxAceStreamBytes, maxAceSpoolBytes,
   aceStreamTimeout, maxDropReportSenders }`, `GetLimits()`, `UNBOUNDED`,
   `ACE_WIRE_VERSION`, `ACE_BASELINE`, `API`, `REVISION`. Programming errors
   raise at the caller's line; data problems are report entries or returned
   reasons.
5. Ownership: conversions, reports and previews are plain tables the caller
   owns. The importer writes only the target global and the backup global the
   caller names, and refuses either when it already holds data. A wire channel
   lives in the CommKit scope the caller passes and closes with it; AceComm
   reassembly belongs to the prefix, shared by every channel on it, and is
   dropped when the last channel of the prefix closes. BridgeKit owns no
   per-addon scope and needs no logout close.
6. Performance: conversion and import are one-time walks that allocate by
   design; a wrapped Ace accessor adds one call and allocates nothing, except
   the `color` and `multiselect` getters (one table per `Get`, an options
   screen being no hot path); the serializer reuses its fragment array and
   allocates only its result and the values it decodes; a single-part AceComm
   message costs one table read beyond CommKit's raw delivery; reassembly
   holds at most `maxAceSpoolBytes` (1 MB) with no polling (streams expire at the
   next receive, design decision 20). Costs are measured and recorded before the first release,
   and the benchmark compares them with Ace3 fetched at run time, never
   redistributed.
7. Tests: Busted specs for every row of the design's field, scope, defaults
   and format tables, inheritance resolution, report vocabularies, `strict`,
   limits, secrets, error levels, upgrade and manifest; a source table
   snapshot equal before and after every import; hostile serializer input
   truncated at every byte never raising; AceSerializer and AceComm fixtures
   recorded from Ace3 over the project's own inputs, with provenance, and no
   Ace3 source or tests copied; a client suite proving wire compatibility
   with real Ace3 over whisper-to-self, what bytes the client's addon channel
   carries, the AceDB import across `/reload` in both modes, a converted tree
   rendered by WidgetKit and CommandKit, and the secret refusals.
8. Docs: README (the three parts, footprint per part, when to stop embedding
   it), `docs/API.md` (the contract, every reason with its Ace3 citation,
   costs, deviations), CHANGELOG; `docs/MIGRATING_FROM_ACE3.md` updated from
   planned to current API; EMBEDDING footprint and host-requirements rows;
   ARCHITECTURE, `docs/README.md` and `README.md` list the package; the design
   document kept current.
9. Status: delivered (2026-11-15). Design and migration guide written. The
   owner answered the design's five open questions on 2026-11-15, accepting
   every recommendation (design decisions 9 to 13). Delivery sequence N0
   (prerequisites P1, P2) to N5 in the design, section 15. N0 is done
   (2026-11-15): CommKit 0.5.0 carries raw addon messages and SettingsKit
   0.3.2 publishes its saved-table layout. N1 is done (2026-11-15):
   bridgeKit 0.1.0 writes and reads AceSerializer-3.0 text, held to output
   recorded from Ace3. N2 is done (2026-11-15): bridgeKit 0.2.0 converts
   AceConfig-3.0 tables to OptionsKit trees. N3 is done (2026-11-15):
   bridgeKit 0.3.0 imports AceDB-3.0 saved variables into the SettingsKit
   layout. N4 is done (2026-11-15): bridgeKit 0.4.0 speaks AceComm-3.0
   through CommKit's raw addon messages; streams expire lazily instead of on
   a TimerKit timer (design decision 20). N5 is done (2026-11-15): the
   real-client suites (written, not yet run in a client), the
   `aceSerializer` benchmark workload, the measured costs and the
   acceptance review, accepted after fixes; package N is closed.

