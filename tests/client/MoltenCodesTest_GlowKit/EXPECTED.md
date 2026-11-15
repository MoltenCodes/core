# Expected result: `/mct run glowKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package glowKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** A dark square above the middle of the
screen glows for under a second, three times. A normal run finishes within a
few seconds.

## At login

```text
MoltenCodes Test: test suites loaded for glowKit. Type /mct run glowKit to run them; /mct help lists every command.
```

## After `/mct run glowKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running glowKit: 2 suites. Results follow when every test has finished.
MoltenCodes Test: PASS glowKit.facade: Registry:Get('glowKit', 1) is the GlowKit facade with API 1 and every documented method
MoltenCodes Test: PASS glowKit.facade: the installed GlowKit carries the revision of the committed manifest
MoltenCodes Test: PASS glowKit.glows: a pixel glow's lines move on the client's frame updates
MoltenCodes Test: PASS glowKit.glows: a pulse glow breathes on the client's frame updates
MoltenCodes Test: PASS glowKit.glows: stopped glows give their overlay back and the next glow reuses it
MoltenCodes Test: glowKit: 5 passed, 0 failed, 0 skipped, 0 timed out (5 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('glowKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed GlowKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `a pixel glow's lines move ...` | The overlay's `OnUpdate` runs on the client and moves the first line within two seconds. |
| `a pulse glow breathes ...` | The overlay's alpha changes on the client's frames within two seconds. |
| `stopped glows give their overlay back ...` | `Stop` hides the overlay, and the next glow reuses it without a new frame. |

## What a run leaves behind

One hidden square frame of this file and GlowKit's pooled overlays. Nothing is
written to a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_GlowKit`.
- A glow left on screen after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
