# Expected result: `/mct run optionsKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package optionsKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package optionsKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package optionsKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. Run it out of combat, logged in with a character (the
profile tests read its name and realm). The lines below are Retail's;
[Per flavour](#per-flavour) gives the two Classic clients.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for optionsKit. Type /mct run optionsKit to run them; /mct help lists every command.
```

## After `/mct run optionsKit`

Within about two seconds, exactly these lines, in this order (`PASS` is
green in the client). Nothing waits on the clock; the four allocation
measurements each run a full garbage collection first, which can make the
client stutter for a moment:

```text
MoltenCodes Test: running optionsKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS optionsKit.facade: Registry:Get('optionsKit', 1) is the OptionsKit facade with API 1, Define, Get, Undefine, ProfileOptions, MAX_OPTIONS 1024, MAX_DEPTH 8, UNBOUNDED and a Tree prototype with its ten methods
MoltenCodes Test: PASS optionsKit.facade: the installed OptionsKit carries the revision of the committed manifest
MoltenCodes Test: PASS optionsKit.facade: the host facilities OptionsKit finds at call time are present: SettingsKit API 1 through Registry:Find, and UnitName('player') and GetRealmName() as plain non-empty strings
MoltenCodes Test: PASS optionsKit.cvar: a toggle whose get and set call C_CVar on chatBubbles reads the client's value, and each Set changes the CVar before it returns and fires OnChange while GetCVar already answers the new value
MoltenCodes Test: PASS optionsKit.cvar: a validate refusal returns false with its message and a string '1' raises at OptionsKitSuite.lua:<line> as expected boolean, and neither reaches C_CVar.SetCVar
MoltenCodes Test: PASS optionsKit.cvar: a disabled predicate and a desc function that read chatBubbles follow a change made through the tree: IsDisabled flips and Describe rewrites the description
MoltenCodes Test: PASS optionsKit.database: a range bound to profile.chat.scale in a real SettingsKit database reads its default 1, Set stores 1.25 in the in-memory table's default profile, and Reset clears it and answers 1 again, each with OnChange
MoltenCodes Test: PASS optionsKit.database: an input bound to char.note stores its text under the key '<UnitName> - <GetRealmName>' the client answers, and Reset brings back the default empty text
MoltenCodes Test: PASS optionsKit.database: with a SettingsKit field narrower than the option, Validate answers SettingsKit's own message and Set raises it at OptionsKitSuite.lua:<line> after 'refused by the database', storing nothing
MoltenCodes Test: PASS optionsKit.profiles: ProfileOptions offers the character profile '<UnitName> - <GetRealmName>' beside the database's default profile, and Describe fills the group's and the options' desc functions with the current profile's name
MoltenCodes Test: PASS optionsKit.profiles: Set of profiles.current to the character profile switches the database, which records the choice under the same key, fires OnChange once, and a bound option reads the new profile at once
MoltenCodes Test: PASS optionsKit.profiles: profiles.new creates and switches to a typed profile with OnChange for profiles.current then profiles.new, and answers a blank or an over-long name with a message instead of raising
MoltenCodes Test: PASS optionsKit.profiles: copy and delete stay disabled until their select names another profile, Execute of copy before that raises at OptionsKitSuite.lua:<line>, copying brings the other profile's bound value and deleting removes the profile
MoltenCodes Test: PASS optionsKit.profiles: a switch made directly on the database reaches the tree's OnChange as profiles.current with the new name, and after Undefine the database's switches reach the tree no more
MoltenCodes Test: PASS optionsKit.clientLua: Validate of three inputs with a pattern agrees with the client's own string.find on empty, ASCII, UTF-8, colour-escaped and control-byte text
MoltenCodes Test: PASS optionsKit.clientLua: Validate answers SchemaKit's phrases as the client prints them: range bounds 2 and 0.33333333333333, a select's sorted keys, a multiselect key, a colour's nested field and a toggle's type
MoltenCodes Test: PASS optionsKit.allocation: Get and Set of a range with validate, a toggle, a select and a colour through getters, with an OnChange listener connected, allocate nothing over 5000 cycles
MoltenCodes Test: PASS optionsKit.allocation: Get and Set of a range bound to the real SettingsKit database, after its first write, allocate nothing over 5000 cycles
MoltenCodes Test: PASS optionsKit.allocation: Walk, Validate of a valid value, IsDisabled and IsHidden with predicates on the option and its group allocate nothing over 5000 cycles
MoltenCodes Test: PASS optionsKit.errors: Define refuses a misspelt field, a min above max, a root that is not a group and a bind without a database at OptionsKitSuite.lua:<line>, naming the field by its path, and registers nothing
MoltenCodes Test: PASS optionsKit.errors: tree methods refuse an unknown path, a group as a value, a value out of range, Reset of an option without a database, Execute of a range and UIParent as the tree at OptionsKitSuite.lua:<line>
MoltenCodes Test: PASS optionsKit.errors: Describe raises at OptionsKitSuite.lua:<line> when a desc function returns no string, and an error raised by a getter reaches the caller of Get unchanged, from the getter's own line
MoltenCodes Test: PASS optionsKit.errors: a second Define of one addon name raises at OptionsKitSuite.lua:<line>, Undefine answers true then false, and the old handle refuses every method as an undefined tree
MoltenCodes Test: PASS optionsKit.secrets: Set of a secret true on the chatBubbles toggle raises at OptionsKitSuite.lua:<line> before the setter runs, Validate answers secret value, and the CVar is unchanged
MoltenCodes Test: PASS optionsKit.secrets: a secret path to Get and Set, and a secret addon name to Get and Define, are refused at OptionsKitSuite.lua:<line> before they index anything
MoltenCodes Test: PASS optionsKit.secrets: Get and Describe pass a getter's secret through untouched, at the top and inside a colour table, and a desc function's secret string becomes the description
MoltenCodes Test: PASS optionsKit.secrets: a secret true from disabled and hidden predicates counts as false in IsDisabled, IsHidden and Describe, and a secret true from validate refuses the value as refused by validate
MoltenCodes Test: PASS optionsKit.secrets: Define refuses a secret disabled field and a secret maxDepth, and ProfileOptions a secret options.name, at OptionsKitSuite.lua:<line>
MoltenCodes Test: PASS optionsKit.secrets: a colour holding a secret red is refused by the schema: Set raises tint.r expected number, found secret value at OptionsKitSuite.lua:<line> and Validate answers the same without the prefix
MoltenCodes Test: optionsKit: 29 passed, 0 failed, 0 skipped, 0 timed out (29 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

- The **chat bubbles** option (`chatBubbles` CVar, Interface options) changes
  during the three `optionsKit.cvar` tests: each flips it through the tree
  and back, and the After hook puts back the value it had before the test if
  a test stopped halfway. Chat bubbles already on screen may appear or vanish
  for a frame. The `chatBubbles` value after the run is the value before it.
- Nothing else is visible: no frame is drawn, no sound plays, no chat line
  other than the harness's appears and no request goes to the server.

## What stays for the session

- **`OptionsKitClientTestDB`**, a global table. SettingsKit opens a database
  over a global name and has no way to close one, so the first test that
  needs the database opens it once for the session and every later test
  reuses it. No addon lists the name under `## SavedVariables` (this addon
  declares none), so the client never writes it to disk and it is gone after
  `/reload`: it is an in-memory table. The After hook of every suite empties
  it with `db:ResetDatabase()` after each test, so between tests and after
  the run it holds only the empty layout SettingsKit creates, on the
  `Default` profile. The name deliberately does not start with
  `MoltenCodes`, so the Registry suite's check of the framework's globals is
  not affected when both run in one session. With EventKit loaded,
  SettingsKit connects the database to `PLAYER_LOGOUT` for compaction; that
  compaction only touches this in-memory table.
- Nothing else. Every tree a test defines is undefined by the After hook,
  which disconnects its `OnChange` listeners and its profile group's
  database connections. OptionsKit keeps no package-wide limits, and the
  SettingsKit limits are only read. Nothing is written to a saved variable
  other than the harness's own results.

## Expected skips

None on Retail 12.1; [Per flavour](#per-flavour) gives the Classic clients.

### On a client without secret values

The 6 `optionsKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine
secret out of combat without side effects: the client's own API
documentation (`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these 6 lines instead, and the totals line
reads `23 passed, 0 failed, 6 skipped, 0 timed out (29 tests)`:

```text
MoltenCodes Test: SKIP optionsKit.secrets: Set of a secret true on the chatBubbles toggle raises at OptionsKitSuite.lua:<line> before the setter runs, Validate answers secret value, and the CVar is unchanged -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP optionsKit.secrets: a secret path to Get and Set, and a secret addon name to Get and Define, are refused at OptionsKitSuite.lua:<line> before they index anything -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP optionsKit.secrets: Get and Describe pass a getter's secret through untouched, at the top and inside a colour table, and a desc function's secret string becomes the description -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP optionsKit.secrets: a secret true from disabled and hidden predicates counts as false in IsDisabled, IsHidden and Describe, and a secret true from validate refuses the value as refused by validate -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP optionsKit.secrets: Define refuses a secret disabled field and a secret maxDepth, and ProfileOptions a secret options.name, at OptionsKitSuite.lua:<line> -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP optionsKit.secrets: a colour holding a secret red is refused by the schema: Set raises tint.r expected number, found secret value at OptionsKitSuite.lua:<line> and Validate answers the same without the prefix -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### A client that does not know the player

The tests that read `UnitName("player")` and `GetRealmName()` (the `char`
bind and the first two profile tests) end as skipped with
`UnitName('player') or GetRealmName() answered no plain name` when the client
answers either with nothing, an empty string or a secret. After login it
always knows the player, so a `SKIP` there is unexpected.

## Per flavour

The suite reads only what all three promised clients have: `C_CVar.GetCVar`
and `C_CVar.SetCVar`, `UnitName` and `GetRealmName` (documented by the apiKit
metadata for `retail`, `classic-era` and `classic-mop`), `UIParent`, and the
`chatBubbles` CVar behind the "Chat Bubbles" interface option, which every
flavour has (the metadata does not list CVars). The metadata of all three
flavours also documents `issecretvalue` and `secretwrap`. No test depends on
the flavour itself.

### Retail (12.1)

The lines above: `MoltenCodes Test: optionsKit: 29 passed, 0 failed, 0 skipped, 0 timed out (29 tests)`,
with no `SKIP` line.

### Classic Era (1.15) and Mists of Pandaria Classic (5.5)

The `running` line and every test line are the same as Retail's, in the same
order. Whether the six `optionsKit.secrets` tests run depends on answers only the
running client gives, measured when the suite loads: whether it has the
global functions `issecretvalue` and `secretwrap` (both Classic flavours
document them), and whether it actually makes secrets, which
`Harness:CanMakeSecrets()` measures once as
`issecretvalue(secretwrap(true)) == true`.

- The client makes secrets: the totals line is Retail's,
  `MoltenCodes Test: optionsKit: 29 passed, 0 failed, 0 skipped, 0 timed out (29 tests)`.
- The client has both functions but makes no secrets: the six tests print
  these lines, and the totals line is
  `MoltenCodes Test: optionsKit: 23 passed, 0 failed, 6 skipped, 0 timed out (29 tests)`:

```text
MoltenCodes Test: SKIP optionsKit.secrets: Set of a secret true on the chatBubbles toggle raises at OptionsKitSuite.lua:<line> before the setter runs, Validate answers secret value, and the CVar is unchanged -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP optionsKit.secrets: a secret path to Get and Set, and a secret addon name to Get and Define, are refused at OptionsKitSuite.lua:<line> before they index anything -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP optionsKit.secrets: Get and Describe pass a getter's secret through untouched, at the top and inside a colour table, and a desc function's secret string becomes the description -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP optionsKit.secrets: a secret true from disabled and hidden predicates counts as false in IsDisabled, IsHidden and Describe, and a secret true from validate refuses the value as refused by validate -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP optionsKit.secrets: Define refuses a secret disabled field and a secret maxDepth, and ProfileOptions a secret options.name, at OptionsKitSuite.lua:<line> -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP optionsKit.secrets: a colour holding a secret red is refused by the schema: Set raises tint.r expected number, found secret value at OptionsKitSuite.lua:<line> and Validate answers the same without the prefix -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

- The client lacks either function: the six lines listed under
  [On a client without secret values](#on-a-client-without-secret-values)
  are `SKIP`, with the same totals line
  `MoltenCodes Test: optionsKit: 23 passed, 0 failed, 6 skipped, 0 timed out (29 tests)`.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('optionsKit', 1) is the OptionsKit facade ...` | The facade the client loaded is API 1 with `Define`, `Get`, `Undefine`, `ProfileOptions`, `MAX_OPTIONS` 1024, `MAX_DEPTH` 8, the `UNBOUNDED` sentinel and a `Tree` prototype carrying `Get`, `Set`, `Validate`, `Reset`, `Execute`, `IsDisabled`, `IsHidden`, `Walk`, `Describe` and `OnChange`. |
| `the installed OptionsKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's (5), not an older or newer embedded copy. |
| `the host facilities OptionsKit finds at call time ...` | `Registry:Find("settingsKit", 1)` finds the SettingsKit the bundle ships (the same table the suite uses), and the client answers `UnitName("player")` and `GetRealmName()` with plain non-empty strings. The log gives SettingsKit's revision, the character profile `"<name> - <realm>"` and whether `issecretvalue` and `secretwrap` exist. |
| `a toggle whose get and set call C_CVar on chatBubbles ...` | A getter and a setter that call the client work through the tree: `Get` answers the CVar, each `Set` (to the other value, then back) returns `true` with the CVar already changed, and `OnChange` fires once per `Set`, with the path and value, while `C_CVar.GetCVar` already answers the new value. |
| `a validate refusal returns false with its message ...` | A `validate` refusal comes back as `false` and its message; the string `"1"` raises `OptionsKit.Tree:Set bubbles: expected boolean, found string` at this file's calling line and `Validate` answers the same phrase; `C_CVar.SetCVar` is never called and `OnChange` never fires. |
| `a disabled predicate and a desc function that read chatBubbles ...` | Predicates and `desc` functions run at every call: after each `Set` of the CVar through the tree, `IsDisabled` and the described `disabled` follow it, and `Describe` calls the `desc` function with the option's `info` (`size follows chat bubbles, now shown` / `... now hidden`). The log gives both descriptions. |
| `a range bound to profile.chat.scale in a real SettingsKit database ...` | With the real SettingsKit (the Busted specs use a stand-in): the schema default `1` is read through the database's views, `Set(1.25)` writes into the in-memory table at `profiles.Default.chat.scale` and reads back through `db.profile`, `Describe` shows the value and the bind path, and `Reset` clears the stored value so the default answers again, with one `OnChange` for each. |
| `an input bound to char.note ...` | The `char` scope works on the client's identity: the text lands in the in-memory table under `char["<UnitName> - <GetRealmName>"]`, the key the test builds from the same client functions, and `Reset` returns the default `""`. The log gives the key. |
| `with a SettingsKit field narrower than the option ...` | Where the database's schema (0 to 3) is narrower than the option's (0 to 10), `Validate(5)` answers SettingsKit's own message and `Set(5)` raises `OptionsKit.Tree:Set width refused by the database: SettingsKit (OptionsKitClientTestDB) profile.chat.width: expected number <= 3, found larger number` at this file's calling line, storing nothing and firing nothing; `2` is accepted. |
| `ProfileOptions offers the character profile ...` | The per-character choice is built from the real `UnitName` and `GetRealmName`: `Describe` lists it beside `Default` in `profiles.current`'s values; the group's `desc` and those of `current` and `reset` are filled with `"Default"`; `new` reads `""` with usage `<profile name>`; the copy source has no choice and `copy` and `delete` are disabled. The log gives the name offered. |
| `Set of profiles.current to the character profile ...` | Choosing it switches the database, fires `OnChange` exactly once (`profiles.current`, the name), and SettingsKit records the choice in the in-memory table's `profileKeys` under the character key it read at `Open`, which must equal the name OptionsKit offered; the bound `scale` reads the new profile's default at once, and the group's `desc` names the new profile. |
| `profiles.new creates and switches to a typed profile ...` | Creating through `new` switches to the profile and fires `OnChange` twice, `profiles.current` then `profiles.new`; a blank name and a name one byte over `maxProfileNameLength` come back as messages from `Validate` and `Set` without raising or switching. The log gives the session's `maxProfileNameLength`. |
| `copy and delete stay disabled until their select names another profile ...` | `copy` is disabled until `copySource` names another profile, and `Execute` before that raises `OptionsKit.Tree:Execute profiles.copy needs "profiles.copySource" to be set first` at this file's calling line (through the group's own closure); copying brings `Default`'s bound `1.75` into the new profile with one `OnChange`; deleting the chosen profile removes it, clears `deleteTarget`, disables `delete` again and fires one `OnChange`. |
| `a switch made directly on the database ...` | `db:SetProfile` called outside the tree reaches the tree's `OnChange` as (`profiles.current`, the new name); after `Undefine`, the database's switches reach the tree no more. |
| `Validate of three inputs with a pattern ...` | For `^[%w ]*$`, `^%a+$` and `^[^|]*$`, `Validate` answers exactly what the client's own `string.find` answers on empty, ASCII, UTF-8 (`Épée`), colour-escaped and control-byte text. The log gives the client's answers per pattern. |
| `Validate answers SchemaKit's phrases as the client prints them ...` | The messages a renderer shows, as the client formats them: `expected number <= 2, found larger number`, `expected number >= 0.33333333333333, found smaller number`, `expected one of "BOTTOM", "CENTER", "TOP", found unlisted string`, `YELL: expected key one of "PARTY", "SAY", found unlisted string`, `r: expected number <= 1, found larger number` and `expected boolean, found number`; nothing is written. |
| `Get and Set of a range with validate, a toggle, a select and a colour ...` | After a full collection in a step of its own and one unmeasured cycle, 5000 rounds of `Get` and `Set` of four getter options, with a `validate` and an `OnChange` listener, move `collectgarbage("count")` by at most 1 KB. |
| `Get and Set of a range bound to the real SettingsKit database ...` | The same for 5000 rounds of `Get` and `Set` of an option bound to the real database, after its first write created the stored key. |
| `Walk, Validate of a valid value, IsDisabled and IsHidden ...` | The same for 5000 `Walk`s of five options (the visitor counts every visit) and 5000 rounds of `Validate`, `IsDisabled` and `IsHidden` with predicates on the option and its group. |
| `Define refuses a misspelt field, a min above max ...` | Each `Define` error names this file at the calling line and the field by its path (`tree.args.size contains unknown field "<the misspelt name>" for type "range"` for a misspelling of `width`, `tree.args.size.min must not be greater than max`, `tree.type must be "group" at the root`, `tree.args.size.bind needs a SettingsKit database passed as options.db`), and no tree is registered. |
| `tree methods refuse an unknown path ...` | `Get` of an unknown path, `Set` of a group, `Set` out of range, `Reset` of an option with `get`/`set`, `Execute` of a range, and a tree method called on `UIParent` all raise at this file's calling line with the documented messages; the tree still works. |
| `Describe raises ... when a desc function returns no string ...` | `OptionsKit.Tree:Describe desc function of "size" returned no string` at the calling line; an error raised by a getter reaches the caller of `Get` unchanged, naming the getter's own line in this file. |
| `a second Define of one addon name raises ...` | `OptionsKit:Define "MoltenCodesTest_OptionsKit" already has a tree; Undefine it first` at the calling line; `Undefine` answers `true` then `false`; the old handle's `Get` and `Walk` raise `... cannot be called on an undefined tree`. |
| `Set of a secret true on the chatBubbles toggle ...` | A genuine secret boolean is refused by `Set` at this file's calling line (`OptionsKit.Tree:Set value must not be a secret value`) before the setter runs, `Validate` answers `false, "secret value"`, and the CVar is unchanged. No "attempt to perform boolean test" error escapes. |
| `a secret path to Get and Set, and a secret addon name ...` | `OptionsKit.Tree:Get path must not be a secret value`, `OptionsKit.Tree:Set path must not be a secret value`, `OptionsKit:Get addonName must not be a secret value` and `OptionsKit:Define addonName must not be a secret value`, each at the calling line, where using the secret as a table key would have raised inside OptionsKit. |
| `Get and Describe pass a getter's secret through untouched ...` | A getter's secret boolean comes back from `Get` and in `Describe`'s `value` still secret and still a boolean; a colour table holding a secret red is copied with the secret passed through (the copy is a new table, `r` still a secret number); a `desc` function's secret string is the node's `desc`, still secret. Checked only with `issecretvalue` and `type`. |
| `a secret true from disabled and hidden predicates ...` | A predicate answering a secret `true` counts as `false` in `IsDisabled`, `IsHidden` and `Describe`, on the option and on its group, without raising; a `validate` answering a secret `true` refuses with `refused by validate` in `Set` and `Validate`, and the setter never runs. |
| `Define refuses a secret disabled field and a secret maxDepth ...` | `OptionsKit:Define tree.args.flag.disabled must not be a secret value`, `OptionsKit:Define options.maxDepth must not be a secret value` and `OptionsKit:ProfileOptions options.name must not be a secret value`, each at the calling line; no tree is registered. |
| `a colour holding a secret red is refused by the schema ...` | `Set` raises `OptionsKit.Tree:Set tint.r: expected number, found secret value` at the calling line and `Validate` answers `r: expected number, found secret value`; the setter never runs. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals
  line other than `29 passed, 0 failed, 0 skipped, 0 timed out (29 tests)`
  (on a Classic client, other than the two totals lines under
  [Per flavour](#per-flavour)).
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_OptionsKit`. Every error the suite
  provokes is caught by the test itself; an "attempt to compare" or "attempt
  to perform boolean test" error from OptionsKit would mean a secret reached
  a comparison or a truth test.
- `chatBubbles` not back to what it was after the run.
- `Registry:Find('settingsKit', 1) found nothing`: the bundle was built
  without SettingsKit; every database, profile and bound allocation test
  then fails with that message.
- `Set of profiles.current to the character profile ...` failing on
  `profileKeys`: OptionsKit and SettingsKit build the character key
  differently on this client (for example for a realm name with spaces or
  non-ASCII letters); the log of the first profile test gives the name.
- `Validate of three inputs with a pattern ...` failing: the input schema
  answers a subject differently from the client's `string.find`; the log line
  of that pattern shows the client's answers.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled; for the bound test, whether the SettingsKit test
  addon ran in the same session.
- `the installed OptionsKit carries the revision ...` failing: another
  enabled addon embeds a different OptionsKit copy.
- An `optionsKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (SettingsKit's revision, the
   character profile name, `chatBubbles` before the test, the two
   descriptions, the client's pattern answers, every `Validate` message, the
   four measured memory deltas and every error message with its path) and
   the client facts. Lua shortens a long file path from the left, so a
   logged message may start with `...`; the tests compare only the
   `OptionsKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
