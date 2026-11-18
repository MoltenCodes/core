# settingsKit records

Moved from `docs/ROADMAP.md` (Package C planned Kits — the nine points).

## settingsKit

**settingsKit** — facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1.
2. Purpose: saved variables done once: a database opened over the addon's
   SavedVariables table with scopes (`global`, `char`, `realm`, `class`,
   `faction`, `profile`), defaults applied without being written back
   (including wildcard defaults for keyed sections), profiles with copy,
   reset and delete, change notifications, and versioned migrations.
   v1 ships profiles; spec-aware profiles and namespaces are v2 (recorded
   here so the state layout leaves room: a `namespaces` table and a
   `profileKeys` table exist from v1). Non-goals: an options UI, storage
   outside SavedVariables, encryption.
3. Dependencies: registry API 2, schemaKit API 1 (defaults and validation),
   signalKit API 1 (change and profile signals); lifecycleKit API 1
   optional through `Registry:Find` (flush hook at shutdown is the host's
   job; nothing to do — documented).
4. Surface: `SettingsKit:Open(savedVariable, schema, options)` where
   `savedVariable` is the global name from the TOC (the table is created if
   missing), `schema` a `SchemaKit.table` per scope (`{ global = ..., profile
   = ..., char = ... }`), options `defaultProfile` (`"Default"` or `"char"`
   for one profile per character), `version` and `migrations = { [n] = fn(db) }`;
   the returned `db` exposes `db.global`, `db.char`, `db.realm`, `db.class`,
   `db.faction`, `db.profile` as live tables whose reads fall back to
   defaults through a metatable and whose writes are validated against the
   schema at the writer's line; `db:GetProfile()`, `db:SetProfile(name)`,
   `db:GetProfiles()` (sorted, allocating), `db:CopyProfile(from)`,
   `db:ResetProfile()`, `db:DeleteProfile(name)`, `db:ResetDatabase()`,
   `db:OnChange(scope, callback)` / `db:OnProfileChanged(callback)` returning
   SignalKit connections; `db:Compact()` removes values equal to defaults
   before logout (called automatically on `PLAYER_LOGOUT` when EventKit is
   present, documented).
5. Ownership: one `db` per saved-variable name in package state; connections
   are the consumer's; upgrades keep databases and their listeners.
6. Performance: a read is one table read or one default lookup; a write is
   one schema check plus one table write; no per-read allocation; default
   fallback never writes into the saved table, so files stay small; scopes
   are resolved once at `Open` from `UnitName`, `GetRealmName`,
   `UnitClass`, `UnitFactionGroup` (stubbed in tests).
7. Tests: defaults not written back, wildcard defaults, validated writes at
   the caller's line, each scope key, profile switch with signal, copy,
   reset, delete (current profile refused), migrations in order once,
   Compact, OnChange, upgrade keeping the db, manifest, error levels.
8. Docs: README, API.md with a full addon example (TOC `## SavedVariables`,
   schema, Open in OnLoaded), INTERNALS.md (layout of the saved table),
   CHANGELOG; EMBEDDING.md host row and a saved-variables section.
