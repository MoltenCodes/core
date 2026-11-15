# CommKit API

CommKit API generation **1** sends and receives addon messages of any length: prefix registration, a chunk protocol with bounded reassembly, three priority queues that refuse rather than grow, and a bandwidth budget shared with everything else in the session. Two optional [parts](#parts) add a `SyncSet` of named fields versioned by content hash, and chat lines and Battle.net game data through the same budget ([Chat and Battle.net](#chat-and-battlenet)).

Implementation revision: **11**. Parts: SyncSet revision 1, ChatThrottle revision 1. Wire protocol: control bytes `0x01`–`0x05`, specified in [Wire protocol](#wire-protocol).

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
EventKit.lua
TimerKit.lua
PoolKit.lua
CommKit.lua
parts/CommKit-SyncSet.lua        (optional; needs CodecKit)
parts/CommKit-ChatThrottle.lua   (optional)
```

CommKit depends on Registry API 2, SignalKit API 1, EventKit API 1, TimerKit API 1 (the expiry and drop-report timers, the frame-rate ticker, and the send driver when SchedulerKit is absent) and PoolKit API 1: six files with CommKit itself. SchedulerKit API 1 is optional from revision 11: when it is loaded, the send driver runs as its job, as it always did, and shares its frame budget; see [Queues and priorities](#queues-and-priorities). `python3 -m tooling.package.embeds commKit` prints the core's `embeds.xml`, and `commKit/SyncSet`, `commKit/ChatThrottle` or `'commKit/*'` add parts. It does not depend on LifecycleKit; see [Scopes and shutdown](#scopes-and-shutdown) and [At logout](#at-logout). Portable WoW code resolves the package through Registry:

```lua
local CommKit = MoltenCodes.Registry:Get("commKit", 1)
```

Loading CommKit without one of its dependencies raises at load time with the missing package named: `MoltenCodes CommKit requires SignalKit API 1 to be loaded first`, and so on for EventKit, TimerKit and PoolKit; without Registry, `MoltenCodes CommKit requires Registry API 2 to be loaded first`; without `GetTimePreciseSec`, which TimerKit also reads, `MoltenCodes CommKit requires GetTimePreciseSec`. Revision 10 and earlier also required SchedulerKit.

A part loaded before its core raises `MoltenCodes CommKit part SyncSet requires CommKit API 1 to be loaded first` (or `... part ChatThrottle ...`).

### Optional facilities

| Facility | Used by | Without it |
|---|---|---|
| SchedulerKit API 1 | running the send driver inside SchedulerKit's frame budget | The driver runs on a TimerKit timer; see [Queues and priorities](#queues-and-priorities). |
| CodecKit API 1 | `SyncSet` frames and content hashes (the SyncSet part) | `scope:SyncSet` raises at the caller: `CommKit.Scope:SyncSet requires CodecKit API 1, which is not loaded`. Sending and receiving strings is unaffected. |
| HookKit API 1 | measuring traffic other code sends | Outside traffic is not charged to the budget. |
| SchemaKit API 1 | `SyncSet` `options.schema` | A `schema` option raises at the caller. |
| LifecycleKit API 1 | closing an addon scope at logout after the addon's shutdown callbacks (see [At logout](#at-logout)) | CommKit's own `PLAYER_LOGOUT` watcher closes it instead. |
| `GetFramerate` | the low-frame-rate mode | The mode never engages. |
| `UnitInParty`, `UnitInRaid` | evicting the streams of a sender who left the group | No eviction; streams still expire. |
| `securecallfunction` | isolating callbacks | Callbacks run under `pcall`; an error is still reported. |
| `issecretvalue` | refusing secret arguments and dropping secret payloads | Nothing is treated as secret. |
| `geterrorhandler` | reporting callback errors and dropped streams | Reports are printed. |

CodecKit, HookKit, SchemaKit and LifecycleKit are found with `Registry:Find` when they are used, so they may load in any order. Host functions are read with `rawget` on the global table when they are used, with three exceptions the client defines before any addon loads, resolved once when CommKit loads: `issecretvalue`, `securecallfunction` and the `Success` entry of `Enum.SendAddonMessageResult`. A function absent then is looked up again on every call, so one installed later is still used. The driver reads `SendAddonMessage` and `SendAddonMessageLogged` once per run, so a function another addon replaces is used from the next run.

### The client API CommKit calls

| Call | When | Fallback |
|---|---|---|
| `C_ChatInfo.IsAddonMessagePrefixRegistered(prefix)` | before registering a prefix | the legacy global of the same name; without either, the prefix is registered |
| `C_ChatInfo.RegisterAddonMessagePrefix(prefix)` | first `Register` of a prefix in the session | the legacy global; without either, nothing is registered (outside a client) |
| `C_ChatInfo.SendAddonMessage(prefix, text, distribution, target)` | every chunk | the legacy global `SendAddonMessage` |
| `C_ChatInfo.SendAddonMessageLogged(prefix, text, distribution, target)` | every chunk of a `constraints.logged` send | the legacy global; without either, `Send` refuses with `"unavailable"` |
| `C_ChatInfo.SendChatMessage(text, chatType, languageID, target)` | every `scope:SendChat` line (ChatThrottle part) | the legacy global; without either, `SendChat` refuses with `"unavailable"` |
| `C_BattleNet.SendGameData(gameAccountID, prefix, data)` | every chunk of a `scope:SendBattleNet` message (ChatThrottle part) | without it, `SendBattleNet` refuses with `"unavailable"` |
| `Enum.SendAddonMessageResult`, `Enum.RegisterAddonMessagePrefixResult` | reading results | the 12.x values: `Success` 0, `AddonMessageThrottle` 3, `ChannelThrottle` 8; `Success` 0, `DuplicatePrefix` 1, `InvalidPrefix` 2, `MaxPrefixes` 3 |

Events, through a Kit-owned EventKit scope: `CHAT_MSG_ADDON` and `CHAT_MSG_ADDON_LOGGED` (payload `prefix, text, channel, sender, target, zoneChannelID, localID, name, instanceID`; CommKit reads the first four) and `GROUP_ROSTER_UPDATE`, connected only while at least one registration exists; `PLAYER_ENTERING_WORLD`, connected when the first scope is created; `BN_CHAT_MSG_ADDON` (payload `prefix, text, channel, senderID`), connected by the first `scope:RegisterBattleNet` and kept for the session.

## Parts

| File | Part | Adds | Needs |
|---|---|---|---|
| `parts/CommKit-SyncSet.lua` | `SyncSet` | `scope:SyncSet` and the SyncSet object ([SyncSet](#syncset)) | CodecKit API 1; SchemaKit API 1 for `schema` |
| `parts/CommKit-ChatThrottle.lua` | `ChatThrottle` | `scope:SendChat`, `scope:SendBattleNet`, `scope:RegisterBattleNet` ([Chat and Battle.net](#chat-and-battlenet)) | nothing; HookKit to charge others' Battle.net traffic |

A part loads after the core, in the same addon or another one. `CommKit:HasPart(name)` answers whether a part is installed; test that, not `type(scope.SyncSet) == "function"`, because a member whose part is not loaded is still a function: it raises at the caller's line with the file to embed,

```text
CommKit.Scope:SyncSet is in CommKit's SyncSet part, which is not loaded: add commKit\parts\CommKit-SyncSet.lua to embeds.xml after commKit\CommKit.lua
```

On a closed scope it returns `nil, "closed"` first, as the real member does. The members stay so every copy's public-surface check keeps accepting the facade. The SyncSet limits (`maxSyncPeers`, `maxSyncReplyBytes`) and every statistics counter belong to the core, so `SetLimits`, `GetLimits` and `GetStatistics` have one shape whatever is loaded. A part keeps its revision in `_state.parts`; the highest revision of a part in the session serves every addon, as for the core, and a newer core loaded after a part keeps the part's members.

## Public surface

### Package facade

| Member | Returns | Purpose |
|---|---|---|
| `CreateScope([options])` | scope | A manually owned scope; `options.maxRegistrations` (see [Limits](#limits)). |
| `ForAddon(addonName[, options])` | scope | The addon's canonical scope, closed by `CloseAddonScopes`; `options` apply when this call creates it. |
| `CloseAddonScopes(addonName)` | boolean | Close that scope at the addon's shutdown; `false` when there is none or it is closed. |
| `GetQueueDepth([priority])` | messages, bytes | Queued messages and text bytes in one priority, or in all. |
| `GetBudget()` | available, bytesPerSecond, capacity, mode | The shared bucket now. |
| `SetLimits(limits)` | nothing | Change any subset of the [limits](#limits). |
| `GetLimits()` | a fresh table | The limits. |
| `GetStatistics()` | a fresh table | The [counters](#statistics). |
| `HasPart(name)` | boolean | Whether the part `"SyncSet"` or `"ChatThrottle"` is installed ([Parts](#parts), revision 11). |
| `Priority` | table | `ALERT`, `NORMAL`, `BULK`. |
| `MAX_MESSAGE_BYTES` | `255` | The client's limit on one addon message. |
| `MAX_REGISTRATIONS` | `32` | The default `maxRegistrations` of a scope. |
| `UNBOUNDED` | table | Sentinel `maxRegistrations` and `maxListeners` accept to lift the bound (see [Limits](#limits)). |
| `API`, `REVISION` | integers | API generation and implementation revision. |
| `Scope`, `Connection`, `SendHandle`, `SyncSet` | tables | The shared prototypes. |

### Scopes

| Method | Returns | Purpose |
|---|---|---|
| `Register(prefix, callback)` | connection, or `nil, reason` | Receive whole messages on `prefix`. |
| `RegisterRaw(prefix, callback)` | connection, or `nil, reason` | Receive every addon message on `prefix` as it arrived, unparsed ([raw messages](#raw-messages), revision 8). |
| `Send(request)` | send handle, or `nil, reason` | Queue a message, and send it at once as far as the budget pays when the [driver](#queues-and-priorities) is idle. |
| `SendRaw(request)` | send handle, or `nil, reason` | Queue addon messages written by the caller as one message, without CommKit's framing ([raw messages](#raw-messages), revision 8). |
| `SyncSet(prefix, options)` | SyncSet, or `nil, reason` | Named fields synchronised over `prefix`. SyncSet part. |
| `SendChat(request)` | send handle, or `nil, reason` | A chat line through the shared budget ([Chat and Battle.net](#chat-and-battlenet)). ChatThrottle part. |
| `SendBattleNet(request)` | send handle, or `nil, reason` | A message to a Battle.net game account. ChatThrottle part. |
| `RegisterBattleNet(prefix, callback)` | connection, or `nil, reason` | Whole Battle.net messages on `prefix`. ChatThrottle part. |
| `UnregisterAll()` | integer | Close every SyncSet and disconnect every registration; the scope stays usable. |
| `CancelAll()` | integer | Cancel every pending send; the scope stays usable. |
| `Close()` | boolean | Cancel the sends (reason `"closed"`), close the SyncSets, disconnect the registrations. Terminal. |
| `IsClosed()` | boolean | |
| `GetAddonName()` | string or `nil` | The owning addon, `nil` for a manual scope. |
| `GetRegistrationCount()` | integer | Live registrations, SyncSet ones included. |
| `GetPendingCount()` | integer | Sends not yet terminal. |
| `GetMaxRegistrations()` | integer or `CommKit.UNBOUNDED` | The scope's `maxRegistrations`. |

A closed scope refuses `Register`, `RegisterRaw`, `Send`, `SendRaw` and `SyncSet` with `nil, "closed"`.

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
- A refused registration returns `nil` and the client's reason: the key of `Enum.RegisterAddonMessagePrefixResult` with its first letter lowered (`"invalidPrefix"`, `"maxPrefixes"`), `"refused"` for a legacy `false`, `"unknownResult"` for a value the enum does not name. `nil, "full"` means the scope holds its `maxRegistrations` (32 by default); `nil, "closed"` that it is closed; `nil, "framingConflict"` that the prefix holds [raw](#raw-messages) registrations.
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
| `target` | for `WHISPER` and `CHANNEL` | A non-empty player name for `WHISPER`; a channel number (a number or a string of digits) for `CHANNEL`. Ignored for the others. |
| `priority` | no | `CommKit.Priority.ALERT`, `NORMAL` (default) or `BULK`. |
| `constraints` | no | `{ logged = boolean, battleNet = boolean }`; see below. |
| `onProgress` | no | Called after every chunk that left, with the text bytes sent so far. |
| `onComplete` | no | Called once with the terminal state and a reason. |

An unknown field, a wrong type, a secret value or an unknown priority raises at the caller. Everything that depends on the state of the queue or on the value of `text` is a return value instead:

| Refusal | When |
|---|---|
| `"closed"` | The scope is closed. |
| `"badDistribution"` | `distribution` is not one of the nine, or `WHISPER`/`CHANNEL` has no usable `target` (a `CHANNEL` target that is not a channel number). |
| `"forbiddenByte"` | `text` contains NUL (`0x00`), line feed (`0x0A`), carriage return (`0x0D`) or `\|` (`0x7C`). |
| `"tooLarge"` | `text` is longer than `maxQueuedBytes`, or declares more bytes than one receiver accepts from one sender (`maxReassemblyBytesPerSender`). It could never be delivered. |
| `"queueFull"` | Queueing it would pass `maxQueuedMessages` or `maxQueuedBytes`. It may fit later. |
| `"unavailable"` | The client lacks the send function the constraints select. |

A refusal allocates nothing and queues nothing. **Escaping is the caller's job**: CommKit refuses a forbidden byte rather than transform the text, so a receiver gets exactly the string the sender passed. `CodecKit:EncodeForAddon` (or `Encode` with `channel = "addon"`) produces text that is never refused.

### Constraints: the payload chooses the channel

`constraints.logged = true` sends every chunk with `SendAddonMessageLogged`, the channel the client logs so players can report what it carried; use it for payloads that contain text a player wrote. Logged and ordinary messages to the same destination travel in separate [pipes](#queues-and-priorities). `constraints.battleNet = true` permits Battle.net transport; `Send` addresses a player by name and Battle.net needs a game account, so `Send` never selects it and the flag changes nothing. Battle.net game data has its own method, `scope:SendBattleNet` in the ChatThrottle part (see [Deviations](#deviations-from-the-planned-contract)).

### Send states

```text
queued ──→ sending ──→ sent
   │          │
   └──────────┴──→ cancelled | failed
```

`sending` means at least one chunk of a multi-chunk message left. **`Send` may return a handle already `sending` or `sent`**: when the driver is idle, `Send` runs it once before returning (see [the driver](#queues-and-priorities)), so a message the bucket pays for leaves inside the call, as ChatThrottleLib sends at once while bandwidth is left. A message the bucket cannot pay for, or one sent while the driver is busy, is returned `queued`. A throttle or a refusal answered inside the call returns it `queued` (set aside for its retry) or `failed`.

`onComplete(handle, state, reason)` is called exactly once:

| State | Reason |
|---|---|
| `"sent"` | `nil` |
| `"cancelled"` | `"cancelled"` (`handle:Cancel()`, `scope:CancelAll()`), `"closed"` (`scope:Close()`), `"shutdown"` (`CloseAddonScopes`, called at logout; see [At logout](#at-logout)) |
| `"failed"` | the key of `Enum.SendAddonMessageResult` the client returned (`"NotInGroup"`, `"InvalidChatType"`, ...), `"GeneralError"` for a legacy `false`, `"error"` when the send function raised (the error is reported), `"unavailable"` when the send function disappeared, `"tooLarge"` when `SetLimits` lowered `maxReassemblyBytesPerSender` below what the message, not yet started, declares |

A result the enum does not name — one a client newer than this file added — is treated like a throttle: the pipe is set aside and the chunk retried, rather than the message failed.

Cancelling a message mid-send stops its remaining chunks and queues an [abort](#abort) at the head of its pipe, so receivers drop the incomplete stream at once and silently. A message that fails mid-send, because the client refused a later chunk, queues the same abort. Until the abort leaves, it counts as a stream in flight, as the message did. The abort is sent once: a throttled one waits for its pipe, and one the client refuses is dropped, leaving receivers to expire the stream. Callbacks run isolated, like receive callbacks, after CommKit's own state is settled, so a callback may send, cancel or close.

**No callback runs before `Send` returns.** The `onProgress` and `onComplete` calls of chunks sent inside `Send` are held and made by the next driver run: with SchedulerKit loaded, a SchedulerKit job scheduled with `Schedule` (so it runs in SchedulerKit's next pass: on a later frame, or later in the current pass when `Send` was called from a SchedulerKit job); without it, a zero-delay TimerKit timer (a later frame; the "current pass" case needs a SchedulerKit job on the stack, so it cannot arise). That run makes them before it sends anything; a message a held callback sends is queued and leaves in that same run. Each handle's calls keep their order, progress in chunk order and completion last: a `Cancel`, `CancelAll`, `Close` or `CloseAddonScopes` that completes a message while calls are held makes the held calls first, inside that call, then its own. Held calls cost no table each: they wait in one array CommKit keeps, at most one progress call per chunk and one completion per message sent inside `Send` since the last driver run, and none remains once that run began.

## Raw messages

Revision 8 lets another protocol travel through CommKit's queue and budget:
bridgeKit's AceComm channel (`docs/BRIDGE_KIT_DESIGN.md`, section 8.3) is the
reason, and any addon that speaks a foreign wire format may use it. A raw
message is never framed, chunked or reassembled by CommKit: the caller writes
the addon messages and reads them back.

### Receiving: `scope:RegisterRaw(prefix, callback)`

`callback(prefix, text, distribution, sender)` is called for **every** addon
message on `prefix`, with `text` exactly as the client delivered it, whatever
its first byte. Everything else is as for `Register`: the prefix is
registered with the client on first use, callbacks run isolated in
registration order, a message with a secret argument is dropped and counted
in `secretsDropped`, and each message counts in `chunksReceived`,
`messagesReceived` and `bytesReceived`. The refusals are `Register`'s.

A prefix holds raw or framed registrations, never both, because the two
readings of a message's first byte contradict each other. While a prefix has
a registration of one kind, `Register` or `SyncSet` (framed) and
`RegisterRaw` (raw) of the other kind return `nil, "framingConflict"`, in any
scope. Once the prefix's last registration ends it may be registered either
way again.

Send raw messages only on a raw prefix. The client echoes a group message to
its sender, so a raw message sent to `PARTY`, `RAID` or `GUILD` on a prefix this
client has registered framed comes back through the framed parser: a part that
starts with `01` reaches the framed callbacks as a CommKit message.

### Sending: `scope:SendRaw(request)`

```lua
local handle, reason = scope:SendRaw({
  prefix = "MyAceAddon",
  parts = { "\001first 254 bytes...", "\003the rest" },
  distribution = "WHISPER",
  target = "Friend-Realm",
  priority = CommKit.Priority.NORMAL,
  onProgress = function(handle, bytesSent, bytesTotal) end,
  onComplete = function(handle, state, reason) end,
})
```

| Field | Required | Meaning |
|---|---|---|
| `prefix` | yes | 1 to 16 bytes. |
| `parts` | yes | An array of 1 to 4096 strings of 1 to 255 bytes: the addon messages, sent as written, in order. CommKit copies the array. |
| `distribution`, `target`, `priority`, `onProgress`, `onComplete` | as for `Send` | |

There is no `constraints` field: a raw message goes through
`SendAddonMessage`, on the ordinary channel.

The parts are queued **as one message** in one [pipe](#queues-and-priorities)
and leave part after part, through the same queue, bucket, throttle backoff,
send states, held callbacks and statistics as `Send`; nothing else queued to
the same destination and channel leaves between them. `onProgress` is called
after every part with the bytes sent so far; the handle's byte counts are the
parts' bytes. A raw message opens no stream, so it uses none of the in-flight
allowance (`maxInFlightPerSender`, `maxReassemblyBytesPerSender`) and never
waits for it. Cancelling one, or a part the client refuses, stops the parts
not yet sent; **nothing tells the receivers**, because CommKit does not know
the protocol: they must time the stream out themselves.

A wrong request raises at the caller as for `Send`, and so does a `parts` that
is not an array of 1 to 4096 strings of 1 to 255 bytes, or that holds a secret
part. The refusals are `Send`'s, with one difference: only NUL (`0x00`) is
refused, as `"nulByte"`, because the client cannot carry it; line breaks and
`|` are the caller's business. `"tooLarge"` means the parts' bytes exceed
`maxQueuedBytes`.

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

A message of 255 bytes or more is split into `n = ceil(length / 251)` chunks. The header can number up to 16383 chunks (5624 on the logged channel); the largest accepted [limits](#limits) keep a message at 4178. Every chunk has a four-byte header:

| Byte | First chunk | Middle chunk | Last chunk |
|---|---|---|---|
| 1 | `02` | `03` | `04` |
| 2 | stream id | stream id | stream id |
| 3, 4 | `n`, the chunk count | `i`, the chunk's index | `i = n` |
| 5 … | message bytes 1–251 | bytes `251(i−1)+1` to `251i` | the rest, 1 to 251 bytes |

The first chunk is index 1; middle chunks carry 2 to `n − 1`. First and middle chunks carry exactly 251 bytes, so every chunk but the last is exactly 255 bytes long.

**Digits.** The stream id and the two-byte number are written as digits, the stream id as one digit and a number `k` as `floor(k / radix)` then `k mod radix`. There are two schemes:

| Channel | Digit `d` is the byte | Radix | Stream ids | Most chunks |
|---|---|---|---|---|
| ordinary (`SendAddonMessage`, `CHAT_MSG_ADDON`) | `80 + d` | 128 | 0–127 | 16383 |
| logged (`SendAddonMessageLogged`, `CHAT_MSG_ADDON_LOGGED`) | `30 + d` | 75 | 0–74 | 5624 |

On the ordinary channel every header byte after the control byte is in `80`–`FF`: the channel carries it, and it is never a control byte. The logged channel may insist on valid UTF-8 text, which lone bytes above `7F` are not, so its digits are printable ASCII from `30` (`0`) to `7A` (`z`), below the pipe `7C`. A receiver decodes a header with the scheme of the event that delivered it. The payload itself is the caller's: logged payloads should be printable text, such as CodecKit's print channel.

**Stream ids** count up from 0, one counter per scheme across all prefixes and destinations, in the order the first chunks of multi-chunk messages leave, and wrap at the radix. An id that a stream of this client still in flight holds (a started message, or an abort not yet sent) is skipped, so a receiver never holds two streams of one sender under one id; at most `maxInFlightPerSender` (64 at most) streams are in flight, fewer than either radix. Single chunks use none.

A 510-byte message on stream 5 is three chunks:

```text
02 85 80 83 <bytes 1..251>      first:  3 chunks
03 85 80 82 <bytes 252..502>    middle: index 2
04 85 80 83 <bytes 503..510>    last:   index 3, 8 bytes
```

A 130-chunk message writes its count as `81 82` (1 × 128 + 2). On the logged channel the same 510-byte message on stream 0 starts `02 30 30 33`.

### Abort

A sender whose message is cancelled or fails after its first chunk left sends one four-byte chunk and nothing after it:

| Byte | Content |
|---|---|
| 1 | `05` |
| 2 | the stream id |
| 3, 4 | `n`, the chunk count the first chunk declared |

A 3-chunk message on stream 0 is aborted with `05 80 80 83`. A receiver holding that stream with that count drops it without a report (`streamsAborted`); any other abort is refused.

### What a receiver accepts

A stream is keyed by prefix, distribution, sender and stream id. The receiver:

- delivers a single chunk at once;
- opens a stream with a first chunk whose count is 2 to the scheme's most chunks (16383, or 5624 logged) and whose payload is 251 bytes, if the [bounds](#reassembly) allow it; a first chunk for a key that already has a stream drops the old one (`"restarted"`) and opens the new one;
- adds a middle chunk whose index is 2 to `n − 1` and whose payload is 251 bytes, and a last chunk whose index is `n`, in any order after the first;
- delivers the message when all `n` chunks arrived, as the concatenation of their payloads in index order;
- drops a stream on an abort naming its count.

A stream is keyed by the channel too, so logged and ordinary streams never mix. It refuses, and counts in `chunksRefused`, a multi-chunk chunk shorter than five bytes or an abort that is not exactly four, a header byte outside the scheme's digits, a first chunk outside the rules above, a middle, last or abort chunk for a stream it does not hold, and any other control byte. A middle or last chunk that breaks the rules for a stream it holds — an index out of range, a middle chunk that is not full, a last chunk whose index is not `n`, an index received twice — is refused and **drops the stream**.

### Extension rules

Control bytes `06`–`7F` are reserved. A receiver of this generation refuses them, so a new control byte is only compatible with receivers that know it; a sender that needs older receivers must not use it. The header layout of `01`–`05` never changes within API generation 1.

## Reassembly

Everything a stranger can make CommKit hold is bounded in count, bytes and time:

| Limit | Default | Bounds |
|---|---|---|
| `maxReassemblyStreams` | 64 | Streams held at once, across every sender. |
| `maxInFlightPerSender` | 4 | Streams one sender may have open. |
| `maxReassemblyBytesPerSender` | 16384 | Bytes one sender's streams may hold, counted from the size each first chunk declares: `251 (n − 1) + 1`, the least a message of `n` chunks can be. |
| `reassemblyTimeout` | 30 s | Time since a stream's last chunk before it expires. |

In all, reassembly holds at most `maxReassemblyStreams` streams of at most `maxReassemblyBytesPerSender` declared bytes each: 64 × 16 KB, about 1 MB, with the defaults.

A first chunk that would pass any of the first three is refused before anything is stored, so a sender announcing 9999 chunks costs one comparison.

**The sender keeps within the receiver's bounds.** A multi-chunk message waits in its pipe, without interleaving its chunks, while starting it would give this client more than `maxInFlightPerSender` streams in flight or more than `maxReassemblyBytesPerSender` declared bytes in flight, counted across every destination because the audiences of different distributions overlap; other pipes keep going. The abort of a cancelled or failed message holds its allowance until it leaves, because receivers hold the stream until then. A message that alone declares more than `maxReassemblyBytesPerSender` is refused as `"tooLarge"`; one already queued when `SetLimits` lowers the bound below what it declares fails as `"tooLarge"` unless it has started. Both sides read the same two limits, so **addons that share a prefix must keep them equal**; the defaults are.

**Reports.** Every dropped stream is counted by reason: `streamsExpired`, `streamsEvicted` (the sender left the group), `streamsMalformed`, `streamsRestarted`, `streamsAborted`, `streamsDiscarded` (the last registration of its prefix went), and a first chunk refused at quota in `chunksRefusedQuota`. Expired, departed, malformed, restarted and quota drops are also reported through the host error handler, **at most once per sender per minute**: a sender's first drop is reported at once, and the drops of the following minute are reported together when it ends:

```text
CommKit dropped 99 incomplete messages from Friend-Realm: 1 expired, 98 restarted
```

At most `maxDropReportSenders` senders (64 by default) are tracked at once; past that, drops are reported under `(other senders)`. Aborted and discarded streams are never reported, and neither are chunks refused before any stream exists (an unknown stream, a malformed header), so a stranger can cause at most one report per minute.

**Expiry** runs on one TimerKit timer, armed for the earliest deadline and re-armed after each sweep; nothing polls while no stream is open. The drop reports use one more TimerKit timer, armed only while a sender's minute is running.

**Peer departure.** On `GROUP_ROSTER_UPDATE`, every stream received on `PARTY`, `RAID` or `INSTANCE_CHAT` whose sender neither `UnitInParty` nor `UnitInRaid` places in the group — asked with the full `Name-Realm`, then with the name alone — is dropped as `"departed"`. A secret answer counts as a member. Streams on other distributions are left to expire.

**When the last registration of a prefix goes**, its streams are discarded without a report: nobody is listening.

## Queues and priorities

Every send joins a **pipe**: one per priority and destination, where the destination is the distribution, the target and whether the message is logged. A pipe is first in, first out.

- **Across priorities**, a persistent weighted rotation serves one chunk at a time: ALERT four times, NORMAL twice, BULK once in every seven, skipping a priority that has nothing ready. ALERT therefore gets most of a saturated channel, and BULK is slowed but never starved: a BULK chunk leaves within seven chunks of any saturating load.
- **Inside a priority**, the pipes form a ring and the ring advances after every chunk, so one busy destination cannot starve another: three whispers to three players go out `X Y Z X Y Z`, and the chunks of a long message interleave with short messages to other destinations.
- **Inside a pipe**, messages go out in order, each chunk by chunk.

Priority is service preference, not ordering: a message in one priority may arrive before an earlier one in another.

The queue is bounded across every scope by `maxQueuedMessages` (256) and `maxQueuedBytes` (65536 bytes of text), and a send that would pass either is refused. Lowering a bound drops nothing already queued; new sends are refused until the queue is below it. `GetQueueDepth(priority)` reports messages and text bytes.

**A one-chunk message without callbacks is sent at once, without the queue** (revision 10): when no run is on the stack, no job is scheduled, no held callback is being made and nothing is queued, `Send` checks the bucket and hands the chunk to the client directly, building no queue record, pipe or run, and returns the handle `sent`. Nothing else differs: the bucket is charged, the statistics count it as a queued message that was sent, and a throttle or a refusal answered by the client queues the message and sets it aside, or completes it `failed`, exactly as a run would, with no second attempt inside the call. A message the bucket cannot pay for takes the queue. Fairness and backoff have nothing to act on while the queue is empty.

**The driver** sends chunks in runs. A run sends until the bucket, the queue or a cap of 32 chunks runs out, then schedules its successor: after the time the bucket needs, after the earliest throttled pipe is reinstated, or on the next frame. The successor is one SchedulerKit job while SchedulerKit is loaded, so a run waits for SchedulerKit's shared frame budget as before; without SchedulerKit it is one TimerKit timer, and a run is bounded by the 32-chunk cap alone, as a run inside `Send` always was. SchedulerKit is found with `Registry:Find` when a run is armed, at most once a second until it is found, so one loaded after CommKit is used from the first run armed at least a second after the previous lookup; once found it is kept. Everything below holds the same way on either: "job" means whichever of the two is armed. **A `Send` made while the driver is idle runs it at once, on the caller's stack**: idle means no run on the stack and no job scheduled but one that only makes held callbacks, which is the case whenever the queue was empty. That run is an ordinary run: it serves the queue in rotation, stops at the bucket or the cap, and schedules its successor when anything is left, so a message the bucket pays for in full leaves before `Send` returns and builds no job, and one it pays for in part returns `sending` and continues from the job. A `Send` made while the driver is busy — a job waiting for the bucket, a backoff or the next frame, or a run on the stack, such as from a callback — queues and leaves on that run or its successor. There is never more than one job: scheduling a successor replaces any job already scheduled. The one job exists only while something is queued or callbacks are held (see [Send states](#send-states)); when the queue empties — sent, or cancelled while the driver waits — and no callback is held, the job is cancelled, nothing is scheduled and no per-frame handler or ticker remains.

## Bandwidth

**The bandwidth is an account-wide resource shared by every addon in the session, and CommKit treats it that way.** There is one bucket for every scope and every embedded copy; the limits are shared like SchedulerKit's frame budget, and an addon that raises them raises them for everybody. Libraries should keep the defaults.

The bucket holds at most `burst` (4000) bytes and refills at `maxCps` (800) bytes per second. A message costs its prefix, its text including headers, and `messageOverhead` (40) bytes: a full 255-byte chunk on a six-byte prefix costs 301. It starts full. When a chunk costs more than the bucket can hold (a small `burst`, or the zoning capacity), a full bucket pays for it, so nothing waits forever.

| Mode | When | Refill | Capacity |
|---|---|---|---|
| `"normal"` | otherwise | `maxCps` | `burst` |
| `"lowFrameRate"` | the last sample was below 20 frames per second | half | `burst` |
| `"zoning"` | for 5 s after `PLAYER_ENTERING_WORLD` | a tenth | the smaller of `burst` and half a second of `maxCps` |

The frame rate is sampled from `GetFramerate` when the driver wakes from idle, at most once a second between wakes (sends that each leave inside `Send` sample once between them), and then once a second on a TimerKit ticker, started by the first driver run that leaves anything queued and stopped when the queue empties — never once per send, and never while idle. A message the first run sends in full never starts the ticker.

**Traffic CommKit did not send.** When HookKit is loaded, CommKit secure-hooks `C_ChatInfo.SendAddonMessage`, `SendAddonMessageLogged` and `SendChatMessage` (the legacy globals where `C_ChatInfo` lacks one) with `HookKit:CreateScope():SecureHook` when the driver wakes from idle and finds HookKit. Until it is found, a wake looks it up at most once a second: the hooks are installed on the first wake from idle at least one second after the previous lookup (the first wake of the session always looks), so a HookKit that loads after CommKit is found by the first such wake after it loaded. Traffic other code sends before then is not charged. Every message another addon sends through them is charged to the bucket — prefix, text and overhead, or the most one message can cost when an argument is secret — and may drive the bucket down to two seconds of debt (−1600 bytes by default), which is repaid before CommKit sends again. A flag set around CommKit's own calls keeps its chunks from being charged twice. Secure hooks cannot be removed; they stay installed for the session.

**Throttled sends.** When the client answers `AddonMessageThrottle`, `ChannelThrottle` or a value its enum does not name, the chunk was not sent and is not charged; its pipe is set aside for 0.35 s, doubling on every consecutive throttle of that pipe up to 5.6 s, and reset by the next success. Other pipes keep going. When the pipe is reinstated, the same chunk is tried again.

`GetBudget()` returns the available bytes (negative while repaying debt), the current refill rate, the capacity and the mode.

## SyncSet

The SyncSet part, `parts/CommKit-SyncSet.lua` (revision 11; before that the core held it). Without the part, `scope:SyncSet` raises with the file to embed (see [Parts](#parts)).

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

- `fields` names 1 to 32 distinct fields of 1 to 64 bytes. `Set`, `Get`, `GetHash` and `GetRemote` raise for an undeclared field.
- `schema`, optional, maps declared fields to sealed SchemaKit schemas. A received value that fails its schema is dropped and counted in `syncRejected`; a local `Set` that fails returns `nil, "schema"`.
- `Set(field, value)` returns `true, changed`, or `nil` and CodecKit's reason (`"cycle"`, `"unsupportedType"`, a limit), `"tableKey"`, `"schema"` or `"closed"`. `nil` clears the field. The value is kept by reference: after changing a table, call `Set` again. A secret value, or a table holding one, raises at the caller.
- `Request(target)` whispers the request and returns its send handle, or `nil` and `"closed"`, `"unavailable"` (CodecKit is gone or refused the frame) or a `Send` refusal; the SyncSet registers its prefix like `Register` does and counts toward the scope's `maxRegistrations`. Replies are whispers too, at NORMAL priority, through the same queue and budget.
- A SyncSet answers a request only when it arrived as a whisper; a request on any other distribution is refused and counted in `syncRejected`.
- It answers one peer at most once a second; requests in between are dropped and counted in `syncRejected`.
- At most one reply per peer is in the queue, and at most `maxSyncReplyBytes` (8 KB by default) of replies across every SyncSet; a reply past either is dropped and counted in `syncReplyDropped`, so requests can never fill the queue other sends share.
- The peer cache holds `maxSyncPeers` peers (64 by default); the least recently seen peer not answered in the last second and with no reply still queued is evicted, so eviction never lifts a reply interval or lets a peer queue a second reply. When every cached peer was answered in the last second or has a reply queued, a new peer's request or delivery is dropped. After `SetLimits` lowers the bound, the next new peer evicts down to it.
- A field named in both `values` and `removed` of one delivery is removed, and `OnChanged` fires once.
- `maxListeners`, optional, bounds the `OnChanged` listeners: a positive integer or `CommKit.UNBOUNDED`, 16 by default.
- `OnChanged` accepts `maxListeners` listeners (`nil, "full"` past that, `nil, "closed"` on a closed SyncSet); they run isolated, like receive callbacks.

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

## Chat and Battle.net

The ChatThrottle part, `parts/CommKit-ChatThrottle.lua` (revision 11): the two senders ChatThrottleLib throttles beside addon messages, through CommKit's one bucket, its priorities, its rotation and its send handles. Chat lines and Battle.net messages count in the existing statistics (`messagesQueued`, `messagesSent`, `chunksSent`, `bytesSent`, the refusals); there are no new counters and no new limits.

### `scope:SendChat(request)`

| Field | Required | Meaning |
|---|---|---|
| `text` | yes | The line, at most 255 bytes, no NUL. |
| `chatType` | yes | `SAY`, `EMOTE`, `YELL`, `PARTY`, `RAID`, `RAID_WARNING`, `INSTANCE_CHAT`, `GUILD`, `OFFICER`, `WHISPER`, `CHANNEL`, … as the client names them. |
| `languageID` | no | The language to speak in. |
| `target` | for `WHISPER` and `CHANNEL` | A player name for `WHISPER`, a channel number for `CHANNEL`. Ignored for the others. |
| `priority` | no | `ALERT`, `NORMAL` (default) or `BULK`. |
| `onComplete` | no | Called once with the terminal state and a reason, never before `SendChat` returns. |

**SAY, YELL and CHANNEL are never queued.** The client sends them only from a hardware event (a key press or click) in the outdoor world, and CHANNEL indoors too; a queued line would run later, without one. CommKit cannot tell indoors from outdoors, so it treats all three as needing one everywhere: the line leaves inside the call when the bucket can pay for it now, and otherwise `SendChat` returns `nil, "hardwareEvent"` and sends nothing. Call it from the input handler that has the hardware event. Every other chat type is queued like an addon message: a pipe per chat type, target and language, in the same rotation, charged its text plus `messageOverhead`.

Refusals, each counted like `Send`'s: `"closed"`, `"badDistribution"` (a `WHISPER` or `CHANNEL` without a usable target), `"nulByte"`, `"tooLarge"` (over 255 bytes), `"queueFull"`, `"unavailable"` (no `SendChatMessage` on this client), and `"hardwareEvent"` (not counted). A malformed request, an unknown field, or a secret `text`, `chatType`, `languageID` or `target` raises at the caller: on Retail the client accepts secret arguments only from untainted code, which addon code never is. The client's `SendChatMessage` returns nothing, so a line is `sent` once the call returned without raising; one the client raises on is `failed` with the reason `"error"` and reported.

### `scope:SendBattleNet(request)` and `scope:RegisterBattleNet(prefix, callback)`

`SendBattleNet{ prefix, text, gameAccountID, priority?, onProgress?, onComplete? }` sends a message of any length (up to the queue's byte limit) to a Battle.net game account through `C_BattleNet.SendGameData`, framed and chunked exactly as `scope:Send` frames a message, with the printable digit scheme of the logged channel. A pipe per game account. The client's `SendAddonMessageResult` is read as for addon messages: a throttle sets the pipe aside with the same backoff. Refusals: `"closed"`, `"forbiddenByte"` (NUL, CR, LF or `|`, as for `Send`), `"tooLarge"`, `"queueFull"`, `"unavailable"`. `gameAccountID` must be a positive integer; a malformed request raises at the caller.

`RegisterBattleNet(prefix, callback)` calls `callback(prefix, text, senderID)` for every whole message received through `BN_CHAT_MSG_ADDON`, reassembled by CommKit's reassembly with its bounds. Battle.net traffic is keyed apart from realm traffic: a `Register` on the same prefix never sees it, and its streams never share a sender with a realm player. The registration counts toward the scope's `maxRegistrations`, its `GetPrefix()` answers `prefix`, and it is released with the scope. The prefix is registered with the client like a realm prefix.

With HookKit, `C_BattleNet.SendGameData` joins the [outside-traffic hooks](#bandwidth), so another addon's Battle.net traffic is charged to the budget, as ChatThrottleLib charges it. `SendChatMessage` was already hooked.

**Not verified in a client.** The largest `data` `SendGameData` accepts is not documented in the client's generated API documentation or on warcraft.wiki.gg: CommKit sends at most 255 bytes per call, its addon-message chunk size. Whether `BN_CHAT_MSG_ADDON` needs the prefix registered is not documented either; CommKit registers it. The chat limit of 255 bytes is the chat edit box's (`visibleBytes="255"` in `ChatFrameEditBox.xml`); the API's own limit is not documented. The client suite checks all three (`tests/client/MoltenCodesTest_CommKit/EXPECTED.md`).

## Secret values

Retail clients hand addon code **secret values** in restricted contexts; see [`EMBEDDING.md` → Secret values](../../../docs/EMBEDDING.md#secret-values-retail-12x). A secret prefix, text, distribution, target, priority, constraint, limit (a `SetLimits` value, `maxRegistrations` or `maxListeners`), addon name, sender, field or value passed to CommKit raises at the caller, before CommKit compares it with anything, `nil` and `CommKit.UNBOUNDED` included. A received message whose prefix, text, channel or sender is secret is dropped before any of them is used as a key, compared or measured, and counted in `secretsDropped`. Error messages never format a value CommKit did not create.

A secret receiver of a facade method (`CommKit.GetQueueDepth(secret)`, say) is refused at the caller with the ordinary receiver error, `CommKit:<Method> must be called on the CommKit facade; use CommKit:<Method>(...)`, before it is compared with the facade. CommKit also asks `issecretvalue` about what the client and other packages hand back before it compares it with anything:

| Value | Secret outcome |
|-------|----------------|
| `SendAddonMessage` or `SendAddonMessageLogged` result | Names nothing, so it is a throttle: the pipe is set aside and the chunk retried. |
| `RegisterAddonMessagePrefix` result | `Register` and `SyncSet` return `nil, "unknownResult"`. |
| `IsAddonMessagePrefixRegistered` answer | Not taken as registered; the prefix is registered, which the client accepts again. |
| An entry of `Enum.SendAddonMessageResult` or `Enum.RegisterAddonMessagePrefixResult` | CommKit's own value for that entry is used instead. |
| A SchemaKit schema's `Check` verdict | Not an acceptance: `Set` returns `nil, "schema"`, a delivery is counted in `syncRejected`. |
| An entry of LifecycleKit's `CLOSES_ADDON_SCOPES` | Not a hand-over: case (b) or (c) of [At logout](#at-logout) applies. |

## Security: received data is untrusted

A received message is whatever the sender chose to send, and a sender may be hostile. CommKit bounds what a sender can make it hold and refuses malformed chunks, but it does not authenticate senders or check what a message says. **Decode received text with CodecKit, validate the result with SchemaKit, and treat a failure like any other malformed message**; see [`codecKit/docs/API.md`](../../codecKit/docs/API.md#security-decoded-data-is-untrusted). A SyncSet checks the shape of every frame and each field against its schema when one is given; give one. A SyncSet also caches deliveries nobody requested: any sender can whisper a delivery and have its values stored under its own name, up to `maxSyncPeers` peers, so treat `GetRemote` and `OnChanged` values as claims of that sender, never as facts. Never run received text as code or a macro, and never use it as a frame name, a global name or a format string. The `sender` string is filled in by the server, but the addon behind it can send anything.

## Limits

Every queue, cache and registry CommKit keeps is bounded by default. A bound on an object you create is an option on its constructor; a bound on what the session shares is a `SetLimits` entry. `CommKit.UNBOUNDED` lifts a bound only where the memory is your own: every package-wide limit is grown by other addons or other players, or is a rate, so `SetLimits` refuses it.

| Limit | Default | How to open | `UNBOUNDED` allowed? | Ceiling and reason |
|---|---|---|---|---|
| `maxRegistrations` | 32 | `CreateScope({ maxRegistrations = n })`, `ForAddon(name, { maxRegistrations = n })` | yes | none: the registrations are the scope owner's own |
| `maxListeners` | 16 | `scope:SyncSet(prefix, { fields, maxListeners = n })` | yes | none: the listeners are the SyncSet owner's own |
| `maxQueuedBytes` | 65536 | `SetLimits` | no: every addon shares the queue | 1048576: keeps a message within the chunks the logged channel's header can number (5624) |
| `maxQueuedMessages` | 256 | `SetLimits` | no: every addon shares the queue | 4096 |
| `maxReassemblyStreams` | 64 | `SetLimits` | no: other players grow it | 1024 |
| `maxReassemblyBytesPerSender` | 16384 | `SetLimits` | no: other players grow it | 1048576, as `maxQueuedBytes` |
| `maxInFlightPerSender` | 4 | `SetLimits` | no: other players grow it | 64: stream ids in flight must stay below both radixes |
| `reassemblyTimeout` | 30 s | `SetLimits` | no: other players grow it | 600 s |
| `maxDropReportSenders` | 64 | `SetLimits` | no: other players grow it | 1024 |
| `maxSyncPeers` | 64 | `SetLimits` | no: other players grow it | 1024 |
| `maxSyncReplyBytes` | 8192 | `SetLimits` | no: other players' requests grow it | 1048576, as `maxQueuedBytes` |
| `maxCps` | 800 | `SetLimits` | no: a rate, not a retention bound | 100000 |
| `burst` | 4000 | `SetLimits` | no: a rate, not a retention bound | 1000000 (at least 255) |
| `messageOverhead` | 40 | `SetLimits` | no: part of the rate, not a retention bound | 255 (at least 0) |

These stay fixed, because the client or the wire format sets them:

| Constant | Value | Reason |
|---|---|---|
| addon message | 255 bytes (`MAX_MESSAGE_BYTES`) | the client's limit |
| prefix | 16 bytes | the client's limit |
| chunk header | 4 bytes, 251 payload bytes | the wire format of API generation 1 |
| chunks per message | 16383, 5624 on the logged channel | two header digits of radix 128 or 75 |
| SyncSet `fields` | 1 to 32 names of 1 to 64 bytes | a static declaration every peer shares; a request carries one hash per field |
| raw message | 1 to 4096 parts of 1 to 255 bytes (`SendRaw`) | the client's message limit, and a fixed bound on the array `SendRaw` copies |
| chunks per driver run | 32 | a per-frame work cap, not retention |

```lua
local comm = CommKit:ForAddon("MyAddon", { maxRegistrations = CommKit.UNBOUNDED })
CommKit:SetLimits({ maxQueuedMessages = 128 })
local limits = CommKit:GetLimits() -- a fresh table
```

`maxRegistrations` and `maxListeners` must be positive integers or `CommKit.UNBOUNDED`; anything else raises at the caller. `ForAddon` applies `options` when it creates the scope; a later call that passes a different `maxRegistrations` raises, so two callers cannot disagree silently about one scope. `scope:GetMaxRegistrations()` reports the bound.

`SetLimits` raises at the caller on an unknown name, `CommKit.UNBOUNDED` (naming the reason), a secret value or a value outside its range, before changing anything. Lowering a queue bound drops nothing already queued. Lowering `maxReassemblyBytesPerSender` fails every queued message that has not started and now declares more (`"failed"`, reason `"tooLarge"`), because it could never start. **The limits are shared by every consumer in the session**, and are kept across an in-place upgrade. `CommKit.UNBOUNDED` is one table kept in the package state, so every embedded copy and every revision publishes the same sentinel.

## Error behaviour

- **Programming errors raise at the caller's line**: a wrong receiver (a `.` call), a wrong argument or option type, an unknown request field, a secret argument, an out-of-range limit, and a member of a part that is not loaded ([Parts](#parts)). The level is explicit, so the line printed is the caller's.
- **Everything that depends on the state of the queue or on the data is a return value**: `Send`, `SendRaw`, `SendChat`, `SendBattleNet`, `Register`, `RegisterRaw`, `RegisterBattleNet` and `SyncSet` answer `nil, reason` with the reasons each section lists, and count it.
- **Received data never raises**: a malformed chunk, a hostile header, a secret argument or a frame a SyncSet cannot read is dropped and counted, and dropped streams are reported at most once per sender per minute.
- **Callbacks are isolated**: a raising receive, progress, completion or `OnChanged` callback is reported through the host error handler (or `securecallfunction`) and CommKit carries on.

## Statistics

`GetStatistics()` returns a fresh table of counters since load, plus three current totals:

| Counter | Counts |
|---|---|
| `messagesQueued`, `messagesSent`, `messagesCancelled`, `messagesFailed` | sends by outcome |
| `refusedQueueFull`, `refusedTooLarge`, `refusedClosed`, `refusedForbiddenByte`, `refusedBadDistribution`, `refusedUnavailable`, `refusedNulByte` | refused sends by reason (`refusedNulByte`: raw messages, revision 8) |
| `chunksSent`, `bytesSent` | chunks that left, and their bytes on the wire |
| `throttled` | throttle results |
| `outsideMessages`, `outsideBytes` | traffic charged from the HookKit hooks |
| `messagesReceived`, `bytesReceived` | whole messages delivered and their bytes |
| `chunksReceived`, `chunksRefused` | addon messages on registered prefixes, and those refused |
| `streamsOpened`, `streamsCompleted`, `streamsExpired`, `streamsEvicted` | reassembly streams opened, completed, expired, and evicted when their sender left the group |
| `secretsDropped` | received messages dropped because an argument was secret |
| `streamsMalformed`, `streamsRestarted`, `streamsAborted`, `streamsDiscarded`, `chunksRefusedQuota` | reassembly drops by reason |
| `syncRequests`, `syncAcknowledgements`, `syncDeliveries`, `syncRejected` | SyncSet messages received, and those refused |
| `syncReplyDropped` | SyncSet replies not queued: one already pending for that peer, or the reply allowance (`maxSyncReplyBytes`, 8 KB by default) full |
| `queuedMessages`, `queuedBytes`, `openStreams` | the current queue and reassembly totals |

## Scopes and shutdown

CommKit does not observe addon shutdown; the scope `ForAddon(addonName)` returns stays open until `CloseAddonScopes(addonName)` closes it. That call is the second half of the two-step TimerKit, SchedulerKit, EventKit, HookKit and CommandKit use, and `ForAddon` makes sure somebody makes it at logout: see [At logout](#at-logout). Closing cancels the scope's pending sends, which complete as `"cancelled"` with the reason `"shutdown"`, closes its SyncSets and disconnects its registrations.

Closing is terminal, as in TimerKit and SchedulerKit: the closed scope stays the addon's canonical scope, so a later `ForAddon(addonName)` returns it closed and its `Register`, `Send` and `SyncSet` return `nil, "closed"`. An addon that never asked for a scope has nothing to close, so the addon-scope map grows only with `ForAddon` calls.

## At logout

An addon scope is closed at logout whatever LifecycleKit and CommKit revisions an addon set pairs. CommKit never depends on LifecycleKit (design constitution, principle 4b); `ForAddon` finds it with `Registry:Find` and decides who closes the scope:

| Case | Registered | Who closes the addon scope |
|---|---|---|
| (a) | LifecycleKit whose `LifecycleKit.CLOSES_ADDON_SCOPES` names `commKit` (0.6.0 and later) | LifecycleKit, after the addon's shutdown callbacks. `ForAddon` only makes sure the addon has a LifecycleKit instance (`LifecycleKit:ForAddon(addonName)`), because LifecycleKit closes the scopes of the addons it tracks. |
| (b) | LifecycleKit without that field (older revisions) | CommKit subscribes once to `LifecycleKit:ForAddon(addonName):OnShutdown` and calls `CloseAddonScopes` there. The subscription is kept on the scope and disconnected when the scope closes first. |
| (c) | no LifecycleKit | One package-level `Once("PLAYER_LOGOUT")` connection in CommKit's own EventKit scope, made on the first `ForAddon` that needs it, closes every addon scope in this case, in addon-name order. |
| (d) | — | Does not arise: EventKit is a required dependency, so case (c) is always available and an addon never has to close its scope itself. |

The decision is made at the first `ForAddon(addonName)` and taken again by every later `ForAddon` while it is (c), so a LifecycleKit that loads after the first call still takes the scope over. The (c) watcher leaves a scope that moved to (a) or (b) to LifecycleKit. A failure in LifecycleKit while deciding goes to the host error handler; `ForAddon` still returns the scope, and the next call asks again.

In case (b) CommKit's `OnShutdown` subscription is made at the first `ForAddon`, so it runs before the addon's own shutdown callbacks subscribed later, which then find the scope closed and their pending sends cancelled. Only case (a) guarantees that shutdown callbacks can still send, which is why LifecycleKit 0.6.0 announces the list. Manual scopes are never closed at logout.

## Performance

- **Receiving a single chunk allocates no table**: the payload is one `string.sub`, and the lookup, the counters and the dispatch allocate nothing. Specs guard this with `collectgarbage("count")`.
- A multi-chunk stream leases one stream record from a PoolKit table pool, holding the chunks in its array part, and returns it when the stream completes or is dropped; the key is one string per chunk and the message one `table.concat`. Per-sender accounting records are recycled through a free list of at most 16, and arming the expiry timer for a full timeout, as the first stream to open does, restarts one kept TimerKit timer instead of building a timer handle: a two-chunk message from a new sender allocates its three strings and what TimerKit's start allocates. Specs guard this.
- A one-chunk message without callbacks sent while nothing is queued allocates its handle (four fields; revision 10 dropped the unread `_schema` field from every send handle) and its chunk string, and nothing else: no queue record, pipe, pipe key or run.
- A send allocates its handle, its pipe key string and one string per chunk. A message sent in full inside `Send` builds no driver job; one that leaves anything queued, or whose callbacks are held, costs what one job (or, without SchedulerKit, one TimerKit timer) costs until the driver is idle again. The queue record comes from CommKit's own free list of at most 64 records, which lets go of the message's text, handle and callbacks when it ends, and the pipe of a destination with nothing queued from a free list of at most 16 emptied pipes; each is built only when its list is empty. A spec guards that a send the bucket pays for at once allocates only its handle and its chunk string.
- Until HookKit is found, a wake from idle looks it up with `Registry:Find` at most once a second (revision 7), not once per send; once found, the hooks are installed and it is never looked up again.
- The forbidden-byte check of a framed message (NUL, LF, CR, `|`) is four plain searches, and the raw path's NUL check one; a character class is tried at every start position in Lua 5.1 and cost about 56 µs on 8,000 bytes on the host, the plain searches under 1 µs.
- The reassembly key suffix of a stream id is made the first time that id is received and kept (at most 128 plus 75 strings); a session that never receives a multi-chunk message holds none of them.
- Against AceComm-3.0 with ChatThrottleLib on the host benchmark (`python3 -m tooling.bench.run --workload comm`), CommKit's time ÷ Ace3's

  | Case | Revision 9 ÷ Ace3 | Revision 10 ÷ Ace3 | Bytes per operation, revision 10 (Ace3) |
  |---|---:|---:|---|
  | send 200 / 1,000 / 8,000 bytes | 7.22 / 5.37 / 4.53× | 2.73 / 2.55 / 1.38× | 674 (104), 2,333 (2,086), 19,116 (21,679) |
  | receive 200 / 1,000 / 8,000 bytes | 3.38 / 3.52 / 2.69× | 3.18 / 3.37 / 2.50× | 225 (0), 2,014 (1,703), 30,188 (29,848) |

  Both columns come from one session on 2026-11-15, on a machine that was not idle. What a short send still costs over ChatThrottleLib's is the request validation (unknown-key refusal and secret checks), the handle and the wire header; a multi-chunk receive pays for the expiry timer being disarmed whenever the last stream closes.
- An idle CommKit runs nothing: no job, no per-frame handler, no ticker. The frame-rate ticker runs only while something is queued, the expiry timer only while a stream is open, and the drop-report timer only while a sender's report minute is running.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **`battleNet` is accepted and never selects Battle.net.** The plan lets the payload permit Battle.net transport; `Send` addresses a player by name and Battle.net a game account with its own receive event, so Battle.net game data has its own methods in the ChatThrottle part (revision 11), and the flag stays a permission that is honoured by never being needed.
- **Refusal reasons beyond the plan's three**: `"forbiddenByte"`, `"badDistribution"` and `"unavailable"` for `Send`; `"full"` and the client's reasons for `Register`. Each names a condition the caller can act on.
- **The scope bound counts registrations**, 32 per scope by default with SyncSet registrations included, rather than distinct prefixes; bounding registrations bounds prefixes too.
- **Priorities are weighted 4 : 2 : 1 per chunk**, where ChatThrottleLib split bandwidth equally between priorities with traffic; equal shares make ALERT no faster than BULK under load.
- **The reassembly timeout counts from a stream's last chunk**, not its first, so a long message on a degraded budget does not expire while it is still arriving.
- **Per-sender bytes are counted from the size a first chunk declares**, so a stream is refused before it holds anything.
- **`SetLimits` also accepts `maxCps`, `burst` and `messageOverhead`**, and `GetLimits` is added.
- **`SyncSet` additions**: `Get`, `GetHash`, `GetRemote`, `Close` and `IsClosed`; a reply interval of one second per peer; a peer cache of 64; `OnChanged` receives `nil` for a cleared field. `schema` maps each field to its own sealed schema, because a delivery carries only the fields that changed.
- **Scope additions**: `UnregisterAll`, `CancelAll`, `GetRegistrationCount`, `GetPendingCount`; **facade additions**: `CloseAddonScopes`, `MAX_MESSAGE_BYTES`, `MAX_REGISTRATIONS`.
- **Every message carries a control byte**, including single chunks, so no message is ever escaped and a receiver can tell CommKit traffic from anything else on the prefix.
- **The driver is a chain of plain SchedulerKit jobs, or of TimerKit timers without SchedulerKit (revision 11), not a lane.** The plan names a lane; a lane rations concurrent work and spacing between starts, while the driver is a single consumer whose pacing comes from the byte bucket, so one job at a time — scheduled with `Schedule`, `After` for a bucket or backoff wait, or `NextFrame` after the per-run cap — gives the same "exists only while something is queued" with no lane registered in the session-wide lane table. From revision 6 a `Send` made while the driver is idle also runs it once on the caller's stack, which no lane could do.
- **Additions to the protocol**: the abort chunk (`05`), and a printable digit scheme for the logged channel.
- **The sender keeps within the receiver's stream bounds**, counted across all destinations rather than per destination, because one receiver can be in the party, the raid and the guild at once.
- **A send result the client's enum does not name is retried like a throttle**, not failed.
- **Dropped streams are reported at most once per sender per minute**, aggregated, where the plan reports each dropped stream once; a report per stream would let a stranger fill the error log.

## Embedded copies and upgrades

The package state (`_state`) holds the queues, the bucket, the limits, the statistics, the reassembly streams, the prefix signals, the Kit-owned scopes and the pools, and all of it is kept across an in-place upgrade: a newer compatible revision replaces the functions on the shared prototypes and in the dispatch table, and every callback CommKit handed to EventKit, TimerKit, SchedulerKit and HookKit calls through that table, so queued sends, open streams, registrations and SyncSets keep working under the new code.

Revisions 3 and 4 inherit revision 2's state unchanged. Revision 5 adds the free lists (`spares`) and the reusable expiry timer to an inherited state; streams a revision 4 copy opened keep their separate chunk list until they close. Revision 6 adds the record free list (`spares.records`), the held-callback array (`deferred`), the driver's `inline` flag and the time of the last frame-rate sample to an inherited state; revision 7 adds the time of the last HookKit lookup (none yet, so the next wake looks it up); revision 8 adds the framing of each prefix (`prefixFraming`; every prefix an older copy registered is framed) and starts the `refusedNulByte` counter at zero; revision 9 inherits revision 8's state unchanged, and so does revision 10 (a send handle an older copy built keeps its `_schema` field, which nothing reads); a queue record an older copy leased from its PoolKit pool goes back to that pool when its message ends, and a driver job an older copy scheduled runs the new code. Revision 2 and later upgrade the addon scopes revision 1 built in place and arrange their [logout close](#at-logout) while it loads, for every open one. A later revision keeps the `OnShutdown` subscriptions and the `PLAYER_LOGOUT` watcher it inherits: the subscription calls the facade and the watcher calls through the `logout` trampoline, so both run the newest code, and nothing is subscribed twice. Revision 11 splits the file: SyncSet into its part, and SchedulerKit becomes optional. It adds the part interface (`parts`, `helpers`, `partInterface`, `transports`) to an inherited state, and a driver job an older copy scheduled runs the new code and is cancelled through `Cancel()` like a TimerKit timer. A state built by a whole-file revision (10 or older) may hold SyncSets: when the SyncSet part is loaded, from any addon, by the next frame, it serves them and they keep working. When it is not, the next frame closes the SyncSets of addon scopes, reports once through the host error handler which file to embed, and leaves a SyncSet of a manual scope (which CommKit cannot enumerate) inert: it stops receiving and answering, its methods raise with the file to embed, and its scope still closes it; the first time it receives anything, that is reported once. A revision 10 copy loaded after a revision 11 core is the lower revision and yields: its addon's `SyncSet` call raises with the file to embed. No revision of CommKit was ever published, so only development copies can meet either case.

The wire protocol belongs to API generation 1, not to the revision.
