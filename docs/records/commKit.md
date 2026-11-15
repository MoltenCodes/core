# commKit records

Moved from `docs/ROADMAP.md` (Package D planned Kits — the nine points).

## commKit

**commKit** — facade `CommKit`

1. Package `commKit`, facade `CommKit`, API generation 1.
2. Purpose: addon messaging of arbitrary length with prefix registration,
   chunking and reassembly, priority queues that refuse rather than grow, a
   bandwidth budget shared with everything else in the session (including
   traffic sent outside the Kit, measured through a secure hook), bounded
   per-sender reassembly with expiry, payload-driven channel selection, and
   a content-hash `SyncSet` for versioned fields with delta replies.
   Non-goals: serialisation (codecKit), encryption, guaranteed delivery or
   ordering across priorities, exceeding the client's rate limits.
3. Dependencies: registry API 2, signalKit API 1, eventKit API 1
   (`CHAT_MSG_ADDON`), schedulerKit API 1 (the send driver is a lane that
   exists only while something is queued), poolKit API 1 (message and chunk
   records); codecKit API 1 and hookKit API 1 optional through
   `Registry:Find` (hashing for SyncSet, the outside-traffic hook);
   lifecycleKit API 1 for addon scopes.
4. Surface: `CommKit:ForAddon(addonName)` / `CreateScope()`;
   `scope:Register(prefix, callback)` → connection (callback receives
   `prefix, text, distribution, sender` and never a partial message);
   `scope:Send{ prefix, text, distribution, target, priority, constraints,
   onProgress, onComplete }` → send handle or `nil, reason` when a bound
   would be exceeded (`"queueFull"`, `"tooLarge"`, `"closed"`); handle
   `Cancel()`, `GetState()`, `GetBytesSent()`, `GetBytesTotal()`;
   `CommKit.Priority.ALERT | NORMAL | BULK`; `scope:SyncSet(prefix, {
   fields, schema })` → `Set(field, value)`, `Request(target)`,
   `OnChanged(callback)`; package `GetQueueDepth(priority)`, `GetBudget()`,
   `SetLimits{ maxQueuedBytes, maxQueuedMessages, maxReassemblyStreams,
   maxReassemblyBytesPerSender, maxInFlightPerSender, reassemblyTimeout }`,
   `GetStatistics()`.
5. Ownership: a registration belongs to a scope, released on close and at
   shutdown; reassembly streams keyed by prefix, distribution and sender,
   bounded in count, bytes and time, evicted on peer departure; an evicted
   stream is reported once per stream.
6. Performance: every queue bounded in messages and bytes with a named
   refusal; the single-chunk receive path allocates no table; per-destination
   round-robin inside a priority; no per-frame handler while idle; frame
   rate sampled on a timer, never on the hot path; adaptive degradation of
   the budget below 20 frames per second and for five seconds after login or
   zoning.
7. Tests: chunking at every boundary, reassembly in and out of order, a
   missing chunk, interleaved streams from one sender, a stream that never
   completes and expires, a hostile chunk header refused at quota, every
   bound reached with the refusal surfaced, priority fairness and
   round-robin, the throttled result putting a pipe aside, budget accounting
   with a simulated outside sender, cancel while queued and mid-send, scope
   close and shutdown mid-send, SyncSet delta and ack, statistics, all
   against the stubbed client and clock; upgrade; manifest; error levels.
8. Docs: README, API.md specifying the chunk protocol byte by byte, the
   bounds and their defaults, the priority model, the shared-bandwidth
   statement and the security note that received data is untrusted;
   INTERNALS.md; CHANGELOG; EMBEDDING.md host row (`C_ChatInfo`).
9. Status: implemented (package D, 0.1.0); deviations recorded in
   `packages/commKit/docs/API.md`.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## commKit send fast path and cheaper checks

**commKit send fast path and cheaper checks** — an internal change to facade `CommKit`

1. Package `commKit`, facade `CommKit`, API generation 1 (unchanged),
   version 0.5.3, implementation revision 10 (from 0.5.2, revision 9).
   Patch: no public surface is added or removed.
