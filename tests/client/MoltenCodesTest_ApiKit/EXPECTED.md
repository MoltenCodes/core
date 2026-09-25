# Expected result: `/mct run apiKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package apiKit`
on Retail, with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_era_ --package apiKit`
on Classic Era, or with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --flavour-dir _classic_ --package apiKit`
on Mists of Pandaria Classic, and nothing else from the MoltenCodes framework
enabled in the client. Run it out of combat. The lines below are those of a
Retail 12.1.0 client; [Per flavour](#per-flavour) gives the two Classic
clients, whose test names and expected values follow their own committed
metadata.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for apiKit. Type /mct run apiKit to run them; /mct help lists every command.
```

## After `/mct run apiKit`

Within a few seconds, exactly these lines, in this order (`PASS` is green in
the client). The three binding tests walk every client global and every `C_`
namespace, and the two allocation tests each run a full garbage collection
first, so the client may stutter for a moment:

```text
MoltenCodes Test: running apiKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS apiKit.facade: Registry:Get('apiKit', 1) is the ApiKit facade with API 1, its four methods and the five SUPPORTED_FLAVORS in table order
MoltenCodes Test: PASS apiKit.facade: the installed ApiKit carries the revision of the committed manifest
MoltenCodes Test: PASS apiKit.flavour: GetFlavor() is 'retail' because the client reports WOW_PROJECT_ID 1 and neither IsTestBuild() nor IsBetaBuild(); the facts are logged
MoltenCodes Test: PASS apiKit.flavour: GetMetadataBuild('retail') is 12.1.0 build 69933 and names the client's own GetBuildInfo() version; the two builds are logged side by side
MoltenCodes Test: PASS apiKit.flavour: all five flavour files of the bundle registered their metadata: GetMetadataBuild answers the committed version and build of every flavour, installed or not
MoltenCodes Test: PASS apiKit.namespaces: GetGlobalStatus() is 'published' and the wow global is MoltenCodes.wow itself
MoltenCodes Test: PASS apiKit.namespaces: MoltenCodes.wow holds retail, classic.era, classic.mop, ptr and beta, and only retail.api is filled: the four other api tables are empty
MoltenCodes Test: PASS apiKit.bindings: every function of the installed Retail surface is the very host function the naming rules name: C_ namespace members and global functions compared by identity, every relocated binding's host member present, counts logged
MoltenCodes Test: PASS apiKit.bindings: named samples are the host's own functions: api.timer.newTicker is C_Timer.NewTicker, api.unit.name is UnitName, api.build.getBuildInfo is GetBuildInfo, api.restrictedActions.inCombatLockdown is InCombatLockdown, and api.profiler is api.addOnProfiler
MoltenCodes Test: PASS apiKit.bindings: host functions of C_Timer, C_AddOns, C_Spell, C_Item and other watched namespaces that the capture does not bind are logged as client additions, and every C_ namespace the client has but the surface lacks is counted
MoltenCodes Test: PASS apiKit.data: api.events holds 1782 event strings, each named by its own lowerCamelCase, api.events.playerLogin is 'PLAYER_LOGIN', and the client's C_EventUtils.IsEventValid is asked about every one
MoltenCodes Test: PASS apiKit.data: every api.enums entry is the client's Enum table of the same name, api.enums.itemQuality.Epic is Enum.ItemQuality.Epic, and Enum tables the capture lacks are logged
MoltenCodes Test: PASS apiKit.data: every api.constants entry is the client's Constants table of the same name, api.constants.auctionConstants is Constants.AuctionConstants
MoltenCodes Test: PASS apiKit.calls: read-only getters called through the wrapper answer exactly what the raw calls answer: GetBuildInfo, the build probes, GetLocale, UnitName, UnitClass, C_AddOns, C_CVar.GetCVar, C_EventUtils.IsEventValid, C_Map.GetBestMapForUnit and others
MoltenCodes Test: PASS apiKit.allocation: looking up wow.retail.api, api.timer.newTicker, api.unit.name, api.events.playerLogin, api.enums.itemQuality and an empty flavour's table again allocates nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.allocation: GetFlavor, GetGlobalStatus, GetMetadataBuild('retail') and a getter called through the wrapper allocate nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.errors: GetFlavor called with a dot names ApiKitSuite.lua at the calling line
MoltenCodes Test: PASS apiKit.errors: RegisterFlavor with an unknown flavour, a non-function installer, an info that is not a table, a numeric info.version and a fractional info.build is refused at the calling line, runs nothing and leaves the metadata as it was
MoltenCodes Test: PASS apiKit.errors: GetMetadataBuild with an unknown flavour and a write to SUPPORTED_FLAVORS are refused at the calling line
MoltenCodes Test: PASS apiKit.errors: a second registration of the running flavour and a registration of the Public Test Realm on this client are dropped: both return false, neither installer runs, the surface and the metadata stay as they were
MoltenCodes Test: PASS apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs
MoltenCodes Test: PASS apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was
MoltenCodes Test: PASS apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Retail flavour returns false without raising and its metadata stays the committed one
MoltenCodes Test: apiKit: 23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines.

## Visible side effects

None. Nothing is drawn, no sound plays, no chat line other than the
harness's appears, and nothing is sent. The getters the calls test runs are
read-only: `C_CVar.GetCVar("scriptErrors")` reads one setting and changes
none, and `C_AddOns.GetAddOnMetadata("MoltenCodes", "Title")` reads the
bundle's `.toc`. The only thing a player can notice is a short stutter while
the binding tests walk the global table and the allocation tests collect
garbage.

## What stays for the session

Nothing. The registration tests call `RegisterFlavor` for the running flavour
(Retail here), which is already installed, and for the Public Test Realm,
which this client does not run, passing exactly the metadata each flavour
file already registered; both
calls are dropped, record nothing new and never run the installer this file
hands over. Every refused call is refused before it records anything.
Nothing is written to a global or a saved variable other than the harness's
own results.

### On a client without secret values

The three `apiKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(`FrameScriptDocumentation`, mirrored in
`packages/apiKit/metadata/retail/namespaces.json`) lists it with no
restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these three lines instead, and the totals
line reads `20 passed, 0 failed, 3 skipped, 0 timed out (23 tests)`:

```text
MoltenCodes Test: SKIP apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Retail flavour returns false without raising and its metadata stays the committed one -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

A client that has both functions but makes no secret with them (the harness
asks once whether `issecretvalue` reports what `secretwrap` returns as
secret) skips the same three tests with the harness's own reason, and the
totals line is the same
`20 passed, 0 failed, 3 skipped, 0 timed out (23 tests)`:

```text
MoltenCodes Test: SKIP apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
MoltenCodes Test: SKIP apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Retail flavour returns false without raising and its metadata stays the committed one -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
```

On Retail 12.1 any `SKIP` is unexpected.

## Per flavour

The suite runs the same 9 suites and 23 tests on every flavour. What it
expects of the running client is the row of `FLAVOUR_EXPECTATIONS` in
`ApiKitSuite.lua` that `Harness:GetFlavour()` names, taken from the committed
metadata of that flavour (`packages/apiKit/README.md`, "Flavours", and
`packages/apiKit/metadata/<flavour>/`):

| | Retail | Classic Era | Mists of Pandaria Classic |
|---|---|---|---|
| `GetFlavor()` and `WOW_PROJECT_ID` | `retail`, 1, both build probes `false` | `classic-era`, 2 | `classic-mop`, 19 |
| committed metadata | 12.1.0 build 69933 | 1.15.9 build 69722 | 5.5.4 build 69934 |
| filled `api` table | `wow.retail.api` | `wow.classic.era.api` | `wow.classic.mop.api` |
| at most namespaces / bound functions | 312 / 4,900 | 261 / 3,229 | 261 / 3,230 |
| events (exact) / at most enumerations | 1,782 / 844 | 1,483 / 740 | 1,483 / 740 |
| named samples / getters compared | 12 / 23 | 10 / 16 | 10 / 16 |
| getters of the second allocation test | `api.systemTime.getTime`, `api.build.isTestBuild` | `api.locale.getLocale`, `api.build.isBetaBuild` | the same as Classic Era |

ApiKit consults `IsTestBuild()` and `IsBetaBuild()` for Retail's project id
only (`packages/apiKit/docs/API.md`, "Flavour detection"), so on a Classic
client the detection test expects only the project id and `GetFlavor()`, and
logs the probes as the client answers them. The Classic Era and Mists
metadata do not document `GetBuildInfo`, `GetTime`, `IsTestBuild`,
`IsPublicBuild`, `IsWindowsClient`, `IsMacClient`, `IsLoggedIn` or
`UnitLevel`, so the Classic surfaces bind none of them: the samples test
leaves out `api.build.getBuildInfo` and `api.systemTime.getTime`, and the
calls test leaves out those two and the other six. Every other sample, getter,
watched namespace (`C_Timer` to `C_DateAndTime`), event
(`PLAYER_LOGIN`, `ADDON_LOADED`, `PLAYER_ENTERING_WORLD`), enumeration
(`ItemQuality` with `Epic`, `PhaseReason`), constants table
(`AuctionConstants`) and the seven relocated bindings are documented by all
three flavours at the same host paths. The build test reads the client's
`GetBuildInfo()`, a core global every client has although the Classic
metadata does not list it. Its version check holds the committed Classic
metadata to the running Classic client just as on Retail: a client on
another patch than 1.15.9 or 5.5.4 fails it until that flavour's metadata is
refreshed.

### Retail (12.1)

The lines above:
`MoltenCodes Test: apiKit: 23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)`,
with no `SKIP` line.

### Classic Era (1.15)

Exactly these lines, in this order, when the client makes secret values:

```text
MoltenCodes Test: running apiKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS apiKit.facade: Registry:Get('apiKit', 1) is the ApiKit facade with API 1, its four methods and the five SUPPORTED_FLAVORS in table order
MoltenCodes Test: PASS apiKit.facade: the installed ApiKit carries the revision of the committed manifest
MoltenCodes Test: PASS apiKit.flavour: GetFlavor() is 'classic-era' because the client reports WOW_PROJECT_ID 2, which ApiKit maps without consulting IsTestBuild() or IsBetaBuild(); the facts are logged
MoltenCodes Test: PASS apiKit.flavour: GetMetadataBuild('classic-era') is 1.15.9 build 69722 and names the client's own GetBuildInfo() version; the two builds are logged side by side
MoltenCodes Test: PASS apiKit.flavour: all five flavour files of the bundle registered their metadata: GetMetadataBuild answers the committed version and build of every flavour, installed or not
MoltenCodes Test: PASS apiKit.namespaces: GetGlobalStatus() is 'published' and the wow global is MoltenCodes.wow itself
MoltenCodes Test: PASS apiKit.namespaces: MoltenCodes.wow holds retail, classic.era, classic.mop, ptr and beta, and only classic.era.api is filled: the four other api tables are empty
MoltenCodes Test: PASS apiKit.bindings: every function of the installed Classic Era surface is the very host function the naming rules name: C_ namespace members and global functions compared by identity, every relocated binding's host member present, counts logged
MoltenCodes Test: PASS apiKit.bindings: named samples are the host's own functions: api.timer.newTicker is C_Timer.NewTicker, api.unit.name is UnitName, api.locale.getLocale is GetLocale, api.restrictedActions.inCombatLockdown is InCombatLockdown, and api.profiler is api.addOnProfiler
MoltenCodes Test: PASS apiKit.bindings: host functions of C_Timer, C_AddOns, C_Spell, C_Item and other watched namespaces that the capture does not bind are logged as client additions, and every C_ namespace the client has but the surface lacks is counted
MoltenCodes Test: PASS apiKit.data: api.events holds 1483 event strings, each named by its own lowerCamelCase, api.events.playerLogin is 'PLAYER_LOGIN', and the client's C_EventUtils.IsEventValid is asked about every one
MoltenCodes Test: PASS apiKit.data: every api.enums entry is the client's Enum table of the same name, api.enums.itemQuality.Epic is Enum.ItemQuality.Epic, and Enum tables the capture lacks are logged
MoltenCodes Test: PASS apiKit.data: every api.constants entry is the client's Constants table of the same name, api.constants.auctionConstants is Constants.AuctionConstants
MoltenCodes Test: PASS apiKit.calls: read-only getters called through the wrapper answer exactly what the raw calls answer: IsBetaBuild, GetLocale, UnitName, UnitClass, C_AddOns, C_CVar.GetCVar, C_EventUtils.IsEventValid, C_Map.GetBestMapForUnit and others
MoltenCodes Test: PASS apiKit.allocation: looking up wow.classic.era.api, api.timer.newTicker, api.unit.name, api.events.playerLogin, api.enums.itemQuality and an empty flavour's table again allocates nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.allocation: GetFlavor, GetGlobalStatus, GetMetadataBuild('classic-era') and a getter called through the wrapper allocate nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.errors: GetFlavor called with a dot names ApiKitSuite.lua at the calling line
MoltenCodes Test: PASS apiKit.errors: RegisterFlavor with an unknown flavour, a non-function installer, an info that is not a table, a numeric info.version and a fractional info.build is refused at the calling line, runs nothing and leaves the metadata as it was
MoltenCodes Test: PASS apiKit.errors: GetMetadataBuild with an unknown flavour and a write to SUPPORTED_FLAVORS are refused at the calling line
MoltenCodes Test: PASS apiKit.errors: a second registration of the running flavour and a registration of the Public Test Realm on this client are dropped: both return false, neither installer runs, the surface and the metadata stay as they were
MoltenCodes Test: PASS apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs
MoltenCodes Test: PASS apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was
MoltenCodes Test: PASS apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Classic Era flavour returns false without raising and its metadata stays the committed one
MoltenCodes Test: apiKit: 23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Mists of Pandaria Classic (5.5)

Exactly these lines, in this order, when the client makes secret values:

```text
MoltenCodes Test: running apiKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS apiKit.facade: Registry:Get('apiKit', 1) is the ApiKit facade with API 1, its four methods and the five SUPPORTED_FLAVORS in table order
MoltenCodes Test: PASS apiKit.facade: the installed ApiKit carries the revision of the committed manifest
MoltenCodes Test: PASS apiKit.flavour: GetFlavor() is 'classic-mop' because the client reports WOW_PROJECT_ID 19, which ApiKit maps without consulting IsTestBuild() or IsBetaBuild(); the facts are logged
MoltenCodes Test: PASS apiKit.flavour: GetMetadataBuild('classic-mop') is 5.5.4 build 69934 and names the client's own GetBuildInfo() version; the two builds are logged side by side
MoltenCodes Test: PASS apiKit.flavour: all five flavour files of the bundle registered their metadata: GetMetadataBuild answers the committed version and build of every flavour, installed or not
MoltenCodes Test: PASS apiKit.namespaces: GetGlobalStatus() is 'published' and the wow global is MoltenCodes.wow itself
MoltenCodes Test: PASS apiKit.namespaces: MoltenCodes.wow holds retail, classic.era, classic.mop, ptr and beta, and only classic.mop.api is filled: the four other api tables are empty
MoltenCodes Test: PASS apiKit.bindings: every function of the installed Mists of Pandaria Classic surface is the very host function the naming rules name: C_ namespace members and global functions compared by identity, every relocated binding's host member present, counts logged
MoltenCodes Test: PASS apiKit.bindings: named samples are the host's own functions: api.timer.newTicker is C_Timer.NewTicker, api.unit.name is UnitName, api.locale.getLocale is GetLocale, api.restrictedActions.inCombatLockdown is InCombatLockdown, and api.profiler is api.addOnProfiler
MoltenCodes Test: PASS apiKit.bindings: host functions of C_Timer, C_AddOns, C_Spell, C_Item and other watched namespaces that the capture does not bind are logged as client additions, and every C_ namespace the client has but the surface lacks is counted
MoltenCodes Test: PASS apiKit.data: api.events holds 1483 event strings, each named by its own lowerCamelCase, api.events.playerLogin is 'PLAYER_LOGIN', and the client's C_EventUtils.IsEventValid is asked about every one
MoltenCodes Test: PASS apiKit.data: every api.enums entry is the client's Enum table of the same name, api.enums.itemQuality.Epic is Enum.ItemQuality.Epic, and Enum tables the capture lacks are logged
MoltenCodes Test: PASS apiKit.data: every api.constants entry is the client's Constants table of the same name, api.constants.auctionConstants is Constants.AuctionConstants
MoltenCodes Test: PASS apiKit.calls: read-only getters called through the wrapper answer exactly what the raw calls answer: IsBetaBuild, GetLocale, UnitName, UnitClass, C_AddOns, C_CVar.GetCVar, C_EventUtils.IsEventValid, C_Map.GetBestMapForUnit and others
MoltenCodes Test: PASS apiKit.allocation: looking up wow.classic.mop.api, api.timer.newTicker, api.unit.name, api.events.playerLogin, api.enums.itemQuality and an empty flavour's table again allocates nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.allocation: GetFlavor, GetGlobalStatus, GetMetadataBuild('classic-mop') and a getter called through the wrapper allocate nothing over 2000 rounds
MoltenCodes Test: PASS apiKit.errors: GetFlavor called with a dot names ApiKitSuite.lua at the calling line
MoltenCodes Test: PASS apiKit.errors: RegisterFlavor with an unknown flavour, a non-function installer, an info that is not a table, a numeric info.version and a fractional info.build is refused at the calling line, runs nothing and leaves the metadata as it was
MoltenCodes Test: PASS apiKit.errors: GetMetadataBuild with an unknown flavour and a write to SUPPORTED_FLAVORS are refused at the calling line
MoltenCodes Test: PASS apiKit.errors: a second registration of the running flavour and a registration of the Public Test Realm on this client are dropped: both return false, neither installer runs, the surface and the metadata stay as they were
MoltenCodes Test: PASS apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs
MoltenCodes Test: PASS apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was
MoltenCodes Test: PASS apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Mists of Pandaria Classic flavour returns false without raising and its metadata stays the committed one
MoltenCodes Test: apiKit: 23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Secret values on the Classic clients

Both Classic flavours document `issecretvalue` and `secretwrap`. Whether the
three `apiKit.secrets` tests run depends on one answer only the running
client gives: whether its `secretwrap` makes a value `issecretvalue` reports
as secret.

- When it does, the totals line is the one above:
  `MoltenCodes Test: apiKit: 23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)`.
- When it does not, the three secrets lines are `SKIP` and the totals line is
  `MoltenCodes Test: apiKit: 20 passed, 0 failed, 3 skipped, 0 timed out (23 tests)`.
  On Classic Era:

  ```text
  MoltenCodes Test: SKIP apiKit.secrets: a secret flavour id handed to RegisterFlavor and to GetMetadataBuild is refused at the calling line before it is used as a key, and no installer runs -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  MoltenCodes Test: SKIP apiKit.secrets: a secret info.build is refused at the calling line before its integer test, runs no installer and leaves the Retail metadata as it was -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  MoltenCodes Test: SKIP apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Classic Era flavour returns false without raising and its metadata stays the committed one -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  ```

  On Mists of Pandaria Classic the first two lines are the same and the third
  reads:

  ```text
  MoltenCodes Test: SKIP apiKit.secrets: a secret info.version is accepted, as docs/API.md says: the registration of the installed Mists of Pandaria Classic flavour returns false without raising and its metadata stays the committed one -- the client makes no secret values (issecretvalue does not report what secretwrap returns as secret)
  ```

## What the logs hold

The saved results carry each test's log lines. The ones worth reading on
every run:

| Test | Log |
|---|---|
| `GetFlavor() is 'retail' ...` | `WOW_PROJECT_ID`, `WOW_PROJECT_MAINLINE`, `IsTestBuild()`, `IsBetaBuild()` and `IsPublicTestClient()` as the client answers them. |
| `GetMetadataBuild('retail') is 12.1.0 build 69933 ...` | The metadata's version and build next to `GetBuildInfo()`'s version, build, date and interface, and either "the client runs the build the Retail metadata was captured from" or how many builds apart the two are. A different build is logged, not failed; a different version fails. |
| `every function of the installed Retail surface is the very host function ...` | How many namespaces and functions are installed next to the documented 312 and 4,900, how many come from `C_` namespaces and how many are global functions, how many documented functions this client lacks, how many of the seven relocated bindings are bound, and every binding that is not the host function the rules name or that no host name resolves (with every host path holding that function), every relocated binding whose host member is missing and every one the surface lacks. |
| `host functions of C_Timer, C_AddOns, C_Spell, C_Item and other watched namespaces ...` | For twelve namespaces (`C_Timer`, `C_AddOns`, `C_Spell`, `C_Item`, `C_UnitAuras`, `C_Map`, `C_ChatInfo`, `C_EncodingUtil`, `C_CVar`, `C_Container`, `C_EventUtils`, `C_DateAndTime`): the host's functions, how many are bound, and the names of the unbound ones, which are functions the client has that the captured documentation does not describe. Then the totals over every `C_` namespace, and the `C_` namespaces the surface binds nothing of. |
| `api.events holds 1782 event strings ...` | The count, any key that is not its event's lowerCamelCase, and every event `C_EventUtils.IsEventValid` answers `false` for. |
| `every api.enums entry ...`, `every api.constants entry ...` | The entries, any that is not the client's table of the same name, and the client's `Enum` and `Constants` tables the capture does not alias. |
| `read-only getters called through the wrapper ...` | Each getter's value count and values (only their types for `UnitName`, `UnitGUID` and `GetRealmName`, which identify the player), or `<secret>` for a secret. |
| the allocation tests | The memory delta over 2000 rounds. |
| the errors and secrets tests | The client's own error messages with their paths. |

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('apiKit', 1) is the ApiKit facade ...` | The facade the client loaded is API 1 with `GetFlavor`, `GetGlobalStatus`, `RegisterFlavor` and `GetMetadataBuild`, and `SUPPORTED_FLAVORS` reads `retail, classic-era, classic-mop, ptr, beta` through its read-only view with `SUPPORTED_FLAVOR_COUNT` 5. |
| `the installed ApiKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `GetFlavor() is 'retail' ...` | ApiKit's flavour detection on the client's own facts: `WOW_PROJECT_ID` 1 and neither build probe answering `true` make the Retail row match. |
| `GetMetadataBuild('retail') is 12.1.0 build 69933 ...` | The Retail file the bundle carries registered the committed capture's metadata, and the capture's version is the client's `GetBuildInfo()` version. |
| `all five flavour files of the bundle registered their metadata ...` | The bundle loads all five flavour files and each one called `RegisterFlavor` on this client with its committed version and build (`1.15.9` 69722, `5.5.4` 69934, `12.1.5` 69952, `12.0.1` 66220 besides Retail), although only Retail installed. |
| `GetGlobalStatus() is 'published' ...` | Nothing else owns `wow` on a clean client, so ApiKit published it and it is `MoltenCodes.wow` itself. |
| `MoltenCodes.wow holds retail, classic.era, ...` | The namespace root has exactly `retail`, `classic` (with `era` and `mop`), `ptr` and `beta`; `retail.api` is filled and the four other `api` tables are empty, so the other flavour files' installers did not run. |
| `every function of the installed Retail surface is the very host function ...` | The direct-alias promise over the whole surface. For every function namespace (the alias `profiler` is checked separately), every entry is a function, and it is identical (`rawequal`) to the host function the naming rules of `packages/apiKit/docs/NAMING.md` name: the member of the `C_` namespace whose name matches without the prefix, or the global function named by the system's words and the function's (`unit` + `name` is `UnitName`) or by the function alone (`systemTime.getTime` is `GetTime`). Names are matched lowercased and without underscores, which is exactly what the rules change; the committed rules have no exceptions. The seven functions the tables place outside their system's namespace with their own `Namespace` attribute (`RELOCATED_BINDINGS`, held to the Retail metadata by `tooling/tests/test_api_committed_flavours.py`) are compared with the host function the tables name instead: `api.restrictedActions.inCombatLockdown` with the global `InCombatLockdown`, `api.localization.getDefaultAbbreviationBreakpoints` with `C_StringUtil.GetDefaultAbbreviationBreakpoints`, `api.stringUtil.trim` with `string.trim`, and `api.tableUtil.count`, `create`, `freeze` and `isfrozen` with `table.count`, `table.create`, `table.freeze` and `table.isfrozen`. For these the host path is known, so the walk also checks from the host's side: a host member that is missing, or a present one the surface did not bind, fails the test. That is the class of defect the run of 2026-09-25 found, when the metadata bound `InCombatLockdown` through `C_RestrictedActions` and the wrapper was silently absent. At most 312 namespaces and 4,900 functions, every one resolved, and all seven relocated bindings bound. |
| `named samples are the host's own functions ...` | Twelve readable pairs, each a `wrapper` and its `binding` in `packages/apiKit/metadata/retail/namespaces.json`, such as `api.timer.newTicker == C_Timer.NewTicker`, `api.map.getBestMapForUnit == C_Map.GetBestMapForUnit`, `api.unit.name == UnitName` and `api.restrictedActions.inCombatLockdown == InCombatLockdown` (the global: its documentation marks it `Namespace = ""` in the `C_RestrictedActions` system, and before ApiKit 0.1.4 the metadata bound it through `C_RestrictedActions`, which left the wrapper `nil` on Retail 12.1.0 b69933), and `api.profiler` is the same table as `api.addOnProfiler`. |
| `host functions of C_Timer, C_AddOns, ...` | Logs what the client has beyond the capture; asserts only that each of the twelve watched namespaces the client has is bound. |
| `api.events holds 1782 event strings ...` | The event table has every documented event, each key is its event name in lowerCamelCase, and the three samples hold their event strings. |
| `every api.enums entry is the client's Enum table ...` | Every enumeration alias is the client's own `Enum` table (not a copy), at most 844 of them, with `Enum.ItemQuality.Epic` reached through the alias. |
| `every api.constants entry is the client's Constants table ...` | The same for `Constants`. |
| `read-only getters called through the wrapper ...` | Twenty-three getters (`GetBuildInfo`, the build probes, `GetLocale`, `GetCurrentRegion`, `GetExpansionLevel`, `IsLoggedIn`, `InCombatLockdown`, `UnitName`, `UnitClass`, `UnitLevel`, `UnitFactionGroup`, `UnitGUID`, `GetRealmName`, `C_AddOns`, `C_CVar.GetCVar`, `C_EventUtils.IsEventValid`, `C_Map.GetBestMapForUnit`), each called through the wrapper and raw in the same frame with the same arguments, return the same number of values and the same values. A getter missing on either side counts as a disagreement. |
| `looking up wow.retail.api, api.timer.newTicker, ...` | docs/API.md's "A call through the wrapper is one table index more than the raw call and allocates nothing", for the lookups themselves, on the client's collector: after a full collection in its own step and one warm-up round, 2000 rounds move `collectgarbage("count")` by at most 1 KB. |
| `GetFlavor, GetGlobalStatus, GetMetadataBuild('retail') and a getter ...` | The same for the facade's getters and two getters called through the wrapper ("Nothing in the package grows with use"). |
| `GetFlavor called with a dot ...` | The receiver check raises at this file's calling line, as the client names it. |
| `RegisterFlavor with an unknown flavour, ...` | Each argument refusal of `RegisterFlavor` at the calling line with docs/API.md's wording; the installer never runs and the Retail metadata is unchanged. |
| `GetMetadataBuild with an unknown flavour and a write to SUPPORTED_FLAVORS ...` | The flavour refusal of `GetMetadataBuild`, and the read-only view refusing a write at the writing line. |
| `a second registration of the running flavour and a registration of the Public Test Realm ...` | Both are dropped and return `false`: no installer runs, `retail.api` keeps its keys and tables, `ptr.api` stays empty, the metadata is unchanged. |
| `a secret flavour id handed to RegisterFlavor and to GetMetadataBuild ...` | A genuine secret flavour id is refused with ApiKit's own message at the calling line, so ApiKit asked `issecretvalue` before the client's `cannot be indexed with secret keys` error could arise. |
| `a secret info.build is refused ...` | A secret build is refused before the integer test (arithmetic on a secret raises), and nothing is recorded. |
| `a secret info.version is accepted ...` | docs/API.md's one accepted secret: the call does not raise, returns `false` for the installed flavour, and the metadata stays the committed, non-secret one. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1, or a totals
  line other than `23 passed, 0 failed, 0 skipped, 0 timed out (23 tests)`;
  on a Classic client, a line, a `SKIP` or a totals line that
  [Per flavour](#per-flavour) does not list.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_ApiKit`. Every error the suite
  provokes is caught by the test itself.
- `GetFlavor() is 'retail'` (or `'classic-era'`, `'classic-mop'`) failing:
  the client reports other facts than a live client of that flavour (the log
  has them), or ApiKit read them wrongly.
- `GetMetadataBuild('retail') ...` (or the Classic flavour's) failing on the
  version: the client runs another patch than the committed capture, so that
  flavour's metadata needs a refresh (`packages/apiKit/docs/UPDATING.md`). A
  build difference alone is only logged.
- `GetGlobalStatus() is 'published'` failing: another enabled addon owns the
  `wow` global; say which addons are enabled.
- The identity test failing: the log names every binding that is not the host
  function the rules name, or that no host name resolves, with the host paths
  that do hold it, and every relocated binding whose host member is missing or
  that the surface lacks. Any of them is a defect in the generator, the naming
  rules or the metadata's bindings.
- An allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed ApiKit carries the revision ...` failing: another enabled
  addon embeds a different ApiKit copy.
- An `apiKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`
   (`_classic_era_` or `_classic_` instead of `_retail_` on the Classic
   clients).
   It holds the full report, each test's logs (the flavour facts, both
   builds, the binding counts, the client additions per namespace, the event,
   enumeration and constant comparisons, the getters' values, the memory
   deltas, the client's own error messages with their paths) and the client
   facts. Lua shortens a long file path from the left, so a logged message may
   start with `...`; the tests compare only the `ApiKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
