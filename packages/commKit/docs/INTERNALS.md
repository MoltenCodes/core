# CommKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API; the contract and the wire protocol are in [`API.md`](API.md).

## Package state

`CommKit._state` is shared by every embedded copy and kept across upgrades:

| Field | Meaning |
|---|---|
| `schema`, `runtimeRevision` | The state layout (1) and the revision that last committed its functions. |
| `dispatch` | Every function another Kit calls back into, by name. |
| `trampolines` | The closures handed to EventKit, TimerKit, SchedulerKit and HookKit, created once per session; each only looks its target up in `dispatch`. |
| `metatables` | One metatable per object kind (`scope`, `connection`, `handle`, `syncSet`), whose `__index` is the shared prototype. |
| `addonScopes` | Addon name to canonical scope. |
| `limits`, `statistics` | The shared limits and counters. |
| `queues` | Per priority: `ring` (pipes in service order), `cursor` (the next pipe), `pipes` (key to pipe), `messages`, `bytes`. |
| `blockedPipes` | Pipes set aside after a throttle, waiting for `blockedUntil`. |
| `queuedMessages`, `queuedBytes`, `rotationCursor`, `nextStreamId`, `nextLoggedStreamId` | Queue totals, the priority rotation's position, the next stream id of each digit scheme. |
| `inFlightStreams`, `inFlightBytes` | Multi-chunk messages whose first chunk left and last did not, and the bytes their first chunks declared. |
| `syncReplyBytes` | Text bytes of SyncSet replies in the queue. |
| `budget` | `tokens`, `lastRefill`, `zoningUntil`, `framesPerSecond` (the last sample, or `false`). |
| `driver` | `job` (the scheduled driver job or `false`), `delayed` (`false`, `"budget"`, `"blocked"` or `"frame"`), `sampler` (the frame-rate ticker or `false`), `running` (a run is on the stack), `wakeRequested` (a send arrived during it). |
| `sendingOwnTraffic`, `outsideHooks` | The re-entrancy flag and the HookKit scope holding the outside-traffic hooks. |
| `streams`, `streamList`, `senders` | Open streams by key and in opening order; per sender, `{ streams, bytes }`. |
| `expiry` | The one expiry timer and its due time. |
| `dropReports` | `bySender` (sender to `{ reportedAt, pending, reasons }`), `count`, and the one flush timer and its due time. |
| `prefixSignals`, `prefixCounts`, `clientPrefixes`, `registrationTotal`, `chatConnections` | Per prefix, the SignalKit signal and the live registration count; prefixes registered with the client; the total; the EventKit connections for the chat and roster events. |
| `kitScopes` | CommKit's own EventKit, TimerKit and SchedulerKit scopes, and the `PLAYER_ENTERING_WORLD` connection. |
| `pools` | PoolKit table pools: `records` (queued messages), `streams` and `parts` (reassembly). |

## Sending

A **record** (pooled) holds one queued message: its handle, scope, prefix, text, destination, priority, pipe, chunk count, next chunk index, bytes sent, stream id and callbacks. The **handle** is a separate small table the caller keeps; it holds the state and the byte counts and points at the record until the message is terminal. `completeSend` is the only way out of the queue: it dequeues the record, settles the handle, removes it from the scope's `_pending`, releases the record, and only then calls `onComplete`.

An **abort** is a record of kind `"abort"` with no handle: `completeSend` queues one at the head of the pipe when a message is cancelled after its first chunk left, and `finishAbort` releases it once sent or refused. A started message holds an in-flight allowance (`inFlight`), released by `completeSend` whatever the outcome; `headMayStart` keeps a multi-chunk head that has not started waiting while the allowance is spent.

A **pipe** is `{ key, priority, fifo, blocked, blockedUntil, backoff }`. It lives in its queue's `ring` or, while blocked, in `blockedPipes`, and in `pipes` either way, so a send to a blocked destination joins the blocked pipe. An emptied pipe is forgotten at once.

### Driver

```text
idle ──Send──→ scheduled (Schedule) ──run──→ sends chunks
                     ↑                          │
                     └── After(wait) ←─ bucket short ("budget")
                     └── After(until) ←─ only blocked pipes left ("blocked")
                     └── NextFrame ←──── 32 chunks this run ("frame")
                                                │
                                   queue empty ─┴──→ idle (sampler stopped)
```

`runDriver` sets `running` around a protected call of `driveChunks`; while it is set, `wakeDriver` only sets `wakeRequested`, so a send from a progress or completion callback never schedules a second job, and `scheduleDriver` cancels any job it replaces. Otherwise `wakeDriver` schedules a run unless one is coming; a run waiting only for a blocked pipe is cancelled and replaced, because the new message may use another pipe. `peekNextPipe` finds the next pipe without moving a cursor; the cursors move only when a chunk is handed to the client, so a chunk the bucket cannot pay for is the one tried next. `secondsUntilAffordable` rounds a deficit under one byte to zero and caps the requirement at the capacity; both prevent a run from waiting forever or re-arming nanosecond timers.

## Receiving

`onAddonMessage` checks every argument's type and secrecy before using the prefix as a key, returns at once for a prefix nobody registered, and delivers a single chunk with one `string.sub`. Multi-chunk keys are `prefix \t distribution \t sender \t streamId`. A stream record (pooled) holds the key, the four identifying strings, `total`, `received`, the byte `reserved` against its sender, the pooled `parts` array and the `deadline`. `closeStream` is the only way out: it unlinks the stream from all three structures and releases both pooled tables; `dropStream` adds the counter and, except for an abort, `noteDrop`. `noteDrop` reports a sender's first drop at once and accumulates the rest until `flushDropReports`, on one TimerKit timer, reports them a minute later; entries with nothing pending are forgotten after their minute. Keys include the channel (`\tlogged\t`), and headers are decoded with the digit scheme of the event that delivered them.

## Callbacks and upgrades

Registrations and `OnChanged` listeners are SignalKit connections whose listener closes over the consumer's callback and calls `dispatch.isolatedCall`, so errors are isolated per listener while SignalKit keeps ordering and mutation-during-dispatch semantics. The SyncSet's own registration closes over the SyncSet and calls `dispatch.receiveSync`. Because every closure CommKit hands out resolves its behaviour through `dispatch`, a newer revision needs only to rewrite `dispatch` and the prototypes; objects and queued work carry over untouched.

## The local-variable budget

Lua 5.1 allows 200 local variables in one function, and the file's main chunk is one function. Constants are therefore grouped into tables (`WIRE`, `REASON`, `POLICY`, `SYNC`, `FNV`, ...) and public methods are defined on method tables (`ScopeMethods`, ...) that `commitMethods` copies onto the prototypes. Helpers used by one function only live in `do` blocks with the function forward-declared (`hashValue`, `noteDrop`, `receiveSync`, ...). The main chunk holds about 189 locals; a change that adds file-scope locals should group them the same way.