9. Status: implemented (package C2, 0.1.0); deviations recorded in
   `packages/settingsKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## settingsKit spec profiles

**settingsKit spec profiles** — an addition to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.4.0, implementation revision 11.
2. Purpose: a database switches its current profile by itself when the
   player changes specialization, what LibDualSpec-1.0 gives AceDB-3.0
   databases. Each character assigns a profile to a *spec index*; when the
   index changes, the database calls its own `SetProfile` with the
   assigned name, so `db.profile`, getters and `OnProfileChanged` follow
   as for any switch. The spec index is the specialization on Retail and
   Mists of Pandaria Classic (`C_SpecializationInfo.GetSpecialization()`,
   1 to the class's count), and the active talent group on Classic Era,
   Season of Discovery and Hardcore, where dual talent specialization is
   the mechanism (`C_SpecializationInfo.GetActiveSpecGroup()`). Which of
   the two is decided once from `WOW_PROJECT_ID`, with ClientKit's
   literals: `1` and `19` mean specialization, anything else (or no
   constant) means talent group, the answer every client has. This is
   the roadmap's "spec-aware profiles" (settingsKit record, point 2),
   which the saved-table contract lets generation 1 add as a new section.
   Non-goals: the options UI (OptionsKit's `ProfileOptions`, a separate
   capability with its own record), switching on Retail talent loadouts,
   pet specializations, an enabled flag (no assignment means no
   switching), importing LibDualSpec's AceDB namespace (a later bridgeKit
   item).
3. Dependencies: unchanged, registry API 2, schemaKit API 1, signalKit
   API 1; EventKit API 1 stays optional through `Registry:Find` and is what
   makes the switch automatic (without it, the addon calls
   `db:ApplySpecProfile()` itself). Host requirements: `C_SpecializationInfo`
   with `GetSpecialization`, `GetActiveSpecGroup`, `IsInitialized` and
   `GetNumSpecializationsForClassID`, and `UnitClass` (third return, the
   class ID), all in the generated documentation of `live`, `classic` and
   `classic_era`; `GetNumTalentGroups` (not in the generated
   documentation, used by Blizzard's Classic talent frame) for the
   talent-group count, guarded. Every answer is checked with
   `issecretvalue` first. Without `C_SpecializationInfo` the index is
   unknown and nothing switches.
4. Surface: `SettingsKit:GetSpecIndex()` → `index|nil, count, kind`
   (`kind` is `"specialization"` or `"talentGroup"`; `nil` while the
   client has no data yet or the player has no specialization, for
   example Retail's starter specialization, whose index is above the
   class's count); `db:SetSpecProfile(index, name?)` → `true`, or `false`
   when the character key is unavailable: assigns profile `name` to spec
   index `index` (a positive integer up to 8) for this character, `nil`
   clears it, and applies it at once when `index` is the current one;
   `db:GetSpecProfile(index)` → `name|nil`; `db:ApplySpecProfile()` →
   `true` when it switched. Saved table: a new section `specProfiles`,
   keyed by `"<name> - <realm>"`, each entry `{ [index] = profileName }`;
   `Open` creates the section like the others and refuses a present
   non-table; an entry that is not a usable profile name is ignored.
   `DeleteProfile` removes assignments naming the deleted profile,
   `ResetDatabase` empties the section, a read-only database refuses
   `SetSpecProfile` and never switches. A manual `SetProfile` changes no
   assignment; the next spec change applies the assignment again.
5. Ownership: assignments live in the saved variable. One shared listener
   for the session, in state and calling through the dispatch table,
   connected to `PLAYER_ENTERING_WORLD`, `ACTIVE_TALENT_GROUP_CHANGED` and
   `PLAYER_SPECIALIZATION_CHANGED` (`ConnectUnit`, `"player"`) the first
   time a database has an assignment (at `Open` or `SetSpecProfile`), so an
   addon that never uses spec profiles costs EventKit nothing. On each
   event it reads the index once and applies it to every open database
   with an assignment for that index; an unchanged index does nothing.
   Databases opened by revision 10 or earlier gain the methods and the
   switching through the rewritten prototype; the section is created at
   their first `SetSpecProfile`.
6. Performance and memory: nothing per frame and nothing on the read and
   write paths of a view. A spec event costs two or three client calls and
   one table lookup per open database; the switch itself is
   `SetProfile`'s existing cost. No allocation until the first assignment
   of a character (its entry table). The main chunk sits at 197 of Lua
   5.1's 200 slots, so the new code goes in one `do` block with its own
   locals.
7. Tests: stand-ins for `C_SpecializationInfo`, `GetNumTalentGroups`,
   `UnitClass`, `WOW_PROJECT_ID` and the three events through EventKit's
   test environment; both kinds of index, a switch on each event, the
   starter specialization and uninitialised data answering `nil`, no
   switch without an assignment or for an unchanged index, assignment
   applied at once, clearing, `DeleteProfile` and `ResetDatabase` removing
   assignments, read-only refusal, no character key, without EventKit
   (`ApplySpecProfile` only), the listener connected once and only when
   used, a corrupted section and entries, secret answers from the client,
   argument error levels, an upgrade from revision 10 keeping databases
   and switching afterwards, manifest. A client-suite case on Retail (switch
   specialization, see the profile follow) is written and not run.
8. Docs: API.md (*Spec profiles*, the new saved-table section in *The
   saved table*, *Embedded copies and upgrades* for revision 11),
   INTERNALS.md (the shared listener and the section), README (a
   migration table from LibDualSpec-1.0), CHANGELOG, tests/README;
   ROADMAP's settingsKit record and package M checklist (the maintainer's).
9. Status: implemented 2026-11-15 under core decision 16, settingsKit
   0.4.0, revision 11, 33 specs (268 in all), with two additions decided
   while building: `PLAYER_LEVEL_CHANGED` is listened to as well
   (documented on all three flavours), and OptionsKit's `ProfileOptions`
   carries the per-spec choice in the same work (optionsKit 0.6.0, revision
   11, 13 specs: selects `spec1` to `spec8` over
   `db:SetSpecProfile`/`GetSpecProfile`, shown while
   `SettingsKit:GetSpecIndex()` counts more than one index). Deviations:
   the kind is read from `WOW_PROJECT_ID` on every call (same answer, one
   table read); each database remembers the index it last applied, and
   `Open` applies the assignment at once, so after `/reload` the assignment
   wins over a manual choice, as LibDualSpec does; an in-place upgrade also
   connects the listener for characters whose saved table already holds
   assignments. Client-suite tests are written in
   `MoltenCodesTest_SettingsKit` (suite `specProfiles`) and
   `MoltenCodesTest_OptionsKit` and have not been run in a client.
   Review fix 2026-11-15 (decision 17): settingsKit 0.4.1, revision 12: a
   spec event records the index for a database without an assignment,
   switches over a snapshot so databases opened by profile listeners during
   the event never make it skip one, and an in-place upgrade applies
   assignments only to databases revision 10 or earlier opened; 3 specs
   (271 in all). optionsKit 0.6.1, revision 12: a `ProfileOptions` group
   cached without spec selects is replaced once SettingsKit offers spec
   profiles; 1 spec (203 in all).

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## settingsKit read-through views, lazy Open, client-refused secret probes removed

**settingsKit read-through views, lazy Open, client-refused secret probes removed** — a change to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.5.0 (from 0.4.2), implementation revision 14 (from 13), node
   layout 4 (from 3).
2. Purpose: a `db.profile.x` read costs what AceDB's does, `Open` costs no
   more than AceDB's in memory, and a write costs only what its validation
   needs. Five changes:
   a. **Read-through chains** (perf-settings fix 1, prototype B). Each record
      view keeps its empty proxy (so every write still reaches `__newindex`
      and is validated at the writer's line) but gets its own metatable whose
      `__index` is a table: `proxy → shadow (the child views of record
      fields, only for records that have some) → saved table (given a
      SettingsKit metatable) → scalar defaults`. The VM answers a read with no
      Lua call. A keyed section whose every key answers with an entry view
      reads through its entry cache, with the function path on a miss. The
      function path (`viewIndex`) stays for what a chain cannot answer: a
      saved table with a foreign metatable, a record without a default stored
      as a scalar, and a view with a plain-table default (`READ_COPY`) not yet
      stored (the view reads through `viewIndex` until every such key has its
      copy, then is bound to its chain; a read-only database keeps the
      function path for such a view, so a raw read never stores anything,
      `Getter_spec.lua:209`). The chain record is folded into the proxy's
      metatable (fields beside `__index`/`__newindex`/`__metatable`), and the
      saved-table metatable and defaults table are shared per plan when the
      view's defaults are its plan's own. Chains are rebound by one helper
      called at the end of every mutating method, after the mutation (never
      before: the prototype rebound `Compact` before removing tables and wrote
      into a detached table); a table write rebinds only the written view's
      subtree. The generation scheme stays underneath (writes, `Pairs`,
      `Validate` and getters made by revisions 7 to 13 resolve through it).
      `scanValue` accepts a table carrying SettingsKit's saved-table marker.
   b. **Decision 19b: the read-side secret-key probes are removed** from
      `viewIndex` (`SettingsKit.lua:2033-2039`) and `databaseIndex`
      (`3561-3566`). On the client a secret key raises before `__index` runs
      (docs/EMBEDDING.md "Measured on the client", Retail 12.1.0 b69933), so
      the probes could never fire there. A read with a secret key now raises
      the client's own error, "attempted to index a table that cannot be
      indexed with secret keys", at the reading line; SettingsKit's messages
      "... cannot be read with a secret key" and "SettingsKit databases cannot
      be read with a secret key" are gone. `viewIndex` keeps the `type(value)`
      test (no new exception to the repository rule is needed: the chain does
      the hot read). Every other secret check stays: write keys and values,
      `Getter`, `Validate`, `Compact`, profile names, scope names, client
      answers.
   c. **Lazy Open** (fix 4, prototype C, completed). A scope root is built by
      `databaseIndex` on the first `db.<scope>` read, a view's probe table by
      its first full check. Every site that read `rawget(db, scopeName)`
      goes through one root accessor: `Getter`, `Validate`, `Pairs`,
      `SetProfile`'s republication of `db.profile`, spec profiles, `Compact`
      and the upgrade path (the prototype missed `Getter`, `Validate` and spec
      profiles: 21 spec failures). Record children stay eager when their
      parent is built, because the shadow must hold them. **Layout sections
      stay eager**: `docs/API.md` *The saved table* promises that `Open`
      creates every missing section in a writable database and lets other
      code read the layout, so the prototype's lazy layout is not taken (it
      would save about 1.5 KB and 250 instructions on a new saved variable
      only).
   d. **Non-allocating depth limit** (fix 5): `depthAllows` and
      `readMaxDepth` read `SchemaKit:GetLimit("maxDepth")` (schemaKit record
      below) and keep the depth-probe check as the fallback for a SchemaKit
      revision without it. `SetLimits` still applies at once.
   e. **Fused scalar write path** (fix 8): one function for the common write
      (a verified record view, a non-table value, a field with a compiled fast
      check): read-only and detached tests, the value's secret probe, the fast
      check, the store, the signal. Everything else takes the current path.
      Messages and error levels unchanged.
   f. **Character key from `UnitNameUnmodified`** (ace3-gaps side finding):
      `readScopeKeys` asks `UnitNameUnmodified("player")` first and falls back
      to `UnitName("player")` when it is absent or its answer is not usable
      (secret, empty, not a string), so no client that has a key today loses
      it. The two answer alike except under a name-changing effect, where
      today's key is the effect's name, so existing saved data keeps its key.
   g. **`db:Getter` becomes a thin closure over the chain**: bound to a view,
      `return proxy[key]`; following a scope, `return db[scopeName][key]`.
      Its argument checks and the key's secret probe at creation stay. A call
      cannot cost less than the plain read it performs plus one Lua call;
      that floor is the target. Getters made by revisions 7 to 13 keep their
      closures and keep working (the generation scheme stays). The docs say
      a plain read is now the hot-loop answer and `Getter` is for handing a
      reader around.
   Non-goals: lazy layout sections (above), lazy record children under
   chains, splitting views or spec profiles into a part file (decision 18a,
   a later package O record), WoW Forever's regional unique names (not a supported client; see
   the report), a plan built from SchemaKit's compiled nodes instead of
   `Describe` copies (not measured).
3. Dependencies: registry API 2, schemaKit API 1 (uses `GetLimit` when
   present, falls back without it), signalKit API 1, eventKit API 1 optional;
   all unchanged. Host: `UnitNameUnmodified` added, guarded
   (`type(...) == "function"`), its answer checked with `issecretvalue`
   first; `UnitName` stays as the fallback.
4. Surface: no new method on databases or views. `SettingsKit:GetCharacterKey()`
   → `string|nil`, the `char` key `Open` would use now (an addition so
   BridgeKit computes the same key instead of repeating the rule; the maintainer's
   call, see the report). Behaviour changes, all in CHANGELOG and
   `docs/API.md`: (i) raw saved tables reachable from an open database carry
   a SettingsKit metatable, so `MyAddonDB.profiles.Default.scale` read
   directly answers the default instead of `nil`, as with AceDB; `rawget`,
   `next` and `pairs` are unaffected, nothing on disk changes (the client
   saves no metatables), a table that leaves the tree keeps the harmless
   metatable; (ii) a table assigned through a view gets that metatable;
   (iii) a secret key read raises the client's error (19b); (iv) the `char`
   key row of *The saved table* names `UnitNameUnmodified` with the
   `UnitName` fallback.
5. Ownership: chain metatables, shared per-plan saved metatables and defaults
   live in `state` (weak-keyed where they hang off views), not in file
   locals, so a later revision rebinds them. In-place upgrade from revision
   13: every live view in `state.views` gets its chain; the old shared
   `VIEW_METATABLE` is protected by `__metatable`, which SettingsKit owns, so
   the upgrade clears that field, sets each live proxy's new metatable and
   restores it; databases opened by revision 13 keep their eagerly built
   roots; rebinding then runs once per database. Getters and listeners of
   revision 13 keep working.
6. Performance and memory (host Lua, bench, against AceDB in the same run):

   | Case | Today (rev 13) | Expected | Basis |
   |---|---|---|---|
   | read-default | 29.6x | 3.6x | measured, prototype D |
   | read-saved | 29.8x (33 instructions) | 2.8x (2 instructions, as AceDB) | measured, D |
   | read-nested | 35.9x | 2.1x | measured, D |
   | read-entry-default | 41.6x | 2.3x | measured, D |
   | read-getter | 2.56x (39 ns) | about 1.5x (20 to 25 ns; floor 15.8 ns per call) | estimate from `Floors.lua` |
   | open-empty | 4.87x, 8.3 KB | 2.3x, 2.6 KB (AceDB 3.3 KB) | measured, D (D had lazy layout: add up to 1.5 KB here, estimate) |
   | open-populated | 2.57x, 7.7 KB | 2.8x, 8.4 KB in D; 2.0x or less with per-plan sharing | D measured; sharing an estimate |
   | retained per open DB (AceDB 3 872 B) | 7 192 B | 7 880 B in D; about 5 KB with sharing (400 to 600 B per view) | D measured; sharing an estimate |
   | switch-profile | 0.24x | 0.21x (stays faster than AceDB) | measured, D |
   | write-scalar | 53x (146 instructions) | about 25x (about 70 instructions) | estimate (fix 8) |
   | write-nested | 177x (324 instructions) | 93x (169) measured with the depth read; about 60x with the fused path | C measured; fused an estimate |

   No allocation on a read or a write. Rebinding allocates nothing; building
   a view allocates its metatable (and, without sharing, its defaults and
   saved metatable). "Open below AceDB": in memory yes for a new saved
   variable without reads; in time no (2.3x), the remainder is validation,
   scope keys and plan lookup.
7. Tests: chains for every read kind (default, saved, nested, keyed entry,
   wildcard default, detached view, read-only database, foreign metatable,
   scalar stored where a record is declared, `READ_COPY` before and after its
   copy, read-only `READ_COPY`), rebinding after every mutating method
   (`SetProfile`, `CopyProfile`, `ResetProfile`, `DeleteProfile`,
   `ResetDatabase`, `Compact` including logout, `Resync`, table writes, spec
   switches), a mutation that raises halfway; the nine specs prototype B
   fails, resolved: raw inspections through `rawget` (`Writes_spec.lua:85`,
   `:182`), `Aliasing_spec.lua:44` asserting SettingsKit's marker instead of
   no metatable, the three secret-key read specs rewritten to assert no
   SettingsKit probe and no SettingsKit message (`Aliasing_spec.lua:259`,
   `Writes_spec.lua:331`, `Defaults_spec.lua:122`), `Getter_spec.lua:209`
   (failing first), and the upgrade specs (`Bootstrap_spec.lua:79`,
   `Caching_spec.lua:338`) with an upgrade from revision 13 rebuilding live
   views; lazy roots through `Getter`, `Validate`, `Pairs`, spec profiles
   and `Compact` before any read; `Open_spec.lua:15` unchanged (layout
   stays eager); `Allocation_spec.lua` (nothing on reads and writes, the
   root's cost on its first read); the depth read with and without
   `GetLimit` and after `SetLimits`; the fused write's messages and levels;
   the character key from `UnitNameUnmodified`, the fallback when absent,
   secret or empty; `GetCharacterKey`; getters of revision 13 after the
   upgrade. Client suite (never run): `db.profile[secret]` and `db[secret]`
   raise the client's "cannot be indexed with secret keys" at the reading
   line, before any SettingsKit code; `GetCharacterKey()` equals
   `UnitNameUnmodified("player") .. " - " .. GetRealmName()`.
8. Docs: README (reads cost what AceDB's do; migration table rows for raw
   reads and `UnitNameUnmodified`), `docs/API.md` (*Host facilities* row for
   `issecretvalue` loses reads, *The saved table* `char` row, *Reads*, *Views
   hold their saved tables*, `db:Getter`, *Error behaviour* messages removed,
   *Performance* table, revision 14 under *Embedded copies and upgrades*),
   `docs/INTERNALS.md` (the chain, its rebinding rule, node layout 4, the
   upgrade), CHANGELOG, `tests/README.md`, the client suite's `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.0,
   revision 14, node layout 4, 298 specs (25 new in `ReadThrough_spec.lua`).
   Recorded deviations: record field views are built on their first use too (a
   pending proxy each, which the shadow holds), not with their parent; a
   record view whose plain-table default is not stored yet reads through the
   function path while its saved table exists (a direct read of the saved
   table must never store a copy) and through a tail of its own while nothing
   is saved; a database creates `_signals` with its first profile listener, so
   two scopes keep it to 16 fields. Measured on host Lua 5.1, each against
   AceDB-3.0 in its own run: read-saved 31.7x to 2.8x, read-default 29.3x to
   3.7x, read-nested 34.4x to 1.9x, read-entry-default 40.2x to 1.9x, read-
   getter 2.5x to 1.65x, write-scalar 53x to 35x, write-nested 190x to 102x,
   open-empty 4.7x and 8.3 KB to 3.1x and 3.7 KB (AceDB 3.3 KB), open-
   populated 2.6x to 2.3x, switch-profile 0.24x to 0.19x; an open database
   with one profile read holds 3.0 KB (revision 13: 3.9 KB, AceDB-3.0: 3.4
   KB). The main chunk is down to 195 locals.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## settingsKit AceDB scopes, profile lifecycle signals, missingOk, and the core side of namespaces

