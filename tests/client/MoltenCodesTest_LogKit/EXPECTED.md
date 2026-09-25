# Expected result: `/mct run logKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package logKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for logKit. Type /mct run logKit to run them; /mct help lists every command.
```

## After `/mct run logKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green in
the client). The three allocation tests each run a full garbage collection
first, so the client may stutter for a moment. One line of the run is not the
harness's: the `ChatSink()` test writes
`[MoltenCodesTest_LogKit] warn: LogKit test: this line reached the chat frame through ChatSink()`
(the word `warn` in orange) to the chat frame on purpose, before the harness
prints its results:

```text
MoltenCodes Test: running logKit: 11 suites. Results follow when every test has finished.
MoltenCodes Test: PASS logKit.facade: Registry:Get('logKit', 1) is the LogKit facade with API 1, its eleven methods, the read-only LEVELS trace 1 to off 6, DEFAULT_LEVEL 'warn', MAX_FORMAT_ARGUMENTS 16, SECRET_PLACEHOLDER '<secret>' and UNBOUNDED
MoltenCodes Test: PASS logKit.facade: the installed LogKit carries the revision of the committed manifest
MoltenCodes Test: PASS logKit.facade: the client has GetTimePreciseSec, geterrorhandler, SlashCmdList and a default chat frame with AddMessage, and Registry finds CommandKit API 1 and SettingsKit API 1 for the optional integrations
MoltenCodes Test: PASS logKit.levels: an addon override beats the global level, which beats the default warn, and GetLevel names the source of each
MoltenCodes Test: PASS logKit.levels: a Debug call below warn reads neither its message nor its arguments: a non-string message does not raise, a __tostring argument never runs, and the SignalKit journal's generation does not move
MoltenCodes Test: PASS logKit.levels: once debug is on, the same Debug call formats once through the client's string.format, runs __tostring once and reaches a table sink and the journal
MoltenCodes Test: PASS logKit.levels: the client's string.format gives positional %2$s before %1$s, %5.1f, %x and %q, nil and booleans format as in Lua 5.2, and a bare '100% of the bars' is delivered unformatted
MoltenCodes Test: PASS logKit.levels: Log takes a level name or a LEVELS value, IsEnabled answers what the level methods do, and SetLevel('off') silences error
MoltenCodes Test: PASS logKit.journal: History walks this addon's entries oldest to newest with GetTimePreciseSec times taken between the calls, filters by addon and minimum level, and skips a disabled call
MoltenCodes Test: PASS logKit.journal: LogKit's journal is a SignalKit journal: its newest entry holds the addon, the level number, the message and the same time History yields, and each delivered message moves its generation by one
MoltenCodes Test: PASS logKit.sinks: a ChatSink bound to a hidden ScrollingMessageFrame receives '[addon] warn: message' with the orange warn escape and a red error line, nothing below the level, and the real chat frame's lines are unchanged
MoltenCodes Test: PASS logKit.sinks: ChatSink() without a frame reads DEFAULT_CHAT_FRAME when it writes, so its line lands in the real chat frame (one visible line)
MoltenCodes Test: PASS logKit.sinks: sinks run in registration order with one shared record, a table sink's Write is looked up at every message, and RemoveSink stops delivery at once and answers false for an unknown handle
MoltenCodes Test: PASS logKit.reported: a sink that raises is reported once through the client's error handler naming LogKitSuite.lua at the raising line, the next sink still runs and the logging caller continues
MoltenCodes Test: PASS logKit.reported: a table a sink raises reaches the client's error handler as that same table
MoltenCodes Test: PASS logKit.reported: a %d given a string is reported through the client's error handler as a format failure for this addon, and the message reaches neither the journal nor any sink
MoltenCodes Test: PASS logKit.command: RegisterCommand registers /log through CommandKit in the client's SlashCmdList, and a second call answers true without registering again
MoltenCodes Test: PASS logKit.command: SlashCmdList /log '<addon> Debug' and '<addon> default' set and clear this addon's override, the level read without case, and print the level to LogKit's command sink
MoltenCodes Test: PASS logKit.command: /log * info and /log * DEFAULT set and clear the global level; an unknown level, a missing level and an empty /log print their refusal or the usage and change nothing
MoltenCodes Test: PASS logKit.command: /log for an addon without a logger sets its level without creating the logger, /log show lists the global level then every logger sorted by name, and /log show <addon> names one
MoltenCodes Test: PASS logKit.bindLevels: BindLevels over an in-memory SettingsKit database restores this addon's saved level and the '*' global level, ignores an unknown level, and writes every change to the saved table until BindLevels(nil)
MoltenCodes Test: PASS logKit.bindLevels: a write the database refuses (a logLevels map of max 2 already full) is reported through the client's error handler and the level still applies for the session
MoltenCodes Test: PASS logKit.bindLevels: BindLevels refuses a plain table and a database without global.logLevels at the calling line
MoltenCodes Test: PASS logKit.limits: maxMessageLength 16 cuts a message of two-byte characters to 12 bytes plus '...' on a character boundary, and the limit is put back afterwards
MoltenCodes Test: PASS logKit.limits: maxLoggers and maxSinks lowered to 1 refuse a new logger with 'capped' and a new sink with 'full', while existing loggers are still returned
MoltenCodes Test: PASS logKit.allocation: Trace, Debug and Info below warn with three format arguments, and Log with a LEVELS value, allocate nothing over 5000 calls each
MoltenCodes Test: PASS logKit.allocation: an enabled bare Warn delivered to a table sink and the journal allocates nothing over 2000 calls
MoltenCodes Test: PASS logKit.allocation: an enabled Warn formatting '%d of %s' to text the client already interned allocates nothing over 2000 calls with a table sink
MoltenCodes Test: PASS logKit.errors: ForAddon with an empty name and GetLimits called with a dot name LogKitSuite.lua at the calling line
MoltenCodes Test: PASS logKit.errors: an enabled Warn with a number as message, 17 format arguments, Log at off and SetLevel('loud') are each refused at the calling line
MoltenCodes Test: PASS logKit.errors: a logger method called on UIParent, AddSink and ChatSink given UIParent, and a write to LEVELS are each refused at the calling line
MoltenCodes Test: PASS logKit.errors: SetLimits with UNBOUNDED for journalCapacity, a capacity above SignalKit's maxJournalCapacity and maxMessageLength 8 is refused at the calling line and the limits stay as they were
MoltenCodes Test: PASS logKit.secrets: a secret number and a secret string as %s arguments reach a table sink, the journal and a hidden ChatSink as '<secret>', and neither the call nor the error handler sees a client error
MoltenCodes Test: PASS logKit.secrets: a secret number given to %d is replaced before string.format, so the format failure is reported through the error handler instead of a client error, and nothing is delivered
MoltenCodes Test: PASS logKit.secrets: a secret message raises at the calling line when the level is enabled and is not read at all when it is disabled
MoltenCodes Test: PASS logKit.secrets: a secret level, addon name, History filter, sink, chat frame and SetLimits value are refused at the calling line, RemoveSink answers false for a secret, and nothing changes
MoltenCodes Test: PASS logKit.secrets: a secret string a sink raises reaches the client's error handler still secret, and the next sink still runs
MoltenCodes Test: logKit: 37 passed, 0 failed, 0 skipped, 0 timed out (37 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines, and the chat frame
gets the one `ChatSink()` line again.

## Visible side effects

One chat line per run, described above. Every other sink the tests add writes
to a table or to a hidden `ScrollingMessageFrame` that is never shown, and the
output of `/log` goes to a CommandKit capture sink for the length of each test.
Nothing is drawn, no sound plays, no client setting (CVar) changes and nothing
is sent to the server.

## What stays for the session

Every test starts from the session's LogKit state and its After hook puts it
back, pass or fail: the sinks it added are removed, the global level and the
four limits are set to what they were, the levels of this addon's two loggers
and of the typed-only name `MoltenCodesTest_LogKit.Typed` are put back, and the
`/log` scope's output goes back to the chat frame. A SettingsKit binding
another addon held is unbound for each test, so no level a test sets is written
to that addon's saved variables, and bound again afterwards. What LogKit keeps,
because it never removes it:

- the two loggers `MoltenCodesTest_LogKit` and `MoltenCodesTest_LogKit.Other`,
  two of the 256 `maxLoggers`, created when the addon loads;
- the `/log` command, registered once per session by `RegisterCommand`; typing
  `/log` afterwards works as docs/API.md describes;
- the journal entries the tests logged: the two enabled allocation tests
  deliver 4002 messages, so the 1024-entry journal then holds this suite's
  lines only;
- one hidden `ScrollingMessageFrame` (the client never frees a Frame);
- in SettingsKit's package state, the small database each of the three
  BindLevels tests opens over a scratch global named
  `MoltenCodesTest_LogKitScratch_<n>`; the globals themselves are removed, and
  they were never saved variables, so nothing reaches the disk.

### On a client without secret values

The five `logKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead, and the totals
line reads `32 passed, 0 failed, 5 skipped, 0 timed out (37 tests)`:

