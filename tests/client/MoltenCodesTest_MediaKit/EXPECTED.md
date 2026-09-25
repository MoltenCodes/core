# Expected result: `/mct run mediaKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package mediaKit`
and nothing else from the MoltenCodes framework enabled in the client, and no
other addon that loads LibSharedMedia-3.0. Run it out of combat.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for mediaKit. Type /mct run mediaKit to run them; /mct help lists every command.
```

## After `/mct run mediaKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green in
the client). The two allocation tests run full garbage collections first, so
the client may stutter for a moment:

```text
MoltenCodes Test: running mediaKit: 10 suites. Results follow when every test has finished.
MoltenCodes Test: PASS mediaKit.facade: Registry:Get('mediaKit', 1) is the MediaKit facade with API 1, its eleven methods, MAX_ENTRIES_PER_TYPE 1024 and the UNBOUNDED sentinel
MoltenCodes Test: PASS mediaKit.facade: the installed MediaKit carries the revision of the committed manifest
MoltenCodes Test: PASS mediaKit.facade: the client's GetLocale answers a locale string MediaKit maps to a script; issecretvalue, LibStub, LibSharedMedia-3.0, GetFileIDFromPath and CreateFrame are logged
MoltenCodes Test: PASS mediaKit.builtins: every built-in entry of docs/API.md's table holds its documented data for this client's locale, and each type's Get fallback is one of them
MoltenCodes Test: PASS mediaKit.builtins: the four built-in fonts load into a hidden FontString: SetFont(path, 12) returns true for each and GetFont names the file; a missing font file is logged as the control
MoltenCodes Test: PASS mediaKit.builtins: the nine texture-backed built-ins (backgrounds, borders but 'None', the icon, the status bars and the texture) load into a hidden Texture: SetTexture returns true, GetTexture answers and GetTextureFileID equals GetFileIDFromPath
MoltenCodes Test: PASS mediaKit.builtins: GetFileIDFromPath resolves every texture-backed built-in path to a FileDataID; the font paths and the 'None' border and sound placeholders are logged, not asserted, and nothing is played
MoltenCodes Test: SKIP mediaKit.builtins: a sound registered by a FileDataID of a shipped interface sound is a FileDataID to IsFileDataID, and Fetch hands back that number; nothing is played -- GetFileIDFromPath answered nil for Sound\Interface\RaidWarning.ogg, ReadyCheck.ogg and LevelUp.ogg on Retail 12.1.0 b69933, and SOUNDKIT holds SoundKit ids, not FileDataIDs; the Busted specs cover a sound FileDataID
MoltenCodes Test: PASS mediaKit.scripts: GetLocale() maps to the documented script, and a font declaring that script is fetched, listed and Has true while a font declaring only greek is hidden unless anyScript
MoltenCodes Test: PASS mediaKit.scripts: a font registered without scripts is Latin only: offered on a Latin client, hidden on any other, and always reachable with anyScript
MoltenCodes Test: PASS mediaKit.scripts: the built-in fonts are offered without anyScript on a Latin or ruRU client and hidden on a CJK or Korean one, as docs/API.md's built-in table says
MoltenCodes Test: PASS mediaKit.lists: List returns every name sorted with < in byte order ('Bar 10' before 'Bar 2', upper case before lower case), whatever order the names were registered in
MoltenCodes Test: PASS mediaKit.lists: List hands out the same cached array until a registration of its type, then a new one, never changes an array handed out earlier, and keeps its cache through a registration of another type
MoltenCodes Test: PASS mediaKit.lists: the client's font list and the anyScript font list are cached separately, and a font of another script enters only the anyScript list
MoltenCodes Test: PASS mediaKit.registration: Register answers true again for the same name and data, nil and 'taken' for other data or other scripts, and treats a script set in another order with repeats as the same
MoltenCodes Test: PASS mediaKit.registration: OnRegistered fires once with type, name and data after the entry is stored, not for an identical or refused registration, and not after Disconnect
MoltenCodes Test: PASS mediaKit.defaults: Defaults returns one object per consumer name, and a consumer without choices gets each type's documented built-in fallback on this client
MoltenCodes Test: PASS mediaKit.defaults: defaults:Set of a registered test status bar is answered by that consumer's Get only, and Set(type, nil) brings the fallback back
MoltenCodes Test: PASS mediaKit.defaults: a chosen name registered only later is answered as soon as it is registered, and a chosen font of another script yields the fallback
MoltenCodes Test: PASS mediaKit.libSharedMedia: without LibSharedMedia-3.0 AdoptLibSharedMedia and MirrorToLibSharedMedia both answer false and 'absent' and change nothing
MoltenCodes Test: SKIP mediaKit.libSharedMedia: a real LibSharedMedia-3.0 holds MediaKit's built-in names with the same files (read only; nothing is adopted or mirrored) -- no real LibSharedMedia-3.0 is loaded; the stand-in tests cover the bridge
MoltenCodes Test: PASS mediaKit.libSharedMedia: AdoptLibSharedMedia adopts a stand-in LibSharedMedia's entries read-only in sorted name order, skips invalid and clashing ones, follows its later registrations and subscribes once
MoltenCodes Test: PASS mediaKit.libSharedMedia: MirrorToLibSharedMedia registers MediaKit's entries into a stand-in LibSharedMedia with the documented langmask, mirrors a later Register before OnRegistered fires, and nothing echoes with both directions on
MoltenCodes Test: PASS mediaKit.allocation: Fetch of a status bar and of a font, anyScript Fetch and Has allocate nothing over 2000 calls each
MoltenCodes Test: PASS mediaKit.allocation: List of an unchanged type, List('font') with and without anyScript and defaults:Get allocate nothing over 2000 calls each
MoltenCodes Test: PASS mediaKit.errors: Register with the type 'statusBar', an empty name, a zero FileDataID, scripts on a status bar and an unknown script is refused at the calling line with docs/API.md's wording
MoltenCodes Test: PASS mediaKit.errors: Fetch of a nil name, List with an unknown option field and Has with anyScript 'yes' are refused at the calling line
MoltenCodes Test: PASS mediaKit.errors: OnRegistered with a string callback, defaults.Get called with a dot and MediaKit.SetLimits called with a dot are refused at the calling line
MoltenCodes Test: PASS mediaKit.errors: SetLimits with UNBOUNDED or 16385 for maxEntriesPerType and an unknown limit is refused at the calling line and the limits stay as they were
MoltenCodes Test: PASS mediaKit.secrets: Register refuses a secret type, name, data and script name at the calling line and registers nothing
MoltenCodes Test: PASS mediaKit.secrets: Fetch, Has and List refuse a secret name or a secret anyScript at the calling line, and OnRegistered a secret type
MoltenCodes Test: PASS mediaKit.secrets: Defaults refuses a secret consumer name, defaults:Set a secret name and defaults:Get a secret type, at the calling line
MoltenCodes Test: PASS mediaKit.secrets: SetLimits refuses a secret maxConsumers at the calling line and the limits stay as they were, and IsFileDataID answers false for a secret FileDataID
MoltenCodes Test: PASS mediaKit.secrets: with a stand-in LibSharedMedia, a secret entry is not adopted, a callback with a secret type and name raises nothing, a secret LOCALE_BIT_western gives way to 128 and a secret Register answer is not counted as mirrored
MoltenCodes Test: mediaKit: 32 passed, 0 failed, 2 skipped, 0 timed out (34 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The two `SKIP` lines are expected. The comparison with a real
LibSharedMedia-3.0 runs only when another addon has loaded one, and the
stand-in tests cover the bridge otherwise. The sound FileDataID test is
registered as skipped: a sound's FileDataID can only be proven to name a
shipped file through `GetFileIDFromPath`, and the run of 2026-09-25 on Retail
12.1.0 b69933 measured that it answers `nil` for three shipped interface
sounds (`Sound\Interface\RaidWarning.ogg`, `ReadyCheck.ogg`, `LevelUp.ogg`)
and for the one font path it was asked about (`Fonts\ARIALN.TTF`), while it
resolves every texture path. The client's `SOUNDKIT` constants are SoundKit
ids for `PlaySound`, not FileDataIDs, and no client function maps one to the
other without playing the sound. The Busted specs register and fetch sound
FileDataIDs.

Running it again in the same session prints the same lines: every test
registers new names (each ends with a number that grows for the session), and
the defaults tests start from consumers whose choices the previous run cleared.

### With a real LibSharedMedia-3.0 loaded

When another enabled addon (a media pack, WeakAuras, any Ace3 addon that
embeds it) has loaded LibSharedMedia-3.0, the four tests that need it absent
or replaced by the stand-in skip, and the read-only comparison runs instead.
These lines replace their counterparts above:

```text
MoltenCodes Test: SKIP mediaKit.libSharedMedia: without LibSharedMedia-3.0 AdoptLibSharedMedia and MirrorToLibSharedMedia both answer false and 'absent' and change nothing -- a real LibSharedMedia-3.0 is loaded, so the absent path cannot be reached
MoltenCodes Test: PASS mediaKit.libSharedMedia: a real LibSharedMedia-3.0 holds MediaKit's built-in names with the same files (read only; nothing is adopted or mirrored)
MoltenCodes Test: SKIP mediaKit.libSharedMedia: AdoptLibSharedMedia adopts a stand-in LibSharedMedia's entries read-only in sorted name order, skips invalid and clashing ones, follows its later registrations and subscribes once -- a real LibSharedMedia-3.0 is loaded; the stand-in is installed only when none exists
MoltenCodes Test: SKIP mediaKit.libSharedMedia: MirrorToLibSharedMedia registers MediaKit's entries into a stand-in LibSharedMedia with the documented langmask, mirrors a later Register before OnRegistered fires, and nothing echoes with both directions on -- a real LibSharedMedia-3.0 is loaded; the stand-in is installed only when none exists
MoltenCodes Test: SKIP mediaKit.secrets: with a stand-in LibSharedMedia, a secret entry is not adopted, a callback with a secret type and name raises nothing, a secret LOCALE_BIT_western gives way to 128 and a secret Register answer is not counted as mirrored -- a real LibSharedMedia-3.0 is loaded; the stand-in is installed only when none exists
```

and the totals line reads `29 passed, 0 failed, 5 skipped, 0 timed out (34 tests)`.
MediaKit never adopts from nor mirrors into the real library during the run.

### On a client without secret values

The five `mediaKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead:

