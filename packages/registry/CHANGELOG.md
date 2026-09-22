# Changelog

## 0.5.0 — 2026-09-22

- Added `Registry:Bootstrap(request)`, the reconciliation every embedded package repeated by hand: look the package up, refuse to reinterpret private state owned by a newer revision, register this one, and report the revision whose state it inherits. A package now supplies only what it alone can answer — its identity, the label its failures carry, which fields make its public surface complete, whether a same-revision copy already finished, and optionally how to resume one that did not.
- Documented the decision table, the `resume` hook, and the forward-compatible `Registries[2] or Registry` lookup a package uses to reach Registry before it can call `Bootstrap`, in `docs/API.md`.
- Registry does not use the helper for itself. It publishes the facade the helper lives on, so its own bootstrap has to run before any facade method exists.
- `Bootstrap` is part of the facade self-check, so a corrupted or incomplete facade still fails deterministically at load.
- Implementation revision 6. The public API generation is unchanged at 2; a package calling `Bootstrap` requires a Registry at least this new, which the documented load order already guarantees.

## 0.4.1 — 2026-09-22

- Normalised every LuaCATS annotation to the canonical `---@` form and completed the public surface: 40 annotation lines became 40. Every public function, method, facade table, class, field, alias and callback signature is now typed, so editors and `lua-language-server` describe the package instead of guessing.
- Renamed `RegistryPackageInfo` to `Registry.PackageInfo`, so every LuaCATS type in the framework is named after the facade that owns it.
- The annotation count is unchanged because the public surface was already fully annotated; only the type name and the style rule changed.
- Added `src/.luarc.json`. `lua-language-server --check <dir>` treats the directory it is given as its workspace root and ignores parent configuration, so each package source directory now points at the shared `meta/` definitions and at its own runtime dependencies. `packages/<name>/src` type-checks clean at `--checklevel=Warning`.
- Added the now-required `license` field (`MIT`) to `package.manifest.json`, matching the repository `LICENSE` that the release builder copies into every artifact.
- Added an "Embedding" section to the README with this package's load order and direct dependencies, pointing at the new `docs/EMBEDDING.md`.
- No runtime behaviour change. `IMPLEMENTATION_REVISION` is unchanged, and `luac -s -l` produces an identical instruction listing before and after, so no embedded copy carrying these edits displaces an equivalent copy.

## 0.4.0 — 2026-09-22

- Registry API generations now publish side by side. Every generation publishes itself at `MoltenCodes.Registries[<generation>]` and `MoltenCodes.Registry` is an alias for the newest generation present, so loading a second generation no longer aborts either addon's load with a fatal `MoltenCodes.Registry API generation conflict` error.
- A generation displaced from the alias is parked under its own `Registries` key when that key is free, so generations that predate the `Registries` convention stay reachable.
- Load-time failures raise at level 0 with an explicit `Registry:` prefix. A stack level is meaningless at file scope, where the "caller" is whichever addon TOC happened to load the file; argument errors raised from `Register`, `Get` and `GetInfo` continue to point at the calling line.
- `Register`, `Get` and `GetInfo` now reject API generations and revisions above `2^53`. Lua 5.1 numbers are doubles, so a value such as `1e300` used to be accepted as a "positive integer" and became an unbeatable revision that no future embedded copy could replace.
- Annotated the public surface with LuaCATS types so editors and lua-language-server describe `Register`, `Get`, `GetInfo` and the metadata snapshot correctly.
- Added specs for two generations coexisting in both load orders, generation-private bootstrap state, the integer bound, and the caller-line position of argument errors.
- Documented the API-generation migration story and a `.toc` embedding example.

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
