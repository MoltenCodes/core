# Changelog

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
- 109 specs, including the three cookbook schemas from API.md run as written, an allocation guard on a valid check of a nested table, depth and size bounds, secret refusal through a local `issecretvalue` stub, an in-place upgrade spec, and pinned error levels.
