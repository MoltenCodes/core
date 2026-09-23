# CommKit

CommKit sends and receives addon messages of any length. It registers prefixes with the client, splits long messages into chunks and reassembles them on the other side, queues sends in three priorities that refuse rather than grow, and paces everything through one bandwidth budget shared with the whole session — including traffic other addons send, when HookKit is present. A `SyncSet` keeps named fields versioned by content hash and answers a request with only the fields that changed.

```lua
local CommKit = MoltenCodes.Registry:Get("commKit", 1)
local CodecKit = MoltenCodes.Registry:Get("codecKit", 1)

local comm = CommKit:ForAddon("MyAddon") -- closed at the addon's shutdown

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
- **Bounded against strangers.** Reassembly is bounded in streams (64), bytes per sender (16 KB), streams per sender (4) and time (30 s since the last chunk); a sender who leaves the group loses their streams. A hostile header is refused before anything is stored, and dropped streams are reported at most once per sender per minute. The sender keeps within the same bounds, so default peers never lose a message to them, and a cancelled message is aborted so receivers drop it silently.
- **Queues that say no.** Sends are bounded at 256 messages and 64 KB, across every addon; a send that would pass a bound returns `nil, "queueFull"` instead of growing the queue.
- **Fair.** ALERT, NORMAL and BULK are served four, two and one chunks per turn, and destinations inside a priority take turns, so neither a busy priority nor a busy destination starves the rest.
- **One budget for the session.** A token bucket (800 bytes per second, burst 4000, 40 bytes per message) paces every scope, halves below 20 frames per second, drops to a tenth for five seconds after zoning, sets a throttled destination aside with backoff, and charges traffic other code sends when HookKit is loaded.
- **Idle means idle.** The send driver is a SchedulerKit job that exists only while something is queued.
- **Delta sync.** `scope:SyncSet(prefix, { fields, schema })` exchanges named fields versioned by a 32-bit FNV-1a hash; a request carries the hashes the requester holds and the answer only the fields that differ.

Received data is untrusted: decode it with CodecKit and validate it with SchemaKit before use. See [`docs/API.md`](docs/API.md) for the full contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the implementation.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\schedulerKit\SchedulerKit.lua
Libs\MoltenCodes\poolKit\PoolKit.lua
Libs\MoltenCodes\commKit\CommKit.lua
```

Direct runtime dependencies: Registry API 2, SignalKit API 1, EventKit API 1,
LifecycleKit API 1, SchedulerKit API 1 and PoolKit API 1; TimerKit comes with
SchedulerKit. Every file above is required; omitting one makes this package
raise at load.

Optional: CodecKit API 1 (required by `SyncSet`), HookKit API 1 (measures
traffic other code sends) and SchemaKit API 1 (validates `SyncSet` fields).
CommKit looks each up with `Registry:Find` when it needs it, so they may load in
any order after their own dependencies. The client functions CommKit calls —
`C_ChatInfo.RegisterAddonMessagePrefix`, `SendAddonMessage`,
`SendAddonMessageLogged` and `IsAddonMessagePrefixRegistered` (with the legacy
globals as fallbacks), `GetFramerate`, `UnitInParty` and `UnitInRaid` — are read
with `rawget` when used.
