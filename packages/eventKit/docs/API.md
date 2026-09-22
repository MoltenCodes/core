# EventKit API

EventKit API generation 1 provides lazy World of Warcraft event subscriptions backed by SignalKit API 1.

Implementation revision: **2**.

EventKit is multi-tenant: one shared instance serves every addon in a WoW session.

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

## `EventKit:ConnectUnit(eventName, callback, unit1 [, unit2])`

Subscribes with WoW's `Frame:RegisterUnitEvent` filtering. At least one non-empty string unit token is required. Duplicate tokens are removed and tokens are sorted before registration, so equivalent unit sets reuse one internal registration group regardless of caller order.

### The two-token limit

`Frame:RegisterUnitEvent(event, unit1, unit2)` has exactly **two** unit-filter
slots. More than two *distinct* tokens is rejected with an error at the calling
line:

```text
EventKit:ConnectUnit accepts at most 2 distinct unit tokens because
Frame:RegisterUnitEvent has 2 filter slots; received 3
```

Duplicates are removed before the limit is applied, so
`ConnectUnit(event, callback, "player", "target", "player")` is a two-token
subscription and is accepted.

Rejecting was chosen over splitting the request into several two-token groups
and fanning them in. Fan-in is not free: it needs one extra Frame per extra
pair, makes a single `Disconnect()` responsible for several registrations, and —
because EventKit does not define callback ordering between Frames — would make
delivery order for one logical subscription unspecified. Explicitly refusing an
impossible filter is simpler, deterministic, and tells the caller what is wrong.
Callers that want three units make three subscriptions and own the fan-in.

Before revision 2 the third token was sorted, silently dropped by the client,
and then still claimed by EventKit's internal group key, so the caller received
a filter they never asked for and a group keyed on a filter that was not in
effect.

EventKit deliberately does not hard-code the host client's accepted unit-token
catalog beyond that slot count. The running WoW client remains authoritative and
registration errors are propagated.

## `EventKit:OnceUnit(eventName, callback, unit1 [, unit2])`

Unit-filtered one-shot subscription with the same disconnect-before-callback guarantee as `Once`, and the same two-token limit as `ConnectUnit`.

## Connection API

### `connection:Disconnect()`

Disconnects the subscription and returns `true` exactly once. Later calls return `false`. If this was the final listener for its underlying event registration, EventKit unregisters the event immediately.

### `connection:IsConnected()`

Returns whether the connection is still active.

## Registration architecture

Normal events share one lazily created Frame.

Unit events cannot all safely share that same Frame: repeated `RegisterUnitEvent` calls for the same event on one Frame replace the prior unit filter. EventKit therefore maintains one cached Frame for each normalized unit-filter set. Different event names using the same unit set share that Frame.

### Unit-group lifetime

A unit group is released as soon as its last channel loses its last listener.
Releasing detaches the Frame's `OnEvent` handler — so an event the host already
queued cannot reach a group that no longer exists — and returns the Frame to a
free list. The next unit set to be subscribed re-purposes a free Frame:
`RegisterUnitEvent` re-points it and `UnregisterEvent` clears it again.

WoW Frames cannot be destroyed, so the meaningful bound is on how many EventKit
ever creates. That number is capped at **64**. Past the cap, with no free Frame
available, `ConnectUnit`/`OnceUnit` raise:

```text
EventKit: refusing to create more than 64 unit-filter Frames; disconnect unused
unit subscriptions or reuse unit sets
```

Because released Frames are reused, the cap constrains only how many *distinct
unit sets are live at once*, not how many are used over a session: creating and
releasing a hundred different unit sets one at a time creates exactly one Frame.
The free list is bounded by the same number, since every Frame in it is one
EventKit created.

Before revision 2, unit groups were never released: their Frames were retained
for the package lifetime and `state.unitGroups` only ever grew.

## Dispatch semantics

Listener ordering, mutation safety, and recursive dispatch follow SignalKit API 1 semantics within one registration channel:

- listeners run in connection order;
- disconnecting a later listener prevents it from running in the current dispatch;
- listeners connected during a dispatch begin with a later dispatch;
- nested dispatch observes mutations already made by the outer callback;
- one-shot listeners disconnect before invocation.

Regular registrations and distinct unit-filter groups may use different WoW Frames. EventKit therefore does not define callback ordering between different Frames.

### Listener isolation

EventKit is shared by every addon in the session. A listener that raises is
therefore **reported, not raised**: the error goes to the host error handler and
delivery continues to every other listener of that event.

```lua
EventKit:Connect("PLAYER_LOGIN", function()
    error("one addon's bug")
end)

EventKit:Connect("PLAYER_LOGIN", function()
    -- still runs
end)
```

