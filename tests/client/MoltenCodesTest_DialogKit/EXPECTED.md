# Expected result: `/mct run dialogKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package dialogKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A dialog appears near the top of the
screen for at most a second, a few times. The Escape test calls the client's
`CloseSpecialWindows`, which also closes any other window open at that moment:
run it with no other window open. A normal run finishes within a few seconds.

## At login

```text
MoltenCodes Test: test suites loaded for dialogKit. Type /mct run dialogKit to run them; /mct help lists every command.
```

## After `/mct run dialogKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running dialogKit: 2 suites. Results follow when every test has finished.
MoltenCodes Test: PASS dialogKit.facade: Registry:Get('dialogKit', 1) is the DialogKit facade with API 1 and every documented method
MoltenCodes Test: PASS dialogKit.facade: the installed DialogKit carries the revision of the committed manifest
MoltenCodes Test: PASS dialogKit.dialogs: a dialog with an input line is accepted through its button with the typed text
MoltenCodes Test: PASS dialogKit.dialogs: the client's CloseSpecialWindows closes the dialog through UISpecialFrames, as Escape does
MoltenCodes Test: PASS dialogKit.dialogs: a queued dialog is shown when the first ends, and a timeout cancels it on the client's clock
MoltenCodes Test: dialogKit: 5 passed, 0 failed, 0 skipped, 0 timed out (5 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('dialogKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed DialogKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `a dialog with an input line is accepted ...` | The frame builds with `UIPanelButtonTemplate` and `InputBoxTemplate`; a real button click calls `onAccept` with the input line's text and hides the frame. |
| `the client's CloseSpecialWindows closes the dialog ...` | The frame's name is in `UISpecialFrames`, and the client's own Escape handler hides it, which cancels the dialog with `"escape"`. |
| `a queued dialog is shown when the first ends ...` | The second dialog waits, is shown when the first is accepted, and its 0.5-second timeout cancels it with `"timeout"` on the client's `OnUpdate` and `GetTime`. |

## What a run leaves behind

DialogKit's one dialog frame, hidden, and its name in `UISpecialFrames`, until
`/reload`. Nothing is written to a saved variable besides the harness's own
results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_DialogKit`, or an "interface action blocked" message.
- A dialog left on screen after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
