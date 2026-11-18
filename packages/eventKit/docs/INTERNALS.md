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
| `group` | The unit group, or `false` for a regular event. |

A combat-log route has `subEvent`, `listeners`, `tombstones` and `count` with the
same meanings. Both are delivered by one walk, `deliverListeners`.

## Listener storage

The rules are SignalKit's for a signal (its `docs/API.md`, "Mutation
semantics"): a dispatch walks `listeners` up to the length it read when it
started, so a connection made during it waits for the next event; a
disconnect marks the handle (slot 2 `false`), so the walk skips it at
once; a `Once` handle is disconnected before its callback runs.

`state.dispatchDepth` counts EventKit dispatches on the stack. It decides how a
disconnect (`dropListener`) changes the array:

| Depth | What a disconnect does to the array |
|---|---|
| `0` | Settles in place (`settleInPlace`): drops tombstones at the tail, then, once at least half of the entries are tombstones, shifts the live ones down and clears the rest. Allocates nothing. |
| above `0` | Leaves a tombstone; at the same threshold stores a compacted copy in `listeners`, leaving the walked array untouched. |

The depth is package-wide rather than per channel: a disconnect inside any
dispatch takes the copying path, which is always safe, and the counter already
existed for the deferred scope sweep. `fireChannel` raises it around the walk
and protects the walk with `pcall` only when it can raise (see *One-shot count
and the protected walk*), so the depth is restored on every such path.

`disconnectEventConnection` special-cases the churn pattern inline: with no
dispatch running, a handle that is the tail of an array without tombstones is
removed with one assignment, and a channel other connections still share only
has its count decremented.

## Connection handles

A handle is the listener's record in the array, so connecting allocates it and
nothing else. Its fields live in the table's array part (revision 21):

| Slot | Meaning |
|---|---|
| `[1]` | The listener; `nil` once disconnected. For the method form, a closure over the receiver and the method name that looks the method up per call. |
| `[2]` | `true` while it delivers, `false` after; never `nil`, which is how scope code tells a connection from a Coalesce or Derive handle. |
| `[3]` | Whether it disconnects before its first call. |
| `[4]` | Its fan-out, a channel or a combat-log route (a route carries `subEvent`); `nil` once disconnected. |
| `[5]`, `[6]`, `[7]` | Only on a scoped handle: the owning scope or `false`, the previous and the next member of the scope's intrusive list. |

Every handle carries `state.connectionMetatable`, which is also the receiver
test of `Disconnect` and `IsConnected`. `newConnection` uses two table
constructors, with four and seven values, because Lua 5.1 sizes a
constructor's array part by the values it lists: 56 + 4 × 16 = 128 bytes on a
64-bit build, and 56 + 7 × 16 = 176 bytes for a scoped handle, where the named
layout of revisions 17 to 20 filled a four- or eight-node hash part (224 and
384 bytes). A slot past the constructor's is never written, because assigning
even `nil` to a missing key inserts the key, which can grow the table.

Coalesce and Derive handles keep their scope links by name (`_scope`,
`_scopePrevious`, `_scopeNext`). `linkToScope`, `unlinkFromScope` and
`scopeOfMember` test slot 2 to pick the layout of each member and of its
neighbours. Neither metatable has `__newindex`, so the links are written with
plain indexing.

## One-shot count and the protected walk

`fireChannel` runs `deliverListeners` under `pcall` only while
`channel.onceCount` is above zero. `onceCount` is
created by the first `Once` on a channel, raised by every one-shot connect,
lowered by every one-shot disconnect (its own delivery included) and reset to
zero when the record is pooled. The other ways the walk could raise are a bug
or a raising isolation function, and neither `securecallfunction` nor `xpcall`
propagates a listener's error.

## The channel pool

When a channel's last connection goes, `releaseChannel` removes it from its map,
unregisters the event and hands the record to `poolChannel`, which keeps it in
`state.channelPool` when no dispatch is running, its array is empty and the pool holds fewer than 16 records. A pooled record has
`false` in `eventName`, `frame`, `channels` and `group`, so it keeps nothing
alive. `newChannel` takes the newest pooled record before building a new one.
The connect-and-disconnect of an event's only listener therefore reuses one
record and its array. A record reached by a dispatch in flight is left to the
collector, because that dispatch may still read it.

`releaseChannel` returns early for a record whose `eventName` is `false` or that
is no longer the one its map holds, so a bookkeeping slip that released a record
twice cannot unregister the event of whichever channel reuses it.

## Dispatch path

`OnEvent` → `state.dispatchRegular` (or `dispatchUnit`, filled by the Units
part) → `fireChannel` →
`deliverListeners` → `state.isolate(callback, eventName, ...)` per live listener.
The dispatcher and the isolation function are read through `state` so a newer
revision replaces them for Frames and channels that already exist. The path
reads EventKit's own tables with plain indexing, a VM instruction, instead of
`rawget`, a C call; receivers from outside are still tested with `type` and
`rawget` first.

The combat-log router (CombatLog part) is an ordinary connection on the
`COMBAT_LOG_EVENT_UNFILTERED` channel whose callback resolves
`state.dispatchCombatLog`, which reads the client once and walks the matching
route, then the wildcard route, with the core's `deliverListeners`.

## The parts and what the core keeps for them

The core keeps every piece of state a part fills, so a part loaded by any
addon, or a higher revision of it, finds and takes it over:

- unit groups (`unitGroups`), the Frame free list (`unitFrames`) and the
  creation count (`unitFrameCount`), bounded by `limits.maxUnitFrames`;
- the combat-log router (`combatLog`: `channel`, `inner`, `readEventInfo`,
  `routes`, `anyRoute`, `listenerCount`);
- the Coalesce and Derive metatables and method tables.

