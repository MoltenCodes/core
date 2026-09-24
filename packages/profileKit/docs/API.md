# ProfileKit API

ProfileKit API generation **1** provides named performance sections measured in
milliseconds of addon CPU time, a sorted report, and zero cost while disabled.

## Public surface

Package facade:

| Member | Purpose |
|---|---|
| `Enable()` | Start measuring. Returns `true`, or `false, "unavailable"` without `debugprofilestop`. |
| `Disable()` | Stop measuring. Keeps statistics; abandons open measurements. |
| `IsEnabled()` | Return whether ProfileKit is measuring. |
| `Section(name)` | Return the section called `name`, creating it on first use; `nil, "capped"` beyond `maxSections`. |
| `Measure(name, fn, ...)` | Call `fn(...)` inside section `name` and return all of its results. |
| `Report()` | Return a fresh array of `{ name, count, total, max, last }`, sorted by `total` descending. |
| `Reset()` | Zero every section's statistics and abandon open measurements. |
| `SetLimits(limits)` | Change the shared `maxSections` limit. Returns nothing. |
| `GetLimits()` | A fresh table `{ maxSections = ... }`; allocates. |
| `DEFAULT_MAX_SECTIONS` | `256`, the default of `maxSections`. |
| `UNBOUNDED` | Sentinel that lifts `maxSections`; the same table for every revision. |
| `API`, `REVISION` | API generation `1` and implementation revision. |

Sections:

| Method | Enabled | Disabled |
|---|---|---|
| `Begin()` | `true`, or `nil, "active"` when the section is already begun. | No-op; returns nothing. |
| `End()` | Elapsed milliseconds, or `nil, "idle"` without a `Begin`, or `nil, "clockReset"` when the sample was dropped. | No-op; returns nothing. |

## Time and the clock

Every time is **milliseconds** read from `debugprofilestop`, the addon CPU clock
SchedulerKit's frame budget also uses. Values are fractional. A client hitch or
a garbage-collection pause that stalls the frame without running the measured
code is not charged to the section.

`debugprofilestop` is bound once when the file loads. On a host that does not
publish it, ProfileKit still loads and every method works, but `Enable()`
returns `false, "unavailable"` and ProfileKit stays disabled. There is no
wall-clock fallback: a section measured in wall time would silently mean
something else.

