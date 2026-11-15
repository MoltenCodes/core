# Expected result: `/mct run panelKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package panelKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** The two page tests open Blizzard's
settings panel (Esc → Options) on the test's own page in the AddOns tab and
close it again within a few seconds. They change no setting. Run it standing
idle, out of combat, with no other window open; a normal run finishes within
about five seconds.

## At login

```text
MoltenCodes Test: test suites loaded for panelKit. Type /mct run panelKit to run them; /mct help lists every command.
```

## After `/mct run panelKit`

Out of combat, exactly these lines, in this order:

```text
MoltenCodes Test: running panelKit: 3 suites. Results follow when every test has finished.
MoltenCodes Test: PASS panelKit.facade: Registry:Get('panelKit', 1) is the PanelKit facade with API 1 and every documented method
MoltenCodes Test: PASS panelKit.facade: the installed PanelKit carries the revision of the committed manifest
MoltenCodes Test: PASS panelKit.facade: the client's Settings table has the four functions PanelKit calls
MoltenCodes Test: PASS panelKit.pages: a category opened with panel:Open() is drawn by WidgetKit, and every widget returns to its pool when the panel closes
MoltenCodes Test: PASS panelKit.pages: a subcategory opened by its own category ID draws its own tree, not its parent's
MoltenCodes Test: SKIP panelKit.pages: what panel:Open() does in combat is logged -- not run: not in combat; start combat (a training dummy) and run /mct run panelKit again
MoltenCodes Test: PASS panelKit.secrets: Register refuses a secret tree name at this file's line
MoltenCodes Test: panelKit: 6 passed, 0 failed, 1 skipped, 0 timed out (7 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### In combat

Started while in combat (attack a training dummy, then type the command), the
two page tests are skipped with `in combat; run it out of combat`, and the
combat test runs: it calls `panel:Open()` and logs what happened, whether it
raised, what it returned and whether the settings panel came up. It passes
whatever the client did; the log is the result. Totals then read
`5 passed, 0 failed, 2 skipped, 0 timed out (7 tests)`.

### Per flavour

Classic Era and Mists of Pandaria Classic have no secret values: the
`secrets` test is skipped there with the harness's reason, and the totals gain
one skip. Those clients have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('panelKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists; the log gives `maxPanels`. |
| `the installed PanelKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the client's Settings table has the four functions ...` | `RegisterCanvasLayoutCategory`, `RegisterCanvasLayoutSubcategory`, `RegisterAddOnCategory` and `OpenToCategory` exist on this client. |
| `a category opened with panel:Open() ...` | The real Settings API accepts the canvas category, `Open` selects it by `GetCategoryID()`, Blizzard's showing the canvas makes WidgetKit draw the tree (the `enabled` toggle exists), and closing the panel releases every widget: WidgetKit's active count is back where it was. The log gives the category ID and how many widgets the page used. |
| `a subcategory opened by its own category ID ...` | `Settings.OpenToCategory` takes a subcategory's ID and selects that page: the subpage is drawn and its parent is not. |
| `what panel:Open() does in combat is logged` | Design question from `docs/ROADMAP.md` (panelKit, point 7): Blizzard's `HasRestrictions` flag on `C_SettingsUtil.OpenSettingsPanel` is undocumented. |
| `Register refuses a secret tree name ...` | A `secretwrap` value is refused at this file's line, before anything is registered. |

## What a run leaves behind

Blizzard cannot remove a category, so the first run of a session registers two
pages until `/reload`: `MoltenCodes Test: PanelKit` in the AddOns tab and
`Subpage` under it. Later runs reuse them. The OptionsKit trees they draw are
undefined after each test, so opening one of the pages afterwards shows
`No options are defined for MoltenCodesTest_PanelKit.` Nothing is written to a
saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_PanelKit`.
- The settings panel staying open after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds each test's logs, among them the category IDs and, for a run
in combat, what `Open` did.
