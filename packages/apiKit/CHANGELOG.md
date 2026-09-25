# Changelog

## 0.1.4 — 2026-09-25

- Fixed: a function the client's documentation tables place outside its system's namespace with its own `Namespace` attribute was bound through the system's namespace, a host member that does not exist, so its wrapper was silently absent. Found on Retail 12.1.0 b69933: `api.restrictedActions.inCombatLockdown` was `nil` because the Retail file read `C_RestrictedActions.InCombatLockdown`, while the tables mark `InCombatLockdown` with `Namespace = ""`, a global. `tooling/api/normalize.py` now takes the function's own `Namespace` over its system's for the binding (empty string: a global; another name: that table), and `tooling/api/validate.py` refuses a binding that disagrees with the attribute. Wrapper names do not move (`docs/NAMING.md`, rule 3).
- Regenerated the five flavours from their unchanged pinned captures (the same mirror commits, versions and builds; `provenance.json` and `history.json` are unchanged, and no change report is written, because no build changed). Only these bindings changed, 28 in all:
  - Retail (`09b9db79`, 12.1.0 b69933), Classic Era (`33e177d9`, 1.15.9 b69722) and Mists of Pandaria Classic (`cde55d00`, 5.5.4 b69934), seven each: `restrictedActions.inCombatLockdown` → `InCombatLockdown`; `localization.getDefaultAbbreviationBreakpoints` → `C_StringUtil.GetDefaultAbbreviationBreakpoints`; `stringUtil.trim` → `string.trim`; `tableUtil.count`, `tableUtil.create`, `tableUtil.freeze`, `tableUtil.isfrozen` → `table.count`, `table.create`, `table.freeze`, `table.isfrozen`.
  - Public Test Realm (`5c9363cc`, 12.1.5 b69952), three: `restrictedActions.inCombatLockdown` → `InCombatLockdown`, `pvp.getArenaOpponentSpec` → `GetArenaOpponentSpec`, `localization.getDefaultAbbreviationBreakpoints` → `C_StringUtil.GetDefaultAbbreviationBreakpoints`.
  - Beta (`078d0cf7`, 12.0.1 b66220), four: `restrictedActions.inCombatLockdown` → `InCombatLockdown`, `stringUtil.trim` → `string.trim`, `tableUtil.count` and `tableUtil.create` → `table.count` and `table.create`.
- The generated flavour files read such a function from where it lives: a global from the host, another table's member only when the host has that table. A namespace holding one is published when the host has its own table or any of those functions, so `api.restrictedActions` exists on a client without `C_RestrictedActions`. Every other namespace block is byte for byte what it was. The LuaCATS definitions are unchanged.
- Implementation revision 4, because the executed flavour files changed. No facade state or method changed: an in-place upgrade from revision 3 keeps everything. A flavour already installed in the session by an older copy's file keeps that surface (`docs/API.md`, *Embedded identity and upgrades*).
- Specs: `RetailBindings_spec.lua` binds `InCombatLockdown` from the global on a host without `C_RestrictedActions`; `Bootstrap_spec.lua` upgrades revision 3 in place. 76 → 78 specs. The real-client suite asserts `api.restrictedActions.inCombatLockdown == InCombatLockdown` again, and its identity walk now also reports a binding whose host member is missing.
- `ApiKit` API generation 1 is unchanged.

## 0.1.3 — 2026-09-24

- Fixed: `RegisterFlavor` and `GetMetadataBuild` refuse a secret `flavor` (Retail 12.x) at the caller's line with `ApiKit:<Method> flavor must not be a secret value` before it is used as a key of the flavour table, and `RegisterFlavor` refuses a secret `info.build` with `ApiKit:RegisterFlavor info.build must not be a secret value` before its integer test (`build % 1`). A secret used as a table key or in arithmetic raises at that line (measured on Retail 12.1.0 b69933), which reported the failure inside ApiKit instead. `issecretvalue` is looked up at call time; a client without it refuses nothing. A secret `info.version` is only stored and handed back, so it stays accepted. `docs/API.md` documents it under *Secret values* and *Errors*. The generated flavour files are unchanged.
- Implementation revision 3. No state changed: an in-place upgrade from revision 2 keeps the namespace tables, the installed flavours and their `info`, and replaces the methods only.
- Specs: `SecretValues_spec.lua` (a secret flavour id on both methods, a secret `info.build`, a secret `info.version` accepted, a host without `issecretvalue`) and an in-place upgrade from revision 2. 71 → 76 specs.
- `ApiKit` API generation 1 is unchanged.

## 0.1.2 — 2026-09-24

