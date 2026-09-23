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
  span, sharing a section with `Section`, and recursion measured once;
- the section cap: `nil, "capped"` beyond `DEFAULT_MAX_SECTIONS`, existing
  sections still returned, and `Measure` running unmeasured for a refused name;
- `Report` ordering and fresh tables, `Reset`, and `Disable` then `Enable`
  keeping sections and statistics;
- `Enable` declining with `"unavailable"` on a host without `debugprofilestop`;
- allocation guards on the disabled and the enabled hot paths;
- duplicate embedded loading, refusal to downgrade, an in-place upgrade to the
  next revision (the real source with its revision constant rewritten), and a
  corrupted-state refusal;
- `error` levels: every argument failure reports the caller's own line;
- manifest/runtime API and revision consistency.

The clock is the shared fixture's `ClockStub`. A spec that needs a host without
the clock calls `ProfileKitTestEnv.NewPackageWithoutProfilingClock()`, because
`NewPackage` resets the stubs and would restore it.
