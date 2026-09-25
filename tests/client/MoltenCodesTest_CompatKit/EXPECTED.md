# Expected result: `/mct run compatKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package compatKit`
and nothing else from the MoltenCodes framework enabled in the client. Run it
out of combat, on Retail 12.1.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for compatKit. Type /mct run compatKit to run them; /mct help lists every command.
```

## After `/mct run compatKit`

Within a second or two, exactly these lines, in this order (`PASS` is green in
the client). The allocation test runs one full garbage collection first, so
the client may stutter for a moment:

```text
MoltenCodes Test: running compatKit: 8 suites. Results follow when every test has finished.
MoltenCodes Test: PASS compatKit.facade: Registry:Get('compatKit', 1) is the CompatKit facade with API 1, its seven methods, a nine-row CATALOGUE and UNBOUNDED; the session's limits and shims are logged
MoltenCodes Test: PASS compatKit.facade: the installed CompatKit carries the revision of the committed manifest
MoltenCodes Test: PASS compatKit.facade: the bundle's ClientKit and ApiKit are found through Registry:Find: ClientKit answers 'mainline' on WOW_PROJECT_MAINLINE, and ApiKit's flavour file for the running client is installed (flavour, metadata build and binding count logged)
MoltenCodes Test: PASS compatKit.shims: Apply runs a shim for the running ClientKit flavour and one without flavours once each, filters one for every other flavour, and hands every shim context.flavour 'mainline'
MoltenCodes Test: PASS compatKit.shims: the highest version registered before Apply is the one that runs; a higher version after Apply is recorded beside the applied one and never run
MoltenCodes Test: PASS compatKit.shims: SkipShim before a shim is registered and after it is pending keeps both from running on every Apply, and both are counted as skipped
MoltenCodes Test: PASS compatKit.context: context.hasApi answers by identity with the installed ApiKit surface: C_Timer.NewTicker and the catalogue's replacements true, the legacy GetAddOnMetadata global and undocumented hooksecurefunc false, and covers records those two missing
MoltenCodes Test: PASS compatKit.context: context.hasGlobal answers what raw reads of the client's global table answer: UIParent and C_Timer.NewTicker present, UIParent.GetName absent (a metatable method), a path through a number absent; Menu, MenuUtil and Settings.OpenToCategory logged
MoltenCodes Test: PASS compatKit.catalogue: CATALOGUE holds docs/EMBEDDING.md's nine rows in order, and every replacementApi (C_TooltipInfo.GetUnit, C_AddOns.GetAddOnMetadata, C_SettingsUtil.OpenSettingsPanel, C_UnitAuras.GetAuraDataByIndex) is a function of this client with the running ApiKit flavour in its flavours (each logged)
MoltenCodes Test: PASS compatKit.catalogue: the FrameXML replacements the catalogue names (Menu, MenuUtil, Settings.OpenToCategory, TooltipDataProcessor.AddTooltipPostCall, UISpecialFrames) and the legacy subsystems it warns about are logged as this client has them
MoltenCodes Test: PASS compatKit.failures: a raising shim is reported once, unchanged, through the handler seterrorhandler installed, naming CompatKitSuite.lua at the raising line; the shim after it still runs, and the failed one is never retried
MoltenCodes Test: PASS compatKit.failures: a shim that calls Apply fails with 'CompatKit:Apply cannot be called from inside a shim' at its own line in CompatKitSuite.lua, is reported, and the next Apply works
MoltenCodes Test: PASS compatKit.providers: a registry whose probes read InCombatLockdown, IsLoggedIn and the chat frame's visibility resolves the highest-priority live provider, a live preferred one, and keeps its memo; List reports each probe's host answer
MoltenCodes Test: PASS compatKit.providers: a raising probe is reported through the handler seterrorhandler installed, naming CompatKitSuite.lua at the raising line, once per Resolve, and counts as dead; a memo hit asks it nothing
MoltenCodes Test: PASS compatKit.providers: Resolve on a memo hit and with a live preferred provider, probed by the client's IsLoggedIn, allocates nothing over 10000 rounds (allocation guard)
MoltenCodes Test: PASS compatKit.errors: Shim, Apply and a registry's Resolve called with a dot name CompatKitSuite.lua at the calling line
MoltenCodes Test: PASS compatKit.errors: Shim refuses a zero version, an unknown option, an empty flavours array and an invalid covers name at the calling line, and registers nothing
MoltenCodes Test: PASS compatKit.errors: Providers with an empty kind, Register with a probe that is not a function or a fractional priority, and SetLimits with an unknown limit are refused at the calling line, changing nothing
MoltenCodes Test: PASS compatKit.errors: writes into the catalogue, a row, a row's flavours and a shim's context, and hasApi or hasGlobal of an empty or non-string name, are refused at the writer's or caller's line
MoltenCodes Test: PASS compatKit.secrets: Shim refuses a secret name, version, description and flavour, SkipShim a secret name, Providers a secret kind and Apply a secret receiver, each at the calling line, registering nothing
MoltenCodes Test: PASS compatKit.secrets: Register refuses a secret implementation and priority, Unregister and Resolve a secret name, and SetLimits a secret limit, each at the calling line, changing nothing
MoltenCodes Test: PASS compatKit.secrets: context.hasApi and context.hasGlobal refuse a secret name at the shim's line in CompatKitSuite.lua
MoltenCodes Test: PASS compatKit.secrets: a shim raising a secretwrap string hands the handler the secret unchanged, and GetShims keeps it as the failed value with status 'failed'
MoltenCodes Test: PASS compatKit.secrets: a probe answering secretwrap(true) counts as dead in Resolve and List, is never compared, and reports nothing to the error handler
MoltenCodes Test: compatKit: 24 passed, 0 failed, 0 skipped, 0 timed out (24 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines, up to four runs
in all (see "What stays for the session").

## Visible side effects

None. Nothing is drawn, no sound plays, no chat line other than the
harness's appears, and no client setting (CVar) changes. Every shim the tests
register is a no-op towards the client: it reads the context it is handed and
records what it saw in a table of the suite, or raises on purpose. The
deliberate failures (a raising shim, a shim that calls `Apply`, a raising
probe, a shim raising a secret) are caught by a collector the tests install
with `seterrorhandler` for the one call and remove at once, so no Lua error
window opens.

## What stays for the session

CompatKit cannot remove a shim: a name lives for the session
(`packages/compatKit/docs/API.md`, "Shims"). Every run therefore leaves 14
shims, named `MoltenCodesTest.CompatKit.<serial>.<purpose>` with a serial that
counts up for the session, so a second run never meets the first run's
shims:

| Test | Shims it leaves | Status afterwards |
|---|---|---|
| flavour filtering | `a-current`, `b-other`, `c-every` | applied, filtered, applied |
| versions | `versioned` | applied (version 3 recorded, 2 applied) |
| `SkipShim` | `skipped-before`, `skipped-pending` | skipped; they stay pending, so every later `Apply` in the session counts them as skipped |
| `hasApi`, `hasGlobal` | `hasApi`, `hasGlobal` | applied |
| failures | `a-fails`, `b-runs`, `reenters` | failed, applied, failed |
| context refusals | `contextRefusals` | applied |
| secrets | `secretContext`, `secretFailure` | applied, failed (its `failed` value is the secret it raised) |

CompatKit's default `maxShims` is 64, so four runs fit in a session. In a
fifth, the tests that register shims and find no free name end with
`SKIP ... CompatKit's maxShims is reached: every run registers 14 shims that
stay for the session (four runs fit in one); /reload before running again`;
a `/reload` empties CompatKit and the next run passes again. The tests never
raise the limit, because the limits are shared by every addon in the session,
and a test registers its raising shim last, so a refused registration never
leaves a raising shim pending for somebody else's `Apply`.

The four provider kinds the tests use (`MoltenCodesTest.CompatKit.hostFacts`,
`...raisingProbe`, `...secretProbe`, `...allocation`) stay registered, as every
kind does (they take 4 of the 32 `maxProviderKinds`, the same 4 on every run),
but each suite's After hook unregisters every provider a test added, pass or
fail. CompatKit's limits are never changed: the `SetLimits` calls are
refusals the tests check. Nothing is written to a global or a saved variable
other than the harness's own results.

### On a client without secret values

The five `compatKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`. `secretwrap` is the one documented way to obtain a genuine secret
out of combat without side effects: the client's own API documentation
(mirrored in `packages/apiKit/metadata/retail/namespaces.json`) lists it with
no restriction, and it only converts the values handed to it. Retail 12.1 has
both. A client without them prints these five lines instead, and the totals
line reads `19 passed, 0 failed, 5 skipped, 0 timed out (24 tests)`:

```text
MoltenCodes Test: SKIP compatKit.secrets: Shim refuses a secret name, version, description and flavour, SkipShim a secret name, Providers a secret kind and Apply a secret receiver, each at the calling line, registering nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP compatKit.secrets: Register refuses a secret implementation and priority, Unregister and Resolve a secret name, and SetLimits a secret limit, each at the calling line, changing nothing -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP compatKit.secrets: context.hasApi and context.hasGlobal refuse a secret name at the shim's line in CompatKitSuite.lua -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP compatKit.secrets: a shim raising a secretwrap string hands the handler the secret unchanged, and GetShims keeps it as the failed value with status 'failed' -- the client has no issecretvalue and secretwrap; the secret path was not exercised
MoltenCodes Test: SKIP compatKit.secrets: a probe answering secretwrap(true) counts as dead in Resolve and List, is never compared, and reports nothing to the error handler -- the client has no issecretvalue and secretwrap; the secret path was not exercised
```

### When a test is skipped at run time

- The host-facts provider test ends with `SKIP ... the player is in combat;
  run it out of combat` when `InCombatLockdown()` is true.
- The four tests that provoke a reported failure (the raising shim, the shim
  that calls `Apply`, the raising probe, the secret shim failure) and the
  secret-probe test end with `SKIP ... the client's error handler could not be
  swapped` when an error-capturing addon such as BugGrabber refuses
  `seterrorhandler`. Nothing is provoked in that case. Disable it and run
  again.
- The shim tests of a fifth run in one session, as described above.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('compatKit', 1) is the CompatKit facade ...` | The facade the client loaded is API 1 with `Shim`, `SkipShim`, `GetShims`, `Apply`, `Providers`, `SetLimits`, `GetLimits`, a nine-row `CATALOGUE` and `UNBOUNDED`, and a registry has `Register`, `Unregister`, `Resolve`, `List` and is the same object on every `Providers` call. The log gives the session's limits (and says when another addon changed one) and how many shims the session already holds, by status. |
| `the installed CompatKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `the bundle's ClientKit and ApiKit are found through Registry:Find ...` | The two optional Kits CompatKit looks up at call time are in the bundle; ClientKit answers `"mainline"` when `WOW_PROJECT_ID` is `WOW_PROJECT_MAINLINE`; ApiKit's flavour (`"retail"` on the live client) has a registered flavour file with a metadata version, and its `api` table binds functions. The log gives the project constants, both flavours, the metadata version and build, and how many functions are bound. |
| `Apply runs a shim for the running ClientKit flavour ...` | With the real ClientKit, a shim whose `flavours` names the running flavour and one without `flavours` run exactly once, one whose `flavours` names every other ClientKit flavour is filtered (`status "filtered"`, `applied false`), `Apply`'s three counts match what `GetShims` records, every shim sees `context.flavour == "mainline"`, and a second `Apply` runs none of them again. |
| `the highest version registered before Apply is the one that runs ...` | `Shim` answers `pending`, `replaced`, `ignored`, then `recorded` after `Apply`; only version 2 runs; the record shows `version 3` beside `applied 2`. |
| `SkipShim before a shim is registered and after it is pending ...` | A skip that arrives before the registration and one that arrives after it both keep the shim from running, on two `Apply` calls, and each call counts them as skipped. |
| `context.hasApi answers by identity with the installed ApiKit surface ...` | Inside a shim, `hasApi` answers exactly what this file's own walk of `MoltenCodes.wow.<flavour>.api` answers (the host function is bound there, compared by identity), and on Retail what the committed metadata says: `true` for `C_Timer.NewTicker`, `C_Timer.After`, `GetMouseFoci` and the four catalogue replacements; `false` for the legacy `GetAddOnMetadata` global (catalogue row 5, absent from the Retail metadata), `InterfaceOptionsFrame_OpenToCategory` (row 7), `hooksecurefunc` (on the host, not documented) and a function no client has. The shim's `covers` records `missing = { "GetAddOnMetadata", "hooksecurefunc" }`. The log gives each name's answer, the host type and whether the flavour file binds it; whether the client still has a legacy `GetAddOnMetadata` global and whether it is the same function as `C_AddOns.GetAddOnMetadata` (if it were, identity would answer `true`); and that `MoltenCodes.wow.retail.api.timer.newTicker` is `C_Timer.NewTicker`. |
| `context.hasGlobal answers what raw reads of the client's global table answer ...` | Inside a shim, `hasGlobal` equals a raw walk of the global table for every path: `UIParent`, `DEFAULT_CHAT_FRAME` and `C_Timer.NewTicker` are present; a missing `C_Timer` field, `UIParent.GetName` (a frame's methods live in its metatable, which the documented raw read does not follow), a path through the number `WOW_PROJECT_ID` and an unknown global are absent. The legacy `GetAddOnMetadata`, `Menu`, `MenuUtil` and `Settings.OpenToCategory` are logged as the client has them. |
| `CATALOGUE holds docs/EMBEDDING.md's nine rows in order ...` | The installed catalogue's subsystems are the document's, in order; each of the four rows with a `replacementApi` names a function this client has, and its `flavours` lists the running ApiKit flavour; the five FrameXML or own-frames rows list no flavour. Each row is logged. |
| `the FrameXML replacements the catalogue names ...` | Logs, without asserting, what 12.1 has for `Menu`, `MenuUtil`, `MenuUtil.CreateContextMenu`, `Settings`, `Settings.OpenToCategory`, `TooltipDataProcessor`, `TooltipDataProcessor.AddTooltipPostCall`, `UISpecialFrames` and `hooksecurefunc`, for the legacy subsystems (`UIDropDownMenu_Initialize`, `EasyMenu`, `UIDROPDOWNMENU_OPEN_MENU`, `StaticPopup_Show`, `ActionButton_ShowOverlayGlow`/`HideOverlayGlow`, `GetAddOnMetadata`, `ShowUIPanel`/`HideUIPanel`, `InterfaceOptionsFrame_OpenToCategory`, `SetOverrideBindingClick`, `CompactUnitFrame_UpdateAll`), and whether `Blizzard_Menu`, `Blizzard_Settings` and `Blizzard_Deprecated` are loaded. These are the facts docs/EMBEDDING.md's catalogue rests on. |
| `a raising shim is reported once, unchanged, ...` | `Apply` hands the failure to the handler `seterrorhandler` installed exactly once, as the string the shim raised (naming `CompatKitSuite.lua` at the `error` line), stores the same string as the shim's `failed`, still runs the shim after it (name order), and does not retry the failed one on the next `Apply`. |
| `a shim that calls Apply fails with ...` | Re-entering `Apply` from a shim raises at the shim's own line with the documented message, is reported and recorded as failed, and the guard is cleared: `Apply` works again right after. |
| `a registry whose probes read InCombatLockdown, IsLoggedIn and the chat frame's visibility ...` | Probes over real host answers: the one reading `InCombatLockdown` (priority 30) is dead out of combat, so `Resolve()` answers the one reading `IsLoggedIn` (priority 20); `List` reports each probe's host answer in cascade order; a live preferred provider wins without touching the memo; an unknown preferred name falls through to the memo; unregistering the memoised provider clears it. The log gives each probe's raw answer, which also shows that `IsLoggedIn` answers `true` (CompatKit counts only `true` as alive). |
| `a raising probe is reported ...` | A probe that raises is reported once per `Resolve` naming this file at the raising line and counts as dead; a memo hit on another provider does not ask it; `List` and a `Resolve` naming it as preferred report it once more each. |
| `Resolve on a memo hit and with a live preferred provider ...` | docs/API.md's "`Resolve` allocates nothing", on the client's collector with a real host probe (`IsLoggedIn` itself, called through `pcall`): after a full collection in its own step and one unmeasured call, 10000 rounds of `Resolve()` and `Resolve("fallback")` move `collectgarbage("count")` by at most 1 KB. |
| `Shim, Apply and a registry's Resolve called with a dot ...` | The receiver checks raise at this file's calling line with docs/API.md's wording. |
| `Shim refuses a zero version, an unknown option, ...` | Each argument and option refusal at the calling line, with the documented message, and no shim is registered. |
| `Providers with an empty kind, Register with a probe that is not a function ...` | The provider and limit refusals at the calling line; no provider is registered and the limits are unchanged. |
| `writes into the catalogue, a row, a row's flavours and a shim's context, ...` | The read-only views refuse writes at the writer's line (`CompatKit.CATALOGUE[1]`, `CompatKit.CATALOGUE[4].flavours`, `CompatKit.CATALOGUE`, `CompatKit shim context`), and inside a shim `hasApi("")` and `hasGlobal(42)` raise at the shim's line; the shim, which caught them, is applied. |
| `Shim refuses a secret name, version, description and flavour, ...` | Genuine secrets are refused at the calling line with CompatKit's own message, so CompatKit found them before the client's comparison or boolean-test error could: `Shim` name, version, `options.description`, a secret inside `options.flavours`, `SkipShim` name, `Providers` kind, and a secret receiver of `Apply`. Nothing is registered. |
| `Register refuses a secret implementation and priority, ...` | The same for `Register` implementation and priority, `Unregister` and `Resolve` names and a `SetLimits` value; limits unchanged. |
| `context.hasApi and context.hasGlobal refuse a secret name ...` | Inside a shim both helpers refuse a secret name at the shim's line before reading the global table with it. |
| `a shim raising a secretwrap string ...` | A secret error value travels unchanged: the handler receives exactly one secret, and `GetShims` keeps it as `failed` (still secret, type `string`) with status `failed`, so CompatKit's status test (`failed ~= false`) did not raise on it. |
| `a probe answering secretwrap(true) counts as dead ...` | A secret probe answer is dead for `Resolve`, a preferred `Resolve` and `List`, and CompatKit never compares or boolean-tests it: nothing reaches the error handler. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, a `SKIP` line on Retail 12.1 in one of the
  first four runs of a session, or a totals line other than
  `24 passed, 0 failed, 0 skipped, 0 timed out (24 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_CompatKit`. Every failure the suite
  provokes goes to its own collector.
- The `hasApi` test failing on `GetAddOnMetadata` while the log says the
  legacy global is the same function as `C_AddOns.GetAddOnMetadata`: identity
  cannot tell an alias from the documented function, so `hasApi` would answer
  `true` for a name the Retail metadata does not document. That is a finding
  about CompatKit's identity check, not a client failure; send the log.
- The `hasApi` test failing on `C_Timer.NewTicker` with the log saying the
  binding is not `C_Timer.NewTicker`: another addon replaced
  `C_Timer.NewTicker` after MoltenCodes loaded. Say which addons are enabled.
- The catalogue test failing on a `replacementApi` that is not a function on
  this client: the client removed a documented replacement; the catalogue and
  the metadata need a refresh.
- The host-facts provider test failing on `alive.loggedIn`: `IsLoggedIn`
  answered something other than `true` (the log shows what), which CompatKit
  counts as dead.
- The allocation test failing: its log gives the measured delta. Say which
  other addons are enabled.
- `the installed CompatKit carries the revision ...` failing: another enabled
  addon embeds a different CompatKit copy.
- A `compatKit.secrets` test failing with "secretwrap raised" or "secretwrap
  returned a value issecretvalue does not report as secret": the client's
  secret functions behave differently from their documentation.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (every `hasApi` and `hasGlobal`
   answer beside the host's, each catalogue row, the FrameXML and legacy
   globals of 12.1, each probe's host answer, the memory delta, the client's
   own error messages with their paths) and the client facts. Lua shortens a
   long file path from the left, so a logged message may start with `...`; the
   tests compare only the `CompatKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
