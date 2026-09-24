# SchemaKit API

SchemaKit API generation **1** provides value schemas: builders that describe a value, a seal that makes the description immutable, and a checker that reports structured failures which never contain the checked value.

Implementation revision: **4**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SchemaKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local SchemaKit = MoltenCodes.Registries[2]:Get("schemaKit", 1)
```

SchemaKit does not rely on `require()` at runtime.

### Optional host facilities

| Facility | Used by | Without it |
|---|---|---|
| `issecretvalue` | every `Check`, `Assert` and `Apply`, `SetLimits`, and the builders' argument checks | Nothing is treated as secret, which is correct on clients without secret values. |

`issecretvalue` is read from the global table at every call, not once at load, so a probe that appears later is used at once. It costs one `rawget` per call.

## Public surface

Package facade:

| Field | Purpose |
|---|---|
| `string(spec?)` | A string, optionally bounded in length, matched against a pattern or restricted to a list. |
| `number(spec?)` | A number, optionally bounded and restricted to whole numbers. |
| `boolean()` | `true` or `false`. |
| `enum(values)` | One of the listed strings, numbers or booleans. |
| `table(spec)` | A record with named fields, closed to other fields unless `open`. |
| `array(spec)` | A sequence with keys exactly `1..n`. |
| `map(spec)` | A table whose keys and values each match a schema, with a required size bound. |
| `optional(schema, default?)` | `nil` or a value matching `schema`; `Apply` fills in `default`. |
| `oneOf(alternatives)` | A value matching at least one alternative, tried in order. |
| `any()` | Any value except `nil`. |
| `custom(check, description)` | A value your function accepts. |
| `Seal(node, options?)` | Seal a node (or re-seal a schema) into a schema. |
| `SetLimits(limits)` | Change any subset of the shared limits (see [Limits](#limits)). |
| `GetLimits()` | Return the four limits in a fresh table. |
| `MAX_DEPTH` | `16`: the default of the `maxDepth` limit. |
| `DEFAULT_ARRAY_MAX` | `1024`: the default of the `defaultArrayMax` limit. |
| `UNBOUNDED` | Sentinel `SetLimits{ defaultArrayMax }` accepts to lift the default array bound. |
| `Schema` | The shared prototype of sealed schemas. |

Builders are plain functions and are called with a dot: `SchemaKit.string{ max = 32 }`. Calling one with a colon raises `SchemaKit.string is called with a dot, not a colon`. `Seal` is a method and is called with a colon; calling it with a dot raises `SchemaKit:Seal is called with a colon, not a dot`. Code that uses many builders usually aliases the facade: `local S = SchemaKit`.

Sealed schemas:

| Method | Purpose |
|---|---|
| `Check(value)` | `true`, or `false` and a failure. Allocates nothing for a valid value. |
| `Assert(value, argumentName?, level?)` | Raise a message built from the failure; return `value` when valid. |
| `Apply(value)` | `true` and a copy with defaults filled in, or `false` and a failure. Allocates. |
| `Describe()` | A fresh plain description of the schema. Allocates. |

## Nodes and sealing

A builder validates its spec at your line and returns a **node**: an immutable, opaque description with no methods. A node can be used as a field, an element, a key or value schema, an alternative, or the inner schema of `optional`, and one node can be used in many places. Sealing a node returns a **schema**, which has the methods above.

Sealed schemas are accepted wherever a node is, so a schema sealed by one module can be embedded in another module's schema.

`SchemaKit:Seal(node, options)` accepts:

| Option | Default | Meaning |
|---|---|---|
| `freshFailures` | `false` | Return a new failure table from every failing call instead of the schema's reused one. |

Sealing a sealed schema returns a new schema that shares the compiled checker and has its own failure table and options.

**Contract deviation, recorded.** The planned contract calls builder results "unsealed" and has `Seal` deep-freeze them. A node here is immutable from the moment its builder returns, and a builder copies what it keeps out of your spec (lists, defaults), so there is never a window in which a node shared between modules can be edited before or after sealing. `Seal` therefore freezes nothing further: it gives the compiled node a failure record and options. Later edits to the spec tables you passed have no effect.

### What "sealed" means in Lua 5.1

Nodes and schemas are empty proxy tables. Their metatables refuse writes (`SchemaKit schemas are sealed and cannot be modified`, `SchemaKit schema nodes are immutable`, raised at the writing line) and set `__metatable`, so `setmetatable` refuses to replace them and `getmetatable` returns the name `"SchemaKit.Schema"` or `"SchemaKit.Node"`.

What the seal does not do is hide the compiled checker. It lives in `SchemaKit._state`, which is private **by convention**, like every Kit's `_state`: Lua 5.1 has no way to make a table reachable from shared package state yet unreachable to the addons that share it. Other doors stay open as well: `rawset` still writes a field onto a proxy (shadowing a method on that one proxy), `debug.setmetatable` still replaces a metatable, and the shared `SchemaKit.Schema` prototype is an ordinary table whose methods any addon could replace for everyone. A consumer must not:

- read or write `SchemaKit._state` or anything reachable from it, such as the compiled node behind a proxy (changing its `max` would make every schema using it accept values it refuses);
- write to `SchemaKit.Schema`, the facade, or any proxy with `rawset`;
- replace a proxy's metatable with `debug.setmetatable`.

The seal is a guard against mistakes, not a security boundary between addons, which share one Lua state. SchemaKit recognises its own nodes and schemas by identity in private weak tables, never by `getmetatable`, so an ordinary table shaped like a schema is refused as a receiver or a child.

## Builders

### `SchemaKit.string(spec?)`

| Field | Meaning |
|---|---|
| `min`, `max` | Length bounds in bytes, non-negative integers, `min <= max`. |
| `pattern` | A Lua pattern the string must contain (`string.find`). Anchor it with `^` and `$` to match the whole string. Validated as a whole when the node is built: Lua 5.1 reports a malformed pattern (`"a["`, `"(a"`, `"a%"`, a back-reference to an unclosed capture) only when matching reaches the broken part, so SchemaKit walks the pattern once and refuses it at your line instead of letting `Check` raise later. |
| `oneOf` | A non-empty array of distinct strings; nothing else is accepted. |

Rules: `type`, `enum`, `min`, `max`, `pattern`, checked in that order. The `max` check runs before the pattern, so give strings you receive from other players a `max`. Lua patterns backtrack: a pattern made of single characters and classes without `*`, `+`, `-` or `?` runs in time proportional to the string, but one with several of those items (`(.-)(.-)x`) can take time polynomial in the string's length on a subject that almost matches. The pattern is yours to choose; anchor it with `^` so it is tried from one position only, and keep repeated items few.

### `SchemaKit.number(spec?)`

| Field | Meaning |
|---|---|
| `min`, `max` | Inclusive bounds, numbers that are not NaN, `min <= max`. |
| `integer` | `true` accepts finite whole numbers only. |

Rules: `type` (also for NaN, reported as found `NaN`), `integer`, `min`, `max`.

### `SchemaKit.boolean()`

Accepts `true` and `false`. Takes no arguments.

### `SchemaKit.enum(values)`

`values` is a non-empty array of distinct strings, numbers or booleans (no NaN). Rule `enum`.

### `SchemaKit.table{ fields, open }`

`fields` maps non-empty string names to nodes. Declared fields are checked in sorted name order, so the first failing field reported does not depend on hash order. A field that must be present uses a plain node; a field that may be absent uses `optional`. A closed table (`open` absent or `false`) refuses any other key with rule `unknown`; an open table accepts other keys and does not check them. Fields are read with `rawget`, so a metatable on the value cannot supply or hide one.

### `SchemaKit.array{ of, min, max }`

Keys must be exactly `1..n` (rule `sequence` otherwise), every element must match `of`, and `min <= n <= max` (rules `min` and `max`). `min` defaults to `0`, `max` to the `defaultArrayMax` limit, **1024** unless `SetLimits` changed it. The default exists so that an array schema is bounded even when its author forgot to bound it; raise it explicitly when you need more. The default is read when the node is built.

### `SchemaKit.map{ keys, values, max }`

Every key must match `keys` and every value `values`; at most `max` entries (rule `max`). All three are required: a map is what a hostile message would inflate, so it has no default bound. `keys` cannot be `optional`, since a key is never `nil`. A failing key is reported with `expected` prefixed by `key `.

### `SchemaKit.optional(schema, default?)`

Accepts `nil`, and otherwise checks `schema`. `Check` never fills anything in; `Apply` fills in a fresh deep copy of `default` where the value is `nil`, and then fills the defaults declared inside it. The default is checked against `schema` when the node is built (`SchemaKit.optional default.size: expected number, found string`), must nest at most `maxDepth` tables (16 by default), and is copied, so later edits to your table have no effect. `optional(optional(x))` is refused.

### `SchemaKit.oneOf(alternatives)`

A non-empty array of nodes, tried in order; the first that accepts the value wins. When none does, the failure is reported at the `oneOf` itself with rule `oneOf` and `expected` joining the alternatives (`string or table`). Alternatives cannot be `optional`; wrap the whole `oneOf` instead.

### `SchemaKit.any()`

Any value except `nil`. It does not look inside tables.

### `SchemaKit.custom(check, description)`

`check(value)` returns a truthy value to accept. `description` is what a failure reports as `expected`. `check` is never called with `nil` or a secret. A secret answer (Retail 12.x) rejects the value like a falsy one: the failure has rule `custom` and found the value's type, because testing a secret answer would raise inside SchemaKit. An error raised by `check` propagates out of `Check`, `Assert` or `Apply` unchanged.

## `schema:Check(value)`

Returns `true`, or `false` and a failure:

| Field | Meaning |
|---|---|
| `path` | Where the failure is: `frames[3].point`, `byName["two words"]`, or `""` for the value itself. Names that are identifiers are joined with dots; numbers, booleans and other strings are bracketed; table keys appear as `[table]`. Quoted keys are escaped for display: `|` is doubled (so no World of Warcraft `|T`, `|H` or `|c` escape sequence survives), `\` and `"` are backslash-escaped, and every other control byte appears as `\ddd`. Keys longer than the `pathKeyLimit` limit (32 bytes by default) are cut, never inside a UTF-8 sequence, and marked with `...`. |
| `rule` | The rule that failed (below). |
| `expected` | What the schema accepts there, from the schema's own constants. |
| `found` | A type name or a fixed description such as `larger number`, `string of length 40` or `secret value`. **Never the value.** |

