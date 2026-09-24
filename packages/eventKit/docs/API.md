# EventKit API

EventKit API generation 1 provides lazy World of Warcraft event subscriptions backed by SignalKit API 1.

Implementation revision: **16**.

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

On a client with `C_EventUtils.IsEventValid`, a name the client does not know
is refused at the caller's line before anything is registered:
`EventKit:Connect eventName "X" is not an event this client knows`. Every
method that registers an event name does the same; see
[Event names the client does not know](#event-names-the-client-does-not-know).

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
registration errors are propagated. The event name itself is checked with the
client's `C_EventUtils.IsEventValid` where the client has it (see
[Event names the client does not know](#event-names-the-client-does-not-know)).

## `EventKit:OnceUnit(eventName, callback, unit1 [, unit2])`

Unit-filtered one-shot subscription with the same disconnect-before-callback guarantee as `Once`, and the same two-token limit as `ConnectUnit`.

## `EventKit:ConnectCombatLog(subEvent, callback)`

Subscribes to one **combat-log sub-event** and returns an ordinary connection.
`COMBAT_LOG_EVENT_UNFILTERED` carries no payload: the client hands the event
out through `CombatLogGetCurrentEventInfo()`, which is only valid inside the
handler. EventKit makes that call **once per event**, for every combat-log
listener together, and calls each listener of the event's sub-event with
**every return, unchanged**:

```lua
EventKit:ConnectCombatLog("SPELL_DAMAGE", function(timestamp, subEvent, hideCaster,
        sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
        destGUID, destName, destFlags, destRaidFlags,
        spellId, spellName, spellSchool, amount, overkill, school, resisted,
        blocked, absorbed, critical, glancing, crushing, isOffHand)
    -- ...
end)
```

- `subEvent` is the client's sub-event name, the second return of
  `CombatLogGetCurrentEventInfo()` (`"SPELL_DAMAGE"`, `"SWING_DAMAGE"`,
  `"UNIT_DIED"`, ...), or **`"*"`** for every sub-event. It must be a
  non-empty string. Sub-event names are not checked against the client, which
  has no function that knows them: a listener of a sub-event that never
  occurs is simply never called.
- The listener receives **no event name** in front: the first value is the
  timestamp and the second the sub-event. The first eleven values are the same
  for every sub-event; what follows is the sub-event's own suffix, whose count
  varies (a swing has none of the spell values, a periodic damage has an
  extra one). Values are forwarded with their count intact, `nil` holes
  included, so `select("#", ...)` in the listener tells the truth.
- Listeners of one sub-event run in connection order; the wildcard listeners
  run **after** the sub-event's own, in their own connection order. A
  sub-event with no listener costs one lookup and nothing else.
- Listeners are isolated exactly as `Connect` listeners are: one that raises is
  reported through the host error handler and the rest still run. Scope
  ownership, `Disconnect`, `IsConnected`, mutation during a dispatch and the
  deferred scope close all behave as for `Connect`.
- The client documents the reader's returns as possibly
  [secret](#secret-values). A secret sub-event cannot be looked up, so that
  event reaches the wildcard (`"*"`) listeners only, with every return
  unchanged (revision 16 and later).

### One registration, shared with `Connect`

EventKit registers `COMBAT_LOG_EVENT_UNFILTERED` with the host only while at
least one combat-log listener exists, and unregisters it when the last one
disconnects. The registration is the event's ordinary channel: a plain
`EventKit:Connect("COMBAT_LOG_EVENT_UNFILTERED", ...)` shares it and keeps
working unchanged, receiving the event name alone, and the event stays
registered as long as either kind of listener remains. The delivery order
between plain listeners and combat-log listeners of the same event is not
defined.

`ConnectCombatLog` resolves the client's **reader** when the first
combat-log listener connects: the global `CombatLogGetCurrentEventInfo`, or
`C_CombatLog.GetCurrentEventInfo` when the global is absent (the current
classic clients document only the namespaced function). Without either, as on
retail 12 clients (see
[World of Warcraft specifics](#the-combat-log-no-payload-two-ways-to-listen)),
the call raises at the caller's line and registers nothing:

```text
EventKit:ConnectCombatLog the combat log is not available to addons on this client (no CombatLogGetCurrentEventInfo reader); check EventKit:IsCombatLogAvailable() first
```

Through a scope the message starts with `EventKit.Scope:ConnectCombatLog`.
Ask [`EventKit:IsCombatLogAvailable()`](#eventkitiscombatlogavailable) first
to take another path on such a client instead of catching the error. Before
revision 15 the refusal was `EventKit: requires the World of Warcraft
CombatLogGetCurrentEventInfo API`, raised without a position. A registration
the host refuses raises `EventKit:ConnectCombatLog could not register event
COMBAT_LOG_EVENT_UNFILTERED` at the caller's line and also leaves nothing
behind. The combat-log event is EventKit's own registration, so it is not
checked with `C_EventUtils.IsEventValid`.

### Cost

Per event: one isolated call for the router itself, in which it makes one
`CombatLogGetCurrentEventInfo()` call, one table lookup for the sub-event and
one field read for the wildcard, and then one isolated call per listener of
the routes that matched, with the values staged the same way as any event
payload (see *Listener isolation*). The router runs inside the same isolation
as a listener, so a client read that raised would be reported through the host
error handler and plain `Connect` listeners of the event would still run.
Nothing is allocated per event; a spec guards that with
`collectgarbage("count")` deltas across sub-event and wildcard listeners
together. The last combat-log listener disconnecting and reconnecting inside
its own callback works, at the price of unregistering and re-registering the
host event within that one dispatch. Per sub-event in use, EventKit keeps one route (a
SignalKit signal and a count) that leaves with the sub-event's last listener,
so routes are bounded by the live subscriptions, like event channels, and need
no limit of their own.

There is no one-shot form: a combat-log sub-event is a stream, and a listener
that wants a single occurrence disconnects itself.

## `EventKit:IsCombatLogAvailable()`

Returns `true` when EventKit can read the combat log on this client, that is
when the global `CombatLogGetCurrentEventInfo` or
`C_CombatLog.GetCurrentEventInfo` exists, and `false` otherwise. It is exactly
the condition under which `ConnectCombatLog` connects instead of refusing, so
an addon that wants combat-log data on every client asks first:

```lua
if EventKit:IsCombatLogAvailable() then
    EventKit:ForAddon("MyAddon"):ConnectCombatLog("SPELL_DAMAGE", onSpellDamage)
else
    -- Retail 12: addon code gets no combat-log reader; degrade or stay quiet.
end
```

Cost: two table reads and no allocation, so it may be asked whenever needed;
it neither reads the combat log nor registers anything. The answer is looked
up on every call rather than once at load, so it follows a reader another
addon installs later; within a session it otherwise does not change. The
receiver is not used, so `EventKit.IsCombatLogAvailable()` answers too.

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
| `ConnectCombatLog(subEvent, callback)` | `EventKit:ConnectCombatLog`, owned by this scope. |
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
`Connect`, `Once`, `ConnectUnit`, `OnceUnit` and `ConnectCombatLog` raise at
the caller's line:

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
its state, even though the logout handling that closes that scope (LifecycleKit's,
or EventKit's own; see [At logout](#at-logout)) may run first. EventKit counts dispatches with two field writes per event, so the
per-event path still allocates nothing.

`DisconnectAll()` and `connection:Disconnect()` are not deferred: they are
explicit requests to stop now.

Argument errors raised through a scope name the scope method
(`EventKit.Scope:Connect eventName must be a non-empty string`) and point at the
caller's line, like the package-level methods.

### Addon scopes and shutdown: the two-step

`ForAddon(addonName)` is idempotent: every call with the same name returns the
same scope. LifecycleKit depends on EventKit, so EventKit cannot depend on
LifecycleKit; closing an addon scope is therefore a separate, public step:

1. The addon's code subscribes through `EventKit:ForAddon("MyAddon")`.
2. At logout, `EventKit:CloseAddonScopes("MyAddon")` closes the scope.

EventKit observes `PLAYER_LOGOUT` itself, so it always arranges the second
step; see [At logout](#at-logout). An addon writes no teardown for its scoped
events, with or without LifecycleKit.

#### At logout

**An addon scope always closes at logout**, whatever LifecycleKit revision is
paired with this one. The first `ForAddon(addonName)` for an addon looks for
LifecycleKit through `Registry:Find` and takes the first case that applies:

1. **LifecycleKit lists `"eventKit"` in `LifecycleKit.CLOSES_ADDON_SCOPES`**
   (LifecycleKit 0.6.0 and later). EventKit connects nothing of its own and
   makes sure the addon is known to LifecycleKit (it calls
   `LifecycleKit:ForAddon(addonName)` once): LifecycleKit calls `CloseAddonScopes` when the addon reaches `shutdown`,
   after its shutdown callbacks have run and after the addon's TimerKit and
   SchedulerKit scopes, before its HookKit, CommandKit and CommKit scopes and
   its SignalKit bus. This is the case with ordering guarantees, and it
   covers an addon that never used LifecycleKit itself.
2. **An older LifecycleKit, without that field.** EventKit asks it for
   `LifecycleKit:ForAddon(addonName):OnShutdown(...)`, once per addon, and
   closes the scope from that callback. This is compatibility only; every
   LifecycleKit that knows scopes also makes the call itself, and the second
   close answers `false`. The subscription is kept on the scope; closing the
   scope disconnects it. If a LifecycleKit that lists EventKit replaces the
   older one before logout, the callback leaves the call to it.
3. **No LifecycleKit.** EventKit keeps one package-level `PLAYER_LOGOUT`
   one-shot, connected by the first `ForAddon` that needs it, which closes
   every addon scope neither case above covers, in addon-name order.
4. **The host refused that registration.** Nothing is connected and
   `ForAddon` works as always; the next `ForAddon` for that addon tries again.
   Until one succeeds, call `CloseAddonScopes` yourself on `PLAYER_LOGOUT`:

```lua
EventKit:Once("PLAYER_LOGOUT", function()
    EventKit:CloseAddonScopes("MyAddon")
end)
```

Every case closes the scope inside the `PLAYER_LOGOUT` dispatch, so the
connections are swept only after that dispatch completes: a scoped
`PLAYER_LOGOUT` listener still runs, whether it was connected before or after
the listener that closed its scope (see *Closing during a dispatch*). From the
moment the scope closes it refuses new connections, so a listener that runs
after the close cannot connect through it. Before revision 6 a close from a
`PLAYER_LOGOUT` handler silently dropped a scoped `PLAYER_LOGOUT` listener
connected after it.

The routing costs one field read per `ForAddon` once decided. EventKit
allocates one closure and one LifecycleKit subscription per addon in case 2,
and one connection for the whole package in case 3.

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

EventKit does not depend on SchedulerKit: coalescing is the one feature that
needs a scheduler, and requiring it would triple EventKit's footprint for every
addon that only wants events. Both methods find
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
  (or NaN, or a [secret value](#secret-values)) is keyed by its event name, so
  `BAG_UPDATE_DELAYED` still counts.
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
| `OnChange(callback)` | `callback(value, previous)` whenever a recompute changes the value; returns a SignalKit connection. Listeners are isolated like event listeners. On a closed handle it raises `EventKit.DeriveHandle:OnChange cannot subscribe to a closed derived value` at the caller's line. |
| `Invalidate()` | Mark the value stale, exactly as one of its events would. |
| `Close()` | Unregister the events, drop a pending recompute, disconnect the `OnChange` listeners. Terminal; `false` if already closed; `Get()` keeps returning the last value. |
| `IsClosed()` | Whether the handle is closed. |

A `compute` that raises during a recompute is reported and the previous value
is kept; so is an `equals` that raises, which then counts as a change. With the
default `==`, a `compute` that returns NaN counts as a change on every
recompute, because NaN is never equal to itself; so does a
[secret](#secret-values) value on either side, which cannot be compared.
An `equals` that answers with a secret value counts as a change too: the
answer cannot be tested as a boolean, so it is never read as "equal"
(revision 16 and later).

### Ownership

`scope:Coalesce` and `scope:Derive` put the handle into the scope. The handle
counts as **one** member in `GetActiveCount()`; `DisconnectAll()` and `Close()`
release it with everything it owns — its event registrations and the
SchedulerKit scope holding its timing handle — and closing a scope during a
dispatch defers that, as for any connection. The handle's own event
connections are internal and belong to no scope. A `Derive` whose `compute`
closes the scope it is being created in is refused with `EventKit.Scope:Derive
cannot connect in a closed scope` and leaves nothing registered.

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
ever creates. That number is the shared `maxUnitFrames` limit, **64** by default
(see [Limits](#limits)). Past it, with no free Frame available,
`ConnectUnit`/`OnceUnit` raise:

```text
EventKit: refusing to create more than 64 unit-filter Frames; disconnect unused
unit subscriptions, reuse unit sets or raise EventKit:SetLimits{ maxUnitFrames }
```

Because released Frames are reused, the cap constrains only how many *distinct
unit sets are live at once*, not how many are used over a session: creating and
releasing a hundred different unit sets one at a time creates exactly one Frame.
The free list is bounded by the same number, since every Frame in it is one
EventKit created.

Before revision 2, unit groups were never released: their Frames were retained
for the package lifetime and `state.unitGroups` only ever grew.

## Limits

EventKit keeps one package-wide limit. It is shared by **every consumer in the
session**: every embedded copy and every addon read the same value, so an addon
that raises it raises it for everybody, and a library should rely on the
default.

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxUnitFrames` | 64 | `EventKit:SetLimits{ maxUnitFrames = n }`, `n` an integer from 1 to 512 | No: the client never frees a Frame, so every Frame admitted lives for the rest of the session. The ceiling is 512. |

```lua
EventKit:SetLimits({ maxUnitFrames = 128 })
local limits = EventKit:GetLimits() -- a fresh table: { maxUnitFrames = 128 }
```

`SetLimits(limits)` accepts any subset of the limits and returns nothing. It
raises at the caller's line, before changing anything, on a non-table argument,
an unrecognised name (`EventKit:SetLimits limits.<name> is not a recognised
limit`), a value that is not an integer from 1 to the ceiling (`... must be an
integer from 1 to 512`), and `EventKit.UNBOUNDED` (`... cannot be
EventKit.UNBOUNDED: the client never frees a Frame`). `GetLimits()` returns a
fresh table on every call, so it allocates; read it at configuration time, not
per event.

Lowering the limit below the Frames already created evicts nothing: existing
unit subscriptions keep their Frames, released Frames are still reused, and a
new Frame is refused until the limit is raised again.

`EventKit.UNBOUNDED` is the package's sentinel for "no limit", one table shared
by every revision. No EventKit limit accepts it today; it exists so every Kit
exposes the same escape-hatch vocabulary, and the refusal above names it.

Two bounds stay fixed, because they are not retention a consumer can own:

- **Two unit tokens** per `ConnectUnit`: `Frame:RegisterUnitEvent` has exactly
  two filter slots (see [The two-token limit](#the-two-token-limit)).
- **32 distinct events** per `Coalesce` or `Derive` call. The bound is per
  call, not per session: each call copies its event list into a fresh array
  and holds one connection per event on the handle it returns, all released by
  `Close`. Related events that one handle should merge come in handfuls
  (a unit's health and power events, the bag events), so 32 is several times
  any real composite; a longer list is almost always a generated or mistaken
  argument, refused at the caller before anything is connected. A caller that
  needs more makes more than one handle.

Scopes have no connection cap: a scope's connections are its owner's own
registrations and are released with it. The logout routing holds at most one
LifecycleKit subscription per addon scope, released when the scope closes, and
one `PLAYER_LOGOUT` connection for the package. Combat-log routes are released
with their sub-event's last listener, as event channels are, so they carry no
limit either (see [`ConnectCombatLog`](#eventkitconnectcombatlogsubevent-callback)).

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
`COMBAT_LOG_EVENT_UNFILTERED`, carries no payload at all, so a plain `Connect`
listener for it takes the cheapest inline path; a `ConnectCombatLog` listener
receives the full `CombatLogGetCurrentEventInfo()` return list, which the
buffered path forwards without allocating.

Errors are reported once per failing listener per dispatch, so a listener that
fails on every event will spam the host error handler exactly as a non-isolated
one would.

## Embedded copies and upgrades

Registry owns one stable EventKit table for `(eventKit, API 1)`. Compatible higher implementation revisions update that table in place. Existing connection handles resolve methods through a stable shared `Connection` method table; Frames created since revision 2 resolve their dispatcher through `_state`, and revision-1 Frames through the reserved facade fields described under *Reserved fields*. Scopes and `Coalesce`/`Derive` handles are validated by metatables kept in `_state`, and handle listeners resolve their behaviour through it, so handles created by an older copy run the newer code.

Revision 15 keeps `_state` at schema 8 and adopts the state of revision 14
as it is, adding `IsCombatLogAvailable` to the facade. The loading copy probes
`C_EventUtils.IsEventValid` itself, so every event name subscribed through the
facade from then on is checked; listeners the older copy connected keep
delivering whatever their names.

Revision 14 keeps `_state` at schema 8 and adopts the state of revision 13
as it is. It tests values it did not create for absence with `type` and
handles [secret values](#secret-values) before any comparison.

Revision 13 keeps `_state` at schema 8. A copy loading over revision 12
adopts the state as it is; its router, routes and listeners keep delivering,
and the next attach resolves the client API as described under
[`ConnectCombatLog`](#eventkitconnectcombatlogsubevent-callback).

Revision 12 moved `_state` from schema 7 to schema 8, adding the combat-log
router (`combatLog`: the router's share of the `COMBAT_LOG_EVENT_UNFILTERED`
channel, the routes by sub-event, the wildcard route and the listener count)
and the dispatcher its channel listener resolves through (`dispatchCombatLog`).
A revision-12 copy loading over revision 11 or older adds both in place with
no listener; a plain `Connect` listener the older copy made for the combat-log
event keeps its channel, which the router shares from the first
`ConnectCombatLog` on. Connections made before revision 12 carry no `_route`
field, which the newer disconnect reads as "a channel". A newer copy loading
over revision 12 keeps the router, its routes and its listeners, and the
channel listener the older copy connected follows the newer dispatcher.

Revision 11 moved `_state` from schema 6 to schema 7, adding the package's
`PLAYER_LOGOUT` connection (`logoutConnection`) and the two handlers the
logout routes resolve when they fire (`closeOnLogout`, `closeOnShutdown`);
addon scopes gain `_logoutRoute` and `_logoutSubscription`. A revision-11 copy
loading over revision 10 or older routes every carried addon scope as a first
`ForAddon` would (see [At logout](#at-logout)); a scope a revision 11 or later
copy already routed keeps its route, its subscription and the connection.

Revision 10 moved `_state` from schema 5 to schema 6, adding the package
sentinel (`unbounded`, published as `EventKit.UNBOUNDED`) and the shared limits
(`limits`). A revision-10 copy loading over revisions 7 to 9 adds both in place,
with `maxUnitFrames` at the former fixed cap of 64; Frames the older copy
created stay counted against it. A newer copy inherits the sentinel's identity
and the limits a consumer set.

Revisions 8 and 9 kept `_state` at schema 5. A copy loading over revision 7 or
8 adopts the state as it is; handles the older copy created close through the
newer code from then on.

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

### The combat log: no payload, two ways to listen

Since Legion `COMBAT_LOG_EVENT_UNFILTERED` delivers **no arguments**. The
client hands the event out through `CombatLogGetCurrentEventInfo()`, which is
only valid inside the handler. EventKit offers two ways to listen, sharing one
host registration:

| | `Connect("COMBAT_LOG_EVENT_UNFILTERED", callback)` | `ConnectCombatLog(subEvent, callback)` |
|---|---|---|
| The callback receives | `"COMBAT_LOG_EVENT_UNFILTERED"` and nothing else. | Every return of `CombatLogGetCurrentEventInfo()`, unchanged. |
| Who reads the client | The callback, itself, on every event. | EventKit, once per event for all combat-log listeners. |
| Which events reach it | Every one. | Its sub-event's, or every one with `"*"`. |
| Use it when | You need the raw event, or must read the client yourself. | Almost always. |

```lua
-- Raw: read the client yourself, filter yourself.
EventKit:Connect("COMBAT_LOG_EVENT_UNFILTERED", function()
    local timestamp, subEvent, hideCaster, sourceGUID = CombatLogGetCurrentEventInfo()
    if subEvent == "SPELL_DAMAGE" then
        -- ...
    end
end)

-- Routed: EventKit reads the client once and delivers by sub-event.
EventKit:ConnectCombatLog("SPELL_DAMAGE", function(timestamp, subEvent, hideCaster, sourceGUID)
    -- ...
end)
```

Either way, keep the handler short: this is the highest-frequency event in the
client.

**Retail 12 clients give addon code no event reader.** The retail, PTR and
beta metadata under `packages/apiKit/metadata/` list `GetCurrentEventInfo`
only under `C_CombatLogSecure` (restricted) and `C_CombatLogInternal`;
`C_CombatLog` keeps its filter and retention functions but not the reader, and
no `CombatLogGetCurrentEventInfo` global is listed. Measured in a real Retail
12.1.0 (build 69933) client on 2026-09-24 by
`tests/client/MoltenCodesTest_EventKit`: the global
`CombatLogGetCurrentEventInfo` and `GetCurrentEventInfo` under `C_CombatLog`,
`C_CombatLogInternal` and `C_CombatLogSecure` are all absent from addon code,
and `C_CombatLog.IsCombatLogRestricted()` returns `true`. There
`EventKit:IsCombatLogAvailable()` answers `false`, and `ConnectCombatLog`
raises the refusal above at the caller's line and registers nothing. The classic-era and classic-mop metadata
list `C_CombatLog.GetCurrentEventInfo`, which EventKit reads when the global
is absent. `COMBAT_LOG_EVENT_UNFILTERED` is a normal event, not a unit event. The
routed form is specified under
[`EventKit:ConnectCombatLog`](#eventkitconnectcombatlogsubevent-callback).

### Event names the client does not know

Every method that registers an event name the caller gave checks it with the
client's `C_EventUtils.IsEventValid` when the client has that function:
`Connect`, `Once`, `ConnectUnit`, `OnceUnit`, their scope forms, and every
event of `Coalesce` and `Derive`, as a single name or in an `events` array. A
name the client does not know is refused at the caller's line before anything
is registered or allocated (revision 15 and later):

```text
<Method> eventName "<name>" is not an event this client knows
<Method> events entry "<name>" is not an event this client knows
```

`<Method>` is `EventKit:Connect`, `EventKit.Scope:ConnectUnit`,
`EventKit:Coalesce` and so on. A `Coalesce` or `Derive` event given as a single
string is reported as `eventName`, like its other argument errors; an entry of
an `events` array as `events entry`.

Without the check, the client refuses the name inside `Frame:RegisterEvent`.
Measured on Retail 12.1.0 (2026-09-24), that error reads
`Frame:RegisterEvent(): Attempt to register unknown event "X"` and carries no
caller position, so the mistake could not be traced to the line that made it.

- **Order.** The name is checked for its type, then for being a
  [secret value](#secret-values), then with the client, so a wrong type or a
  secret is refused before the client is asked.
- **Probed once.** EventKit looks `C_EventUtils.IsEventValid` up once, when its
  file loads, as it does with the rest of the client's fixed API set. A client
  without it (older classic clients) keeps the previous behaviour: the name
  reaches `RegisterEvent`, and a registration the host refuses by returning
  `false` raises `<Method> could not register event <name>` at the caller's
  line.
- **Only a plain `false` refuses.** Any other answer leaves the verdict to the
  host's registration, so a client quirk never refuses a real event.
- **EventKit's own registrations are not checked**: its `PLAYER_LOGOUT`
  listener for addon scopes and the `COMBAT_LOG_EVENT_UNFILTERED` registration
  behind `ConnectCombatLog`. Combat-log sub-event names are not checked either;
  the client has no function that knows them.
- **Cost.** One `IsEventValid` call per subscribing call, and one per distinct
  name of a `Coalesce` or `Derive` list, asked only after the list passed its
  32-event bound. Nothing is added to event dispatch.

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

### Secret values

On a client with secret values, comparing a secret with a value of its own
type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike), and so does using it
as a table key or testing it as a boolean (`if x`, `x and y`, `x or y`,
`not x`); a comparison with `nil` or with a value of another type happens
not to raise (measured on Retail 12.1.0 b69933, see
[`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)).
EventKit still tests every value it did not create — arguments, option and
limit fields, event payloads, `compute` results — for absence with
`type(value) == "nil"`, the repository rule, which never compares anything, and
deals with a secret before it would compare one (revision 14 and later):

- A secret argument or option value is refused at the caller's line:

  ```text
  <Method> eventName must not be a secret value
  <Method> subEvent must not be a secret value
  <Method> unit token must not be a secret value
  <Method> events entry must not be a secret value
  <Method> intervalSeconds must not be a secret value
  <Method> byEvent must not be a secret value
  <Method> delaySeconds must not be a secret value
  EventKit:ForAddon addonName must not be a secret value
  EventKit:CloseAddonScopes addonName must not be a secret value
  EventKit:SetLimits limits.<name> must not be a secret value
  ```

- A facade method called with a dot and a secret first argument is refused as
  a call without the facade, by its type, before any comparison.
- A `Coalesce` payload whose first argument is secret is keyed by its event
  name, and a `Derive` value that is secret on either side counts as a change.
  Payloads themselves are passed to listeners untouched.
- A secret answer from a `Derive` `equals` function is never tested as a
  boolean: it counts as a change (revision 16 and later).
- A combat-log event whose sub-event is secret is not looked up by it: it
  reaches the wildcard listeners only (revision 16 and later).

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
