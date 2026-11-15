# CommKit

CommKit sends and receives addon messages of any length. It registers prefixes with the client, splits long messages into chunks and reassembles them on the other side, queues sends in three priorities that refuse rather than grow, and paces everything through one bandwidth budget shared with the whole session — including traffic other addons send, when HookKit is present. Two optional part files add more: `CommKit-SyncSet.lua`, named fields versioned by content hash that answer a request with only the fields that changed, and `CommKit-ChatThrottle.lua`, chat lines and Battle.net game data through the same budget.

```lua
local CommKit = MoltenCodes.Registry:Get("commKit", 1)
local CodecKit = MoltenCodes.Registry:Get("codecKit", 1)

local comm = CommKit:ForAddon("MyAddon") -- closed by CommKit:CloseAddonScopes("MyAddon")

-- Receiving: the callback only ever sees whole messages.
comm:Register("MyAddon", function(prefix, text, distribution, sender)
  local ok, message = CodecKit:Decode(text, { channel = "addon" })
  if not ok or not MessageSchema:Check(message) then
    return -- received data is untrusted: drop anything malformed
  end
  handle(message, sender)
end)

-- Sending: any length; a bound that would be passed is a return value.
local ok, text = CodecKit:Encode({ kind = "hello", version = 3 }, { channel = "addon" })
local send, reason = comm:Send({
  prefix = "MyAddon",
  text = text,
  distribution = "RAID",
  priority = CommKit.Priority.BULK,
  onComplete = function(send, state, why)
    -- "sent", or "cancelled" / "failed" with a reason
  end,
})
if not send then
  print("not queued: " .. reason) -- "queueFull", "tooLarge", "forbiddenByte", ...
end
```

What each piece promises:

- **Whole messages only.** A message over 254 bytes travels as chunks with a stream id and an index; a callback runs once every chunk arrived, in any order after the first. The protocol is specified byte by byte in [`docs/API.md`](docs/API.md#wire-protocol).
- **Bounded against strangers.** Reassembly is bounded in streams (64), bytes per sender (16 KB), streams per sender (4) and time (30 s since the last chunk); a sender who leaves the group loses their streams. A hostile header is refused before anything is stored, and dropped streams are reported at most once per sender per minute. The sender keeps within the same bounds, so default peers never lose a message to them, and a message cancelled or failed mid-send is aborted so receivers drop it silently.
- **Queues that say no.** Sends are bounded at 256 messages and 64 KB, across every addon; a send that would pass a bound returns `nil, "queueFull"` instead of growing the queue.
- **Fair.** ALERT, NORMAL and BULK are served four, two and one chunks per turn, and destinations inside a priority take turns, so neither a busy priority nor a busy destination starves the rest.
- **One budget for the session.** A token bucket (800 bytes per second, burst 4000, 40 bytes per message) paces every scope, halves below 20 frames per second, drops to a tenth for five seconds after zoning, sets a throttled destination aside with backoff, and charges traffic other code sends when HookKit is loaded.
- **Idle means idle.** A message sent while nothing waits leaves inside `Send` as far as the budget pays, with its callbacks made by the driver's next run, after `Send` returned; the send driver's one job (a SchedulerKit job while SchedulerKit is loaded, a TimerKit timer otherwise) exists only while something is queued or callbacks wait. A one-chunk message without callbacks goes straight to the client, without a queue record, which keeps a short send near ChatThrottleLib's cost (see *Performance* in [`docs/API.md`](docs/API.md#performance)).
- **Delta sync** (SyncSet part). `scope:SyncSet(prefix, { fields, schema })` exchanges named fields versioned by a 32-bit FNV-1a hash; a request carries the hashes the requester holds and the answer only the fields that differ.
- **Chat and Battle.net** (ChatThrottle part). `scope:SendChat{ text, chatType, ... }` sends a chat line through the shared budget; SAY, YELL and CHANNEL, which need the caller's hardware event, leave inside the call or are refused with `"hardwareEvent"`, never queued. `scope:SendBattleNet{ prefix, text, gameAccountID }` and `scope:RegisterBattleNet(prefix, callback)` carry messages of any length over Battle.net game data.

Every bound is documented under *Limits* in the API: a scope's `maxRegistrations` and a SyncSet's `maxListeners` accept `CommKit.UNBOUNDED`, and the session-shared limits are raised through `SetLimits`.

### Moving from AceComm-3.0 and ChatThrottleLib

CommKit does both libraries' jobs: AceComm's splitting and reassembly, and ChatThrottleLib's pacing and priorities. Its wire format is its own, so peers still on AceComm cannot read it; keep the two on different prefixes during the move, or speak AceComm's format through CommKit with [BridgeKit](../bridgeKit/). [`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#acecomm-30) walks through a port.

| AceComm-3.0, ChatThrottleLib | CommKit |
|---|---|
| `self:RegisterComm(prefix, method)` | `comm:Register(prefix, callback)`: a connection, or `nil, reason`. |
| `self:UnregisterComm(prefix)` | `connection:Disconnect()` |
| `self:UnregisterAllComm()` | `comm:UnregisterAll()` |
| `self:SendCommMessage(prefix, text, distribution, target, priority, callbackFn, callbackArg)` | `comm:Send({ prefix = prefix, text = text, distribution = distribution, target = target, priority = CommKit.Priority.BULK, onProgress = ..., onComplete = ... })`. A send that does not fit is refused with `nil, reason` instead of queued without bound. |
| `callbackFn(callbackArg, sent, length, sendResult)` | `onProgress(handle, bytesSent, bytesTotal)` after every chunk, and `onComplete(handle, state, reason)` once. |
| `ChatThrottleLib:SendAddonMessage(priority, prefix, text, chatType, target)` | `comm:SendRaw({ prefix = prefix, parts = { text }, distribution = chatType, target = target, priority = ... })`, which sends the text as written through the same queue and budget. |
| `ChatThrottleLib:SendAddonMessageLogged(...)` | `comm:Send({ ..., constraints = { logged = true } })`; `SendRaw` has no logged form. |
| `ChatThrottleLib:SendChatMessage(priority, prefix, text, chatType, language, destination, queueName, callbackFn, callbackArg)` | ChatThrottle part: `comm:SendChat({ text = text, chatType = chatType, languageID = language, target = destination, priority = ..., onComplete = ... })`. SAY, YELL and CHANNEL leave inside the call or are refused with `"hardwareEvent"`; ChatThrottleLib queued them. |
| `ChatThrottleLib:BNSendGameData(priority, prefix, text, chatType, gameAccountID, queueName, callbackFn, callbackArg)` | ChatThrottle part: `comm:SendBattleNet({ prefix = prefix, text = text, gameAccountID = gameAccountID, priority = ... })`, framed and chunked, so a message of any length arrives whole at `comm:RegisterBattleNet(prefix, callback)`. |
| ChatThrottleLib's per-prefix `queueName` | One pipe per destination and channel, taking turns inside each priority. |

Received data is untrusted: decode it with CodecKit and validate it with SchemaKit before use. See [`docs/API.md`](docs/API.md) for the full contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the implementation.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\commKit\CommKit.lua
```

Minimum footprint: embed 6 files: `registry/Registry.lua`, `signalKit/SignalKit.lua`, `eventKit/EventKit.lua`, `poolKit/PoolKit.lua`, `timerKit/TimerKit.lua`, `commKit/CommKit.lua`.

Direct runtime dependencies: Registry API 2, SignalKit API 1, EventKit API 1,
TimerKit API 1 and PoolKit API 1. Every file above is required; omitting one
makes this package raise at load. SchedulerKit is optional from revision 11:
when an addon embeds it, the send driver runs inside its frame budget.

Parts, each after the core (`python3 -m tooling.package.embeds 'commKit/*'`
prints the lines):

| Part | File | Adds | Needs |
|---|---|---|---|
| SyncSet | `commKit\parts\CommKit-SyncSet.lua` | `scope:SyncSet` | CodecKit (load it before the part) |
| ChatThrottle | `commKit\parts\CommKit-ChatThrottle.lua` | `scope:SendChat`, `scope:SendBattleNet`, `scope:RegisterBattleNet` | nothing |

A part's member is still there without the part, and raises with the file to
embed; test `CommKit:HasPart("SyncSet")` when a feature is optional.

At logout an addon scope is closed by LifecycleKit when it is loaded, and by
CommKit's own `PLAYER_LOGOUT` watcher otherwise (see "At logout" in
[`docs/API.md`](docs/API.md#at-logout)); you never close it yourself.

Optional: SchedulerKit API 1 (the driver's frame budget), CodecKit API 1
(required by the SyncSet part), HookKit API 1 (measures traffic other code
sends) and SchemaKit API 1 (validates `SyncSet` fields).
CommKit looks each up with `Registry:Find` when it needs it, so they may load in
any order after their own dependencies. The client functions CommKit calls —
`C_ChatInfo.RegisterAddonMessagePrefix`, `SendAddonMessage`,
`SendAddonMessageLogged` and `IsAddonMessagePrefixRegistered` (with the legacy
globals as fallbacks), `GetFramerate`, `UnitInParty` and `UnitInRaid` — are read
with `rawget` when used.
