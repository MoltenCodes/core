# Expected result: `/mct run unitFrameKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package unitFrameKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client, and no other unit frame addon. No result has been recorded in the
client yet; the lines below are what the code and the host specs predict.

**Before the run.** Be out of combat and in a party of at least two, with
Blizzard's party frames shown (either style: raid-style party frames or the
classic party frames).

**What this test does on screen.** Nothing you can see: a small, empty
secure button for your character is shown above the middle of the screen for
a few seconds and hidden again.

## At login

```text
MoltenCodes Test: test suites loaded for unitFrameKit. Type /mct run unitFrameKit to run them; /mct help lists every command.
```

## After `/mct run unitFrameKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running unitFrameKit: 3 suites. Results follow when every test has finished.
MoltenCodes Test: PASS unitFrameKit.facade: Registry:Get('unitFrameKit', 1) is the UnitFrameKit facade with API 1 and every documented method
MoltenCodes Test: PASS unitFrameKit.facade: the installed UnitFrameKit carries the revision of the committed manifest
MoltenCodes Test: PASS unitFrameKit.scan: a scan finds this suite's secure unit button for player
MoltenCodes Test: PASS unitFrameKit.scan: OnChange reports the button gone once it is hidden
MoltenCodes Test: PASS unitFrameKit.scan: Blizzard's PlayerFrame answers for player
MoltenCodes Test: PASS unitFrameKit.party: in a party, party1 answers a shown Blizzard party frame
MoltenCodes Test: unitFrameKit: 6 passed, 0 failed, 0 skipped, 0 timed out (6 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('unitFrameKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed UnitFrameKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `a scan finds this suite's secure unit button for player` | The client's `EnumerateFrames` hands out a secure unit button, its `unit` attribute is read, the sliced scan ends, and a caller's pattern ranks it first. |
| `OnChange reports the button gone once it is hidden` | A hidden frame leaves the cache and listeners hear `(frame, nil, "player")`. |
| `Blizzard's PlayerFrame answers for player` | `PlayerFrame` carries the `unit` attribute and the solo-token rule lets it answer. |
| `in a party, party1 answers a shown Blizzard party frame` | Blizzard's party frames, `CompactPartyFrameMember%d` or the unnamed `PartyFrame.MemberFrame%d`, are found, shown and showing `party1`. |

## What a run leaves behind

One hidden secure button of this file, `MoltenCodesTestUnitFrameKitButton`.
Nothing is written to a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`. A `FAIL` of the party test
  while not in a party, and of the two button tests in combat, is expected.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_UnitFrameKit`.
- An "interface action blocked" message.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
