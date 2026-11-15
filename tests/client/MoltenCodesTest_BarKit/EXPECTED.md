# Expected result: `/mct run barKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package barKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A bar appears above the middle of the
screen for at most a second, a few times. A normal run finishes within a few
seconds.

## At login

```text
MoltenCodes Test: test suites loaded for barKit. Type /mct run barKit to run them; /mct help lists every command.
```

## After `/mct run barKit`

On Retail, exactly these lines, in this order:

```text
MoltenCodes Test: running barKit: 3 suites. Results follow when every test has finished.
MoltenCodes Test: PASS barKit.facade: Registry:Get('barKit', 1) is the BarKit facade with API 1 and every documented method
MoltenCodes Test: PASS barKit.facade: the installed BarKit carries the revision of the committed manifest
MoltenCodes Test: PASS barKit.status: the client's StatusBar takes a secret value and range through SetValue and SetMinMax
MoltenCodes Test: PASS barKit.status: a status bar shows a plain value, label, icon and colour
MoltenCodes Test: PASS barKit.timer: a timer bar runs to its end on the client's frames, calls onFinished once and releases itself
MoltenCodes Test: PASS barKit.timer: a released bar's frame is handed out again
MoltenCodes Test: barKit: 6 passed, 0 failed, 0 skipped, 0 timed out (6 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

### Per flavour

Classic Era and Mists of Pandaria Classic have no secret values: the secret
test is skipped there with the harness's reason, and the totals gain one
skip. Those clients have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('barKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed BarKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the client's StatusBar takes a secret value ...` | `SetMinMax(0, secret)` and `SetValue(secret)` with `secretwrap` values raise nothing: the client's status bar draws what the addon may not read. |
| `a status bar shows a plain value ...` | Value, label and icon are on the client's frame as set. |
| `a timer bar runs to its end ...` | A 0.5-second timer runs out on the client's `OnUpdate` and `GetTime` within three seconds, calls `onFinished` once and, with `releaseOnFinish`, releases the bar cleared. |
| `a released bar's frame is handed out again` | The pool reuses the frame and builds no new one. |

## What a run leaves behind

BarKit's pooled frames, hidden and kept for reuse. Nothing is written to a
saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` other than those above.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_BarKit`.
- A bar left on screen after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
