# EventKit API

EventKit API generation 1 provides lazy World of Warcraft event subscriptions backed by SignalKit API 1.

Implementation revision: **8**.

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

## Owner scopes

A scope groups connections so their owner can tear them all down in one call.
The model mirrors TimerKit's scopes exactly, so the subscription-owning Kits
share one vocabulary.

```lua
local scope = EventKit:CreateScope()
scope:Connect("PLAYER_REGEN_DISABLED", onCombat)
scope:ConnectUnit("UNIT_HEALTH", onHealth, "player")

scope:DisconnectAll() -- every connection gone; the scope stays reusable
scope:Close()         -- terminal; later connections are refused
```

### Package methods

| Method | Purpose |
|---|---|
| `EventKit:CreateScope()` | Create a manually owned scope. |
| `EventKit:ForAddon(addonName)` | Return the canonical scope of an addon, creating it on demand. |
| `EventKit:CloseAddonScopes(addonName)` | Close that addon's scope; returns `false` when it has none or it was already closed. |

### Scope methods

| Method | Purpose |
|---|---|
| `Connect(eventName, callback)` | `EventKit:Connect`, owned by this scope. |
| `Once(eventName, callback)` | `EventKit:Once`, owned by this scope. |
| `ConnectUnit(eventName, callback, unit1 [, unit2])` | `EventKit:ConnectUnit`, owned by this scope. |
| `OnceUnit(eventName, callback, unit1 [, unit2])` | `EventKit:OnceUnit`, owned by this scope. |
| `DisconnectAll()` | Disconnect every live connection; return how many; keep the scope usable. |
| `Close()` | Terminally close after best-effort disconnection; `false` if already closed. |
| `IsClosed()` | Whether the scope is closed. |
| `GetAddonName()` | The owning addon name, or `nil` for a manual scope. |
| `GetActiveCount()` | The number of live connections the scope owns; a `Coalesce` or `Derive` handle counts as one. |
| `Coalesce(events, intervalSeconds, callback[, options])` | `EventKit:Coalesce`, owned by this scope. See [Coalescing events](#coalescing-events). |
| `Derive(events, compute[, options])` | `EventKit:Derive`, owned by this scope. |

A connection made through a scope is an ordinary connection handle. It can
still be disconnected on its own, and it leaves its scope the moment it
disconnects — explicitly, as a one-shot that fired, or through bulk teardown —
so a scope never holds dead handles and `GetActiveCount()` counts only live
ones.

`DisconnectAll()` and `Close()` process connections in creation order. A host
failure while releasing one connection does not stop the sweep: every
connection is attempted and leaves the scope, and the first error object is
re-raised unchanged afterwards. This is the contract
`TimerKit.Scope:CancelAll()` already documents.

`Close()` marks the scope closed before the sweep begins. From then on
`Connect`, `Once`, `ConnectUnit` and `OnceUnit` raise at the caller's line:

```text
MyAddon/Main.lua:42: EventKit.Scope:Connect cannot connect in a closed scope
```

### Closing during a dispatch

`Close()` prevents future deliveries; it never cuts short the one in flight.
When a scope is closed from inside a listener — directly, or through
`CloseAddonScopes` from LifecycleKit's `PLAYER_LOGOUT` handling — the scope is
closed at once and refuses new connections, but its connections stay connected
until the outermost dispatch returns. Every listener still due to receive the
event being dispatched receives it, including the scope's own listeners of that
event; after the dispatch returns, the connections are swept and nothing else
is delivered to them. Until the sweep, `GetActiveCount()` still counts them.

A dispatch that a listener starts synchronously (a nested event) is part of the
delivery in flight. A failure while sweeping after the dispatch has nobody to be
raised to, so it goes to the host error handler.

This is what lets an addon connect `PLAYER_LOGOUT` through its own scope to save
its state, even though LifecycleKit's logout handling closes that scope and runs
first. EventKit counts dispatches with two field writes per event, so the
per-event path still allocates nothing.

`DisconnectAll()` and `connection:Disconnect()` are not deferred: they are
explicit requests to stop now.

Argument errors raised through a scope name the scope method
(`EventKit.Scope:Connect eventName must be a non-empty string`) and point at the
caller's line, like the package-level methods.

### Addon scopes and shutdown: the two-step

`ForAddon(addonName)` is idempotent: every call with the same name returns the
same scope. TimerKit closes its addon scopes itself because it depends on
LifecycleKit. EventKit cannot: LifecycleKit depends on EventKit, so the reverse
dependency would be a cycle. Closing an addon scope is therefore a separate,
public step taken by whoever observes the addon's shutdown:

1. The addon's code subscribes through `EventKit:ForAddon("MyAddon")`.
2. On that addon's shutdown, the observer calls
   `EventKit:CloseAddonScopes("MyAddon")`.

LifecycleKit makes that call: when an addon reaches `shutdown`, after its
shutdown callbacks have run, LifecycleKit calls
`EventKit:CloseAddonScopes(addonName)`. An addon using LifecycleKit writes no
teardown for its scoped events.

A consumer that does not use LifecycleKit wires the second step itself:

```lua
EventKit:Once("PLAYER_LOGOUT", function()
    EventKit:CloseAddonScopes("MyAddon")
end)
```

That handler runs inside the `PLAYER_LOGOUT` dispatch, so it closes the scope
without taking the logout away from the scope's own listeners: see *Closing
during a dispatch*. Before revision 6 this wiring, like LifecycleKit's, silently
dropped a scoped `PLAYER_LOGOUT` listener connected after it.

Closing is terminal, as shutdown is. The closed scope stays the addon's
canonical scope, so a later `ForAddon("MyAddon")` returns it and refuses new
connections rather than silently creating subscriptions that outlive the
shutdown. Calling `CloseAddonScopes` for an addon that never asked for a scope
records nothing and returns `false`, as HookKit, CommandKit and CommKit do, so
the addon-scope map grows only with `ForAddon` calls; a later `ForAddon` for
that addon creates an open scope. Revisions before 8 recorded a closed scope
instead. Each addon keeps at most one scope table, so the addon-scope map is
bounded by the number of addon names used.

`CloseAddonScopes` must be called on the facade with a colon. A dot call raises
at the caller: `EventKit:CloseAddonScopes must be called on the EventKit
facade; use EventKit:CloseAddonScopes(addonName)`.

Manual scopes are never closed by `CloseAddonScopes`.

### Cost

Each connection carries three link fields, created with the connection.
Joining a scope and leaving it are a handful of field writes on an intrusive
doubly linked list: nothing is allocated, and a disconnect unlinks in constant
time. Dispatch is unchanged; a scoped listener costs exactly what a
package-level one does, and a spec guards that it allocates nothing per event.

## Coalescing events

`Coalesce` and `Derive` are the event half of the framework's coalescing
family. The timing half — `Debounce`, `Coalesce`, `Watch` and lanes — lives in
SchedulerKit, and the family is documented once, in SchedulerKit's
[`docs/API.md`](../../schedulerKit/docs/API.md#coalescing-and-lanes). EventKit
supplies the subscriptions; SchedulerKit supplies when things run.

### SchedulerKit is optional

EventKit does not depend on SchedulerKit: SchedulerKit depends on LifecycleKit,
which depends on EventKit, so the reverse would be a cycle. Both methods find
SchedulerKit API 1 through `Registry:Find` **when they are called**, so it may
load after EventKit.

| | With SchedulerKit | Without it |
|---|---|---|
| `Coalesce` | One callback per interval. | Refused at the caller: `EventKit:Coalesce requires SchedulerKit API 1, which is not available (absent)`. Nothing is registered. |
| `Derive` | Recompute debounced, by default to the next frame. | Recompute synchronously on every event. It still works; it just does not coalesce. |

### `EventKit:Coalesce(events, intervalSeconds, callback[, options])`

Registers every event in `events` (a name or an array of names, at most 32
distinct) and collects their payloads into a **set**, keyed by the first
payload argument. The first event starts the interval; at its end
`callback(set)` runs once with everything collected. This is AceBucket's
interval semantics: *first event starts the interval, callback at its end with
everything collected*.

```lua
local events = EventKit:ForAddon("MyAddon")
events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.1, function(units)
    for unit in pairs(units) do
        updateHealthBar(unit)
    end
end, { units = { "player", "target" } })
```

| Option | Meaning |
|---|---|
| `byEvent` | Key the set by event name instead of the first payload argument. |
| `units` | One or two unit tokens: the events are registered with `ConnectUnit` semantics, including its two-token limit. |
| `maxKeys` | Distinct keys one interval may hold; SchedulerKit's default is 256. Past it, new keys are refused and counted. |
| `lane` | A SchedulerKit lane every delivery goes through. |

- Every value in the set is `true`. An event whose first argument is `nil`
  (or NaN) is keyed by its event name, so `BAG_UPDATE_DELAYED` still counts.
- **The set is reused.** Without a lane it is emptied as soon as the callback
  returns; delivered through a lane it lives until the lane job reaches a
  terminal state, across retries, and is emptied then. Do not keep it; copy
  what you need.
- A raising callback is reported through the host error handler, as any
  listener is.

The handle:

| Method | Purpose |
|---|---|
| `Flush()` | Deliver now; `false` when nothing was collected, or `false, "deferred"` / `false, "dropped"` when a lane did not take the delivery. |
| `IsPending()` | Whether payloads wait for delivery. |
| `GetStats()` | SchedulerKit's `{ keys, refused, delivered, deferred, dropped }`, in a reused table. |
| `Close()` | Unregister the events, drop what was collected, leave the scope. Terminal; `false` if already closed. |
| `IsClosed()` | Whether the handle is closed. |

### `EventKit:Derive(events, compute[, options])`

A value that `compute()` produces, cached, and recomputed when any of `events`
fires. `compute` runs once at creation, before anything is registered; if it
raises, the error reaches the caller and nothing is left behind.

```lua
local freeSlots = EventKit:ForAddon("MyAddon"):Derive("BAG_UPDATE_DELAYED", countFreeSlots)
freeSlots:OnChange(function(now, before)
    print("free slots", before, "->", now)
end)
print(freeSlots:Get())
```

| Option | Meaning |
|---|---|
| `delaySeconds` | Quiet period before recomputing; `0`, the default, is the next frame. Uses SchedulerKit's `Debounce`. |
| `equals` | `fun(previous, current): boolean` deciding whether a new value is the same; `==` when omitted. |
| `units` | One or two unit tokens, as for `Coalesce`. |

| Method | Purpose |
|---|---|
| `Get()` | The cached value. It is not recomputed by reading it. |
| `OnChange(callback)` | `callback(value, previous)` whenever a recompute changes the value; returns a SignalKit connection. Listeners are isolated like event listeners. |
| `Invalidate()` | Mark the value stale, exactly as one of its events would. |
| `Close()` | Unregister the events, drop a pending recompute. Terminal; `Get()` keeps returning the last value. |
| `IsClosed()` | Whether the handle is closed. |

A `compute` that raises during a recompute is reported and the previous value
is kept; so is an `equals` that raises, which then counts as a change. With the
default `==`, a `compute` that returns NaN counts as a change on every
recompute, because NaN is never equal to itself.

### Ownership

`scope:Coalesce` and `scope:Derive` put the handle into the scope. The handle
counts as **one** member in `GetActiveCount()`; `DisconnectAll()` and `Close()`
release it with everything it owns — its event registrations and the
SchedulerKit scope holding its timing handle — and closing a scope during a
dispatch defers that, as for any connection. The handle's own event
connections are internal and belong to no scope.

Each handle creates its own SchedulerKit scope, so closing the package-level
SchedulerKit scope from elsewhere cannot silently stop it; a `Derive` whose
timing handle is closed anyway falls back to recomputing synchronously.

### Cost

The per-event path is one isolated listener call and one table write into a
reused set: a spec guards that steady-state events allocate nothing. Creating a
handle allocates its tables, one closure, one SchedulerKit scope and the event
connections.

## Connection API

### `connection:Disconnect()`

Disconnects the subscription and returns `true` exactly once. Later calls return `false`. If this was the final listener for its underlying event registration, EventKit unregisters the event immediately.

### `connection:IsConnected()`

Returns whether the connection is still active.

### Both methods require a receiver

`EventKit.Connection` is the shared method prototype every handle indexes, so its
methods are reachable without a receiver. Called that way — `EventKit.Connection.Disconnect()`
or `connection.Disconnect()` with a dot instead of a colon — they raise
`EventKit:Disconnect must be called on a connection handle; use connection:Disconnect()`
at the calling line. The receiver test is a field type test rather than a metatable
comparison, so a handle created by an older embedded revision is still accepted after
an in-place upgrade.

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

Revision 7 moved `_state` from schema 4 to schema 5, adding the dispatch table
that `Coalesce` and `Derive` listeners resolve through and the metatables their
handles are validated by. A revision-7 copy loading over revision 6 adds them
in place; scopes revision 6 created gain `Coalesce` and `Derive`, and its
connections keep working.

Revision 6 moved `_state` from schema 3 to schema 4, adding the dispatch depth
and the list of scopes closed during a dispatch. A revision-6 copy loading over
revision 5 adds them in place; scopes revision 5 created keep working and gain
the deferred close.

Revision 5 added scopes and moved `_state` from schema 2 to schema 3. A
revision-5 copy loading over revision 2 to 4 adds the shared `Scope` prototype,
the addon-scope map and the shared scope metatable; scope receivers are
validated by that metatable's identity, so it lives in shared state rather than
in the loading file. Connections made by the older revision carry no scope link
and keep working: they are simply owned by no scope.

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