This reverses revision 1, where an error propagated out through `OnEvent` and
every listener behind the failing one lost the event — including listeners
belonging to completely unrelated addons.

Isolation is per listener and happens at EventKit's boundary, not SignalKit's.
SignalKit still propagates listener errors; EventKit wraps each subscription so
the callback it hands SignalKit cannot raise.

The mechanism depends on the client:

- **`securecallfunction`**, when the client provides it. It isolates the call and
  keeps the caller's taint state out of the listener.
- **`xpcall` with `geterrorhandler()`** otherwise. Lua 5.1's `xpcall` takes no
  extra arguments, so the payload is staged in reusable upvalues (or, past six
  values, one reusable buffer table) and forwarded by a single reusable
  trampoline. No closure and no argument table is allocated per event. Using
  `xpcall` rather than `pcall` means the handler runs before the stack unwinds,
  so a handler that captures a traceback captures the point of failure.

Outside a WoW client, where `geterrorhandler` does not exist, the message is
printed. Staying silent would turn a listener bug into an invisible one.

#### Cost

Measured on Lua 5.1.5, 200,000 events delivered to 8 listeners (1.6 million
listener invocations), best of three runs, against revision 1 with no isolation:

| Payload | Revision 1 | Revision 2 | Added per listener call |
|---|---:|---:|---:|
| `eventName` + 2 values | 145.8 ms | 330.2 ms | ~115 ns |
| `eventName` + 10 values | 148.7 ms | 490.4 ms | ~214 ns |

Both revisions allocate nothing measurable per event; a spec guards that with
`collectgarbage("count")` deltas. The hottest real event,
`COMBAT_LOG_EVENT_UNFILTERED`, carries no payload at all and therefore takes the
cheapest inline path.

Errors are reported once per failing listener per dispatch, so a listener that
fails on every event will spam the host error handler exactly as a non-isolated
one would.

## Embedded copies and upgrades

Registry owns one stable EventKit table for `(events, API 1)`. Compatible higher implementation revisions update that table in place. Existing connection handles resolve methods through a stable shared `Connection` method table, and existing Frame handlers resolve dispatch functions through the stable EventKit facade.

Revision 2 changed the shape of `_state` (schema 1 to schema 2). A revision-2
copy loading over live revision-1 state adopts that state in place: it keys the
existing unit groups, counts the Frames revision 1 already created against the
Frame cap, and installs the dispatch and isolation slots. Package table,
connection method table, Frames and live subscriptions are all preserved.

A breaking public contract change requires a new EventKit API generation.

## World of Warcraft specifics

### `COMBAT_LOG_EVENT_UNFILTERED` carries no payload

Since Legion the combat-log event delivers **no arguments**. Handlers read the
event out of the client instead:

```lua
EventKit:Connect("COMBAT_LOG_EVENT_UNFILTERED", function()
    local timestamp, subEvent, hideCaster, sourceGUID = CombatLogGetCurrentEventInfo()
    -- ...
end)
```

EventKit forwards the event name and whatever the client passed, so the callback
receives exactly `"COMBAT_LOG_EVENT_UNFILTERED"` and nothing else. Do not expect
payload parameters, and keep the handler short: this is the highest-frequency
event in the client.

`COMBAT_LOG_EVENT_UNFILTERED` is a normal event, not a unit event.
`CombatLogGetCurrentEventInfo()` is only valid inside the handler.

### Taint

EventKit is a shared bus, so callbacks from different addons run through the
same Frame handler. Two consequences:

- **Execution taint spreads through the bus.** If an insecure addon's listener
  runs first, the EventKit dispatch it returns into is tainted, and so is every
  listener after it in the same dispatch. On clients that provide
  `securecallfunction`, EventKit uses it precisely to keep each listener's taint
  from leaking into the next. Elsewhere the `xpcall` fallback isolates errors but
  not taint.
- **Do not call protected functions from an EventKit listener.** A listener is
  never a secure execution path, whichever addon loaded EventKit. Protected
  actions belong in a secure template or a hardware-event handler owned by the
  addon itself.

Registration itself is not protected: `RegisterEvent`/`RegisterUnitEvent` on an
addon-created Frame is safe from any code.

### Reserved fields

Every underscore-prefixed field on the EventKit facade is reserved package
storage:

```lua
EventKit._state             -- shared runtime state
EventKit._DispatchRegular   -- dispatcher for the shared regular-event Frame
EventKit._DispatchUnit      -- dispatcher for unit-filter Frames
```

They are not public API. Consumers must not read or write them, and a compatible
revision may change their shape. `_DispatchRegular` and `_DispatchUnit` exist on
the facade only so that Frames created by implementation revision 1 keep
resolving the current dispatcher after an in-place upgrade; revision 2 Frames
resolve it through `_state`, which removes a per-event type check from the hot
path.
