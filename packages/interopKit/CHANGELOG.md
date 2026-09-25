# Changelog

## 0.1.2 — 2026-09-25

- `Find(major)` checks its argument inline (type, one `issecretvalue` probe, empty string) and calls the shared validator only to raise, with the same messages at the same caller line. `type`, `rawget` and the global table are read into locals once. Its `Registry:Find` calls benefit from Registry revision 14's lookup fast path.
- Host benchmark, workload `libraryRegistry`, case `foreign-lookup`, 3 rounds, run while other packages were being benchmarked: 178 → 120 ns (3.1× → 2.2× `LibStub:GetLibrary(major, true)`), 0 bytes before and after. The remaining gap is the secret probe of `major` and the adoption record read, which the contract keeps.
- Implementation revision 3. No state changed: an in-place upgrade keeps the adoption records and replaces the methods only. New specs: every `Find` refusal (including a secret major that names an adopted library) at the caller's line, and an in-place upgrade from a revision 2 copy with the current file. 61 specs.
- `InteropKit` API generation 1 is unchanged.

## 0.1.1 — 2026-09-24

- Fixed: absence of a value that did not originate in InteropKit is tested with `type(value) == "nil"` rather than compared with `nil`, so no comparison runs on a caller's value before its secret check. This covers the optional `major` of `ExposeToLibStub` (a secret major is now refused as a secret instead of first being compared with `nil`), `options` and `options.except` of `ExposeAll`, and the library and minor InteropKit reads from LibStub's `libs` and `minors` tables.
- Implementation revision 2. No state changed: an in-place upgrade from revision 1 keeps the adoption records and replaces the methods only.
- Specs: the upgrade specs load the next revision relative to the current one; a new spec upgrades a revision 1 copy with the current file; a secret package name in `options.except` is refused at the caller. 59 specs.
- `InteropKit` API generation 1 is unchanged.

## 0.1.0 — 2026-09-23

- Added InteropKit API generation 1, implementation revision 1: the LibStub bridge.
- `ExposeToLibStub(packageName, api, major)` makes a Kit's shared facade the LibStub library under `major` (default `"MoltenCodes-<Facade>-<api>"`), with the implementation revision as the minor. Idempotent; a newer revision exposes again with the higher minor. Returns `true, major`, or `false` with `"absent"`, `"unknown"` (plus Registry's reason), `"taken"` or `"unsupported"`.
- The bridge calls `LibStub:NewLibrary` and then writes the facade into `LibStub.libs[major]` in place of the empty table LibStub created. That is its only write into LibStub's internals; a major another library holds is refused before LibStub is called, so the foreign library and its minor are never touched.
- `ExposeAll(options)` exposes every active package `Registry:Packages()` lists, skipping `options.except`, and returns the exposed, skipped and refused counts.
- `AdoptFromLibStub(major)` returns a LibStub library and its minor through the silent `GetLibrary(major, true)` and records it; `Find(major)` reads the record without LibStub and without allocating; `Adopted()` lists every adoption sorted by major.
- `IsLibStubPresent()` reports whether a global `LibStub` with `NewLibrary` and `GetLibrary` is loaded.
- Argument errors name the method and parameter and point at the caller's line; a secret `packageName`, `api` or `major` is refused before it is compared or formatted.
