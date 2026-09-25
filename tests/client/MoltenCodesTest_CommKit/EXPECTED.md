# Expected result: `/mct run commKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package commKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package commKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package commKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. The lines below are Retail's;
[Per flavour](#per-flavour) gives the two Classic clients.

**What this test sends.** The test whispers addon messages to your own
character only. Every message it sends is a `WHISPER` addon message
(`C_ChatInfo.SendAddonMessage`) addressed to the character you are playing,
as `Name-Realm`; the server hands it straight back to you as
`CHAT_MSG_ADDON`. Nothing is ever sent to guild, party, raid, instance chat,
say, yell or a chat channel, and no other player can receive anything. Addon
messages are invisible: nothing appears in the chat frame. A run sends at most
20 addon messages in all, spread over a few seconds, far below any server
limit.

Run it standing idle, out of combat, solo (not in a group), outside any
instance (a capital city is ideal). No test needs combat, a group, an
instance or any action of yours. A normal run finishes within about fifteen
seconds: the round trips wait for the server, and the SyncSet test waits one
second on purpose between its two requests. Keep the game window in the
foreground.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for commKit. Type /mct run commKit to run them; /mct help lists every command.
```

## After `/mct run commKit`

Exactly these lines, in this order (`PASS` is green and `SKIP` yellow in the
client):

```text
MoltenCodes Test: running commKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS commKit.facade: Registry:Get('commKit', 1) is the CommKit facade with API 1, every documented method, MAX_MESSAGE_BYTES 255, MAX_REGISTRATIONS 32, the three priorities and UNBOUNDED
MoltenCodes Test: PASS commKit.facade: the installed CommKit carries the revision of the committed manifest
MoltenCodes Test: PASS commKit.facade: C_ChatInfo has every function CommKit calls, and the client's SendAddonMessageResult and RegisterAddonMessagePrefixResult give the values CommKit falls back to (both enums logged)
MoltenCodes Test: PASS commKit.prefixes: Register has the real client register the prefix, IsAddonMessagePrefixRegistered then answers true, and registering it again answers DuplicatePrefix (answers and prefix count logged)
MoltenCodes Test: SKIP commKit.prefixes: Register returns nil and 'maxPrefixes' when the client's prefix limit is reached -- not probed: reaching the limit would register many prefixes the client cannot unregister; packages/commKit/tests/Lifecycle_spec.lua covers the refusal
MoltenCodes Test: PASS commKit.roundTrip: a short message whispered to the player's own character arrives once through CHAT_MSG_ADDON with its prefix, its text, WHISPER and the player as sender, and completes as sent (round trip logged)
MoltenCodes Test: PASS commKit.roundTrip: an empty message travels as the lone control byte 01 and is delivered as an empty string
MoltenCodes Test: PASS commKit.roundTrip: a 252-byte single chunk holding every byte value Send accepts (01-FF but 0A, 0D and 7C) arrives byte-identical, carried on the wire as 01 plus the payload
MoltenCodes Test: PASS commKit.roundTrip: a 2048-byte message leaves as nine chunks with onProgress after each, 251 bytes apiece, and is delivered once and byte-identical (per-chunk timing, budget and throttles logged)
MoltenCodes Test: PASS commKit.roundTrip: a message cancelled from onProgress after its first chunk sends one abort chunk (05, its stream id, its count) and the receiver drops the stream silently
MoltenCodes Test: PASS commKit.roundTrip: a raw C_ChatInfo.SendAddonMessage of a CommKit single chunk answers Success (result logged), reaches CommKit's registration, and is charged as outside traffic when HookKit is loaded
MoltenCodes Test: PASS commKit.roundTrip: a send cancelled before CommKit's driver ran never reaches the client, and completes once as cancelled
MoltenCodes Test: PASS commKit.syncSet: a SyncSet that whispers a request to the player's own character answers itself with a delivery of all three fields, and a second request a second later with an ack (hashes checked against the documented vectors)
MoltenCodes Test: PASS commKit.scopes: ForAddon with this test addon's name returns one open scope naming the addon, with the default 32 registrations (logout route logged)
MoltenCodes Test: PASS commKit.scopes: CloseAddonScopes on a probe addon cancels its queued send with reason shutdown before any chunk leaves, answers true then false, and the closed scope refuses Send and Register with closed
MoltenCodes Test: SKIP commKit.scopes: at logout this addon's scope is closed and its queued sends are cancelled with reason shutdown -- not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/commKit/tests/LogoutClose_spec.lua proves it
MoltenCodes Test: PASS commKit.allocation: handle and queue queries (GetState, GetBytesSent, GetBytesTotal, GetQueueDepth, GetBudget, scope getters) allocate nothing over 10000 rounds (allocation guard)
MoltenCodes Test: PASS commKit.allocation: 2000 refused sends (a forbidden byte, WHISPER without a target) allocate nothing, queue nothing and are counted (allocation guard)
MoltenCodes Test: SKIP commKit.allocation: receiving and delivering a single chunk allocates no table (allocation guard) -- not measurable here: the client delivers CHAT_MSG_ADDON between frames, where every other listener allocates too; packages/commKit/tests/Allocation_spec.lua guards it
MoltenCodes Test: PASS commKit.errors: Send with an unknown request field names it at the calling line
MoltenCodes Test: PASS commKit.errors: Send with an unknown priority, and Register with a 17-byte prefix or a callback that is not a function, are refused at the calling line
MoltenCodes Test: PASS commKit.errors: a facade method called with a dot and a scope method called on another table are refused at the calling line
MoltenCodes Test: PASS commKit.errors: SetLimits refuses CommKit.UNBOUNDED and an out-of-range value at the calling line and changes nothing
MoltenCodes Test: PASS commKit.errors: Send answers nil and the documented reason for NUL, LF, CR and | in the text, WHISPER without a target, and a text past maxReassemblyBytesPerSender, queueing nothing
MoltenCodes Test: PASS commKit.errors: ForAddon with an empty name and a SyncSet without fields are refused at the calling line
MoltenCodes Test: PASS commKit.secrets: Send refuses a secret prefix, text, distribution, target and priority at the calling line, before comparing them, and queues nothing
MoltenCodes Test: PASS commKit.secrets: Register refuses a secret prefix and SetLimits a secret limit at the calling line, changing nothing
MoltenCodes Test: PASS commKit.secrets: a secret facade receiver, a secret ForAddon name and a secret maxRegistrations are refused at the calling line
MoltenCodes Test: PASS commKit.secrets: SyncSet:Set refuses a secret value and a table holding one at the calling line
MoltenCodes Test: SKIP commKit.secrets: a received message whose prefix, text, channel or sender is secret is dropped and counted in secretsDropped -- not producible solo: the client hands addon messages over as secrets only in restricted contexts such as encounters; packages/commKit/tests/Reassembly_spec.lua covers the drop
MoltenCodes Test: commKit: 26 passed, 0 failed, 4 skipped, 0 timed out (30 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The four `SKIP` lines are expected on every client:

- **The prefix limit.** Reaching the client's limit of registered prefixes
  would take many registrations, and the client cannot unregister a prefix, so
  the probe would change the session for good.
  `packages/commKit/tests/Lifecycle_spec.lua` proves the `"maxPrefixes"`
  refusal.
- **At logout.** An addon scope closes at `PLAYER_LOGOUT`, which ends the
  session before any result could be printed or saved.
  `packages/commKit/tests/LogoutClose_spec.lua` proves it.
- **A delivered chunk.** The client delivers `CHAT_MSG_ADDON` between two
  frames, where every other listener allocates too, so a memory reading around
  it cannot be pinned on CommKit. `packages/commKit/tests/Allocation_spec.lua`
  guards it.
- **A secret received message.** The client hands addon messages over as
  secret values only in restricted contexts such as encounters, which a solo
  run outside an instance never reaches.
  `packages/commKit/tests/Reassembly_spec.lua` proves the drop.

Running it again in the same session prints the same lines.

## Measured on Retail 12.1.0 b69933 (2026-09-25)

The first run gave 25 passed, 1 failed, 4 skipped. The one failure was the
2048-byte test's assumption about listener order, corrected since (see its
row below); every CommKit behaviour it checks held. Facts from that run:

- Whispers to your own character work: the server hands each one back as
  `CHAT_MSG_ADDON` with `WHISPER` and the sender as `Name-Realm` (the realm
  always included). Round trips took about 266 to 281 ms: 280.8 ms for the
  30-byte message, about 266 ms for the empty message, the 252-byte chunk and
  the 2048-byte message.
- The nine chunks of the 2048-byte message all left within 0.3 ms of `Send`
  (the budget had 3905 of 4000 bytes, and 1339 after the last chunk; no
  throttle) and all arrived back between +265.7 and +265.8 ms, in index
  order. CommKit's listener ran before the test's observer on the last chunk's
  event, and the message was delivered in that event.
- The abort test put two messages on the wire (the first chunk and the
  four-byte `05`); the raw `C_ChatInfo.SendAddonMessage` answered the number
  0 (`Success`), and with HookKit loaded was charged as 69 outside bytes.
- The prefix test counted 0 registered prefixes before its `Register` and 1
  after; a second registration answered 1 (`DuplicatePrefix`). LifecycleKit was loaded and lists `commKit` in
  `CLOSES_ADDON_SCOPES`. The SyncSet exchange took four wire messages.

### When the whisper to your own character does not come back

The round-trip tests (`commKit.roundTrip`, except the one that cancels before
anything leaves) and the SyncSet test need the server to hand a whisper to
your own character back as `CHAT_MSG_ADDON`. If the client refuses that
whisper, or never delivers it, those tests end as `SKIP` with the reason
instead of passing or failing. Retail 12.1.0 b69933 delivered them (see
above), so on that client these skips are unexpected. For example:

```text
MoltenCodes Test: SKIP commKit.roundTrip: a short message whispered to the player's own character arrives once through CHAT_MSG_ADDON with its prefix, its text, WHISPER and the player as sender, and completes as sent (round trip logged) -- the client refused the whisper to self: SendAddonMessage answered InvalidChatType
MoltenCodes Test: SKIP commKit.roundTrip: a short message whispered to the player's own character arrives once through CHAT_MSG_ADDON with its prefix, its text, WHISPER and the player as sender, and completes as sent (round trip logged) -- the client accepted the whisper to self but delivered no CHAT_MSG_ADDON within 5 s
MoltenCodes Test: SKIP commKit.syncSet: a SyncSet that whispers a request to the player's own character answers itself with a delivery of all three fields, and a second request a second later with an ack (hashes checked against the documented vectors) -- no CHAT_MSG_ADDON came back for the SyncSet request whispered to self (request state failed; failed means the client refused it)
```

The name after `answered` is the key of `Enum.SendAddonMessageResult` the
client returned. Seven tests are then skipped for that reason and the totals
line reads `19 passed, 0 failed, 11 skipped, 0 timed out (30 tests)`. That is
an answer, not a fault of the run: send it back. Two other run-time skips are
possible: `the client did not accept the whisper to self within 8 s` (every
attempt was throttled), and, for the raw-send test only,
`the client throttled the raw send (AddonMessageThrottle); run it again in a few seconds`.

### On a client without secret values

Four `commKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. `secretwrap` only converts the value
handed to it into a secret and changes no game state. A client without them
prints these four lines instead, and the totals line reads
`22 passed, 0 failed, 8 skipped, 0 timed out (30 tests)`:

```text
MoltenCodes Test: SKIP commKit.secrets: Send refuses a secret prefix, text, distribution, target and priority at the calling line, before comparing them, and queues nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP commKit.secrets: Register refuses a secret prefix and SetLimits a secret limit at the calling line, changing nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP commKit.secrets: a secret facade receiver, a secret ForAddon name and a secret maxRegistrations are refused at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP commKit.secrets: SyncSet:Set refuses a secret value and a table holding one at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

## Per flavour

Every client capability the suite reads is documented for `retail`,
`classic-era` and `classic-mop` alike in the committed apiKit metadata
(`packages/apiKit/metadata/<flavour>/`): the four `C_ChatInfo` functions
CommKit calls and `GetRegisteredAddonMessagePrefixes`, with the same
arguments and the same enum results; `Enum.SendAddonMessageResult` and
`Enum.RegisterAddonMessagePrefixResult` with the same keys and values
(`Success` 0 to `TargetOffline` 12, and `Success` 0 to `MaxPrefixes` 3);
`GetTimePreciseSec`, `UnitName`, `GetNormalizedRealmName`, `UnitInParty`,
`UnitInRaid`, `GetFramerate`, `issecretvalue` and `secretwrap`; and the
events `CHAT_MSG_ADDON`, `CHAT_MSG_ADDON_LOGGED`, `GROUP_ROSTER_UPDATE` and
`PLAYER_ENTERING_WORLD`. `geterrorhandler` and `securecallfunction` are core
globals every client provides. So no test is skipped by flavour, and nothing
the suite reads at load is missing on a Classic client.

### Retail (12.1)

The lines above:
`MoltenCodes Test: commKit: 26 passed, 0 failed, 4 skipped, 0 timed out (30 tests)`,
with the four `SKIP` lines listed under them.

### Classic Era (1.15) and Mists of Pandaria Classic (5.5)

The `running` line (8 suites) and every test line are the same as Retail's,
in the same order, with the same four `SKIP` lines. Two answers only the
running client gives decide the totals:

- **Secret values.** Both Classic flavours document the global functions
  `issecretvalue` and `secretwrap`; the suite reads them at load. With both,
  and secrets made with them, the four `commKit.secrets` tests run and the
  totals line is Retail's:
  `MoltenCodes Test: commKit: 26 passed, 0 failed, 4 skipped, 0 timed out (30 tests)`.
  Without them, the four lines under
  [On a client without secret values](#on-a-client-without-secret-values)
  are `SKIP` and the totals line is
  `MoltenCodes Test: commKit: 22 passed, 0 failed, 8 skipped, 0 timed out (30 tests)`.
  A client that has both but makes no secret with them (`issecretvalue`
  does not report what `secretwrap` returns as secret;
  `Harness:CanMakeSecrets` measures this once at load) skips the same four
  tests with the reason below, and the totals line is again
  `MoltenCodes Test: commKit: 22 passed, 0 failed, 8 skipped, 0 timed out (30 tests)`.

  ```text
  MoltenCodes Test: SKIP commKit.secrets: Send refuses a secret prefix, text, distribution, target and priority at the calling line, before comparing them, and queues nothing -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  MoltenCodes Test: SKIP commKit.secrets: Register refuses a secret prefix and SetLimits a secret limit at the calling line, changing nothing -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  MoltenCodes Test: SKIP commKit.secrets: a secret facade receiver, a secret ForAddon name and a secret maxRegistrations are refused at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  MoltenCodes Test: SKIP commKit.secrets: SyncSet:Set refuses a secret value and a table holding one at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  ```

- **The whisper to your own character.** No Classic client has been measured
  yet. If it refuses or never returns the whisper, the seven tests named under
  [When the whisper to your own character does not come back](#when-the-whisper-to-your-own-character-does-not-come-back)
  end as `SKIP` with the client's answer, and the totals line reads
  `19 passed, 0 failed, 11 skipped, 0 timed out (30 tests)` (with secret
  values; without them `15 passed, 0 failed, 15 skipped`). Send that answer
  back.

## Visible side effects

None. No window opens, nothing is printed besides the harness lines, no
setting is changed, and addon messages never appear in the chat frame. The
whispers go to your own character and are invisible to everyone, you
included.

## What a run leaves behind

Every CommKit scope, SyncSet and EventKit connection a test creates is closed
by its suite's After hook, pass or fail, which also cancels any send still
queued. What stays in the session until `/reload`:

- six addon message prefixes registered with the client by the first run:
  `MCTCommKitReg`, `MCTCommKitShort`, `MCTCommKitLong`, `MCTCommKitAbort`,
  `MCTCommKitRaw` and `MCTCommKitSync`. The client has no way to unregister a
  prefix; later runs reuse the same six, so the count never grows past them;
- this addon's own CommKit scope, `CommKit:ForAddon("MoltenCodesTest_CommKit")`,
  empty, closed at logout;
- one closed scope per run for a probe addon name,
  `MoltenCodesTest_CommKitProbe1`, then `...Probe2` on the next run, and so
  on. No such addon exists;
- CommKit's counters (`GetStatistics`), which count since load, and, when
  HookKit is loaded, the secure hooks CommKit puts on the client's send
  functions the first time it sends. Secure hooks cannot be removed; CommKit
  documents them as session-long (docs/API.md, "Bandwidth").

Nothing is written to a global or a saved variable besides the harness's own
results.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('commKit', 1) is the CommKit facade ...` | The facade the client loaded is API 1 with the eight facade methods, `MAX_MESSAGE_BYTES` 255, `MAX_REGISTRATIONS` 32, `Priority.ALERT`, `NORMAL`, `BULK` and the `UNBOUNDED` table; a scope carries its eleven methods and a send handle its four. The handle belongs to a send cancelled before anything left. |
| `the installed CommKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's. |
| `C_ChatInfo has every function CommKit calls ...` | `C_ChatInfo.IsAddonMessagePrefixRegistered`, `RegisterAddonMessagePrefix`, `SendAddonMessage` and `SendAddonMessageLogged` are functions, and the client's `Enum.SendAddonMessageResult` has `Success` 0, `AddonMessageThrottle` 3 and `ChannelThrottle` 8, and `Enum.RegisterAddonMessagePrefixResult` has `Success` 0, `DuplicatePrefix` 1, `InvalidPrefix` 2 and `MaxPrefixes` 3: the values docs/API.md says CommKit falls back to. Both enums are logged in full. |
| `Register has the real client register the prefix ...` | After `Register("MCTCommKitReg", ...)`, the client's `IsAddonMessagePrefixRegistered` answers `true`, and a second `RegisterAddonMessagePrefix` of the same prefix answers `DuplicatePrefix`. The log gives the answer before (`false` on the first run of a session), the count of registered prefixes before and after (`GetRegisteredAddonMessagePrefixes`) and the second answer. |
| `a short message whispered to the player's own character ...` | A 30-byte message leaves as one addon message and comes back exactly once as `CHAT_MSG_ADDON`, and CommKit delivers it whole with the prefix, the text, `WHISPER` and your own name as sender; the handle reads `sent` with all 30 bytes. The log gives the time until it was sent and until it came back, and the sender as the server wrote it. |
| `an empty message travels as the lone control byte 01 ...` | The one-byte addon message `01` survives the server, and CommKit delivers `""`. |
| `a 252-byte single chunk holding every byte value ...` | Every byte value `Send` accepts, 01 to FF except 0A, 0D and 7C, crosses the server unchanged in one addon message (`01` plus the 252 bytes, 253 on the wire), including the bytes 80 to FF that CommKit's chunk headers rely on. On a difference the log names the first differing byte. |
| `a 2048-byte message leaves as nine chunks ...` | The message leaves as nine addon messages; `onProgress` runs after each with 251, 502, ... 2008, 2048 of 2048 bytes; the wire shows `02`, seven `03` and `04`, every chunk 255 bytes but the last (44), header digits in 80-FF, one stream id, and the chunk count 9; CommKit delivers the message once, byte-identical, only after the last chunk arrived. CommKit's listener and the test's wire observer run on the same `CHAT_MSG_ADDON` event, so the test places the delivery by counting, not by the clock: when each of the first eight chunks was recorded nothing had been delivered, and the delivery sits next to the record of the ninth, just before it when CommKit's listener runs first (as on Retail 12.1.0 b69933) or just after it otherwise. The log says which. The run of 2026-09-25 failed here only because the test compared clock readings and expected the delivery after the observer's last record. The log gives the moment each chunk left and each wire message arrived, the budget before and after, and the counters, `throttled` included (0 expected; a throttle is retried and still passes). |
| `a message cancelled from onProgress after its first chunk ...` | A 600-byte (three-chunk) message cancelled inside its first `onProgress` sends exactly two addon messages: the first chunk and the four-byte abort `05` with the same stream id and count (`80 83`). The receiver opens the stream and drops it silently (`streamsAborted` +1), nothing is delivered and no stream stays open; the handle is `cancelled` with 251 bytes sent. |
| `a raw C_ChatInfo.SendAddonMessage of a CommKit single chunk ...` | After one CommKit send (which installs CommKit's outside-traffic hooks when HookKit is loaded), the test calls `C_ChatInfo.SendAddonMessage` itself with `01` plus text. The client answers `Enum.SendAddonMessageResult.Success` (the type, value and name are logged), CommKit charges it as outside traffic (`outsideMessages` +1, `outsideBytes` + prefix + text + 40) when HookKit is loaded, and CommKit's registration receives both messages. |
| `a send cancelled before CommKit's driver ran ...` | A send cancelled in the same frame it was queued completes once as `cancelled`, and in the following second nothing reaches the wire and no chunk is counted. |
| `a SyncSet that whispers a request to the player's own character ...` | Setting `name` `"a"`, `level` 1 and `talents` `{ b = 2, a = 1 }` gives the documented FNV-1a hashes 3539962124, 2020387990 and 1171038798 on the client's own arithmetic. The request whispered to yourself is answered by the same SyncSet with a delivery: `OnChanged` runs three times with your name as sender and `GetRemote` returns the three values (`level` checked by its SchemaKit schema). 1.3 s later the same request is answered with an ack. Four addon messages in all; `syncRequests` +2, `syncDeliveries` +1, `syncAcknowledgements` +1, `syncRejected` +0. |
| `ForAddon with this test addon's name ...` | `ForAddon("MoltenCodesTest_CommKit")` returns the same open scope every time, naming the addon, with 32 registrations. The log says whether LifecycleKit is loaded and lists `commKit` in `CLOSES_ADDON_SCOPES` (it should). |
| `CloseAddonScopes on a probe addon ...` | `CloseAddonScopes` answers `false` for a name with no scope, `true` for the probe whose send is still queued, then `false`; the send completes `cancelled` with reason `shutdown` before any chunk left; the closed scope answers `nil, "closed"` to `Send` and `Register`, and `ForAddon` still returns it. |
| `handle and queue queries ...` | After a full collection, 10000 rounds of nine queries move `collectgarbage("count")` by at most 1 KB. |
| `2000 refused sends ...` | 1000 sends refused for a `\|` in the text and 1000 for `WHISPER` without a target allocate at most 1 KB in all, queue nothing, and are counted in `refusedForbiddenByte` and `refusedBadDistribution`. |
| `Send with an unknown request field ...` | The refusal names `colour` and this file at the calling line. |
| `Send with an unknown priority, and Register with a 17-byte prefix ...` | Each refusal carries its documented message at the calling line; nothing is registered or queued. |
| `a facade method called with a dot ...` | `CommKit.GetQueueDepth({})` and `scope.GetPendingCount({})` are refused with the receiver messages at the calling line. |
| `SetLimits refuses CommKit.UNBOUNDED ...` | Both refusals name this file at the calling line, and `GetLimits` is unchanged. |
| `Send answers nil and the documented reason ...` | NUL, LF, CR and `\|` answer `forbiddenByte`, `WHISPER` without a target or with `""` answers `badDistribution`, and a text past `maxReassemblyBytesPerSender` answers `tooLarge`; nothing is queued. Every refused request is addressed to your own character, so even a regression could not reach anyone else. |
| `ForAddon with an empty name and a SyncSet without fields ...` | Both refusals name this file at the calling line. |
| `Send refuses a secret prefix, text, distribution, target and priority ...` | A genuine secret in each request field is refused at the calling line before CommKit compares it (the priority with the ordinary priority message), and nothing is queued. |
| `Register refuses a secret prefix and SetLimits a secret limit ...` | Both refusals name this file at the calling line; nothing is registered and the limits are unchanged. |
| `a secret facade receiver, a secret ForAddon name and a secret maxRegistrations ...` | `CommKit.GetQueueDepth(secret)` gets the receiver message, `ForAddon(secret)` the ordinary `addonName must be a non-empty string`, and `CreateScope({ maxRegistrations = secret })` `must not be a secret value`, each at the calling line. |
| `SyncSet:Set refuses a secret value and a table holding one ...` | `Set` refuses a secret with `must not be a secret value` and a table holding one with `must not contain a secret value`, at the calling line; neither field is set. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` other than the four above on Retail
  12.1 (or the whisper-to-self skips described above), or a totals line other
  than `26 passed, 0 failed, 4 skipped, 0 timed out (30 tests)` (on a Classic
  client, other than the totals lines under [Per flavour](#per-flavour)).
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_CommKit`. No test raises an error on
  purpose outside a `pcall`.
- A chat line, a whisper window or a "player not found" system message: the
  test addresses only your own character, so any of these means something
  left that should not have. Send a screenshot.
- `C_ChatInfo has every function ...` failing: the client's enums moved, and
  CommKit's documented fallbacks are wrong for this client.
- `a 252-byte single chunk ...` failing: the server changed a byte; the log
  names the first one. That would break CommKit's chunk headers too.
- `a short message ...` failing on `#deliveries` 2: the client delivered the
  whisper to self twice.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed CommKit carries the revision ...` failing: another enabled
  addon embeds a different CommKit copy.
- A `commKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (both result enums, the prefix
   registration answers and count, the round-trip times and the sender as the
   server wrote it, every chunk's departure and arrival time with its header
   bytes, the budget and throttle counters, the raw `SendAddonMessage`
   result, the SyncSet hashes and counters, the logout route, the measured
   memory deltas, the client's own error messages with their paths) and the
   client facts. Lua shortens a long file path from the left, so a logged
   message may start with `...`; the tests compare only the
   `CommKitSuite.lua:<line>` part. Send it back whatever the result: the
   round-trip timings and the raw send result are the facts the run exists to
   collect.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. Whether you were in a group, an instance or combat, and the list of other
   enabled addons, when a test failed or was skipped at run time.