Rules:

| Rule | Meaning |
|---|---|
| `secret` | The value is secret (Retail 12.x). |
| `required` | `nil` where a value is required. |
| `type` | Wrong type, or NaN where a number is expected. |
| `min`, `max` | A number, string length, array length or map size out of bounds. |
| `integer` | A fractional or infinite number where an integer is expected. |
| `pattern` | A string that does not match the pattern. |
| `enum` | A value not in an `enum` or a string `oneOf` list. |
| `unknown` | An undeclared field of a closed table; the path names the field. |
| `sequence` | An array with holes or keys other than `1..n`. |
| `depth` | A table nested deeper than the `maxDepth` limit (16 by default). |
| `oneOf` | No alternative accepted the value. |
| `custom` | A custom check refused the value. |

**The failure table is reused.** Every failing call on one schema returns the same table and overwrites it, so a valid check allocates nothing and a failing check at the root allocates nothing beyond the `found` phrases that carry a count (`string of length N` for a string out of its length bounds, `array of N elements` for an array below its `min`). Read or copy the fields before checking again with that schema, or seal it with `freshFailures = true`. A failure below the root also builds its `path` string.

## `schema:Assert(value, argumentName?, level?)`

Checks `value` and returns it when valid. Otherwise raises:

```text
<argumentName>.<path>: expected <expected>, found <found>
```

