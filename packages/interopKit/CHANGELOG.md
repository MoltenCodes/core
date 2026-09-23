# Changelog

## 0.1.0 — 2026-09-23

- Added InteropKit API generation 1, implementation revision 1: the LibStub bridge.
- `ExposeToLibStub(packageName, api, major)` makes a Kit's shared facade the LibStub library under `major` (default `"MoltenCodes-<Facade>-<api>"`), with the implementation revision as the minor. Idempotent; a newer revision exposes again with the higher minor. Returns `true, major`, or `false` with `"absent"`, `"unknown"` (plus Registry's reason), `"taken"` or `"unsupported"`.
- The bridge calls `LibStub:NewLibrary` and then writes the facade into `LibStub.libs[major]` in place of the empty table LibStub created. That is its only write into LibStub's internals; a major another library holds is refused before LibStub is called, so the foreign library and its minor are never touched.
- `ExposeAll(options)` exposes every active package `Registry:Packages()` lists, skipping `options.except`, and returns the exposed, skipped and refused counts.
- `AdoptFromLibStub(major)` returns a LibStub library and its minor through the silent `GetLibrary(major, true)` and records it; `Find(major)` reads the record without LibStub and without allocating; `Adopted()` lists every adoption sorted by major.
- `IsLibStubPresent()` reports whether a global `LibStub` with `NewLibrary` and `GetLibrary` is loaded.
- Argument errors name the method and parameter and point at the caller's line; a secret `packageName` or `major` is refused before it is compared or formatted.
