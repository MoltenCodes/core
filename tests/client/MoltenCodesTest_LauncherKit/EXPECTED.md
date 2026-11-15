# Expected result: `/mct run launcherKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package launcherKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A question-mark button appears on the
right edge of the minimap, moves to the top, shows its tooltip for a moment
and is hidden again; on Retail an entry `MoltenCodesTest_LauncherKit` is added
to the addon compartment (the drop-down beside the minimap) until `/reload`.
Run it standing idle; nothing needs combat or a group.

## At login

```text
MoltenCodes Test: test suites loaded for launcherKit. Type /mct run launcherKit to run them; /mct help lists every command.
```

## After `/mct run launcherKit`

On Retail, exactly these lines, in this order:

```text
MoltenCodes Test: running launcherKit: 4 suites. Results follow when every test has finished.
MoltenCodes Test: PASS launcherKit.facade: Registry:Get('launcherKit', 1) is the LauncherKit facade with API 1 and every documented method
MoltenCodes Test: PASS launcherKit.facade: the installed LauncherKit carries the revision of the committed manifest
MoltenCodes Test: PASS launcherKit.facade: the client has Minimap, GameTooltip and GetCursorPosition; the optional facilities are logged
MoltenCodes Test: PASS launcherKit.button: a button on the real minimap is placed at its saved angle, shown, hidden and moved
MoltenCodes Test: PASS launcherKit.button: hovering the button fills GameTooltip through the object's OnTooltipShow
MoltenCodes Test: PASS launcherKit.compartment: AddToCompartment adds an entry on Retail and answers unavailable without one
MoltenCodes Test: PASS launcherKit.secrets: Register refuses a secret object name at this file's line
MoltenCodes Test: launcherKit: 7 passed, 0 failed, 0 skipped, 0 timed out (7 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Per flavour

Classic Era and Mists of Pandaria Classic have no addon compartment: the
compartment test still passes, expecting `"unavailable"`. They have no secret
values either: the `secrets` test is skipped there with the harness's reason,
and the totals gain one skip. Those clients have not been run (no game time;
see `tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('launcherKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed LauncherKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the client has Minimap, GameTooltip ...` | The three required facilities exist; the log says whether a minimap addon defines `GetMinimapShape` (and its answer) and whether `AddonCompartmentFrame` exists. |
| `a button on the real minimap ...` | The button is a child of `Minimap`, centred on it at 0 degrees to the right and at 90 degrees above; `Show` and `Hide` write `hide`. The log gives the offset. |
| `hovering the button ...` | The button's `OnEnter` fills the client's `GameTooltip` with the object's line and owns it; `OnLeave` hides it. |
| `AddToCompartment ...` | On Retail an entry is added (or already was, on a later run) and a second call answers `"already"`; without a compartment, `"unavailable"`. |
| `Register refuses a secret object name ...` | A `secretwrap` value is refused at this file's line. |

## What a run leaves behind

The first run of a session creates the BrokerKit object
`MoltenCodesTest_LauncherKit`, its minimap button (hidden after each test) and,
on Retail, its compartment entry, all until `/reload`; later runs reuse them.
Nothing is written to a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_LauncherKit`.
- The test button still visible on the minimap after the run, or a tooltip
  left on screen.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds each test's logs, among them the minimap shape and the
button's offset.