(`<argumentName><path>` when the path starts with `[`, and `<argumentName>` alone for a failure at the root). `argumentName` defaults to `"value"`. `level` means what it means to `error` in the function that calls `Assert`: `1` (the default) reports the line that called `Assert`; a Kit validating its own public argument passes `2` to report its caller's line.

## `schema:Apply(value)`

Returns `true` and a copy of `value` with every declared default filled in, or `false` and the failure when the filled copy does not check. `value` is never modified. What is copied:

- tables described by `table`, `array` and `map` are copied, recursively;
- defaults are deep-copied on every call, so two results never share a default table;
- undeclared fields of an open table, and values under `any` or `custom`, are kept as they are (shared, not copied);
- for `oneOf`, the first alternative whose filled copy checks is the one applied.

**Wildcard defaults.** A map's `values` or an array's `of` may be `optional(schema, default)`. Every entry present is filled from `schema`'s own defaults, and `Describe` publishes `default` as the value for a new entry, which is what a settings layer materialises for a key it has not seen (AceDB's `["*"]`). `Apply` itself cannot invent keys that are not there.

`Apply` allocates: a new table per copied table and a copy per default used. It is bounded like `Check`, with one difference: `Check` never looks at the undeclared fields of an open table, while `Apply` walks all of them to keep them in the copy, so give an open table you receive from other players a closed schema instead.

