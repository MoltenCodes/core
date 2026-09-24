# Expected result: `/mct run signalKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package signalKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for signalKit. Type /mct run signalKit to run them; /mct help lists every command.
```

## After `/mct run signalKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green in
the client). The three allocation tests each run a full garbage collection
first, which can make the client stutter for a moment:

```text
MoltenCodes Test: running signalKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS signalKit.facade: Registry:Get('signalKit', 1) is the SignalKit facade with API 1, every documented method and UNBOUNDED
MoltenCodes Test: PASS signalKit.facade: the installed SignalKit carries the revision of the committed manifest
MoltenCodes Test: PASS signalKit.dispatch: listeners run in connection order, and one function connected twice runs twice
MoltenCodes Test: PASS signalKit.dispatch: Fire forwards every argument, explicit nils included
MoltenCodes Test: PASS signalKit.dispatch: a listener connected during Fire is not called by that Fire, only by the next
MoltenCodes Test: PASS signalKit.dispatch: a listener disconnected by an earlier listener during Fire is skipped
MoltenCodes Test: PASS signalKit.dispatch: a nested Fire sees the listener set as it is when the nested call begins
MoltenCodes Test: PASS signalKit.dispatch: DisconnectAll during Fire stops every listener that has not run and returns the count
MoltenCodes Test: PASS signalKit.dispatch: Once disconnects before its callback, so a nested Fire from it does not run it again
MoltenCodes Test: PASS signalKit.dispatch: a listener error reaches the Fire caller, stops that dispatch, and the signal stays usable
MoltenCodes Test: PASS signalKit.dispatch: Disconnect answers true once and false after, and IsConnected follows it
MoltenCodes Test: PASS signalKit.hooks: onFirst runs when the live listener count goes from 0 to 1 and onLast when it goes back to 0
MoltenCodes Test: PASS signalKit.hooks: DisconnectAll runs onLast once however many listeners go, and not at all when none is connected
MoltenCodes Test: PASS signalKit.hooks: a Once listener that is the last one runs onLast during Fire, before its own callback
MoltenCodes Test: PASS signalKit.journal: GetGeneration counts every Fire, moves before listeners run, and ignores connects
MoltenCodes Test: PASS signalKit.journal: a journal keeps its last capacity firings, oldest to newest, with generations and explicit nils
MoltenCodes Test: PASS signalKit.journal: a journal firing one argument over maxJournalArguments is refused at the calling line and records nothing
MoltenCodes Test: PASS signalKit.allocation: Fire with three listeners connected allocates nothing over 10000 firings (allocation guard)
MoltenCodes Test: PASS signalKit.allocation: a journal Fire into a ring every slot of which has been used allocates nothing over 10000 firings
MoltenCodes Test: PASS signalKit.allocation: History walks over a full 16-entry journal allocate nothing over 2000 walks
MoltenCodes Test: PASS signalKit.bus: a subscriber that subscribes before its topic is declared receives publishes once it is
MoltenCodes Test: PASS signalKit.bus: Publish of an undeclared topic is refused at the calling line and delivers nothing
MoltenCodes Test: PASS signalKit.bus: Publish with the wrong argument count is refused at the calling line; the right count with a nil is delivered
MoltenCodes Test: PASS signalKit.bus: a validator's refusal reason is raised at the calling line and nothing is delivered
MoltenCodes Test: PASS signalKit.bus: a validator that raises becomes a refusal at the publishing line and nothing is delivered
MoltenCodes Test: PASS signalKit.bus: a failing bus listener neither aborts the publisher nor stops the listeners behind it
MoltenCodes Test: PASS signalKit.bus: a failing bus listener's error reaches the client's error handler once, naming SignalKitSuite.lua
MoltenCodes Test: PASS signalKit.bus: ForAddon with this test addon's name is the bus Bus returns for that name, on every call
MoltenCodes Test: PASS signalKit.bus: a bus scope's DisconnectAll ends every subscription it owns, and Close is terminal
MoltenCodes Test: PASS signalKit.errors: SignalKit.Connect called without a signal names SignalKitSuite.lua at the calling line
MoltenCodes Test: PASS signalKit.errors: Connect with a callback that is not a function names SignalKitSuite.lua at the calling line
MoltenCodes Test: PASS signalKit.secrets: a secret value published on a counted bus topic reaches the subscriber still secret
MoltenCodes Test: PASS signalKit.secrets: a secret topic name is refused at the calling line before SignalKit compares it
MoltenCodes Test: PASS signalKit.secrets: a journal records a secret argument and History hands it back still secret
MoltenCodes Test: PASS signalKit.secrets: a validator that answers with a secret instead of true refuses the publish
MoltenCodes Test: signalKit: 35 passed, 0 failed, 0 skipped, 0 timed out (35 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines. Every connection a
test makes is disconnected by its suite's After hook, pass or fail. Two named
buses stay in the session until `/reload`, because SignalKit never frees a
bus: `mctSignalKitProbe` and `MoltenCodesTest_SignalKit` (this addon's
`ForAddon` bus, which LifecycleKit closes at logout). Each run adds one topic,
`Early<n>`, to the probe bus; everything else is declared again with the same
policy, which SignalKit accepts.

### On a client without secret values

The four `signalKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these four lines instead, and the totals
line reads `31 passed, 0 failed, 4 skipped, 0 timed out (35 tests)`:

```text
MoltenCodes Test: SKIP signalKit.secrets: a secret value published on a counted bus topic reaches the subscriber still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP signalKit.secrets: a secret topic name is refused at the calling line before SignalKit compares it -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP signalKit.secrets: a journal records a secret argument and History hands it back still secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP signalKit.secrets: a validator that answers with a secret instead of true refuses the publish -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('signalKit', 1) is the SignalKit facade ...` | The facade the client loaded is API 1 and carries `New`, `NewJournal`, `Bus`, `ForAddon`, `CloseAddonBus`, `SetLimits`, `GetLimits` and the `UNBOUNDED` sentinel. |
| `the installed SignalKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `listeners run in connection order ...` | Dispatch order is connection order, and each connection of one function is its own listener. |
| `Fire forwards every argument, explicit nils included` | `select("#", ...)` inside a listener is 4 for `Fire(1, nil, "x", nil)`. |
| `a listener connected during Fire ...` | A listener added mid-dispatch is beyond the captured length: not called now, called next time. |
| `a listener disconnected by an earlier listener ...` | A disconnect is visible at once to the dispatch in progress. |
| `a nested Fire sees the listener set ...` | A nested `Fire` captures the set as it is when it begins (sees the added listener, skips the removed one); the outer one keeps its own boundary. |
| `DisconnectAll during Fire ...` | `DisconnectAll` from a listener stops the rest of the dispatch and returns 3. |
| `Once disconnects before its callback ...` | `IsConnected()` is `false` inside a `Once` callback, and its own nested `Fire` does not run it again. |
| `a listener error reaches the Fire caller ...` | A raw signal's listener error propagates with this file's position, stops that dispatch, and the signal works afterwards. |
| `Disconnect answers true once and false after ...` | `Disconnect` is idempotent and reports the transition; `IsConnected` follows it. |
| `onFirst runs when ...` | The hooks fire on the 0→1 and 1→0 transitions only, receive the signal, and do not move the generation. |
| `DisconnectAll runs onLast once ...` | One `onLast` for three listeners, none for an empty signal. |
| `a Once listener that is the last one ...` | `onLast` runs during `Fire`, before the `Once` callback. |
| `GetGeneration counts every Fire ...` | The counter starts at 0, ignores connects, is already moved when a listener reads it, and counts a firing whose listener raised. |
| `a journal keeps its last capacity firings ...` | A 3-slot ring after four firings walks the last three oldest to newest, with the right generation and argument count (explicit `nil`s included). |
| `a journal firing one argument over maxJournalArguments ...` | The refusal names this file at the calling line and the session's limit, and nothing is recorded, delivered or counted. |
| `Fire with three listeners connected allocates nothing ...` | After a full collection, 10000 firings move `collectgarbage("count")` by at most 1 KB on the client's own collector. |
| `a journal Fire into a ring ...` | The same for 10000 journal firings once every slot has been used. |
| `History walks over a full 16-entry journal ...` | 2000 complete walks allocate at most 1 KB and visit every entry. |
| `a subscriber that subscribes before its topic is declared ...` | Load order does not matter: a subscription to a topic declared later receives its publishes. |
| `Publish of an undeclared topic ...` | A declared-topics bus refuses an undeclared publish at this file's calling line, and the subscriber gets nothing. |
| `Publish with the wrong argument count ...` | A counted topic refuses one argument for two at the calling line; `Publish(topic, 1, nil)` counts as two and is delivered. |
| `a validator's refusal reason ...` | A validator's `false, reason` becomes the error at the calling line; an accepted value is delivered. |
| `a validator that raises ...` | A raising validator becomes a `validator ... failed:` refusal at the publishing line, not an error from the validator's own line. |
| `a failing bus listener neither aborts ...` | Through the client's real `securecallfunction`, the listener after the failing one still runs and `Publish` returns to the publisher. |
| `a failing bus listener's error reaches the client's error handler ...` | The failure reaches the client's error handler exactly once, with this file and the failing line, and no error window opens. |
| `ForAddon with this test addon's name ...` | `ForAddon("MoltenCodesTest_SignalKit")` returns the same bus every time, and it is the bus `Bus` returns for that name. |
| `a bus scope's DisconnectAll ...` | A scope ends both its subscriptions in one call, and `Close` answers `true` then `false`. |
| `SignalKit.Connect called without a signal ...` | The receiver error names this file at the calling line, as the client names it. |
| `Connect with a callback that is not a function ...` | The callback error names this file at the calling line. |
| `a secret value published on a counted bus topic ...` | A genuine secret passes the argument count and securecallfunction and arrives still secret. |
| `a secret topic name is refused ...` | A secret topic is refused at the calling line with a message that contains no secret. |
| `a journal records a secret argument ...` | The ring stores a secret untouched and `History()` hands it back still secret. |
| `a validator that answers with a secret ...` | A secret verdict is not an acceptance: the publish is refused and nothing is delivered. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals line
  other than `35 passed, 0 failed, 0 skipped, 0 timed out (35 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_SignalKit`. The two bus-isolation
  tests raise `mctSignalKit deliberate listener failure` on purpose, but it
  must reach only the test's own collector.
- `a failing bus listener's error reaches the client's error handler ...`
  failing with "the client's error handler could not be replaced": an
  error-capturing addon (BugGrabber, usually with BugSack) keeps the handler,
  and the deliberate failure went to it. Disable it and run again; the test
  is reporting the session truthfully.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed SignalKit carries the revision ...` failing: another enabled
  addon embeds a different SignalKit copy.
- A `signalKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the client's own error
   messages with their paths, the three measured memory deltas, whether
   `securecallfunction` was present, the message the error handler received)
   and the client facts. Lua shortens a long file path from the left, so a
   logged message may start with `...`; the tests compare only the
   `SignalKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