2. Purpose: bring a send down towards AceComm-3.0 with ChatThrottleLib
   without dropping a documented guarantee, following the runtime
   performance diagnosis of 2026-11-15 (commKit, fixes F1 to F4, R1) and the
   memory diagnosis (fix 8).
   - F1. The forbidden-byte refusal (`CommKit.lua:4004`, pattern
     `"[%z\n\r|]"` at `:144`) becomes four plain `string.find(text, byte,
     1, true)` calls. Same refusal set, same reason code. Lua 5.1 tries a
     character class at every start position; plain finds do not.
   - F2. Send at once: a message of one chunk with no `onProgress` or
     `onComplete`, sent while the driver is not running, no deferred flush
     is under way, no driver job is scheduled and nothing is queued, is
     handed to the client straight away. One bucket check (refill and cost
     with one mode reading), then one client call under `pcall` with
     `sendingOwnTraffic` set. No record, pipe, ring entry or driver run is
     created, and the handle comes back already `sent`. When the bucket
     cannot pay, the message takes the queue path as today. When the client
     refuses or raises, the message is enqueued and then set aside
     (throttled) or completed as failed, exactly as the driver would, so a
     refusal never causes a second attempt within the same call.
   - F3. Host reads: `SendAddonMessage` and `SendAddonMessageLogged` are
     read once per driver run (not once per send and again per chunk), the
     `Enum.SendAddonMessageResult.Success` value once at load (the client's
     `Enum` is fixed for the session; the built-in fallback stays for a
     client without it). A function another addon replaces between two runs
     is used from the next run. One replaced from inside a hook on the send
     function itself takes effect from the next run, not the next chunk.
   - F4. Driver loop: the mode and rate are computed once per run, the
     rotation walk is skipped while exactly one message is queued and its
     pipe is still at the ring index served last (the guard that keeps the
     throttle specs passing), and `assignStreamId` runs for a message's
     first chunk only.
   - R1, by the secret-probe rule (one rule for every Kit):
     `issecretvalue` and `securecallfunction` are resolved once at load. A
     function absent at load is looked up again on each call, so a probe
     installed later is still honoured. That covers the three specs that
     install the probe after load and that pure load-time caching broke.
   - F5. Send handles drop `_schema`, which nothing reads (the handle
     layout is 1 and has never changed). Absent means layout 1 to any
     future migration. A fast-path handle has four fields and fits a
     four-slot hash.
   - Memory fix 8: the reassembly key-suffix tables (`WIRE.plain.keySuffix`,
     `WIRE.logged.keySuffix`, 128 and 75 strings, `:162-168`) are built on
     first use. Correction to the memory diagnosis, which says "first send": they are
     read only by the receive path (`:3161`), so they are built on the
     first chunk of a multi-chunk message received.
   Kept, by the owner's decision: "nothing armed when idle". The reassembly
   expiry timer is still cancelled when the last stream closes (R2, lazy
   disarm, is not taken). Not in this record: R3 (a no-wipe stream-pool
   reset, one isolation layer on receive), and anything that changes the
   wire format or the request-table API.
3. Dependencies: unchanged (registry API 2, signalKit, eventKit, poolKit,
   timerKit as today). Host functions as today: `C_ChatInfo.SendAddonMessage`
   and `SendAddonMessageLogged` (or the legacy globals), `Enum`,
   `issecretvalue`, `securecallfunction`; no new client API.
4. Surface: unchanged. Same errors at the same caller lines, same reasons,
   handle states, statistics, limits and throttle behaviour. One observable
   difference: a fast-path send is already `sent` when `Send` returns (today
   the inline driver run gives the same state before `Send` returns, so
   callers already see it). `SendHandle` fields are private; `_schema` was
   never documented.
5. Ownership: unchanged. The fast path counts `messagesQueued`,
   `chunksSent`, `bytesSent` and the terminal statistic as the queued path
   does. The suffix tables and the load-time host values are file-local and
   rebuilt by each revision's load; nothing new goes into `_state`, so an
   in-place upgrade from revision 9 takes over queues, pipes, streams and
   timers as before. The main chunk holds 198 of 200 locals: the new
   load-time values are fields of an existing file-local table, not new
   locals.