## `schema:Describe()`

Returns a fresh plain table on every call; edit it freely.

| Field | Present for |
|---|---|
| `kind` | Always: `string`, `number`, `boolean`, `enum`, `table`, `array`, `map`, `oneOf`, `any` or `custom`. |
| `optional`, `default` | An `optional` node. The wrapper is folded into the description of its inner schema; `default` is a fresh copy. |
| `min`, `max`, `pattern`, `oneOf` | `string`. |
| `min`, `max`, `integer` | `number`. |
| `values` | `enum`: the values in declaration order. |
| `fields`, `fieldNames`, `open` | `table`: descriptions by name, and the names sorted. |
| `of`, `min`, `max` | `array` (`max` is present unless the array was built without one while `defaultArrayMax` was `SchemaKit.UNBOUNDED`). |
| `keys`, `values`, `max` | `map`. |
| `alternatives` | `oneOf`. |
| `description` | `custom`. |

## Bounds

| Bound | Value | Rule |
|---|---|---|
| Nested tables in a checked value, counting the outermost | `maxDepth`, 16 by default (`SchemaKit.MAX_DEPTH`) | `depth` |
| Array elements | `max`, default `defaultArrayMax`, 1024 by default (`SchemaKit.DEFAULT_ARRAY_MAX`) | `max` |
| Map entries | `max`, required | `max` |
| Undeclared keys of a closed table | stops at the first | `unknown` |

An array or map is counted with `next` and refused one step past its bound, before any element is checked, so an oversized table costs `max + 1` steps however large it is. A closed table's keys are walked only until the first undeclared one. The depth bound holds however the schema is nested: a schema may describe deeper tables, but a value is never followed past `maxDepth`.

## Limits

