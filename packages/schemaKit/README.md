# SchemaKit

SchemaKit is one validation core for the values a Kit or an addon receives from outside its own code: API arguments, saved variables, options and received messages. You describe a value once with builders, seal the description, and then check values against it. A failure says where, which rule, what was expected and what was found, and it never contains the value itself, so it is safe to print even when the value was a secret.

```lua
local SchemaKit = MoltenCodes.Registries[2]:Get("schemaKit", 1)
local S = SchemaKit

local BarSettings = SchemaKit:Seal(S.table({
  fields = {
    enabled = S.optional(S.boolean(), true),
    scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
    anchor = S.optional(S.string({ oneOf = { "TOP", "BOTTOM" } }), "TOP"),
    buttons = S.optional(S.array({ of = S.number({ integer = true }), max = 12 }), {}),
  },
}))

local ok, failure = BarSettings:Check(saved)
if not ok then
  print(failure.path, failure.rule, failure.expected, failure.found)
  -- scale   max   number <= 2   larger number
end

local applied, settings = BarSettings:Apply(saved) -- a copy with the defaults filled in

function MyBar:Configure(options)
  BarSettings:Assert(options, "MyBar:Configure options", 2)
  -- MyBar:Configure options.scale: expected number <= 2, found larger number
end
```

What each piece promises:

- **Builders** (`S.string`, `S.number`, `S.boolean`, `S.enum`, `S.table`, `S.array`, `S.map`, `S.optional`, `S.oneOf`, `S.any`, `S.custom`) validate their own spec at your line and return an immutable node. Nodes and sealed schemas compose: any of them can be a field, an element or an alternative of another.
- **`SchemaKit:Seal(node, options)`** returns a sealed schema. It refuses writes, cannot have its metatable replaced, and is safe to share between addons.
- **`schema:Check(value)`** returns `true`, or `false` and a failure `{ path, rule, expected, found }`. A valid value costs no allocation. The failure table is reused by every failing call on that schema unless you seal with `freshFailures = true`.
- **`schema:Assert(value, argumentName, level)`** raises `argumentName.path: expected ..., found ...` at the line you choose, and returns the value when it is valid.
- **`schema:Apply(value)`** returns `true` and a copy with every declared default filled in, or `false` and the failure. It allocates, by design.
- **`schema:Describe()`** returns a fresh plain table describing the schema, for documentation and options screens.
- **Bounded, opened on purpose.** `SchemaKit:SetLimits{}` raises the depth (ceiling 64), path-key and default array limits, and `SchemaKit.UNBOUNDED` lifts the default array bound; see *Limits* in the API.
- **Bounded.** A checked value may nest at most 16 tables by default (the `maxDepth` limit; rule `"depth"`); an array holds at most its `max` elements (1024 unless you say otherwise) and a map at most its required `max` entries (rule `"max"`). Oversized input is refused after `max + 1` steps, so a hostile message cannot make validation unbounded.
- **Secret values** (Retail 12.x) are refused with rule `"secret"` before anything else touches them, whenever the client has `issecretvalue`.

See [`docs/API.md`](docs/API.md) for the complete contract and a cookbook, and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the compiled form.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\schemaKit\SchemaKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `schemaKit/SchemaKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.

SchemaKit has no optional dependencies. The one host facility it reads,
`issecretvalue`, is looked up at every check; on a client without it nothing is
treated as secret.