**settingsKit AceDB scopes, profile lifecycle signals, `missingOk`, and the core side of namespaces** — a change to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.6.0 (from 0.5.0), implementation revision 15 (from 14), database
   layout 4 and node layout 4 unchanged (no new field on a database or node
   that does not use the new features; see 5).
2. Purpose: close the settingsKit items of the gap report's work package 10
   in the core, and give the Namespaces part (next record) the hooks it needs,
   without touching a read or write path.
   a. **Four declarable scopes with AceDB's keys**: `race`, `factionrealm`,
      `factionrealmregion`, `locale`, in sections of the same names. Keys as
      AceDB computes them (client facts above), so data BridgeKit imports
      from AceDB keeps its keys verbatim. Each key is read **only when the
      schema declares its scope**, once per `Open` (as the existing four are),
      through `callHost`, every answer probed with `issecretvalue` first; a
      database that declares none of them makes no new host call. A scope
      whose key cannot be read is unavailable, with the existing message
      form: `race` needs `UnitRace("player")`; `factionrealm` and
      `factionrealmregion` need `UnitFactionGroup("player")` and
      `GetRealmName()` (the region always resolves, falling back to `"TR"` as
      AceDB does); `locale` needs `GetLocale()`. They are keyed sections like
      `realm` and `class`: views, `OnChange`, `Getter`, `Validate`, `Pairs`,
      `Compact` (an emptied entry is removed) and logout compaction treat
      them alike. The new sections are created by `Open` (writable database)
      only when declared, and their layout check (present but not a table is
      refused) runs only when declared, so saved data that holds an
      unrelated top-level `race` key, which SettingsKit never read, still
      opens.
      **Core, not a part (weighed, 0/16 use):** the four scopes are rows in
      the scope tables plus about 40 lines of key reading (about 1.5 KB held,
      estimate at 35 KB per 1,000 lines). A part would need the core's scope
      lists made extensible from outside (they are walked by `Open`,
      compaction, rebinding and `findRoot`), which costs about as much in the
      core as the rows themselves, plus the part's own header and bootstrap
      (about 1 KB) and an embed line. Not loading them would save almost
      nothing, so they stay in the core and cost nothing at run time unless
      declared.
   b. **Four more profile lifecycle signals**, through the existing lazy
      design (`_signals`, created by the first connection, so `Open`
      allocates nothing more and a database nobody listens to keeps its 16
      hash slots):
      - `db:OnNewProfile(callback)` → `callback(db, name)`, when SettingsKit
        creates the current profile's table: `SetProfile` (spec switches
        included), `ResetDatabase`, and `CopyProfile`/`ResetProfile` when
        the current profile's table was missing. Fires after the operation's
        changes, before its other signals (so a listener that fills the new
        profile runs before `OnProfileChanged` listeners read it, as in
        AceDB).
      - `db:OnProfileShutdown(callback)` → `callback(db, name)`, at the start
        of a `SetProfile` that will switch (not for the current name, not on
        a read-only database), **before anything changes**: `db.profile` is
        still the old profile. A raising listener stops the switch before
        anything changed (the error reaches the caller's line, as every
        SettingsKit signal's does). AceDB passes no name; the name of the
        profile being left is added because the listener otherwise has to
        call `db:GetProfile()`.
      - `db:OnDatabaseShutdown(callback)` → `callback(db)`, at
        `PLAYER_LOGOUT` (with EventKit, as logout compaction), for every
        database on the logout list in the order opened, **before** that
        database is compacted, so a listener's final writes are compacted
        too. Fires for a read-only database as well (which is then not
        compacted). A raising listener is reported through the host error
        handler and never stops another database's shutdown or compaction.
        Without EventKit nothing fires; the docs keep pointing to
        LifecycleKit's `OnShutdown` for that case.
      - `db:OnDatabaseReset(callback)` → `callback(db)`, from
        `ResetDatabase`, first, before its existing `OnProfileReset` and
        `OnProfileChanged` (whose behaviour is unchanged).
      Callbacks are functions, like the four existing `On*` methods; the
      method-name form of decision 0003 is not extended to SettingsKit here
      (0003 names the runtime Kits; adding it to every `On*` method of
      SettingsKit is a separate record if wanted).
   c. **`db:IsNewProfile()`** → whether the current profile's table was
      created during this session (by `Open`, `SetProfile`, a spec switch or
      `ResetDatabase`). Needed because `Open` creates a new character's
      first profile before any `OnNewProfile` listener can connect, and the
      corpus relies on hearing about that profile
      (`Bartender4/Bartender4.lua:49`). Kept in a weak-keyed table in
      `state`, not on the database, so a database keeps its hash size.
   d. **`missingOk`** (gap report 3.6 last row): `db:CopyProfile(from,
      options?)` and `db:DeleteProfile(name, options?)` accept
      `{ missingOk = true }` and then return `false` instead of raising when
      the named profile does not exist; both now return `true` when they
      did their work (they returned nothing). The options table is checked
      like `Open`'s: unknown fields, a secret key or value, and a
      non-boolean `missingOk` are refused at the caller's line. Every other
      refusal (copying the current profile onto itself, deleting the current
      profile, too deep) is unchanged.
   e. **Core side of namespaces** (the part does the rest, next record):
      - `state.parts` (decision 0001, point 4) for part state, created by
        this revision and by the upgrade from 14.
      - A database that has namespaces holds one extra field, `_namespaces`
        (created by the part's first `RegisterNamespace`). The profile
        methods ask `rawget(db, "_namespaces")` once and, only when present,
        call the part's cascade through `state.dispatch`, at three fixed
        points: before the change (refusals and `OnProfileShutdown`), after
        the parent's change and before the parent's post signals (the
        children's changes and signals), and from compaction (manual and
        logout) and `Resync`. A database without namespaces pays one
        `rawget` per profile operation, nothing on reads or writes.
      - A namespace child is a database table with the same private layout
        and the same metatable (so views, `OnChange`, `Getter`, `Validate`,
        `Pairs` work unchanged and at the same speed), marked by `_parent`.
        The core's `SetProfile`, `CopyProfile`, `DeleteProfile`,
        `ResetDatabase`, `SetSpecProfile` and `ApplySpecProfile` refuse a
        child at the caller's line, naming the parent:
        `SettingsKit.Database:SetProfile cannot be called on namespace Bars of MyAddonDB; call it on MyAddonDB's database`.
        `ResetProfile` on a child empties only that namespace's current
        profile (AceDB's child behaviour). `GetProfiles` and
        `GetSpecProfile` on a child answer the parent's. `GetSavedVariable`
        on a child answers the parent's global name; messages name the
        namespace (`SettingsKit (MyAddonDB namespace Bars) db.class is unavailable: ...`).
      - `RegisterNamespace` and `GetNamespace` read on a database while the
        part is not loaded raise at the reading line (decision 0001, point
        5), built only on that miss path of `databaseIndex`:
        `SettingsKit.Database:RegisterNamespace is in SettingsKit's Namespaces part, which is not loaded: add settingsKit\parts\SettingsKit-Namespaces.lua`.
      - `Open` accepts `maxNamespaces` (a positive integer or
        `SettingsKit.UNBOUNDED`, default 256, checked like
        `maxScannedEntries`), stored on the database only when passed, so the
        default costs no field. It is accepted without the part and bounds
        `RegisterNamespace`.
   Non-goals: AceDB's `RegisterDefaults` (the schema is fixed at `Open` by
   design), `GetProfiles(tbl)` reuse, method-name callbacks on SettingsKit's
   `On*` methods (above), WoW Forever's ruleset keys (not a supported
   client), reading scope keys again when the faction changes mid-session (a
   Neutral Pandaren keeps `Neutral` keys until the next `Open`, as AceDB
   keeps them until reload), lazy layout sections for the existing scopes.
3. Dependencies: registry API 2, schemaKit API 1, signalKit API 1, eventKit
   API 1 optional; all unchanged. Host: `UnitRace`, `GetCurrentRegion`,
   `GetCurrentRegionName`, `GetLocale`, read through `callHost` (guarded by
   `type(...) == "function"`), each answer checked with `issecretvalue`
   first; `GetCurrentRegion`'s answer must be a non-secret number to index
   the region table.
4. Surface: `db:OnNewProfile`, `db:OnProfileShutdown`, `db:OnDatabaseShutdown`,
   `db:OnDatabaseReset`, `db:IsNewProfile`; the `options` argument of
   `CopyProfile` and `DeleteProfile` and their `true`/`false` returns; the
   `maxNamespaces` option of `Open`; scopes `race`, `factionrealm`,
   `factionrealmregion`, `locale` (`db.race` and the rest, and the scope
   names accepted by `OnChange`, `Getter`, `Validate`); four sections in *The
   saved table*. Every `On*` returns a SignalKit connection and refuses a
   non-function callback and a non-database receiver at the caller's line.
   Behaviour changes, all in CHANGELOG and `docs/API.md`: `CopyProfile` and
   `DeleteProfile` return a boolean; the `namespaces` row of *The saved
   table* stops being "reserved" (next record).
5. Ownership: signals live in the database's lazily created `_signals` (as
   today); `createdProfiles` (weak-keyed database to a set of names) and
   `parts` in `state`; the cascade entry points in `state.dispatch`, set by
   the part, never overwritten by a core revision. Main-chunk locals: the
   four scope tables (`SCOPE_NAMES`, `SCOPE_SECTIONS`, `SCOPE_SET`,
   `UNAVAILABLE_REASONS`) fold into one `Scopes` table, freeing three locals;
   every new helper lives in a table or a `do` block, so the main chunk ends
   at or below today's 195 (the ratchet only goes down). In-place upgrade
   from revision 14: `state.parts` and `state.createdProfiles` are created;
   databases opened by revision 14 gain the new methods through the shared
   prototype, keep their scopes (the new ones were never declared there) and
   their signals; a database whose current profile revision 14 created reads
   `IsNewProfile() == false` (not recorded then, documented).
