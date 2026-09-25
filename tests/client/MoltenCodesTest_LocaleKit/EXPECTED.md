# Expected result: `/mct run localeKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package localeKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package localeKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package localeKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. Run it out of combat. The lines below are Retail's;
[Per flavour](#per-flavour) gives the two Classic clients. The lines below are for an English client (`GetLocale()`
answers `enUS` or `enGB`); on any other locale the same lines are expected, and
the logs name that locale instead.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for localeKit. Type /mct run localeKit to run them; /mct help lists every command.
```

## After `/mct run localeKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green and
`SKIP` yellow in the client). The four allocation tests each run a full garbage
collection first, which can make the client stutter for a moment:

```text
MoltenCodes Test: running localeKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS localeKit.facade: Registry:Get('localeKit', 1) is the LocaleKit facade with API 1, every documented method and UNBOUNDED
MoltenCodes Test: PASS localeKit.facade: the installed LocaleKit carries the revision of the committed manifest
MoltenCodes Test: PASS localeKit.clientLocale: NewLocale needs the locale the client's own GetLocale() names (enGB folded to enUS) and returns nil for any other, enGB included
MoltenCodes Test: PASS localeKit.clientLocale: the read table holds the client locale's text over the default, the default's text for the rest, and nothing from another locale
MoltenCodes Test: PASS localeKit.clientLocale: a default file for the client's own locale keeps a translation that loaded first, and a later client-locale file still overwrites
MoltenCodes Test: PASS localeKit.clientLocale: SetLocaleOverride to another locale registers new addons under it, keeps earlier addons on theirs, and nil restores the client's locale
MoltenCodes Test: PASS localeKit.clientLocale: SetLocaleOverride('enGB') registers new addons under enUS, so an enGB file is never needed
MoltenCodes Test: PASS localeKit.missing: report mode returns a missing key as itself and reports it once through the client's error handler, naming the client locale
MoltenCodes Test: PASS localeKit.missing: silent mode returns a missing key as itself without a report, and raw mode returns nil and records nothing
MoltenCodes Test: PASS localeKit.missing: MissingKeys lists the keys read but never defined, sorted, and drops a key once a later file defines it
MoltenCodes Test: PASS localeKit.missing: past maxMissingKeys a missing key still reads as itself, is not recorded, and the cap is reported once
MoltenCodes Test: PASS localeKit.format: Format reorders, repeats and mixes indexed and sequential specifiers on the client's string library
MoltenCodes Test: PASS localeKit.format: Format applies flags, width and precision exactly as the client's own string.format does
MoltenCodes Test: PASS localeKit.format: Format gives the text the client's own string.format gives for fully indexed templates, where the client accepts them
MoltenCodes Test: PASS localeKit.format: a width over two digits is refused as an invalid specifier at LocaleKitSuite.lua's calling line, because the client's string.format refuses it
MoltenCodes Test: PASS localeKit.errors: NewLocale with a locale that is not a client locale code names LocaleKitSuite.lua at the calling line
MoltenCodes Test: PASS localeKit.errors: assigning a number through a write proxy names LocaleKitSuite.lua at the assignment line
MoltenCodes Test: PASS localeKit.errors: GetLocale for an addon that registered nothing names LocaleKitSuite.lua at the calling line
MoltenCodes Test: PASS localeKit.errors: a later GetLocale naming another missing mode names LocaleKitSuite.lua at the calling line and keeps the first mode
MoltenCodes Test: PASS localeKit.errors: a Format template needing a missing argument names LocaleKitSuite.lua through the client's string.gsub
MoltenCodes Test: PASS localeKit.errors: a Format template with an unsupported specifier names LocaleKitSuite.lua through the client's string.gsub
MoltenCodes Test: PASS localeKit.allocation: reading a defined key 10000 times allocates nothing (allocation guard)
MoltenCodes Test: PASS localeKit.allocation: reading a missing key 10000 times after its first read allocates nothing (allocation guard)
MoltenCodes Test: PASS localeKit.allocation: reading a key past maxMissingKeys 10000 times allocates nothing, though each read runs __index (allocation guard)
MoltenCodes Test: PASS localeKit.allocation: repeating one indexed Format 10000 times allocates no table or closure (allocation guard)
MoltenCodes Test: PASS localeKit.secrets: Format refuses a genuine secret argument at LocaleKitSuite.lua's calling line
MoltenCodes Test: PASS localeKit.secrets: Format refuses a genuine secret template at LocaleKitSuite.lua's calling line before string.gsub sees it
MoltenCodes Test: PASS localeKit.secrets: GetLocale refuses a genuine secret maxMissingKeys at LocaleKitSuite.lua's calling line and fixes neither the limit nor the mode
MoltenCodes Test: PASS localeKit.secrets: a read table indexed with a genuine secret key raises the client's refusal at LocaleKitSuite.lua's calling line, before __index runs, and stores, records and reports nothing
MoltenCodes Test: SKIP localeKit.session: nothing LocaleKit holds survives /reload, and translation files register again -- a /reload ends the run; the Busted upgrade and bootstrap specs cover a fresh load
MoltenCodes Test: SKIP localeKit.session: without the client's geterrorhandler a missing-key report is printed -- the client always has geterrorhandler, and replacing that global would taint it for Blizzard code
MoltenCodes Test: SKIP localeKit.session: a newer LocaleKit embedded by another addon upgrades read tables, modes, missing keys and the override in place -- needs a second LocaleKit copy loaded by another addon; the Busted upgrade specs cover it
MoltenCodes Test: localeKit: 29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The three `localeKit.session` skips are expected on every client: they name
behaviour a single run cannot observe, and the reason says where it is
covered instead.

Running it again in the same session prints the same lines: every test
registers its own probe addon under a fresh name, so a second run meets none
of the first run's records.

### Visible side effects

None. Nothing is shown, no frame is created, and no setting, CVar, saved
variable or global is written. The client's error handler is replaced for the
length of one synchronous call in four tests and put back at once. No error
window opens: the missing-key reports those tests provoke go to the test's own
collector.

### What remains for the session

LocaleKit keeps every addon it registered until `/reload`, and has no way to
forget one. Each run leaves 28 small probe records (on a client with secret values; 24 without) named
`mctLocaleKit<Label><n>` (for example `mctLocaleKitReport14`), with their read
tables and a few recorded missing keys. The locale override is back to "none"
after the run: the two tests that set one clear it themselves, and the After
hook of `localeKit.clientLocale` clears it again whatever the outcome.

### The indexed-specifier test may be a skip

`Format gives the text the client's own string.format gives ...` first asks
the client's own `string.format` to format four fully indexed templates
(`%2$s %1$s`, `%2$d items belong to %1$s`, `%1$s, %1$s!` and
`%3$.2f %1$s %2$05d`) and logs what it answered. For each one the client
accepts, `LocaleKit:Format` must give the same text. LocaleKit never hands an
indexed specifier to `string.format` (it rewrites `%2$s` to `%s` and picks the
argument itself), so it does not depend on the answer; the test records it.
Retail 12.1.0 b69933 accepts positional specifiers (`%2$s %1$s` and
`%3$.2f %1$s %2$05d` were measured), so on Retail 12.1 the test passes. A
client whose `string.format` refuses all four prints this line instead, and
the totals read `28 passed, 0 failed, 4 skipped`:

```text
MoltenCodes Test: SKIP localeKit.format: Format gives the text the client's own string.format gives for fully indexed templates, where the client accepts them -- the client's string.format refuses indexed specifiers, so there is nothing to compare; LocaleKit:Format does not need them
```

That skip is not a failure of LocaleKit, but it is not expected on Retail
12.1; send the logs either way.

### The secret-key test

`a read table indexed with a genuine secret key ...` pins a measured fact of
Retail 12.1.0 b69933: the client refuses a secret used as a table key to read
at the index itself, before the table's `__index` metamethod runs, even on a
table that has one. `strings[secretKey]` on a read table therefore raises the
client's error, `attempted to index a table that cannot be indexed with
secret keys`, at the line of the index in this file, and LocaleKit never sees
the key: nothing is stored, recorded in `MissingKeys` or reported.
`docs/API.md` ("Missing keys") documents this. Should a later client let the
read reach `__index`, the test fails at `readSucceeded`; send the whole line
and the log, because the documentation would then need to change.

### On a client without secret values

The four `localeKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints the four tests as
`SKIP ... -- the client has no issecretvalue and secretwrap; the secret path was not exercised`.

### When another addon set a locale override

LocaleKit's override is shared by every addon in the session. When another
addon has set one, the tests that depend on the client's own locale cannot
tell it apart from the override, and the two that set one would clear it, so
they end as
`SKIP ... -- another addon set a LocaleKit locale override in this session`
(with `; this test would clear it` for the two override tests). Up to seven
tests can skip this way. Disable that addon and run again.

## Per flavour

The suite reads only what all three promised clients have: `GetLocale`
(documented by the apiKit metadata for `retail`, `classic-era` and
`classic-mop`), the core globals `geterrorhandler` and `seterrorhandler`,
and Lua 5.1's string library. The metadata of all three flavours also
documents `issecretvalue` and `secretwrap`. No test depends on the flavour
itself; three answers only the running client gives decide the outcome.