`issecretvalue` is also bound once at load and is optional. `SetLimits` asks
it about each limit value before comparing it, and `Section` and `Measure` ask
it about the section name before comparing it with the empty string or using it
as a key; without it nothing is treated as secret. See
[Secret values](#secret-values).

The clock is one process-wide timer that any addon may zero with
`debugprofilestart()`. An `End` whose reading is smaller than its `Begin`
reading measured nothing, so the sample is **dropped**: `count`, `total`, `max`
and `last` are unchanged and `End` returns `nil, "clockReset"`. The section is
idle again afterwards.

## Enabling and disabling

ProfileKit loads disabled and nothing in the framework enables it. `Enable` and
`Disable` are idempotent.

The switch is a function swap, not a flag. `Enable` installs the measuring
`Begin` and `End` on the one section prototype every section shares and the
measuring `Measure` on the facade; `Disable` installs no-op functions in the
same places. A caller always looks the method up, so while ProfileKit is off a
`section:Begin()` costs one table read and one call to an empty function, and
`ProfileKit:Measure(name, fn, ...)` checks its two arguments (two type checks
and, on a client with `issecretvalue`, one call to it about `name`) and
tail-calls `fn(...)`. Neither reads the clock or allocates.

The disabled `Begin` and `End` perform no argument checks at all. The enabled
ones check their receiver, so `section.Begin()` (a dot call) raises only once
ProfileKit is enabled.

`Disable` keeps every section and its statistics; a later `Enable` continues
counting from them. Only `Reset` clears statistics. A measurement begun before
`Disable` is **abandoned**: its `End` after a later `Enable` returns
`nil, "idle"` instead of recording a span that straddled the switch.

## Sections

```lua
local section = ProfileKit:Section("MyAddon.OnUpdate")

section:Begin()
-- measured work
section:End()
```

`Section(name)` accepts a non-empty string and returns the same section for the
same name for the whole session, whether or not ProfileKit is enabled, so create
sections once at file scope. Creating a section allocates one table; `Begin` and
`End` never allocate.

Sections nest: an outer section's span includes the time of every section begun
and ended inside it (inclusive timing). A section is **not** re-entrant:
`Begin` on a section that is already begun is refused with `nil, "active"`
rather than an error, and the original start is kept, so the eventual `End`
measures from the first `Begin`. Use a different section for an inner span, or
`Measure`, which handles recursion (below).

`End` on a section that is not begun returns `nil, "idle"`.

### The section limit

By default at most `DEFAULT_MAX_SECTIONS` (256) sections exist per session.
Sections are never freed, because callers hold them, so the limit is what stops
code that builds section names from data from growing ProfileKit without limit.
`Section(name)` for a new name at the limit returns `nil, "capped"`; existing
names are still returned. `Reset` keeps sections, so they keep counting against
the limit. The limit is opened with `SetLimits`; see [Limits](#limits).

## `Measure(name, fn, ...)`

```lua
local a, b, c = ProfileKit:Measure("MyAddon.Rebuild", MyAddon.Rebuild, MyAddon, full)
```

Calls `fn(...)` and returns **every** result of `fn`, trailing `nil`s included.
The results travel as a Lua vararg list from the call to the caller, so no table is
built for them, whatever their number.

While enabled, `Measure` uses the section called `name` (creating it on first
use, sharing it with `Section(name)`), reads the clock before and after, and
records the span. `fn` runs inside `pcall`: when it raises, the span is still
recorded, and the error value is then re-raised **unchanged** with
`error(value, 0)` — a string keeps the position `fn` gave it, a table error is
the same table. The re-raise does lose the original stack traceback.

Because of that `pcall`, a measured `fn` must not yield: Lua 5.1 cannot yield
across `pcall`. Inside a SchedulerKit job, measure with a section's `Begin` and
`End` around the non-yielding part instead.

`Measure` runs `fn` **unmeasured** in three cases, and still returns its
results: the name is refused by the `maxSections` limit; the section is already begun, by a
manual `Begin` or by an outer `Measure` of the same name (recursion is measured
once, at the outermost call); and ProfileKit is disabled. If `fn` itself calls
`Disable`, `Reset` or the section's `End`, the span is not recorded a second
time.

`name` must be a non-empty string and `fn` a function, whether ProfileKit is
enabled or not, so code that fails once profiling is on already fails while it
is off.

## `Report()`

Returns a new array with one new table per section:

| Field | Meaning |
|---|---|
| `name` | Section name. |
| `count` | Completed, recorded measurements. |
| `total` | Sum of every recorded measurement, in milliseconds. |
| `max` | Worst single measurement (the spike), in milliseconds. |
| `last` | Most recent measurement, in milliseconds. |

Rows are sorted by `total` descending, ties by `name` ascending, so the order is
deterministic. Sections that were never measured are listed with zeros.
`Report` **allocates by design**: the caller owns the array and every row, and
changing them does not affect ProfileKit. Call it from diagnostics, never from
a hot path.

## `Reset()`

Zeroes `count`, `total`, `max` and `last` of every section and abandons open
measurements. Sections and the enabled state are kept.

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxSections` | 256 (`DEFAULT_MAX_SECTIONS`) | `ProfileKit:SetLimits({ maxSections = n })` | Yes |

```lua
ProfileKit:SetLimits({ maxSections = 1024 })
ProfileKit:SetLimits({ maxSections = ProfileKit.UNBOUNDED })
local limits = ProfileKit:GetLimits() -- a fresh table; allocates
```

`SetLimits` accepts any subset of the limits and returns nothing. It raises at
the caller's line, **before changing anything**, when `limits` is not a table,
names an unknown limit (`ProfileKit:SetLimits limits.<name> is not a recognised
limit`) or gives a value that is neither a positive integer nor
`ProfileKit.UNBOUNDED` (`ProfileKit:SetLimits limits.maxSections must be a
positive integer or ProfileKit.UNBOUNDED`). A secret value (Retail 12.x) is
refused with that same message before it is compared with anything, when the
client has `issecretvalue`. `GetLimits` returns a new table on
every call, with `ProfileKit.UNBOUNDED` itself for a lifted limit.

**The limits are shared by every consumer in the session**: every embedded copy
and every addon uses one set, like the sections themselves. A library should
rely on the default; an addon that raises the limit raises it for everybody.

`UNBOUNDED` is allowed because the only memory it lets grow is the sections
consumers create by name — one small table each — and no client resource.
Lowering the limit below the sections that already exist removes none of them;
new names are refused with `nil, "capped"` until the count is under the limit
again.

## Refusal reasons

| Reason | Returned by | Meaning |
|---|---|---|
| `"unavailable"` | `Enable` | The host has no `debugprofilestop`. |
| `"capped"` | `Section` | A new section would exceed the `maxSections` limit. |
| `"active"` | `Begin` | The section is already begun. |
| `"idle"` | `End` | The section is not begun, or its measurement was abandoned. |
| `"clockReset"` | `End` | The clock went backwards; the sample was dropped. |

## Errors

Argument errors are raised at the caller's line:

- `ProfileKit:Section name must be a non-empty string`
- `ProfileKit:Measure name must be a non-empty string`
- `ProfileKit:Section name must not be a secret value` and `ProfileKit:Measure name must not be a secret value` (enabled and disabled; see [Secret values](#secret-values))
- `ProfileKit:Measure fn must be a function`
- `ProfileKit.Section:Begin must be called on a ProfileKit section` (enabled only)
- `ProfileKit.Section:End must be called on a ProfileKit section` (enabled only)
- `ProfileKit:SetLimits limits must be a table`
- `ProfileKit:SetLimits limits.<name> is not a recognised limit`
- `ProfileKit:SetLimits limits.maxSections must be a positive integer or ProfileKit.UNBOUNDED` (also for a secret value)
- `ProfileKit:SetLimits must be called on the ProfileKit facade; use ProfileKit:SetLimits(...)` (and the same for `GetLimits`)

## Secret values

On Retail 12.x a secret compared with a value of its own type, or used as a
table key, raises at that line (measured on Retail 12.1.0 b69933; see
[`EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)).
ProfileKit asks `issecretvalue`, bound once at load, first:

- `Section(name)` and `Measure(name, fn, ...)`, enabled and disabled alike,
  refuse a secret `name` at the caller's line with `ProfileKit:<Method> name
  must not be a secret value`, after the string type check and before `name`
  is compared with `""` or used as a key of the section index. Nothing is
  created and `fn` is not called. Section names normally come from the addon's
  own code, so a plain name pays one probe call and nothing else.
- `SetLimits` refuses a secret limit value with the invalid-value message
  above, before comparing it.

The messages never format the value in. A client without `issecretvalue` has
no secret values and refuses nothing.

## Cost

| Path | Cost |
|---|---|
| Disabled `Begin` / `End` | One table read and one call to an empty function. |
| Disabled `Measure` | Two type checks, one `issecretvalue` call about `name` (bound at load; none on a client without it) and a tail call to `fn`. |
| Enabled `Begin` + `End` | Two clock reads, one receiver check each, a few field writes. No allocation. |
| Enabled `Measure` | One table lookup, two clock reads, one `pcall`. No allocation after the section exists. |
| `Section` (new name) | One table. |
| `Report` | One array and one table per section, plus a sort. |
| `GetLimits` | One table. |

## Upgrades

ProfileKit bootstraps through `Registry:Bootstrap`. Sections, their statistics,
the section prototype, the enabled state, the limits a consumer set and the
`UNBOUNDED` sentinel live in the shared package state,
so an in-place upgrade keeps all of them: a section created by an older embedded
copy resolves to the newer copy's methods, and a measurement begun under the
older copy is ended by the newer one. The newer copy re-binds the measuring or
no-op functions according to the inherited enabled state; if its host has no
`debugprofilestop`, it comes up disabled.
