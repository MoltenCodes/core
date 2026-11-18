# EventKit API

EventKit API generation 1 provides lazy World of Warcraft event subscriptions with SignalKit API 1's dispatch semantics, without needing SignalKit itself.

Implementation revision: **23**. Parts: `Units` revision **1**, `CombatLog` revision **1**, `Coalescing` revision **2**.

EventKit is multi-tenant: one shared instance serves every addon in a WoW session.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
EventKit.lua
parts/EventKit-Units.lua        (optional: ConnectUnit and OnceUnit)
parts/EventKit-CombatLog.lua    (optional: ConnectCombatLog)
SignalKit.lua                   (only for the Coalescing part)
parts/EventKit-Coalescing.lua   (optional: Coalesce and Derive)
```

The core needs Registry alone; LifecycleKit is optional and found through
`Registry:Find` when an addon scope asks it (see [At logout](#at-logout)).
Revisions before 23 required SignalKit; the core now uses none of it, and only
the Coalescing part's `Derive` does, for its change listeners.

### Parts

EventKit is a core and three optional parts
([ADR 0001](../../../docs/decisions/0001-kit-core-and-parts.md)). The core is
`Connect`, `Once`, scopes, connection handles, isolation, the logout routes and
the limits: what AceEvent-3.0 gives an addon, and what most addons need.

| Part | File | Adds | Needs |
|---|---|---|---|
| `Units` | `parts/EventKit-Units.lua` | [`ConnectUnit` and `OnceUnit`](#eventkitconnectunitevent-callback-unit1--unit2), on the facade and on scopes | the core |
| `CombatLog` | `parts/EventKit-CombatLog.lua` | [`ConnectCombatLog`](#eventkitconnectcombatlogsubevent-callback), on the facade and on scopes | the core |
| `Coalescing` | `parts/EventKit-Coalescing.lua` | [`Coalesce` and `Derive`](#coalescing-events), on the facade and on scopes | the core and SignalKit; TimerKit to time them, SchedulerKit (with its Coalescing and Lanes parts) only for a `lane`; the `Units` part for the `units` option |

Each part loads after the core. `python3 -m tooling.package.embeds
eventKit/Units eventKit/CombatLog eventKit/Coalescing` prints the lines for an
`embeds.xml`. `IsCombatLogAvailable` and `SetLimits{ maxUnitFrames }` stay in
the core: the first answers for the client (Retail 12 gives addon code no
combat-log reader, so an addon there should not have to embed the part to
learn that), and the limit keeps `SetLimits` and `GetLimits` one shape.

Without a part its members stay on the facade and the scope prototype, so
every embedded copy's surface check still accepts them, and raise at the
caller's line with the file to embed:

```text
EventKit:ConnectUnit is in EventKit's Units part, which is not loaded: add eventKit\parts\EventKit-Units.lua to embeds.xml after eventKit\EventKit.lua
```

(`OnceUnit`, `ConnectCombatLog`, `Coalesce` and `Derive`, and the scope forms
`EventKit.Scope:<Member>`, the same way). A `Coalesce` or `Derive` `units`
option without the Units part raises `<Method> option "units" is in EventKit's
Units part, which is not loaded: ...`.

`EventKit:HasPart(name)` answers whether a part is installed in the session
(`EventKit:HasPart("Units")`). Code that uses a part optionally asks it,
because a stub satisfies `type(EventKit.ConnectUnit) == "function"`. A secret
name raises `EventKit:HasPart name must not be a secret value`, any other name
that is not a string `EventKit:HasPart name must be a part name string`.

A part loaded without its core, or over a core older than revision 23 (part
interface 2), raises `MoltenCodes EventKit part <Part> requires EventKit API 1
to be loaded first`; the Coalescing part loaded without SignalKit raises
`MoltenCodes EventKit part Coalescing requires SignalKit API 1 to be loaded
first`. Two addons may embed different revisions of a part; the highest serves
both, as for the core, and takes over the unit groups, the combat-log router or
the Coalesce and Derive handles in place.

Portable WoW code should resolve the package through Registry:

```lua
local EventKit = MoltenCodes.Registry:Get("eventKit", 1)
```

EventKit does not rely on `require()` at runtime.

The facade carries two read-only constants: `EventKit.API`, the API generation
(`1`), and `EventKit.REVISION`, the implementation revision of the copy that
is active in the session (`23` for this one). A newer embedded copy replaces
`REVISION` when it upgrades the facade in place. Loading errors are listed
under [Error messages](#error-messages).

## Public surface

| Member | Part | Returns |
|---|---|---|
| `EventKit.API`, `EventKit.REVISION` | core | `1`; the active implementation revision |
| [`EventKit:Connect(eventName, callback[, methodName])`](#eventkitconnecteventname-callback), [`EventKit:Once(...)`](#eventkitonceeventname-callback) | core | a connection |
| [`EventKit:ConnectUnit(eventName, callback, unit1[, unit2])`](#eventkitconnectunitevent-callback-unit1--unit2), [`EventKit:OnceUnit(...)`](#eventkitonceunitevent-callback-unit1--unit2) | Units | a connection |
| [`EventKit:ConnectCombatLog(subEvent, callback)`](#eventkitconnectcombatlogsubevent-callback) | CombatLog | a connection |
| [`EventKit:IsCombatLogAvailable()`](#eventkitiscombatlogavailable) | core | `boolean` |
| [`EventKit:CreateScope()`, `EventKit:ForAddon(addonName)`, `EventKit:CloseAddonScopes(addonName)`](#owner-scopes) | core | a scope; a scope; `boolean` |
| [`EventKit:Coalesce(...)`, `EventKit:Derive(...)`](#coalescing-events) | Coalescing | a handle |
| [`EventKit:SetLimits(limits)`, `EventKit:GetLimits()`, `EventKit.UNBOUNDED`](#limits) | core | nothing; a fresh table; the sentinel |
| [`EventKit:HasPart(name)`](#parts) | core | `boolean` |
| [`EventKit.Connection`](#connection-api): `Disconnect`, `IsConnected` | core | `boolean` |
| [`EventKit.Scope`](#scope-methods): the subscription methods above, `DisconnectAll`, `Close`, `IsClosed`, `Reopen`, `GetAddonName`, `GetActiveCount` | as the facade member | |

## `EventKit:Connect(eventName, callback)`

Subscribes to a normal WoW event and returns a connection. The callback receives `eventName, ...`: the WoW event name followed by the original event payload. The first active listener for an event registers the underlying Frame; additional listeners reuse that registration; the final disconnect unregisters it.

On a client with `C_EventUtils.IsEventValid`, a name the client does not know
is refused at the caller's line before anything is registered:
`EventKit:Connect eventName "X" is not an event this client knows`. Every
method that registers an event name does the same; see
[Event names the client does not know](#event-names-the-client-does-not-know).

### Method-name callbacks

`Connect`, `Once`, `ConnectUnit` and `OnceUnit` (and their scope forms) also
take a receiver table and a method name in place of the callback, the
counterpart of AceEvent's `self:RegisterEvent("EVENT", "OnEvent")`:

```lua
local events = EventKit:ForAddon("MyAddon")
events:Connect("BAG_UPDATE", MyAddon, "OnBagUpdate") -- MyAddon:OnBagUpdate("BAG_UPDATE", bagID)
events:Connect("PLAYER_LOGIN", MyAddon)              -- MyAddon:PLAYER_LOGIN("PLAYER_LOGIN")
events:ConnectUnit("UNIT_HEALTH", MyAddon, "OnHealth", "player")
```

- The method `receiver[methodName]` runs as `method(receiver, eventName, ...)`: the
  receiver, then exactly what a callback would receive.
- On `Connect` and `Once` the method name may be left out; it is then the
  event name, as in AceEvent. On `ConnectUnit` and `OnceUnit` it is required
  and comes before the unit tokens, because a unit token in its place would be
  ambiguous.
- The method must exist when the connection is made: `receiver` must be a
  table, the name a non-empty, non-secret string and `receiver[methodName]` a
  function, or the call raises at the caller's line (see
  [Error messages](#error-messages)). Nothing is registered then.
- **The method is looked up on the receiver at every delivery**, as AceEvent
  does. A method replaced afterwards, by the addon itself or by another
  addon's `HookKit` hook on it, is the one that runs for connections made
  before. A method that is gone by then (`nil`) raises inside the listener's
  isolation, which reports `EventKit receiver has no method "<name>"` to the
  host error handler; the connection stays, and delivers again once the
  method is back.
- Cost: one closure of two upvalues per connection, about 136 bytes on a
  64-bit Lua 5.1, and per delivery one extra Lua call and one table read
  (about 16 ns on the reference host). The function form is unchanged.
- `ConnectCombatLog`, `Coalesce` and `Derive` take functions only.

## `EventKit:Once(eventName, callback)`

Like `Connect`, but disconnects before the first callback invocation. Recursive/re-entrant dispatch therefore cannot invoke the one-shot listener twice.

## `EventKit:ConnectUnit(eventName, callback, unit1 [, unit2])`

In the [Units part](#parts). Subscribes with WoW's `Frame:RegisterUnitEvent` filtering. At least one non-empty string unit token is required. Duplicate tokens are removed and tokens are sorted before registration, so equivalent unit sets reuse one internal registration group regardless of caller order.

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

In the [Units part](#parts). Unit-filtered one-shot subscription with the same disconnect-before-callback guarantee as `Once`, and the same two-token limit as `ConnectUnit`.

## `EventKit:ConnectCombatLog(subEvent, callback)`

In the [CombatLog part](#parts). Subscribes to one **combat-log sub-event** and returns an ordinary connection.
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
listener array and two counts, like a channel) that leaves with the sub-event's last listener,
so routes are bounded by the live subscriptions, like event channels, and need
no limit of their own.

There is no one-shot form: a combat-log sub-event is a stream, and a listener
that wants a single occurrence disconnects itself.

## `EventKit:IsCombatLogAvailable()`

Returns `true` when EventKit can read the combat log on this client, that is
when the global `CombatLogGetCurrentEventInfo` or
`C_CombatLog.GetCurrentEventInfo` exists, and `false` otherwise. It is exactly
the condition under which `ConnectCombatLog` connects instead of refusing, so
an addon that wants combat-log data on every client asks first. It is in the
core, so the answer needs no part:

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
| `Reopen()` | Open a closed manual scope again, empty; `true` when it did, `false` when the scope was open. Revision 21. |
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

### Reopening a manual scope

`scope:Reopen()` opens a closed scope again, empty, so its owner can keep using
the same object. ModuleKit uses it to keep a module's `scope.Events` across
enable cycles. Connections the scope held when it closed stay disconnected; a
`Coalesce` or `Derive` handle stays closed. It answers `false` for an open scope.

An addon scope (`ForAddon`) cannot be reopened: closing it is its addon's
teardown. `Reopen` on one raises `EventKit.Scope:Reopen cannot reopen an addon
scope` at the caller's line.

When the scope was closed during a dispatch and reopened before that dispatch
returned, the connections it held are still swept when the outermost dispatch
returns (they move to a closed carrier that takes the scope's place in the
deferred sweep), and the connections made after the reopen are not.

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
2. **Otherwise** (no LifecycleKit, or one that does not list EventKit).
   EventKit keeps one package-level `PLAYER_LOGOUT` one-shot, connected by the
   first `ForAddon` that needs it, which closes every addon scope LifecycleKit
   does not close, in addon-name order.
3. **The host refused that registration.** Nothing is connected and
   `ForAddon` works as always; the next `ForAddon` for that addon tries again.
   Until one succeeds, call `CloseAddonScopes` yourself on `PLAYER_LOGOUT`:

```lua
EventKit:Once("PLAYER_LOGOUT", function()
  EventKit:CloseAddonScopes("MyAddon")
end)
```

Revisions before 23 also subscribed to `OnShutdown` of a LifecycleKit without
the capability, which only its never-published revisions before 13 lacked;
such a LifecycleKit is now covered by case 2.

Every case closes the scope inside the `PLAYER_LOGOUT` dispatch, so the
connections are swept only after that dispatch completes: a scoped
`PLAYER_LOGOUT` listener still runs, whether it was connected before or after
the listener that closed its scope (see *Closing during a dispatch*). From the
moment the scope closes it refuses new connections, so a listener that runs
after the close cannot connect through it. Before revision 6 a close from a
`PLAYER_LOGOUT` handler silently dropped a scoped `PLAYER_LOGOUT` listener
connected after it.

The routing costs one field read per `ForAddon` once decided. EventKit
allocates one connection for the whole package in case 2, and nothing per
addon.

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

A scoped connection carries three link fields, created with it; an unscoped
one carries none. Joining a scope and leaving it are a handful of field writes
on an intrusive doubly linked list: nothing is allocated beyond the handle,
and a disconnect unlinks in constant time. Dispatch is unchanged; a scoped listener costs exactly what a
package-level one does, and a spec guards that it allocates nothing per event.

## Coalescing events

`Coalesce` and `Derive` are the [Coalescing part](#parts). They are the event
half of the framework's coalescing family, whose other half (`Debounce`,
`Coalesce`, `Watch` and lanes for any code) is SchedulerKit's
([`docs/API.md`](../../schedulerKit/docs/API.md#coalescing-and-lanes)). Since
revision 22 they time themselves on TimerKit, with the rules below, which are
the ones SchedulerKit documents for its own `Coalesce` and `Debounce`; only a
`lane` goes through SchedulerKit.

### TimerKit is optional

EventKit does not depend on TimerKit or SchedulerKit. The part finds TimerKit
API 1 through `Registry:Find` **when a method is called**, so it may load after
EventKit, and remembers it once found. SchedulerKit API 1 is looked up only for
a `lane`.

| | With TimerKit | Without it |
|---|---|---|
| `Coalesce` | One callback per interval. | Refused at the caller: `EventKit:Coalesce requires TimerKit API 1, which is not available (absent)`. Nothing is registered. |
| `Coalesce` with `lane` | Timed by SchedulerKit's `Coalesce`, which needs SchedulerKit with its Coalescing and Lanes parts. | The same: TimerKit is not used. |
| `Derive` | Recompute after a quiet period, by default the next frame. | Recompute synchronously on every event. It still works; it just does not coalesce. |

A `lane` without SchedulerKit is refused with `<Method> requires SchedulerKit
API 1, which is not available (<reason>)`; with a SchedulerKit whose
Coalescing or Lanes part is not loaded, with `<Method> with a lane needs
SchedulerKit's Lanes part, which is not loaded: add
schedulerKit\parts\SchedulerKit-Lanes.lua to embeds.xml after
schedulerKit\SchedulerKit.lua` (or `Coalescing`, with its file).

Before revision 22 the table read "SchedulerKit is optional": `Coalesce` was
refused and `Derive` recomputed synchronously whenever SchedulerKit was
absent, even with TimerKit loaded.

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
| `maxKeys` | Distinct keys one interval may hold; default **256**. Past it, a new key is refused and counted; a key already in the set is still updated. |
| `lane` | A SchedulerKit lane every delivery goes through (SchedulerKit's `Coalesce` then times the handle). |

- Every value in the set is `true`. An event whose first argument is `nil`
  (or NaN, or a [secret value](#secret-values)) is keyed by its event name, so
  `BAG_UPDATE_DELAYED` still counts.
- **One timer per burst.** The first key arms one TimerKit timer for
  `intervalSeconds`; later keys in the interval only join the set. An
  interval of `0` means the next frame.
- **The set is reused.** It is one of two tables the handle swaps at every
  delivery. Without a lane it is emptied as soon as the callback returns;
  delivered through a lane it lives until the lane job reaches a terminal
  state, across retries, and is emptied then. Do not keep it; copy what you
  need. Keys recorded while the callback runs go into the other table and
  arrive with the next interval.
- If TimerKit cannot arm the timer on the first key, the failure is raised to
  that event's dispatch, which reports it through the listener isolation; the
  key stays collected, and the next event arms the timer again (or `Flush()`
  delivers it).
- A raising callback is reported through the host error handler, as any
  listener is; the next interval delivers as usual.

The handle:

| Method | Purpose |
|---|---|
| `Flush()` | Deliver now and cancel the interval's timer; `false` when nothing was collected or when called from inside the handle's own callback, or `false, "deferred"` / `false, "dropped"` when a lane did not take the delivery. |
| `IsPending()` | Whether payloads wait for delivery. |
| `GetStats()` | `{ keys, refused, delivered, deferred, dropped }`, in one table reused by every call. `deferred` and `dropped` count only lane deliveries. |
| `Close()` | Unregister the events, drop what was collected, cancel the timer, leave the scope. Terminal; `false` if already closed. A closed handle still answers `IsPending` (`false`) and `GetStats`. |
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
| `delaySeconds` | Quiet period before recomputing; `0`, the default, is the next frame. |
| `equals` | `fun(previous, current): boolean` deciding whether a new value is the same; `==` when omitted. |
| `units` | One or two unit tokens, as for `Coalesce`. |

**The quiet period.** Each event (or `Invalidate()`) restarts it by recording
the time on `GetTimePreciseSec`, the clock TimerKit's deadlines use. The first
call of a burst arms one timer for `delaySeconds`; a call inside the window
does not re-arm it. When the timer wakes before the burst has been quiet for
`delaySeconds`, it re-arms once for the remainder, never longer than the delay
itself; a timer that wakes within one millisecond of its due time counts as
due. On a host without `GetTimePreciseSec` the recompute runs when the timer
wakes. If TimerKit cannot arm the timer on the first call of a burst, the
failure is raised to that caller (the event's dispatch reports it, or
`Invalidate()` raises it) and nothing stays pending. Whether a handle uses
TimerKit is decided when it is created.

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
release it with everything it owns — its event registrations and its timer
(or, for a lane, its SchedulerKit timing handle) — and closing a scope during
a dispatch defers that, as for any connection. The scope sweep closes a
handle through `state.composites.close`, which the part fills (since revision
23; the core closed handles before). The handle's own event
connections are internal and belong to no scope. A `Derive` whose `compute`
closes the scope it is being created in is refused with `EventKit.Scope:Derive
cannot connect in a closed scope` and leaves nothing registered.

The timers live in one TimerKit scope private to the part, created with the
first timer and created again if it was ever closed; it is not TimerKit's
package-level scope, so closing that from elsewhere cannot stop a handle. Lane
handles keep their SchedulerKit timing in one SchedulerKit scope private to
EventKit, as since revision 18.

### Cost

The per-event path is one isolated listener call, one table write into a
reused set and, at the first key of an interval, one TimerKit timer: a spec
guards that steady-state events allocate nothing. Creating and closing a
`Coalesce` handle for two events allocates about 1.8 KB on Lua 5.1, and a live
one holds about 1.2 KB (its record of 16 fields, two sets, its event list, one
closure and its event connections), with no SchedulerKit handle. TimerKit is
looked up through `Registry:Find` until it is found and not again afterwards.
The Coalescing part itself holds about 42 KB resident when loaded; an addon
that does not embed it pays nothing for it.

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
at the calling line. Since revision 21 the receiver test is metatable identity:
the connection metatable lives in `_state`, so every handle an older copy made
carries it after the upgrade converts it. A disconnected handle of revisions 17
to 20 that the conversion could not reach (no listener array held it) keeps its
named fields and is still recognised by them.

## Registration architecture

Normal events share one lazily created Frame.

Unit events cannot all safely share that same Frame: repeated `RegisterUnitEvent` calls for the same event on one Frame replace the prior unit filter. EventKit therefore maintains one cached Frame for each normalized unit-filter set. Different event names using the same unit set share that Frame.

### Unit-group lifetime

A unit group is released as soon as its last channel loses its last listener.
Releasing detaches the Frame's `OnEvent` handler — so an event the host already
queued cannot reach a group that no longer exists — and returns the Frame to a
free list. The next unit set to be subscribed re-purposes a free Frame:
`RegisterUnitEvent` re-points it and `UnregisterEvent` clears it again. A
group created for a registration the host refuses, by returning `false` or by
raising, is released the same way before the error reaches the caller (a
raising host since revision 19).

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

## Secret values

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
  <Method> methodName must not be a secret value
  EventKit:HasPart name must not be a secret value
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
- `methodName` in the method form is refused when secret, like the other
  arguments (revision 21).
- The client's `issecretvalue` is resolved once, when the copy loads; every
  client flavour defines it before any addon runs. Only when it was absent at
  load is the global read again on each check, so a probe installed later (a
  test environment, a compatibility shim) is still honoured (revision 21; the
  shared `isSecret` block since revision 23).

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
limit; it accepts maxUnitFrames`; a secret key is shown as `<secret>`, a string key is shown as written, a number or boolean as `tostring`
gives it, and any other key by its type, `limits.<table>`, so a key's
`__tostring`, the caller's code, never runs), a value that is not an integer from 1 to the ceiling (`... must be an
integer from 1 to 512`), a secret value (`... must not be a secret value`) and
`EventKit.UNBOUNDED` (`... cannot be EventKit.UNBOUNDED: the client never
frees a Frame`). The check is the shared `limits` block
(`tooling/shared/lua/limits.lua`). The limit stays in the core, so it is set
and read with or without the Units part, which enforces it. `GetLimits()` returns a
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
registrations and are released with it. The logout routing holds one
`PLAYER_LOGOUT` connection for the package. Combat-log routes are released
with their sub-event's last listener, as event channels are, so they carry no
limit either (see [`ConnectCombatLog`](#eventkitconnectcombatlogsubevent-callback)).

## Dispatch semantics

Listener ordering, mutation safety, and recursive dispatch follow SignalKit API 1 semantics within one registration channel. Since revision 17 EventKit keeps each channel's (and each combat-log route's) connections in an array of its own that applies those rules, rather than on a SignalKit signal, so that a connection is one handle and a delivery one isolated call:

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

The walk over a channel's listeners runs inside a second, protected call only
while the channel holds a one-shot listener, whose release talks to the host.
Listener calls are
isolated either way, so a raising listener never reaches the walk, and the
dispatch depth is restored on every path that can raise.

Isolation is per listener: EventKit's dispatch calls every listener through
the isolation function below. (Before revision 17 each subscription carried a
wrapper closure that isolated it, handed to a SignalKit signal, since
SignalKit propagates listener errors.)

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

### Cost of a connection

A connection is one table, the handle, which is also the channel's record of
the listener. Its fields live in the table's array part: 128 bytes on a 64-bit
Lua 5.1 for an unscoped connection (four slots) and 176 for a scoped one
(seven), plus one 16-byte slot in the channel's listener array. Before revision
21 the fields were named: 224 and 384 bytes. The handle is inherent to the
contract: it stays valid after `Disconnect` and keeps answering
`IsConnected` with `false`, so EventKit cannot take it back and reuse it.

Outside a dispatch a disconnect edits the channel's array in place and
allocates nothing; during one, a disconnect leaves a tombstone and the array
is compacted into a copy at half tombstones, so the running dispatch keeps its
own (see [`docs/INTERNALS.md`](INTERNALS.md)). When an event's last listener
goes, its channel record and array are kept for the next channel in a pool of
at most 16, so connecting the only listener of an event again allocates the
handle and nothing of EventKit's own; the host's `RegisterEvent` is the
client's cost. Specs guard both (`ListenerStorage_spec.lua`).

Measured with the host benchmark (`docs/BENCHMARKS.md`, Lua 5.1.5, both sides
in the same run, 2026-09-25) against AceEvent-3.0: dispatch to 1, 10 and 100
listeners takes 1.08×, 0.95× and 0.99× of AceEvent's time; connecting and
disconnecting one listener beside ten others 1.30×, with 224 bytes against
none; the only listener 1.52×, with 328 bytes against 104 (both sides pay the
fake client's 104-byte registration record). The remaining difference is the
handle, and the ordering, scope and isolation bookkeeping the contract
promises.

## Error behaviour

Every argument and receiver error below is raised at the caller's line, never
inside EventKit. `<Method>` is the qualified public method, for example
`EventKit:Connect` or `EventKit.Scope:ConnectUnit`; `<...>` marks a value
filled in from the call. A secret argument is refused first, with the messages
listed under [Secret values](#secret-values).

| Raised by | Message |
|---|---|
| `Connect`, `Once`, `ConnectUnit`, `OnceUnit` and their scope forms | `<Method> eventName must be a non-empty string`; `<Method> eventName "<name>" is not an event this client knows` (see [Event names the client does not know](#event-names-the-client-does-not-know)) |
| `ConnectCombatLog` and its scope form | `<Method> subEvent must be a non-empty string`; `<Method> the combat log is not available to addons on this client (no CombatLogGetCurrentEventInfo reader); check EventKit:IsCombatLogAvailable() first` |
| `Connect`, `Once`, `ConnectUnit`, `OnceUnit` and their scope forms | `<Method> callback must be a function, or a receiver table followed by a method name`; `<Method> methodName must be a non-empty string`; `<Method> receiver has no method "<name>"` (also when the field is not a function); a secret method name: `<Method> methodName must not be a secret value` |
| `ConnectCombatLog`, `Coalesce` | `<Method> callback must be a function` |
| `Scope:Reopen` on an addon scope | `EventKit.Scope:Reopen cannot reopen an addon scope` |
| `ConnectUnit`, `OnceUnit`, the `units` option | `<Method> requires at least one unit token`; `<Method> unit tokens must be non-empty strings`; `<Method> accepts at most 2 distinct unit tokens because Frame:RegisterUnitEvent has 2 filter slots; received <count>`; for the option, `<Method> units must be an array of one or two unit tokens` |
| a registration the host refuses with `false` | `<Method> could not register event <name>` |
| a scope method on something that is not a scope | `<Method> must be called on an EventKit scope` |
| a connecting scope method, `Coalesce` or `Derive` on a closed scope | `<Method> cannot connect in a closed scope` |
| `connection:Disconnect()`, `connection:IsConnected()` without a handle | `EventKit:Disconnect must be called on a connection handle; use connection:Disconnect()`; the same for `IsConnected` |
| `Coalesce`, `Derive` | `<Method> events must be an event name or a non-empty array of them`; `<Method> events must contain only non-empty strings`; `<Method> accepts at most 32 distinct events`; `<Method> options must be a table`; `<Method> options contains unknown field "<field>"` (the first unknown field in sorted order; a key that is not a string, number or boolean is named by its type, `"<table>"`, and its `__tostring` never runs) |
| `Coalesce` | `<Method> intervalSeconds must be a finite number greater than or equal to zero`; `<Method> byEvent must be a boolean`; `<Method> requires TimerKit API 1, which is not available (<reason>)`, with Registry's `Find` reason; `<Method>: SchedulerKit.Scope:Coalesce maxKeys must be a finite positive integer` (or `... must not be a secret value`), the wording SchedulerKit gave it before revision 22, kept; with a `lane`: `<Method> requires SchedulerKit API 1, which is not available (<reason>)`, `<Method> with a lane needs SchedulerKit's <Part> part, which is not loaded: add <file> to embeds.xml after schedulerKit\\SchedulerKit.lua`, and `<Method>: <SchedulerKit's refusal>` for a `maxKeys` or `lane` SchedulerKit refuses, its position removed |
| a member of a part that is not loaded: `ConnectUnit`, `OnceUnit` (Units), `ConnectCombatLog` (CombatLog), `Coalesce`, `Derive` (Coalescing), and their scope forms | `<Method> is in EventKit's <Part> part, which is not loaded: add eventKit\\parts\\EventKit-<Part>.lua to embeds.xml after eventKit\\EventKit.lua` |
| the `units` option of `Coalesce` or `Derive` without the Units part | `<Method> option "units" is in EventKit's Units part, which is not loaded: add eventKit\\parts\\EventKit-Units.lua to embeds.xml after eventKit\\EventKit.lua` |
| `HasPart` | `EventKit:HasPart name must be a part name string`; a secret name: `EventKit:HasPart name must not be a secret value` |
| `Derive` | `<Method> compute must be a function`; `<Method> delaySeconds must be a finite number greater than or equal to zero`; `<Method> equals must be a function` |
| a `Coalesce` or `Derive` handle method on something else | `EventKit.CoalesceHandle:<Method> must be called on an EventKit coalesce handle`; `EventKit.DeriveHandle:<Method> must be called on an EventKit derived value` |
| `OnChange` | `EventKit.DeriveHandle:OnChange callback must be a function`; `EventKit.DeriveHandle:OnChange cannot subscribe to a closed derived value` |
| `ForAddon`, `CloseAddonScopes` | `EventKit:ForAddon addonName must be a non-empty string`; `EventKit:CloseAddonScopes addonName must be a non-empty string`; `EventKit:CloseAddonScopes must be called on the EventKit facade; use EventKit:CloseAddonScopes(addonName)` |
| `SetLimits`, `GetLimits` | `EventKit:SetLimits limits must be a table`; `EventKit:SetLimits limits.<name> is not a recognised limit; it accepts maxUnitFrames`; `EventKit:SetLimits limits.<name> must be an integer from 1 to <ceiling>`; `EventKit:SetLimits limits.<name> must not be a secret value`; `EventKit:SetLimits limits.<name> cannot be EventKit.UNBOUNDED: <reason>`; `EventKit:SetLimits must be called on the EventKit facade; use EventKit:SetLimits(limits)`; `EventKit:GetLimits must be called on the EventKit facade; use EventKit:GetLimits()` |