### Retail (12.1)

The lines above: `MoltenCodes Test: localeKit: 29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)`,
with the three `localeKit.session` skips and no other.

### Classic Era (1.15) and Mists of Pandaria Classic (5.5)

The `running` line, every test line and the three `localeKit.session` skips
are the same as Retail's, in the same order, when the client answers as
Retail 12.1 does. These answers cannot be read from the metadata, so each
variant is given:

- **Secret values.** Whether the four `localeKit.secrets` tests run depends on answers only the
running client gives, measured when the suite loads: whether it has the
global functions `issecretvalue` and `secretwrap` (both Classic flavours
document them), and whether it actually makes secrets, which
`Harness:CanMakeSecrets()` measures once as
`issecretvalue(secretwrap(true)) == true`. When it makes
  secrets, the four tests run. When it has both functions but makes no
  secrets, they print these lines in place of their `PASS` lines:

```text
MoltenCodes Test: SKIP localeKit.secrets: Format refuses a genuine secret argument at LocaleKitSuite.lua's calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP localeKit.secrets: Format refuses a genuine secret template at LocaleKitSuite.lua's calling line before string.gsub sees it -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP localeKit.secrets: GetLocale refuses a genuine secret maxMissingKeys at LocaleKitSuite.lua's calling line and fixes neither the limit nor the mode -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP localeKit.secrets: a read table indexed with a genuine secret key raises the client's refusal at LocaleKitSuite.lua's calling line, before __index runs, and stores, records and reports nothing -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

  When it lacks either function, they print these lines instead:

```text
MoltenCodes Test: SKIP localeKit.secrets: Format refuses a genuine secret argument at LocaleKitSuite.lua's calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP localeKit.secrets: Format refuses a genuine secret template at LocaleKitSuite.lua's calling line before string.gsub sees it -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP localeKit.secrets: GetLocale refuses a genuine secret maxMissingKeys at LocaleKitSuite.lua's calling line and fixes neither the limit nor the mode -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP localeKit.secrets: a read table indexed with a genuine secret key raises the client's refusal at LocaleKitSuite.lua's calling line, before __index runs, and stores, records and reports nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

