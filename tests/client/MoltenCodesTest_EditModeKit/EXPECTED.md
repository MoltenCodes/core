# Expected result: `/mct run editModeKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package editModeKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A dark box appears
above the middle of the screen and moves once. The chat frame then asks you
to open Edit Mode (Game Menu → Edit Mode) and close it again within 30
seconds; while it is open, the box carries a blue overlay reading
`MoltenCodes Test`. A run finishes as soon as you close Edit Mode.

## At login

```text
MoltenCodes Test: test suites loaded for editModeKit. Type /mct run editModeKit to run them; /mct help lists every command.
```

## After `/mct run editModeKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running editModeKit: 3 suites. Results follow when every test has finished.
MoltenCodes Test: open Edit Mode, then close it, within 30 seconds.
MoltenCodes Test: PASS editModeKit.facade: Registry:Get('editModeKit', 1) is the EditModeKit facade with API 1 and every documented method
MoltenCodes Test: PASS editModeKit.facade: the installed EditModeKit carries the revision of the committed manifest
MoltenCodes Test: PASS editModeKit.positions: the client's Edit Mode manager names the active layout
MoltenCodes Test: PASS editModeKit.positions: a drag's end saves the centre offset under the active layout
MoltenCodes Test: PASS editModeKit.positions: Refresh puts the saved position back
MoltenCodes Test: PASS editModeKit.editMode: opening Edit Mode shows the overlay and closing it hides it
MoltenCodes Test: editModeKit: 6 passed, 0 failed, 0 skipped, 0 timed out (6 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('editModeKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed EditModeKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the client's Edit Mode manager names the active layout` | `EditModeManagerFrame:GetActiveLayoutInfo()` answers a layout name. |
| `a drag's end saves the centre offset ...` | The position is saved under that layout from the client's own `GetCenter` and scales. |
| `Refresh puts the saved position back` | The box is anchored by its centre to `UIParent`'s centre. |
| `opening Edit Mode shows the overlay ...` | The client's `EventRegistry` delivers `EditMode.Enter` and `EditMode.Exit` to EditModeKit. |

## What a run leaves behind

One hidden box of this file and EditModeKit's overlay, unregistered and
kept for reuse. Nothing is written to a saved variable besides the harness's
own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`. A `FAIL` of the last test
  without having opened Edit Mode is expected.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_EditModeKit`.
- Blizzard's Edit Mode reporting that an addon has blocked an action.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