```text
MoltenCodes Test: SKIP mediaKit.secrets: Register refuses a secret type, name, data and script name at the calling line and registers nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP mediaKit.secrets: Fetch, Has and List refuse a secret name or a secret anyScript at the calling line, and OnRegistered a secret type -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP mediaKit.secrets: Defaults refuses a secret consumer name, defaults:Set a secret name and defaults:Get a secret type, at the calling line -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP mediaKit.secrets: SetLimits refuses a secret maxConsumers at the calling line and the limits stay as they were, and IsFileDataID answers false for a secret FileDataID -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP mediaKit.secrets: with a stand-in LibSharedMedia, a secret entry is not adopted, a callback with a secret type and name raises nothing, a secret LOCALE_BIT_western gives way to 128 and a secret Register answer is not counted as mirrored -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

and the totals line reads `27 passed, 0 failed, 7 skipped, 0 timed out (34 tests)`.
On Retail 12.1 any `SKIP` other than the real-LibSharedMedia comparison and
the sound FileDataID test is unexpected.

### On a client with another locale

The tests read `GetLocale()` and expect what docs/API.md states for it, so the
same 32 lines pass on every locale; only the logs differ. On `ruRU` the
built-in fonts are the `_CYR` files; on `zhCN`, `zhTW` and `koKR` no built-in
font is offered without `anyScript`, and a consumer's font default is the first
font that client can render.

## Visible side effects

None. Nothing is drawn: the probe Frame is created hidden, at alpha 0, with no
size and no anchor, and its Texture and FontString are never shown. No sound
plays: the suite only logs what `GetFileIDFromPath` answers for the `None`
sound's path and never calls `PlaySound`, `PlaySoundFile` or any other sound
function. No chat line other than the harness's appears, and no client
setting (CVar) changes. The only thing a player can notice is a short stutter
while the allocation tests collect garbage.

## What stays for the session

- **Test entries.** MediaKit never removes an entry, so every entry the tests
  register stays in MediaKit until `/reload` or logout, named
  `MoltenCodesTest <label> <n>` (about 35 per run: status bars, backgrounds
  and fonts). Each names a file the client ships
  (`Interface\Buttons\WHITE8X8`, `Interface\TargetingFrame\UI-StatusBar`,
  `Fonts\FRIZQT__.TTF`). An
  addon listing MediaKit media in this session would show them. Entries the
  stand-in LibSharedMedia handed over (adopted) stay the same way.
- **Two defaults objects**, `MoltenCodesTest_MediaKit A` and
  `MoltenCodesTest_MediaKit B`: MediaKit keeps a consumer for the session. The
  After hook of every suite clears their choices.
- **One hidden probe Frame** with one Texture and one FontString, created on
  first use: the client never frees a Frame. The Texture is cleared after the
  texture test.

What does not stay:

- Every `OnRegistered` connection a test made is disconnected by the After
  hook, pass or fail.
- The stand-in LibSharedMedia is installed only while one test body runs, and
  only when no real LibSharedMedia-3.0 exists: the test replaces the `LibStub`
  global with a stand-in LibStub (which passes every other library to the real
  LibStub when there is one), and puts back the previous `LibStub` value and
  MediaKit's three bridge pointers (`adoptSource`, `subscribed`,
  `mirrorTarget`, docs/INTERNALS.md) before the body returns, pass or fail.
  The body never yields, so no other code can see the stand-in. When a real
  LibStub was present, putting it back is a write of the same table from this
  addon; Blizzard code never reads `LibStub`.
- MediaKit's shared limits are never changed: every `SetLimits` call is a
  refusal the tests check, and they compare `GetLimits()` before and after.
- Nothing is written to a global or a saved variable other than the harness's
  own results.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('mediaKit', 1) is the MediaKit facade ...` | The facade the client loaded is API 1 with all eleven methods, `MAX_ENTRIES_PER_TYPE` 1024 and the `UNBOUNDED` sentinel. The log gives the session's two limits. |
