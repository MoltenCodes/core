# Expected result: `/mct run bindingKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package bindingKit`
on Retail, and nothing else from the MoltenCodes framework enabled in the
client. No result has been recorded in the client yet; the lines below are
what the code and the host specs predict.

**What this test does.** It binds `CTRL-ALT-SHIFT-F12`, which no default
binding uses, to a function for a moment and clears it. Your saved bindings
are never changed. Run it out of combat.

## At login

```text
MoltenCodes Test: test suites loaded for bindingKit. Type /mct run bindingKit to run them; /mct help lists every command.
```

## After `/mct run bindingKit`

On every promised client, exactly these lines, in this order:

```text
MoltenCodes Test: running bindingKit: 2 suites. Results follow when every test has finished.
MoltenCodes Test: PASS bindingKit.facade: Registry:Get('bindingKit', 1) is the BindingKit facade with API 1 and every documented method
MoltenCodes Test: PASS bindingKit.facade: the installed BindingKit carries the revision of the committed manifest
MoltenCodes Test: PASS bindingKit.keys: a function key is bound through SetOverrideBindingClick, runs its function and is cleared
MoltenCodes Test: bindingKit: 3 passed, 0 failed, 0 skipped, 0 timed out (3 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

In combat, the keys test is skipped with `in combat; run it out of combat`.
Classic Era and Mists of Pandaria Classic have not been run (no game time; see
`tests/client/README.md`).

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('bindingKit', 1) ...` | The loaded facade is API 1 with every method docs/API.md lists. |
| `the installed BindingKit carries the revision ...` | Registry selected the committed manifest's revision. |
| `a function key is bound ...` | The real `SetOverrideBindingClick` binds the key: `GetBindingAction(key, true)` answers `CLICK MoltenCodesBindingKitButton<n>:LeftButton` (logged); clicking that button calls the function once; after `ClearAll` the key has no action. |

## What a run leaves behind

One scope's owner frame and one hidden button, until `/reload`. Override
bindings are never saved, and the test key is cleared before the run ends.
Nothing is written to a saved variable besides the harness's own results.

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, or a `SKIP` out of combat.
- A Lua error window naming `MoltenCodes`, `MoltenCodesTest` or
  `MoltenCodesTest_BindingKit`, or an "interface action blocked" message.
- `CTRL-ALT-SHIFT-F12` still doing something after the run.

## What to send back

The chat lines, and after `/reload` the file
`WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua` from the flavour
folder: it holds the binding action the client reported.