- **Indexed specifiers.** Whether the client's `string.format` accepts `%2$s`
  (see [The indexed-specifier test may be a skip](#the-indexed-specifier-test-may-be-a-skip)).
- **Secret keys.** The secret-key test pins a fact measured on Retail; a
  client that makes secrets but lets a secret key reach `__index` fails it at
  `readSucceeded` (see [The secret-key test](#the-secret-key-test)). That is a
  difference to send back, not an expected outcome.

The totals line is one of these four:

| Secret values | Indexed specifiers | Totals line |
|---|---|---|
| made | accepted | `MoltenCodes Test: localeKit: 29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)` |
| made | refused | `MoltenCodes Test: localeKit: 28 passed, 0 failed, 4 skipped, 0 timed out (32 tests)` |
| not made, or a function absent | accepted | `MoltenCodes Test: localeKit: 25 passed, 0 failed, 7 skipped, 0 timed out (32 tests)` |
| not made, or a function absent | refused | `MoltenCodes Test: localeKit: 24 passed, 0 failed, 8 skipped, 0 timed out (32 tests)` |

`docs/EMBEDDING.md` records that Classic Era 1.15.9 and Mists Classic 5.5.4
expose `issecretvalue`; whether they make secrets, and whether their
`string.format` accepts indexed specifiers, has not been measured yet. Send
the logs whatever the row: the format test logs the client's answer to each
indexed template.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('localeKit', 1) is the LocaleKit facade ...` | The facade the client loaded is API 1 and carries `NewLocale`, `GetLocale`, `MissingKeys`, `Format`, `SetLocaleOverride` and the `UNBOUNDED` sentinel. |
| `the installed LocaleKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `NewLocale needs the locale the client's own GetLocale() names ...` | With the client's real `GetLocale()` (logged), a translation file for that locale (with `enGB` folded to `enUS`) gets a proxy, a file for another locale and an `enGB` file get `nil`, and a default file is needed whatever its locale. |
| `the read table holds the client locale's text over the default ...` | The client locale's text wins over the default, an untranslated key falls back to the default's text, and another locale's file contributes nothing. |
| `a default file for the client's own locale keeps a translation ...` | On a client whose locale is also the default's (the enUS case), a default proxy still never overwrites, and a later client-locale proxy does. |
| `SetLocaleOverride to another locale ...` | An override makes new addons register under it, an addon registered before it keeps the client's locale, and `SetLocaleOverride(nil)` puts new addons back on the client's locale. |
| `SetLocaleOverride('enGB') ...` | An `enGB` override is folded to `enUS`. |
| `report mode returns a missing key as itself ...` | The report reaches the client's error handler (swapped with `seterrorhandler`) exactly once, with the exact documented text naming the client locale; the second read is a plain table read. |
| `silent mode returns a missing key ... raw mode returns nil ...` | Neither mode reports; silent records the key for `MissingKeys`, raw records nothing. |
| `MissingKeys lists the keys read but never defined, sorted ...` | `MissingKeys` sorts with `<` (`Alpha`, `beta`, `zeta`), and a translation file loaded after the read replaces the stored key and drops it from the report. |
| `past maxMissingKeys a missing key still reads as itself ...` | With a limit of 2, the third missing key reads as itself without being stored or recorded, and the cap is reported once with the documented text. |
| `Format reorders, repeats and mixes ...` | Indexed, repeated and mixed specifiers, `%%`, and indexed specifiers with flags and precision give the documented text on the client's `string.gsub` and `string.format`. |
| `Format applies flags, width and precision ...` | A template with `-`, `+`, space, `0`, width and precision gives exactly what the client's own `string.format` gives (logged). |
| `Format gives the text the client's own string.format gives ...` | Whether the client's `string.format` accepts indexed specifiers (logged per template), and that `Format` agrees with it wherever it does. |
| `a width over two digits is refused ...` | The client's `string.format` refuses `%100s` (logged), and `Format` turns that into its documented error at this file's calling line. |
| `NewLocale with a locale that is not a client locale code ...` | The refusal of an all-lower-case locale code names this file at the calling line. |
| `assigning a number through a write proxy ...` | A write-proxy error, raised from the `__newindex` metamethod, names this file at the assignment line. |
| `GetLocale for an addon that registered nothing ...` | The refusal names this file at the calling line. |
| `a later GetLocale naming another missing mode ...` | The refusal names this file at the calling line, and the table keeps its first mode. |
| `a Format template needing a missing argument ...` | A template error raised inside the replacement function, under the client's C `string.gsub`, still names this file at the calling line. |
| `a Format template with an unsupported specifier ...` | The same for `%x`, and the next `Format` works, so the staged arguments were cleared. |
| `reading a defined key 10000 times ...` | After a full collection, 10000 reads move `collectgarbage("count")` by at most 1 KB on the client's own collector. |
| `reading a missing key 10000 times after its first read ...` | The same for a key stored as its own value by its first read. |
| `reading a key past maxMissingKeys 10000 times ...` | The same for a key past the limit, whose every read runs `__index`. |
| `repeating one indexed Format 10000 times ...` | 10000 identical `Format` calls allocate at most 1 KB: no table or closure per call, and the client interns the repeated strings. |
| `Format refuses a genuine secret argument ...` | A secret made by `secretwrap` is refused at this file's calling line with a message that contains no secret, and the next `Format` works. |
| `Format refuses a genuine secret template ...` | A secret template is refused at the calling line before `string.gsub` runs over it. |
| `GetLocale refuses a genuine secret maxMissingKeys ...` | The refusal comes before any comparison (no client error about a secret), and the refused call fixed neither its mode nor a limit: the next call chooses `silent`, and the limit is the default 1024. |
| `a read table indexed with a genuine secret key ...` | The client refuses the secret key at the index, naming this file at the indexing line with `attempted to index a table that cannot be indexed with secret keys`; the collector receives no report, `MissingKeys` stays empty and the defined key still reads (see above). |
| the three `localeKit.session` skips | Registered skips for what a run cannot observe. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line other than the ones described
  above, or a totals line
  other than `29 passed, 0 failed, 3 skipped, 0 timed out (32 tests)` (or one
  of the variants above and under [Per flavour](#per-flavour)).
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest`, `MoltenCodesTest_LocaleKit` or `LocaleKit: missing
  translation`. The missing-key tests provoke reports on purpose, but they
  must reach only the test's own collector.
- A missing-key test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack) keeps
  the handler, and the reports went to it. Disable it and run again.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed LocaleKit carries the revision ...` failing: another enabled
  addon embeds a different LocaleKit copy.
- A `localeKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (what `GetLocale()` answered,
   the missing-key report text, the client's `string.format` answers to the
   flag template, the four indexed templates and `%100s`, the client's own
   error messages with their paths, and the four measured memory deltas) and
   the client facts. Lua shortens a long file path from the left, so a logged
   message may start with `...`; the tests compare only the
   `LocaleKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
