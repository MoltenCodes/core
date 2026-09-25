# EventKit Internals

This document describes implementation invariants for maintainers. It is not an
additional public API; `docs/API.md` is the contract.

## Channels and routes

A channel is one event name's host registration and the connections behind it:

| Field | Meaning |
|---|---|
| `eventName` | The event; `false` while the record waits in the pool. |
| `frame` | The Frame holding the registration: the shared regular Frame or the unit group's. |
| `listeners` | Connection handles in connection order, tombstones included. |
| `tombstones` | Disconnected handles still in `listeners`. |
| `count` | Live connections sharing the registration, the combat-log router included. |
| `channels` | The map the channel is in: `state.regularChannels` or its group's `channels`. |
| `group` | The unit group, or `false` for a regular event (`nil` on a channel from before revision 17). |
| `signal` | Only on a channel from before revision 17 (see *Upgrades*). |

A combat-log route has `subEvent`, `listeners`, `tombstones` and `count` with the
same meanings. Both are delivered by one walk, `deliverListeners`.

## Listener storage

The rules are SignalKit's for a signal (its `docs/API.md`, "Mutation
semantics"): a dispatch walks `listeners` up to the length it read when it
started, so a connection made during it waits for the next event; a
disconnect marks the handle (`_connected = false`), so the walk skips it at
once; a `Once` handle is disconnected before its callback runs.

`state.dispatchDepth` counts EventKit dispatches on the stack. It decides how a
disconnect (`dropListener`) changes the array:

| Depth | What a disconnect does to the array |
|---|---|
| `0` | Settles in place (`settleInPlace`): drops tombstones at the tail, then, once at least half of the entries are tombstones, shifts the live ones down and clears the rest. Allocates nothing. |
| above `0` | Leaves a tombstone; at the same threshold stores a compacted copy in `listeners`, leaving the walked array untouched. |

The depth is package-wide rather than per channel: a disconnect inside any
dispatch takes the copying path, which is always safe, and the counter already
existed for the deferred scope sweep. `fireChannel` raises it around a
protected walk (`pcall`), so it is restored even if the walk raises; the walk
itself only raises on a bug or a host failure while a `Once` releases its
registration, because every listener call is isolated.

`disconnectEventConnection` special-cases the churn pattern inline: with no
dispatch running, a handle that is the tail of an array without tombstones is
removed with one assignment, and a channel other connections still share only
has its count decremented.

## Connection handles

A handle is the listener's record in the array, so connecting allocates it and
nothing else:

| Field | Meaning |
|---|---|
| `_connected` | `true` while it delivers; the receiver test is that this is a boolean. |
| `_channel` or `_route` | The fan-out it is on; the other field is absent. `nil` once disconnected. |
| `_callback` | The listener; `nil` once disconnected. |
| `_once` | Whether it disconnects before its first call. |
| `_scope`, `_scopePrevious`, `_scopeNext` | Only on a scoped handle: the intrusive scope list (see `docs/API.md`, "Owner scopes"). |
| `_inner` | Only on a handle from before revision 17 (see *Upgrades*). |

`newConnection` uses two table constructors, with and without the scope links,
because Lua 5.1 sizes a constructor's hash part by the fields it names: three
named fields and the fan-out field fill a four-slot hash part (224 bytes on a
64-bit build), six and the fan-out field an eight-slot one (384 bytes). A field
is only ever written when it exists, because assigning even `nil` to a missing
key inserts the key, which can grow a full table.

## The channel pool

When a channel's last connection goes, `releaseChannel` removes it from its map,
unregisters the event and hands the record to `poolChannel`, which keeps it in
`state.channelPool` when no dispatch is running, it carries no `signal`, its
array is empty and the pool holds fewer than 16 records. A pooled record has
`false` in `eventName`, `frame`, `channels` and `group`, so it keeps nothing
alive. `newChannel` takes the newest pooled record before building a new one.
The connect-and-disconnect of an event's only listener therefore reuses one
record and its array. A record reached by a dispatch in flight is left to the
collector, because that dispatch may still read it.

