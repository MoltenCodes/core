# Expected result: `/mct run rangeKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package rangeKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does on screen.** Nothing is drawn. The chat frame asks you
twice for something: first to target a unit next to you (a training dummy is
ideal) and walk at least 30 yards away from it within 30 seconds, then to
change a talent that grants or removes a spell within 60 seconds. A run
finishes as soon as both have happened.

## At login

```text
MoltenCodes Test: test suites loaded for rangeKit. Type /mct run rangeKit to run them; /mct help lists every command.
```

## After `/mct run rangeKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running rangeKit: 3 suites. Results follow when every test has finished.
MoltenCodes Test: target a unit next to you (a training dummy), then walk at least 30 yards away from it, within 30 seconds.
MoltenCodes Test: change a talent that grants or removes a spell, within 60 seconds.
MoltenCodes Test: PASS rangeKit.facade: Registry:Get('rangeKit', 1) is the RangeKit facade with API 1 and every documented method
MoltenCodes Test: PASS rangeKit.facade: the installed RangeKit carries the revision of the committed manifest
MoltenCodes Test: PASS rangeKit.checkers: the player's spellbook gives the harm list at least one spell checker
MoltenCodes Test: PASS rangeKit.checkers: every list holds the interact checkers at 7 and 28 yards
MoltenCodes Test: PASS rangeKit.checkers: GetRange('player') answers 0 to 7 yards from the interact distance
MoltenCodes Test: PASS rangeKit.player: the bracket of the target grows as the player walks away from it
MoltenCodes Test: PASS rangeKit.player: a talent change rebuilds the lists through the client's events
MoltenCodes Test: rangeKit: 7 passed, 0 failed, 0 skipped, 0 timed out (7 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`). On Classic Era a talent change needs free talent
points; without them the last test fails, which is expected.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('rangeKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed RangeKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `the player's spellbook gives the harm list ...` | `C_SpellBook.IsSpellInSpellBook` reports a candidate of the player's class and `C_Spell.GetSpellInfo` gives it a reach. |
| `every list holds the interact checkers ...` | `CheckInteractDistance` exists and both interact checkers are kept in every list. |
| `GetRange('player') answers 0 to 7 yards ...` | `CheckInteractDistance("player", 3)` answers yes for the player's own unit. This is not documented; a `FAIL` here records what the client really answers. |
| `the bracket of the target grows ...` | The client's spell and interact checks bracket a real unit: first within 7 yards, then beyond 28. |
| `a talent change rebuilds the lists ...` | A talent change reaches RangeKit through `SPELLS_CHANGED` or `PLAYER_TALENT_UPDATE` and changes a list. |

## What a run leaves behind

Nothing: the talent test disconnects its listener. Nothing is written to a
saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP`. A `FAIL` of a `rangeKit.player`
  test without having done what the chat asked is expected.
- A `FAIL` of the interact checker test for a class with a spell of exactly 7
  or 28 yards: that spell then takes the interact checker's place, by design.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_RangeKit`, or an "action blocked" message for
  `CheckInteractDistance`.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder.
