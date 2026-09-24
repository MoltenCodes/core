# ProfileKit

ProfileKit measures the framework and its consumers inside the World of Warcraft
client. Code marks named **sections**; each section counts its calls and keeps
the total time, the worst single call (the spike) and the last call. A report
lists every section sorted by total time.

```lua
local ProfileKit = MoltenCodes.Registries[2]:Get("profileKit", 1)
local onUpdate = ProfileKit:Section("MyAddon.OnUpdate") -- once, at file scope

frame:SetScript("OnUpdate", function(_, elapsed)
    onUpdate:Begin()
    MyAddon:Refresh(elapsed)
    onUpdate:End()
end)

local rebuilt = ProfileKit:Measure("MyAddon.Rebuild", MyAddon.Rebuild, MyAddon)

ProfileKit:Enable() -- from a slash command or a debug build, never by default
-- ...
for _, row in ipairs(ProfileKit:Report()) do
    print(row.name, row.count, row.total, row.max, row.last)
end
```

Three contracts are worth knowing before the first section:

- **Zero cost when off.** ProfileKit loads disabled. While disabled, `Begin`,
  `End` and `Measure` are no-op functions (`Measure` just calls `fn`), swapped
  in and out on the shared section prototype by `Disable` and `Enable`. A
  disabled caller pays one table read and one call; nothing branches on a flag
  and nothing allocates.
- **Milliseconds of addon CPU time.** Every time is read from
  `debugprofilestop`. A client hitch that stalls the frame is not charged to a
  section. On a host without `debugprofilestop`, `Enable()` returns
  `false, "unavailable"` and ProfileKit stays disabled.
- **Bounded.** By default at most `ProfileKit.DEFAULT_MAX_SECTIONS` (256) sections exist
  per session. A further name gets `nil, "capped"` from `Section`, and `Measure`
  runs it unmeasured. Open it on purpose with
  `ProfileKit:SetLimits({ maxSections = n })` or `ProfileKit.UNBOUNDED`.

Not in scope: memory profiling, per-frame graphs, sampling, and anything that
ships enabled.

See [`docs/API.md`](docs/API.md) for the complete contract.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\profileKit\ProfileKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `profileKit/ProfileKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load. `debugprofilestop` is optional: without it the package loads and stays
disabled.
