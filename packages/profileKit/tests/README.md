# ProfileKit Tests

The ProfileKit suite covers:

- the disabled path: `Begin`, `End` and `Measure` bound to no-ops that read no
  clock, record nothing and allocate nothing;
- measuring with the shared fixture's `debugprofilestop` stub: count, total,
  spike (`max`) and `last`, in milliseconds, and wall-clock stalls not charged;
- nested different sections (inclusive), a nested `Begin` on the same section
  refused with `"active"`, an `End` without `Begin` refused with `"idle"`, and a
  backwards clock jump dropped with `"clockReset"`;
- `Measure` passing arguments in and every result out (trailing `nil`s
  included), re-raising string and table errors unchanged after recording the
  span, sharing a section with `Section`, recursion measured once, running
  unmeasured under an open manual `Begin`, and a span `fn` ends itself recorded
  once;
- the section cap: `nil, "capped"` beyond `DEFAULT_MAX_SECTIONS`, existing
  sections still returned, and `Measure` running unmeasured for a refused name;
- the limits: `GetLimits` defaults and fresh tables, `SetLimits` raising and
  lowering `maxSections` (lowering evicts nothing), `UNBOUNDED` honoured, and
  invalid values, unknown names and non-facade receivers refused at the
  caller's line without changing anything;
- `Report` ordering and fresh tables, `Reset`, and `Disable` then `Enable`
  keeping sections and statistics;
- `Enable` declining with `"unavailable"` on a host without `debugprofilestop`;
- allocation guards on the disabled and the enabled hot paths;
- duplicate embedded loading, refusal to downgrade, an in-place upgrade to the
  next revision (the real source with its revision constant rewritten) that
  keeps the set limits and the `UNBOUNDED` sentinel, an in-place upgrade from
  the previous revision to the working file, and corrupted-state refusals;
- secret values (a `issecretvalue` stub installed before load): a secret
  `maxSections` and a secret receiver refused at the caller's line;
- `error` levels: every argument failure reports the caller's own line;
- manifest/runtime API and revision consistency.

The clock is the shared fixture's `ClockStub`. A spec that needs a host without
the clock calls `ProfileKitTestEnv.NewPackageWithoutProfilingClock()`, because
`NewPackage` resets the stubs and would restore it.

| Spec | Covers |
|---|---|
| `ProfileKit_spec.lua` | switching, sections, statistics, nesting, clock resets, `Report`, `Reset` |
| `Measure_spec.lua` | `Measure` results, errors, recursion and self-ended spans |
| `Disabled_spec.lua` | the no-op bindings and both allocation guards |
| `Cap_spec.lua` | the section cap |
| `Limits_spec.lua` | `SetLimits`, `GetLimits` and `UNBOUNDED` for `maxSections` |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `SecretValues_spec.lua` | a secret limit value and a secret receiver refused at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, corrupted state |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
