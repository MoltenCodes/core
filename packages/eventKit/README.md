# EventKit

EventKit is MoltenCodes' World of Warcraft event bridge. It turns Frame `OnEvent` notifications into deterministic SignalKit-backed subscriptions while keeping Frame registration lazy and scoped to active listeners.

## Package contract

- Package: `eventKit`
- Version: `0.2.1`
- API generation: `1`
- Implementation revision: `2`
- Runtime dependencies: Registry API 2, SignalKit API 1

EventKit is multi-tenant: one shared instance serves every addon in a WoW
session. That shapes three of its guarantees:

- **Listeners are isolated.** One addon's erroring handler is reported through
  the host error handler and never stops delivery to the others.
- **Unit-filter Frames are bounded and reused.** A unit group is released when
  its last listener goes and its Frame returns to a free list; EventKit creates
  at most 64 Frames for unit filters in a session.
- **`ConnectUnit` accepts at most two unit tokens**, because
  `Frame:RegisterUnitEvent` has two filter slots. A third is an error rather
  than something the client silently drops.

## Example

```lua
local Registry = MoltenCodes.Registry
local EventKit = Registry:Get("eventKit", 1)

local connection = EventKit:Connect("PLAYER_LOGIN", function(eventName)
    print("Logged in via", eventName)
end)

-- Later:
connection:Disconnect()
```

Unit-filtered events use the same connection lifecycle:

```lua
local health = EventKit:ConnectUnit("UNIT_HEALTH", function(eventName, unit)
    print(eventName, "for", unit)
end, "player")
```

See [`docs/API.md`](docs/API.md) for the full public contract and edge-case
semantics, including the combat-log event's empty payload, the taint
consequences of a shared bus, and the measured cost of listener isolation.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
```

Direct runtime dependencies: Registry API 2, SignalKit API 1.
Every file above is required; omitting one makes this package raise at
load.
