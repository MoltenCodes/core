# SignalKit API

Package: `signalKit`  
API generation: `1`  
Implementation revision: `1`

SignalKit provides deterministic callback dispatch with explicit connection lifetimes.

SignalKit instances and connection handles are opaque runtime objects. Only members documented in this file are public API; underscore-prefixed storage fields are private implementation detail and must not be read or mutated by consumers.

## Access

`SignalKit.lua` registers through Registry API 2. Registry must already be loaded.

Portable WoW runtime access is:

```lua
local Registry = MoltenCodes.Registry
local SignalKit = Registry:Get("signalKit", 1)
```

The source file also returns the same shared package table for pure-Lua test/module environments. Runtime code must not require module loading as its bootstrap mechanism.

## `SignalKit:New()`

Creates an independent signal instance.

```lua
local changed = SignalKit:New()
```

`SignalKit.New()` is also accepted, but colon syntax is the canonical form.

## `signal:Connect(callback)`

Connects `callback` and returns a connection handle.

```lua
local connection = changed:Connect(function(value)
    print(value)
end)
```

`callback` must be a function.

Multiple connections may use the same function. Each connection is independent and occupies its own position in deterministic connection order.

## `signal:Once(callback)`

Connects a callback that can run at most once.

The connection is disconnected **before** callback invocation. Therefore a recursive `Fire()` triggered by that callback cannot invoke the same once-listener again.

## `signal:Fire(...)`

Invokes currently eligible listeners in connection order and forwards all arguments exactly, including `nil` values.

Callback return values are ignored.

### Mutation semantics

Each `Fire()` captures the active listener-array identity **and its current length** at the beginning of that call.

- A listener connected during that `Fire()` is appended beyond the captured length and is not invoked by that dispatch.
- A listener disconnected before its turn is skipped immediately.
- `DisconnectAll()` prevents not-yet-run callbacks in the current snapshot from running.
- A nested `Fire()` captures the then-current active listener array and therefore observes connects/disconnects performed before the nested call.

Disconnect operations replace the signal's active listener array, while already-running dispatches may continue to hold an older array reference. Connection objects are shared across those arrays, so the connected flag makes a disconnect immediately visible everywhere.

These rules make re-entrant dispatch deterministic without allocating a listener-array copy for each `Fire()`.

### Errors

Listener errors are not swallowed or converted into status values. The error propagates to the caller and the current dispatch stops immediately; later listeners in that dispatch are not invoked.

SignalKit keeps no mutable dispatch-depth bookkeeping, so the signal remains usable after the caller handles an error.

## `signal:DisconnectAll()`

Disconnects every listener connected at the moment of the call and returns the number of connections that were disconnected.

```lua
local removed = changed:DisconnectAll()
```

Calling it when no listeners are connected returns `0`.

## Connection

Connections are created only by `Connect()` and `Once()`. `SignalKit.Connection` is the shared method prototype used by connection handles; it is exposed for introspection, not as a constructor.

### `connection:Disconnect()`

Disconnects that connection.

Returns `true` when the call transitioned the connection from connected to disconnected. Returns `false` when it was already disconnected.

Disconnect is idempotent.

### `connection:IsConnected()`

Returns whether the connection is currently active.

A once-connection reports `false` while its callback is executing because it is disconnected before invocation.

## Complexity and allocation behavior

Let `n` be the number of currently connected listeners.

| Operation | Time | Listener-array allocation |
|---|---:|---:|
| `Fire(...)` | `O(n)` | none |
| `Connect(...)` | amortized `O(1)` | none |
| `Once(...)` | amortized `O(1)` | none |
| `Disconnect()` | `O(n)` | one array when connected |
| `DisconnectAll()` | `O(n)` | one empty array |

This model intentionally optimizes repeated dispatch, which is expected to be more common than listener mutation in framework event paths.

## Embedded copies and revision upgrades

Registry owns the stable `SignalKit` package table for `(signal, API 1)`. SignalKit instances use that shared table as their method prototype, so existing signal instances observe compatible package-method upgrades loaded into the same API generation.

`SignalKit.Connection` is also preserved as one shared method table across compatible package revisions, allowing existing connection handles to observe compatible connection-method upgrades.

As with every Registry-managed package, a revision is selected before package initialization completes. Package initialization is therefore written so that all fallible dependency validation occurs before registration and the post-registration commit path performs only local deterministic mutations.
