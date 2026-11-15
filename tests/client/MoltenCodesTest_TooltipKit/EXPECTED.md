# Expected result: `/mct run tooltipKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package tooltipKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A tooltip appears above the middle of the
screen for a moment, a few times. Keep the cursor away from the middle of the
screen while it runs: the auto-hide test waits for the cursor to be off the
tooltip. A normal run finishes within a few seconds.

## At login

```text
MoltenCodes Test: test suites loaded for tooltipKit. Type /mct run tooltipKit to run them; /mct help lists every command.
```

## After `/mct run tooltipKit`

On Retail, exactly these lines, in this order:

```text
MoltenCodes Test: running tooltipKit: 4 suites. Results follow when every test has finished.
MoltenCodes Test: PASS tooltipKit.facade: Registry:Get('tooltipKit', 1) is the TooltipKit facade with API 1 and every documented method
MoltenCodes Test: PASS tooltipKit.facade: the installed TooltipKit carries the revision of the committed manifest
MoltenCodes Test: PASS tooltipKit.layout: three columns, a header and a span are laid out with the client's fonts
MoltenCodes Test: PASS tooltipKit.layout: a cell whose text grows on a shown tooltip widens its column
MoltenCodes Test: PASS tooltipKit.layout: a height limit scrolls the lines with the wheel on the client's scroll frame
MoltenCodes Test: PASS tooltipKit.layout: SmartAnchorTo puts the tooltip on the side of the frame with room
MoltenCodes Test: PASS tooltipKit.lifecycle: auto-hide releases the tooltip on the client's frame updates
MoltenCodes Test: PASS tooltipKit.lifecycle: a released tooltip's frames return to their pools and are reused
MoltenCodes Test: PASS tooltipKit.secrets: AddLine refuses a secret text at this file's line, and SetCell draws one with allowSecret
MoltenCodes Test: tooltipKit: 9 passed, 0 failed, 0 skipped, 0 timed out (9 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Per flavour

Classic Era and Mists of Pandaria Classic have no secret values: the
`secrets` test is skipped there with the harness's reason, and the totals gain
one skip. Those clients have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('tooltipKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed TooltipKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `three columns, a header and a span ...` | The client's fonts measure every cell; the tooltip is wider than its padding and gaps and taller than its padding. The log gives its size. |
| `a cell whose text grows ...` | The layout measures a cell's whole text with `GetUnboundedStringWidth`, not the width the last layout gave the font string (which `GetStringWidth` stops at): the tooltip at least doubles in width. The log gives both widths. |
| `a height limit scrolls ...` | Forty lines in a 150-pixel tooltip: the frame is 150 high, one wheel notch scrolls (the log gives how far), and a large notch back returns to the top. |
| `SmartAnchorTo puts the tooltip ...` | A frame above the screen's middle gets the tooltip below it, anchored to that frame. |
| `auto-hide releases the tooltip ...` | With the cursor off the tooltip and its anchor, the client's `OnUpdate` releases it within three seconds. |
| `a released tooltip's frames ...` | Released and acquired again under the same key, the tooltip reuses its frame and makes no new line frame. |
| `AddLine refuses a secret text ...` | A `secretwrap` value is refused at this file's line, and drawn by `SetCell` with `allowSecret` without an error. |

## What a run leaves behind

TooltipKit's pooled frames, hidden and kept for reuse because the client never
frees a frame, and one empty anchor frame of this file. Nothing is written to
a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_TooltipKit`.
- A tooltip left on screen after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds each test's logs, among them the measured sizes.
