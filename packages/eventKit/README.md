# EventKit

EventKit is MoltenCodes' World of Warcraft event bridge. It turns Frame `OnEvent` notifications into deterministic SignalKit-backed subscriptions while keeping Frame registration lazy and scoped to active listeners.

## Package contract

- Package: `eventKit`
- Version: `0.1.0`
- API generation: `1`
- Implementation revision: `1`
- Runtime dependencies: Registry API 2, SignalKit API 1

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

See [`docs/API.md`](docs/API.md) for the full public contract and edge-case semantics.
