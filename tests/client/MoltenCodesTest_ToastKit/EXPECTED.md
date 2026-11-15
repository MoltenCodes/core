# Expected result: `/mct run toastKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package toastKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** Two toasts appear near the top of the
screen for under a second, then one more. Keep the cursor away from the top
of the screen: a toast under the cursor holds. A normal run finishes within a
few seconds.

## At login

```text
MoltenCodes Test: test suites loaded for toastKit. Type /mct run toastKit to run them; /mct help lists every command.
```

## After `/mct run toastKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running toastKit: 2 suites. Results follow when every test has finished.
MoltenCodes Test: PASS toastKit.facade: Registry:Get('toastKit', 1) is the ToastKit facade with API 1 and every documented method
MoltenCodes Test: PASS toastKit.facade: the installed ToastKit carries the revision of the committed manifest
MoltenCodes Test: PASS toastKit.toasts: two toasts stack on UIParent and each ends within its duration on the client's frames
MoltenCodes Test: PASS toastKit.toasts: a released toast's frame is handed out again
MoltenCodes Test: toastKit: 4 passed, 0 failed, 0 skipped, 0 timed out (4 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('toastKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed ToastKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `two toasts stack on UIParent ...` | Both are shown, the second below the first (the log gives the offsets), and both end within four seconds on the client's `OnUpdate` with the cursor away. |
| `a released toast's frame is handed out again` | The pool reuses the frame and builds no new one. |

## What a run leaves behind

ToastKit's pooled frames, hidden. Nothing is written to a saved variable
besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_ToastKit`.
- A toast left on screen after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
