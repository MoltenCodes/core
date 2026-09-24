# Changelog

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
  client 12.1.0, build 69933, captured 2026-09-24): 391 namespaces, 6,338
  functions, 1,782 events, 844 enumerations, 752 structures, 20 callbacks,
  60 constants tables, 57 restriction predicates; the LuaCATS definitions
  under `types/retail/` and the first history entry. The reference and the
  search index are built into a release asset rather than committed.
- Classic Era bindings from `Gethe/wow-ui-source@33e177d9bf38d76d5c6c6e05d5da78db1899659a`
  (classic_era, client 1.15.9, build 69722, 534 tables): 337 namespaces,
  4,589 functions, 1,483 events, 740 enumerations. Mists of Pandaria Classic
  bindings from `Gethe/wow-ui-source@cde55d0033e89b246381385b2f063cd6c6047ef8`
  (classic, client 5.5.4, build 69934, 533 tables): 337 namespaces, 4,590
  functions, 1,483 events, 740 enumerations. Two host types the Classic tables
  reference joined `types.json` (`luaFunction`, `RoleShortageReward`).
- Public Test Realm bindings from `Gethe/wow-ui-source@5c9363cc1b4e80b98963e3fcc87ab460fa911a94`
  (ptr2, client 12.1.5, build 69952, 622 tables): 397 namespaces, 6,437
  functions, 1,783 events, 856 enumerations; four host types the 12.1.5 tables
  introduce joined `types.json` (`Milliseconds`, `Seconds`, `UnitCastBarID`,
  `any`). Beta bindings from `Gethe/wow-ui-source@078d0cf7512bfc9c83c576ae83d14ef6a173ea3b`
  (beta, client 12.0.1, build 66220, the branch's last export of 2026-03-03,
  575 tables): 374 namespaces, 5,942 functions, 1,728 events, 810
  enumerations.
