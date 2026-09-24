# SignalKit

SignalKit is the framework's small, deterministic observer primitive for pure-Lua communication, and the home of its named message buses.

It is intentionally independent from World of Warcraft's event system. Higher-level packages can use SignalKit for lifecycle notifications, state changes, completion callbacks, and internal framework events without coupling themselves to Frames or `RegisterEvent`.

## Why SignalKit exists

Callback dispatch is easy to duplicate and surprisingly easy to get wrong once callbacks can mutate the listener set or recursively dispatch the same signal.

SignalKit centralizes those semantics:

- listeners run in connection order;
- disconnects take effect immediately;
- listeners connected during a `Fire()` are not invoked by that dispatch;
- a nested `Fire()` sees the listener set as it exists when that nested call begins;
- `Once()` disconnects before callback invocation;
- callback errors propagate to the caller and abort that dispatch;
- `Fire()` does not clone the listener array or allocate a dispatch snapshot;
- calling a signal or connection method without its receiver is reported as a
  SignalKit error at the calling line.

## Observed sources, generations and journals

Three small additions cover what an observer primitive is usually wrapped in:

- `SignalKit:New({ onFirst = ..., onLast = ... })` runs `onFirst` when the
  live listener count goes from 0 to 1 and `onLast` when it goes from 1 to 0,
  so a source (an event registration, a ticker) can be active only while
  somebody listens. A signal without hooks pays one truthiness test per
  connect and disconnect; hooks hold under re-entrant connect and disconnect,
  `Once` listeners count until they disconnect, `DisconnectAll` runs `onLast`
  once, and a hook error propagates to the caller of the call that caused the
  transition.
- `signal:GetGeneration()` is a counter that moves on every `Fire`, for cheap
  "changed since I looked" checks without a listener. It is exact up to 2^53.
- `SignalKit:NewJournal(capacity)` is a signal that also keeps its last
  `capacity` firings (128 by default) in a ring allocated once and reused.
  `journal:History()` walks them oldest to newest without allocating; nothing
  is replayed to a listener that connects. One firing carries at most
  `maxJournalArguments` values (8 by default), refused at the firing line.

```lua
local recent = SignalKit:NewJournal(16, {
    onFirst = function() print("somebody is watching") end,
    onLast = function() print("nobody is watching") end,
})
recent:Fire("login", "Alice")
for position, entry in recent:History() do
    print(position, entry.generation, entry[1], entry[2])
end
```

## Named message buses

A signal is anonymous, so two modules or two addons that share no reference
cannot use one to talk. A bus gives signals names: `SignalKit:Bus(name)`
returns the same bus to everyone who asks for that name, and each topic on it
is an ordinary signal underneath, with the same ordering and re-entrancy rules.

- Topics are declared with an argument count or a validator; publishing an
  undeclared topic, or arguments that fail the policy, raises at the publishing
  line. Buses created with `openTopics = true` skip the declaration, for
  prototypes.
- Subscribers may subscribe before the topic is declared, so load order never
  matters.
- Bus listeners are isolated from each other and from the publisher: a failure
  is reported through the host error handler, using `securecallfunction` when
  the client provides it.
- `SignalKit:ForAddon(addonName)` is an addon's default bus, closed by
  `SignalKit:CloseAddonBus(addonName)` at shutdown; `bus:CreateScope()` groups
  subscriptions for one-call teardown.
- At logout an addon's bus is closed by LifecycleKit, or by SignalKit's own
  `PLAYER_LOGOUT` watcher when only EventKit is loaded; with neither, call
  `SignalKit:CloseAddonBus("MyAddon")` yourself (see "At logout" in
  [`docs/API.md`](docs/API.md#at-logout)).
- Buses (64), topics per bus (256) and listeners per topic (256) are bounded
  by default and opened on purpose: `maxTopics` and `maxListeners` are bus
  options that accept `SignalKit.UNBOUNDED`, and `maxBuses`, together with the
  journal bounds `maxJournalCapacity` and `maxJournalArguments`, is set through
  `SignalKit:SetLimits` (see "Limits" in `docs/API.md`). A steady-state publish
  allocates nothing.

```lua
local bus = SignalKit:ForAddon("MyAddon")
bus:DeclareTopic("ProfileChanged", { arguments = 1 })

SignalKit:Bus("MyAddon"):Subscribe("ProfileChanged", function(profileName)
    print("profile is now", profileName)
end)

bus:Publish("ProfileChanged", "Default")
```

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

SignalKit depends on Registry API 2 only for embedded-package identity and revision selection. Its callback implementation uses standard Lua only. At the bus boundary it uses `securecallfunction` and `geterrorhandler` when the client provides them, and falls back to `xpcall` and `print` otherwise.

Registry must be loaded before `SignalKit.lua`. LifecycleKit API 1 and EventKit API 1 are optional: `SignalKit:ForAddon` finds them with `Registry:Find` to arrange an addon bus's close at logout, so they may load in any order.

## Performance model

Dispatch is optimized for the common pattern where signals fire more often than listeners are added or removed.

`Fire()` captures the current listener-array reference and its length without allocating a copy. `Connect()` appends in `O(1)`; an in-progress dispatch keeps its original length boundary, so the new listener is deferred.

`Disconnect()` marks the shared connection inactive in `O(1)` without allocating, so in-progress dispatches skip it immediately. The handle stays in the listener array as a tombstone until at least half the array is tombstones, at which point the array is compacted. Disconnection is therefore amortized `O(1)` and the array never retains more than twice the live listener count.

This keeps the hot dispatch path allocation-free while making both connection and bulk teardown cheap and deterministic. See [`docs/API.md`](docs/API.md) for measured numbers.

## Documentation

- [`docs/API.md`](docs/API.md) — complete API, mutation semantics, hooks, generations, journals and named buses.
- [`CHANGELOG.md`](CHANGELOG.md) — package evolution.
- [`tests/README.md`](tests/README.md) — behavior covered by executable specs.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`.

Direct runtime dependencies: Registry API 2.
Every file above is required; omitting one makes this package raise at
load.