6. Performance and memory (host Lua; against AceDB in the same bench run):

   | Case | Today (rev 14) | Expected | Basis |
   |---|---|---|---|
   | read-default, read-saved, read-nested, read-entry-default, read-getter | 3.76x, 2.95x, 1.95x, 1.93x, 1.65x | unchanged (no code added on a read) | by construction; bench re-run in phase 2 |
   | write-scalar, write-nested | 319 ns, 557 ns | unchanged (no code added on a write) | by construction |
   | open-empty, open-populated | 3.03x / 3,691 B, 2.28x / 4,704 B | within noise; bytes unchanged (no new field, no new table unless a new scope is declared) | the scope loop walks 10 rows instead of 6: about 20 to 40 ns, under 1% (estimate) |
   | switch-profile | 590 ns, 0 B (0.19x) | at most 620 ns, 0 B | three more `rawget`s (shutdown signal, namespaces, new-profile record) per switch (estimate) |
   | Open declaring all four new scopes | — | about +4 host calls and four small tables in a new saved variable (about 160 B) | estimate |
   | core held memory | 186.1 KB | about 191 KB (+5 KB: scopes 1.5 KB, signals and `IsNewProfile` 2 KB, `missingOk` 0.5 KB, namespace hooks 1 KB) | estimate at 35 KB per 1,000 lines |

   No allocation on reads, writes or switches. `OnDatabaseShutdown` costs
   one `rawget` per database at logout when nobody listens.
7. Tests: each new scope declared and read, its key from the stubbed host
   (race file name; faction and realm; the region table, then
   `GetCurrentRegionName`, then `"TR"`, with `GetCurrentRegion` absent,
   secret, out of range, and `GetCurrentRegionName` absent, empty, secret;
   `GetLocale():lower()`), unavailable when its host call is absent,
   secret, empty or `nil`, with the message; no host call for an undeclared
   new scope (a counting stub); the new sections created only when
   declared, a present non-table one refused only when declared;
   compaction removing an emptied entry of a new scope; `OnNewProfile` from
   `SetProfile`, a spec switch, `ResetDatabase`, and not from switching to
   an existing profile; `OnProfileShutdown` before the change (the listener
   sees the old `db.profile`), not for the current name, a raising listener
   leaving the profile not switched; `OnDatabaseShutdown` at logout before
   compaction (its write compacted), for a read-only database, a raising
   listener reported and the next database still compacted; `OnDatabaseReset`
   first in `ResetDatabase`; `IsNewProfile` after `Open` of a new character,
   after `Open` of an existing one, after `SetProfile`; `missingOk` for both
   methods, the options refusals at the caller's line (ErrorLevels), the new
   return values; a child refused by each profile method with the message
   naming the parent; the not-loaded message for `RegisterNamespace` and
   `GetNamespace`; `maxNamespaces` option checks; the upgrade from revision
   14 with an open database, its listeners and getters; `Allocation_spec`
   unchanged for reads, writes and switches; main-chunk locals at or below
   195. Client suite (never run): the four keys equal AceDB's rule computed
   in the suite from the client calls; `OnProfileShutdown` and `OnNewProfile`
   order around `SetProfile`.
8. Docs: README (migration table rows for the four scopes, the callbacks,
   `silent`), `docs/API.md` (*Host facilities* rows for the four calls,
   *Public surface*, *The saved table* rows, *Profiles* (`missingOk`,
   returns), *Change signals* (the four signals and their order), *Error
   behaviour*, *Performance*, revision 15 under *Embedded copies and
   upgrades*; also fix the stale "Implementation revision: **13**" line at
   the top, which still reads 13 at revision 14), `docs/INTERNALS.md` (the
   `Scopes` table, lazy key reads, `createdProfiles`, `state.parts`, the
   cascade hook points and their order), CHANGELOG 0.6.0, `tests/README.md`,
   the client suite's `EXPECTED.md`.
9. Status: implemented 2026-11-15, 0.6.0, revision 15, 72 specs (370 in all).
   Deviations: after a cascaded operation, namespace signals fire signal by
   signal across all namespaces, then the parent's; held core memory rose
   about 24 KB (to 211 KB, mostly new messages and constants) against the 5 KB
   estimated, and open-empty is about 8% heavier in instructions; reads,
   writes and profile switches are unchanged. Switching a profile with ten
   namespaces costs 0.25x AceDB's time and allocates nothing (AceDB 1.9 KB); a
   namespace holds 4.0 KB against AceDB's 3.3 KB. The main chunk is down to
   193 locals.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## settingsKit Namespaces part: AceDB namespaces in the saved layout

