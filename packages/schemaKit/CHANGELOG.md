# Changelog

## 0.3.0 — 2026-11-18

The heavy builders out of the core (roadmap package P, "schemaKit Rules and Apply parts", core decision 20). API generation 1; additive for an addon that embeds both parts.

- Changed: string patterns, `SchemaKit.custom` and `SchemaKit.oneOf` moved to the new optional part `Rules` (`src/parts/SchemaKit-Rules.lua`), and `schema:Apply` to the new optional part `Apply` (`src/parts/SchemaKit-Apply.lua`), each part revision 1. Without a part its members stay on the facade and the `Schema` prototype and raise at the caller's line: `SchemaKit.custom is in SchemaKit's Rules part, which is not loaded: add schemaKit\parts\SchemaKit-Rules.lua`, the same for `SchemaKit.oneOf` and `SchemaKit.string pattern`, and `SchemaKit.Schema:Apply is in SchemaKit's Apply part, which is not loaded: add schemaKit\parts\SchemaKit-Apply.lua`. The checker stays whole in the core, so nodes built with a part check the same without it.
- Added: `SchemaKit:HasPart(name)`, whether a part is loaded, without raising for an unknown name; it refuses a dot call, a secret name and a non-string at the caller's line.
- Changed: the builders', `GetLimit`'s and `HasPart`'s secret checks use the shared probe block (`tooling/shared/lua/isSecret.lua`): a probe present at load is kept, one absent at load is read again on each call; `Check`, `Assert`, `Apply` and `SetLimits` still read the global once per call. A `SetLimits` key that is a secret is named `<secret>` (the shared `describeKey` block); a secret cannot be a table key on a client, so no client sees it. The limits loop keeps its own messages (`tooling/shared/pins.json` opts it out of the shared `limits` block).
- Resident memory, host Lua 5.1.5, debug information kept, 2026-11-18: core 85.4 KB → 78.7 KB; Rules part 7.8 KB; Apply part 6.8 KB.
- Implementation revision 7. An in-place upgrade from revision 6 with a part absent keeps revision 6's `string`, `custom`, `oneOf` and `Schema.Apply` (they build and read node layout 2, which revision 7 checks unchanged) until the part loads; revision 6 loaded after revision 7 yields, and its addon meets the stubs until some addon embeds the parts (documented under *Embedded copies and upgrades*). `tests/fixtures/SchemaKit-revision6.lua` is a byte copy of revision 6 for these specs.
- Specs: 139 → 161 (one pending). `Parts_spec.lua` (eleven: the stubs at the caller's line, the core alone, `HasPart`, installing, a newer core checking part-built nodes, loading without the core, a part run twice, the upgrade from revision 6 with and without the parts, the reverse-order limit), `Manifest_spec.lua` (the parts), `Conformance_spec.lua` (KitConformance; `limits` pending because `defaultArrayMax` has no ceiling).

## 0.2.0 — 2026-11-15

Smaller schemas and a non-allocating limit read (roadmap package O, "schemaKit sparse compiled nodes and GetLimit", core decision 18). API generation 1, additive.

- Changed: a compiled node holds only `layout`, `kind`, `expected` and the fields its kind uses (node layout 2); every other field is absent instead of `false`. The seven `~= false` tests became truthiness tests, which read both layouts; `Describe` answers `integer = false` and `open = false` for an absent flag, so its output is unchanged. A 4-field schema holds 4 723 B instead of 13 523 B (−65%), the benchmark schema's 38 nodes 15.2 KB instead of 49.0 KB, measured on host Lua 5.1 (2026-11-15). Checks cost the same.
- Added: `SchemaKit:GetLimit(name)`, one shared limit's current value without allocating, for a consumer that reads a limit on a hot path (SettingsKit's nested writes). It raises at the caller's line on a dot call, a secret name and any name but the four limits.
- Implementation revision 6. An in-place upgrade from revision 5 or earlier copies every node built before it into a layout 2 node and re-points every reference (proxies, schema records, child fields), so schemas built before the upgrade give their memory back and keep checking, applying and describing as before.
- Specs: 133 → 139. `NodeLayout_spec.lua` (three: node sizes, `Describe` unchanged, the upgrade from layout 1), `GetLimit` in `Limits_spec.lua` (three, one an allocation guard).

## 0.1.6 — 2026-11-15

- Fixed: `SetLimits` built its unknown-limit message with `tostring(key)`, so a key that is a table or userdata with a `__tostring` metamethod ran that foreign code inside SchemaKit. The metamethod could raise or answer a secret value, and the caller then saw its error instead of the real refusal. A string key is still shown as written and a number or boolean key through `tostring` (no foreign code runs for those, so `limits.1` is unchanged); any other key is named by its type: `SchemaKit:SetLimits limits.<table> is not a recognised limit`, at the caller's line, with no limit changed. `docs/API.md` documents the form under *Limits*.
- Implementation revision 5. No state changed: an in-place upgrade from revision 4 keeps every node, schema, failure table and limit and replaces the methods only; the upgrade specs check the new message after the upgrade.
- Specs: a table key whose `__tostring` raises is refused by its type at the caller without running it. 132 → 133 specs.

## 0.1.5 — 2026-11-15

- `docs/API.md` listed every builder, method and limit message but none of the three raised at load; *Loading* now gives them (`requires Registry API 2 to be loaded first`, `requires a valid Registry API 2 facade`, `package state is corrupted or incomplete`).
- `tests/README.md` named only the upgrade from revision 1 to the working file; `Bootstrap_spec.lua` also upgrades the previous revision in place, and the list now says so.
- The README's list of limits left out `maxPatternCaptures`, the fourth limit `SetLimits` accepts (lower only, 32 being Lua 5.1's own capture limit); it now names it.
- Documentation only: implementation revision 4 is unchanged.

## 0.1.4 — 2026-09-24

- A secret builder argument or `Assert` argument (Retail 12.x) is refused at the caller's line, with the message an invalid value of that argument gets, before SchemaKit compares it, uses it as a key or does arithmetic on it. Measured on Retail 12.1.0 (build 69933): comparing a secret with a value of its own type and using it as a table key raise in tainted code. The sites were the `min` and `max` of `SchemaKit.string`, `SchemaKit.number` and `SchemaKit.array` (the NaN test, the integer test and `min > max`), `SchemaKit.map`'s `max`, `SchemaKit.string`'s `pattern` (the empty-string test), the literals of `SchemaKit.string{ oneOf }` and `SchemaKit.enum` (the NaN test and the set lookup), `SchemaKit.custom`'s `description`, and `Assert`'s `argumentName` (the empty-string test) and `level` (the integer test and `level + 1`). `docs/API.md` lists each message under "Secret values", and its implementation revision line, which still said 2, says 4.
- Implementation revision 4, because the executed implementation changed. No state changed: an in-place upgrade from revision 3 keeps every node, schema, failure table and limit and replaces the methods only.
- Specs: the secret builder arguments, the secret `Assert` arguments, plain values still accepted while the probe exists; the in-place upgrade from the previous revision now runs from revision 3. 132 specs.

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
