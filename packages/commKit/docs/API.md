# CommKit API

CommKit API generation **1** sends and receives addon messages of any length: prefix registration, a chunk protocol with bounded reassembly, three priority queues that refuse rather than grow, a bandwidth budget shared with everything else in the session, and a `SyncSet` of named fields versioned by content hash.

Implementation revision: **1**. Wire protocol: control bytes `0x01`–`0x04`, specified in [Wire protocol](#wire-protocol).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
EventKit.lua
LifecycleKit.lua
TimerKit.lua
SchedulerKit.lua
PoolKit.lua
CommKit.lua
```

CommKit depends on Registry API 2, SignalKit API 1, EventKit API 1, LifecycleKit API 1, SchedulerKit API 1 and PoolKit API 1. TimerKit API 1 is not a direct dependency: SchedulerKit requires it, so it is always loaded, and CommKit finds it through `Registry:Find` for its two timers. Portable WoW code resolves the package through Registry:

```lua
local CommKit = MoltenCodes.Registry:Get("commKit", 1)
```

Loading CommKit without one of its dependencies raises at load time with the missing package named: `MoltenCodes CommKit requires SignalKit API 1 to be loaded first`, and so on for EventKit, LifecycleKit, SchedulerKit and PoolKit; without Registry, `MoltenCodes CommKit requires Registry API 2 to be loaded first`; without `GetTimePreciseSec`, which SchedulerKit also requires, `MoltenCodes CommKit requires GetTimePreciseSec`.

### Optional facilities

| Facility | Used by | Without it |
|---|---|---|
| CodecKit API 1 | `SyncSet` frames and content hashes | `scope:SyncSet` raises at the caller: `CommKit.Scope:SyncSet requires CodecKit API 1, which is not loaded`. Sending and receiving strings is unaffected. |
| HookKit API 1 | measuring traffic other code sends | Outside traffic is not charged to the budget. |
| SchemaKit API 1 | `SyncSet` `options.schema` | A `schema` option raises at the caller. |
| `GetFramerate` | the low-frame-rate mode | The mode never engages. |
| `UnitInParty`, `UnitInRaid` | evicting the streams of a sender who left the group | No eviction; streams still expire. |
| `securecallfunction` | isolating callbacks | Callbacks run under `pcall`; an error is still reported. |
| `issecretvalue` | refusing secret arguments and dropping secret payloads | Nothing is treated as secret. |
| `geterrorhandler` | reporting callback errors and dropped streams | Reports are printed. |

CodecKit, HookKit and SchemaKit are found with `Registry:Find` when they are used, so they may load in any order. Host functions are read with `rawget` on the global table when they are used.

### The client API CommKit calls

| Call | When | Fallback |
|---|---|---|
| `C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)` | before registering a prefix | the legacy global of the same name; without either, the prefix is registered |
| `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` | first `Register` of a prefix in the session | the legacy global; without either, nothing is registered (outside a client) |
| `C_ChatInfo.SendAddonMessage(prefix, text, distribution, target)` | every chunk | the legacy global `SendAddonMessage` |
| `C_ChatInfo.SendAddonMessageLogged(prefix, text, distribution, target)` | every chunk of a `constraints.logged` send | the legacy global; without either, `Send` refuses with `"unavailable"` |
| `Enum.SendAddonMessageResult`, `Enum.RegisterAddonMessagePrefixResult` | reading results | the 12.x values: `Success` 0, `AddonMessageThrottle` 3, `ChannelThrottle` 8; `Success` 0, `DuplicatePrefix` 1, `InvalidPrefix` 2, `MaxPrefixes` 3 |

Events, through a Kit-owned EventKit scope: `CHAT_MSG_ADDON` and `CHAT_MSG_ADDON_LOGGED` (payload `prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID`; CommKit reads the first four) and `GROUP_ROSTER_UPDATE`, connected only while at least one registration exists; `PLAYER_ENTERING_WORLD`, connected when the first scope is created.

## Public surface

### Package facade

| Member | Returns | Purpose |
|---|---|---|
| `CreateScope()` | scope | A manually owned scope. |
| `ForAddon(addonName)` | scope | The addon's canonical scope, closed when its LifecycleKit instance shuts down. |
| `CloseAddonScopes(addonName)` | boolean | Close that scope as shutdown does; `false` when there is none or it is closed. |
| `GetQueueDepth([priority])` | messages, bytes | Queued messages and text bytes in one priority, or in all. |
| `GetBudget()` | available, bytesPerSecond, capacity, mode | The shared bucket now. |
| `SetLimits(limits)` | nothing | Change any subset of the [limits](#limits). |
| `GetLimits()` | a fresh table | The limits. |
| `GetStatistics()` | a fresh table | The [counters](#statistics). |
| `Priority` | table | `ALERT`, `NORMAL`, `BULK`. |
| `MAX_MESSAGE_BYTES` | `255` | The client's limit on one addon message. |
| `MAX_REGISTRATIONS` | `32` | Registrations one scope holds at once. |
| `API`, `REVISION` | integers | API generation and implementation revision. |
| `Scope`, `Connection`, `SendHandle`, `SyncSet` | tables | The shared prototypes. |

### Scopes

| Method | Returns | Purpose |
|---|---|---|
| `Register(prefix, callback)` | connection, or `nil, reason` | Receive whole messages on `prefix`. |
| `Send(request)` | send handle, or `nil, reason` | Queue a message. |
| `SyncSet(prefix, options)` | SyncSet, or `nil, reason` | Named fields synchronised over `prefix`. |
| `UnregisterAll()` | integer | Close every SyncSet and disconnect every registration; the scope stays usable. |
| `CancelAll()` | integer | Cancel every pending send; the scope stays usable. |
| `Close()` | boolean | Cancel the sends (reason `"closed"`), close the SyncSets, disconnect the registrations. Terminal. |
| `IsClosed()` | boolean | |
| `GetAddonName()` | string or `nil` | The owning addon, `nil` for a manual scope. |
| `GetRegistrationCount()` | integer | Live registrations, SyncSet ones included. |
| `GetPendingCount()` | integer | Sends not yet terminal. |

A closed scope refuses `Register`, `Send` and `SyncSet` with `nil, "closed"`.

### Connections, send handles, SyncSets

| Object | Method | Returns |
|---|---|---|
| connection | `Disconnect()` | `true` once, then `false` |
| connection | `IsConnected()`, `GetPrefix()` | boolean, string |
| send handle | `Cancel()` | `true` when it cancelled a queued or partly sent message |
| send handle | `GetState()` | `"queued"`, `"sending"`, `"sent"`, `"cancelled"` or `"failed"` |
| send handle | `GetBytesSent()`, `GetBytesTotal()` | text bytes sent so far, text bytes in all |
| SyncSet | `Set(field, value)` | `true, changed` or `nil, reason` |
| SyncSet | `Get(field)`, `GetHash(field)` | this client's value and its hash |
| SyncSet | `GetRemote(sender, field)` | the value `sender` last delivered |
| SyncSet | `Request(target)` | send handle, or `nil, reason` |
| SyncSet | `OnChanged(callback)` | connection, or `nil, reason` |
| SyncSet | `Close()`, `IsClosed()` | boolean |

## Receiving

```lua
local scope = CommKit:ForAddon("MyAddon")
local connection, reason = scope:Register("MyAddon", function(prefix, text, distribution, sender)
    -- text is one whole message, never a part of one.
end)
```

- `prefix` is 1 to 16 bytes. The first registration of a prefix in the session asks the client to register it; `DuplicatePrefix` counts as registered, and a prefix the client already reports as registered is not registered again.
- A refused registration returns `nil` and the client's reason: the key of `Enum.RegisterAddonMessagePrefixResult` with its first letter lowered (`"invalidPrefix"`, `"maxPrefixes"`), `"refused"` for a legacy `false`, `"unknownResult"` for a value the enum does not name. `nil, "full"` means the scope holds 32 registrations; `nil, "closed"` that it is closed.
- The callback receives `prefix, text, distribution, sender`, where `distribution` is the channel the client reported (`"PARTY"`, `"RAID"`, `"GUILD"`, `"WHISPER"`, ...). Messages on the logged channel arrive through `CHAT_MSG_ADDON_LOGGED` and are delivered the same way.
- Every registration of a prefix receives every message on it, in registration order. A callback runs through `securecallfunction` where the client has it, otherwise under `pcall`; an error is reported through the host error handler and the next callback still runs.
- The client echoes a group message to its sender, so a message this client sent to `PARTY` arrives here too, with `sender` set to the player. Filter on `sender` if that matters.
- A message is delivered only when every chunk arrived. See [Reassembly](#reassembly).

## Sending

```lua
local ok, encoded = CodecKit:Encode(payload, { channel = "addon" })
local handle, reason = scope:Send({
    prefix = "MyAddon",
    text = encoded, -- any string without NUL, CR, LF or |
    distribution = "RAID",
    priority = CommKit.Priority.BULK,
    onProgress = function(handle, bytesSent, bytesTotal) end,
    onComplete = function(handle, state, reason) end,
})
```

| Field | Required | Meaning |
|---|---|---|
| `prefix` | yes | 1 to 16 bytes. Sending does not require a registration. |
| `text` | yes | The message, any length up to the queue's byte limit. |
| `distribution` | yes | `PARTY`, `RAID`, `INSTANCE_CHAT`, `GUILD`, `OFFICER`, `WHISPER`, `CHANNEL`, `YELL` or `SAY`. |
| `target` | for `WHISPER` and `CHANNEL` | A non-empty player name for `WHISPER`; a channel name or number for `CHANNEL`. Ignored for the others. |
| `priority` | no | `CommKit.Priority.ALERT`, `NORMAL` (default) or `BULK`. |
| `constraints` | no | `{ logged = boolean, battleNet = boolean }`; see below. |
| `onProgress` | no | Called after every chunk that left, with the text bytes sent so far. |
| `onComplete` | no | Called once with the terminal state and a reason. |

An unknown field, a wrong type, a secret value or an unknown priority raises at the caller. Everything that depends on the state of the queue or on the value of `text` is a return value instead:

| Refusal | When |
|---|---|
| `"closed"` | The scope is closed. |
| `"badDistribution"` | `distribution` is not one of the nine, or `WHISPER`/`CHANNEL` has no usable `target`. |
| `"forbiddenByte"` | `text` contains NUL (`0x00`), line feed (`0x0A`), carriage return (`0x0D`) or `\|` (`0x7C`). |
| `"tooLarge"` | `text` is longer than `maxQueuedBytes`, or needs more than 16383 chunks. It could never be queued. |
| `"queueFull"` | Queueing it would pass `maxQueuedMessages` or `maxQueuedBytes`. It may fit later. |
| `"unavailable"` | The client lacks the send function the constraints select. |

A refusal allocates nothing and queues nothing. **Escaping is the caller's job**: CommKit refuses a forbidden byte rather than transform the text, so a receiver gets exactly the string the sender passed. `CodecKit:EncodeForAddon` (or `Encode` with `channel = "addon"`) produces text that is never refused.

### Constraints: the payload chooses the channel

`constraints.logged = true` sends every chunk with `SendAddonMessageLogged`, the channel the client logs so players can report what it carried; use it for payloads that contain text a player wrote. Logged and ordinary messages to the same destination travel in separate [pipes](#queues-and-priorities). `constraints.battleNet = true` permits Battle.net transport; revision 1 has none and never selects it, so the flag changes nothing yet (see [Deviations](#deviations-from-the-planned-contract)).

### Send states

```text
queued ──→ sending ──→ sent
   │          │
   └──────────┴──→ cancelled | failed