```text
MoltenCodes Test: SKIP logKit.secrets: a secret number and a secret string as %s arguments reach a table sink, the journal and a hidden ChatSink as '<secret>', and neither the call nor the error handler sees a client error -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP logKit.secrets: a secret number given to %d is replaced before string.format, so the format failure is reported through the error handler instead of a client error, and nothing is delivered -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP logKit.secrets: a secret message raises at the calling line when the level is enabled and is not read at all when it is disabled -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP logKit.secrets: a secret level, addon name, History filter, sink, chat frame and SetLimits value are refused at the calling line, RemoveSink answers false for a secret, and nothing changes -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP logKit.secrets: a secret string a sink raises reaches the client's error handler still secret, and the next sink still runs -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### When `/log` is already taken

The four `logKit.command` tests need `/log` for LogKit. When another enabled
addon, or the client, already holds `/log`, CommandKit refuses it and the four
tests print `SKIP` with CommandKit's reason (`taken` or `emote`), for example:

```text
MoltenCodes Test: SKIP logKit.command: RegisterCommand registers /log through CommandKit in the client's SlashCmdList, and a second call answers true without registering again -- CommandKit refused /log (taken): another addon or the client holds it
MoltenCodes Test: SKIP logKit.command: SlashCmdList /log '<addon> Debug' and '<addon> default' set and clear this addon's override, the level read without case, and print the level to LogKit's command sink -- CommandKit refused /log (taken): another addon or the client holds it
MoltenCodes Test: SKIP logKit.command: /log * info and /log * DEFAULT set and clear the global level; an unknown level, a missing level and an empty /log print their refusal or the usage and change nothing -- CommandKit refused /log (taken): another addon or the client holds it
MoltenCodes Test: SKIP logKit.command: /log for an addon without a logger sets its level without creating the logger, /log show lists the global level then every logger sorted by name, and /log show <addon> names one -- CommandKit refused /log (taken): another addon or the client holds it
```

With only the MoltenCodes addons enabled any `SKIP` is unexpected on Retail
12.1.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('logKit', 1) is the LogKit facade ...` | The facade the client loaded is API 1 with all eleven methods, the read-only `LEVELS` (`getmetatable` is `"LogKit.Levels"`), `DEFAULT_LEVEL`, `MAX_FORMAT_ARGUMENTS`, `SECRET_PLACEHOLDER` and `UNBOUNDED`. The log gives the session's four limits, the global level and how many sinks exist. |
| `the installed LogKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the client has GetTimePreciseSec, geterrorhandler, SlashCmdList ...` | Every host facility docs/API.md names is present, and `Registry:Find` finds CommandKit and SettingsKit for `RegisterCommand` and `BindLevels`. The log gives their revisions, whether `seterrorhandler`, `issecretvalue` and `secretwrap` exist, and SignalKit's journal limits. |
| `an addon override beats the global level ...` | The precedence addon, global, default, and the source `GetLevel` names for each, including a level given as a `LEVELS` value. |
| `a Debug call below warn reads neither its message nor its arguments ...` | The lazy contract on the client: a table and a number as message do not raise while disabled, a `__tostring` argument never runs, no sink is called and the SignalKit journal's generation stays where it was. |
| `once debug is on, the same Debug call formats once ...` | An enabled call formats through the client's `string.format` (`%.1f` of 2.5), runs `__tostring` exactly once, and the table sink receives addon, level number, level name and text; the journal's generation moves by one. |
| `the client's string.format gives positional %2$s before %1$s ...` | The client's `string.format` accepts positional specifiers, which stock Lua 5.1 refuses, and LogKit passes them through; `%5.1f`, `%x` and `%q` format as in C; `nil`, `true` and `false` format as in Lua 5.2; a bare message with `%` is delivered as it is. The error handler is swapped for the calls, so a client that refused `%2$s` would log the format failure here rather than open the error window. |
| `Log takes a level name or a LEVELS value ...` | `Log` by name and by value, `IsEnabled` agreeing with the level methods, and `off` silencing `Error`. |
| `History walks this addon's entries oldest to newest ...` | Entries come back oldest first with the level names, a disabled call leaves no entry, the filters by addon and by minimum level hold, `History(nil, "off")` yields nothing, and every `time` is a `GetTimePreciseSec` reading taken between the clock readings around the calls. The log gives how far apart the two entries were stamped. |
| `LogKit's journal is a SignalKit journal ...` | The journal is SignalKit's own ring: its newest raw entry has `count` 4 and holds the addon, the level number, the text and the very `time` `History` yields; each delivered message moves its generation by one and a disabled one does not. |
| `a ChatSink bound to a hidden ScrollingMessageFrame ...` | `ChatSink(frame)` writes `[MoltenCodesTest_LogKit] warn: profile "x" not found, using default`, the level word wrapped in the orange escape docs/API.md lists, and the red error line to a real client message frame that is never visible, nothing below the level, and the real chat frame holds exactly the lines it held before. The log gives both lines as the frame stores them. |
| `ChatSink() without a frame reads DEFAULT_CHAT_FRAME ...` | A chat sink built without a frame reads `DEFAULT_CHAT_FRAME` when it writes, so its line appears in the real chat frame exactly once more than before (counted from the end of each line, since timestamps may come first). This is the run's one visible line. |
| `sinks run in registration order with one shared record ...` | A function sink and a table sink run in registration order and receive the same record table; replacing the table sink's `Write` after `AddSink` takes effect at the next message; `RemoveSink` stops delivery at once and answers `false` for a removed handle, an unknown table and `nil`. |
| `a sink that raises is reported once through the client's error handler ...` | With the handler swapped by `seterrorhandler` for the call, the failure reaches it once, naming `LogKitSuite.lua` at the raising line; the next sink still receives the message, the journal records it, and the logging caller runs on. |
| `a table a sink raises reaches the client's error handler as that same table` | The error value is passed on unchanged. |
| `a %d given a string is reported ...` | A format failure is reported as `LogKit.Logger:Warn could not format a message for addon MoltenCodesTest_LogKit: <the client's message>` and the message reaches neither the journal nor any sink. The log gives the client's own wording. |
| `RegisterCommand registers /log through CommandKit ...` | `/log` is a function in the client's `SlashCmdList` under the key whose `SLASH_<key>1` is `/log` (the log gives the key, normally `MOLTENCODES_LOG`), a second `RegisterCommand` answers `true` and leaves the entry as it was, and LogKit's scope reports `log` registered. |
| `SlashCmdList /log '<addon> Debug' and '<addon> default' ...` | Calling the client's `SlashCmdList` entry, as the chat box does, sets and clears an addon override, reads the level word without case, ignores trailing tokens, and prints `<addon>: <level> (<source>)` to the scope's sink. |
| `/log * info and /log * DEFAULT set and clear the global level ...` | The global level through `*`, the refusal line of an unknown level, and the usage (first line `Usage: /log <addon\|*> <level\|default>`) for a missing level and for an empty `/log`, none of which changes a level. |
| `/log for an addon without a logger sets its level without creating the logger ...` | Setting the typed-only name does not create a logger (it is absent from `/log show`), `/log show <addon>` still answers for it, and `/log show` prints the global level first and then every logger sorted by addon name. |
| `BindLevels over an in-memory SettingsKit database ...` | A database over a scratch global that already holds `global.logLevels` restores this addon's level and the `*` global level, ignores `"loud"`, writes every changing `SetLevel` and `SetGlobalLevel` into the raw saved table, removes a cleared level, and writes nothing after `BindLevels(nil)`. |
| `a write the database refuses ...` | A `logLevels` map of `max` 2 that is full refuses a new addon's level: SettingsKit's refusal (`... global.logLevels: expected at most 2 entries`) reaches the swapped error handler once, the level still applies, and the saved table is unchanged. |
| `BindLevels refuses a plain table and a database without global.logLevels ...` | Both refusals at this file's calling line with docs/API.md's wording, and no binding is left. |
| `maxMessageLength 16 cuts a message of two-byte characters ...` | Eleven `é` (22 bytes) come out as six `é` and `...` (15 bytes): the cut never splits a UTF-8 sequence on the client's strings. A message of exactly 16 bytes is not cut. |
| `maxLoggers and maxSinks lowered to 1 ...` | A new logger gets `nil, "capped"` and a new sink `nil, "full"`, while `ForAddon` still returns an existing logger. |
| `Trace, Debug and Info below warn ...` | docs/API.md's "Disabled is nearly free" on the client's collector: after a full collection in its own step and one unmeasured warm-up round, 5000 rounds of three disabled level calls and a disabled `Log` with a `LEVELS` value move `collectgarbage("count")` by at most 1 KB; no argument is converted and the journal does not move. |
| `an enabled bare Warn delivered to a table sink ...` | "Enabled bare message: no allocation", with the journal firing and one table sink, over 2000 messages. Skipped when a sink of another addon is registered, since the messages would reach it. |
| `an enabled Warn formatting '%d of %s' ...` | "Allocates the formatted string (and none when it is already interned)": the same text 2000 times allocates nothing, and the journal's newest entry is `7 of bars`. |
| `ForAddon with an empty name and GetLimits called with a dot ...` | Both refusals at this file's calling line. |
| `an enabled Warn with a number as message, 17 format arguments ...` | The enabled-call checks and the level refusals at the calling line, and the logger's level unchanged. |
| `a logger method called on UIParent, AddSink and ChatSink given UIParent ...` | The receiver check, both sink shapes and the read-only `LEVELS` at the calling line, with a real client frame as the wrong argument. |
| `SetLimits with UNBOUNDED for journalCapacity ...` | Each refusal names its reason at the calling line, the SignalKit ceiling is the session's own `maxJournalCapacity`, and a refused call with one valid entry changes nothing. |
| `a secret number and a secret string as %s arguments ...` | A `secretwrap(42)` and a `secretwrap("Thrall")` given as `%s` arguments come out as `health <secret>, name <secret>` in a table sink, the journal and a hidden chat sink; the call returns normally and the error handler receives nothing, so no client compare or concatenation error escaped. The log records what the client itself does with `string.format` and concatenation of a secret. |
| `a secret number given to %d is replaced ...` | The placeholder is a string, so `%d` fails inside LogKit's `pcall`: the failure is reported as a LogKit format failure that is not itself secret, the call returns normally and nothing is delivered. |
| `a secret message raises at the calling line ...` | An enabled `Warn` and `Log` refuse a secret message with `... message must not be a secret value` at the calling line; a disabled `Debug` does not read it. |
| `a secret level, addon name, History filter, sink, chat frame and SetLimits value ...` | Every secret argument is refused at the calling line before it is compared or used as a key, `RemoveSink` answers `false`, and the levels, limits and sinks are as they were. |
| `a secret string a sink raises ...` | The error value of a sink is handed to the error handler untouched, still secret, and the next sink still runs. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line with only the MoltenCodes addons
  enabled on Retail 12.1, or a totals line other than
  `37 passed, 0 failed, 0 skipped, 0 timed out (37 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_LogKit`. Every error the suite provokes
  is caught by the test itself.
- More than the one `ChatSink()` line in the chat frame, or a line from `/log`
  (`MoltenCodesTest_LogKit: debug (addon)`, `global: info`, `Usage: /log ...`):
  output that should have gone to a capture sink reached the chat.
- A test failing with "the client's error handler could not be replaced": an
  error-capturing addon (BugGrabber) kept the handler; disable it and run
  again.
- The positional-format test failing with `expected number 1 to be number 0`:
  the client's `string.format` refused `%2$s`; its log holds the client's
  message.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed LogKit carries the revision ...` failing: another enabled
  addon embeds a different LogKit copy.
- A `logKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the session's limits, the
   `SlashCmdList` key of `/log`, the lines of the hidden frame, the journal
   timings, the memory deltas, the client's messages for the secret
   operations and the format failures, with their paths) and the client facts.
   Lua shortens a long file path from the left, so a logged message may start
   with `...`; the tests compare only the `LogKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed or was skipped.
