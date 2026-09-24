# Changelog

## 0.1.1 — 2026-09-24

- Documentation and specs only; implementation revision 1 is unchanged.
- README says the 256-section bound is the default of the `maxSections` limit.
- The upgrade specs load the shipped revision plus one (and plus two) instead of fixed revisions 2 and 3, so they keep testing an upgrade after the next revision bump.

## 0.1.0 — 2026-09-23

- Added ProfileKit API generation 1, implementation revision 1: named performance sections with call count, total time, worst spike and last time, in milliseconds of addon CPU time from `debugprofilestop`.
- Added `Enable`, `Disable` and `IsEnabled`. ProfileKit loads disabled; `Enable` returns `false, "unavailable"` on a host without `debugprofilestop`.
- Added `Section(name)` returning a section with `Begin()` and `End()`. A nested `Begin` on the same section is refused with `nil, "active"`, an `End` without `Begin` with `nil, "idle"`, and a sample whose clock went backwards (another addon called `debugprofilestart()`) is dropped with `nil, "clockReset"`.
- Added `Measure(name, fn, ...)`, which returns every result of `fn` without building a table for them and re-raises an error from `fn` unchanged after closing the span.
- Added `Report()`, a fresh array sorted by total descending, and `Reset()`, which zeroes statistics and keeps sections.
- Zero cost when off: `Begin`, `End` and `Measure` are swapped for no-op functions on the shared section prototype and facade, so disabled callers pay one table read and one call and allocate nothing.
- Sections are bounded by the `maxSections` limit, default `DEFAULT_MAX_SECTIONS` (256); a further name is refused with `nil, "capped"`.
- Added `SetLimits({ maxSections = n })` and `GetLimits()` (2026-09-23), replacing the fixed cap: `maxSections` accepts a positive integer or the new `ProfileKit.UNBOUNDED` sentinel, is validated at the caller before anything changes, and is shared by every consumer in the session. Lowering it evicts nothing. `GetLimits` returns a fresh table. The sentinel and the set limits live in the package state and survive an in-place upgrade.
- State survives an in-place upgrade through `Registry:Bootstrap`: sections, statistics, the enabled binding, the limits and the `UNBOUNDED` sentinel carry over.
