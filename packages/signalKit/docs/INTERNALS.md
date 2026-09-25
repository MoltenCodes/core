# SignalKit Internals

This document describes implementation invariants for maintainers. It is not an
additional public API; `docs/API.md` is the contract.

## Listener storage

A signal keeps its connections in `_listeners`, an array in connection order,
and counts the disconnected entries still in it in `_tombstones`. `Fire` walks
the array up to the length it read when it started, so a connection made during
the walk waits for the next `Fire`, and it skips every entry whose
`_connected` is not `true`, so a disconnect takes effect at once.

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

A handle is the only allocation of `Connect`, `Once` and a bus subscription:

| Field | Meaning |
|---|---|
| `_connected` | `true` while it delivers; the receiver test for `Disconnect` and `IsConnected` is that this is a boolean. |
| `_signal` | The signal it is on; `nil` once disconnected. |
| `_callback` | The listener; `nil` once disconnected, so the closure is released at once. |
| `_once` | Whether it disconnects before its first call. |
| `_busScope` | Only on a bus scope's subscription. |
| `_busCallback` | Only on a bus subscription made before revision 9 (see *Upgrades*). |

`attach` uses two table constructors, with and without `_busScope`, because
Lua 5.1 sizes a constructor's hash part by the fields it names: four fields fill
a four-slot hash part (224 bytes on a 64-bit build), while naming a fifth field
as `nil` would double it. For the same reason a field is only ever written
when it exists: assigning even `nil` to a missing key inserts the key, which
can grow a full table.

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
`nil`. Receivers from outside are still tested with `type` and `rawget` first.

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
listeners. Such a signal keeps compacting by replacement.