6. Performance and memory, host bench (`comm` workload), MoltenCodes ÷ Ace3
   in the same run. Before: the unmodified tree. After: the diagnosis
   prototype (F1 to F5, R1) with the expiry disarm restored, rerun
   2026-11-15:

   | Case | Before | After (expected) | B/op before → after (Ace3) |
   |---|---:|---:|---|
   | send-200 | 7.37× | 2.85× | 834 → 674 (104) |
   | send-1000 | 5.50× | 2.59× | 2,493 → 2,493 (2,086) |
   | send-8000 | 4.68× | 1.41× | 19,276 → 19,276 (21,679) |
   | receive-200 | 3.20× | 2.98× | 225 (0) |
   | receive-1000 | 3.53× | 3.47× | 2,014 (1,703) |
   | receive-8000 | 2.52× | 2.39× | 30,188 (29,848) |

   Calls per send-200: 121 → 63; per send-8000: 1,320 → 571 (Ace3: 647).
   Resident memory: −19.2 KB (memory diagnosis, exact drop) for a session that
   never receives a multi-chunk message.
   The target "at or below ChatThrottleLib/AceComm cost" is met on calls
   for large sends and on allocation for send-8000, not on time. What is
   left on send-200 is the request validation (about 186 instructions:
   unknown-key refusal and secret checks), the handle object and the
   one-byte control header (wire format). Each buys a documented
   guarantee. Receive stays above 2× without R2: the expiry timer cancel and
   restart per multi-chunk message (about 130 instructions, 20 calls) is
   the price of "nothing armed when idle".
7. Tests, failing first where a spec can observe the change:
   - the forbidden bytes NUL, LF, CR and `|` each refused with the same
     reason, at the start, the middle and the last byte, and a 255-byte
     clean message accepted;
   - fast path: one-chunk send while idle sends once and returns a `sent`
     handle with no record, pipe or driver run left behind; the same send
     with a queued message, a running driver, a scheduled job, a deferred
     flush, callbacks or two chunks takes the queue; an empty bucket takes
     the queue; a client refusal enqueues and sets the pipe aside without a
     second attempt; a raising client completes the handle as failed and
     reports through the error handler once; statistics match the queued
     path;
   - host functions read once per run: a `C_ChatInfo` function replaced
     between runs is used by the next run;
   - the probe rule: a probe present at load is used, a probe installed
     after load is honoured (the three existing specs keep passing),
     `securecallfunction` likewise;
   - the suffix tables absent after load and built by the first multi-chunk
     receive, keys unchanged;
   - the expiry timer still disarms when the last stream closes (existing
     spec kept);
   - `Bootstrap_spec:322` (one spare record) is rewritten for the fast path,
     which leaves no spare record;
   - in-place upgrade from revision 9 with a message queued and a stream
     open: both finish under revision 10.
   Client suite (`tests/client/MoltenCodesTest_CommKit/`, never run here):
   a fast-path send on the real channel reports `sent`, and a three-chunk
   message to the player still arrives whole.
8. Docs: `docs/API.md` (the send path and when a message is sent at once,
   cost notes), `INTERNALS.md` (the fast path, per-run host reads, the lazy
   suffix tables, the handle without `_schema`), `CHANGELOG.md` 0.5.3,
   `README.md` performance note, `tests/README.md`, the client suite's
   `EXPECTED.md`.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.5.3,
   revision 10, 12 specs (275). Raw messages' NUL check is a plain find as
   well; reassembly key suffixes are made per stream id on first receipt
   rather than all on the first receive.

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## commKit (package O): SyncSet as a part, ChatThrottle, a new part for chat and Battle.net sends, and SchedulerKit optional

**commKit (package O): SyncSet as a part, ChatThrottle, a new part for chat and Battle.net sends, and SchedulerKit optional** — a change to facade `CommKit`

1. Package `commKit`, facade `CommKit`, API generation 1 (additive),
   version 0.6.0 (from 0.5.3), implementation revision 11 (from 10). Parts,
   revision 1 each: `SyncSet` (moved), `ChatThrottle` (new).
