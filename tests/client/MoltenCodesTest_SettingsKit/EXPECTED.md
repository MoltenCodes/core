# Expected result: `/mct run settingsKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package settingsKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat, on one character for the whole procedure.

This addon declares two real saved variables in its `.toc`:

| Saved variable | Kind | File the client writes |
|---|---|---|
| `MoltenCodesTest_SettingsKitDB` | `## SavedVariables` (account-wide) | `WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest_SettingsKit.lua` |
| `MoltenCodesTest_SettingsKitCharDB` | `## SavedVariablesPerCharacter` | `WTF/Account/<ACCOUNT>/<Realm>/<Character>/SavedVariables/MoltenCodesTest_SettingsKit.lua` |

The suites open SettingsKit databases over them (the account one with
`defaultProfile = "char"` and `version = 2`, the per-character one with
`version = 1`). Nothing is opened at login: the first test that needs a
database opens it, long after the addon's loaded phase.

## The procedure: two runs with a `/reload` between them

Persistence across `/reload` is the fact only the real client can show, so
the persistence suite runs in two steps:

1. Log in, type `/mct run settingsKit`. **Run 1**: step one writes known
   values and a marker; step two and the cleanup test are `SKIP` (see the
   lines below).
2. Type `/reload`. The client fires `PLAYER_LOGOUT` (every database compacts
   itself), writes both saved variables to the two files above, reloads the
   UI and restores them before this addon's `ADDON_LOADED`.
3. Type `/mct run settingsKit` again. **Run 2**: step one is `SKIP` (it keeps
   the marker the client restored), both step-two tests `PASS`, and the last
   test, `cleanup: ...`, empties both saved variables.
4. Type `/reload` once more. The client now writes both files without the
   two tables, so nothing of this addon's data remains on disk. The harness
   results (`MoltenCodesTest.lua`) are written by the same `/reload`.

Which run is which is decided by what the client restored, not by a counter:
at this addon's loaded phase the suite copies the two restored tables before
any code of the session can write to them, and a marker in that copy was
written by an earlier session.

