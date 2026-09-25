# Expected result: `/mct run eventKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package eventKit`
for Retail, adding `--flavour-dir _classic_era_` for Classic Era or
`--flavour-dir _classic_` for Mists of Pandaria Classic, and nothing else from
the MoltenCodes framework enabled in the client.

Run it standing idle, out of combat, solo, outside any instance (a capital
city is ideal), with the character neither away (AFK) nor busy (DND). No test
needs combat, a group or an instance: every event is one the test raises itself
through a harmless call, or one the server sends in reply to such a call.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for eventKit. Type /mct run eventKit to run them; /mct help lists every command.
```

## After `/mct run eventKit`

Within about five seconds, exactly these lines, in this order (`PASS` is green
and `SKIP` yellow in the client):

```text
MoltenCodes Test: running eventKit: 10 suites. Results follow when every test has finished.
MoltenCodes Test: PASS eventKit.facade: Registry:Get('eventKit', 1) is the EventKit facade with API 1, every documented method and UNBOUNDED
MoltenCodes Test: PASS eventKit.facade: the installed EventKit carries the revision of the committed manifest
MoltenCodes Test: PASS eventKit.dispatch: a C_CVar.SetCVar change reaches two Connect listeners in connection order with the CVar name and the new value
MoltenCodes Test: PASS eventKit.dispatch: a Once listener runs for the first CVAR_UPDATE only and is already disconnected inside its callback
MoltenCodes Test: PASS eventKit.dispatch: TIME_PLAYED_MSG, the server's reply to RequestTimePlayed, reaches a Once listener with two numbers
MoltenCodes Test: PASS eventKit.isolation: a raising listener is reported once to the client's error handler, naming EventKitSuite.lua, and the next listener still runs
MoltenCodes Test: PASS eventKit.registration: the first Connect registers CVAR_UPDATE on one frame, a second listener shares it, and the last Disconnect unregisters it
MoltenCodes Test: PASS eventKit.registration: ConnectUnit with player registers PLAYER_FLAGS_CHANGED filtered to player, and Disconnect unregisters it
MoltenCodes Test: PASS eventKit.units: toggling Do Not Disturb delivers PLAYER_FLAGS_CHANGED to a player ConnectUnit listener and not to a party1 one
MoltenCodes Test: PASS eventKit.scopes: a scope's DisconnectAll ends its connections before the next event, and Close is terminal
MoltenCodes Test: PASS eventKit.scopes: a closed scope refuses Connect at the calling line
MoltenCodes Test: PASS eventKit.scopes: ForAddon with this test addon's name returns one open scope that names the addon
MoltenCodes Test: PASS eventKit.coalesce: Coalesce delivers two CVar changes inside one 0.25-second interval as one callback keyed by event name
MoltenCodes Test: PASS eventKit.coalesce: Derive recomputes after a CVar change and OnChange reports the new and the previous value
MoltenCodes Test: PASS eventKit.errors: Connect with an event name that is not a string names EventKitSuite.lua at the calling line
MoltenCodes Test: PASS eventKit.errors: ConnectUnit with three distinct unit tokens is refused at the calling line
MoltenCodes Test: PASS eventKit.errors: Connect to an event name the client does not know is refused on every attempt, at the calling line where the client can tell, and caches nothing
MoltenCodes Test: PASS eventKit.combatLog: ConnectCombatLog does what docs/API.md documents for the combat-log reader this client has (every fact is logged)
MoltenCodes Test: SKIP eventKit.allocation: dispatch allocates nothing per event (allocation guard) -- not measurable here without side effects: EventKit has no public dispatch entry point, and no harmless event can be raised thousands of times without the client's own handlers allocating; packages/eventKit/tests guards it
MoltenCodes Test: eventKit: 18 passed, 0 failed, 1 skipped, 0 timed out (19 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The one `SKIP` is expected on every client: EventKit dispatches only from the
`OnEvent` handler the client calls, and the only way to raise a harmless event
thousands of times (changing a CVar in a loop) also runs every Blizzard handler
of that event, whose allocations the measurement could not tell apart from
EventKit's. The Busted specs under `packages/eventKit/tests/` guard dispatch
allocation instead.

Running it again in the same session prints the same lines.

## Visible side effects

Interleaved with the harness lines, the client itself prints:

- two lines from `RequestTimePlayed`, exactly what `/played` prints, for
  example `Total time played: 12 days, 3 hours, 4 minutes, 5 seconds` and
  `Time played this level: 1 day, ...`;
- two system lines from the Do Not Disturb toggle, the same as typing `/dnd`
  twice, in enUS for example `You are now Busy: Do not Disturb` and then
  `You are no longer marked Busy.` While the flag is on, for about a second,
  other players see `<Busy>` on the character.

The `chatBubbles` CVar (Interface options, chat bubbles) is flipped and put
back several times within the run; bubbles said during that second may not
show. The `combatLog` test calls `C_CombatLogInternal.GetCurrentEventInfo()`
under `pcall` to learn whether addon code may; if the client forbids it, it may
show its "an addon has been blocked from an action" warning naming
`MoltenCodesTest_EventKit`. That is the answer the test is after, not a fault:
say so when sending the results back.

## What a run leaves behind

Every connection, scope and `Coalesce` or `Derive` handle a test creates is
released by its suite's After hook, pass or fail, and only then are
`chatBubbles` and the Do Not Disturb flag put back to what they were before the
test. The client's error handler is replaced only while the isolation test
waits for its deliberate failure, and put back at once. This addon's own
EventKit scope (`EventKit:ForAddon("MoltenCodesTest_EventKit")`) stays in the
session, empty, and closes at logout. EventKit keeps the Frames it created for
reuse, because the client never frees a Frame.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('eventKit', 1) is the EventKit facade ...` | The facade the client loaded is API 1 and carries `Connect`, `Once`, `ConnectUnit`, `OnceUnit`, `ConnectCombatLog`, `IsCombatLogAvailable`, `CreateScope`, `ForAddon`, `CloseAddonScopes`, `Coalesce`, `Derive`, `SetLimits`, `GetLimits` and the `UNBOUNDED` sentinel. |
| `the installed EventKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `a C_CVar.SetCVar change reaches two Connect listeners ...` | A CVAR_UPDATE the client raises reaches both listeners in connection order, with the event name first, then the CVar name and the value that was written. The log says whether it arrived before `SetCVar` returned. |
| `a Once listener runs for the first CVAR_UPDATE only ...` | Over two real CVar changes, a `Once` listener runs once and `IsConnected()` is already `false` inside its callback. |
| `TIME_PLAYED_MSG, the server's reply ...` | An event the server sends reaches a `Once` listener with two numbers, total time not below the time at this level, within five seconds. |
| `a raising listener is reported once ...` | Through the client's real `securecallfunction`, the listener after the failing one still runs, and the failure reaches the client's error handler exactly once, naming this file at the failing line; no error window opens. |
| `the first Connect registers CVAR_UPDATE on one frame ...` | `GetFramesRegisteredForEvent` lists one more frame after the first `Connect`, the same one after the second, and none after the last `Disconnect`, where `IsEventRegistered` turns `false`. |
| `ConnectUnit with player registers PLAYER_FLAGS_CHANGED ...` | The client's own `IsEventRegistered` answers `true, "player"` for EventKit's unit frame, and the registration is gone after `Disconnect`. |
| `toggling Do Not Disturb delivers PLAYER_FLAGS_CHANGED ...` | The client's unit filter delivers the event to the `"player"` listener with `"player"` as its unit, and not to a `"party1"` listener of the same event. |
| `a scope's DisconnectAll ends its connections ...` | After `DisconnectAll` returns 2, a real CVar change reaches a plain listener and neither scoped one; `Close` answers `true`, then `false`. |
| `a closed scope refuses Connect at the calling line` | The closed-scope error names this file at the calling line. |
| `ForAddon with this test addon's name ...` | `ForAddon` returns the same open scope every time, naming this addon, and `DisconnectAll` empties it. |
| `Coalesce delivers two CVar changes ...` | Two real events inside one interval produce one callback holding `CVAR_UPDATE` alone, and no second callback follows within half a second. |
| `Derive recomputes after a CVar change ...` | The derived value follows the CVar within three seconds and `OnChange` reports the new and the previous value once. |
| `Connect with an event name that is not a string ...` | The argument error names this file at the calling line. |
| `ConnectUnit with three distinct unit tokens ...` | The two-slot refusal names this file at the calling line, with the documented message. |
| `Connect to an event name the client does not know ...` | `MOLTENCODES_TEST_NO_SUCH_EVENT` is refused on two attempts in a row, so EventKit kept nothing from the first, and a real event still connects afterwards. Where the client has `C_EventUtils.IsEventValid` (Retail 12.1 does, and the Classic Era and Mists Classic metadata document it), each refusal is EventKit's own, `EventKit:Connect eventName "MOLTENCODES_TEST_NO_SUCH_EVENT" is not an event this client knows`, naming `EventKitSuite.lua` at the calling line; without the function it is the client's `RegisterEvent` refusal, which names no caller line. The log holds what `IsEventValid` answers and each message. |
| `ConnectCombatLog does what docs/API.md documents ...` | See below. |

### The combat-log facts

The `combatLog` test logs, before it asserts anything:

- whether the global `CombatLogGetCurrentEventInfo` exists;
- whether `C_CombatLog.GetCurrentEventInfo`, `C_CombatLogInternal.GetCurrentEventInfo`
  and `C_CombatLogSecure.GetCurrentEventInfo` exist;
- what calling `C_CombatLogInternal.GetCurrentEventInfo()` from addon code does
  (how many values it returned, or the error it raised);
- what `C_CombatLog.IsCombatLogRestricted()` answers;
- whether EventKit finds a reader (the global, or `C_CombatLog.GetCurrentEventInfo`);
- what `EventKit:IsCombatLogAvailable()` answers, which must agree with the
  line before.

It then calls `EventKit:ConnectCombatLog("*", ...)` twice and passes when the
outcome matches the documented contract for the facts it found:

- **No reader** (measured on Retail 12.1.0 on 2026-09-24): `IsCombatLogAvailable()`
  answers `false`, and both calls raise, naming `EventKitSuite.lua` at the
  calling line,
  `EventKit:ConnectCombatLog the combat log is not available to addons on this client (no CombatLogGetCurrentEventInfo reader); check EventKit:IsCombatLogAvailable() first`;
  no frame is registered for `COMBAT_LOG_EVENT_UNFILTERED` afterwards.
- **A reader**: `IsCombatLogAvailable()` answers `true`, and each call either connects (and disconnects cleanly) or raises
  the client's refusal of the registration; either way nothing stays registered.

The test also logs the flavour the harness names. On Classic Era and Mists
Classic (`classic-era`, `classic-mop`) it additionally requires the reader
path: EventKit's docs/API.md ("Cost") says those clients document
`C_CombatLog.GetCurrentEventInfo`, which EventKit reads when the global is
absent, so finding no reader there fails the test.

The log is the answer to the open question of which reader Retail 12.1 gives
addon code, so send it back whatever the result.

## Per flavour

Every client capability the suites use is documented for all three clients in
`packages/apiKit/metadata/<flavour>/`: `C_CVar.GetCVar` and `C_CVar.SetCVar`,
`RequestTimePlayed`, `UnitIsDND`, `UnitIsAFK`, `C_ChatInfo.SendChatMessage`,
`C_EventUtils.IsEventValid`, `C_CombatLog.IsCombatLogRestricted`,
`C_CombatLogInternal.GetCurrentEventInfo`, `Frame:IsEventRegistered` (the same
`isRegistered, units` returns), and the events `CVAR_UPDATE` (`eventName,
value`), `TIME_PLAYED_MSG` (two numbers), `PLAYER_FLAGS_CHANGED` (a unit
token) and `COMBAT_LOG_EVENT_UNFILTERED`, with the same payloads. The core
globals `CreateFrame`, `GetFramesRegisteredForEvent`, `securecallfunction`,
`seterrorhandler` and `geterrorhandler` are not in that documentation and are
taken to be present on all three; the isolation test passes on either of
EventKit's documented paths (`securecallfunction` or `xpcall`), and a client
without `GetFramesRegisteredForEvent` would print the two registration tests
as SKIP with the reason above. The `chatBubbles` CVar is taken to exist on
every client; if it did not, the CVar tests would fail with
"C_CVar.GetCVar is missing or does not know the CVar chatBubbles".

The one difference is the combat log: the Classic clients document
`C_CombatLog.GetCurrentEventInfo`, so the `combatLog` test there takes the
"a reader" path described above instead of Retail's "no reader" path. Its
chat line is the same `PASS`.

| Client | Totals line | SKIP lines |
|---|---|---|
| Retail (`_retail_`) | `MoltenCodes Test: eventKit: 18 passed, 0 failed, 1 skipped, 0 timed out (19 tests)` | the allocation line above |
| Classic Era (`_classic_era_`) | `MoltenCodes Test: eventKit: 18 passed, 0 failed, 1 skipped, 0 timed out (19 tests)` | same as Retail |
| Mists of Pandaria Classic (`_classic_`) | `MoltenCodes Test: eventKit: 18 passed, 0 failed, 1 skipped, 0 timed out (19 tests)` | same as Retail |

No EventKit test needs combat, a group, a second character or another addon,
so the package has no combat suites. The combat-log reader on the Classic
clients is connected and disconnected, but no combat-log event is awaited:
that would need combat nearby.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, any `SKIP` other than the allocation one, or a
  totals line other than `18 passed, 0 failed, 1 skipped, 0 timed out (19 tests)`,
  on any of the three clients.
- No login line, or `Expected.lua is missing`: the harness or the installer did
  not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`, `MoltenCodesTest`
  or `MoltenCodesTest_EventKit`. The isolation test raises
  `mctEventKit deliberate listener failure` on purpose, but it must reach only
  the test's own collector.
- The isolation test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack) keeps
  the handler, and the deliberate failure went to it. Disable it and run again.
- The tests that change `chatBubbles` failing together (the first dispatch
  test with "no CVAR_UPDATE naming chatBubbles ...", the others with `expected
  boolean false to be boolean true` at a wait): the client did not raise
  CVAR_UPDATE for that CVar, or named it differently. Their logs list what
  `SetCVar` answered and how many other CVAR_UPDATE events arrived.
- The units test failing: the log says whether the character was already busy,
  and how many deliveries each listener saw. "the character is away (AFK)"
  means it ran while AFK; clear it and run again.
- A `registration` test reported as `SKIP` with "the client has no
  GetFramesRegisteredForEvent": the client removed that function.
- `chatBubbles` or the Do Not Disturb flag not back to what it was after the run.
- `the installed EventKit carries the revision ...` failing: another enabled
  addon embeds a different EventKit copy.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs and any blocked-action warning.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (the combat-log facts, the
   CVAR_UPDATE payload and whether it arrived during `SetCVar`, the time-played
   payload, `IsEventRegistered`'s answer, the client's messages with their
   paths, whether `securecallfunction` was present, the message the error
   handler received) and the client facts. Lua shortens a long file path from
   the left, so a logged message may start with `...`; the tests compare only
   the `EventKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