Four limits are package-wide and set through `SetLimits`; the bounds a schema author writes (`max` on strings, numbers, arrays and maps) are options on the node and need nothing here.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxDepth` | `16` | `SchemaKit:SetLimits{ maxDepth = n }` | no | `64`: checking, `Apply` and default validation recurse once per nesting level of a value its sender shapes. |
| `maxPatternCaptures` | `32` | `SchemaKit:SetLimits{ maxPatternCaptures = n }` (lower only) | no | `32`: Lua 5.1 raises `too many captures` on a pattern with more (the matcher's fixed capture limit), so a larger value would let `Check` raise. |
| `pathKeyLimit` | `32` | `SchemaKit:SetLimits{ pathKeyLimit = n }` | no | `1024`: failure paths print keys a received message chooses. |
| `defaultArrayMax` | `1024` | `SchemaKit:SetLimits{ defaultArrayMax = n }` | yes | none: the elements are already in memory and SchemaKit retains none of them. |
| `map` `max` | none | required on every map | no | a map is what a hostile message inflates, so its bound is always the author's. |

```lua
SchemaKit:SetLimits({ maxDepth = 24, defaultArrayMax = SchemaKit.UNBOUNDED })
local limits = SchemaKit:GetLimits() -- a fresh table
```

`SetLimits` accepts any subset and checks every entry before it changes anything, so a refused call changes no limit. It raises at the caller's line on a non-table, an unknown name (`SchemaKit:SetLimits limits.maxWidth is not a recognised limit`), a value outside 1 to the ceiling (`SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64`, with `: <reason>` appended when the value is an integer above the ceiling), a `defaultArrayMax` that is neither a positive integer nor the sentinel (`SchemaKit:SetLimits limits.defaultArrayMax must be a positive integer or SchemaKit.UNBOUNDED`), `SchemaKit.UNBOUNDED` where the table says no (`SchemaKit:SetLimits limits.maxDepth cannot be SchemaKit.UNBOUNDED: <reason>`), and a dot call. A secret value (Retail 12.x) is refused before it is compared with anything, with the message an invalid value of that limit gets: `SchemaKit:SetLimits limits.maxDepth must be an integer from 1 to 64` for a limit with a ceiling, `SchemaKit:SetLimits limits.defaultArrayMax must be a positive integer or SchemaKit.UNBOUNDED` otherwise. `GetLimits` returns a new table on every call; `defaultArrayMax` reads back as `SchemaKit.UNBOUNDED` when it was set to it.

**The limits are shared by every consumer in the session**: every embedded copy and every addon uses one set. A library should rely on the defaults; an addon that changes a limit changes it for everybody. `maxDepth` and `pathKeyLimit` apply from the next check, to every schema. `maxPatternCaptures` and `defaultArrayMax` apply to nodes built after the change; a node keeps what it was built with. A pattern refused by a lowered `maxPatternCaptures` raises `SchemaKit.string pattern is not a valid Lua pattern`.

An array built without `max` while `defaultArrayMax` is `SchemaKit.UNBOUNDED` accepts any number of elements, and checking it walks every one: give arrays that hold received data an explicit `max`. `SchemaKit.UNBOUNDED` is one table kept in the package state, so every copy and revision publishes the same sentinel.

## Secret values

On Retail 12.x the client hands tainted code **secret values**, which raise when compared, tested, indexed or used as a table key (see [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)). Every node asks `issecretvalue(value)` first, before any comparison, type test or index, and a secret fails with rule `secret` and found `secret value`. The failure and the `Assert` message never contain it. `Apply` keeps a secret where it found it and the check of the copy reports it. Custom checks are never called with a secret, and a secret answer from one rejects the value with rule `custom` (see [`SchemaKit.custom`](#schemakitcustomcheck-description)).

The boolean flags `SchemaKit.number{ integer }`, `SchemaKit.table{ open }` and `Seal`'s `freshFailures` are asked about with `issecretvalue` before they are tested. A secret flag is refused at the caller's line with the message an invalid value of that flag gets (`SchemaKit.number integer must be a boolean`, `SchemaKit.table open must be a boolean`, `SchemaKit:Seal freshFailures must be a boolean`), the style `SetLimits` uses for a secret limit.

Every other builder and `Assert` argument that SchemaKit would compare, look up or do arithmetic on is asked about the same way first, and a secret is refused at the caller's line with the message an invalid value gets:

| Argument | Message for a secret |
|---|---|
| `string{ min, max }`, `array{ min, max }` | `SchemaKit.<builder> min must be a non-negative integer` (or `max`) |
| `number{ min, max }` | `SchemaKit.number min must be a number` (or `max`) |
| `map{ max }` | `SchemaKit.map max must be a positive integer` |
| `string{ pattern }` | `SchemaKit.string pattern must be a non-empty string` |
| a literal in `string{ oneOf }` or `enum(values)` | `SchemaKit.string oneOf values must be strings, numbers or booleans`, `SchemaKit.enum values must be strings, numbers or booleans` |
| `custom(check, description)`'s `description` | `SchemaKit.custom description must be a non-empty string` |
| `Assert`'s `argumentName` | `SchemaKit.Schema:Assert argumentName must be a non-empty string` |
| `Assert`'s `level` | `SchemaKit.Schema:Assert level must be a positive integer` |

Without the probe first, a secret bound would raise inside SchemaKit at `min > max` or the NaN test, a secret literal at the NaN test or the set lookup that uses it as a key, a secret `argumentName` at the empty-string test and a secret `level` at the integer test. Plain values pay one `issecretvalue` call each, at build time or per `Assert` call.

## Cookbook

### A settings schema

Saved variables: defaults for everything the user did not change, per-entry defaults for a map keyed by spell, and bounds everywhere.

```lua
local S = SchemaKit

local Aura = S.table({
  fields = {
    shown = S.optional(S.boolean(), true),
    color = S.optional(S.array({ of = S.number({ min = 0, max = 1 }), min = 3, max = 4 }), { 1, 1, 1 }),
    sound = S.optional(S.string({ max = 64 })),
  },
})

local Settings = SchemaKit:Seal(S.table({
  fields = {
    version = S.optional(S.number({ integer = true, min = 1 }), 1),
    scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
    anchor = S.optional(S.string({ oneOf = { "TOP", "CENTER", "BOTTOM" } }), "CENTER"),
    auras = S.optional(S.map({ keys = S.number({ integer = true }), values = S.optional(Aura, {}), max = 256 }), {}),
  },
}))