```

`sending` means at least one chunk of a multi-chunk message left. `onComplete(handle, state, reason)` is called exactly once:

| State | Reason |
|---|---|
| `"sent"` | `nil` |
| `"cancelled"` | `"cancelled"` (`handle:Cancel()`, `scope:CancelAll()`), `"closed"` (`scope:Close()`), `"shutdown"` (the addon's shutdown or `CloseAddonScopes`) |
| `"failed"` | the key of `Enum.SendAddonMessageResult` the client returned (`"NotInGroup"`, `"InvalidChatType"`, ...), `"result<n>"` for a value the enum does not name, `"GeneralError"` for a legacy `false`, `"error"` when the send function raised (the error is reported), `"unavailable"` when the send function disappeared |

Cancelling a message mid-send stops its remaining chunks; the receivers drop the incomplete stream when it expires. Callbacks run isolated, like receive callbacks, after CommKit's own state is settled, so a callback may send, cancel or close.

## Wire protocol

This is a wire format: every copy of every revision of API generation 1 writes and reads exactly this. Numbers are byte values in hexadecimal.

### Single chunk

A message of at most 254 bytes is one addon message:

| Byte | Content |
|---|---|
| 1 | `01` |
| 2 … | the message, 0 to 254 bytes |

`"hello"` is `01 68 65 6C 6C 6F`. The control byte is always present, so a message whose first byte happens to be a control byte needs no escape.

### Multi-chunk messages

A message of 255 bytes or more is split into `n = ceil(length / 251)` chunks, `2 ≤ n ≤ 16383`. Every chunk has a four-byte header:

| Byte | First chunk | Middle chunk | Last chunk |
|---|---|---|---|
| 1 | `02` | `03` | `04` |
| 2 | stream id | stream id | stream id |
| 3, 4 | `n`, the chunk count | `i`, the chunk's index | `i = n` |
| 5 … | message bytes 1–251 | bytes `251(i−1)+1` to `251i` | the rest, 1 to 251 bytes |

The first chunk is index 1; middle chunks carry 2 to `n − 1`. First and middle chunks carry exactly 251 bytes, so every chunk but the last is exactly 255 bytes long.

**Digits.** The stream id and the two-byte number are written as digits in base 128, each digit `d` as the byte `80 + d`: the stream id as one digit (0–127), a number `k` as `80 + floor(k / 128)` then `80 + k mod 128`. Every header byte after the control byte is therefore in `80`–`FF`: the addon channel carries it, and it is never a control byte.

**Stream ids** count up from 0 for every multi-chunk message a session sends, across all prefixes and destinations, and wrap after 127. Single chunks use none.

A 510-byte message on stream 5 is three chunks:

```text
02 85 80 83 <bytes 1..251>      first:  3 chunks
03 85 80 82 <bytes 252..502>    middle: index 2
04 85 80 83 <bytes 503..510>    last:   index 3, 8 bytes
```

A 130-chunk message writes its count as `81 82` (1 × 128 + 2).

### What a receiver accepts

A stream is keyed by prefix, distribution, sender and stream id. The receiver:

- delivers a single chunk at once;
- opens a stream with a first chunk whose count is 2 to 16383 and whose payload is 251 bytes, if the [bounds](#reassembly) allow it; a first chunk for a key that already has a stream drops the old one (`"restarted"`) and opens the new one;
- adds a middle chunk whose index is 2 to `n − 1` and whose payload is 251 bytes, and a last chunk whose index is `n`, in any order after the first;
- delivers the message when all `n` chunks arrived, as the concatenation of their payloads in index order.

It refuses, and counts in `chunksRefused`, a chunk shorter than five bytes with a multi-chunk control byte, a header byte below `80`, a first chunk outside the rules above, a middle or last chunk for a stream it does not hold, and any other control byte. A middle or last chunk that breaks the rules for a stream it holds — an index out of range, a middle chunk that is not full, a last chunk whose index is not `n`, an index received twice — is refused and **drops the stream**.

### Extension rules

Control bytes `05`–`7F` are reserved. A receiver of this generation refuses them, so a new control byte is only compatible with receivers that know it; a sender that needs older receivers must not use it. The header layout of `01`–`04` never changes within API generation 1.

## Reassembly

Everything a stranger can make CommKit hold is bounded in count, bytes and time:

| Limit | Default | Bounds |
|---|---|---|
| `maxReassemblyStreams` | 64 | Streams held at once, across every sender. |
| `maxInFlightPerSender` | 4 | Streams one sender may have open. |
| `maxReassemblyBytesPerSender` | 16384 | Bytes one sender's streams may hold, counted from the size each first chunk declares: `251 (n − 1) + 1`, the least a message of `n` chunks can be. |
| `reassemblyTimeout` | 30 s | Time since a stream's last chunk before it expires. |

A first chunk that would pass any of the first three is refused before anything is stored, so a sender announcing 9999 chunks costs one comparison. A message larger than the receiver's per-sender byte limit can never be received; senders should keep messages below 16 KB unless every receiver raised it.

A stream that is dropped after it opened — expired, malformed, restarted, or evicted because its sender left the group — is **reported once** through the host error handler, naming the prefix, distribution, sender, reason and how many chunks arrived:

```text
CommKit dropped an incomplete message on prefix MyAddon (PARTY) from Friend-Realm: expired, 2 of 3 chunks received
```

Refused chunks are counted, not reported, so a stranger cannot fill the error log.

**Expiry** runs on one TimerKit timer, armed for the earliest deadline and re-armed after each sweep; nothing polls while no stream is open.

**Peer departure.** On `GROUP_ROSTER_UPDATE`, every stream received on `PARTY`, `RAID` or `INSTANCE_CHAT` whose sender neither `UnitInParty` nor `UnitInRaid` places in the group — asked with the full `Name-Realm`, then with the name alone — is dropped as `"departed"`. A secret answer counts as a member. Streams on other distributions are left to expire.

**When the last registration of a prefix goes**, its streams are discarded without a report: nobody is listening.

## Queues and priorities

Every send joins a **pipe**: one per priority and destination, where the destination is the distribution, the target and whether the message is logged. A pipe is first in, first out.

- **Across priorities**, a persistent weighted rotation serves one chunk at a time: ALERT four times, NORMAL twice, BULK once in every seven, skipping a priority that has nothing ready. ALERT therefore gets most of a saturated channel, and BULK is slowed but never starved: a BULK chunk leaves within seven chunks of any saturating load.
- **Inside a priority**, the pipes form a ring and the ring advances after every chunk, so one busy destination cannot starve another: three whispers to three players go out `X Y Z X Y Z`, and the chunks of a long message interleave with short messages to other destinations.
- **Inside a pipe**, messages go out in order, each chunk by chunk.

Priority is service preference, not ordering: a message in one priority may arrive before an earlier one in another.

The queue is bounded across every scope by `maxQueuedMessages` (256) and `maxQueuedBytes` (65536 bytes of text), and a send that would pass either is refused. Lowering a bound drops nothing already queued; new sends are refused until the queue is below it. `GetQueueDepth(priority)` reports messages and text bytes.

**The driver** is one SchedulerKit job, and it exists only while something is queued. A run sends chunks until the bucket, the queue or a cap of 32 chunks runs out, then schedules its successor: after the time the bucket needs, after the earliest throttled pipe is reinstated, or on the next frame. When the queue empties, nothing is scheduled and no per-frame handler remains.

## Bandwidth

**The bandwidth is an account-wide resource shared by every addon in the session, and CommKit treats it that way.** There is one bucket for every scope and every embedded copy; the limits are shared like SchedulerKit's frame budget, and an addon that raises them raises them for everybody. Libraries should keep the defaults.

The bucket holds at most `burst` (4000) bytes and refills at `maxCps` (800) bytes per second. A message costs its prefix, its text including headers, and `messageOverhead` (40) bytes: a full 255-byte chunk on a six-byte prefix costs 301. It starts full. When a chunk costs more than the bucket can hold (a small `burst`, or the zoning capacity), a full bucket pays for it, so nothing waits forever.

| Mode | When | Refill | Capacity |
|---|---|---|---|
| `"normal"` | otherwise | `maxCps` | `burst` |
| `"lowFrameRate"` | the last sample was below 20 frames per second | half | `burst` |
| `"zoning"` | for 5 s after `PLAYER_ENTERING_WORLD` | a tenth | the smaller of `burst` and half a second of `maxCps` |

The frame rate is sampled from `GetFramerate` once when the driver wakes from idle and then once a second on a TimerKit ticker while anything is queued — never on the send path, and never while idle.

**Traffic CommKit did not send.** When HookKit is loaded, CommKit secure-hooks `C_ChatInfo.SendAddonMessage`, `SendAddonMessageLogged` and `SendChatMessage` (the legacy globals where `C_ChatInfo` lacks one) with `HookKit:CreateScope():SecureHook`, the first time the driver wakes after HookKit is found. Every message another addon sends through them is charged to the bucket — prefix, text and overhead, or the most one message can cost when an argument is secret — and may drive the bucket down to two seconds of debt (−1600 bytes by default), which is repaid before CommKit sends again. A flag set around CommKit's own calls keeps its chunks from being charged twice. Secure hooks cannot be removed; they stay installed for the session.

**Throttled sends.** When the client answers `AddonMessageThrottle` or `ChannelThrottle`, the chunk was not sent and is not charged; its pipe is set aside for 0.35 s, doubling on every consecutive throttle of that pipe up to 5.6 s, and reset by the next success. Other pipes keep going. When the pipe is reinstated, the same chunk is tried again.

`GetBudget()` returns the available bytes (negative while repaying debt), the current refill rate, the capacity and the mode.

## SyncSet

A SyncSet keeps this client's values for a fixed list of fields and a cache of the values peers delivered, and exchanges them over one prefix with three verbs. A request carries the hashes the requester holds; the answer carries only the fields whose hash differs, or an ack.

```lua
local sync = scope:SyncSet("MyAddonSync", {
    fields = { "name", "level", "talents" },
    schema = { level = SchemaKit:Seal(SchemaKit.number({ integer = true, min = 1, max = 80 })) },
})