The core reaches a part only through entries the part fills:

| Entry | Filled by | Called when | Default while the part is absent |
|---|---|---|---|
| `state.dispatchUnit` | Units | a unit group's Frame receives an event | nothing (no group exists) |
| `state.dispatch.releaseUnitGroup` | Units | `releaseChannel` released a unit group's last channel | nothing |
| `state.dispatchCombatLog` | CombatLog | the router's connection receives the event | nothing (no router exists) |
| `state.dispatch.releaseRoute` | CombatLog | a route connection disconnects (after `dropListener`) | nothing |
| `state.composites.close` | Coalescing | the scope sweep reaches a handle | `closeCompositeEvents`: disconnect the handle's events and unlink it (for a part revision 1 loaded after this core) |
| `state.composites.onEvent`, `recompute`, `wake` | Coalescing | a handle's listener or timer fires | not set: no handle exists |

and `state.helpers`, overwritten by every core revision that loads: the
validators, `bindMethod`, the Frame boundary (`requireFrameMethod`,
`createEventFrame`), `newChannel`, `createRegularChannel`, `connectToChannel`,
`disconnectEventConnection`, `deliverListeners`, `fireChannel`,
`findCombatLogReader`, the scope links, `reportListenerError` and
`missingPartMessage`; `normalizeUnits` and `createUnitChannel` are the Units
part's, which the Coalescing part's `units` option calls (stubs raising the
missing-part message without it). The defaults and the members' stubs are
installed only while their part is absent, so a core that upgrades after a
part leaves it alone.

An upgrade from revision 22 that finds unit groups or a router installs, in a
block only that upgrade runs, the retirement of what an absent part cannot
serve: `state.dispatchUnit` and `state.dispatchCombatLog` become
`retireUnservedObjects`, and a `C_Timer.NewTimer(0, ...)` runs it on the next
frame. It checks `HasPart` at run time, so a part loaded right after the core
keeps everything. Retiring marks each connection disconnected and unlinks it,
unregisters the unit events, returns the Frames to the free list (a Units part
loaded later reuses them), disconnects the router's own connection and reports
once per part (`retiredReported`). A fresh load never instantiates any of it,
so its prototypes are freed with the main chunk.

## Coalescing handles and the part

`Coalesce` and `Derive` live in `src/parts/EventKit-Coalescing.lua`. The core
creates the shared metatables and method tables (`compositeMetatables`,
`compositePrototypes`) so a part another addon loads finds them. Since part
revision 2 the part owns `closeCompositeHandle`, published as
`state.composites.close`: it disconnects the handle's event connections,
unlinks it from its scope, closes a lane handle's SchedulerKit timing, cancels
a TimerKit timer and empties the collected set, and disconnects `OnChange`
listeners. `helpers.closeCompositeHandle` stays, delegating to
`state.composites.close`, for a part revision 1 that calls it.

A handle times itself one of two ways, told apart by `_timing`:

- **TimerKit** (every handle the part builds without a `lane`): a `Coalesce`
  handle has sixteen fields (`_kind`, `_closed`, `_byEvent`, `_connections`,
  the three scope links, `_callback`, `_interval`, `_maxKeys`, `_set`,
  `_spare`, `_keyCount`, `_timer`, `_delivered`, `_firing`), so its hash part
  is sixteen slots; `_refused` and the reused `_statsView` are written when
  first needed. A `Derive` handle has `_delay` (a number, or `false` when it
  was built without TimerKit and recomputes synchronously), `_timer` and
  `_lastCall`. Every timer lives in one TimerKit scope,
  `_state.compositeTimerScope`, created on the first arm (again if it was
  closed), and runs one shared callback that finds its handle through the
  timer's user data, checks that the handle still points at that timer, and
  calls `state.composites.wake`. Arming therefore allocates no closure, and a
  higher part revision serves timers armed before it loaded.
- **SchedulerKit** (`_timing` holds a SchedulerKit handle): a handle with a
  `lane`, timed by SchedulerKit's `Coalesce` in one shared SchedulerKit scope
  (`_state.coalesceSchedulerScope`). Every method forwards to `_timing`.

The per-event path (`onCompositeEvent`) records the key itself, inline. The
TimerKit lookup remembers the facade the first successful `Registry:Find`
returned and not a failure; the SchedulerKit lookup does the same, and
`HasPart("Coalescing")` and `HasPart("Lanes")` are asked on every lane call,
so parts loaded later are seen.

## Upgrades

Revision 23 upgrades in place from revision 22 only (the upgrade floor; no
revision was ever published). The bootstrap refuses a copy below it, refuses
state that is not schema 10, and adds `state.dispatch` to revision 22's state;
nothing else changes layout. Revision 22's unit groups and router are served
by the parts or retired (see *The parts and what the core keeps for them*).
Its addon scopes keep `_logoutRoute`; a `_logoutSubscription` field it left
is never read again.

Older layouts are documented in the changelog. What the floor removed: the
schema 1 to 9 migrations, the named connection layout of revisions 17 to 20
(`disconnectNamedHandle`, `isNamedConnectionHandle`), the signal fan-outs and
`_inner` handles of revisions before 17, the `_DispatchRegular` and
`_DispatchUnit` facade fields of revision 1, the logout routing of addon
scopes revisions before 11 created, and revision 21's SchedulerKit-timed
`Derive` handles and per-handle SchedulerKit scopes in the Coalescing part.

Scope `Reopen` hands a scope still waiting for the deferred sweep over to a
closed carrier scope that takes its place in `pendingScopes`, re-pointing each
member's scope link.

Older revisions raise the same `dispatchDepth` around their dispatches, so
revision 22's dispatch still on the stack below an upgrade keeps the newer
copy from editing arrays in place.
