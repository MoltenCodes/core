# Expected result: `/mct run schemaKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package schemaKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package schemaKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package schemaKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. Run it out of combat. The lines below are Retail's;
[Per flavour](#per-flavour) gives the two Classic clients.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for schemaKit. Type /mct run schemaKit to run them; /mct help lists every command.
```

## After `/mct run schemaKit`

Within about two seconds, exactly these lines, in this order (`PASS` is
green in the client). Nothing waits on the clock; the five allocation tests
each run a full garbage collection first, which can make the client stutter
for a moment:

```text
MoltenCodes Test: running schemaKit: 6 suites. Results follow when every test has finished.
MoltenCodes Test: PASS schemaKit.facade: Registry:Get('schemaKit', 1) is the SchemaKit facade with API 1, its eleven builders, Seal, SetLimits, GetLimits, UNBOUNDED and the Schema prototype's four methods
MoltenCodes Test: PASS schemaKit.facade: the installed SchemaKit carries the revision of the committed manifest
MoltenCodes Test: PASS schemaKit.facade: GetLimits answers a fresh table holding the session's four limits at their defaults, which MAX_DEPTH and DEFAULT_ARRAY_MAX publish
MoltenCodes Test: PASS schemaKit.clientLua: for 17 accepted patterns, the pattern rule agrees with the client's own string.find on 11 subjects each, and no Check raises
MoltenCodes Test: PASS schemaKit.clientLua: 7 malformed patterns that the client's string.find answers on one subject but raises on another are each refused by SchemaKit.string at the calling line
MoltenCodes Test: PASS schemaKit.clientLua: a pattern of 32 captures is accepted and checks without raising, and one of 33, which the client's string.find refuses with too many captures, is refused at the calling line
MoltenCodes Test: PASS schemaKit.clientLua: number bounds in failures are printed by the client's %.14g: 0.1, 1e+15, 9.007199254741e+15, -0.5, 0.33333333333333, and an integer bound reads integer <= 100
MoltenCodes Test: PASS schemaKit.clientLua: string bounds count the bytes of the client's UTF-8 text, NaN is found as NaN and an infinite number as infinite, and an enum lists '|' doubled
MoltenCodes Test: PASS schemaKit.hostValues: GetBuildInfo's version, build, date and interface match a schema of their shapes, and a failing bound names rule and bound but not the interface number
MoltenCodes Test: PASS schemaKit.hostValues: C_Spell.GetSpellInfo(6603) matches an open spell info schema, and a closed schema naming only name and spellID refuses one of the client's other fields by name
MoltenCodes Test: PASS schemaKit.hostValues: Apply copies C_Spell.GetSpellInfo(6603) into a new table with a default filled in, keeps the client's undeclared fields and leaves the client's table unchanged
MoltenCodes Test: PASS schemaKit.hostValues: a table schema reads UIParent with rawget, so GetName, which the Frame's metatable supplies, is missing and refused as required
MoltenCodes Test: PASS schemaKit.hostValues: UIParent's userdata handle is found as userdata, accepted by any and kept as it is by Apply, and a Frame or its handle used as a key shows in a path as [table] or [userdata]
MoltenCodes Test: PASS schemaKit.hostValues: a custom check receives UIParent itself and accepts it, and refuses a plain table with found table
MoltenCodes Test: PASS schemaKit.allocation: Check and Assert of a valid nested settings table, the cookbook's, allocate nothing over 5000 cycles
MoltenCodes Test: PASS schemaKit.allocation: Check of the client's C_Spell.GetSpellInfo(6603) table against the open spell info schema allocates nothing over 5000 cycles
MoltenCodes Test: PASS schemaKit.allocation: Check of strings against an anchored pattern with bounds, a oneOf list and an enum allocates nothing over 5000 cycles
MoltenCodes Test: PASS schemaKit.allocation: a Check failing at the root with a fixed phrase (larger number, wrong type) reuses its failure table and allocates nothing over 5000 cycles
MoltenCodes Test: PASS schemaKit.errors: SchemaKit.number with min above max and SchemaKit.table with a field that is not a node name SchemaKitSuite.lua at the calling line
MoltenCodes Test: PASS schemaKit.errors: a builder called with a colon and Seal called with a dot are refused at the calling line
MoltenCodes Test: PASS schemaKit.errors: Check called on UIParent instead of a schema, and a write to a sealed schema, are refused at the calling line
MoltenCodes Test: PASS schemaKit.errors: Assert raises its failure at the calling line, and with level 2 at the line that called the validating function
MoltenCodes Test: PASS schemaKit.errors: an error raised by a custom check propagates unchanged from its own line in SchemaKitSuite.lua, through Check and Assert
MoltenCodes Test: PASS schemaKit.errors: an optional default that fails its schema is refused at the calling line with the default's own failure
MoltenCodes Test: PASS schemaKit.errors: SetLimits with an unknown limit or a maxDepth above 64 is refused at the calling line and changes no limit
MoltenCodes Test: PASS schemaKit.secrets: the client raises when a secret number meets a number in < or == or is used as a key, and answers type and a comparison with nil: the hazards SchemaKit must refuse before
MoltenCodes Test: PASS schemaKit.secrets: a secret number checked against number schemas with min, max and integer fails with rule secret and found secret value, and no client compare error escapes
MoltenCodes Test: PASS schemaKit.secrets: a secret string, boolean and number are refused with rule secret by string with a pattern, bounds or a oneOf list, enum, boolean, any, oneOf and optional, each without raising
MoltenCodes Test: PASS schemaKit.secrets: a custom check is never called with a secret, and the failure names rule secret
MoltenCodes Test: PASS schemaKit.secrets: a secret inside a table, an array and a map is refused at stats.health, [2] and byUnit.player without raising
MoltenCodes Test: PASS schemaKit.secrets: Assert with a secret raises at the calling line in SchemaKitSuite.lua with 'health: expected number, found secret value', a plain string without the secret's text
MoltenCodes Test: PASS schemaKit.secrets: Apply of a secret in a declared field fails with rule secret, while a secret in an undeclared field of an open table is kept, still secret, in the copy
MoltenCodes Test: PASS schemaKit.secrets: SetLimits refuses a secret maxDepth and a secret defaultArrayMax at the calling line with the messages any invalid value gets, and the limits stay as they were
MoltenCodes Test: PASS schemaKit.secrets: a Check of a secret at the root allocates nothing over 5000 cycles
MoltenCodes Test: schemaKit: 34 passed, 0 failed, 0 skipped, 0 timed out (34 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

None. Nothing is drawn, no sound plays, no chat line other than the harness's
appears, no client setting (CVar) changes and no request goes to the server:
`GetBuildInfo()` and `C_Spell.GetSpellInfo(6603)` (Auto Attack) answer from
the client's own data, and `UIParent` is only read, never changed. The only
thing a player could notice is the short stutter of the five full garbage
collections.

## What stays for the session

Nothing the suite needs to release. Nodes and schemas are plain Lua tables the
collector frees once a test drops them (SchemaKit keeps them in weak tables),
no Frame is created and nothing is written to a global or a saved variable
other than the harness's own results. SchemaKit's package-wide limits
(`maxDepth`, `maxPatternCaptures`, `pathKeyLimit`, `defaultArrayMax`) are never
changed: every `SetLimits` call in the suite is a refusal the test checks, and
the tests that make one compare `GetLimits()` before and after. The suite
therefore has no After hook.

### On a client without secret values

The 9 `schemaKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these 9 lines instead, and the totals
line reads `25 passed, 0 failed, 9 skipped, 0 timed out (34 tests)`:

```text
MoltenCodes Test: SKIP schemaKit.secrets: the client raises when a secret number meets a number in < or == or is used as a key, and answers type and a comparison with nil: the hazards SchemaKit must refuse before -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: a secret number checked against number schemas with min, max and integer fails with rule secret and found secret value, and no client compare error escapes -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: a secret string, boolean and number are refused with rule secret by string with a pattern, bounds or a oneOf list, enum, boolean, any, oneOf and optional, each without raising -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: a custom check is never called with a secret, and the failure names rule secret -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: a secret inside a table, an array and a map is refused at stats.health, [2] and byUnit.player without raising -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: Assert with a secret raises at the calling line in SchemaKitSuite.lua with 'health: expected number, found secret value', a plain string without the secret's text -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: Apply of a secret in a declared field fails with rule secret, while a secret in an undeclared field of an open table is kept, still secret, in the copy -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: SetLimits refuses a secret maxDepth and a secret defaultArrayMax at the calling line with the messages any invalid value gets, and the limits stay as they were -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP schemaKit.secrets: a Check of a secret at the root allocates nothing over 5000 cycles -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### A client without the functions the host-value tests read

The three tests that read `C_Spell.GetSpellInfo` end as skipped with `the
client has no C_Spell.GetSpellInfo`, or with `C_Spell.GetSpellInfo(6603)
answered no plain table` when the answer is missing or secret; the
`GetBuildInfo` test ends as skipped with `the client has no GetBuildInfo`.
All three promised clients have both (see [Per flavour](#per-flavour)), so
such a `SKIP` is unexpected on each of them.

## Per flavour

Every test reads only what all three promised clients have: Lua 5.1's
`string.find` and `string.format`, `collectgarbage`, `UIParent` and its
userdata handle, and `GetBuildInfo`, which every client provides as a core
global although the committed Classic metadata does not list it. The apiKit
metadata documents `C_Spell.GetSpellInfo` (with the same seven `SpellInfo`
fields), `issecretvalue` and `secretwrap` for `retail`, `classic-era` and
`classic-mop` alike.

### Retail (12.1)

The lines above: `MoltenCodes Test: schemaKit: 34 passed, 0 failed, 0 skipped, 0 timed out (34 tests)`,
with no `SKIP` line.

### Classic Era (1.15) and Mists of Pandaria Classic (5.5)

The `running` line and every test line are the same as Retail's, in the same
order; the build test logs the Classic version, build and interface (for
example `1.15.9` and `11509`, or `5.5.4` and `50504`). Whether the nine `schemaKit.secrets` tests run depends on answers only the
running client gives, measured when the suite loads: whether it has the
global functions `issecretvalue` and `secretwrap` (both Classic flavours
document them), and whether it actually makes secrets, which
`Harness:CanMakeSecrets()` measures once as
`issecretvalue(secretwrap(true)) == true`.

- The client makes secrets: the totals line is Retail's,
  `MoltenCodes Test: schemaKit: 34 passed, 0 failed, 0 skipped, 0 timed out (34 tests)`.
- The client has both functions but makes no secrets: the nine tests print
  these lines, and the totals line is
  `MoltenCodes Test: schemaKit: 25 passed, 0 failed, 9 skipped, 0 timed out (34 tests)`:

```text
MoltenCodes Test: SKIP schemaKit.secrets: the client raises when a secret number meets a number in < or == or is used as a key, and answers type and a comparison with nil: the hazards SchemaKit must refuse before -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: a secret number checked against number schemas with min, max and integer fails with rule secret and found secret value, and no client compare error escapes -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: a secret string, boolean and number are refused with rule secret by string with a pattern, bounds or a oneOf list, enum, boolean, any, oneOf and optional, each without raising -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: a custom check is never called with a secret, and the failure names rule secret -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: a secret inside a table, an array and a map is refused at stats.health, [2] and byUnit.player without raising -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: Assert with a secret raises at the calling line in SchemaKitSuite.lua with 'health: expected number, found secret value', a plain string without the secret's text -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: Apply of a secret in a declared field fails with rule secret, while a secret in an undeclared field of an open table is kept, still secret, in the copy -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: SetLimits refuses a secret maxDepth and a secret defaultArrayMax at the calling line with the messages any invalid value gets, and the limits stay as they were -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP schemaKit.secrets: a Check of a secret at the root allocates nothing over 5000 cycles -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

- The client lacks either function: the nine lines listed under
  [On a client without secret values](#on-a-client-without-secret-values)
  are `SKIP`, with the same totals line
  `MoltenCodes Test: schemaKit: 25 passed, 0 failed, 9 skipped, 0 timed out (34 tests)`.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('schemaKit', 1) is the SchemaKit facade ...` | The facade the client loaded is API 1 with the eleven builders, `Seal`, `SetLimits`, `GetLimits`, `UNBOUNDED` and a `Schema` prototype carrying `Check`, `Assert`, `Apply` and `Describe`; `getmetatable` answers the names `SchemaKit.Schema` and `SchemaKit.Node`. |
| `the installed SchemaKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `GetLimits answers a fresh table ...` | `GetLimits` returns a new table per call, holding the defaults 16, 32, 32 and 1024, and `MAX_DEPTH` and `DEFAULT_ARRAY_MAX` publish 16 and 1024. The log gives the session's limits; a difference means another addon changed them. |
| `for 17 accepted patterns ...` | For every accepted pattern (anchors, sets holding `]` and `-`, `%f`, `%b`, a back-reference, lazy repetition, `%c`, a colour escape, and plain text such as `a)`), the `pattern` rule answers exactly what the client's own `string.find` answers on each of 11 subjects (empty, ASCII, a version, parentheses, UTF-8, control bytes), and no `Check` raises. The log gives one line of answers per pattern. |
| `7 malformed patterns ...` | For `a[`, `a(b`, `a%`, `x%1`, `%a)`, `a%b` and `1%f[a`, the client's `string.find` answers a subject that never reaches the broken part and raises on one that does, which is why SchemaKit walks the pattern when the node is built: each is refused at this file's calling line. The log holds the client's own matcher messages. |
| `a pattern of 32 captures ...` | The client's matcher has Lua 5.1's limit of 32 captures: a 32-capture pattern checks without raising, the client refuses 33 with `too many captures`, and SchemaKit refuses that pattern at the calling line. |
| `number bounds in failures are printed by the client's %.14g ...` | Each bound phrase (`number >= 0.1`, `number <= 1e+15`, `number <= 9.007199254741e+15`, `number >= -0.5`, `number <= 0.33333333333333`, `integer <= 100`) is exactly what the client's `string.format` prints, with rule `min` or `max` and found `smaller number` or `larger number`. |
| `string bounds count the bytes of the client's UTF-8 text ...` | `Épée` (four characters, six bytes) fails `max = 4` as `string of length 6` and passes `min = 5`; the client's `0/0` is found as `NaN`, `math.huge` under `integer` as `infinite number`, and an enum phrase doubles `|` so no chat escape survives. |
| `GetBuildInfo's version, build, date and interface ...` | The first four answers of the real `GetBuildInfo()` match a schema of their shapes (`^%d+%.%d+%.%d+$`, digits, a date, an integer interface) through `Check` and `Assert`; a bound the interface fails is reported as `max`, `integer <= 9999` (every promised client's interface number has five digits or more), `larger number`, and no failure field contains the interface number. The log gives the answers. |
| `C_Spell.GetSpellInfo(6603) matches an open spell info schema ...` | The client's spell info table passes an open schema of its documented fields, and a closed schema naming only `name` and `spellID` refuses one of the client's other fields with rule `unknown`, the path being that field's name. The log gives the table's field names and the field refused. |
| `Apply copies C_Spell.GetSpellInfo(6603) ...` | `Apply` returns a new table with the declared default filled in, every field the client put there kept, and the client's table unchanged. |
| `a table schema reads UIParent with rawget ...` | A Frame's `GetName` comes from its metatable, so a field schema that reads with `rawget` finds it missing (`required`, `any value`, `nil`); an open table schema and `any` accept the Frame. |
| `UIParent's userdata handle ...` | The Frame's handle `UIParent[0]` is found as `userdata`, accepted by `any`, kept identical by `Apply`, and as a key shows in a path as `[userdata]` (a Frame as a key as `[table]`), never by value. |
| `a custom check receives UIParent itself ...` | A custom check is called with the Frame itself and accepts it; a plain table is refused with rule `custom`, expected `a Frame`, found `table`. |
| `Check and Assert of a valid nested settings table ...` | After a full collection in a step of its own and one unmeasured cycle, 5000 `Check` and `Assert` pairs of the cookbook's settings table (a map of records holding arrays) move `collectgarbage("count")` by at most 1 KB. |
| `Check of the client's C_Spell.GetSpellInfo(6603) table ...` | The same for 5000 checks of the client's own table. |
| `Check of strings against an anchored pattern ...` | The same for 5000 rounds of a bounded, anchored pattern, a `oneOf` list and an enum. |
| `a Check failing at the root with a fixed phrase ...` | Two failing checks return the same failure table, and 5000 rounds failing with `larger number` and a wrong type (the Frame) allocate nothing. |
| `SchemaKit.number with min above max ...` | Builder errors name this file at the calling line, as the client names it; a Frame is refused as a field node. |
| `a builder called with a colon and Seal called with a dot ...` | Both call-style mistakes are named at the calling line. |
| `Check called on UIParent instead of a schema ...` | The receiver check refuses a real Frame table, and a write to a sealed schema is refused at the writing line; the schema still works. |
| `Assert raises its failure at the calling line ...` | `Assert`'s message, and `level = 2` reporting the line that called the validating function. |
| `an error raised by a custom check propagates unchanged ...` | The custom check's own error reaches the caller of `Check` and of `Assert` with its position in this file untouched. |
| `an optional default that fails its schema ...` | `SchemaKit.optional default.size: expected number, found string` at the calling line. |
| `SetLimits with an unknown limit or a maxDepth above 64 ...` | Both refusals at the calling line, with the ceiling's reason appended, and a call that also held a valid value changes nothing. |
| `the client raises when a secret number meets a number ...` | The hazard SchemaKit guards against, measured: a secret number raises in `<` and in `==` with a number and as a table key, while `type` answers `number` and `== nil` answers `false`. The log holds the client's messages. |
| `a secret number checked against number schemas with min, max and integer ...` | A genuine secret meets no bound: `Check` returns (no "attempt to compare" error escapes) with rule `secret`, found `secret value`, the node's type phrase as expected, and no field holding a secret or the secret's digits. |
| `a secret string, boolean and number are refused ...` | The same for `string` with a pattern and bounds, a `oneOf` list and an enum listing the secret's own text (where a lookup would have raised), `boolean`, `any`, `oneOf` and `optional` with a default. |
| `a custom check is never called with a secret ...` | The custom function runs zero times for a secret string and a secret number, and once for a plain value. |
| `a secret inside a table, an array and a map ...` | Nested secrets are refused at `stats.health`, `[2]` and `byUnit.player` without raising. |
| `Assert with a secret raises at the calling line ...` | The message is a plain string at this file's calling line, `health: expected number, found secret value` (and `name: expected string, found secret value`), holding neither the secret's text nor its digits. |
| `Apply of a secret in a declared field ...` | `Apply` returns `false` with the `secret` failure for a declared field, and keeps a secret in an undeclared field of an open table in the copy, still secret and still a number. |
| `SetLimits refuses a secret maxDepth and a secret defaultArrayMax ...` | Both refusals at the calling line with the messages any other invalid value gets, before a comparison; `GetLimits()` unchanged. |
| `a Check of a secret at the root allocates nothing ...` | 5000 refusals of a secret allocate nothing, `issecretvalue` included. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals
  line other than `34 passed, 0 failed, 0 skipped, 0 timed out (34 tests)`
  (on a Classic client, other than the two totals lines under
  [Per flavour](#per-flavour)).
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_SchemaKit`. Every error the suite
  provokes is caught by the test itself; an "attempt to compare" error from
  SchemaKit would mean a secret reached a comparison.
- `for 17 accepted patterns ...` failing: the client's `string.find` answers a
  pattern differently from Lua 5.1, or raises where the validator accepted the
  pattern. The log line of that pattern shows the client's answers.
- `7 malformed patterns ...` failing on `expected boolean true to be boolean
  false`: the client's matcher accepts a pattern Lua 5.1 refuses, so
  SchemaKit is stricter than the client; send the log.
- A number-phrase test failing: the client's `%.14g` prints differently.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `GetLimits answers a fresh table ...` failing on a limit value: another
  enabled addon changed SchemaKit's shared limits.
- `the installed SchemaKit carries the revision ...` failing: another enabled
  addon embeds a different SchemaKit copy.
- `the client raises when a secret number meets a number ...` failing: the
  client's secret values behave differently from the facts
  `docs/EMBEDDING.md` records; send the log lines.
- A `schemaKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (the session's limits, the
   client's answer to every pattern and subject, the client's own matcher
   messages, the `GetBuildInfo` answers, the spell info field names, the five
   measured memory deltas, the client's messages for the secret hazards, and
   every error message with its path) and the client facts. Lua shortens a
   long file path from the left, so a logged message may start with `...`;
   the tests compare only the `SchemaKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