| `the installed MediaKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the client's GetLocale answers a locale string ...` | `GetLocale()` is a function answering a string, the one host fact MediaKit filters fonts by. The log gives the locale and the script docs/API.md maps it to, whether `issecretvalue` and `secretwrap` exist, whether `LibStub` and LibSharedMedia-3.0 are loaded (with its minor), and whether `GetFileIDFromPath` and `CreateFrame` exist. |
| `every built-in entry of docs/API.md's table holds its documented data ...` | All fifteen built-ins are registered with the exact data of docs/API.md's table (the `_CYR` fonts on `ruRU`, the Western ones elsewhere), and each type's `defaults:Get` fallback is a built-in (`origin` `builtin`). |
| `the four built-in fonts load into a hidden FontString ...` | Each built-in font path is a font the client really has: `SetFont(path, 12)` on a hidden FontString answers `true`, while the control, a missing file, raises `Invalid font asset (...): file not found` (Retail 12.1.0 b69933). This is the proof for fonts, because `GetFileIDFromPath` answered `nil` for `Fonts\ARIALN.TTF`. The log gives `SetFont` and `GetFont` for each, the answer for the `ruRU` file of each font on a non-`ruRU` client (not asserted: those files are not this client's entries), and the answer for a font file the client does not ship, the control. |
| `the nine texture-backed built-ins ...` | Each texture built-in (three backgrounds, two borders, the icon, two status bars, the texture) is a texture the client really has: `SetTexture(path)` on a hidden Texture answers `true`, `GetTexture` answers a string or number, and `GetTextureFileID` equals what `GetFileIDFromPath` answers for the path. The control, a missing file, is logged. |
| `GetFileIDFromPath resolves every texture-backed built-in path ...` | The nine texture-backed built-ins resolve to a FileDataID through `GetFileIDFromPath`. The font paths and the two `None` placeholders (`Interface\None` for the border, `Interface\Quiet.ogg` for the sound: the names LibSharedMedia uses for "no media", not client files) are logged, not asserted; Retail 12.1.0 b69933 answered `nil` for both placeholders and for `Fonts\ARIALN.TTF` (the first font; that run stopped there), and this run logs the other fonts' answers. Nothing is played. |
| `a sound registered by a FileDataID of a shipped interface sound ...` | Registered as skipped, with the measured reason: no sound FileDataID can be proven to name a shipped file without playing it (see above). The Busted specs cover registering, fetching and `IsFileDataID` of a sound FileDataID. |
| `GetLocale() maps to the documented script, and a font declaring that script ...` | The filter uses the client's own `GetLocale()`: a test font declaring this client's script is fetched, listed and `Has` true; one declaring only `greek` (no client writes it) is `nil`, `false` and unlisted, and reachable only with `anyScript`. |
| `a font registered without scripts is Latin only ...` | An undeclared font is offered on a Latin client and hidden on any other, and always reachable with `anyScript`. |
| `the built-in fonts are offered without anyScript on a Latin or ruRU client ...` | The built-in fonts' scripts on this client match docs/API.md. The log gives how many fonts this client is offered and how many exist. |
| `List returns every name sorted with < in byte order ...` | The whole status bar list is in byte order, and four names registered as `Bar 2`, `bar 1`, `Bar 10`, `Alpha` come out as `Alpha`, `Bar 10`, `Bar 2`, `bar 1`. |
| `List hands out the same cached array until a registration of its type ...` | The cached array is shared until a status bar is registered (a background does not invalidate it); the new array has the entry, the old one is unchanged. |
| `the client's font list and the anyScript font list are cached separately ...` | Two distinct cached arrays; a `greek` font enters only the `anyScript` list, and the client's list keeps its length. |
| `Register answers true again for the same name and data ...` | An identical registration answers `true` and keeps the cached list; other data answers `nil, "taken"` and keeps the first data (also against the built-in `Solid`); a font's script set compares as a set. |
| `OnRegistered fires once with type, name and data after the entry is stored ...` | The listener runs once with `("statusbar", name, data)` and already sees the entry through `Fetch` and `List`; an identical, a refused and another type's registration fire nothing; after `Disconnect` nothing fires. |
| `Defaults returns one object per consumer name ...` | `Defaults` answers the same object per name and another per other name; a consumer without choices gets the documented fallback of every type on this client (the log lists them). |
| `defaults:Set of a registered test status bar ...` | A choice is answered by that consumer only, the other keeps `Blizzard`, and `Set(type, nil)` brings the fallback back. |
| `a chosen name registered only later ...` | A choice not yet registered yields the fallback until its registration, then the choice at once; a chosen `greek` font yields the font fallback. |
| `without LibSharedMedia-3.0 AdoptLibSharedMedia and MirrorToLibSharedMedia ...` | The client-side "absent" path: both answer `false, "absent"` whether `LibStub` exists or not (the log says which), and neither the bridge nor the lists change. |
| `a real LibSharedMedia-3.0 holds MediaKit's built-in names ...` | Runs only when a real LibSharedMedia-3.0 is loaded: docs/API.md's claim that the built-ins use LibSharedMedia's names for the same files, read from `HashTable` and compared without case or slash differences (fonts only on a Latin or `ruRU` client). Nothing is adopted or mirrored. |
| `AdoptLibSharedMedia adopts a stand-in LibSharedMedia's entries ...` | Adoption through the `LibStub` global as the client resolves it: `true, 4`; the adopted status bars fire `OnRegistered` in sorted order; `Solid` with other data keeps MediaKit's built-in, `Blizzard` with the same data adds nothing, an empty name and a `0` FileDataID are skipped; an adopted font is offered without `anyScript`; an adopted name is read-only; a later registration in the stand-in is adopted through its callback; a second call adds nothing and subscribes no second time. |
| `MirrorToLibSharedMedia registers MediaKit's entries into a stand-in ...` | Every non-adopted entry of the five shared types is offered to the stand-in and the count equals what it accepted; adopted ones are not mirrored back; the `langmask` is 130 for `latin` + `cyrillic`, 128 for an undeclared font, 0 for `greek` (which the stand-in refuses, as LibSharedMedia does), and the built-in font's matches this client; a later `Register` is in the stand-in before `OnRegistered` fires; with both directions on, a registration fires once and stays `registered`. |
| `Fetch of a status bar and of a font, anyScript Fetch and Has allocate nothing ...` | docs/API.md's "Fetch, Has: no allocation", including the font path that calls the client's `GetLocale`: after a full collection in its own step and one warm-up call, 2000 calls move `collectgarbage("count")` by at most 1 KB. |
| `List of an unchanged type, List('font') ... and defaults:Get allocate nothing ...` | The same for cached lists (filtered and not) and `defaults:Get`. |
| `Register with the type 'statusBar', ...` | Each `Register` refusal raises at this file's calling line with docs/API.md's wording, and nothing is registered. |
| `Fetch of a nil name, List with an unknown option field and Has with anyScript 'yes' ...` | Lookup refusals at the calling line. |
| `OnRegistered with a string callback, defaults.Get called with a dot and MediaKit.SetLimits called with a dot ...` | The callback check and both receiver checks at the calling line. |
| `SetLimits with UNBOUNDED or 16385 for maxEntriesPerType and an unknown limit ...` | The three limit refusals at the calling line, with the reason for refusing `UNBOUNDED`, and the limits unchanged. |
| `Register refuses a secret type, name, data and script name ...` | A genuine secret in any `Register` argument is refused at the calling line with MediaKit's own message, so MediaKit found it before the client's comparison error could. |
| `Fetch, Has and List refuse a secret name or a secret anyScript ...` | A secret name, a secret boolean `anyScript` (which would raise in a boolean test) and a secret type are refused at the calling line. |
| `Defaults refuses a secret consumer name, ...` | The three defaults refusals at the calling line; the consumer's answer is unchanged. |
| `SetLimits refuses a secret maxConsumers ...` | Refused at the calling line, limits unchanged; `IsFileDataID` answers `false` for a secret `569593` without raising, and `true` for the plain number. |
| `with a stand-in LibSharedMedia, a secret entry is not adopted, ...` | Foreign secrets never reach a comparison: a secret path in the stand-in's table is skipped (`true, 1`), the stand-in's callback fired with a secret type and name raises nothing, a secret `LOCALE_BIT_western` is replaced by 128, and `Register` answers that are secret count as not mirrored (`true, 0`). |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line other than the ones above for
  this client, or a totals line other than the ones above.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_MediaKit`. Every error the suite
  provokes is caught by the test itself.
- Anything visible or audible.
- A built-in file test failing: the log names the path and the client's
  answers. That means docs/API.md's built-in table names a file this client
  does not have, and must be reported rather than retried.
- `the four built-in fonts ...` passing while its log says the control
  `SetFont` answered `true` instead of raising: the probe cannot tell a missing
  file, and nothing else proves the fonts (`GetFileIDFromPath` answered `nil`
  for `Fonts\ARIALN.TTF`). Send the log.
- A `GetTextureFileID` mismatch: the log gives both numbers.
- An allocation test failing: its log gives the measured deltas. Say which
  other addons are enabled.
- `the installed MediaKit carries the revision ...` failing: another enabled
  addon embeds a different MediaKit copy.
- A `mediaKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the locale and its script,
   whether LibStub and LibSharedMedia-3.0 are loaded, every `SetFont`,
   `SetTexture`, `GetTexture`, `GetTextureFileID` and `GetFileIDFromPath`
   answer, the fonts' and the two placeholders' `GetFileIDFromPath` answers, the controls, the memory deltas, the
   client's own error messages with their paths) and the client facts. Lua
   shortens a long file path from the left, so a logged message may start with
   `...`; the tests compare only the `MediaKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed or skipped.
