# SignalKit API

Package: `signalKit`  
API generation: `1`  
Implementation revision: `5`

SignalKit provides deterministic callback dispatch with explicit connection lifetimes, and named message buses built on the same signals.

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

Bus deliveries are the exception: a bus is shared across addons, so its
listener errors are isolated and reported instead. See
[Named message buses](#named-message-buses).

## `signal:DisconnectAll()`

Disconnects every listener connected at the moment of the call and returns the number of connections that were disconnected.

```lua
local removed = changed:DisconnectAll()
```

Calling it when no listeners are connected returns `0`.

## Connection

Connections are created only by `Connect()`, `Once()` and the bus subscription methods. `SignalKit.Connection` is the shared method prototype used by connection handles; it is exposed for introspection, not as a constructor.

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
| `bus:Publish(...)` | `O(n)` plus the validator | none |
| `bus:Subscribe(...)` | amortized `O(1)` | one handle and one delivery closure |
| `bus:Unsubscribe(...)` | `O(n)` | none, except on compaction |

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

## Named message buses

A signal is anonymous: only code that holds the reference can connect to it or
fire it. A **bus** is a named, package-wide map from topic to signal, so two
modules or two addons that share no reference can still talk by agreeing on a
bus name and a topic.

```lua
-- In the addon that owns the information.
local bus = SignalKit:ForAddon("MyAddon")
bus:DeclareTopic("ProfileChanged", {
    arguments = 1,
    description = "The active profile changed; the argument is its name.",
})
bus:Publish("ProfileChanged", "Default")

-- In a module or another addon that holds no reference to the first one.
SignalKit:Bus("MyAddon"):Subscribe("ProfileChanged", function(profileName)
    print("profile is now", profileName)
end)
```

Each topic is dispatched through an ordinary SignalKit signal, created when the
topic is first subscribed to. Ordering, mutation during dispatch, `Once`
semantics and re-entrancy are therefore exactly those documented for
`signal:Fire` above; the bus adds naming, a topic policy and listener
isolation, and never a second dispatch model.

### Bounds

| Bound | Default | Refusal |
|---|---:|---|
| Buses in the session (`maxBuses`) | 64 | `SignalKit:Bus` and `SignalKit:ForAddon` return `nil, "full"` |
| Topics one bus knows, declared or subscribed (`maxTopics`) | 256 | `DeclareTopic`, and a subscription to a new topic, return `nil, "full"` |
| Live listeners per topic (`maxListeners`) | 256 | `Subscribe` and `SubscribeOnce` return `nil, "full"` |

Each bound can be opened; see [Limits](#limits). A disconnected listener frees
its slot at once.

### `SignalKit:Bus(name, options)`

Returns the bus called `name`, creating it on the first request. Every later
request for the same name, from any addon, returns the same bus.

- `name` must be a non-empty string. On clients with `issecretvalue`, a secret
  name is refused at the caller before it is compared; the same applies to
  every topic argument of the bus methods.
- `options.openTopics` (`boolean`, default `false`) lets `Publish` use topics
  that were never declared. It is read only when the bus is created; stating a
  different policy for an existing bus raises at the caller, and omitting
  `options` accepts the existing policy.
- `options.maxTopics` and `options.maxListeners` (a positive integer or
  `SignalKit.UNBOUNDED`, default 256 each) set the bus's topic and per-topic
  listener bounds. The first caller that states one sets it for the shared
  bus, whichever order the addons load in; stating a different value later
  raises at the caller and changes nothing, and omitting it accepts what the
  bus has. See [Limits](#limits).
- Returns `nil, "full"` when `maxBuses` buses (64 by default) already exist.

`SignalKit:Bus` must be called on the facade with a colon. A dot call, or a
call through a signal instance (which inherits the facade's methods), raises at
the calling line.

### `SignalKit:ForAddon(addonName)`

Returns the default bus of an addon: the bus named after it, exactly as
`SignalKit:Bus(addonName)` does. It takes no limit options and states none, so
it never fixes the bus's limits; open them with
`SignalKit:Bus(addonName, { maxTopics = n })`. See
[Limit options on shared objects](#limit-options-on-shared-objects).

### `SignalKit:CloseAddonBus(addonName)`

Closes the bus named `addonName` and disconnects every subscription on it,
including those made through its scopes. Returns `true` when this call closed
the bus, and `false` when there is no such bus or it was already closed. An
addon that never asked for a bus is not recorded, so no bus slot is spent.

Closing is terminal. The closed bus stays registered under its name, so
`ForAddon` and `Bus` keep returning it; it then refuses `Subscribe`,
`SubscribeOnce`, scope subscriptions, `CreateScope` and `DeclareTopic` at the
caller, so a closed bus never spends another topic slot. `Publish` on it
delivers nothing and skips the topic policy, because other addons' shutdown
paths may still publish into it; the topic is still checked to be a non-empty
string.

SignalKit does not observe addon shutdown itself. Whoever does calls
`CloseAddonBus` at the addon's shutdown, the same two-step arrangement as
EventKit's `CloseAddonScopes`, and `ForAddon` makes sure somebody does: see
[At logout](#at-logout).

### At logout

An addon's bus is closed at logout whenever the framework can observe logout
at all, whichever LifecycleKit, EventKit and SignalKit revisions an addon set
pairs. SignalKit depends on neither Kit (design constitution, principle 4b);
`SignalKit:ForAddon` finds them with `Registry:Find` and decides who closes the
bus named after the addon:

| Case | Registered | Who closes the addon's bus |
|---|---|---|
| (a) | LifecycleKit whose `LifecycleKit.CLOSES_ADDON_SCOPES` names `signalKit` (0.6.0 and later) | LifecycleKit, after the addon's shutdown callbacks and last of the addon's scopes. `ForAddon` only makes sure the addon has a LifecycleKit instance (`LifecycleKit:ForAddon(addonName)`), because LifecycleKit closes the buses of the addons it tracks. |
| (b) | LifecycleKit without that field (older revisions) | SignalKit subscribes once to `LifecycleKit:ForAddon(addonName):OnShutdown` and calls `CloseAddonBus` there. The subscription is kept on the bus and disconnected when the bus closes first. |
| (c) | EventKit, no LifecycleKit | One package-level EventKit `Once("PLAYER_LOGOUT")` connection, in SignalKit's own EventKit scope and made on the first `ForAddon` that needs it, closes every addon bus in cases (c) and (d), in name order. |
| (d) | neither | Nothing is subscribed. The consumer closes the bus itself on `PLAYER_LOGOUT`: `SignalKit:CloseAddonBus("MyAddon")`. |

The decision is made at the first `ForAddon(addonName)` and taken again by
every later `ForAddon` while it is (c) or (d), so a LifecycleKit that loads
after the first call still takes the bus over. The (c) watcher leaves a bus
that moved to (a) or (b) to LifecycleKit. A failure in another Kit while
deciding goes to the host error handler; `ForAddon` still returns the bus, and
the next call asks again.

Only a bus `ForAddon` has returned is closed at logout. A bus obtained only
through `SignalKit:Bus(name)` is a shared bus, not an addon's, and stays open
even when its name is an addon's; once `ForAddon` names it, it is that addon's
bus.

In case (b) SignalKit's `OnShutdown` subscription is made at the first
`ForAddon`, so it runs before the addon's own shutdown callbacks subscribed
later, which then find the bus closed. Only case (a) guarantees that shutdown
callbacks can still publish to their subscribers, which is why LifecycleKit
0.6.0 announces the list.

### Topic policy: `bus:DeclareTopic(topic, options)`

Declares `topic` on the bus and returns `true`, or `nil, "full"` when the bus
already knows its `maxTopics` topics (256 by default).

| Option | Type | Meaning |
|---|---|---|
| `arguments` | integer | `Publish` must pass exactly this many arguments, counting explicit `nil`s (`select("#", ...)`). A negative, fractional, infinite or NaN count is refused at the caller. |
| `arguments` | `fun(...): boolean, string?` | A validator called with the published arguments. `true` accepts; anything else refuses, and the second return value becomes the reason. |
| `arguments` | omitted | Any arguments are accepted. |
| `description` | string | What the topic means. It documents the topic at its declaration and is kept with it; no method returns it. |

`bus:Publish` on an undeclared topic raises at the publisher's line unless the
bus was created with `openTopics = true`. On any bus, arguments that fail a
declared policy raise at the publisher's line, and nothing is delivered:

```text
SignalKit.Bus:Publish topic "Level" on bus "MyAddon" refused its arguments: level must be a number
```

Declaring the same topic again with the same `arguments` value (the same count,
or the same validator function) succeeds and changes nothing, so a publisher
and a consumer may both declare a topic. A different policy raises at the
caller.

**Declared or open.** Declared topics make a bus self-documenting — `Topics()`
lists the topics it carries — and turn a misspelt topic
into an error at the publishing line instead of a message nobody receives. An
open bus trades both away for zero ceremony, which suits prototypes and
throwaway tooling. Declared is the default and the recommendation for anything
another module or addon depends on.

**Subscribing needs no declaration.** A subscriber may subscribe before the
publisher declares the topic, so the order in which modules and addons load
never matters. The declaration governs publishing only.

**Secret values.** The bus never inspects published arguments; only a
validator does. On clients that mark values secret, comparing a secret value
raises, so a validator that compares its arguments must test each with
`issecretvalue` first and refuse or skip a secret one. A refusal reason that is
itself secret is never placed in the error message.

A validator that raises does not propagate from its own line: the validator
may belong to another addon than the publisher. Its failure becomes a refusal
at the publishing line, and nothing is delivered:

```text
SignalKit.Bus:Publish validator for topic "Level" on bus "MyAddon" failed: <the validator's error>
```

SignalKit never adds the published argument values to a refusal message; only
the validator's own reason or error text appears, and a secret one is replaced.
The protected call passes the arguments through and allocates nothing.

### `bus:Publish(topic, ...)`

Validates the topic and arguments as above, then delivers `...` to every
subscriber of `topic` in subscription order. A topic nobody subscribed to still
has its policy applied — an argument count, or the validator runs — and then
delivers nothing; it allocates nothing either way.

**Listener errors are isolated.** A raw signal belongs to whoever holds it, so
its listener errors propagate to the caller of `Fire`, who owns the listeners.
A bus is shared by every addon in the session: the publisher does not own its
subscribers, and one subscriber must not stop delivery to the ones behind it.
Each bus delivery therefore runs through `securecallfunction` when the client
provides it — which also keeps one subscriber's taint out of the next — and
through `xpcall` otherwise. A failure is reported through the host error
handler (`geterrorhandler()`, or `print` outside the client) and never reaches
the publisher. See the taint section of
[`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#taint).

The `xpcall` path stages the payload in one reusable buffer and one reusable
trampoline, so a steady-state publish allocates nothing of SignalKit's own on
either path. The `xpcall` path is guarded by a spec; on the other path the cost
of `securecallfunction` itself is the client's.

### `bus:Subscribe(topic, callback)` and `bus:SubscribeOnce(topic, callback)`

Subscribe `callback` to every future publish of `topic`, or to at most one.
They return an ordinary SignalKit connection handle — `connection:Disconnect()`
and `connection:IsConnected()` behave exactly as documented above — or
`nil, "full"` at the topic or listener bound. A `SubscribeOnce` subscription is
disconnected before its callback runs, like `signal:Once`.

Each subscription allocates one connection handle and one delivery closure; no
publish allocates.

### `bus:Unsubscribe(topic, callback)`

Disconnects every subscription of `callback` to `topic` and returns how many it
disconnected. Holding the connection handle and calling `Disconnect` is cheaper
(`O(1)` against `O(n)` in the topic's listeners) and is the preferred form;
`Unsubscribe` exists for code that keeps only the function.

### `bus:Topics()`

Returns a new array of the declared topic names, sorted. Topics that are only
subscribed to are left out. It allocates and is meant for diagnostics.

### Scopes: `bus:CreateScope()`

Returns an ownership scope over the bus, so one call releases everything an
owner subscribed to. It mirrors EventKit's scopes.

| Method | Meaning |
|---|---|
| `scope:Subscribe(topic, callback)` | As `bus:Subscribe`, owned by the scope. |
| `scope:SubscribeOnce(topic, callback)` | As `bus:SubscribeOnce`, owned by the scope. |
| `scope:DisconnectAll()` | Disconnects every subscription the scope owns and returns the count; the scope stays usable. |
| `scope:Close()` | Disconnects everything and closes the scope terminally; `false` when it was already closed. Later subscriptions raise at the caller. |
| `scope:IsClosed()` | Whether the scope is closed. |

Closing or disconnecting a scope during a publish takes effect at once: its
subscribers that have not run yet are skipped, exactly as SignalKit's own
disconnect rule says. (EventKit instead defers a scope sweep until the event's
dispatch ends; buses keep the signal rule so that their dispatch semantics stay
exactly a signal's.)

A scope remembers its connections in an array. Whatever disconnects one of
them — its handle, `bus:Unsubscribe`, a `SubscribeOnce` delivery, or the bus
closing — the scope counts it, and compacts the array in place as soon as the
disconnected entries outnumber the connected ones. The array therefore never
holds more than twice the subscriptions still connected, plus one, and the
compaction is amortized `O(1)` per disconnect.

`CreateScope` on a closed bus raises at the caller.

## Limits

SignalKit follows the framework rule "bounded by default, opened on purpose":
every bound below holds unless the consumer's code says otherwise, and a bound
reached is refused with `nil, "full"`, never grown silently.

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---:|---|---|
| `maxBuses` — named buses in the session | 64 | `SignalKit:SetLimits({ maxBuses = n })`, `n` from 1 to 1024 | No: buses are shared by every addon and never freed |
| `maxTopics` — topics one bus knows | 256 | `SignalKit:Bus(name, { maxTopics = n })` | Yes: the topics are the bus owner's own registrations |
| `maxListeners` — live listeners per topic | 256 | `SignalKit:Bus(name, { maxListeners = n })` | Yes: the listeners are the subscribers' own registrations |

```lua
-- A bus whose owner expects many topics and many listeners per topic.
local bus = SignalKit:Bus("MyAddon", {
    maxTopics = 1024,
    maxListeners = SignalKit.UNBOUNDED,
})

-- A package-wide limit: read it back as a fresh table.
SignalKit:SetLimits({ maxBuses = 128 })
local limits = SignalKit:GetLimits() -- { maxBuses = 128 }
```

### `SignalKit.UNBOUNDED`

One sentinel table, the same in every embedded copy and kept across upgrades,
so `options.maxTopics == SignalKit.UNBOUNDED` stays true after a newer revision
loads. A per-bus option set to it lifts that bound for that bus only.

### `SignalKit:SetLimits(limits)`

Changes any subset of the package-wide limits; `maxBuses` is the only one.
The whole table is validated before anything changes, so one invalid entry
leaves every limit as it was. An unknown name, a value that is not an integer
from 1 to 1024, `SignalKit.UNBOUNDED` for `maxBuses`, a non-table argument or a
call without the facade receiver raises at the caller. Returns nothing.

**The limits are shared by every consumer in the session**: every embedded
copy and every addon uses one set, and a newer revision inherits the values a
consumer set. A library should rely on the default; an addon that raises
`maxBuses` raises it for everybody.

`maxBuses` refuses `UNBOUNDED` because a bus, once created, is never freed: a
closed bus stays registered under its name so late publishers do not fail. The
1024 ceiling keeps that session-wide table bounded while leaving room for
sixteen times the default.

### `SignalKit:GetLimits()`

Returns a fresh table `{ maxBuses = n }`. It allocates one table per call, so
read it once rather than on a hot path.

### Limit options on shared objects

Every Kit follows one rule for limit options on an object several callers
reach by name (an addon's scope, a named bus): the first statement fixes the
value, a later call stating a different value raises at the caller and changes
nothing, and a later call stating the same value or none returns the existing
object. HookKit's and CommandKit's `ForAddon` and LocaleKit's `GetLocale` apply
it with the first call as the statement, defaults included.

SignalKit applies it to buses with one deliberate difference: a call that
states no limit (`Bus(name)`, or `ForAddon`, which takes no options) does not
fix the default. A shared bus is reached by subscribers from other addons,
which may load before the owner that declares its bounds, so only a call that
states a limit fixes it, whatever the load order.

### Lowering a limit

Lowering a limit never evicts: buses, topics and listeners already present stay,
and further additions are refused with `nil, "full"` until the count is below
the new bound. A per-bus limit is read on every declaration and subscription,
so it takes effect at once.

## Embedded copies and revision upgrades

Registry owns the stable `SignalKit` package table for `(signal, API 1)`. SignalKit instances use that shared table as their method prototype, so existing signal instances observe compatible package-method upgrades loaded into the same API generation.

`SignalKit.Connection` is also preserved as one shared method table across compatible package revisions, allowing existing connection handles to observe compatible connection-method upgrades.

Revision 2 changed the listener-array layout. Signals created by revision 1 carry
no tombstone counter, so every counter read treats a missing counter as zero;
live revision-1 signal instances therefore keep working unchanged after a
revision-2 copy upgrades the shared package table in place.

Revision 4 introduced private package state (`_state`, schema 1) holding the
named buses and the bus and scope method tables. Revisions 1 to 3 had none, so
an upgrade over them creates it; existing signals and connections are
untouched. A later revision inherits the state as it is: buses, topics and
their policies, scopes and subscriptions all survive, and existing buses and
scopes gain the newer methods because they resolve through the shared method
tables. Each delivery closure reads the isolation function from that state, so
a newer revision replaces it for subscriptions that already exist.

Revision 5 moved the state to schema 2, which adds the `SignalKit.UNBOUNDED`
sentinel and the package-wide limits (`maxBuses`). An upgrade over revision 4
creates both with the defaults and gives every existing bus the default
`maxTopics` and `maxListeners`, recorded as not yet stated, so the first
caller that states one still sets it. A later revision inherits the sentinel
identity, the limits a consumer set, and each bus's own limits.

Revision 6 moved the state to schema 3, which adds the logout watcher
(`logoutWatch`) and gives every bus two fields: who closes it at logout
(`_logoutCloser`, `false` for a bus `ForAddon` has not returned) and the case
(b) `OnShutdown` subscription. An upgrade over revision 5 adds both with
`false`, because revision 5 did not record which buses `ForAddon` returned:
such a bus is taken for the addon's at its next `ForAddon`. An upgrade over
revision 6 or later arranges the [logout close](#at-logout) of every open addon
bus it inherits while it loads, and keeps the subscriptions and the watcher
without subscribing again: the subscription calls the facade and the watcher
calls through `logoutWatch.close`, which the newer copy replaces. That
arrangement runs after the commit and under `pcall`, so a failure in another
Kit is reported and never fails the load.

As with every Registry-managed package, a revision is selected before package initialization completes. Package initialization is therefore written so that all fallible dependency validation occurs before registration and the post-registration commit path performs only local deterministic mutations.
