# Changelog

## 0.6.2 — 2026-09-23

- Corrupted package state found by `Get`, `GetInfo` and `OnRetire` is raised at the caller's line again. 0.6.0 routed those three through a shared lookup helper, which moved the error one frame too shallow, onto a line inside `Registry.lua`; `Register` and `Find` were unaffected.
- `Packages()` no longer lists malformed private state as data. A malformed entry used to be skipped or listed as a row, and a bucket with a non-integer API key made `table.sort` fail inside Registry; every such case now raises the same corruption error `Get` raises, at the caller.
- Corrected `docs/API.md`: the corruption paragraph now names every method that checks state, and the migration story no longer says the framework packages still read the plain `MoltenCodes.Registry` alias — every package resolves `MoltenCodes.Registries[2]` first.
- Three specs: the caller's line for corrupted state from all six methods, `Packages` refusing four kinds of malformed bucket, and an in-place upgrade from revision 8 that keeps an unfinished migration run and completes it.
- Implementation revision 9. The private state layout is unchanged from revision 8.

## 0.6.1 — 2026-09-23

- Fixed a failed migration step being skipped for good. The next copy started after the revision the failed copy had registered, so the failing step never ran again and later steps received `nil` because the hand-over had been consumed. While a run is unfinished Registry now keeps the state the last completed step produced and where that step left the layout; the next copy (newer revision or same-revision `resume`) resumes from there with that state, without asking the outgoing copy to retire twice. The kept state is released when a run completes.
- A later sealing revision now installs a fresh seal, so the refusal names the label of the revision that currently owns the facade instead of the first one that sealed it.
- Documented that a plain `Register` upgrade over a `retired` entry leaves it `retired` until a copy completes the run through `Bootstrap`, and corrected the decision table: a `resume` that re-runs setup also returns the migrated state.
- Two regression specs: revision 2 fails at step 2 and a revision-3 copy runs steps 2 and 3 once each over the carried state; a second sealing revision's label appears in the refusal.
- Implementation revision 8.

## 0.6.0 — 2026-09-23

- Added `Registry:Find(package, api)`: a silent lookup for optional dependencies. It returns the same table and revision `Get` returns, or `nil` and a reason from a fixed vocabulary (`absent`, `generation_mismatch`, `retired`). It never raises for a missing package, raises at the caller for malformed arguments, and allocates nothing.
- Added `Registry:Packages()`: a sorted, freshly allocated diagnostic listing of every registration as `{ package, api, revision, status }`. It allocates by design and is documented as unsuitable for hot paths.
- Added retirement and migration to `Registry:Bootstrap`. The outgoing copy's `retire` hook (from `request.retire` or the new `Registry:OnRetire(package, api, fn)`) is called exactly once, before the incoming copy registers, and returns the state it hands over. The incoming copy's `request.migrations = { [revision] = fn(state, implementation) }` runs in ascending order over `(inherited revision, own revision]`, each step exactly once: Registry records the last step run per entry, so a copy resuming over already-migrated state does not replay it. The migrated state is `Bootstrap`'s new fourth return value. A failing retire hook is reported through the host error handler and the upgrade continues from no hand-over; a failing step is raised at the package's `Bootstrap` call and leaves the entry `retired` until a copy completes the run. A retire hook is discarded whenever another revision is selected, so it is never handed a newer copy's table.
- Added `request.sealFacade`, an opt-in `__newindex` metatable that refuses new facade fields written from outside the package, at the writer's line. Packages keep writing through `rawset`, so upgrades still mutate the facade, and `rawget` and `pairs` are unchanged. Lua 5.1 cannot intercept assignments to fields that already exist, so the seal refuses additions but not overwrites; `docs/API.md` states the limit. It is intended to become the default in a later API generation.
- Documented the retirement contract, the decision table with its retire and migration columns, and the seal's limits in `docs/API.md`.
- Added a line budget (1000 lines) and a table of contents to the top of `Registry.lua`, and moved the method definitions out of the install block into named sections, so the migration runner and the seal live in their own section beside `Bootstrap`.
- 23 new specs: `Find_spec.lua`, `Retirement_spec.lua` (including the two-step r4 → r6 upgrade and the no-double-run case) and `Seal_spec.lua`.
- Implementation revision 7. The public API generation is unchanged at 2; every addition is additive, and a Kit that passes none of the new request fields bootstraps exactly as before.

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
