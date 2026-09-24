# Changelog

## 0.1.4 — 2026-09-24

- Fixed: `Section(name)` and `Measure(name, fn, ...)`, enabled and disabled, refuse a secret `name` (Retail 12.x) at the caller's line with `ProfileKit:<Method> name must not be a secret value`, after the string type check and before the name is compared with `""` or used as a key of the section index. A secret string compared with a string, or used as a table key, raises at that line (measured on Retail 12.1.0 b69933), which reported the failure inside ProfileKit instead. Nothing is created and `fn` is not called. The probe is the `issecretvalue` bound once at load; a client without it refuses nothing.
- Cost: the disabled `Measure` is now two type checks, one `issecretvalue` call about the name and a tail call (it was two type checks and a tail call); `docs/API.md` (*Enabling and disabling*, *Cost*), the README and the source header say so, and the README no longer says every disabled caller pays one table read and one call, which holds for `Begin` and `End`. `docs/API.md` documents the refusal under *Secret values* and *Errors*.
- Implementation revision 3. No state changed: an in-place upgrade from revision 2 keeps every section, its statistics, the enabled binding and the limits, and re-binds the methods.
- Specs: a secret name refused by `Section`, the disabled `Measure` and the enabled `Measure`, an empty and a plain name unchanged, and an in-place upgrade from revision 2; the revision 1 upgrade spec no longer assumes the working revision is 2. 76 → 81 specs.

## 0.1.3 — 2026-09-24

- Secret values: the source comments on `issecretvalue` and `SetLimits` no longer claim that comparing a secret with anything, `nil` included, raises, or that a raw identity test is safe whatever the other side. They state what was measured on Retail 12.1.0 b69933 (2026-09-24): a secret compared with a value of its own type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike) and a secret used as a table key raises, while a comparison with `nil` or with a value of another type answers without raising. The `type(value) == "nil"` rule stays, as the repository's uniform rule that never compares anything. Comments and documentation only: `luac -s -l` gives the same instruction listing before and after, so the implementation revision is unchanged.

## 0.1.2 — 2026-09-24

- Implementation revision 2 applies the repository nil rule: the absence of a value that came from a caller is tested with `type(value) == "nil"`, never by comparing it with `nil`, so a secret value (Retail 12.x) is never compared inside ProfileKit. The Registry lookup in the shared namespace and the results of `Registry:Bootstrap` are tested the same way.
- `SetLimits` asks `issecretvalue` (bound once at load; absent means nothing is secret) about each limit value before comparing it with `UNBOUNDED` or a number, and refuses a secret with the existing `ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED` at the caller's line. A secret there used to raise inside ProfileKit.
- The facade check of `SetLimits` and `GetLimits` tests the receiver's type before comparing it with the facade.
- `Measure` and `Section` are unchanged: section names come from the addon's own code, and the disabled `Measure` keeps its cost of two type checks and a tail call.
- Specs: a secret `maxSections` refused at the caller, a secret receiver refused, and an in-place upgrade from revision 1 to the working file.

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