Host-environment failures carry no position, because the caller's arguments
did not cause them:

| Message | Raised by |
|---|---|
| `EventKit: requires the World of Warcraft CreateFrame API`; `EventKit: CreateFrame returned no Frame`; `EventKit: requires Frame:<method> support` | the first registration that needs a Frame on a host without one, or a Frame without the method |
| `EventKit: refusing to create more than <n> unit-filter Frames; ...` | a unit subscription past `maxUnitFrames` (see [Unit-group lifetime](#unit-group-lifetime)) |
| the host's own error object, unchanged | a `RegisterUnitEvent` that raised (the group created for it is released first) |

Reported through the host error handler, never raised: a failing listener
(see [Listener isolation](#listener-isolation)), and, once per part, the
retirement of unit or combat-log connections revision 22 made when the part is
not loaded (see [Embedded copies and upgrades](#embedded-copies-and-upgrades)):
`MoltenCodes EventKit disconnected the unit-event connections an earlier
revision made: their delivery is in EventKit's Units part, which is not
loaded: ...` (and the same for `combat-log connections` and the CombatLog
part).

Loading `EventKit.lua` raises `MoltenCodes EventKit requires Registry API 2 to
be loaded first`, `MoltenCodes EventKit requires a valid Registry API 2
facade`, `MoltenCodes EventKit revision 23 upgrades revision 22 or newer in
place, not revision <n>` over a copy below the [upgrade floor](#embedded-copies-and-upgrades),
or `MoltenCodes EventKit package state is corrupted or incomplete`. The part
files' load errors are listed under [Parts](#parts).

## Performance

Per event, per connection and per scope the core costs what the sections
above say: dispatch one isolated call per listener and no allocation
([Listener isolation](#listener-isolation)); a connection 128 or 176 bytes
([Cost of a connection](#cost-of-a-connection)); a scope's links a few field
writes (the *Cost* note under [Owner scopes](#owner-scopes)). The parts cost
what their sections' *Cost* notes say; none of them adds work to a `Connect`
listener's path.

Resident memory after a full collection, measured on the shared fake client
(Lua 5.1.5, 64-bit, debug information kept as the client keeps it, each file
loaded in one process after Registry):

| File | Revision 22 | Revision 23 |
|---|---:|---:|
| `EventKit.lua` (core) | 87.2 KB | 66.3 KB |
| `parts/EventKit-Units.lua` | (in the core) | 9.2 KB |
| `parts/EventKit-CombatLog.lua` | (in the core) | 6.9 KB |
| `parts/EventKit-Coalescing.lua` | 37.4 KB | 40.5 KB |

An addon that embeds the core alone no longer loads SignalKit (90.3 KB).
Loading the core allocates 216.7 KB transiently (284.4 KB for revision 22),
most of it the compiler's, freed after load. AceEvent-3.0 with
CallbackHandler-1.0 is 17.3 KB on the same host; the difference is the
documented guarantees (handles, scopes and their logout routes, caller-line
argument errors, secret-value refusals, bounded limits, in-place upgrade).



## Embedded copies and upgrades

Registry owns one stable EventKit table for `(eventKit, API 1)`. Compatible higher implementation revisions update that table in place. Existing connection handles resolve methods through a stable shared `Connection` method table; Frames resolve their dispatcher through `_state` (`dispatchRegular`, and `dispatchUnit` and `dispatchCombatLog`, which the Units and CombatLog parts fill). Scopes, connection handles and `Coalesce`/`Derive` handles are validated by metatables kept in `_state`, and handle listeners resolve their behaviour through it, so handles created by an older copy run the newer code.

**The upgrade floor.** No revision of EventKit has been published, so revision
23 upgrades in place only from revision 22, the revision it replaces. A copy
older than 22 that loaded first is refused: `MoltenCodes EventKit revision 23
upgrades revision 22 or newer in place, not revision <n>`. The adoption code
of older revisions (named connection handles, SignalKit fan-outs, the state
migrations of schemas 1 to 9, the `_DispatchRegular` and `_DispatchUnit`
facade fields, revision 21's SchedulerKit-timed handles) is gone with them.
`_state` stays at schema 10.

**From revision 22.** Revision 23 moves unit events and the combat log into
the Units and CombatLog parts and adds the part interface 2: `state.dispatch`
(`releaseUnitGroup`, `releaseRoute`), filled by those parts, and the helpers
they call. Unit groups, their Frames and the combat-log router stay in
`_state`, so the parts loaded with the core take over the unit and combat-log
connections revision 22 made, and keep delivering them. When a part is not
loaded, its connections cannot be served: they are disconnected (their
Frames go back to the free list, the router's share of the registration is
released) on the next frame, after every part the addon embeds has loaded, or
by the first event that reaches them, and the host error handler is told once
per part which file to embed. A Units part loaded later reuses those Frames.

The Coalescing part's revision 2 closes its own handles (`state.composites.close`,
which the core's scope sweep calls) and requires SignalKit itself. Handles its
revision 1 made keep working under it. A revision 1 of the part loaded after a
revision 23 core is served by the core's own minimal close: the handle's
events are disconnected and it leaves its scope, and its pending timer then
finds it closed.

Revision 23 also removes the `OnShutdown` logout route (see
[At logout](#at-logout)); an addon scope revision 22 routed that way is closed
by the `PLAYER_LOGOUT` route instead, when that connection exists.

A part keeps its own revision in `_state.parts`: the highest revision of the
part serves every addon, and a core upgraded after the part loaded leaves the
part's members in place and serves it through `helpers`.

The [changelog](../CHANGELOG.md) records what each earlier revision changed.

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

- **Order.** The name is checked for being a
  [secret value](#secret-values), then for its type, then with the client, so
  a secret or a wrong type is refused before the client is asked, and no test
  compares a secret.
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

### Reserved fields

Every underscore-prefixed field on the EventKit facade is reserved package
storage:

```lua
EventKit._state             -- shared runtime state
```

It is not public API. Consumers must not read or write it, and a compatible
revision may change its shape. Revisions before 23 also kept
`_DispatchRegular` and `_DispatchUnit` on the facade for Frames revision 1
made; revision 23 removes them with the upgrade floor.
