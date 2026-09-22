# Changelog

## 0.3.4 — 2026-09-22

- No runtime behaviour change. Revision 4 still describes the shipped implementation.
- Documented that the private bootstrap state key and the public `MoltenCodes` namespace are the two deliberate global writes through which independently embedded copies find each other.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.3.3

- Expanded runtime package-name validation to accept canonical lowerCamelCase Kit identities such as `signalKit`, `eventKit`, and `lifecycleKit`.
- Added validation coverage for lowerCamelCase package names while continuing to reject PascalCase and punctuation-based identities.
- Added a regression test that keeps runtime API/revision metadata aligned with `package.manifest.json`.
- Documented the initialization-failure trade-off of committing an accepted revision before package mutation completes.

## 0.3.2

- Hardened bootstrap-state and facade integrity checks against metatable field spoofing.
- Switched Registry facade upgrades and bootstrap metadata updates to raw table writes so hostile `__newindex` hooks cannot intercept compatible upgrades.
- Added regression coverage for spoofed bootstrap fields, spoofed facade fields, and hostile facade metatables.
- Renamed Registry specs to Busted's default `*_spec.lua` convention so directory-level CI test discovery cannot silently skip the suite.

## 0.3.1

- Hardened package-state validation so `Register()`, `Get()`, and `GetInfo()` reject malformed private Registry entries consistently.
- Switched internal package-state reads to `rawget`/`rawset` so unexpected metatables cannot alter Registry lookup semantics.
- Added regression coverage for revision-1 to revision-2 Registry facade upgrades and corrupted package state.

## 0.3.0

- Declared the stable shared-table registration contract as Registry API generation 2.
- Removed incomplete compatibility with the earlier API-1 `Register(..., implementation)` development contract.
- Added explicit Registry API-generation conflict detection.
- Added facade integrity validation so corrupted compatible bootstrap state fails deterministically.
- Moved the private bootstrap state to an API-2-specific key.
- Added regression coverage for incompatible bootstrap/public facades.

## 0.2.0

- Introduced the stable shared package table design as a development iteration.
- Higher revisions upgrade the existing package table in place.
- Added `previousRevision` for accepted upgrades.
- Added the portable `MoltenCodes.Registry` public WoW runtime namespace.
- Added direct-load, namespace, stable-reference, and upgrade regression tests.

## 0.1.0

- Initial development implementation using candidate implementation replacement.
- This API-1 development contract is superseded by Registry API generation 2.