2. Purpose: three things.
   - **Split.** SyncSet with its content hashes and methods is 21.4 KB of
     CommKit's 134.7 KB of live prototypes and 33.7 KB resident. It has no
     Ace3 counterpart and nothing else in the repository creates one.
     Reassembly stays in the core: AceComm reassembles multipart messages
     itself, and all four corpus addons that use AceComm (Details, Grid2,
     Skada, WeakAuras) also use AceSerializer, so their payloads routinely
     pass 255 bytes; a receiver without reassembly would drop a peer's
     messages silently. Raw messages and the outside-traffic hooks stay too
     (5 KB of prototypes; the hooks are what makes the shared budget
     mutual).
   - **ChatThrottle** (the Ace3 gaps diagnosis, work package 11):
     ChatThrottleLib also throttles `SendChatMessage` and Battle.net game
     data; CommKit throttles addon messages only, and its `constraints.
     battleNet` is inert. Corpus use of either is 0 of 16, so it is a part:
     an addon that needs it pays for it, no one else does. CommKit's main
     chunk holds 198 of 200 locals, so it could not go into the core anyway.
   - **SchedulerKit optional.** The driver uses SchedulerKit for one job at
     a time and nothing else: `Schedule` to wake it, `NextFrame` after the
     32-chunk run cap, `After` for a bucket or backoff wait. It is a plain
     job, never a coroutine, and never asks `ShouldYield`. Requiring
     SchedulerKit costs every comm addon its 90 KB core. From this revision
     the driver uses SchedulerKit **when it is loaded**, exactly as today,
     and TimerKit (already required) when it is not: `After(0)` for a wake
     or the run cap, `After(delay)` for a wait. What each documented
     guarantee needs:
     - *Fairness* (the weighted rotation, the pipe ring, order inside a
       pipe), the bucket, the run cap, backoff and the fast path live in
       the run itself and do not change.
     - *Nothing armed when idle*: one TimerKit timer instead of one job,
       cancelled when the queue empties and no callback is held; the
       frame-rate ticker is TimerKit's already.
     - *The frame budget*: SchedulerKit's frame budget exists only while
       SchedulerKit is loaded, and then the driver is its job, as today, so
       a run still waits for the shared budget. Without SchedulerKit there
       is no budget to share, and a run is bounded by the documented
       32-chunk cap, as an inline run inside `Send` already is today.
     - *No callback before `Send` returns*, and held callbacks made by the
       next run before it sends: unchanged. API.md says that run is "a
       SchedulerKit job scheduled with `Schedule` (so it runs in
       SchedulerKit's next pass: on a later frame, or later in the current
       pass when `Send` was called from a SchedulerKit job)". With TimerKit
       it runs on a later frame; the "current pass" case needs a SchedulerKit
       job on the stack, so SchedulerKit is loaded and the driver uses it.
       Every documented timing therefore holds; only the sentence names
       both drivers.
     - *Error isolation*: a scheduled run keeps its own `pcall` around
       `driveChunks`, as the inline run has, so a failure is reported and a
       retry is arranged whichever Kit fired it.
     - *Logout and scopes*: CommKit owns one SchedulerKit scope today and
       one TimerKit scope already; the driver's timer lives in the TimerKit
       scope, closed with the others.
     No documented guarantee is weakened, so the lever is in this record.
     What changes is loading: CommKit no longer raises `MoltenCodes CommKit
     requires SchedulerKit API 1 to be loaded first`; it now needs six
     files, not seven.
   Non-goals: selecting Battle.net for an ordinary `Send` (a send addresses
   a player by name, Battle.net by game account; `constraints.battleNet`
   stays accepted and inert, as documented); splitting chat messages longer
   than the client accepts; moving the driver off SchedulerKit when
   SchedulerKit is loaded.
3. Dependencies: core: registry API 2, signalKit, eventKit, timerKit,
   poolKit API 1 required; `schedulerKit` API 1 moves from `dependencies` to
   `optionalDependencies`, beside codecKit, hookKit, schemaKit and
   lifecycleKit. SchedulerKit is found through `Registry:Find` when the
   driver is scheduled (cached once found, as EventKit caches it), so a
   SchedulerKit loaded after CommKit is used from the next schedule. `SyncSet`: `codecKit` API 1 required (today it is
   required at the call), `schemaKit` API 1 optional. `ChatThrottle`: none
   beyond the core; `hookKit` optional (the Battle.net hook). Client API,
   from apiKit's generated tables (Gethe/wow-ui-source `live` `297d7aa`
   12.1.5, `classic` `e5d9b3a` 5.5.4, `classic_era` `4192ac6` 1.15.9):
   `C_ChatInfo.SendChatMessage(message, chatType?, languageID?, target?)`,
   no return value, `HasRestrictions`, flag
   `RestrictedForMacroChatMessages`, secret arguments
   `AllowedWhenUntainted` (live); `C_BattleNet.SendGameData(gameAccountID,
   prefix, data)` returning `SendAddonMessageResult`
   (`BattleNetDocumentation.lua`, all three flavours); event
   `BN_CHAT_MSG_ADDON(prefix, text, channel, senderID)` (all three).
   warcraft.wiki.gg, `API_C_ChatInfo.SendChatMessage` (read 2026-11-15):
   SAY and YELL need a hardware event in the outdoor world, CHANNEL indoors
   and outdoors. Each use is guarded for the flavour gate.