sync:Set("level", 70)                      -- true, true (the hash changed)
sync:OnChanged(function(sender, field, value)
    -- value is nil when the peer cleared the field
end)
sync:Request("Friend-Realm")               -- ask for what differs
local level = sync:GetRemote("Friend-Realm", "level")
```

- `fields` names 1 to 32 distinct fields of 1 to 64 bytes. `Set`, `Get` and `GetHash` raise for an undeclared field.
- `schema`, optional, maps declared fields to sealed SchemaKit schemas. A received value that fails its schema is dropped and counted in `syncRejected`; a local `Set` that fails returns `nil, "schema"`.
- `Set(field, value)` returns `true, changed`, or `nil` and CodecKit's reason (`"cycle"`, `"unsupportedType"`, a limit) or `"tableKey"`. `nil` clears the field. The value is kept by reference: after changing a table, call `Set` again.
- `Request(target)` whispers the request; the SyncSet registers its prefix like `Register` does and counts toward the scope's 32 registrations. Replies are whispers too, at NORMAL priority, through the same queue and budget.
- A SyncSet answers one peer at most once a second; requests in between are dropped and counted.
- The peer cache holds 64 peers; the least recently seen is evicted.
- `OnChanged` accepts 16 listeners; they run isolated, like receive callbacks.

### Frames

Each SyncSet message is `CodecKit:Encode(message, { channel = "addon" })` sent through the wire protocol above:

| Verb | Message | Meaning |
|---|---|---|
| request | `{ 1, hashes }` | `hashes[field]` is the hash the requester holds for this client's field; absent when it holds none. |
| ack | `{ 2 }` | Every hash matched. |
| deliver | `{ 3, values, removed }` | `values[field]` for every field whose hash differs; `removed` lists fields the requester holds and this client cleared. |

### Content hashes

A field's version is the 32-bit FNV-1a hash (offset basis 2166136261, prime 16777619) of a canonical encoding of its value:

- a string, number or boolean is CodecKit's serialisation of it (the writer is canonical for scalars);
- a table is `0C`, then each key and its value, keys sorted by type (booleans, then numbers, then strings) and then by value, strings byte by byte, each encoded the same way, then `0D`. A table used as a key is refused with `"tableKey"`.

Two equal tables hash equally whatever their insertion order. The hash is computed with arithmetic, since Lua 5.1 has no bit operations: the exclusive or touches only the low byte, and the product with 16777619 = 2^24 + 403 is split so every intermediate stays below 2^53. Test vectors:

| Value | Canonical bytes | Hash |
|---|---|---|
| `"a"` | `07 01 61` | 3539962124 |
| `1` | `04 01` | 2020387990 |
| `true` | `03` | 101473970 |
| `{ b = 2, a = 1 }` | `0C 07 01 61 04 01 07 01 62 04 02 0D` | 1171038798 |
| `{ [false] = true, [1] = "x", a = "y" }` | `0C 02 03 04 01 07 01 78 07 01 61 07 01 79 0D` | 1141967622 |

A 32-bit hash can collide; a collision makes a changed field look unchanged until it changes again.

## Limits

| Limit | Default | Accepted |
|---|---|---|
| `maxQueuedBytes` | 65536 | integer 1 – 1048576 |
| `maxQueuedMessages` | 256 | integer 1 – 4096 |
| `maxReassemblyStreams` | 64 | integer 1 – 1024 |
| `maxReassemblyBytesPerSender` | 16384 | integer 1 – 1048576 |
| `maxInFlightPerSender` | 4 | integer 1 – 64 |
| `reassemblyTimeout` | 30 | seconds, 1 – 600 |
| `maxCps` | 800 | integer 1 – 100000 |
| `burst` | 4000 | integer 255 – 1000000 |
| `messageOverhead` | 40 | integer 0 – 255 |

```lua
CommKit:SetLimits({ maxQueuedMessages = 128 })
local limits = CommKit:GetLimits() -- a fresh table
```

`SetLimits` raises at the caller on an unknown name or a value outside its range, before changing anything. **The limits are shared by every consumer in the session.**

## Statistics

`GetStatistics()` returns a fresh table of counters since load, plus three current totals:

| Counter | Counts |
|---|---|
| `messagesQueued`, `messagesSent`, `messagesCancelled`, `messagesFailed` | sends by outcome |
| `refusedQueueFull`, `refusedTooLarge`, `refusedClosed`, `refusedForbiddenByte`, `refusedBadDistribution`, `refusedUnavailable` | refused sends by reason |
| `chunksSent`, `bytesSent` | chunks that left, and their bytes on the wire |
| `throttled` | throttle results |
| `outsideMessages`, `outsideBytes` | traffic charged from the HookKit hooks |
| `messagesReceived`, `bytesReceived` | whole messages delivered and their bytes |
| `chunksReceived`, `chunksRefused` | addon messages on registered prefixes, and those refused |
| `streamsOpened`, `streamsCompleted`, `streamsExpired`, `streamsEvicted`, `streamsDropped` | reassembly streams |
| `secretsDropped` | received messages dropped because an argument was secret |
| `syncRequests`, `syncAcknowledgements`, `syncDeliveries`, `syncRejected` | SyncSet messages received, and those refused |
| `queuedMessages`, `queuedBytes`, `openStreams` | the current queue and reassembly totals |

## Scopes and shutdown

`ForAddon(addonName)` binds the scope to `LifecycleKit:ForAddon(addonName)`: when the addon shuts down, the scope closes, its pending sends complete as `"cancelled"` with the reason `"shutdown"`, its SyncSets close and its registrations disconnect. A scope requested after the addon shut down is returned closed. `CloseAddonScopes(addonName)` does the same on demand, so LifecycleKit can also call it in its shutdown sequence, as it does for HookKit and CommandKit.

## Secret values

Retail clients hand addon code **secret values** in restricted contexts; see [`EMBEDDING.md` → Secret values](../../../docs/EMBEDDING.md#secret-values-retail-12x). A secret prefix, text, distribution, target, priority, addon name, field or value passed to CommKit raises at the caller. A received message whose prefix, text, channel or sender is secret is dropped before any of them is used as a key, compared or measured, and counted in `secretsDropped`. Error messages never format a value CommKit did not create.

## Security: received data is untrusted

A received message is whatever the sender chose to send, and a sender may be hostile. CommKit bounds what a sender can make it hold and refuses malformed chunks, but it does not authenticate senders or check what a message says. **Decode received text with CodecKit, validate the result with SchemaKit, and treat a failure like any other malformed message**; see [`codecKit/docs/API.md`](../../codecKit/docs/API.md#security-decoded-data-is-untrusted). A SyncSet checks the shape of every frame and each field against its schema when one is given; give one. Never run received text as code or a macro, and never use it as a frame name, a global name or a format string. The `sender` string is filled in by the server, but the addon behind it can send anything.

## Cost

- **Receiving a single chunk allocates no table**: the payload is one `string.sub`, and the lookup, the counters and the dispatch allocate nothing. Specs guard this with `collectgarbage("count")`.
- A multi-chunk stream leases a stream record and a chunk list from PoolKit table pools and returns both when it completes or is dropped; the key is one string per chunk and the message one `table.concat`.
- A send allocates its handle and one string per chunk; the queue record is leased from a pool.
- An idle CommKit runs nothing: no job, no per-frame handler, no ticker. The expiry timer exists only while a stream is open.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`battleNet` is accepted and never selects Battle.net.** The plan lets the payload permit Battle.net transport; revision 1 has no Battle.net pipe (it needs a game-account target and a separate receive event), and a permission that is never used is still honoured. A later revision can add the transport without changing the contract.
- **Refusal reasons beyond the plan's three**: `"forbiddenByte"`, `"badDistribution"` and `"unavailable"` for `Send`; `"full"` and the client's reasons for `Register`. Each names a condition the caller can act on.
- **The scope bound counts registrations**, 32 per scope with SyncSet registrations included, rather than distinct prefixes; bounding registrations bounds prefixes too.
- **Priorities are weighted 4 : 2 : 1 per chunk**, where ChatThrottleLib split bandwidth equally between priorities with traffic; equal shares make ALERT no faster than BULK under load.
- **The reassembly timeout counts from a stream's last chunk**, not its first, so a long message on a degraded budget does not expire while it is still arriving.
- **Per-sender bytes are counted from the size a first chunk declares**, so a stream is refused before it holds anything.
- **`SetLimits` also accepts `maxCps`, `burst` and `messageOverhead`**, and `GetLimits` is added.
- **`SyncSet` additions**: `Get`, `GetHash`, `GetRemote`, `Close` and `IsClosed`; a reply interval of one second per peer; a peer cache of 64; `OnChanged` receives `nil` for a cleared field. `schema` maps each field to its own sealed schema, because a delivery carries only the fields that changed.
- **Scope additions**: `UnregisterAll`, `CancelAll`, `GetRegistrationCount`, `GetPendingCount`; **facade additions**: `CloseAddonScopes`, `MAX_MESSAGE_BYTES`, `MAX_REGISTRATIONS`.
- **Every message carries a control byte**, including single chunks, so no message is ever escaped and a receiver can tell CommKit traffic from anything else on the prefix.

## Upgrades

The package state (`_state`) holds the queues, the bucket, the limits, the statistics, the reassembly streams, the prefix signals, the Kit-owned scopes and the pools, and all of it is kept across an in-place upgrade: a newer compatible revision replaces the functions on the shared prototypes and in the dispatch table, and every callback CommKit handed to EventKit, TimerKit, SchedulerKit and HookKit calls through that table, so queued sends, open streams, registrations and SyncSets keep working under the new code. The wire protocol belongs to API generation 1, not to the revision.
