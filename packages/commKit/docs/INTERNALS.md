# CommKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API; the contract and the wire protocol are in [`API.md`](API.md).

## Package state

`CommKit._state` is shared by every embedded copy and kept across upgrades:

| Field | Meaning |
|---|---|
| `schema`, `runtimeRevision` | The state layout (1) and the revision that last committed its functions. |
| `dispatch` | Every function another Kit calls back into, by name. |
| `trampolines` | The closures handed to EventKit, TimerKit, SchedulerKit and HookKit, created once per session; each only looks its target up in `dispatch`. `logout` (revision 2) calls `dispatch.closeAddonScopesAtLogout`. |
| `metatables` | One metatable per object kind (`scope`, `connection`, `handle`, `syncSet`), whose `__index` is the shared prototype. |
| `addonScopes` | Addon name to canonical scope. Only `CloseAddonScopes` closes one, called by LifecycleKit, by CommKit's `OnShutdown` subscription or by its `PLAYER_LOGOUT` watcher ("At logout" in `API.md`); a closed scope stays in the map, so closing is terminal and the map grows only with `ForAddon` calls. Each scope carries `_logoutCloser` (`false` for a manual scope, else `"lifecycleKit"`, `"onShutdown"`, `"playerLogout"` or `"none"`) and `_shutdownSubscription` (the case (b) subscription or `false`, disconnected by `closeScope`); they are scope layout 2, and an upgrade over revision 1 adds them to every addon scope and arranges the open ones. |
| `limits`, `statistics` | The shared limits and counters. |
| `queues` | Per priority: `ring` (pipes in service order), `cursor` (the next pipe), `pipes` (key to pipe), `messages`, `bytes`. |
| `blockedPipes` | Pipes set aside after a throttle, waiting for `blockedUntil`. |
| `queuedMessages`, `queuedBytes`, `rotationCursor`, `nextStreamId`, `nextLoggedStreamId` | Queue totals (aborts included, at zero bytes), the priority rotation's position, the id after the last stream started in each digit scheme. |
| `inFlightStreams`, `inFlightBytes` | Streams receivers may hold from this client: multi-chunk messages whose first chunk left and last did not, and aborts not yet sent; and the bytes their first chunks declared. |
| `syncReplyBytes` | Text bytes of SyncSet replies in the queue. |
| `budget` | `tokens`, `lastRefill`, `zoningUntil`, `framesPerSecond` (the last sample, or `false`). |
| `driver` | `job` (the scheduled driver job or `false`), `delayed` (what it waits for: `false`, `"budget"`, `"blocked"`, `"frame"` or `"retry"`), `sampler` (the frame-rate ticker or `false`; started by `runDriver` when a run leaves something queued, from revision 5), `running` (a run is on the stack). |
| `sendingOwnTraffic`, `outsideHooks` | The re-entrancy flag and the HookKit scope holding the outside-traffic hooks. |
| `streams`, `streamList`, `senders` | Open streams by key and in opening order; per sender, `{ streams, bytes }`. |
| `expiry` | `timer` (the armed expiry timer or `false`), `due`, and `idleTimer` (revision 5): the one-shot TimerKit timer, created with `New` for the current `reassemblyTimeout`, that `armExpiry` restarts whenever it arms a full timeout; an earlier deadline gets a plain `After` timer. `false` until first needed, and replaced when the timeout changed or its scope was closed. |
| `dropReports` | `bySender` (sender to `{ reportedAt, pending, reasons }`), `count`, and the one flush timer and its due time. |
| `prefixSignals`, `prefixCounts`, `clientPrefixes`, `registrationTotal`, `chatConnections` | Per prefix, the SignalKit signal and the live registration count; prefixes registered with the client; the total; the EventKit connections for the chat and roster events. |
| `kitScopes` | CommKit's own EventKit, TimerKit and SchedulerKit scopes, the `PLAYER_ENTERING_WORLD` connection, and `logout`, the one `PLAYER_LOGOUT` `Once` connection of case (c), or `false` (revision 2; an upgrade over revision 1 adds it). |
| `pools` | PoolKit table pools: `records` (queued messages), `streams` (reassembly), and in a state inherited from revision 4 or earlier `parts` (the separate chunk lists those revisions leased; revision 5 only returns them and creates no such pool in a new state). |
| `spares` | Revision 5 free lists, each at most `POOL_RETAINED.spares` (16) long: `pipes` (emptied pipes, their FIFO kept) and `senders` (per-sender `{ streams, bytes }` records). An upgrade over revision 4 adds both empty. |

## Sending

A **record** (pooled) holds one queued message: its handle, scope, prefix, text, destination, priority, pipe, chunk count, next chunk index, bytes sent, stream id (`false` until its first chunk is built) and callbacks. The **handle** is a separate small table the caller keeps; it holds the state and the byte counts and points at the record until the message is terminal. `completeSend` is the only way out of the queue for a message: it dequeues the record, settles the handle, removes it from the scope's `_pending`, releases the record, disarms the driver when that emptied the queue outside a run, and only then calls `onComplete`.

An **abort** is a record of kind `"abort"` with no handle, scope, text or callbacks: `completeSend` queues one at the head of the pipe when a message is cancelled or fails after its first chunk left, and `finishAbort` releases it once sent or refused. A started message holds an in-flight allowance (`inFlight`); `completeSend` releases it when the message is sent; on a cancellation or a failure the abort takes it over until `finishAbort`, because receivers hold the stream until the abort arrives. `headMayStart` keeps a multi-chunk head that has not started waiting while the allowance is spent. `SetLimits` fails a message that has not started and that declares more than a lowered `maxReassemblyBytesPerSender`, so no head waits forever.

