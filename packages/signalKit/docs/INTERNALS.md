# SignalKit Internals

This document describes implementation invariants for maintainers. It is not an
additional public API; `docs/API.md` is the contract.

## Listener storage

A signal keeps its connections in `_listeners`, an array in connection order,
and counts the disconnected entries still in it in `_tombstones`. `Fire` walks
the array up to the length it read when it started, so a connection made during
the walk waits for the next `Fire`, and it skips every entry whose connected
flag (see *Connection handles*) is not `true`, so a disconnect takes effect at
once.

`_firing` is the number of `Fire` calls walking the array. It decides how a
disconnect changes the array:

| `_firing` | What a disconnect does to the array |
|---|---|
| `0` | Settles in place (`settleInPlace`): drops disconnected entries at the tail, then, once at least half of the entries are disconnected, shifts the live ones down and clears the rest. Allocates nothing. |
| above `0` | Leaves the entry as a tombstone; at the same threshold `compact` builds a new array of the live entries and stores it, leaving the walked array untouched. |
| absent | As above `0`, for good (see *Upgrades* below). |

Either way disconnect is amortized `O(1)` and the array holds at most twice the
live connections. The churn case (a connection disconnected before anything
else happens) is special-cased in `disconnectConnection`: when the connection
is the tail and the only tombstone, settling is one removal.

`Fire` restores `_firing` to the value it read rather than decrementing it. An
error that escapes a nested `Fire` into a listener that catches it therefore
leaves the depth wrong only until the outer `Fire` returns. An error that
escapes the outermost `Fire` leaves it raised; that signal then compacts by
replacement for the rest of its life, which is the behaviour of every revision
before 9 and is always safe.

`DisconnectAll` releases every live connection, then empties the array in place
when `_firing` is `0` and replaces it with an empty one otherwise.
`bus:Unsubscribe` walks the array marking matches (`releaseConnection`) without
settling, because settling inside the walk would move entries underneath it,
and settles once afterwards.

## Connection handles

A handle is the only allocation of `Connect`, `Once` and a bus subscription.
Since revision 11 its fields live in the array part:

| Slot | Meaning |
|---|---|
| `[1]` | The listener; `nil` once disconnected, so the closure is released at once. |
| `[2]` | `true` while it delivers, `false` afterwards. |
| `[3]` | Whether it disconnects before its first call. |
| `[4]` | The signal it is on; `nil` once disconnected. |
| `[5]` | Only on a bus scope's subscription: the scope. |

`attach` uses two constructors, with and without the scope, so a handle is four
array slots (128 bytes on a 64-bit build) or five (144). The named fields of
revisions up to 10 (`_callback`, `_connected`, `_once`, `_signal`, `_busScope`)
filled a four-node hash part (224 bytes; 384 with `_busScope`, which doubled
it). `_busCallback` exists only on a bus subscription made before revision 9
(see *Upgrades*). A field is only ever written when it exists: assigning even
`nil` to a missing key inserts the key, which can grow a full table.

Every handle this revision creates carries `state.connectionMetatable`, whose
`__index` is the shared `Connection` prototype, so `Disconnect` and
`IsConnected` recognise a handle with one `getmetatable` comparison. A handle
an older revision created carries that revision's own metatable and is
recognised by its boolean `_connected` field instead.

### Two layouts, one per signal

A signal created by revision 11 or later carries `_layout = 2` and holds only
array-part handles. A signal an older revision created holds named-field
handles. The walks (`fire`, `fireIsolated`, `disconnectEveryListener`,
`settleInPlace`, `compact`, `Unsubscribe`) read the layout once and index with
the matching keys held in locals (`1, 2, 3` or `"_callback", "_connected",
"_once"`), which is the same `GETTABLE` instruction either way, so neither
layout pays per listener. Code that holds one handle tells the layout from the
handle: `connection[2]` is a boolean only in the array part, and reads `nil`
through the prototype otherwise.

`attach` converts an older signal (`convertToArrayLayout`) when it finds it with
`_firing == 0`: no `Fire` of any revision is walking it, because every revision
since 9 raises the depth for its walk. The handles are rewritten in place and
take the shared metatable, so tables held elsewhere stay valid. While a walk is
in progress, `attach` adds a named-field handle instead, keeping the array of
one layout. A signal without `_firing` (before revision 9) is never converted.
At load, an upgrade converts every idle bus topic signal it inherits.

## Method-name callbacks

