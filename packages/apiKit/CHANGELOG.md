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
  search index are built into a release asset rather than committed. Flavour
  files for the other clients follow with their captures.