4. Surface.
   - New: `CommKit:HasPart(name)`.
   - **SyncSet**, with the part: `scope:SyncSet`, the prototype and every
     method unchanged. Without it: `scope:SyncSet` raises at the caller with
     the file to embed (on a closed scope it still returns `nil, "closed"`
     first, as today). `UnregisterAll`, `Close` and logout close SyncSets
     through a dispatch entry the part fills. `maxSyncPeers`,
     `maxSyncReplyBytes` and the `sync*` statistics stay in the core's
     tables.
   - **ChatThrottle** (new, in the part; stubs on the scope prototype
     without it):
     - `scope:SendChat(request)` with `text`, `chatType` (non-empty string),
       `languageID`, `target`, `priority`, `onComplete`; returns a send
       handle or `nil, reason`. Charged to the same bucket as addon
       messages (text plus `messageOverhead`), in its own pipe per chat
       type, target and language, served by the same rotation. **SAY, YELL
       and CHANNEL are never queued**: they leave inside the call when the
       bucket can pay, or are refused with `"hardwareEvent"`, because a
       queued send runs without the hardware event the client requires.
       Other refusals as `Send`: `"closed"`, `"queueFull"`, `"tooLarge"`
       (longer than the client's chat limit, which is read from Blizzard's
       UI source before code), `"unavailable"`. A secret `text` or `target`
       raises at the caller (the client refuses secrets from tainted
       code). The client returns nothing, so a chat send completes `sent`
       when the call returned without raising.
     - `scope:SendBattleNet(request)` with `prefix`, `text`,
       `gameAccountID` (positive integer), `priority`, `onProgress`,
       `onComplete`: CommKit's framing and multi-chunk messages over
       `SendGameData`, a pipe per game account, the client's result read
       as for addon messages (a throttle sets the pipe aside, as today).
       The chunk size is the addon-message size until a client check
       confirms what `SendGameData` accepts; the generated documentation
       does not say.
     - `scope:RegisterBattleNet(prefix, callback)`: `callback(prefix, text,
       senderID)` for whole messages received through
       `BN_CHAT_MSG_ADDON`, reassembled by the core's reassembly with a
       sender key of its own, so Battle.net and realm senders never share a
       stream. Counts toward `maxRegistrations`.
     - With HookKit, `C_BattleNet.SendGameData` joins the outside-traffic
       hooks, so another addon's Battle.net traffic is charged to the
       budget, as ChatThrottleLib charges it; CommKit already hooks
       `SendChatMessage`.
     - Statistics: chat and Battle.net sends count in the existing
       counters; no new keys.
5. Ownership: SyncSets and Battle.net registrations belong to their scope
   and close with it; chat and Battle.net sends are send handles like any
   other and are cancelled by `CancelAll` and `Close`. The core gains a
   transport field on a pipe (absent for addon and logged pipes) that names
   the part's sender, so the driver serves every pipe in one rotation. The
   driver's pending run is a SchedulerKit job or a TimerKit timer; both are
   cancelled through `Cancel()`, and a run already scheduled by revision 10
   (always a job) is taken over as it is.