- Fixed: absence of a value that did not originate in the facade is tested with `type(value) == "nil"` rather than compared with `nil`: the optional `info` of `RegisterFlavor` with its `version` and `build` fields, the short `wow` global another addon may own, and the `wow` field of the `MoltenCodes` namespace. No argument is newly refused, and the generated flavour files are unchanged.
- Implementation revision 2. No state changed: an in-place upgrade from revision 1 keeps the namespace tables, the installed flavours and their `info`, and replaces the methods only; the flavour is probed again on the upgrade, as documented.
- Specs: a revision 1 copy is upgraded in place with the current file, and the next revision re-probes the client when it upgrades in place; `tests/support/ApiKitTestEnv.lua` gained `LoadRevision`. 71 specs.
- `ApiKit` API generation 1 is unchanged.

## 0.1.1 — 2026-09-24

- Documentation only: no runtime change, implementation revision 1 is unchanged. `docs/API.md` says the namespace root is written into `MoltenCodes` when the facade first loads (it said "at the first registration", but the facade publishes it before any flavour file registers), and the load-cost table counts what the installed Retail surface retains as 312 tables, one per bound namespace, with `api.profiler` reusing its namespace's table (it said 313 tables, "one per namespace, one per alias"). The README's opening example assigns the event and enumeration it reads, so it compiles.

## 0.1.0 — 2026-09-24

- Initial facade of the flavour-aware wrapper over the World of Warcraft API
  (`docs/API_KIT_DESIGN.md`, roadmap package H step H3). API generation 1,
  implementation revision 1.
- Publishes `MoltenCodes.wow` with one `api` table per flavour (`retail`,
  `classic.era`, `classic.mop`, `ptr`, `beta`) and the short `wow` global when
  nothing else owns the name (`GetGlobalStatus`).
- Detects the running flavour once at load from `WOW_PROJECT_ID`,
  `IsTestBuild()` and `IsBetaBuild()` (`GetFlavor`); a client matching no
  flavour is `"unsupported"` and gets no surface.
- `RegisterFlavor(flavor, install, info?)`: the entry point the generated
  flavour files call. The installer runs at once for the running flavour, once;
  other flavours and later copies are dropped; the metadata's version and build
  are recorded for `GetMetadataBuild`.
- `SUPPORTED_FLAVORS`, a read-only list of the flavour ids in the order of
  `tooling/api/flavours.json`; a spec holds the facade's table to that file.
- Retail bindings generated from the client's documentation tables at
  `Gethe/wow-ui-source@09b9db7948abc9b9648dedaab51eb0cf3ee67b31` (live,
  client 12.1.0, build 69933, captured 2026-09-24): 391 namespaces (312
  bound, 79 script object types), 6,338 documented functions (4,900 bound,
  1,438 methods typed only), 1,782 events, 844 enumerations, 752 structures,
  20 callbacks, 60 constants tables, 57 restriction predicates; the LuaCATS definitions
  under `types/retail/` and the first history entry. The reference and the
  search index are built into a release asset rather than committed.
- Classic Era bindings from `Gethe/wow-ui-source@33e177d9bf38d76d5c6c6e05d5da78db1899659a`
  (classic_era, client 1.15.9, build 69722, 534 tables): 337 namespaces,
  4,589 functions (3,229 bound), 1,483 events, 740 enumerations. Mists of Pandaria Classic
  bindings from `Gethe/wow-ui-source@cde55d0033e89b246381385b2f063cd6c6047ef8`
  (classic, client 5.5.4, build 69934, 533 tables): 337 namespaces, 4,590
  functions (3,230 bound), 1,483 events, 740 enumerations. Two host types the Classic tables
  reference joined `types.json` (`luaFunction`, `RoleShortageReward`).
- Public Test Realm bindings from `Gethe/wow-ui-source@5c9363cc1b4e80b98963e3fcc87ab460fa911a94`
  (ptr2, client 12.1.5, build 69952, 622 tables): 397 namespaces, 6,437
  functions (4,967 bound), 1,783 events, 856 enumerations; four host types the 12.1.5 tables
  introduce joined `types.json` (`Milliseconds`, `Seconds`, `UnitCastBarID`,
  `any`). Beta bindings from `Gethe/wow-ui-source@078d0cf7512bfc9c83c576ae83d14ef6a173ea3b`
  (beta, client 12.0.1, build 66220, the branch's last export of 2026-03-03,
  575 tables): 374 namespaces, 5,942 functions (4,652 bound), 1,728 events,
  810 enumerations.
- Classic Era and Mists test realm clients (`WOW_PROJECT_ID` 2 or 19 with
  `IsTestBuild()` true) run their Classic flavour's surface; the build facts
  are consulted for Retail's project id alone.
