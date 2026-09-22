# SignalKit API

Package: `signalKit`  
API generation: `1`  
Implementation revision: `2`

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

`Connect`, `Once`, `Fire` and `DisconnectAll` must be called **on a signal**, and
`Disconnect` and `IsConnected` **on a connection handle**. Calling them without a
receiver — `SignalKit.Connect(callback)` instead of `signal:Connect(callback)` —
raises a SignalKit error that names the mistake at the calling line:

```text
SignalKit:Connect must be called on a signal instance; use signal:Connect(callback)
```

Previously the same typo surfaced as `attempt to index a function value` or
`attempt to get length of a nil value` somewhere inside SignalKit, naming neither
the mistake nor the line that made it.

The receiver test inspects a private field rather than comparing metatables. A
newer embedded package revision builds its own signal metatable, so a metatable
comparison would reject instances created by the revision it just upgraded.

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

A disconnect marks its connection rather than removing it from the array, and
array compaction replaces the array instead of editing it. Already-running
dispatches may therefore continue to hold an older array. Connection objects are
shared across those arrays, so the disconnected flag makes a disconnect
immediately visible everywhere, including to a dispatch that is mid-walk over an
array the compaction has already superseded.

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
| `Disconnect()` | amortized `O(1)` | none, except on compaction |
| `DisconnectAll()` | `O(n)` | one empty array |

### Tombstones and compaction

`Disconnect()` marks its connection as disconnected and leaves the handle in the
listener array as a tombstone. The array is compacted — replaced by one holding
only live entries — as soon as at least half of its slots are tombstones.

Each compaction is `O(n)` but removes `n/2` slots, so disconnect stays amortized
`O(1)`, and the array never retains more than twice the live listener count. A
disconnected handle's callback is released immediately; only the small handle
table survives until the next compaction.

Revision 1 instead copied the whole array on every `Disconnect()`, which made
tearing a signal down quadratic. Measured on Lua 5.1.5, disconnecting every
listener of a signal one handle at a time:

| Listeners | Revision 1 | Revision 2 |
|---:|---:|---:|
| 100 | 0.13 ms, 119 KB | 0.04 ms, 2 KB |
| 500 | 2.03 ms, 2,658 KB | 0.18 ms, 9 KB |
| 1000 | 7.22 ms, 10,585 KB | 0.34 ms, 17 KB |
| 2000 | 28.53 ms, 42,248 KB | 0.68 ms, 33 KB |
| 4000 | 97.55 ms, 168,805 KB | 1.45 ms, 65 KB |

Revision 1 time grows by roughly 3.4× per doubling of `n` (quadratic); revision 2
grows by roughly 2.1× (linear). At 4000 listeners the teardown is 67× faster and
allocates 2,600× less.

`Fire()` is unchanged: 0 KB allocated in both revisions, and the two type tests
that validate the receiver are within measurement noise of revision 1 across
repeated best-of-five runs (200,000 dispatches over 8 listeners: 110.6 ms versus
111.6 ms in the closest pair, 112.3 ms versus 116.1 ms in the widest).

This model intentionally optimizes repeated dispatch, which is expected to be
more common than listener mutation in framework event paths, while no longer
punishing bulk teardown.

## Embedded copies and revision upgrades

Registry owns the stable `SignalKit` package table for `(signal, API 1)`. SignalKit instances use that shared table as their method prototype, so existing signal instances observe compatible package-method upgrades loaded into the same API generation.

`SignalKit.Connection` is also preserved as one shared method table across compatible package revisions, allowing existing connection handles to observe compatible connection-method upgrades.

Revision 2 changed the listener-array layout. Signals created by revision 1 carry
no tombstone counter, so every counter read treats a missing counter as zero;
live revision-1 signal instances therefore keep working unchanged after a
revision-2 copy upgrades the shared package table in place.

As with every Registry-managed package, a revision is selected before package initialization completes. Package initialization is therefore written so that all fallible dependency validation occurs before registration and the post-registration commit path performs only local deterministic mutations.
