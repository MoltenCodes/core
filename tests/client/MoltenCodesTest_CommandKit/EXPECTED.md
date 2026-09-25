# Expected result: `/mct run commandKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package commandKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package commandKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package commandKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. Run it out of combat, with the chat box closed. The
lines below are Retail's; [Per flavour](#per-flavour) gives the two Classic
clients.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for commandKit. Type /mct run commandKit to run them; /mct help lists every command.
```

## After `/mct run commandKit`

Within about three seconds, exactly these lines, in this order (`PASS` is
green, `SKIP` yellow). The second line is not the harness's: it is the one
line the default-sink test writes to the chat frame on purpose, without the
`MoltenCodes Test:` prefix, while the run is in progress. The three allocation
tests each run a full garbage collection first, which can make the client
stutter for a moment. When the client has not cached the Linen Cloth or
Hearthstone item data, the parser tests ask the server for it and wait up to
five seconds, so the run can take a few seconds longer:

```text
MoltenCodes Test: running commandKit: 9 suites. Results follow when every test has finished.
CommandKit test: this line reached the chat frame through the default sink
MoltenCodes Test: PASS commandKit.facade: Registry:Get('commandKit', 1) is the CommandKit facade with API 1, its methods, UNBOUNDED, MAX_COMMANDS 64 and MAX_DEPTH 3
MoltenCodes Test: PASS commandKit.facade: the installed CommandKit carries the revision of the committed manifest
MoltenCodes Test: PASS commandKit.facade: the client has SlashCmdList and a default chat frame with AddMessage, OptionsKit is found, and the other host facilities are logged
MoltenCodes Test: PASS commandKit.registration: Register('mcttestcmd') writes a function to the client's SlashCmdList under MOLTENCODES_<ADDON>_MCTTESTCMD and '/mcttestcmd' to its SLASH_ global
MoltenCodes Test: PASS commandKit.registration: a name the client uses for a chat type (SLASH_SAY1), for one of its slash commands (from hash_SlashCmdList on Retail 12.1) or for a secure command (IsSecureCmd) is refused as taken, and an emote's name (EMOTE1_CMD1) as emote
MoltenCodes Test: PASS commandKit.registration: a closed scope leaves the client's SlashCmdList entry and SLASH_ global in place, inert and silent, and registering the name again answers through the same function
MoltenCodes Test: PASS commandKit.registration: the addon scope is arranged to close at logout: LifecycleKit announces it closes commandKit scopes, and the scope is open now
MoltenCodes Test: SKIP commandKit.registration: typing /mcttestcmd in the chat box reaches the same SlashCmdList entry -- needs the player to type; the tests call the SlashCmdList entry the chat box calls, see EXPECTED.md for the optional manual check
MoltenCodes Test: SKIP commandKit.registration: the addon scope is closed when the player logs out -- logout ends the session the results are saved from; LifecycleKit's own client suite covers its shutdown callbacks
MoltenCodes Test: PASS commandKit.dispatch: calling SlashCmdList.<key>('scale 1.5', the chat frame's edit box) runs the handler with the number 1.5 and writes only to the capture sink
MoltenCodes Test: PASS commandKit.dispatch: /mcttestcmd with nothing after it prints the generated usage, and an unknown sub-command prints its name with the usage
MoltenCodes Test: PASS commandKit.dispatch: arguments are checked against their schemas: scale 5 is refused with the schema's message and the usage, mode raid off converts off to false
MoltenCodes Test: PASS commandKit.dispatch: a handler that raises is reported to the sink as '/mcttestcmd boom failed' and to the client's error handler naming CommandKitSuite.lua at the raising line
MoltenCodes Test: PASS commandKit.dispatch: with no sink set, a handler's Print reaches the real default chat frame as its newest line (one visible line)
MoltenCodes Test: PASS commandKit.parser: a real Linen Cloth (2589) link from C_Item.GetItemInfo, colour code and spaced name included, is one token bare, quoted and between two words
MoltenCodes Test: PASS commandKit.parser: watch followed by a real Hearthstone (6948) link and a quoted note hands the handler the whole link and the note, and the link passes the |Hitem: pattern
MoltenCodes Test: PASS commandKit.parser: a real link cut before its closing |h is refused as an unterminated link, by Parse and by dispatch with the usage
MoltenCodes Test: PASS commandKit.options: BindOptions registers /mcttestopts over an OptionsKit tree: set scale 1.25 writes through the tree's set, get prints it, set shown off and set anchor top convert the words
MoltenCodes Test: PASS commandKit.options: refusals of /mcttestopts: set scale 5 prints the schema's message, an unknown path and reset of a get/set option are refused, and nothing is written
MoltenCodes Test: PASS commandKit.options: list prints one line per option of the tree, and exec wipe asks its question until the word confirm follows, then runs the button once
MoltenCodes Test: PASS commandKit.completion: EnableCompletion answers whether the client has ChatEdit_CustomTabPressed; when it does, it replaces the global, and DisableCompletion writes the client's function back
MoltenCodes Test: PASS commandKit.completion: a Tab press handed to the installed ChatEdit_CustomTabPressed completes '/mcttestcmd sc' to 'scale ', lists every sub-command after '/mcttestcmd ', and completes a bound option path
MoltenCodes Test: SKIP commandKit.completion: a real Tab press in the chat box calls ChatEdit_CustomTabPressed with that edit box -- needs the player to press Tab in the chat box; the tests hand the installed function a stand-in edit box instead
MoltenCodes Test: PASS commandKit.allocation: 5000 dispatches of 'scale 1.5' through the client's SlashCmdList entry allocate nothing
MoltenCodes Test: PASS commandKit.allocation: 5000 ParseInto calls over text holding a real Hearthstone link allocate nothing
MoltenCodes Test: PASS commandKit.allocation: 5000 calls to the inert SlashCmdList entry of an unregistered command allocate nothing
MoltenCodes Test: PASS commandKit.errors: a spec with an unknown field and a name with a hyphen are refused at the calling line
MoltenCodes Test: PASS commandKit.errors: registering /mcttestcmd twice in one scope, and Register on a closed scope, are refused at the calling line
MoltenCodes Test: PASS commandKit.errors: SetSink with UIParent, a real Frame without AddMessage, and BindOptions with a plain table are refused at the calling line
MoltenCodes Test: PASS commandKit.errors: a context kept past its command, and Parse called with a dot, are refused at the calling line
MoltenCodes Test: PASS commandKit.secrets: Parse and ParseInto refuse a secret text at the calling line
MoltenCodes Test: PASS commandKit.secrets: Register with a secret name and CreateScope with a secret maxCommands are refused at the calling line
MoltenCodes Test: PASS commandKit.secrets: SetLimits with a secret maxCaptured or maxCompletions is refused at the calling line and the limits stay as they were
MoltenCodes Test: PASS commandKit.secrets: inside a dispatched handler, context:Print and Printf refuse a secret argument at the handler's line in CommandKitSuite.lua and write nothing
MoltenCodes Test: PASS commandKit.secrets: a handler that raises a secret message writes '/mcttestsecret failed' without the message and hands the secret, still secret, to the client's error handler
MoltenCodes Test: PASS commandKit.secrets: a bound option whose getter returns a secret prints '(secret value)', and set toggle on a secret toggle is refused and writes nothing
MoltenCodes Test: commandKit: 33 passed, 0 failed, 3 skipped, 0 timed out (36 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

- **One chat line**: `CommandKit test: this line reached the chat frame through the default sink`,
  written by `with no sink set, a handler's Print reaches the real default chat
  frame ...` through CommandKit's default sink, which is the chat frame. Every
  other line CommandKit writes during the run goes to a capture sink, so no
  usage text, refusal or `Scale 1.50.` line appears in chat.
- **Item data requests**: when the client has not cached item 2589 (Linen
  Cloth) or 6948 (Hearthstone), `C_Item.RequestLoadItemDataByID` asks the
  server for it. That is a read-only data query, the same one the client sends
  when an item tooltip is shown; nothing is bought, used or moved.
- Nothing is typed, nothing is drawn, no sound plays, no CVar changes and no
  message is sent to another player.

## What stays for the session

The client keeps every slash command CommandKit wrote for the session, as
docs/API.md ("Inert globals and re-registration") says: the client caches slash
functions, so CommandKit never removes the entries. After a run these stay,
each an inert dispatcher that does nothing (no output, no error) if the name
is typed:

| Slash name | `SlashCmdList` key and `SLASH_<key>1` global |
|---|---|
| `/mcttestcmd` | `MOLTENCODES_MOLTENCODESTEST_COMMANDKIT_MCTTESTCMD` |
| `/mcttestopts` | `MOLTENCODES_MOLTENCODESTEST_COMMANDKIT_MCTTESTOPTS` |
| `/mcttestsecret` | `MOLTENCODES_MOLTENCODESTEST_COMMANDKIT_MCTTESTSECRET` |
| `/mcttestinert` | `MOLTENCODES_MCTTESTINERT` (registered from a manual scope) |

A later run registers the same names again under the same keys, through the
same functions. `/reload` clears all of them.

Everything else is put back by the After hook of each suite, pass or fail:
every command a test registered is unregistered, every manual scope is closed,
the OptionsKit tree `MoltenCodesTest_CommandKit` is undefined, the addon
scope's output goes back to the chat frame, and completion is turned off,
which writes the client's own `ChatEdit_CustomTabPressed` back. The completion
tests replace that global from addon code for a moment, as every addon that
completes chat input does (docs/API.md, "Tab completion"); the function put
back is the client's own, but the client may report the global as written by
addon code (`issecurevariable` false) until `/reload`. The first completion
test logs `issecurevariable` before and after. This addon's own CommandKit
scope (`CommandKit:ForAddon("MoltenCodesTest_CommandKit")`) stays open and
empty until logout, when LifecycleKit closes it. CommandKit's package-wide
limits are not changed (every `SetLimits` call is a refusal the test checks).
The client's error handler is replaced only for the length of one dispatch
and put back at once. Nothing is written to a saved variable other than the
harness's own results.

## The three expected SKIPs

| Test | Why it cannot run in `/mct run` |
|---|---|
| `typing /mcttestcmd in the chat box reaches the same SlashCmdList entry` | Only the player can type. The tests call the `SlashCmdList` entry the chat box calls once it has matched the slash name, with the chat frame's edit box as the second argument, which is everything CommandKit sees of a typed command. |
| `the addon scope is closed when the player logs out` | Logout ends the session the results are saved from. The test before it checks that LifecycleKit announces it closes `commandKit` scopes (case (a) of docs/API.md, "At logout"). |
| `a real Tab press in the chat box calls ChatEdit_CustomTabPressed with that edit box` | Only the player can press Tab in the chat box. The completion test hands the installed global a stand-in edit box instead. |

### Optional manual check (not part of the totals)

Only if you want to see the typed path as well, after the run and before any
`/reload`: the commands are unregistered by then, so typing `/mcttestcmd` must
do nothing at all, with no chat line and no error. That proves the client
reaches CommandKit's inert entry for the name. It is not needed for the report.

### On a client without secret values

The six `commandKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. Retail 12.1 has both. A client without them prints each of the
six lines as `SKIP ... -- the client has no issecretvalue and secretwrap; the
secret path was not exercised`, and the totals line reads
`27 passed, 0 failed, 9 skipped, 0 timed out (36 tests)`.

### A client without `ChatEdit_CustomTabPressed`

docs/API.md lists `ChatEdit_CustomTabPressed` as an optional host facility,
and the Retail 12 chat code has not been checked for it yet. On a client
without it, the first completion test still passes (it checks that
`EnableCompletion` returns `false` and installs nothing), and the second ends
as `SKIP ... -- the client has no ChatEdit_CustomTabPressed; EnableCompletion
returns false and completion is not available`, making the totals
`32 passed, 0 failed, 4 skipped, 0 timed out (36 tests)`. Send the log either
way: the facade test records whether `ChatEdit_CustomTabPressed` and
`ChatEdit_GetActiveWindow` exist and whether the client reports them secure.

## Per flavour

The committed apiKit metadata (`packages/apiKit/metadata/<flavour>/`)
documents what the suite calls for `retail`, `classic-era` and `classic-mop`
alike: `C_Item.GetItemInfo` and `C_Item.RequestLoadItemDataByID` (Linen Cloth,
2589, and the Hearthstone, 6948, exist on every client), `issecretvalue` and
`secretwrap`. Everything else it reads is the client's chat and slash code
and core globals, which the metadata does not list and which every client
provides: `SlashCmdList`, `SLASH_<key><n>`, `DEFAULT_CHAT_FRAME` with
`AddMessage`, `GetNumMessages` and `GetMessageInfo`, `ChatFrame1EditBox`,
`SLASH_SAY1`, `EMOTE1_CMD1`, `UIParent`, `issecurevariable`, `geterrorhandler`,
`seterrorhandler` and `securecallfunction`. The facilities docs/API.md names
as optional (`hash_SlashCmdList`, `hash_ChatTypeInfoList`,
`hash_EmoteTokenList`, `SecureCmdList`, `IsSecureCmd`,
`ChatEdit_CustomTabPressed`, `ChatEdit_GetActiveWindow`) are probed at run
time and logged by the facade test. So no test is skipped by flavour, and
nothing the suite reads at load is missing on a Classic client.

### Retail (12.1)

The lines above:
`MoltenCodes Test: commandKit: 33 passed, 0 failed, 3 skipped, 0 timed out (36 tests)`,
with the three `SKIP` lines listed under
[The three expected SKIPs](#the-three-expected-skips).

### Classic Era (1.15) and Mists of Pandaria Classic (5.5)

The `running` line (9 suites) and every test line are the same as Retail's,
in the same order, with the same three `SKIP` lines. The taken check reads a
slash command of the client's own from `hash_SlashCmdList` when that table
holds one, else from `SlashCmdList`, so it finds one whichever of the two a
Classic chat frame keeps its commands in; the log says which, and the sizes
of both tables.
Whether the six `commandKit.secrets` tests run depends on one answer only the
running client gives: whether it has the global functions `issecretvalue` and
`secretwrap` (both Classic flavours document them; the suite reads them at
load).

- With both functions, and secrets made with them, the totals line is
  Retail's:
  `MoltenCodes Test: commandKit: 33 passed, 0 failed, 3 skipped, 0 timed out (36 tests)`.
- Without them, the six `commandKit.secrets` lines are `SKIP` with the reason
  given under [On a client without secret values](#on-a-client-without-secret-values),
  and the totals line is
  `MoltenCodes Test: commandKit: 27 passed, 0 failed, 9 skipped, 0 timed out (36 tests)`.

A client that has both functions but makes no secret with them
(`issecretvalue` does not report what `secretwrap` returns as secret;
`Harness:CanMakeSecrets` measures this once at load) skips the same six
tests with another reason, and the totals line is again
`MoltenCodes Test: commandKit: 27 passed, 0 failed, 9 skipped, 0 timed out (36 tests)`:

```text
MoltenCodes Test: SKIP commandKit.secrets: Parse and ParseInto refuse a secret text at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP commandKit.secrets: Register with a secret name and CreateScope with a secret maxCommands are refused at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP commandKit.secrets: SetLimits with a secret maxCaptured or maxCompletions is refused at the calling line and the limits stay as they were -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP commandKit.secrets: inside a dispatched handler, context:Print and Printf refuse a secret argument at the handler's line in CommandKitSuite.lua and write nothing -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP commandKit.secrets: a handler that raises a secret message writes '/mcttestsecret failed' without the message and hands the secret, still secret, to the client's error handler -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP commandKit.secrets: a bound option whose getter returns a secret prints '(secret value)', and set toggle on a secret toggle is refused and writes nothing -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

A Classic client without `ChatEdit_CustomTabPressed` adds the one
`SKIP` described under
[A client without `ChatEdit_CustomTabPressed`](#a-client-without-chatedit_customtabpressed),
one pass fewer and one skip more than either totals line above.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('commandKit', 1) is the CommandKit facade ...` | The facade the client loaded is API 1 with every facade method, the `UNBOUNDED` sentinel, `MAX_COMMANDS` 64, `MAX_DEPTH` 3 and the shared prototypes; the log gives the session's package-wide limits. |
| `the installed CommandKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's. |
| `the client has SlashCmdList and a default chat frame ...` | The two host facilities CommandKit cannot work without exist, and OptionsKit is found for `BindOptions`. The log records every other facility docs/API.md names (`SecureCmdList`, `ChatTypeInfo`, `MAXEMOTEINDEX`, `EMOTE1_CMD1`, `SLASH_SAY1`, `hash_SlashCmdList`, `ChatEdit_CustomTabPressed`, `ChatEdit_GetActiveWindow`, `ChatFrame1EditBox`, `securecallfunction`), `issecurevariable` of the two chat edit functions, and which optional Kits are loaded. |
| `Register('mcttestcmd') writes a function to the client's SlashCmdList ...` | The client's own `SlashCmdList` gets a function under `MOLTENCODES_MOLTENCODESTEST_COMMANDKIT_MCTTESTCMD`, `SLASH_<key>1` is `/mcttestcmd` and there is no second alias; the scope answers for the name in any case; `ForAddon` returns the same scope. The log says whether the client's slash cache holds the name (it only does once the name was typed). |
| `a name the client uses for a chat type ... an emote's name ...` | The taken check reads the client's real tables: the name in `SLASH_SAY1` (a chat type), a slash command of the client's own and, when `IsSecureCmd` confirms it, the name in `SLASH_CAST1` (a secure command) are refused as `taken`; the name in `EMOTE1_CMD1` is refused as `emote`. The client's own command is the first plain slash text of `hash_SlashCmdList`, in sorted order, that `hash_ChatTypeInfoList` does not attribute to a CommandKit key; only a client without that table falls back to the first plain `SLASH_<key>1` of a `SlashCmdList` key. Retail 12.1's chat frame (Blizzard_ChatFrameBase, build 69933) moves every `SlashCmdList`, `ChatTypeInfo` and secure-command entry into the `hash_*` tables at load and before each typed line, wipes the lists and keeps `SecureCmdList` private, so the lists hold none of its commands: the run of 2026-09-25 logged `SecureCmdList: nil` and found no `SlashCmdList` key with a `SLASH_<key>1`, and this test was skipped. CommandKit revision 6 reads the `hash_*` tables and `IsSecureCmd` too. The log names each name tried, its key and source, and the size of `SlashCmdList`, the three `hash_*` tables, `ChatTypeInfo` and `SecureCmdList` (with whether a list has an `__index` proxy). Should one be registered after all, the test unregisters it and clears its `SLASH_` global at once, so the client's own command keeps working. |
| `a closed scope leaves the client's SlashCmdList entry ...` | After `Close` the function stays in the client's `SlashCmdList` and `SLASH_MOLTENCODES_MCTTESTINERT1` stays `/mcttestinert`; calling it writes nothing and reports no error; a second scope registering the name gets the very same function, which now reaches the new handler. |
| `the addon scope is arranged to close at logout ...` | The installed LifecycleKit publishes `CLOSES_ADDON_SCOPES.commandKit`, so this addon's scope is closed by LifecycleKit at logout (case (a)); the scope is open during the run. |
| `calling SlashCmdList.<key>('scale 1.5', the chat frame's edit box) ...` | Dispatch through the client's entry with the real edit box converts `1.5` for the number schema, gives the context the command path and the raw text, writes `Scale 1.50.` to the capture sink only, and the chat frame's line count and last line do not change. |
| `/mcttestcmd with nothing after it prints the generated usage ...` | The nine usage lines generated from the spec (sorted sub-commands, `<number 0.5..2>`, `<party\|raid\|all> [on\|off]`, the declared `<item link> [note]`), and `unknown sub-command "fly"` followed by them. |
| `arguments are checked against their schemas ...` | `scale 5` is refused with SchemaKit's message and the sub-command's usage; `scale 1 2` with `expected at most 1 argument`; `MODE raid off` matches the sub-command without case and converts `off` to `false`; `mode loud` is refused with the enum's message. No refused command reaches its handler. |
| `a handler that raises is reported to the sink ...` | The failure is written as `/mcttestcmd boom failed: <file>:<line>: ...` and handed once to the client's error handler (swapped with `seterrorhandler` for the call), naming this file at the raising line. |
| `with no sink set, a handler's Print reaches the real default chat frame ...` | The default sink is the client's `DEFAULT_CHAT_FRAME`: its newest line, read back with `GetMessageInfo`, is the line the handler printed. This is the one visible line of the run. |
| `a real Linen Cloth (2589) link ...` | The link the client builds (quality colour, `\|Hitem:...\|h[Linen Cloth]\|h\|r`, a space in the name) is one token bare, in double quotes and between two words, and `ParseInto` clears stale slots. The log shows the link with its escape codes. |
| `watch followed by a real Hearthstone (6948) link and a quoted note ...` | Through dispatch the handler receives the whole link, which passes the `\|Hitem:` pattern schema, and the quoted note as one argument; two links separated by spaces and a tab are two tokens. |
| `a real link cut before its closing \|h ...` | A real link cut after its item data is refused as `unterminated link` by `Parse` and by dispatch, which prints `/mcttestcmd: unterminated link` and the usage. |
| `BindOptions registers /mcttestopts over an OptionsKit tree ...` | `/mcttestopts` is a real slash entry; `set` parses a range value, the word `off` for a toggle and `top`, the label `Top` matched without case, for a select, writes through the tree's own `set`, and prints `path = value` as docs/API.md shows. |
| `refusals of /mcttestopts ...` | The schema's bound, a word that is not a number, an unknown path and `reset` of a get/set option are each refused with the documented message, and the tree's `set` never runs. |
| `list prints one line per option ... exec wipe asks its question ...` | `list` prints the four options in their `order`, and `exec` prints the `confirm` question and the hint until `confirm` follows, then runs the button once. |
| `EnableCompletion answers whether the client has ChatEdit_CustomTabPressed ...` | With the global present: `EnableCompletion` replaces it and `DisableCompletion` writes the client's function back. Without it: `EnableCompletion` returns `false` and installs nothing. The log gives both globals' types, `ChatEdit_GetActiveWindow()`'s answer with the chat box closed, and `issecurevariable` before and after. |
| `a Tab press handed to the installed ChatEdit_CustomTabPressed ...` | The installed global, called as the client's tab handler calls it but with a stand-in edit box, completes `sc` to `scale `, lists all seven sub-commands on the sink after `/mcttestcmd `, and completes an option path of the bound command. The real chat edit box is never touched. |
| `5000 dispatches of 'scale 1.5' ...` | After a full collection in a step of its own, 5000 dispatches through the client's entry move `collectgarbage("count")` by at most 1 KB, as docs/API.md promises for text seen before. |
| `5000 ParseInto calls over text holding a real Hearthstone link ...` | The same for parsing a real link, quoted, between two words. |
| `5000 calls to the inert SlashCmdList entry ...` | The same for the entry of an unregistered command. |
| `a spec with an unknown field and a name with a hyphen ...` | Both spec refusals name this file at the calling line, as the client names it. |
| `registering /mcttestcmd twice in one scope, and Register on a closed scope ...` | Both refusals at the calling line. |
| `SetSink with UIParent ... and BindOptions with a plain table ...` | A real Frame without `AddMessage` is refused as a sink, and a table that is not an OptionsKit tree is refused, both at the calling line. |
| `a context kept past its command, and Parse called with a dot ...` | A context used after its command returned, and a facade method called with `.`, are refused at the calling line. |
| `Parse and ParseInto refuse a secret text ...` | A `secretwrap` string is refused before it is read, at the calling line. |
| `Register with a secret name and CreateScope with a secret maxCommands ...` | A secret name and a secret limit are refused at the calling line with the documented messages. |
| `SetLimits with a secret maxCaptured or maxCompletions ...` | Both refusals at the calling line with the messages any other invalid value gets, and `GetLimits` unchanged. |
| `inside a dispatched handler, context:Print and Printf refuse a secret argument ...` | A secret never reaches chat output: `Print` and `Printf` raise at the handler's line in this file (argument 2) and write nothing. |
| `a handler that raises a secret message ...` | The sink gets `/mcttestsecret failed` without the message, and the client's error handler receives the value still secret. |
| `a bound option whose getter returns a secret ...` | `get` prints `level = (secret value)`; `set flag toggle` on a secret toggle prints `the current value is secret; use on or off` and writes nothing. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` other than the three above on Retail
  12.1, or a totals line other than
  `33 passed, 0 failed, 3 skipped, 0 timed out (36 tests)` (see the two
  sections above for a client without secrets or without
  `ChatEdit_CustomTabPressed`, and [Per flavour](#per-flavour) for a Classic
  client).
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_CommandKit`. Every error the suite
  provokes is caught by the test itself.
- Any chat line from CommandKit other than the one default-sink line (usage
  text, `Scale 1.50.`, a refusal): a capture sink did not receive it.
- `a name the client uses for a chat type ...` failing, or ending as `SKIP`:
  the log names the names tried and what `Register` answered. A `SKIP`
  means the client lacks `SLASH_SAY1`, a slash command of its own in
  `hash_SlashCmdList` or `SlashCmdList`, or `EMOTE1_CMD1`, so CommandKit's
  taken and emote checks find nothing on this client and docs/API.md needs
  correcting. The run of 2026-09-25 (CommandKit revision 5) ended here as
  `SKIP` with `32 passed, 0 failed, 4 skipped`, because the test looked only
  in `SlashCmdList`. After such a failure, `/reload`
  before typing any slash command.
- A parser test ending as `SKIP` because the server did not send item data
  within five seconds: run again once the client is connected.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed CommandKit carries the revision ...` failing: another enabled
  addon embeds a different CommandKit copy.
- A test failing with "the client's error handler could not be replaced": an
  error-capturing addon (BugGrabber) keeps the handler; disable it and run
  again.
- Tab completion behaving differently in the chat box after the run: the
  completion After hook did not put the client's function back.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (the host facilities and their
   `issecurevariable` answers, the names the taken check tried, the real item
   links with their escape codes, the sink lines of the options tests, the
   chat frame line counts, the client's own error messages with their paths,
   the three measured memory deltas) and the client facts. Lua shortens a long
   file path from the left, so a logged message may start with `...`; the
   tests compare only the `CommandKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