local ok, settings = Settings:Apply(MyAddonDB)
if not ok then
  local failure = settings
  print("MyAddon settings ignored at " .. failure.path .. ": " .. failure.rule)
  ok, settings = Settings:Apply({}) -- every default
end
```

`Settings:Describe().fields.auras.values.default` is `{}`: the wildcard default for an aura the user has not configured yet.

### An options schema

An options screen needs the type, the bounds and the default of each setting, and a validator for what the user types. Both come from one schema.

```lua
local Options = SchemaKit:Seal(S.table({
  fields = {
    fontSize = S.optional(S.number({ integer = true, min = 8, max = 32 }), 12),
    outline = S.optional(S.enum({ "NONE", "OUTLINE", "THICKOUTLINE" }), "NONE"),
    label = S.optional(S.string({ max = 24, pattern = "^[%w ]*$" }), ""),
  },
}))

local description = Options:Describe()
for _, name in ipairs(description.fieldNames) do
  local field = description.fields[name]
  -- field.kind == "number": a slider from field.min to field.max, step 1 when field.integer
  -- field.kind == "enum":   a dropdown over field.values
  -- field.kind == "string": an edit box limited to field.max characters
  -- field.default:          the reset value
end

local FontSize = SchemaKit:Seal(S.number({ integer = true, min = 8, max = 32 }))
local function onFontSizeEntered(value)
  local ok, failure = FontSize:Check(tonumber(value))
  if not ok then
    return false, "expected " .. failure.expected
  end
  return true
end
```

### A message payload schema

A received message is hostile until checked: every string and collection is bounded, the table is closed, and the check happens before anything reads the payload.

```lua
local Payload = SchemaKit:Seal(S.table({
  fields = {
    kind = S.enum({ "hello", "cooldowns" }),
    version = S.number({ integer = true, min = 1, max = 1000 }),
    sender = S.string({ min = 2, max = 64 }),
    cooldowns = S.optional(S.map({
      keys = S.number({ integer = true, min = 1 }),
      values = S.number({ min = 0, max = 86400 }),
      max = 64,
    })),
  },
}))

local function onPayload(payload)
  local ok, failure = Payload:Check(payload)
  if not ok then
    -- Safe to log: the failure never contains the payload's values.
    debugLog("dropped message: " .. failure.path .. " " .. failure.rule .. " (" .. failure.found .. ")")
    return
  end
  handle(payload)
