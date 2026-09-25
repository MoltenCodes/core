# Expected result: `/mct run clientKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package clientKit`
for Retail, adding `--flavour-dir _classic_era_` for Classic Era or
`--flavour-dir _classic_` for Mists of Pandaria Classic, and nothing else from
the MoltenCodes framework enabled in the client. Run it out of combat.

ClientKit is almost entirely host probing, so this suite compares every
answer ClientKit gives with the answer the running client gives when asked
directly, and logs both. The logs in the saved results are the real
client's capability table, build facts and shim shapes; they are the main
thing to send back.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for clientKit. Type /mct run clientKit to run them; /mct help lists every command.
```

## After `/mct run clientKit`

Within about a second, exactly these lines, in this order (`PASS` is green
and `SKIP` yellow in the client). The Hearthstone test waits up to five
seconds when the item is not yet in the client's item cache, and the two
allocation tests each run a full garbage collection first, which can make the
client stutter for a moment:

```text
MoltenCodes Test: running clientKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS clientKit.facade: Registry:Get('clientKit', 1) is the ClientKit facade with API 1 and the thirteen documented methods
MoltenCodes Test: PASS clientKit.facade: the installed ClientKit carries the revision of the committed manifest
MoltenCodes Test: PASS clientKit.identity: GetFlavor maps the client's WOW_PROJECT_ID by the documented table, mainline for Retail's 1
MoltenCodes Test: PASS clientKit.identity: every WOW_PROJECT_* constant the client defines has the number ClientKit's literal flavour map uses
MoltenCodes Test: PASS clientKit.identity: GetBuild returns GetBuildInfo's version and build date, and its build string as an integer
MoltenCodes Test: PASS clientKit.identity: GetInterfaceNumber is the fourth value of GetBuildInfo
MoltenCodes Test: PASS clientKit.identity: IsAtLeast is true at and below the client's interface number and false one above it
MoltenCodes Test: PASS clientKit.capabilities: Has answers each of the twelve documented capabilities exactly as a direct probe of the client does
MoltenCodes Test: PASS clientKit.taint: IsSecret answers false for a plain string, a number, nil, a table and UIParent
MoltenCodes Test: PASS clientKit.taint: CanAccessFrame(UIParent) is true and agrees with UIParent's own IsForbidden and CanBeAccessedInContext
MoltenCodes Test: SKIP clientKit.taint: CanAccessFrame answers false for a forbidden frame -- docs/API.md names no forbidden frame an addon can reach out of combat; UIParent's answers are logged by the test above
MoltenCodes Test: PASS clientKit.taint: IsEventValid agrees with C_EventUtils.IsEventValid for known, replaced and made-up events, as booleans
MoltenCodes Test: PASS clientKit.shims: GetAddOnMetadata reads this addon's Version, Author, Notes and X-MoltenCodes-Probe exactly as the client's metadata call does
MoltenCodes Test: PASS clientKit.shims: GetAddOnMetadata answers nil for an X- field this addon's .toc does not have
MoltenCodes Test: PASS clientKit.shims: GetAddOnMetadata of a field the client does not export answers or raises exactly as the client's call does
MoltenCodes Test: PASS clientKit.shims: IsAddOnLoaded answers true, true for this addon and the harness, and false, false for an addon that is not installed
MoltenCodes Test: PASS clientKit.shims: GetSpellInfo(8936) returns a fresh table with the six documented fields, holding what the client's own call gives
MoltenCodes Test: PASS clientKit.shims: GetSpellInfo answers nil for a spell ID the client does not know, as the client's own call does
MoltenCodes Test: PASS clientKit.shims: GetItemInfo(6948) returns the Hearthstone as the documented list the client's call gives, after the item cache fills when cold
MoltenCodes Test: PASS clientKit.manifest: GetManifest of this addon has the title, notes, version and author the client reads, localised title and notes first
MoltenCodes Test: PASS clientKit.manifest: manifest:Get reads X-MoltenCodes-Probe as yes and answers nil for an X- field the .toc lacks
MoltenCodes Test: PASS clientKit.manifest: the manifest's dependencies array lists MoltenCodesTest, the harness this addon depends on
MoltenCodes Test: PASS clientKit.manifest: manifest fields the client's metadata call does not export read as the client answers them, without raising
MoltenCodes Test: PASS clientKit.manifest: GetManifest answers the same table for every spelling of this addon's name, carrying the client's spelling
MoltenCodes Test: PASS clientKit.manifest: GetManifest of an addon the client does not list answers nil and unknown, every time
MoltenCodes Test: PASS clientKit.manifest: writing a manifest field is refused at the calling line, and the manifest has no raw keys and no metatable
MoltenCodes Test: PASS clientKit.manifest: the harness's manifest reads its title through the same path and lists its saved variables as the client exports them
MoltenCodes Test: PASS clientKit.allocation: 5000 rounds of every identity, capability and taint probe and IsAddOnLoaded allocate nothing
MoltenCodes Test: PASS clientKit.allocation: 5000 rounds of a cached GetManifest in two spellings and remembered Get reads allocate nothing
MoltenCodes Test: PASS clientKit.errors: IsAtLeast with a string or NaN names ClientKitSuite.lua at the calling line
MoltenCodes Test: PASS clientKit.errors: Has of an unknown capability raises at the calling line, naming it, instead of answering false
MoltenCodes Test: PASS clientKit.errors: Has with a number names ClientKitSuite.lua at the calling line
MoltenCodes Test: PASS clientKit.errors: CanAccessFrame with a frame's name instead of the frame names ClientKitSuite.lua at the calling line
MoltenCodes Test: PASS clientKit.errors: IsEventValid with nil names ClientKitSuite.lua at the calling line
MoltenCodes Test: PASS clientKit.errors: the four shims refuse an argument of the wrong type at the calling line before asking the client
MoltenCodes Test: PASS clientKit.errors: GetManifest with an addon index names ClientKitSuite.lua at the calling line
MoltenCodes Test: PASS clientKit.errors: manifest:Get refuses a number field, and a forged table carrying the manifest's name, at the calling line
MoltenCodes Test: PASS clientKit.secrets: IsSecret answers true for a genuine secret made by secretwrap
MoltenCodes Test: PASS clientKit.secrets: a secret capability name is refused by Has at the calling line
MoltenCodes Test: PASS clientKit.secrets: a secret addon name is refused by GetManifest at the calling line
MoltenCodes Test: PASS clientKit.secrets: a secret field name is refused by manifest:Get at the calling line
MoltenCodes Test: clientKit: 40 passed, 0 failed, 1 skipped, 0 timed out (41 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

`GetFlavor` answers `"mainline"` on Retail (`WOW_PROJECT_ID` 1): that is the
name docs/API.md gives the Retail flavour. On Classic Era (2) it answers
`"classic"` and on Mists Classic (19) `"mists"`; the test checks the answer
against the flavour the harness names as well as against `WOW_PROJECT_ID`. Running it again in the same
session prints the same lines.

## Visible side effects

None. Every call only reads the client: no Frame is created, no setting,
CVar, global or saved variable is written, and the client's error handler is
never replaced. No sound, no chat line other than the harness's.

## What stays for the session

- ClientKit's manifest cache holds the manifests of `MoltenCodesTest_ClientKit`
  and `MoltenCodesTest`, as it does for every addon it is asked about and the
  client lists (docs/API.md, "Manifests"). The unknown name the tests ask for,
  `MoltenCodesTest_NoSuchAddon`, is not cached.
- The client may have loaded the Hearthstone (item 6948) into its item cache.

Nothing else: ClientKit owns nothing that needs releasing, so the suites have
no After hooks.

## The expected SKIP

`CanAccessFrame answers false for a forbidden frame` is registered as skipped
on every client: docs/API.md names no forbidden frame an addon can reach out
of combat, so the `false` answer cannot be observed without inventing one.
The test before it logs what `UIParent:IsForbidden()` and
`UIParent:CanBeAccessedInContext()` answer.

### On a client without secret values

The four `clientKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine
secret out of combat without side effects: the client's own API
documentation (`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these four lines instead, and the totals
line reads `36 passed, 0 failed, 5 skipped, 0 timed out (41 tests)`:

```text
MoltenCodes Test: SKIP clientKit.secrets: IsSecret answers true for a genuine secret made by secretwrap -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP clientKit.secrets: a secret capability name is refused by Has at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP clientKit.secrets: a secret addon name is refused by GetManifest at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP clientKit.secrets: a secret field name is refused by manifest:Get at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### On a client that has both functions but makes no secrets

The harness measures once, when this file loads, whether
`issecretvalue(secretwrap(true))` is `true` (`Harness:CanMakeSecrets()`).
When it is not, the four `clientKit.secrets` tests are registered as skipped
with the harness's reason, and the totals line reads
`36 passed, 0 failed, 5 skipped, 0 timed out (41 tests)`:

```text
MoltenCodes Test: SKIP clientKit.secrets: IsSecret answers true for a genuine secret made by secretwrap -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP clientKit.secrets: a secret capability name is refused by Has at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP clientKit.secrets: a secret addon name is refused by GetManifest at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP clientKit.secrets: a secret field name is refused by manifest:Get at the calling line -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

### In combat

On Retail 12.x some spell fields may be secret while restrictions apply. When
a field of Regrowth's spell info is secret, the Regrowth test ends as skipped
instead of comparing it:

```text
MoltenCodes Test: SKIP clientKit.shims: GetSpellInfo(8936) returns a fresh table with the six documented fields, holding what the client's own call gives -- spell field <field> was a secret value (restrictions applied); run out of combat
```

Run out of combat to exercise it.

## Per flavour

ClientKit requires nothing but Lua 5.1 and degrades per facility
(docs/EMBEDDING.md, "What the framework promises"); every test compares it
with the running client, so most answers follow the client. What the tests
need, and what the metadata under `packages/apiKit/metadata/<flavour>/`
documents for the three clients:

- `C_AddOns.GetAddOnMetadata`, `C_AddOns.IsAddOnLoaded`,
  `C_AddOns.GetAddOnDependencies`, `C_Spell.GetSpellInfo` (the same
  `SpellInfo` fields), `C_Item.GetItemInfo` (the same eighteen returns),
  `C_EventUtils.IsEventValid`, `issecretvalue`, `secretwrap`,
  `GetTimePreciseSec`, `debugprofilestop`, `GetLocale` and the four
  `C_AddOns`, `C_Spell`, `C_Item`, `C_Timer` namespaces: documented on all
  three.
- `C_SpellBook.GetSpellBookItemInfo`: Retail only. `Has("spellbookApi")` is
  `false` on the Classic clients, and the capability test still passes because
  it compares with a direct probe that also finds nothing.
- `GetBuildInfo`, `securecallfunction`, `UIParent` and its `IsForbidden` and
  `CanBeAccessedInContext` methods, and the `WOW_PROJECT_*` constants: core
  globals and frame methods the documentation does not list. They are taken to
  be present on all three, except `CanBeAccessedInContext`, which
  docs/API.md dates to 12.1.0; each test compares with the client, so an
  absent one changes a logged value, not the outcome.
- Regrowth (spell 8936, rank 1 on Classic Era) and the Hearthstone (item 6948)
  exist on all three clients.

| Client | Totals line | SKIP lines |
|---|---|---|
| Retail (`_retail_`) | `MoltenCodes Test: clientKit: 40 passed, 0 failed, 1 skipped, 0 timed out (41 tests)` | the forbidden-frame line |
| Classic Era (`_classic_era_`) | secrets made: `MoltenCodes Test: clientKit: 40 passed, 0 failed, 1 skipped, 0 timed out (41 tests)`; no secrets made: `MoltenCodes Test: clientKit: 36 passed, 0 failed, 5 skipped, 0 timed out (41 tests)` | the forbidden-frame line, plus the four lines under "On a client that has both functions but makes no secrets" when it makes none |
| Mists of Pandaria Classic (`_classic_`) | secrets made: `MoltenCodes Test: clientKit: 40 passed, 0 failed, 1 skipped, 0 timed out (41 tests)`; no secrets made: `MoltenCodes Test: clientKit: 36 passed, 0 failed, 5 skipped, 0 timed out (41 tests)` | the forbidden-frame line, plus the four lines under "On a client that has both functions but makes no secrets" when it makes none |

Whether the Classic clients make secrets cannot be read from the metadata:
they document `issecretvalue` and `secretwrap`, and only the running client can
say whether `secretwrap` returns a secret. Both outcomes above are honest; the
saved client facts record which one this client gave.

No ClientKit test needs combat, a group, a second character or another addon,
so the package has no combat suites. The Regrowth test ends as skipped in
combat only when a spell field is secret (see "In combat"), which is why the
suite is run out of combat.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('clientKit', 1) is the ClientKit facade ...` | The facade the client loaded is API 1 with a numeric `REVISION` and every method docs/API.md lists. |
| `the installed ClientKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `GetFlavor maps the client's WOW_PROJECT_ID ...` | The flavour is the documented literal map applied to the live `WOW_PROJECT_ID`: `"mainline"` for Retail's 1. |
| `every WOW_PROJECT_* constant the client defines ...` | The client's own `WOW_PROJECT_MAINLINE`, `_CLASSIC`, `_BURNING_CRUSADE_CLASSIC` and `_MISTS_CLASSIC`, where defined, carry the numbers ClientKit compares as literals; the log lists each. |
| `GetBuild returns GetBuildInfo's version ...` | Version and build date are `GetBuildInfo()`'s, and the build string (`"69933"`) comes back as the integer 69933. |
| `GetInterfaceNumber is the fourth value ...` | The interface number is `GetBuildInfo()`'s fourth value (120100 on 12.1.0). |
| `IsAtLeast is true at and below ...` | `IsAtLeast` is `>=` against that number: true at it, below it and at 0, false one above it and at `math.huge`. |
| `Has answers each of the twelve documented capabilities ...` | Every flag equals a direct probe of the namespace, global function or `UIParent` method docs/API.md names for it; the log is the client's whole capability table. |
| `IsSecret answers false for a plain string ...` | Ordinary values, `nil`, a table and a real Frame are not secret. |
| `CanAccessFrame(UIParent) is true ...` | The answer agrees with `UIParent:IsForbidden()` and `UIParent:CanBeAccessedInContext()` called directly without an argument, as ClientKit calls them; both are logged. |
| `CanAccessFrame answers false for a forbidden frame` | Skipped; see above. |
| `IsEventValid agrees with C_EventUtils.IsEventValid ...` | For `PLAYER_LOGIN`, `PLAYER_TARGET_CHANGED`, `LEARNED_SPELL_IN_TAB` and a made-up event, the answer is the client's, normalised to a boolean; the log gives each. |
| `GetAddOnMetadata reads this addon's Version, Author, Notes ...` | The shim returns exactly what `C_AddOns.GetAddOnMetadata` returns for this addon's `.toc` fields, `X-MoltenCodes-Probe` included. |
| `GetAddOnMetadata answers nil for an X- field ...` | A field the `.toc` lacks reads `nil`; the log gives the client's raw answer. |
| `GetAddOnMetadata of a field the client does not export ...` | For `Interface`, `Category`, `LoadOnDemand` and `DefaultState` the shim answers, or raises the same error, as the client's call does: host errors propagate unchanged. The log says which the client does. |
| `IsAddOnLoaded answers true, true ...` | Two booleans from the client's call for this addon, the harness and an addon that is not installed. |
| `GetSpellInfo(8936) returns a fresh table ...` | Regrowth's info has the six contract fields with their documented types, the same values `C_Spell.GetSpellInfo` gives, and a fresh table on every call; the log lists every field the client's table carries. |
| `GetSpellInfo answers nil for a spell ID the client does not know ...` | Spell 9999999 reads `nil` through the shim and through the client's call. |
| `GetItemInfo(6948) returns the Hearthstone ...` | After the documented readiness path (a first call that may return nothing, then the item cache filling), the shim returns the same list, value for value and count for count, as `C_Item.GetItemInfo`, with the documented types; the log says whether the cache was cold and lists all eighteen positions. |
| `GetManifest of this addon has the title, notes, version and author ...` | The snapshot reads `Title`/`Notes` in the client's locale first (`Notes-enUS` on an enUS client, `Title-deDE` never on it), then the plain field; the log says which spelling the client exported. |
| `manifest:Get reads X-MoltenCodes-Probe as yes ...` | `Get` reads `X-` fields from the real `.toc`, twice the same, and `nil` for one the file lacks. |
| `the manifest's dependencies array lists MoltenCodesTest ...` | The dependency array comes out right whether the client exports `## Dependencies` or ClientKit falls back to `C_AddOns.GetAddOnDependencies`; the log shows the raw field. |
| `manifest fields the client's metadata call does not export ...` | Fields the client refuses read as `nil` in the snapshot (ClientKit's `pcall`), never as an error. |
| `GetManifest answers the same table for every spelling ...` | Lower- and upper-case spellings share the one snapshot, whose `name` is the folder name as the client spells it. |
| `GetManifest of an addon the client does not list ...` | An unknown name answers `nil, "unknown"` on every call. |
| `writing a manifest field is refused ...` | The snapshot refuses writes at this file's calling line, holds no raw keys and hides its metatable. |
| `the harness's manifest reads its title ...` | A second real addon reads through the same path; the log shows what the client exports for `## SavedVariables`. |
| `5000 rounds of every identity, capability and taint probe ...` | After a full collection, 5000 rounds of every probe and `IsAddOnLoaded` move `collectgarbage("count")` by at most 1 KB. |
| `5000 rounds of a cached GetManifest ...` | The same for a cached manifest in two spellings and remembered `Get` reads. |
| `IsAtLeast with a string or NaN ...` and the other `clientKit.errors` tests | Each argument error names this file at the calling line, as the client names it, with the documented message. |
| `IsSecret answers true for a genuine secret ...` | A real `secretwrap` secret is reported secret. |
| `a secret capability name is refused ...`, `a secret addon name ...`, `a secret field name ...` | A genuine secret is refused at the calling line with the documented message before ClientKit compares it or uses it as a key; the log says what `type()` answers for a secret. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line other than the forbidden-frame
  one on Retail 12.1 out of combat, or a totals line other than
  `40 passed, 0 failed, 1 skipped, 0 timed out (41 tests)`; on the Classic
  clients, anything other than the outcomes listed under "Per flavour".
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_ClientKit`.
- `Has answers each of the twelve ...` failing: ClientKit's flag and the
  client disagree. The log names the capability.
- `CanAccessFrame(UIParent) ...` failing with "raised without an argument":
  the client's `CanBeAccessedInContext` wants an argument that docs/API.md
  does not mention.
- A shim test failing on a compared value: the shim and the client's call
  disagree. The log has both.
- `GetItemInfo(6948) ...` failing on its wait: the client did not fill the
  item cache within five seconds. Say whether the server connection was slow.
- A manifest test failing on the title or notes: the client exports localised
  fields differently from docs/API.md's description. The log says which
  spelling answered.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed ClientKit carries the revision ...` failing: another enabled
  addon embeds a different ClientKit copy.
- A `clientKit.secrets` test failing with "must be a string": the client's
  `type()` does not answer `"string"` for a secret string (the log says what
  it answered). With "secretwrap raised" or "secretwrap returned a value
  issecretvalue does not report as secret": the client's secret functions
  behave differently from their documentation (the harness found that they
  make secrets, yet one call did not).

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/<flavour folder>/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`,
   where the flavour folder is `_retail_`, `_classic_era_` or `_classic_`.
   It holds the full report, each test's logs (the capability table as
   ClientKit and the client answer it, the project constants, the build facts,
   the event validity answers, the metadata answers for exported and
   unexported fields, every field of Regrowth's and the Hearthstone's info,
   whether the item cache was cold, the manifest fields and their spellings,
   the two measured memory deltas, the client's own error messages with their
   paths) and the client facts. Lua shortens a long file path from the left,
   so a logged message may start with `...`; the tests compare only the
   `ClientKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