6. Performance and memory: CommKit 213.9 KB → 180.2 KB measured for the core
   (about 182 KB expected), SyncSet 33.7 KB, ChatThrottle about 24 KB.
   Against AceComm + ChatThrottleLib (46.7 KB): 4.6× → 3.9× core only;
   with ChatThrottle, which covers what ChatThrottleLib adds, about 4.4×.
   Comm set (Registry, SignalKit, EventKit, LifecycleKit, TimerKit, PoolKit,
   CommKit): 824.3 KB today with SchedulerKit required → 679.2 KB measured
   split → about 589 KB without SchedulerKit (587.2 KB measured with a
   research copy of CommKit that loads without it, plus about 2 KB for the
   TimerKit driver). Against Ace3's 100.5 KB: 8.2× → 6.8× → 5.9×. With
   HookKit and CodecKit, against Ace3 plus AceHook and AceSerializer
   (129.8 KB): 1,035.3 → 833.7 → about 744 KB (742.0 measured), 8.0× → 6.4×
   → 5.7×. The driver reads one pipe field per chunk and, once per schedule,
   which Kit to schedule on: the `comm` bench (send-200,
   send-1000, send-8000, receive) within 2% of today with SchedulerKit
   loaded, and measured once more without it; the fast path, which
   schedules nothing, unchanged. The main chunk drops from 198 to about 193 locals.
7. Tests, failing first where a spec can observe it:
   - Bootstrap and Manifest for both parts; every SyncSet spec with the
     part, unchanged; without it, the stub at the caller's line, `HasPart`,
     scope close and logout with no SyncSet part;
   - `SendChat`: queued types through the bucket and rotation; SAY, YELL
     and CHANNEL sent inside the call or refused `"hardwareEvent"`, never
     queued; each refusal; a secret text raising at the caller; our own
     chat not charged twice by the existing hook;
   - `SendBattleNet` and `RegisterBattleNet`: one and several chunks to a
     fake game account, throttle results, reassembly keyed apart from a
     realm sender of the same text, the hook charging foreign
     `SendGameData` traffic, `"unavailable"` without `C_BattleNet`;
   - in-place upgrade from revision 10 with a live SyncSet (part loaded:
     kept; not loaded: closed, reported once) and a queued message waiting
     on a revision 10 driver job; revision 10 after a core-only revision 11
     yields;
   - the driver without SchedulerKit, every existing driver spec run both
     ways: rotation order, bucket waits, the run cap continuing on a later
     frame, backoff reinstatement, held callbacks made before the next
     chunk, nothing armed once idle (no timer, no ticker), a raising run
     reported and retried, `CancelAll`/`Close` while a run is pending, and a
     SchedulerKit loaded after CommKit taking over at the next schedule;
     loading without SchedulerKit succeeds; the Manifest spec shows
     `schedulerKit` optional.
   Client suite (never run here): `SendChat` to a whisper target and to
   SAY from a key binding (hardware event) and from a timer (refused);
   `SendBattleNet` to the player's own game account and the largest chunk
   it accepts; `BN_CHAT_MSG_ADDON` arguments as the tables state.
8. Docs: README (parts, a ChatThrottleLib migration table), `docs/API.md`
   (Parts, `HasPart`, a "Chat and Battle.net" section with the hardware-
   event rule, `constraints.battleNet` still inert and why), `INTERNALS.md`
   (pipe transports, the Battle.net sender key, the part interface, the
   two drivers), the "Loading" and "Queues and priorities" sections
   (six files, SchedulerKit optional, the driver sentence naming both),
   `CHANGELOG.md` 0.6.0, `tests/README.md`, client suite `EXPECTED.md`.
   Shared (text for the maintainer): `docs/MIGRATING_FROM_ACE3.md`
   ChatThrottleLib rows (`SendChatMessage`, `BNSendGameData`) and the
   corrected "shared budget" row; `docs/EMBEDDING.md` generated blocks.
9. Status: implemented 2026-11-15, 0.6.0, revision 11, 591 specs (267 rerun
   the driver without SchedulerKit). Core about 193 KB (213.9 KB before),
   SyncSet 34.4 KB, ChatThrottle 20.1 KB. Until SchedulerKit is found the
   driver looks for it at most once a second. ChatThrottle: chat text limited
   to 255 bytes (`visibleBytes` in Blizzard's chat edit box on all three
   branches), SAY, YELL and CHANNEL sent inside the call or refused with
   `"hardwareEvent"`; Battle.net chunk size 255 bytes and prefix registration
   are conservative defaults the client suite checks. The events + timers +
   comm set holds 605.5 KB against Ace3's 100.5 KB (8.2x before, 6.0x now).