`/mct clear` empties only the harness results (`MoltenCodesTestResults`); it
**does not** touch `MoltenCodesTest_SettingsKitDB` or
`MoltenCodesTest_SettingsKitCharDB`. The `cleanup: ...` test of run 2 is what
empties them. If testing stops before run 2, close the game and run
`python3 -m tooling.client.install --remove`: it deletes the
`MoltenCodesTest.lua` result files and both `MoltenCodesTest_SettingsKit.lua`
files (account and character) with their `.bak` copies.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for settingsKit. Type /mct run settingsKit to run them; /mct help lists every command.
```

## Run 1: after the first `/mct run settingsKit`

Within about two seconds, exactly these lines, in this order (`PASS` is
green, `SKIP` yellow in the client). The three allocation tests each run a
full garbage collection first, which can make the client stutter for a
moment:

```text
MoltenCodes Test: running settingsKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS settingsKit.facade: Registry:Get('settingsKit', 1) is the SettingsKit facade with API 1, Open, SetLimits, GetLimits, UNBOUNDED, DEFAULT_PROFILE 'Default', MAX_PROFILE_NAME_LENGTH 64 and the Database prototype's seventeen methods
MoltenCodes Test: PASS settingsKit.facade: the installed SettingsKit carries the revision of the committed manifest
MoltenCodes Test: PASS settingsKit.facade: GetLimits answers a fresh table holding the session's shared limits at their defaults: maxProfileNameLength 64 and pathKeyLimit 32
MoltenCodes Test: PASS settingsKit.savedVariables: Open over the two saved variables of the toc, after the loaded phase, uses each global as the raw table, stamps its version, creates every layout section, and a second Open returns the same database
MoltenCodes Test: PASS settingsKit.savedVariables: the current profile and the char scope are keyed '<name> - <realm>' from the live UnitName('player') and GetRealmName(), and a write through db.char lands under that key
MoltenCodes Test: PASS settingsKit.savedVariables: the realm, class and faction scopes are keyed by the live GetRealmName(), UnitClass('player')'s class file and UnitFactionGroup('player'), and a write through each lands under its key
MoltenCodes Test: PASS settingsKit.savedVariables: reading defaults writes nothing: frame.x, frame.y, auras[118].shown, label, global.counter and char.touched read their defaults and the raw profile, global and char tables gain no key
MoltenCodes Test: PASS settingsKit.savedVariables: an array default is copied into the raw saved table on its first read, as documented, and Compact removes the unchanged copy
MoltenCodes Test: PASS settingsKit.savedVariables: a validated write stores only the written path in the raw saved table, OnChange reports db, scope, key, value and path, and writing nil brings the default back
MoltenCodes Test: PASS settingsKit.savedVariables: the per-character saved variable is a database of its own: a write to its global scope lands in MoltenCodesTest_SettingsKitCharDB and not in the account table
MoltenCodes Test: PASS settingsKit.writes: writes the schema refuses raise at the writing line in SettingsKitSuite.lua with SchemaKit's text and store nothing: scale 7, anchor LEFT, frame.x a string
MoltenCodes Test: PASS settingsKit.writes: an undeclared field of the closed profile record and a fifth aura past max 4 are refused at the writing line, and the section keeps its four entries
MoltenCodes Test: PASS settingsKit.writes: Open, OnChange, SetProfile, DeleteProfile and a write to the database object are refused at the calling line in SettingsKitSuite.lua
MoltenCodes Test: PASS settingsKit.writes: Validate answers false with exactly the text the refused write raises and true for a valid value, and writes nothing to the raw saved table
MoltenCodes Test: PASS settingsKit.profiles: SetProfile to a new profile creates it in the raw saved table, records it under the character key in profileKeys and fires OnProfileChanged; switching back returns to the character profile
MoltenCodes Test: PASS settingsKit.profiles: CopyProfile replaces the current profile with a deep copy of another's saved values, fires OnProfileCopied and keeps db.profile the same view
MoltenCodes Test: PASS settingsKit.profiles: ResetProfile empties the current profile's raw table in place, so every field reads its default, and fires OnProfileReset
MoltenCodes Test: PASS settingsKit.profiles: DeleteProfile removes a profile from the raw saved table and from GetProfiles, fires OnProfileDeleted, and a view kept from it reads defaults and refuses writes at the writing line
MoltenCodes Test: PASS settingsKit.profiles: GetProfiles answers a fresh array sorted with <, always holding the character profile
MoltenCodes Test: PASS settingsKit.migrations: a table written by an older version runs migrations 2 and 3 once each, in ascending order, on the raw table, and stores version 3
MoltenCodes Test: PASS settingsKit.migrations: a new, empty saved table is stamped with the version and no migration runs
MoltenCodes Test: PASS settingsKit.migrations: a migration that raises stops Open at the calling line naming the step, keeps the finished step, and the next Open retries from the failing step only
MoltenCodes Test: PASS settingsKit.migrations: a stored version above options.version is left alone and no migration runs
MoltenCodes Test: PASS settingsKit.migrations: a stored version above options.version opens read-only: IsReadOnly is true, reads work, a view write and SetProfile are refused at the calling line with the exact message, and the saved table and its version stay unchanged
MoltenCodes Test: PASS settingsKit.migrations: allowNewerData opens a stored version above options.version writable, and neither a write nor ResetDatabase lowers the stored version
MoltenCodes Test: PASS settingsKit.migrations: a migration step that writes and then raises leaves the saved table untouched, and the retry applies the step once: scale 1 becomes 2, not 4
MoltenCodes Test: PASS settingsKit.migrations: a scalar stored where the schema declares a record reads as absent: the default view answers frame.x 0, and the next write replaces the scalar
MoltenCodes Test: PASS settingsKit.allocation: reads through views of the real saved variable (scale, frame.x, a held auras entry's shown, char.touched, global.counter) allocate nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.allocation: a validated write of an existing key with a plain value allocates nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.allocation: Validate of a plain value with an array path allocates nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.secrets: a secret string and a secret number stored in the raw saved table behind profile.label and profile.frame.x read back through the views still secret, of their types, without raising
MoltenCodes Test: PASS settingsKit.secrets: Compact walks a profile holding a secret without raising and leaves the secret in place
MoltenCodes Test: PASS settingsKit.secrets: writing a secret value, or a table holding one, through a view raises at the writing line with 'refused a secret value' and the raw saved table is unchanged
MoltenCodes Test: PASS settingsKit.secrets: Validate refuses a secret key on the path with 'refused a secret key' and stores nothing
MoltenCodes Test: PASS settingsKit.secrets: a secret key never reads or stores: db.profile[secret], db.profile.auras[secret], db[secret] and db.profile[secret] = 1 each raise at this file's line, and the raw profile gains no key
MoltenCodes Test: PASS settingsKit.secrets: OnChange and Validate refuse a secret scope, Open a secret version and SetLimits a secret value, each at the calling line before comparing it, and the limits stay as they were
MoltenCodes Test: PASS settingsKit.persistence: persistence step one: profile.scale 1.25, profile.anchor at its default, char.note, the per-character global.note and a marker are written through the views and stored in both raw saved tables
MoltenCodes Test: SKIP settingsKit.persistence: persistence step two: after /reload the client restored both saved tables after this file ran (nil at file scope) and before the loaded phase, and the views read back the marker, scale 1.25, char.note and the per-character note -- run again after /reload: no marker from an earlier session yet (step one wrote it now)
MoltenCodes Test: SKIP settingsKit.persistence: persistence step two: the PLAYER_LOGOUT compaction removed profile.anchor, written equal to its default in step one, before the client wrote the file, and kept scale -- run again after /reload: no marker from an earlier session yet (step one wrote it now)
MoltenCodes Test: SKIP settingsKit.cleanup: cleanup: once persistence step two passed, both saved variables are emptied so the files hold no data after the next /reload -- persistence step two has not passed yet; the saved tables are kept for the run after /reload
MoltenCodes Test: settingsKit: 37 passed, 0 failed, 3 skipped, 0 timed out (40 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The totals line reads `37 passed, 0 failed, 3 skipped, 0 timed out (40 tests)`.
The step-one test logs `marker written: <date> #<number>; now /reload and run
/mct run settingsKit again`.

After run 1 and the `/reload`, the account file holds exactly what step one
wrote and nothing the other tests wrote (their After hooks removed it), and
no default (`anchor` was written equal to its default and removed by the
logout compaction):

```lua
MoltenCodesTest_SettingsKitDB = {
  ["version"] = 2,
  ["global"] = {
    ["persistence"] = {
      ["token"] = "<date> #<number>",
      ["writtenAt"] = "<date>",
      ["character"] = "<name> - <realm>",
    },
  },
  ["profiles"] = { ["<name> - <realm>"] = { ["scale"] = 1.25 } },
  ["char"] = { ["<name> - <realm>"] = { ["note"] = "<date> #<number>" } },
  ["profileKeys"] = {}, ["realm"] = {}, ["class"] = {}, ["faction"] = {}, ["namespaces"] = {},
}
```

and the per-character file holds `version = 1`, `global.note` with the same
token, the empty layout sections and an empty `profiles.Default` (`Open`
creates the current profile's table even when no `profile` scope is declared).
The client may order the keys differently.

## Run 2: after `/reload` and the second `/mct run settingsKit`

```text
MoltenCodes Test: running settingsKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS settingsKit.facade: Registry:Get('settingsKit', 1) is the SettingsKit facade with API 1, Open, SetLimits, GetLimits, UNBOUNDED, DEFAULT_PROFILE 'Default', MAX_PROFILE_NAME_LENGTH 64 and the Database prototype's seventeen methods
MoltenCodes Test: PASS settingsKit.facade: the installed SettingsKit carries the revision of the committed manifest
MoltenCodes Test: PASS settingsKit.facade: GetLimits answers a fresh table holding the session's shared limits at their defaults: maxProfileNameLength 64 and pathKeyLimit 32
MoltenCodes Test: PASS settingsKit.savedVariables: Open over the two saved variables of the toc, after the loaded phase, uses each global as the raw table, stamps its version, creates every layout section, and a second Open returns the same database
MoltenCodes Test: PASS settingsKit.savedVariables: the current profile and the char scope are keyed '<name> - <realm>' from the live UnitName('player') and GetRealmName(), and a write through db.char lands under that key
MoltenCodes Test: PASS settingsKit.savedVariables: the realm, class and faction scopes are keyed by the live GetRealmName(), UnitClass('player')'s class file and UnitFactionGroup('player'), and a write through each lands under its key
MoltenCodes Test: PASS settingsKit.savedVariables: reading defaults writes nothing: frame.x, frame.y, auras[118].shown, label, global.counter and char.touched read their defaults and the raw profile, global and char tables gain no key
MoltenCodes Test: PASS settingsKit.savedVariables: an array default is copied into the raw saved table on its first read, as documented, and Compact removes the unchanged copy
MoltenCodes Test: PASS settingsKit.savedVariables: a validated write stores only the written path in the raw saved table, OnChange reports db, scope, key, value and path, and writing nil brings the default back
MoltenCodes Test: PASS settingsKit.savedVariables: the per-character saved variable is a database of its own: a write to its global scope lands in MoltenCodesTest_SettingsKitCharDB and not in the account table
MoltenCodes Test: PASS settingsKit.writes: writes the schema refuses raise at the writing line in SettingsKitSuite.lua with SchemaKit's text and store nothing: scale 7, anchor LEFT, frame.x a string
MoltenCodes Test: PASS settingsKit.writes: an undeclared field of the closed profile record and a fifth aura past max 4 are refused at the writing line, and the section keeps its four entries
MoltenCodes Test: PASS settingsKit.writes: Open, OnChange, SetProfile, DeleteProfile and a write to the database object are refused at the calling line in SettingsKitSuite.lua
MoltenCodes Test: PASS settingsKit.writes: Validate answers false with exactly the text the refused write raises and true for a valid value, and writes nothing to the raw saved table
MoltenCodes Test: PASS settingsKit.profiles: SetProfile to a new profile creates it in the raw saved table, records it under the character key in profileKeys and fires OnProfileChanged; switching back returns to the character profile
MoltenCodes Test: PASS settingsKit.profiles: CopyProfile replaces the current profile with a deep copy of another's saved values, fires OnProfileCopied and keeps db.profile the same view
MoltenCodes Test: PASS settingsKit.profiles: ResetProfile empties the current profile's raw table in place, so every field reads its default, and fires OnProfileReset
MoltenCodes Test: PASS settingsKit.profiles: DeleteProfile removes a profile from the raw saved table and from GetProfiles, fires OnProfileDeleted, and a view kept from it reads defaults and refuses writes at the writing line
MoltenCodes Test: PASS settingsKit.profiles: GetProfiles answers a fresh array sorted with <, always holding the character profile
MoltenCodes Test: PASS settingsKit.migrations: a table written by an older version runs migrations 2 and 3 once each, in ascending order, on the raw table, and stores version 3
MoltenCodes Test: PASS settingsKit.migrations: a new, empty saved table is stamped with the version and no migration runs
MoltenCodes Test: PASS settingsKit.migrations: a migration that raises stops Open at the calling line naming the step, keeps the finished step, and the next Open retries from the failing step only
MoltenCodes Test: PASS settingsKit.migrations: a stored version above options.version is left alone and no migration runs
MoltenCodes Test: PASS settingsKit.migrations: a stored version above options.version opens read-only: IsReadOnly is true, reads work, a view write and SetProfile are refused at the calling line with the exact message, and the saved table and its version stay unchanged
MoltenCodes Test: PASS settingsKit.migrations: allowNewerData opens a stored version above options.version writable, and neither a write nor ResetDatabase lowers the stored version
MoltenCodes Test: PASS settingsKit.migrations: a migration step that writes and then raises leaves the saved table untouched, and the retry applies the step once: scale 1 becomes 2, not 4
MoltenCodes Test: PASS settingsKit.migrations: a scalar stored where the schema declares a record reads as absent: the default view answers frame.x 0, and the next write replaces the scalar
MoltenCodes Test: PASS settingsKit.allocation: reads through views of the real saved variable (scale, frame.x, a held auras entry's shown, char.touched, global.counter) allocate nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.allocation: a validated write of an existing key with a plain value allocates nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.allocation: Validate of a plain value with an array path allocates nothing over 5000 cycles
MoltenCodes Test: PASS settingsKit.secrets: a secret string and a secret number stored in the raw saved table behind profile.label and profile.frame.x read back through the views still secret, of their types, without raising
MoltenCodes Test: PASS settingsKit.secrets: Compact walks a profile holding a secret without raising and leaves the secret in place
MoltenCodes Test: PASS settingsKit.secrets: writing a secret value, or a table holding one, through a view raises at the writing line with 'refused a secret value' and the raw saved table is unchanged
MoltenCodes Test: PASS settingsKit.secrets: Validate refuses a secret key on the path with 'refused a secret key' and stores nothing
MoltenCodes Test: PASS settingsKit.secrets: a secret key never reads or stores: db.profile[secret], db.profile.auras[secret], db[secret] and db.profile[secret] = 1 each raise at this file's line, and the raw profile gains no key
MoltenCodes Test: PASS settingsKit.secrets: OnChange and Validate refuse a secret scope, Open a secret version and SetLimits a secret value, each at the calling line before comparing it, and the limits stay as they were
MoltenCodes Test: SKIP settingsKit.persistence: persistence step one: profile.scale 1.25, profile.anchor at its default, char.note, the per-character global.note and a marker are written through the views and stored in both raw saved tables -- a marker from an earlier session is present; step two reads it, so nothing is rewritten
MoltenCodes Test: PASS settingsKit.persistence: persistence step two: after /reload the client restored both saved tables after this file ran (nil at file scope) and before the loaded phase, and the views read back the marker, scale 1.25, char.note and the per-character note
MoltenCodes Test: PASS settingsKit.persistence: persistence step two: the PLAYER_LOGOUT compaction removed profile.anchor, written equal to its default in step one, before the client wrote the file, and kept scale
MoltenCodes Test: PASS settingsKit.cleanup: cleanup: once persistence step two passed, both saved variables are emptied so the files hold no data after the next /reload
MoltenCodes Test: settingsKit: 39 passed, 0 failed, 1 skipped, 0 timed out (40 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The totals line reads `39 passed, 0 failed, 1 skipped, 0 timed out (40 tests)`.
Step two logs `marker restored by the client: <token>` and `verified at
<date>`; the compaction test logs `restored profile keys: scale`; the cleanup
test logs `both saved variables are empty; /reload or log out to write the
empty files`. Now `/reload` once more (step 4 above).

### Running again in the same session

After the cleanup test, every test that needs the two databases ends as
`SKIP` with `the cleanup test emptied both saved variables in this session;
/reload to test again`, and the cleanup test with `already emptied in this
session; /reload writes the empty files`: the totals read `11 passed, 0 failed,
29 skipped, 0 timed out (40 tests)` (the facade and migration tests still
run). After the next `/reload` the procedure starts again at run 1.

Running run 1 a second time before the `/reload` prints the run 1 lines again;
step one rewrites the marker with a new token.

## Visible side effects

None in the game: nothing is drawn, no sound plays, no chat line other than
the harness's appears, no client setting (CVar) changes and no request goes to
the server. `UnitName`, `GetRealmName`, `UnitClass` and `UnitFactionGroup`
are only read. The only thing a player could notice is the short stutter of
the three full garbage collections. On disk, the two
`MoltenCodesTest_SettingsKit.lua` files exist between run 1 and the final
`/reload`.

## What stays for the session

- The two databases stay open (SettingsKit keeps one database per saved
  variable for the session, with its `PLAYER_LOGOUT` compaction listener).
  Between run 1 and run 2 the saved tables hold what step one wrote; every
  other test's After hook removes what it wrote (the `frame`, `color`,
  `auras` and `label` profile fields, the `touched` field and any entry it
  leaves empty in `char`, `realm`, `class` and `faction`, the per-character
  `global.probe`), switches back to the character profile, deletes the
  `MoltenCodesTest scratch A` and `B` profiles and puts the character's
  `profileKeys` entry back as it was at open. It disconnects every
  `OnChange` and profile listener the tests connected.
- The migration and secret-option tests open databases over scratch globals
  named `MoltenCodesTest_SettingsKitScratch_<purpose>_<n>`. They are not saved
  variables; the After hook removes the globals, but SettingsKit keeps each
  database it opened in its package state for the session (a few small tables
  per test; `/reload` releases them).
- SettingsKit's shared limits are never changed: the only `SetLimits` call is
  a refusal the test checks against `GetLimits()` before and after.

### On a client without secret values

The 6 `settingsKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. Without them they print `SKIP ... -- the
client has no issecretvalue and secretwrap; the secret path was not
exercised`, and the totals read 31 and 33 passed with 9 and 7 skipped.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('settingsKit', 1) is the SettingsKit facade ...` | The facade the client loaded is API 1 with `Open`, `SetLimits`, `GetLimits`, `UNBOUNDED`, `DEFAULT_PROFILE` `"Default"`, `MAX_PROFILE_NAME_LENGTH` 64 and a `Database` prototype carrying all seventeen documented methods, `IsReadOnly` included. |
| `the installed SettingsKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's (5), not an older or newer embedded copy. |
| `GetLimits answers a fresh table ...` | A new table per call holding `maxProfileNameLength` 64 and `pathKeyLimit` 32; a difference means another addon changed the shared limits. |
| `Open over the two saved variables of the toc ...` | After the loaded phase, `Open` works on the tables the client restored (or creates them on a first install), stamps `version` 2 and 1, creates all eight layout sections, `GetSavedVariable` names each global, a second `Open` (with or without the schema) returns the same database, and views report `getmetatable` `"SettingsKit.View"`. The log says what the client restored at the loaded phase. |
| `the current profile and the char scope are keyed '<name> - <realm>' ...` | With `defaultProfile = "char"`, the current profile is `UnitName("player") .. " - " .. GetRealmName()` from the live client, its table exists in the saved `profiles`, and a write through `db.char` lands in `char["<name> - <realm>"]`. The log gives the key. |
| `the realm, class and faction scopes are keyed ...` | Writes through `db.realm`, `db.class` and `db.faction` land under the live realm, the class file (`"MAGE"`) and the faction group. The log gives the three keys. |
| `reading defaults writes nothing ...` | Reading record, keyed-section (wildcard) and scalar defaults leaves the raw profile, `global` and `char` tables with exactly the keys they had. |
| `an array default is copied into the raw saved table on its first read ...` | The documented exception: the first read of the array default `color` stores a copy (the same table the read returned), and `Compact` removes it again while unchanged. |
| `a validated write stores only the written path ...` | `profile.frame.x = 120` stores `frame = { x = 120 }` and nothing else, `OnChange` receives the database, `"profile"`, `"x"`, `120` and `"frame"`, an entry write reports path `auras[118]`, and writing `nil` removes the value so the default reads again. |
| `the per-character saved variable is a database of its own ...` | A write to the per-character database's `global` lands in `MoltenCodesTest_SettingsKitCharDB`, not in the account table. |
| `writes the schema refuses raise at the writing line ...` | `scale = 7`, `anchor = "LEFT"` and `frame.x = "wide"` raise at this file's writing line with `SettingsKit (MoltenCodesTest_SettingsKitDB) profile.scale: expected number <= 2, found larger number`, `... profile.anchor: expected one of "TOP", "CENTER", "BOTTOM", found unlisted string` and `... profile.frame.x: expected number, found string`, and nothing is stored. |
| `an undeclared field of the closed profile record and a fifth aura ...` | `profile.width = 1` raises `... profile.width: expected only declared fields, found undeclared field`, and the fifth entry of a keyed section with `max = 4` raises `... profile.auras: expected at most 4 entries`, both at the writing line; four entries stay. |
| `Open, OnChange, SetProfile, DeleteProfile and a write to the database object ...` | Six argument errors name this file at the calling line: a non-string saved-variable name, a reopen with a different schema table, an undeclared scope, a whitespace-only profile name, deleting the current profile, and writing a field of the database. |
| `Validate answers false with exactly the text ...` | `Validate` returns the exact refusal text (no position) for `scale = 7`, `true` for a valid array path and a dotted path, and stores nothing. |
| `SetProfile to a new profile ...` | A new profile gets an empty saved table, the choice is recorded in `profileKeys["<name> - <realm>"]`, `OnProfileChanged` receives name and previous, a repeated `SetProfile` answers `false` without a signal, and switching back gives the same character-profile view. |
| `CopyProfile replaces the current profile ...` | The current profile's saved table becomes a deep copy (a new `frame` table) of the source's, its own values are gone, `db.profile` stays the same view, and `OnProfileCopied` receives from and to. |
| `ResetProfile empties the current profile's raw table in place ...` | The same saved table is emptied, every field reads its default, and `OnProfileReset` receives the name. |
| `DeleteProfile removes a profile ...` | The profile leaves the saved table and `GetProfiles`, `OnProfileDeleted` fires, and a view kept from it reads defaults and raises `... profile belongs to a profile that was deleted or reset away` at the writing line without resurrecting it. |
| `GetProfiles answers a fresh array sorted with < ...` | A new array per call, sorted, holding the character profile. The log lists the profiles. |
| `a table written by an older version runs migrations 2 and 3 ...` | Steps 2 and 3 run once each in ascending order on the raw table (step 2 restructures a flat table into `profiles.Default`), `version` becomes 3, and the view reads the migrated value. |
| `a new, empty saved table is stamped with the version ...` | No migration runs on a new install, and `version` is stamped. |
| `a migration that raises stops Open ...` | `SettingsKit:Open migration 3 of <name> failed: step three is not ready` at this file's calling line, `version` 2 stays stored, and the next `Open` runs step 3 only. |
| `a stored version above options.version is left alone ...` | A downgrade runs nothing and keeps `version` 5. |
| `a stored version above options.version opens read-only ...` | Over a scratch global holding `version` 5, `Open` with `version = 2` answers `IsReadOnly()` `true` and reads `profile.scale` 1.5; `db.profile.scale = 1` raises `SettingsKit (<name>) profile is read-only: the saved table has version 5, newer than options.version 2; pass options.allowNewerData = true to SettingsKit:Open to write it` and `db:SetProfile("Other")` raises `SettingsKit.Database:SetProfile cannot change <name>, which is read-only: ...`, both at this file's calling line, and the saved table is exactly as written (no layout, no profile, `version` 5). |
| `allowNewerData opens a stored version above options.version writable ...` | With `allowNewerData = true` the same table is writable (`IsReadOnly()` `false`, the write stored), and `version` stays 5 after the write and after `ResetDatabase`. |
| `a migration step that writes and then raises ...` | A step that doubles `scale` and then raises stops `Open` at this file's calling line with `SettingsKit:Open migration 2 of <name> failed: interrupted after writing`, the scratch table still reads `version` 1 and `scale` 1, and the retry leaves `scale` 2 and `version` 2. |
| `a scalar stored where the schema declares a record reads as absent ...` | With `profiles.Default.frame = 5` saved, `db.profile.frame` is a view reading `x` 0 while the raw 5 stays, and `db.profile.frame.x = 3` replaces it with `{ x = 3 }`. |
| `reads through views of the real saved variable ... allocate nothing` | After a full collection in a step of its own and one unmeasured cycle, 5000 rounds of six view reads (a scalar, a nested record field, a held and a re-read keyed-section entry, `char` and `global`) move `collectgarbage("count")` by at most 1 KB. The log gives the delta. |
| `a validated write of an existing key ... allocates nothing` | The same for 5000 validated writes of `frame.y`. |
| `Validate of a plain value with an array path allocates nothing` | The same for 5000 `Validate` calls. |
| `a secret string and a secret number stored in the raw saved table ...` | A secret placed straight into the saved table (as another writer could) reads back through `db.profile.label` and `db.profile.frame.x` without raising, still secret, and still a string and a number (only `issecretvalue` and `type` are used: a secret cannot be compared). |
| `Compact walks a profile holding a secret ...` | `Compact` does not raise on a secret and keeps it, since a secret never equals a default. |
| `writing a secret value, or a table holding one ...` | `profile.label = secret`, `profile.frame = { x = secret }` and `char.note = secret` raise `... refused a secret value: saved variables never hold secret values` at the writing line, nothing is stored, and `Validate` answers the same text. |
| `Validate refuses a secret key on the path ...` | `Validate("profile", { secretKey }, ...)` answers `... profile refused a secret key: saved variables never hold secret values` and stores nothing. |
| `a secret key never reads or stores ...` | `db.profile[secret]`, `db.profile.auras[secret]`, `db[secret]` and `db.profile[secret] = 1` each raise at this file's line and the raw profile gains no key. The log says, for each, whether SettingsKit refused it (`... cannot be read with a secret key`, `... refused a secret key ...`) or the client refused the key before any metamethod ran (`cannot be indexed with secret keys`); both pass, and the log is the fact to send back. |
| `OnChange and Validate refuse a secret scope ...` | `... OnChange scope must not be a secret value`, `... Validate scope must not be a secret value`, `SettingsKit:Open options.version must not be a secret value` (no global created) and `SettingsKit:SetLimits limits.pathKeyLimit must not be a secret value`, each at the calling line, and the limits are unchanged. |
| `persistence step one: ...` | Run 1: `scale` 1.25, `anchor` at its default `"CENTER"`, `char.note`, the per-character `global.note` and the marker `global.persistence` are written through the views and are in both raw saved tables, `anchor` included (a write of a default-equal value is stored until compaction). Run 2: `SKIP`, keeping the restored marker. |
| `persistence step two: after /reload the client restored both saved tables ...` | Run 2: both globals were `nil` when this file ran and tables at the loaded phase (so a database opened at file scope would have been replaced), the restored tables carry `version` 2 and 1, the current profile is still `"<name> - <realm>"`, and the views read back the marker's token, `scale` 1.25, `char.note` and the per-character `global.note` the client wrote to disk. It then records `verifiedAt` in the marker. Run 1: `SKIP`. |
| `persistence step two: the PLAYER_LOGOUT compaction removed profile.anchor ...` | Run 2: in the table the client restored, `anchor` (default-equal in step one) is gone and `scale` stays, so the EventKit `PLAYER_LOGOUT` compaction ran before the client wrote the file. Run 1: `SKIP`. |
| `cleanup: once persistence step two passed ...` | Run 2: sets both saved-variable globals to `nil`, so the next `/reload` writes files without them. Run 1: `SKIP`, keeping the tables for run 2. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a totals line other than the ones above, or a
  `SKIP` other than the listed ones.
- Run 2 printing `run again after /reload: no marker from an earlier session
  yet ...` for the step-two tests: the client did not write or restore
  `MoltenCodesTest_SettingsKitDB`. Check that the `.toc` was installed with its
  `## SavedVariables` lines and that the file exists on disk.
- `the marker was written by another character; log in with it and run
  again`: run 2 was made on a different character; switch back.
- `persistence step two: after /reload ...` failing on `expected string
  "table" to be string "nil"`: the client restored a saved variable before
  this file ran, which contradicts the documented load order.
- The compaction test failing on `anchor`: the `PLAYER_LOGOUT` compaction did
  not run before the client saved (or EventKit was not loaded).
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_SettingsKit`. Every error the suite
  provokes is caught by the test itself.
- After the final `/reload`, either `MoltenCodesTest_SettingsKit.lua` file
  still holding a table.

## What to send back

1. The chat lines of both runs as they appeared (a screenshot, or a copy of the
   chat log), including any line that differs.
2. After run 1's `/reload`, a copy of
   `WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` (run 2 replaces
   the `settingsKit` entry in it) and of both `MoltenCodesTest_SettingsKit.lua`
   files (paths above), which show what the client wrote to disk.
3. After the final `/reload`, `MoltenCodesTest.lua` again, and both
   `MoltenCodesTest_SettingsKit.lua` files as they are (they should hold no
   table). `MoltenCodesTest.lua` holds the full report of the run, each
   test's logs (the character key, the scope keys, the three memory deltas,
   which refusal each secret key met, every error message with its position)
   and the client facts. Lua shortens a long file path from the left, so a
   logged message may start with `...`; the tests compare only the
   `SettingsKitSuite.lua:<line>` part.
4. The text of any Lua error, with `/console scriptErrors 1` turned on.
5. The list of other enabled addons, when a test failed.
