# CompatKit

CompatKit is the compatibility plumbing World of Warcraft addons keep rewriting:
**shims** applied once per session with the newest version winning across
embedded copies and a host opt-out by name (TaintLess's model), **provider
registries** with liveness probes and a deterministic fallback cascade that
output-routing consumers share (LibSink's model), and the **catalogue** of
taint-hostile Blizzard subsystems with their sanctioned replacements, as data
rather than folklore.

```lua
local CompatKit = MoltenCodes.Registries[2]:Get("compatKit", 1)

-- A shim: named, versioned, run at most once per session by Apply.
CompatKit:Shim("MyAddon.FixDropDownTaint", 3, function(context)
  if context.hasGlobal("UIDropDownMenu_InitializeHelper") then
    -- ... a post-hook, never a replacement (see docs/EMBEDDING.md, Taint)
  end
end, { description = "Keeps UIDropDownMenu's globals secure", flavours = { "mainline" } })

-- A provider registry: whoever prints output, resolved by priority and liveness.
local outputs = CompatKit:Providers("output")
outputs:Register("chat", function(text)
  DEFAULT_CHAT_FRAME:AddMessage(text)
end)
outputs:Register("window", function(text)
  MyAddonWindow:Append(text)
end, function()
  return MyAddonWindow ~= nil and MyAddonWindow:IsShown()
end, 10)

-- Later, at PLAYER_LOGIN: run every pending shim, then route output.
local applied, skipped, failed = CompatKit:Apply()
local output, providerName = outputs:Resolve()
```

What it offers:

- **Shims** — `Shim(name, version, implementation, options?)` records a shim;
  before `Apply` the highest version registered under a name wins whichever
  embedded copy registered it, and equal or lower versions are ignored.
  `Apply()` runs every pending shim once, in name order, isolated: a failing
  shim is reported through the host error handler and recorded, and the others
  still run. A second `Apply` runs only shims registered since. `SkipShim(name)`
  is the host's opt-out, honoured before or after the registration (a skip
  waiting for its shim takes a `maxShims` slot until it arrives).
  `GetShims()` lists every shim with its version, the version that ran, its
  status and its options. Each shim receives a read-only context:
  `flavour` (from ClientKit when it is loaded), `hasApi(name)` (whether
  ApiKit's installed surface binds the documented function) and
  `hasGlobal(name)`.
- **Providers** — `Providers(kind)` returns one registry per kind.
  `Register(name, implementation, probe?, priority?)` adds a provider,
  `Resolve(preferred?)` returns a live one: the preferred provider when it is
  alive, else the memoised answer as long as its probe still says alive, else
  the highest-priority live provider with ties broken by name. `Resolve`
  allocates nothing. `Unregister(name)` and `List()` complete the surface.
- **Catalogue** — `CompatKit.CATALOGUE` mirrors the table in
  [`docs/EMBEDDING.md`](../../docs/EMBEDDING.md#catalogue-of-taint-hostile-subsystems):
  for each subsystem, why it taints, the sanctioned replacement and, when the
  replacement is a documented client API, the apiKit flavours whose metadata
  documents it. A tooling test holds the two tables and the metadata together.
- **Limits** — `SetLimits{ maxShims, maxProviders, maxProviderKinds }`
  (defaults 64, 32 per kind, 32 kinds), every one of them opened with
  `CompatKit.UNBOUNDED`; `GetLimits()` reads them back.

ClientKit and ApiKit are optional: without ClientKit every shim applies and
`context.flavour` is `false`; without ApiKit `hasApi` answers `false` for
everything and `hasGlobal` remains the host probe. Neither adds an edge to the
load order. Everything is load-time work apart from `Resolve`.

## Shims in practice

```lua
-- Two addons embed the same shim at different versions. Whichever loads
-- first, version 2 is the one Apply runs, exactly once.
CompatKit:Shim("SharedLib.FixTooltips", 1, function() end) -- true, "pending"
CompatKit:Shim("SharedLib.FixTooltips", 2, function() end) -- true, "replaced"
CompatKit:Shim("SharedLib.FixTooltips", 1, function() end) -- false, "ignored"

-- A shim that names the documented APIs it relates to. When ApiKit is loaded,
-- Apply records in the shim's `missing` field which of them the installed
-- surface lacks; the shim itself asks context.hasApi before relying on one.
CompatKit:Shim("SharedLib.TooltipData", 1, function(context)
  if not context.hasApi("C_TooltipInfo.GetUnit") then
    return -- nothing to do on this client
  end
end, { covers = { "C_TooltipInfo.GetUnit" } })

-- The host (the addon that owns the session) switches one off by name.
CompatKit:SkipShim("SharedLib.FixTooltips")

for _, shim in ipairs(CompatKit:GetShims()) do
  print(shim.name, shim.version, shim.status, shim.applied)
end
```

Shims are applied once. A higher version registered after `Apply` ran is
recorded (`version` moves, `applied` keeps the version that ran) but not run:
running a second implementation over a first one is what shims exist to avoid.

## Providers in practice

```lua
local sinks = CompatKit:Providers("sink")
sinks:Register("chat", "chat-sink") -- priority 0, always alive
sinks:Register("bag", "bag-sink", function()
  return BagWindow and BagWindow:IsShown() or false
end, 5)

local sink, name = sinks:Resolve() -- "bag-sink", "bag" while the window shows
sink, name = sinks:Resolve("chat") -- "chat-sink", "chat": a live preferred wins
sink, name = sinks:Resolve("gone") -- falls through to the cascade

for _, row in ipairs(sinks:List()) do
  print(row.name, row.priority, row.alive)
end
```

The memo is stable while alive: once the cascade chose `chat` because `bag`
was hidden, `Resolve()` keeps answering `chat` until `chat` dies, even after
`bag` shows again. Consumers that want the best provider at every call pass it
as `preferred`.

## Organisation

| Path | Contents |
|---|---|
| `src/CompatKit.lua` | The facade: shims, providers, limits, catalogue. |
| `docs/API.md` | The complete contract: every method, result, error and cost. |
| `docs/INTERNALS.md` | State layout and invariants for maintainers. |
| `tests/` | Busted specs; `tests/README.md` lists what they cover. |

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\compatKit\CompatKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `compatKit/CompatKit.lua`.

Direct runtime dependencies: Registry API 2. Optional, found at call time
through `Registry:Find`: ClientKit API 1 (the flavour shims are filtered on)
and ApiKit API 1 with the flavour file of your client (`hasApi`); both may load
before or after this file. Call `Apply` after every file that registers a shim
has loaded, for example from your `PLAYER_LOGIN` handler.
