# Changelog

## 0.1.3 — 2026-09-24

- A secret answer from a `SchemaKit.custom` check (Retail 12.x) rejects the value with rule `custom`, like a falsy answer, instead of raising inside SchemaKit when the answer was tested as a boolean. Measured on Retail 12.1.0 (build 69933): a boolean test of a secret raises in tainted code.
- A secret `integer` flag of `SchemaKit.number`, `open` flag of `SchemaKit.table` and `freshFailures` option of `Seal` is refused at the caller's line with the message an invalid value of that flag gets, instead of raising inside SchemaKit when the flag was compared or tested. `docs/API.md` documents both under "Secret values".
- Implementation revision 3, because the executed implementation changed. No state changed. Specs: a secret custom answer, the three secret flags, and an in-place upgrade from revision 2 to the working file; the revision-1 upgrade spec compares with the working revision instead of a fixed number.

## 0.1.2 — 2026-09-24

- Implementation revision 2 applies the repository nil rule: the absence of a value that came from outside SchemaKit (a checked or applied value, an array element, a builder's spec and its fields, `Assert`'s `argumentName` and `level`, `Seal`'s options) and the result of matching a caller's string or pattern are tested with `type(value) == "nil"`, never by comparing the value with `nil`. The Registry lookup in the shared namespace and the results of `Registry:Bootstrap` are tested the same way.
- `SetLimits` asks `issecretvalue` about each value before comparing it with `SchemaKit.UNBOUNDED` or a number, and refuses a secret at the caller's line with the message an invalid value of that limit gets. Before, the value was compared with the sentinel first, which raises inside SchemaKit on a secret.
- Specs: a secret limit value refused at the caller, plain limits still accepted with the probe installed, and an in-place upgrade from revision 1 to the working file.

## 0.1.1 — 2026-09-24

- Documentation and specs only; implementation revision 1 is unchanged.
- API.md lists every argument error SchemaKit raises, per builder and method, instead of three examples.
- API.md states the exact `SetLimits` value messages: the ceiling reason is appended only for an integer above the ceiling, and an invalid `defaultArrayMax` raises `must be a positive integer or SchemaKit.UNBOUNDED`.
- README and API.md name the depth bound as the `maxDepth` limit, 16 by default, rather than a fixed 16.
- Specs cover an empty `pattern` and a `oneOf` that is not an array or has holes; the upgrade specs load the shipped revision plus one instead of a fixed revision 2, so they keep testing an upgrade after the next revision bump.

## 0.1.0 — 2026-09-23

- Added SchemaKit API generation 1, implementation revision 1.
- Added the builders `SchemaKit.string{ min, max, pattern, oneOf }`, `SchemaKit.number{ min, max, integer }`, `SchemaKit.boolean()`, `SchemaKit.enum{ ... }`, `SchemaKit.table{ fields, open }`, `SchemaKit.array{ of, min, max }`, `SchemaKit.map{ keys, values, max }`, `SchemaKit.optional(schema, default)`, `SchemaKit.oneOf{ ... }`, `SchemaKit.any()` and `SchemaKit.custom(check, description)`. Each validates its spec at the caller's line and returns an immutable node; nodes and sealed schemas compose freely.
- Added `SchemaKit:Seal(node, options)`, returning a sealed schema whose writes are refused and whose metatable cannot be replaced. `options.freshFailures` returns a new failure table from every failing call.
- Added `schema:Check(value)` → `true` or `false, failure` with `{ path, rule, expected, found }`. A valid value allocates nothing; the failure table is reused per schema. `found` is a type name or a fixed description, never the value.
- Added `schema:Assert(value, argumentName, level)`, raising `argumentName.path: expected ..., found ...` at the requested level and returning the value when valid.
- Added `schema:Apply(value)` → `true, copy` with every declared default filled in (including per-entry defaults of maps and arrays), or `false, failure`. Allocates.
- Added `schema:Describe()`, a fresh plain description for documentation and options screens.
- Values may nest at most 16 tables (rule `"depth"`); arrays hold at most 1024 elements unless `max` says otherwise and maps require `max` (rule `"max"`). Oversized tables are refused after `max + 1` steps.
- Secret values (Retail 12.x) are refused with rule `"secret"` before any comparison, through `issecretvalue` looked up at every check.
- Failure paths escape quoted keys for display: `|` is doubled so no World of Warcraft escape sequence (`|T`, `|H`, `|c`) survives, `\` and `"` are backslash-escaped, and every other control byte (0 to 31 and 127) appears as `\ddd`. A key cut at 32 bytes is never cut inside a UTF-8 sequence.
- `SchemaKit.Seal(node)` called with a dot raises `SchemaKit:Seal is called with a colon, not a dot`.
- API.md states that the compiled checker in `_state` is private by convention, like every Kit's `_state`, and lists what a consumer must not do; the seal guards against mistakes and is not a boundary between addons.
- Published `SchemaKit.MAX_DEPTH` (16) and `SchemaKit.DEFAULT_ARRAY_MAX` (1024).
- A string `pattern` is validated as a whole when the node is built. Lua 5.1 reports a malformed pattern (`"a["`, `"(a"`, `"a%"`, `"a%b"`, `"%f"` without a set, a back-reference to an unclosed capture, more than 32 captures) only when matching reaches the broken part, so SchemaKit walks the whole pattern at build time and refuses it at the caller's line; `Check` never raises on a pattern.
- `SchemaKit.table{ fields = node }` is refused: a node or sealed schema is not a table of fields.
- `Apply` is documented as walking every undeclared field of an open table, which `Check` does not; the root-failure allocation note names the count phrases it builds.
- Added `SchemaKit:SetLimits{}` and `SchemaKit:GetLimits()` over four session-shared limits kept in the package state: `maxDepth` (16, ceiling 64), `maxPatternCaptures` (32, ceiling 32, the Lua 5.1 matcher's own), `pathKeyLimit` (32, ceiling 1024) and `defaultArrayMax` (1024). Added `SchemaKit.UNBOUNDED`, one sentinel shared by every revision, accepted by `defaultArrayMax` only; the other three refuse it with the reason. Every refusal is raised at the caller's line before any limit changes. API.md gains a *Limits* section.
- 121 specs, including the three cookbook schemas from API.md run as written, an allocation guard on a valid check of a nested table, depth and size bounds, secret refusal through a local `issecretvalue` stub, an in-place upgrade spec, limit specs (defaults, each limit honoured, `UNBOUNDED` accepted or refused with its reason, invalid values refused at the caller, limits and the sentinel kept across an upgrade), and pinned error levels.