`bindMethod` checks the receiver's method once and returns a closure over the
receiver and the name, which becomes the handle's listener. The closure reads
`receiver[methodName]` at every call (late binding), compares it with `nil`
(which never raises, even for a secret) and calls it with the receiver first.
Nothing else knows about the form: dispatch, isolation, `Once` and the scopes
see an ordinary function, and an older revision's code calls it like any
listener.

## Secret values

`issecretvalue` is read once when the file loads (`loadedIsSecretValue`). When
it was absent, `isSecret`, `subscribe` and `busPublish` read the global again on
each check, accepting only a function. `Publish` and `Subscribe` look the topic
up first and test its type only on a miss: a topic record exists only under a
validated non-empty string, and reading a table with a `nil` or NaN key does
not raise. The secret test still comes before the lookup, since indexing with a
secret key raises on the client.

## Bus isolation

A bus topic's signal carries `_isolated = true`. Its dispatch (`fireIsolated`)
reads `state.isolate` once per publish and calls it around each subscriber's
own callback: `securecallfunction` on a client that has it, otherwise the
`xpcall` trampoline with the payload staged in one reusable buffer. `Publish`
calls `fireIsolated` directly, since the bus has already validated what `Fire`
would check; `Fire` on an isolated signal delegates to it.

The hot paths read SignalKit's own tables with plain indexing, a VM
instruction, instead of `rawget`, a C call. A field an older revision's object
lacks falls through the metatable to the facade or the connection prototype,
which carry no underscore fields of a signal or a connection, and reads as
`nil`. A signal receiver from outside is still tested with `type` and `rawget`
first; buses, scopes and handles by their metatable, which `getmetatable`
answers without raising for any value.

## The Coalescing part

The core's only part of it is `installPartMethods` at commit: it creates
`_state.parts` when missing (revision 12; no schema change) and writes
`Coalesce` onto the bus and bus-scope prototypes, the recorded part's functions
or stubs that name the file to embed. The part writes them too when it loads,
so either load order ends with the part serving, and a part revision equal to
or older than the recorded one returns at once.

The part's record (`_state.parts.Coalescing`) keeps, across part revisions,
`handleMetatable` (handles are recognised by it; each revision refills its
`__index`), the SchedulerKit facade once found, and the one SchedulerKit scope
every handle's coalesce handle lives in. A handle is `{ _callback, _methodName,
_connections, _closed, _coalesce }`. It makes no bus-scope member of its own:
its subscriptions go through the bus or the scope, so the scope's sweep
disconnects them, and the delivery checks the first one; a disconnected one
releases the handle (`releaseIfAbandoned`) instead of delivering.

## Upgrades

Revision 9 (state schema 5) marks the topic signals it inherits `_isolated`.
Their subscriptions keep the delivery closure revisions 7 and 8 gave them, and
the subscriber's function in `_busCallback`; `Unsubscribe` compares
`_busCallback or _callback`. Such a subscription is isolated twice, which
reports an error once. Its `_callback` is not rewritten, because an older
copy's `Fire` may still be walking the signal on the stack below the upgrade and
would then call the bare callback without isolation.

A signal an older revision created has no `_firing`, and `Fire` does not add
one: an older copy's `Fire` without depth tracking may be walking it below the
upgrade, and in-place settling underneath that walk would skip or repeat
listeners. Such a signal keeps compacting by replacement, and keeps its
named-field handles.

Revision 11 (state schema 6) adds `connectionMetatable`; a state that already
carries one keeps it. It converts the idle bus topic signals it inherits and
leaves raw signals to their next idle connect (see *Two layouts, one per
signal*).

## Core and parts (revision 13)

The core keeps the listener storage, which the Bus and Journal parts call
through `_state.helpers` (refilled by every core revision and read by the
parts at call time, so a newer core serves a part loaded before it). The core
reaches a part only through its record in `_state.parts`: `Fire` hands a
signal flagged `_isolated` (only bus topic signals carry it) to
`parts.Bus.fireIsolated`; a bus scope's subscription reports its disconnect
to `parts.Bus.noteScopeDisconnect`; `CloseAddonBus` delegates to
`parts.Bus.closeAddonBus`. A part's methods are listed in its record by target
(`facadeMethods`, `busMethods`, `scopeMethods`, `journalMethods`) and the
core's commit reinstalls them over its stubs. Buses an older revision left
(`_state.inheritedBuses`) get stub methods and a terminal close in the core
until the Bus part loads and adopts them; in any other session that code is
freed after load. The named-field handle layout is still handled inline by
the hot functions, as in revision 12.
