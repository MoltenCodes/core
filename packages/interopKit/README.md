# InteropKit

InteropKit is the bridge between the MoltenCodes Registry and LibStub. It makes
a Kit reachable by LibStub consumers, and a LibStub library reachable from
MoltenCodes code through one silent lookup, so an addon that embeds our Kits
beside LibDataBroker, LibSharedMedia or CallbackHandler needs one lookup idiom
rather than two.

```lua
local InteropKit = MoltenCodes.Registries[2]:Get("interopKit", 1)

-- Publish EventKit to LibStub consumers: LibStub("MoltenCodes-EventKit-1").
local ok, majorOrReason = InteropKit:ExposeToLibStub("eventKit", 1)

-- Or every Kit this addon loaded, except the ones you keep private.
local exposed, skipped, refused = InteropKit:ExposeAll({ except = { "hookKit" } })
```

What it offers:

- **Exposing** — `ExposeToLibStub(packageName, api, major)` registers the
  Kit's shared facade under `major` (default `"MoltenCodes-<Facade>-<api>"`)
  with the implementation revision as the minor. It is idempotent, a newer
  revision exposes again with the higher minor, and a major another library
  already holds is refused with `false, "taken"` without touching that library.
  `ExposeAll(options)` does this for every active Kit Registry lists.
- **Adopting** — `AdoptFromLibStub(major)` returns a LibStub library and its
  minor, or `nil, "absent"` / `nil, "unknown"`, and records it; `Find(major)`
  reads that record later with the same results, without LibStub and without
  allocating; `Adopted()` lists every adoption for diagnostics.
- **Presence** — `IsLibStubPresent()`.

LibStub is optional: without it every call answers `"absent"` and nothing
raises. InteropKit never upgrades, wraps or writes into a LibStub library, and
its one write into LibStub's own tables is documented in
[`docs/API.md`](docs/API.md#what-the-bridge-does-to-libstub).

## LibDataBroker through the bridge

```lua
-- Core.lua, after LibStub, LibDataBroker-1.1 and the MoltenCodes files load.
local Registry = MoltenCodes.Registries[2]
local InteropKit = Registry:Get("interopKit", 1)
local EventKit = Registry:Get("eventKit", 1)

local broker = InteropKit:AdoptFromLibStub("LibDataBroker-1.1")
if broker ~= nil then
    local feed = broker:NewDataObject("MyAddon", { type = "data source", text = "0" })
    EventKit:Connect("PLAYER_MONEY", function()
        feed.text = tostring(GetMoney())
    end)
end
```

```lua
-- Any later file: the adoption is read with the silent contract of
-- Registry:Find, without asking LibStub again.
local broker = InteropKit:Find("LibDataBroker-1.1")
if broker ~= nil then
    local feed = broker:GetDataObjectByName("MyAddon")
end
```

A missing LibDataBroker leaves `broker` `nil` and the addon keeps working; no
branch needs `LibStub` itself.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\interopKit\InteropKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `interopKit/InteropKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load. LibStub is not a dependency: InteropKit finds it through
`rawget(_G, "LibStub")` on every call, so LibStub and the libraries you adopt
may load before or after this file. Expose a Kit after the Kit's own file has
loaded.
