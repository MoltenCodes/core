# Expected result: `/mct run menuKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package menuKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** Two tests open a menu in the middle of the
screen and close it again in the same moment. The extension test prints one
line asking you to right-click your own player frame within 20 seconds; do it,
check that the menu ends with a divider and `MoltenCodes Test: MenuKit`, and
close the menu (Esc or a click elsewhere). Run it standing idle, out of combat.

## At login

```text
MoltenCodes Test: test suites loaded for menuKit. Type /mct run menuKit to run them; /mct help lists every command.
```

## After `/mct run menuKit`

With the right click done, exactly these lines, in this order (the request
for the right click appears once the extension test starts):

```text
MoltenCodes Test: running menuKit: 4 suites. Results follow when every test has finished.
MoltenCodes Test: right-click your own player frame within 20 seconds; the menu should end with "MoltenCodes Test: MenuKit".
MoltenCodes Test: PASS menuKit.facade: Registry:Get('menuKit', 1) is the MenuKit facade with API 1 and every documented method
MoltenCodes Test: PASS menuKit.facade: the installed MenuKit carries the revision of the committed manifest
MoltenCodes Test: PASS menuKit.facade: the client has the Blizzard_Menu functions MenuKit calls
MoltenCodes Test: PASS menuKit.menus: a context menu of every entry kind opens through MenuUtil and MenuKit:CloseMenus() closes it
MoltenCodes Test: PASS menuKit.menus: a DropdownButton set up by SetupDropdown opens and closes through Blizzard, calling the menu at each opening
MoltenCodes Test: PASS menuKit.extensions: an extension of MENU_UNIT_SELF is reached when you right-click your own unit frame, and removed
MoltenCodes Test: PASS menuKit.secrets: OpenContextMenu refuses a secret entry text at this file's line
MoltenCodes Test: menuKit: 7 passed, 0 failed, 0 skipped, 0 timed out (7 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Without the right click

The extension test prints `SKIP` with `no right click on your own unit frame
came within 20 seconds`, and the totals read
`6 passed, 0 failed, 1 skipped, 0 timed out (7 tests)`.

### Per flavour

Classic Era and Mists of Pandaria Classic have no secret values: the
`secrets` test is skipped there with the harness's reason, and the totals gain
one skip. Those clients have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('menuKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed MenuKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the client has the Blizzard_Menu functions ...` | `MenuUtil.CreateContextMenu`, `Menu.ModifyMenu` and `Menu.GetManager` exist on this client. |
| `a context menu of every entry kind ...` | The real element descriptions accept every call MenuKit makes (title, button with tooltip, disabled button, checkbox, radio, divider, spacer, submenu): the menu function runs once with the owner, a menu opens, and `CloseMenus` closes it. |
| `a DropdownButton set up by SetupDropdown ...` | `SetupMenu` takes MenuKit's generator; Blizzard's `OpenMenu` calls the menu function again, asks `isSelected`, and `CloseMenu` closes it. The log gives how often each was called. |
| `an extension of MENU_UNIT_SELF ...` | `Menu.ModifyMenu` calls MenuKit's callback when the unit menu opens, with Blizzard's context data (the log gives `contextData.unit`), and `Remove` unregisters it. |
| `OpenContextMenu refuses a secret entry text ...` | A `secretwrap` value is refused at this file's line, before Blizzard sees it. |

## What a run leaves behind

The client never frees a frame, so the first run of a session creates one
hidden `Frame` and one hidden `DropdownButton`; later runs reuse them. Every
extension is removed and every menu closed after its test. Nothing is written
to a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_MenuKit`.
- The `MoltenCodes Test: MenuKit` line missing from your unit menu during the
  extension test, or still there when you right-click again after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds each test's logs.
