# SignalKit

SignalKit is the framework's small, deterministic observer primitive for pure-Lua communication.

It is intentionally independent from World of Warcraft's event system. Higher-level packages can use SignalKit for lifecycle notifications, state changes, completion callbacks, and internal framework events without coupling themselves to Frames or `RegisterEvent`.

## Why SignalKit exists

Callback dispatch is easy to duplicate and surprisingly easy to get wrong once callbacks can mutate the listener set or recursively dispatch the same signal.

SignalKit centralizes those semantics:

- listeners run in connection order;
- disconnects take effect immediately;
- listeners connected during a `Fire()` wait until the next non-nested dispatch;
- a nested `Fire()` sees the listener set as it exists when that nested call begins;
- `Once()` disconnects before callback invocation;
- callback errors propagate to the caller and abort that dispatch;
- `Fire()` does not clone the listener array or allocate a dispatch snapshot;
- calling a signal or connection method without its receiver is reported as a
  SignalKit error at the calling line.

## Example

```lua
local Registry = MoltenCodes.Registry
local SignalKit = Registry:Get("signalKit", 1)

local changed = SignalKit:New()

local connection = changed:Connect(function(unit, value)
    print(unit, value)
end)

changed:Fire("player", 42)
connection:Disconnect()
```

## Runtime dependency

SignalKit depends on Registry API 2 only for embedded-package identity and revision selection. Its callback implementation uses standard Lua only and has no WoW API dependency.

Registry must be loaded before `SignalKit.lua`.

## Performance model

Dispatch is optimized for the common pattern where signals fire more often than listeners are added or removed.

`Fire()` captures the current listener-array reference and its length without allocating a copy. `Connect()` appends in `O(1)`; an in-progress dispatch keeps its original length boundary, so the new listener is deferred.

`Disconnect()` marks the shared connection inactive in `O(1)` without allocating, so in-progress dispatches skip it immediately. The handle stays in the listener array as a tombstone until at least half the array is tombstones, at which point the array is compacted. Disconnection is therefore amortized `O(1)` and the array never retains more than twice the live listener count.

This keeps the hot dispatch path allocation-free while making both connection and bulk teardown cheap and deterministic. See [`docs/API.md`](docs/API.md) for measured numbers.

## Documentation

- [`docs/API.md`](docs/API.md) — complete API and mutation semantics.
- [`CHANGELOG.md`](CHANGELOG.md) — package evolution.
- [`tests/README.md`](tests/README.md) — behavior covered by executable specs.