**settingsKit Namespaces part: AceDB namespaces in the saved layout** — a new part `Namespaces` of facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, part `Namespaces`, file
   `src/parts/SettingsKit-Namespaces.lua`, part revision 1 (`PART_REVISION`),
   needs the core at revision 15 or later (it requires `state.parts` and
   raises `MoltenCodes SettingsKit part Namespaces requires SettingsKit API 1 to be loaded first`
   without it, decision 0001 point 3). Manifest `parts.Namespaces`:
   `{ "description": "db:RegisterNamespace and db:GetNamespace: child databases with their own schema over the saved variable's namespaces section, in AceDB's layout, following the parent's profile.", "revision": 1, "dependencies": {}, "optionalDependencies": {} }`.
2. Purpose: AceDB's most used runtime gap (8/16 addons, 63 registrations,
   145 `GetNamespace` calls) without costing an addon that does not use it.
   a. **`db:RegisterNamespace(name, schema)`** → a child database over
      `MyAddonDB.namespaces[name]`. `name`: a non-secret string of 1 to 64
      bytes with a character other than whitespace. `schema`: what `Open`
      takes (scope names to SchemaKit `table` nodes or sealed schemas, every
      field optional), sealed and compiled the same way and sharing `Open`'s
      plan cache, so namespaces registered with the same schema share one
      plan. Registering a name again with the same schema table returns the
      same child (as `Open` does for a saved variable); a different schema
      raises. Refused at the caller's line: a child receiver (namespaces do
      not nest), more than the database's `maxNamespaces` (default 256),
      `namespaces[name]` or one of its sections present but not a table.
      The child reads the scope keys at registration, as `Open` reads them,
      except `char`, which is the parent's key so both agree.
   b. **The saved layout is AceDB's namespace layout**: inside
      `namespaces[name]`, the sections of the scopes the child declares
      (`profiles`, `global`, `char`, `realm`, `class`, `faction`, `race`,
      `factionrealm`, `factionrealmregion`, `locale`), keyed exactly as the
      parent's sections are; no `profileKeys`, `specProfiles`, `version` or
      nested `namespaces`. A writable parent gets `namespaces[name]`, the
      declared sections and the current profile's table at registration; a
      read-only parent gets none and the child reads what is saved or its
      defaults. This replaces the `namespaces` row's "Reserved: SettingsKit
      writes nothing here" (the row was reserved for exactly this; the
      contract allows filling a reserved section additively). BridgeKit can
      then import AceDB namespaces verbatim (see the report).
   c. **`db:GetNamespace(name, options?)`** → the registered child; a name
      nobody registered raises at the caller's line
      (`SettingsKit.Database:GetNamespace name names no registered namespace`)
      unless `options` is `{ missingOk = true }`, which answers `nil`
      (AceDB's `silent`, in the `missingOk` form of the previous record).
   d. **The child** is a database (previous record, 2e): views and their
      read-through chains, `OnChange`, `Getter`, `Validate`, `Pairs`,
      `Compact` (this namespace only), `Resync` (re-resolves its saved table
      from the parent), `IsReadOnly` (the parent's), `GetProfile`,
      `GetProfiles`, `IsNewProfile`, `ResetProfile` (this namespace's current
      profile only), and the eight profile signals of its own. The profile
      mutators of the parent are refused on it, naming the parent.
   e. **Cascading profile operations.** Every refusal is decided before
      anything changes, the namespaces' copy depth included, so an operation
      either changes the parent and every child or nothing. Then, for the
      parent's `SetProfile`, `CopyProfile`, `ResetProfile`, `DeleteProfile`
      and `ResetDatabase`:
      - signals that announce a change (`OnProfileShutdown`) fire on the
        parent, then on each child in registration order, before anything
        changes;
      - the parent changes, then every child changes (no user code runs in
        between): `SetProfile` points each child at the profile (creating
        its table when the child declares `profile`); `CopyProfile` copies
        each child's `profiles[from]` (an absent one empties the child's
        current profile, as AceDB does); `ResetProfile` empties each child's
        current profile; `DeleteProfile` removes each child's
        `profiles[name]` and detaches its views of it; `ResetDatabase`
        recreates each registered namespace's table and declared sections
        in the wiped saved variable, re-points each child at it, detaches
        every child profile view and republishes `child.profile`;
      - the namespaces nobody registered this session (`namespaces[x]`
        tables with a `profiles` table) get the raw part of the operation
        AceDB gives them: copy (bounded by SchemaKit's `maxDepth`), reset
        (removes `profiles[current]`) and delete (removes `profiles[name]`);
        `SetProfile` and `ResetDatabase` need nothing for them;
      - signals that report a change fire on each child, in registration
        order, then on the parent, each with its usual arguments
        (`OnNewProfile` first when that child's table was created). A
        listener that raises stops the remaining signals and reaches the
        caller's line with every change already made, as for any SettingsKit
        signal.
      Spec switches go through `SetProfile` and cascade with it.
   f. **Compaction**: the parent's `Compact` also compacts every registered
      child and returns the total. At logout, after the parent's
      `OnDatabaseShutdown`, each child's `OnDatabaseShutdown` fires (in
      registration order), then the parent and its children are compacted,
      then, AceDB's logout cleanup inside `namespaces` only: empty profiles
      and empty sections of every namespace table and then empty namespace
      tables are removed. The parent's own layout stays eager, as `Open`
      promises.
   Non-goals: nested namespaces, per-namespace `version`/`migrations` (the
   parent's migrations receive the whole saved table, `namespaces`
   included), `GetNamespaces`/iteration of registered children, OptionsKit
   `bind` to a namespace (`"ns:<name>.profile.key"`, work package 6's
   optionsKit item: optionsKit's owner records it), an AddonKit form
   building a namespace from plain defaults (addonKit's owner), BridgeKit's
   import (bridgeKit's owner; text in the report).
3. Dependencies: the SettingsKit core (API 1, revision 15 or later), found
   through the Registry at file scope; nothing else. No host API of its own.
4. Surface: `db:RegisterNamespace(name, schema)`, `db:GetNamespace(name,
   options?)`, installed on the shared `Database` prototype, so databases
   opened before the part loaded (or by an older core revision upgraded in
   place) have them; the `namespaces` section's documented layout.
5. Ownership: part state in `state.parts.Namespaces` (`revision`); the
   cascade, compaction and resync entry points in `state.dispatch`, called by
   the core only for a database holding `_namespaces`; a parent's children
   in its `_namespaces` (`order`, an array in registration order, and
   `byName`). Children are built by the active part revision through the
   shared prototype and metatable, so a later core revision (in-place
   upgrade) cascades to children registered before it, and a later part
   revision takes over the dispatch entries for every existing parent
   (the gap report's risk 6). The highest part revision wins: an equal or
   older copy loaded later returns at once.
6. Performance and memory (host Lua):

   | Case | AceDB (measured) | Expected SettingsKit | Basis |
   |---|---|---|---|
   | register a namespace with one small profile default and read it | 2,696 ns, 3,294 B held | about 3,500 to 4,500 ns (1.3x to 1.7x), at most 3,300 B held | estimate: a whole `Open` of the same schema measures 6,900 ns and 4,472 B, and a child skips the global, seven of nine layout sections, the migration check, the profile-key lookup and the logout list |
   | `SetProfile` with 10 namespaces | 10,524 ns, 2,044 B allocated | about 4,000 to 6,000 ns (0.4x to 0.6x), 0 B | estimate: one database's switch measures 780 ns; a child's share skips validation and `profileKeys` |
   | reads and writes through a child's views | as the parent's | as the parent's | same code, same chains |
   | a database without namespaces | — | one `rawget` per profile operation | by construction |
   | part held memory | — | about 16 to 18 KB, only in addons that embed it | estimate: about 450 lines at 35 to 40 KB per 1,000 |

   Proposed bench cases (shared tooling, see the report):
   `register-namespace` and `switch-profile-namespaces` (10 children), both
   with an AceDB side.
7. Tests (`Namespaces_spec.lua` and additions to `Bootstrap_spec`,
   `Manifest_spec`, `ErrorLevels_spec`, `Allocation_spec`, `Compact_spec`,
   `SpecProfiles_spec`): registration and its refusals at the caller's line
   (name, schema, nesting, bound, `UNBOUNDED`, a non-table namespace or
   section, same schema returns the child, a different one raises); the
   saved layout created (and nothing on a read-only parent);
   `GetNamespace` with and without `missingOk`; child views read and write
   with validation and `OnChange`; every profile method refused on a child
   naming the parent, `ResetProfile` on a child; each cascading operation on
   registered and unregistered namespaces, its signal order (shutdown parent
   first; reports children first), a refusal leaving parent and children
   unchanged, a raising child listener leaving every change made; spec
   switches cascading; `ResetDatabase` re-pointing children and detaching
   their profile views; parent `Compact` including children; logout:
   shutdown order, compaction, removal of empty profiles, sections and
   namespaces; the part loaded before and after a database is opened; the
   part not loaded (the core's message); the part loaded twice (same and
   older revision); a later core revision upgraded in place over a parent
   with children still cascading; `Allocation_spec`: no allocation reading
   or writing through a child, no allocation in a cascaded switch between
   existing profiles. Client suite (never run): a namespace survives
   `/reload` in the documented layout; `PLAYER_LOGOUT` removes an empty
   namespace.
8. Docs: README (namespaces, the AceDB migration rows `RegisterNamespace`,
   `GetNamespace`), `docs/API.md` (*Loading* with the part's file, *Public
   surface*, a *Namespaces* section, *The saved table* `namespaces` row and
   the namespace layout, *Error behaviour*, *Performance*), `docs/INTERNALS.md`
   (the child's fields, the cascade phases, the dispatch entries, the
   upgrade rules), CHANGELOG (in the 0.6.0 entry), `tests/README.md`, the
   client suite's `EXPECTED.md` and `.toc` (the part's file).
9. Status: implemented 2026-11-15, part revision 1, 33.9 KB held only by
   addons that embed it.

**settingsKit Defaults part: plain AceDB-style defaults without SchemaKit** — a change to facade `SettingsKit` and a new part `Defaults`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1 (additive),
   version 0.7.0 (from 0.6.0), implementation revision 16 (from 15), plan
   layout 3 (record 3). New part `Defaults`, file
   `src/parts/SettingsKit-Defaults.lua`, part revision 1, needs the core at
   revision 16 or later. Manifest `parts.Defaults`:
   `{ "description": "SettingsKit:Open and db:RegisterNamespace from plain AceDB-style defaults: the write rules inferred from each default, checked without SchemaKit.", "revision": 1, "dependencies": {}, "optionalDependencies": { "schemaKit": { "api": 1 } } }`.
   The core's `schemaKit` dependency moves from `dependencies` to
   `optionalDependencies`.
2. Purpose: a database opened from plain defaults validates its writes
   without SchemaKit being loaded, and costs no schema nodes. Today such a
   database is MC:Database's job: AddonKit's Database part infers a SchemaKit
   schema (two nodes per field, about 0.8 KB per field) and the session needs
   SchemaKit (82.7 KB) although the inferred schema uses only a handful of
   rules, every one of which SettingsKit's write fast path already
   reproduces for scalars (`passesFastCheck`).
   a. **Plain scopes.** A scope value of `Open`'s second argument that is a
      plain table (no SchemaKit metatable tag) is a defaults table. Its rules
      are exactly AddonKit's inference rules today, so a database opened
      either way accepts and refuses the same writes:
      `true`/`1`/`"text"` an optional boolean, number (not integer) or string
      of at most `max(4096, #default)` characters; `{ a = ..., b = ... }` a
      closed record of those fields; `{}` a free-form bag with string keys of
      at most 256 characters or number keys, at most 1024 entries, values
      unchecked (the secret scan and `maxScannedEntries` still apply);
      `{ ["*"] = d }` a keyed section of at most 1024 entries whose keys are
      as the bag's and whose entries read `d`; `{ 1, 2, 3 }` an array of one
      primitive type of at most `max(1024, #default)` elements. Refused at
      the caller's line, with the same reasons AddonKit gives today:
      `["**"]`, `["*"]` beside named keys, a non-string record key, a mixed
      or table-valued list, a non-table scope, nesting deeper than 16
      tables, a value that is not a boolean, number, string or table.
      The scope names are SettingsKit's, all ten.
   b. **SchemaKit leaves.** A SchemaKit node or sealed schema inside a
      defaults table (AddonKit's `MC.Range`, `MC.Enum`, or an author's own
      node) is kept as written: the part seals it, splices its
      `Describe()` output into the scope's description, and the checker
      hands that subtree to the sealed leaf's `Check`, prefixing the path.
      Only such a leaf needs SchemaKit, and it cannot exist without it. A
      leaf that is not optional is made optional, as AddonKit does now.
   c. **One checker, plain tables in, the same failure out.** The part builds
      the description `schema:Describe()` would return for the inferred
      schema, so `compilePlan` compiles it unchanged, and a small checker
      object takes the sealed schema's place in `scope.schema`: its
      `Check(value)` answers `true` or `false, failure` with SchemaKit's
      failure shape (`path`, `rule`, `expected`, `found`) and SchemaKit's
      wording for each rule it implements, so write refusals, `Validate`
      and their messages read the same as with an inferred SchemaKit schema.
      The core calls `scope.schema:Check(probe)` as now and never asks which
      kind it holds.
   d. **Without the part**, `Open` (and `RegisterNamespace`) given a plain
      defaults scope raises at the caller's line:
      `SettingsKit:Open plain defaults are in SettingsKit's Defaults part, which is not loaded: add settingsKit\parts\SettingsKit-Defaults.lua`.
      A SchemaKit scope never needs the part.
   e. `SettingsKit:HasPart(name)` → `true` when part `name` is loaded (as
      EventKit, SchedulerKit, CodecKit and CommKit answer), so AddonKit and
      OptionsKit can ask without raising.
   **Core or part (weighed).** In the core the plain path costs every schema
   user about 18 KB they never run; as a part it costs plain-defaults users
   one embed line, which the builder and `tooling.package.embeds` write from
   the manifest. A database needs exactly one source of rules: SchemaKit
   for schemas, this part for plain defaults, each embedded by those who use
   it. The part is the smaller total for every kind of user, so it is a part.
   If the owner prefers `Open` to accept plain defaults with nothing added to
   the embed list, the same code goes in the core instead (core about
   192 KB, no Defaults part), and nothing else in this record changes.
   Non-goals: AceDB's `["**"]` (no SettingsKit form, refused as today),
   `RegisterDefaults` (schemas are fixed at `Open` by design), inferring
   integer numbers or enums from values (a range or choice is written as a
   leaf), native range and enum leaves that avoid SchemaKit (a later record
   if wanted; `MC.Range` and `MC.Enum` keep returning SchemaKit nodes).
3. Dependencies: core: registry API 2, signalKit API 1; schemaKit API 1 and
   eventKit API 1 optional. SchemaKit is resolved at `Open` through
   `Registry:Find` when a scope (or leaf) is a SchemaKit schema, not at file
   scope, so the file loads without it. The depth limit reads
   `SchemaKit:GetLimit("maxDepth")` when SchemaKit is present and
   SettingsKit's own 16 (SchemaKit's default) when it is not. Part: the core
   at revision 16; schemaKit API 1 optional (leaves). No host API.
4. Surface: `SettingsKit:Open(savedVariable, schemaOrDefaults, options)` and
   `db:RegisterNamespace(name, schemaOrDefaults)` accept plain defaults per
   scope (a table that `Open` refused until now: additive);
   `SettingsKit:HasPart(name)`. Behaviour changes, in CHANGELOG and
   `docs/API.md`: SettingsKit loads without SchemaKit; the refusal "must be a
   SchemaKit schema node or sealed schema" becomes, for a plain table, the
   not-loaded message (part absent) or a defaults refusal (part present).
   Embedding: a database-only addon with plain defaults embeds Registry,
   SignalKit, SettingsKit and `SettingsKit-Defaults.lua`; one with SchemaKit
   schemas embeds SchemaKit as before.
5. Ownership: the part keeps its state in `state.parts.Defaults` with its
   `PART_REVISION`, and installs its compiler entry in `state.dispatch`
   (`compileDefaults`), never overwritten by a core revision; the core's
   default entry raises the not-loaded message. Compiled defaults are cached
   per defaults table (weak-keyed), as `compiledScopes` caches schemas, so
   namespaces and databases opened with the same table share one plan. In-place
   upgrade from revision 15: no saved data changes; databases revision 15
   opened keep their sealed schemas and plans; `compiledScopes` is per copy,
   so revision 16 compiles its own; nothing about SchemaKit's presence is
   stored. A revision 15 copy loaded after revision 16 yields as usual and
   never sees the part.
6. Performance and memory (host Lua; AceDB in the same run):

   | Case | Today | Expected | Basis |
   |---|---|---|---|
   | Database-only set, plain defaults | 395.2 KB (SchemaKit loaded) | about 315 KB | measured parts; Defaults part estimated from AddonKit's inference (9.4 KB prototypes) plus a checker the size of SchemaKit's `checkTable`, `checkMap`, `checkArray` (4.5 KB) and failure text, times 1.29 |
   | Bench-shaped defaults, schema plus first Open | 55,046 B | about 27 KB (AceDB 5,584 B) | measured: nodes 20,426 B gone, sparse Open 26,940 B; minus two seals (about 1.6 KB) |
   | read-*, write-scalar | unchanged | unchanged | reads never touch the rules; scalar writes take the same fast checks |
   | write of a table | SchemaKit `Check` of the probe chain | the part's checker over the same chain | estimate: no slower (fewer rules per node) |
   | open-empty, open-populated | as revision 15 | within noise | the description is built once per defaults table |

   No allocation on reads or writes; a refused write allocates its failure
   once per checker, as SchemaKit's reused failure table does.
7. Tests: a differential spec: for a corpus of defaults tables (every rule
   above, nested records, bags, keyed sections, arrays, leaves), open one
   database through the part and one through a SchemaKit schema inferred by
   the same rules, write the same accepted and refused values, compare
   results and messages exactly; each refusal of 2a at the caller's line
   (ErrorLevels); leaves: `MC.Range`-style node accepted and refused with the
   leaf's own message and the prefixed path; the not-loaded message without
   the part; loading SettingsKit without SchemaKit (KitConformance's
   dependency group: only registry and signalKit are required); a SchemaKit
   scope with the part absent; `RegisterNamespace` with defaults (Namespaces
   part unchanged); the plan cache shared per defaults table; `Validate`,
   `Pairs`, `Getter`, `Compact` on a plain database; `HasPart`; upgrade from
   revision 15 with an open schema database, a write after the upgrade;
   `Allocation_spec` for plain databases. Client suite (never run): a plain
   database opened in `OnInitialize` without SchemaKit embedded.
8. Docs: README (plain defaults first, the AceDB migration table row for
   `AceDB:New(name, defaults)`), `docs/API.md` (*Opening a database* both
   forms, the rule table of 2a, *Embedding* lists, *Error behaviour*,
   `HasPart`, revision 16 under *Embedded copies and upgrades*),
   `docs/INTERNALS.md` (description built from defaults, the checker object,
   `state.dispatch.compileDefaults`), CHANGELOG 0.7.0, `tests/README.md`,
   client suite `EXPECTED.md`. Outside the package, the maintainer's:
   EMBEDDING.md database-only row (no SchemaKit), MIGRATING_FROM_ACE3.md
   AceDB rows, and AddonKit's Database part (report).
9. Status: implemented 2026-11-18, 0.7.0, revision 16, 420 specs (with
   records 2 and 3). Measured on host Lua 5.1.5 (64-bit, debug information
   kept, resident after a full collection): Registry, SignalKit, SettingsKit
   and the Defaults part without SchemaKit hold 320.8 KB, the same set with
   SchemaKit instead of the part 388.4 KB (this harness; the record's 395.2 KB
   was measured with another); the Defaults part 20.9 KB; the bench-shaped
   defaults plus the first `Open` 27,047 B (the schema form: 49,881 B at
   revision 15, 40,121 B at revision 16). Choices left open, taken
   conservatively: any table without SchemaKit's metatable tag is plain
   defaults (as AddonKit treats it); a scope that is not a table keeps the
   existing refusal ("must be a SchemaKit schema node or sealed schema")
   rather than a new defaults message; the refusals read
   `<label> defaults <path> <AddonKit's reason>`, the array hint naming
   `SchemaKit.array{ of = ... }`; a SchemaKit leaf is checked by its own
   sealed `Check` from depth 1, so a table-valued leaf nested near
   `maxDepth` is held to the leaf's own depth; the checker builds paths with
   SettingsKit's `pathKeyLimit`, SchemaKit's when equal (both 32 by
   default). Not done: the client suite case (a plain database opened in
   `OnInitialize` without SchemaKit) is not written; the client bundle always
   carries SchemaKit, so it could not show "without". Outside this package
   (reported): AddonKit's Database part can pass its defaults to `Open` and
   name `["Defaults"]`.

---

**settingsKit SpecProfiles part: spec profiles out of the core** — a new part `SpecProfiles` of facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, part `SpecProfiles`, file
   `src/parts/SettingsKit-SpecProfiles.lua`, part revision 1, needs the core
   at revision 16 or later (raises
   `MoltenCodes SettingsKit part SpecProfiles requires SettingsKit API 1 to be loaded first`
   without it). Core 0.7.0, revision 16 (with records 1 and 3). Manifest
   `parts.SpecProfiles`:
   `{ "description": "Profiles assigned per specialization or talent group: SettingsKit:GetSpecIndex, db:SetSpecProfile, db:GetSpecProfile and db:ApplySpecProfile, switched by itself on spec changes while EventKit is embedded.", "revision": 1, "dependencies": {}, "optionalDependencies": { "eventKit": { "api": 1 } } }`.
2. Purpose: LibDualSpec's job is a separate library in Ace3; here it is
   12.5 KB of live prototypes (about 16 KB resident) in every SettingsKit
   core, used only by addons that assign profiles per spec. The body of
   `installSpecProfiles` moves to the part as it is: the client reading
   (`GetSpecIndex`), assignments, the shared listener, `Open`'s immediate
   apply. The core keeps what keeps the saved table consistent without the
   part: the `specProfiles` section in the layout (created and checked as
   today), `ResetDatabase` emptying it, and `DeleteProfile` removing
   assignments that name the deleted profile (moved into the core, about
   0.6 KB), so data stays right in a session that does not load the part.
   Non-goals: any change of behaviour of spec profiles themselves.
3. Dependencies: part: the core; eventKit API 1 optional (found through
   `Registry:Find`, as today). Host API unchanged and only in the part:
   `C_SpecializationInfo` (`GetSpecialization`, `GetActiveSpecGroup`,
   `IsInitialized`, `GetNumSpecializationsForClassID`), `UnitClass`,
   `GetNumTalentGroups`, `WOW_PROJECT_ID`, as the revision 11 record cites;
   every guard and secret probe moves with them (the flavour gate then runs
   on the part file).
4. Surface: unchanged when the part is loaded. Without it the facade and the
   database prototype stay complete (an older copy's surface check runs on
   the newer facade when it yields, `Registry.lua:840-847`), with stubs that
   raise at the caller's line:
   `SettingsKit:GetSpecIndex is in SettingsKit's SpecProfiles part, which is not loaded: add settingsKit\parts\SettingsKit-SpecProfiles.lua`,
   and the existing `databaseIndex` form for `SetSpecProfile`,
   `GetSpecProfile`, `ApplySpecProfile` (added to `PART_METHODS`).
   `SettingsKit:HasPart("SpecProfiles")` (record 1) answers without raising.
   Embedding: OptionsKit's `Profiles` part shows spec selects whenever
   `GetSpecIndex` exists, so its manifest must name this part as a
   dependency (`"settingsKit": { "api": 1, "parts": ["SpecProfiles"] }`
   in its `optionalDependencies`) and test `HasPart`; both are the OptionsKit
   owner's change (report).
5. Ownership: part state in `state.parts.SpecProfiles` with its
   `PART_REVISION`; `state.specListenerConnected` and the dispatch entries
   `onSpecEvent`, `onDatabaseOpened` stay where they are, so the listener
   connected by any revision calls the newest entry. The core installs
   no-op defaults for `onSpecEvent` and `onDatabaseOpened` and its own
   `forgetSpecProfiles`, and never overwrites an entry the part installed.
   In-place upgrade from revision 15 with the part absent: revision 15's
   spec members (`GetSpecIndex`, `SetSpecProfile`, `GetSpecProfile`,
   `ApplySpecProfile`) and its `onSpecEvent` and `onDatabaseOpened` entries
   are kept instead of the stubs, as WidgetKit revision 14 kept a
   single-file copy's members; they read only saved tables and database
   fields and switch through `rawget(Database, "SetProfile")`, so they run
   against revision 16 objects (proved with a byte copy of revision 15 as
   fixture). The part replaces them when it loads. Known limit, documented
   as WidgetKit's: revision 16 loaded first and a revision 15 copy after it,
   the older copy yields and that addon's spec calls raise the not-loaded
   message until some addon embeds the part.
6. Performance and memory:

   | Case | Today | Expected | Basis |
   |---|---|---|---|
   | core | 189.8 KB | about -15 KB | measured 12.5 KB prototypes x 1.29, less about 1.5 KB of stubs and `forgetSpecProfiles` |
   | part | | about 17 KB | the same prototypes plus about 1 KB part state and residue (the Namespaces part's root table is 704 B, measured) |
   | spec switch, reads, writes | unchanged | unchanged | same code, same dispatch |

7. Tests: the 37 spec-profile specs (`SpecProfiles_spec.lua`) run with the part loaded; without it,
   each stub raises at the caller's line with its message (ErrorLevels);
   `DeleteProfile` and `ResetDatabase` keep the section right without the
   part; `Open` does not apply assignments without it and does once it is
   loaded at the next `Open`; `HasPart`; part manifest and `PART_REVISION`;
   load without the core raises; upgrade from revision 15 (byte-copy
   fixture) with the part absent keeps switching on a spec event, then the
   part loading takes over; revision 16 first, revision 15 after, the
   documented limit; flavour gate on the part. Client suite: the existing
   `specProfiles` suite gains the part in its `.toc` (never run).
8. Docs: README (parts list, LibDualSpec migration table names the part),
   `docs/API.md` (*Spec profiles* says which file, *Embedded copies and
   upgrades*), `docs/INTERNALS.md` (the part, the kept members),
   CHANGELOG 0.7.0, `tests/README.md`, client suite. Outside: EMBEDDING.md
   and MIGRATING_FROM_ACE3.md LibDualSpec rows (the maintainer's),
   OptionsKit-Profiles manifest and `HasPart` test (its owner's).
9. Status: implemented 2026-11-18, 0.7.0, revision 16, 420 specs (with
   records 1 and 3). Measured: the part 15,333 B resident. The part decides
   unit events with `EventKit:HasPart("Units")`, and for an EventKit before
   revision 23 (unit events in its core, `HasPart` not knowing `"Units"`)
   with the `ConnectUnit` member, so it is right before and after the
   EventKit Units split; the manifest's optional `eventKit` contract does not
   yet name `"parts": ["Units"]` because this branch's EventKit has no such
   part (validation would refuse it): the integrator adds it with EventKit's
   change (done at integration, 2026-11-18). Only revision 15 (proved with its byte copy) has its members kept
   on an upgrade; revisions 11 to 14 get the stubs. The core keeps setting
   `state.specListenerConnected` and the revision 10 catch-up flag
   (`specProfilesCatchUp`), which the part consumes. Outside (reported):
   OptionsKit-Profiles names the part and asks `HasPart` (done by the
   optionsKit owner in this branch).

---

**settingsKit core trims: sparse plans, SchemaKit fallbacks, option rules, shared helper blocks** — a change to facade `SettingsKit`

1. Package `settingsKit`, facade `SettingsKit`, API generation 1, version
   0.7.0, implementation revision 16 (with records 1 and 2), plan layout 3
   (from 2). Database layout 4 and node layout 4 unchanged.
2. Purpose: what stays in the core costs less, per file and per database.
   a. **Sparse plans** (measured prototype). `compilePlan` sets `layout`,
      `proxied`, `default` and `defaultKind`, and only the fields a record or
      keyed section uses (`fieldNames`, `fields`, `ownDefaults`, `ownKinds`,
      `fastChecks`, `values`, `max`, `keyKind`); `compileFastCheck` sets only
      the bounds a field declares; `passesFastCheck` and the two other
      readers test those fields for truth, which reads layout 2 plans and
      layout 3 plans alike.
   b. **SchemaKit fallbacks.** The depth probes for a SchemaKit older than
      revision 6 (`depthProbes`, `ensureDepthProbe` and their branch of
      `depthAllows`) go: without `GetLimit` the fast path answers "not
      known" and the write takes the full check, where SchemaKit enforces
      its own depth. `readMaxDepth` keeps one fallback, SettingsKit's own 16,
      for a database with no SchemaKit (record 1).
   c. **Option rules.** `readOptions`, `readMaxScannedEntries`,
      `readAllowNewerData`, `DatabaseHelpers.readMaxNamespaces` and
      `readMissingOk` (6.7 KB) become one rule table (`OPTION_RULES`: kind,
      bounds, `UNBOUNDED` allowed or not, what it requires) read by one
      function, with every message and error level unchanged (pinned by the
      existing ErrorLevels and Open specs). Taken only if the phase 2
      prototype measures at least 2 KB saved.
   d. **Shared helper blocks** for every copy `tooling.shared.sync --list`
      names: `isSecret`, `reportError`, `validateFacade`, `describeKey`
      (required by `limits`) and `limits` (`LIMIT_RULES` replaces
      `LIMIT_NAMES`, `LIMIT_MINIMUMS`, `LIMIT_CEILINGS`, `UNBOUNDED_REFUSALS`;
      both limits refuse `UNBOUNDED` with today's reasons). `readIsSecret`
      stays for the hot paths that pass a probe along.
   **Weighed and kept in the core** (moving them would cost more than it
   saves or break an older embedder):
   - *Migrations* (about 6.3 KB prototypes, 8 KB resident). An addon that
     embeds revision 15 and calls `Open` with `migrations` must keep
     opening when another addon's revision 16 core without the part takes
     over: the migration runner is internal to `Open`, so unlike a member it
     cannot be kept from the older copy, and that addon's `Open` would raise.
     Versioned migrations are one of the Kit's stated purposes.
   - *`Getter` and `Validate`* (about 6.2 KB prototypes). `Validate` is called
     by OptionsKit's core for every bound option, so most option-using
     addons would load the part anyway; an older copy's `Validate` kept as a
     member would read layout 3 plans with `== false` tests and fail; a part
     costs about 1 KB of its own and an embed line for a saving of about
     7 KB to database-only addons. `Getter` alone (2 KB) is below a part's
     worth.
   - *The generation scheme* under the chains (about 3.2 KB): writes resolve
     their saved table through it. Replacing it with the chains' binding is
     possible but unmeasured; not in this record.
   Non-goals: shortening messages (6.9 KB in all, pinned by specs), an
   unvalidated database mode (see the diagnosis), rebuilding plans of
   databases opened before an upgrade (they keep layout 2 until reload).
3. Dependencies: as record 1. `GetLimit` is still read when present.
4. Surface: no new method. Behaviour changes, in CHANGELOG and
   `docs/API.md`: `SetLimits` refusal messages take the shared wording
   (`SettingsKit:SetLimits limits.x must be an integer from 64 to 1024`,
   `... is not a recognised limit; it accepts maxProfileNameLength, pathKeyLimit`);
   `validateFacade`'s message gains the `; use SettingsKit:Open(...)` hint; a
   host error handler that raises while a logout compaction failure is
   reported now falls back to `print` instead of propagating.
5. Ownership: unchanged. In-place upgrade from revision 15: plans compiled
   by revision 15 (layout 2, `false` fields) stay on their databases and are
   read by the truthiness tests; new plans are layout 3; `depthProbes` built
   by revision 15 are dropped with their file-local table; limits in
   `state.limits` keep their values.
6. Performance and memory:

   | Case | Today | Expected | Basis |
   |---|---|---|---|
   | bench schema, first Open | 34,620 B | 26,940 B (-22%) | measured, prototype, 370/370 specs |
   | plans / fast checks of the bench schema | 13,376 / 4,992 B | 5,696 / 2,032 B | measured, prototype |
   | depth-probe fallback | about 1.3 KB prototypes | 0 | measured function sizes |
   | option readers | 6.7 KB prototypes | about 3.5 KB | estimate, prototype first (2c) |
   | shared helper blocks | | about +3.8 KB resident | measured canonical bodies |
   | core with records 1 to 3 | 189.8 KB | about 174 KB | sum of the rows above and record 2, plus about 1.5 KB part interface for two new parts |
   | write-scalar, read-* | unchanged | unchanged, or faster by one table slot test | sparse fast checks test absent fields as fast as `false` |

   Main-chunk locals stay at or below 193 (the ratchet); the four limit
   tables fold into `LIMIT_RULES`.
7. Tests: the 370 specs pass on layout 3 plans (the prototype already does);
   plan sizes (a scalar field plan at most 4 hash slots, a fast check at most
   4); a database opened by revision 15 then written and compacted after the
   upgrade (layout 2 plans read by revision 16, byte-copy fixture);
   writes deeper than SchemaKit's `maxDepth` refused with and without
   `GetLimit`; option refusals unchanged at the caller's line; the shared
   blocks (`--check`); `SetLimits` messages; reportError with a raising
   handler; KitConformance opt-in (`tests/Conformance_spec.lua`: manifest,
   limits `maxProfileNameLength` 64..1024 and `pathKeyLimit` 32 in 1..1024,
   receivers, the `Open` and `SetProfile` arguments ADR 0002 names, upgrade
   seeding an open database).
8. Docs: `docs/API.md` (*Limits* messages, *Performance* table, revision 16),
   `docs/INTERNALS.md` (plan layout 3, the depth rule, `OPTION_RULES`, the
   shared blocks), CHANGELOG 0.7.0, `tests/README.md`; the API.md section
   skeleton of `docs/CONTRIBUTING.md`.
9. Status: implemented 2026-11-18, 0.7.0, revision 16, 420 specs (with
   records 1 and 2). Measured (SchemaKit loaded): core 192,145 B → 185,076 B
   for all three records, against the 174 KB estimated; the shared blocks
   and the part interface (stubs, `HasPart`, kept members, helpers) cost
   more than budgeted. 2c (`OPTION_RULES`) not taken: with the four option
   readers stubbed out completely the core measured 3,058 B smaller, so a
   rule table and its reader could not save the required 2 KB. Main-chunk
   locals stay at 193 (the SchemaKit lookup moved into a block). The limits
   block's messages are the shared ones; a secret limit key is now named
   `limits.<secret>` in the unknown-name refusal (the key cannot exist on a
   client). `Open`'s `savedVariable` and profile names are asked about
   secrecy before their type, so KitConformance's secret arguments (tables
   in the host) are refused as secret; a client secret is a string, so no
   client sees a difference. KitConformance's dependency group runs with a
   protected `NewPackageWithout`, since SignalKit itself needs Registry.

---

**Report items for the maintainer (outside settingsKit)**

- AddonKit Database part (its owner): with record 1, `MC:Database` can pass
  its defaults straight to `SettingsKit:Open` and drop its Inference section
  (9.4 KB of live prototypes, 15.5 KB for the whole part); its manifest then
  names `"settingsKit": { "api": 1, "parts": ["Defaults"] }` and keeps
  `schemaKit` optional for `MC.Range` and `MC.Enum`. Side finding: its
  `SCOPE_NAMES` lists six scopes, so `MC:Database` refuses `race`,
  `factionrealm`, `factionrealmregion` and `locale`, which SettingsKit
  accepts since revision 15.
- OptionsKit-Profiles (its owner): name the SpecProfiles part in its
  dependency contract and test `SettingsKit:HasPart("SpecProfiles")`
  (record 2, point 4).
- BridgeKit: unaffected (migrations stay in the core); it may compute the
  character key through `GetCharacterKey` as today.
- `tooling/shared/lua/limits.lua`: the canonical block is about 4.4 KB of
  live prototypes against 1.9 KB hand-written here and 1.8 KB in SchemaKit;
  converting every Kit to it adds about 2.5 KB to each. Shrinking the source
  (for example one loop instead of `applyLimitUpdate` plus `copyLimits`) is
  the maintainer's call.
- EMBEDDING.md footprint tables and the database-only row change with
  record 1 (no SchemaKit); exact text in phase 2 after measuring.
