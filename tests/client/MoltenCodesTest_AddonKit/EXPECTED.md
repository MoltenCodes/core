# Expected result: `/mct run addonKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package addonKit`
on Retail, with the Kits AddonKit's helpers use (ModuleKit, LifecycleKit,
SchemaKit, SettingsKit, OptionsKit, PanelKit, CommandKit, BrokerKit,
LauncherKit) in the installed MoltenCodes addon, and nothing else from the
MoltenCodes framework enabled in the client. No result has been recorded in
the client yet; the lines below are what the code and the host specs predict.

**What this test does on screen.** A gear button appears on the minimap and
moves once. The settings panel opens on the page "MoltenCodes Test AddonKit"
and closes again.

## At login

```text
MoltenCodes Test: test suites loaded for addonKit. Type /mct run addonKit to run them; /mct help lists every command.
```

## After `/mct run addonKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running addonKit: 4 suites. Results follow when every test has finished.
MoltenCodes Test: PASS addonKit.facade: Registry:Get('addonKit', 1) is the AddonKit facade with API 1, every documented method and both parts
MoltenCodes Test: PASS addonKit.facade: the installed AddonKit carries the revision of the committed manifest
MoltenCodes Test: PASS addonKit.entry: MoltenCodes:For answers this addon's facade, and a Kit read through it is the shared one
MoltenCodes Test: PASS addonKit.entry: an error through the facade names this file's line, not AddonKit's
MoltenCodes Test: PASS addonKit.database: an open at file scope, before ADDON_LOADED, was refused with the fix
MoltenCodes Test: PASS addonKit.database: the open in OnInitialize wraps the client's restored saved variable
MoltenCodes Test: PASS addonKit.composition: the panel is in the settings list and /mctaddonkit opens it
MoltenCodes Test: PASS addonKit.composition: the minimap button follows the profile and moves on a profile switch
MoltenCodes Test: addonKit: 8 passed, 0 failed, 0 skipped, 0 timed out (8 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

In a combat run the panel test is skipped. Classic Era and Mists of Pandaria
Classic have not been run (no game time; see `tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('addonKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists, and both part files loaded. |
| `the installed AddonKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `MoltenCodes:For answers this addon's facade ...` | `MoltenCodes.For` is installed in the client and a Kit read through it is the Registry's shared table. |
| `an error through the facade names this file's line ...` | Level 3 inside the facade's `__index` is the reading line in the client's Lua, as on host Lua 5.1. |
| `an open at file scope ... was refused` | LifecycleKit does not count the addon as loaded while its files run, so the gate holds before the client's `ADDON_LOADED`. |
| `the open in OnInitialize wraps the client's restored saved variable` | The database writes into the table the client restored and saves. |
| `the panel is in the settings list and /mctaddonkit opens it` | PanelKit's page and CommandKit's command work together in Blizzard's settings. |
| `the minimap button follows the profile ...` | LauncherKit reads `db.profile.minimap` and `OnProfileChanged` refreshes it. |

## What a run leaves behind

The settings page "MoltenCodes Test AddonKit", a minimap button, the slash
command `/mctaddonkit` and the saved variable `MoltenCodesTestAddonKitDB`
(with a counter of opens). The profile "MoltenCodes Test Other" is deleted
again.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` outside a combat run.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_AddonKit`.
- An "addon blocked an action" message when the settings panel opens.

## What to send back

The chat lines, and after `/reload` the files
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` and
`MoltenCodesTest_AddonKit.lua` from the flavour folder.