**Stream ids.** `assignStreamId` gives a multi-chunk head its id each time its first chunk is built: the scheme's counter, skipped past any id an in-flight head (a started message or an abort, always the head of its pipe) holds. The counter moves past the id only when the first chunk is accepted. In-flight streams number at most `maxInFlightPerSender` (at most 64), below both radixes, so a free id always exists.

A **pipe** is `{ key, priority, fifo, blocked, blockedUntil, backoff }`. It lives in its queue's `ring` or, while blocked, in `blockedPipes`, and in `pipes` either way, so a send to a blocked destination joins the blocked pipe. An emptied pipe is forgotten at once: `removePipe` takes it out of every structure and puts the table on `spares.pipes`, and `obtainPipe` resets a spare to a new pipe's fields (its FIFO is already empty) before it builds one. Forgetting stays immediate, so a destination's throttle backoff is not remembered past its last message, as before revision 5.

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

`runDriver` sets `running` around a protected call of `driveChunks`, and afterwards starts the frame-rate ticker if the run left something queued (`wakeDriver` only samples once): a message the first run sends in full never builds a ticker, and a longer one gets it at most one frame later than the wake, which the ticker's one-second period does not notice; while it is set, `wakeDriver` schedules nothing, so a send from a progress or completion callback never schedules a second job: the run serves it or `finishRun` arranges the next run. `scheduleDriver` cancels any job it replaces. Otherwise `wakeDriver` schedules a run unless one is coming; a run waiting only for a blocked pipe is cancelled and replaced, because the new message may use another pipe. `stopDriver` cancels the job and the sampler; `finishRun` calls it when the queue is empty, `completeSend` when a cancellation empties it outside a run, and `runDriver` when a failed run left nothing queued (with something queued, it retries a second later). `peekNextPipe` finds the next pipe without moving a cursor; the cursors move only when a chunk is handed to the client, so a chunk the bucket cannot pay for is the one tried next. `secondsUntilAffordable` rounds a deficit under one byte to zero and caps the requirement at the capacity; both prevent a run from waiting forever or re-arming nanosecond timers.

## Receiving

`onAddonMessage` checks every argument's type and secrecy before using the prefix as a key, returns at once for a prefix nobody registered, and delivers a single chunk with one `string.sub`. Multi-chunk keys are `prefix \t distribution \t sender \t streamId`. The key's last part comes from `WIRE.plain.keySuffix` or `WIRE.logged.keySuffix`, built at load for every stream id, because a number in a concatenation is formatted with `sprintf` on every chunk; the keys are the ones every revision writes. A stream record (pooled) holds the key, the four identifying strings, `total`, `received`, the byte `reserved` against its sender and the `deadline`, and, from revision 5, the chunk payloads in its own array part by chunk number (a stream a revision 4 copy opened keeps them in a pooled `parts` list, which `continueStream` and `closeStream` still read and release). Per-sender records come from and return to `spares.senders`. `closeStream` is the only way out: it unlinks the stream from all three structures (the oldest stream, the usual case, without a search), releases what it leased, and cancels the expiry timer when no stream is left; `dropStream` adds the counter and, except for an abort, `noteDrop`. `noteDrop` reports a sender's first drop at once and accumulates the rest until `flushDropReports`, on one TimerKit timer, reports them a minute later; entries with nothing pending are forgotten after their minute. Keys include the channel (`\tlogged\t`), and headers are decoded with the digit scheme of the event that delivered them; the `CHAT_MSG_ADDON` trampoline passes on only the four arguments CommKit reads.

## Callbacks and upgrades

Registrations and `OnChanged` listeners are SignalKit connections whose listener closes over the consumer's callback and calls `dispatch.isolatedCall`, so errors are isolated per listener while SignalKit keeps ordering and mutation-during-dispatch semantics. The SyncSet's own registration closes over the SyncSet and calls `dispatch.receiveSync`. Because every closure CommKit hands out resolves its behaviour through `dispatch`, a newer revision needs only to rewrite `dispatch` and the prototypes; objects and queued work carry over untouched.

## Hot paths

The send path, the driver and the receive path index CommKit's own tables (the state and its sub-tables, queue records, pipes, stream records, the limits and the counters) with plain field access. None of them has a metatable, so this reads and writes exactly what `rawget` and `rawset` would, without a C call each (about three times the cost in Lua 5.1). Scopes, handles, connections and SyncSets keep `rawget` and `rawset`: they have metatables whose `__index` is a prototype, and a missing field must not resolve to a method. The same paths read `issecretvalue` once per call and ask it about every value (`onAddonMessage`, `readSendRequest`, `classifySendResult`) instead of letting `isSecret` read it again for each; it is still read at call time, never cached across calls, because a client can gain it after CommKit loads. `driveChunks` ends a run on an empty queue before walking the priority rotation, and `peekNextPipe` skips a priority with nothing queued; `dequeueRecord` and `closeStream` take the head of their list without searching.

## The local-variable budget

Lua 5.1 allows 200 local variables in one function, and the file's main chunk is one function. Constants are therefore grouped into tables (`WIRE`, `REASON`, `POLICY`, `SYNC`, `FNV`, ...) and public methods are defined on method tables (`ScopeMethods`, ...) that `commitMethods` copies onto the prototypes. Helpers used by one function only live in `do` blocks with the function forward-declared (`assignStreamId`, `hashValue`, `noteDrop`, `receiveSync`, ...). The main chunk is at the limit: at its peak 200 locals are live (the most whose ranges overlap in `luac -l -l`, `LOGOUT` and `LogoutClose` included; revision 5 measured this after one more file-scope local failed to load). Revision 5 adds no local: its new state is reached through `state` (`state.spares`) and its new constants live in the existing `WIRE` and `POOL_RETAINED` tables. A change that needs a file-scope local must first fold existing ones into a table.
