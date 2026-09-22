# EventKit API

EventKit API generation 1 provides lazy World of Warcraft event subscriptions backed by SignalKit API 1.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
EventKit.lua
```

Portable WoW code should resolve the package through Registry:

```lua
local EventKit = MoltenCodes.Registry:Get("eventKit", 1)
```

EventKit does not rely on `require()` at runtime.

## `EventKit:Connect(eventName, callback)`

Subscribes to a normal WoW event and returns a connection. The callback receives `eventName, ...`: the WoW event name followed by the original event payload. The first active listener for an event registers the underlying Frame; additional listeners reuse that registration; the final disconnect unregisters it.

## `EventKit:Once(eventName, callback)`

Like `Connect`, but disconnects before the first callback invocation. Recursive/re-entrant dispatch therefore cannot invoke the one-shot listener twice.

## `EventKit:ConnectUnit(eventName, callback, ...units)`

Subscribes with WoW's `Frame:RegisterUnitEvent` filtering. At least one non-empty string unit token is required. Duplicate tokens are removed and tokens are sorted before registration, so equivalent unit sets reuse one internal registration group regardless of caller order.

EventKit deliberately does not hard-code the host client's accepted unit-token catalog or unit-count limit. The running WoW client remains authoritative and registration errors are propagated.

## `EventKit:OnceUnit(eventName, callback, ...units)`

Unit-filtered one-shot subscription with the same disconnect-before-callback guarantee as `Once`.

## Connection API

### `connection:Disconnect()`

Disconnects the subscription and returns `true` exactly once. Later calls return `false`. If this was the final listener for its underlying event registration, EventKit unregisters the event immediately.

### `connection:IsConnected()`

Returns whether the connection is still active.

## Registration architecture

Normal events share one lazily created Frame.

Unit events cannot all safely share that same Frame: repeated `RegisterUnitEvent` calls for the same event on one Frame replace the prior unit filter. EventKit therefore maintains one cached Frame for each normalized unit-filter set. Different event names using the same unit set share that Frame.

Cached unit-filter Frames are retained for the package lifetime and reused if the same unit set is subscribed again. This avoids repeated creation of non-destroyable WoW Frame objects. Event registrations themselves are still removed as soon as their final listener disconnects.

## Dispatch semantics

Listener ordering, mutation safety, and recursive dispatch follow SignalKit API 1 semantics within one registration channel:

- listeners run in connection order;
- disconnecting a later listener prevents it from running in the current dispatch;
- listeners connected during a dispatch begin with a later dispatch;
- nested dispatch observes mutations already made by the outer callback;
- one-shot listeners disconnect before invocation.

Regular registrations and distinct unit-filter groups may use different WoW Frames. EventKit therefore does not define callback ordering between different Frames.

Listener errors are not swallowed. An error propagates through the current `OnEvent` dispatch and prevents later listeners in that SignalKit dispatch from running.

## Embedded copies and upgrades

Registry owns one stable EventKit table for `(events, API 1)`. Compatible higher implementation revisions update that table in place. Existing connection handles resolve methods through a stable shared `Connection` method table, and existing Frame handlers resolve dispatch functions through the stable EventKit facade.

A breaking public contract change requires a new EventKit API generation.