`releaseChannel` returns early for a record whose `eventName` is `false` or that
is no longer the one its map holds, so a bookkeeping slip that released a record
twice cannot unregister the event of whichever channel reuses it.

## Dispatch path

`OnEvent` → `state.dispatchRegular` (or `dispatchUnit`) → `fireChannel` →
`deliverListeners` → `state.isolate(callback, eventName, ...)` per live listener.
The dispatcher and the isolation function are read through `state` so a newer
revision replaces them for Frames and channels that already exist. The path
reads EventKit's own tables with plain indexing, a VM instruction, instead of
`rawget`, a C call; receivers from outside are still tested with `type` and
`rawget` first.

The combat-log router is an ordinary connection on the
`COMBAT_LOG_EVENT_UNFILTERED` channel whose callback reads the client once and
walks the matching route, then the wildcard route, with `deliverListeners`.

## Coalesce handles

A `Coalesce` handle is written with eight fields (`_kind`, `_closed`,
`_byEvent`, `_connections`, `_timing` and the three scope links), so its hash
part has eight slots. It carries neither `_schedulerScope` nor `_signal`:
its SchedulerKit timing handle lives in one SchedulerKit scope that every
`Coalesce` handle shares, kept in `_state.coalesceSchedulerScope` and created
on first use (again if something closed it), and a `Coalesce` handle never has
an `OnChange` signal. `closeCompositeHandle` reads both fields as `false` when
absent, writes them only when present (writing even `nil` to a missing key
could grow the full hash part), and closes a `Coalesce` handle's timing handle
directly with `Close`, which also cancels its timer. Sharing the scope saves a
SchedulerKit scope per handle and the TimerKit scope SchedulerKit creates for a
scope's first timer; the handle's own `Close` is what releases its timing, so
nothing needed that scope to be the handle's own. A `Derive` handle keeps its
own SchedulerKit scope.

`findSchedulerKit` remembers the facade the first successful lookup returned
(Registry hands every compatible revision the same facade table) and does not
remember a failure, so a SchedulerKit loaded after a refused call is found.
The per-event path (`onCompositeEvent`) records the key itself instead of
calling a helper, and `readEventList` drops duplicate names by scanning the
names kept so far, which the 32-event bound keeps short, instead of building a
second lookup table.

## Upgrades

Revision 18 changes no state schema. `_state.coalesceSchedulerScope` is
created on first use, and a `Coalesce` handle an older revision built keeps its
own SchedulerKit scope in `_schedulerScope`, which `closeCompositeHandle` still
closes (closing the scope closes the timing handle in it).

Revision 17 moved `_state` to schema 9 (the `listeners` arrays, `tombstones`
counts and `channelPool`). Revisions before it fanned every channel and route
out through a SignalKit signal, with a wrapper closure per connection that
isolated the callback, and gave each handle its signal connection in `_inner`.

A copy loading over them gives every channel and route an empty `listeners`
array and keeps the `signal`. `deliverListeners` fires that signal before
walking `listeners`: the connections on it were all made before the upgrade,
so connection order holds. A handle with `_inner` is released by
`disconnectLegacyConnection`, the older revisions' path (`inner:Disconnect()`
and the release of its channel or route). An older `Once` wrapper calls the
older copy's own release function; it touches only fields both layouts share
(`count`, `eventName`, `channels`, `frame`, `group`). A router attached by an
older copy holds a SignalKit connection in `combatLog.inner`; detaching tests
whether `inner` is an EventKit handle on the channel and otherwise disconnects
it and releases its share of the channel. A channel with a `signal` is never
pooled.

Older revisions raise the same `dispatchDepth` around their dispatches, so an
older copy's dispatch still on the stack below an upgrade keeps the newer copy
from editing arrays in place, and a legacy walk never runs over `listeners`.