end
```

## Error behaviour

Builder, `Seal` and method argument failures report the line that called them, never a line inside SchemaKit, and name the parameter without formatting the value. The complete list, where `<builder>` is `string`, `number`, `table`, `array` or `map` and `<Method>` is `Check`, `Assert`, `Apply` or `Describe`:

| Raised by | Messages |
|---|---|
| Every builder | `SchemaKit.<builder> is called with a dot, not a colon`, for every builder name |
| Builders taking a spec | `SchemaKit.<builder> spec must be a table`; `SchemaKit.<builder> spec contains unknown field "<field>"` (the alphabetically first unknown field) |
| `string` | `SchemaKit.string min must be a non-negative integer` (and `max`); `SchemaKit.string min must not be greater than max`; `SchemaKit.string pattern must be a non-empty string`; `SchemaKit.string pattern is not a valid Lua pattern`; `SchemaKit.string oneOf must be an array`, `... must be an array without holes or other keys`, `... must not be empty`; `SchemaKit.string oneOf must list strings only`; `SchemaKit.string oneOf values must not repeat` |
| `number` | `SchemaKit.number integer must be a boolean`; `SchemaKit.number min must be a number` (and `max`; NaN is refused too); `SchemaKit.number min must not be greater than max` |
| `boolean`, `any` | `SchemaKit.boolean takes no arguments`; `SchemaKit.any takes no arguments` |
| `enum` | `SchemaKit.enum values must be an array`, `... must be an array without holes or other keys`, `... must not be empty`; `SchemaKit.enum values must be strings, numbers or booleans`; `SchemaKit.enum values must not be NaN`; `SchemaKit.enum values must not repeat` |
| `table` | `SchemaKit.table fields must be a table of schema nodes by name`; `SchemaKit.table open must be a boolean`; `SchemaKit.table field names must be non-empty strings`; `SchemaKit.table fields.<name> must be a SchemaKit schema node or sealed schema` |
| `array` | `SchemaKit.array of must be a SchemaKit schema node or sealed schema`; `SchemaKit.array min must be a non-negative integer` (and `max`); `SchemaKit.array min must not be greater than max` |
| `map` | `SchemaKit.map keys must be a SchemaKit schema node or sealed schema` (and `values`); `SchemaKit.map keys must not be optional`; `SchemaKit.map max is required`; `SchemaKit.map max must be a positive integer` |
| `optional` | `SchemaKit.optional schema must be a SchemaKit schema node or sealed schema`; `SchemaKit.optional schema is already optional`; `SchemaKit.optional default nests deeper than <maxDepth> tables`; `SchemaKit.optional default<path>: expected <expected>, found <found>` (the default's own failure, formatted as by `Assert`) |
| `oneOf` | `SchemaKit.oneOf alternatives must be an array`, `... must be an array without holes or other keys`, `... must not be empty`; `SchemaKit.oneOf alternatives[<index>] must be a SchemaKit schema node or sealed schema`; `SchemaKit.oneOf alternatives must not be optional; wrap the oneOf instead` |
| `custom` | `SchemaKit.custom check must be a function`; `SchemaKit.custom description must be a non-empty string` |
| `Seal` | `SchemaKit:Seal is called with a colon, not a dot`; `SchemaKit:Seal node must be a SchemaKit schema node or sealed schema`; `SchemaKit:Seal options must be a table`; `SchemaKit:Seal options contains unknown field "<field>"`; `SchemaKit:Seal freshFailures must be a boolean` |
| Schema methods | `SchemaKit.Schema:<Method> must be called on a sealed SchemaKit schema`; `SchemaKit.Schema:Assert argumentName must be a non-empty string`; `SchemaKit.Schema:Assert level must be a positive integer` |
| Writes | `SchemaKit schemas are sealed and cannot be modified`; `SchemaKit schema nodes are immutable` (raised at the writing line) |
| `SetLimits`, `GetLimits` | `SchemaKit:SetLimits limits must be a table`; `SchemaKit:SetLimits is called with a colon, not a dot` (and `GetLimits`); the value messages listed under [Limits](#limits) |

## Performance

| Operation | Cost |
|---|---|
| Building a node, sealing | Load time; allocates the node. |
| `Check`, `Assert` on a valid value | O(size of the value as the schema describes it); no allocation. |
| `Check` failing at the root | The failure table is reused; only a `string of length N` or `array of N elements` phrase is built. |
| `Check` failing below the root | Also builds the path string, and `key <expected>` for a failing map key. |
| `Apply`, `Describe` | Allocate their results. |

Each node costs one function call plus one `issecretvalue` call when the client has it. The compiled form behind these numbers is in [`INTERNALS.md`](INTERNALS.md).

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **Nodes are immutable from birth** rather than frozen by `Seal`; see [Nodes and sealing](#nodes-and-sealing).
- **`Apply` returns `true, copy` or `false, failure`** rather than the copy alone. An `optional` root without a default legitimately applies to `nil`, so a bare return value could not tell a valid `nil` from a failure; the pair has the same shape as `Check`.
- **The depth bound is enforced on values, not on schemas.** `Seal` does not refuse a schema that describes more nested tables than the `maxDepth` limit (16 by default); a value is simply never followed past `maxDepth`, and the deeper levels of such a schema can never accept anything.
- **Additions:** `SchemaKit.MAX_DEPTH` and `SchemaKit.DEFAULT_ARRAY_MAX` publish the two defaults, `SetLimits`, `GetLimits` and `UNBOUNDED` open the limits (principle 4a), and `Assert` returns the value it checked so it can be used inline.

## Embedded copies and upgrades

Several addons may embed SchemaKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: nodes and schemas built by an older copy keep their compiled form and failure tables, compose with nodes built by the newer copy, and run the newer checker. The shared limits and the `UNBOUNDED` sentinel live in the package state, so a newer revision inherits the limits a consumer set.

Nothing survives `/reload`: schemas are rebuilt when the addon loads.
