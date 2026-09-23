# Changelog

## 0.1.0 — 2026-09-23

- Added CommKit API generation 1, implementation revision 1.
- Added the wire protocol: a control byte on every message (`01` single, `02` first, `03` middle, `04` last), a stream id and a two-digit chunk number written as bytes `80`–`FF`, 251 payload bytes per chunk and up to 16383 chunks; control bytes `05`–`7F` reserved.
- Added scopes (`CreateScope`, `ForAddon` bound to LifecycleKit shutdown, `CloseAddonScopes`) with `Register`, `Send`, `SyncSet`, `UnregisterAll`, `CancelAll` and `Close`; prefixes are registered with the client on first use, 32 registrations per scope, and the client's refusals are surfaced by name.
- Added `Send` with ALERT, NORMAL and BULK priorities, per-destination pipes served round-robin, a weighted 4 : 2 : 1 rotation between priorities, `constraints.logged` for `SendAddonMessageLogged`, progress and completion callbacks, and send handles with `Cancel`, `GetState`, `GetBytesSent` and `GetBytesTotal`. A send that would pass `maxQueuedMessages` (256) or `maxQueuedBytes` (64 KB) is refused with a named reason, as are closed scopes, unknown distributions, forbidden bytes and oversized messages.
- Added the shared token bucket (800 bytes per second, burst 4000, 40 bytes per message) with a low-frame-rate mode sampled on a TimerKit ticker, a zoning mode after `PLAYER_ENTERING_WORLD`, throttle results setting a pipe aside with doubling backoff, and outside traffic charged through HookKit secure hooks when HookKit is present.
- The send driver is a SchedulerKit job that exists only while something is queued.
- Added bounded reassembly: streams keyed by prefix, distribution, sender and stream id, limited in count (64), per-sender bytes (16 KB), per-sender streams (4) and time (30 s since the last chunk, one TimerKit timer); hostile headers refused before storing anything; streams of senders who left the group evicted on `GROUP_ROSTER_UPDATE`; every dropped stream reported once. A single chunk is delivered without allocating a table.
- Added `SyncSet` with request, ack and deliver verbs as CodecKit frames, delta replies, fields versioned by a 32-bit FNV-1a hash of a canonical encoding computed in pure arithmetic, per-field SchemaKit validation, a one-second reply interval per peer, a 64-peer cache and `OnChanged`.
- Added `GetQueueDepth`, `GetBudget`, `SetLimits`, `GetLimits` and `GetStatistics`.
- Stream and queue records are leased from PoolKit table pools; PoolKit API 1 is a required dependency. CodecKit, HookKit and SchemaKit API 1 are optional dependencies found with `Registry:Find`.
- Secret values are refused at the caller, and received messages with a secret argument are dropped before use.
- 128 specs against a stubbed `C_ChatInfo` and the fixture clock, including every chunk boundary, reassembly in and out of order, expiry, hostile headers, every queue bound, priority fairness, throttling, outside traffic, cancellation mid-send, shutdown mid-send, SyncSet deltas with hash vectors, allocation guards, an in-place upgrade to revision 2 and pinned error levels.
