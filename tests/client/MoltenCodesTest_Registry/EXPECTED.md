# Expected result: `/mct run registry`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package registry`
and nothing else from the MoltenCodes framework enabled in the client.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for registry. Type /mct run registry to run them; /mct help lists every command.
```

## After `/mct run registry`

Within a second or two, exactly these lines, in this order (`PASS` is green in
the client):

```text
MoltenCodes Test: running registry: 4 suites. Results follow when every test has finished.
MoltenCodes Test: PASS registry.facade: MoltenCodes.Registries[2] is the Registry facade with API 2 and every documented method
MoltenCodes Test: PASS registry.facade: the installed Registry carries the revision of the committed manifest
MoltenCodes Test: PASS registry.facade: MoltenCodes.Registry aliases the newest loaded generation, which is generation 2
MoltenCodes Test: PASS registry.facade: every installed Kit is registered at its committed API and revision and publishes that REVISION
MoltenCodes Test: PASS registry.lookup: Registry:Find of a package nobody registered returns nil and absent without raising
MoltenCodes Test: PASS registry.lookup: Registry:Find of a registered Kit under another API generation returns nil and generation_mismatch
MoltenCodes Test: PASS registry.lookup: Registry:Get of a package nobody registered returns nil and nil without raising
MoltenCodes Test: PASS registry.lookup: Registry:Find and Registry:Get allocate nothing over 10000 calls each (allocation guard)
MoltenCodes Test: PASS registry.lookup: a Registry:Get argument error names RegistrySuite.lua at the calling line
MoltenCodes Test: PASS registry.lookup: a Registry:Find argument error names RegistrySuite.lua at the calling line
MoltenCodes Test: PASS registry.bootstrap: Bootstrap of a new probe package registers it and hands back a fresh table
MoltenCodes Test: PASS registry.bootstrap: a second probe copy at the same revision reuses the first copy's table
MoltenCodes Test: PASS registry.bootstrap: a higher probe revision upgrades the shared table in place and keeps its identity
MoltenCodes Test: PASS registry.bootstrap: a lower probe revision steps aside and leaves the newer copy selected
MoltenCodes Test: PASS registry.bootstrap: the outgoing copy's retire hook runs once and its hand-over reaches the incoming migration
MoltenCodes Test: PASS registry.bootstrap: a Registry:Bootstrap argument error names RegistrySuite.lua at the calling line
MoltenCodes Test: PASS registry.globals: the framework publishes only the globals docs/EMBEDDING.md names
MoltenCodes Test: registry: 17 passed, 0 failed, 0 skipped, 0 timed out (17 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

Running it again in the same session prints the same lines: every Bootstrap
test registers a probe package under a fresh ID (`mctRegistryProbe1`,
`mctRegistryProbe2`, ...). Those probes stay registered until the next
`/reload`, because Registry has no way to remove a registration; they are
harmless and appear in the saved `client.packages` of later runs in the same
session.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `MoltenCodes.Registries[2] is the Registry facade ...` | The namespace the client loaded publishes generation 2 with every method `docs/API.md` lists. |
| `the installed Registry carries the revision ...` | The Registry that won in this session is the committed revision, not an older or newer copy. |
| `MoltenCodes.Registry aliases the newest loaded generation ...` | The alias is the highest generation in `Registries`, and that is 2. |
| `every installed Kit is registered at its committed API and revision ...` | Every Kit in `Expected.lua` (TestKit included) answers `Registry:Get` with the committed revision and publishes the same `REVISION`. |
| `Registry:Find of a package nobody registered ...` | A miss is `nil, "absent"`, never an error. |
| `Registry:Find of a registered Kit under another API generation ...` | A generation miss is `nil, "generation_mismatch"`. |
| `Registry:Get of a package nobody registered ...` | `Get` answers `nil, nil` for a miss. |
| `Registry:Find and Registry:Get allocate nothing ...` | 10000 hits and misses of each move `collectgarbage("count")` by at most 1 KB on the client's own collector. |
| `a Registry:Get / Find / Bootstrap argument error names RegistrySuite.lua ...` | The error points at the calling line of this file as the client names it, not inside `Registry.lua`. |
| `Bootstrap of a new probe package ...` | First registration: a fresh table, no previous revision, nothing selected, nothing handed over. |
| `a second probe copy at the same revision ...` | A same-revision copy is refused and handed the first copy. |
| `a higher probe revision upgrades ...` | An upgrade keeps the table's identity, and a cached reference runs the new code. |
| `a lower probe revision steps aside ...` | An older copy is refused and the newer one stays selected. |
| `the outgoing copy's retire hook runs once ...` | The hook runs once with the incoming revision, its hand-over passes through the migration, and a later upgrade does not call it again. |
| `the framework publishes only the globals docs/EMBEDDING.md names` | No global starts with `MoltenCodes` except `MoltenCodes` and the harness's own, exactly one private `__MOLTENCODES...` key exists, and `wow`, when ApiKit reports it published, is `MoltenCodes.wow`. |

## What counts as unexpected

- Any `FAIL`, `SKIP` or `TIMEOUT` line, or a totals line other than
  `17 passed, 0 failed, 0 skipped, 0 timed out (17 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer
  did not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_Registry`.
- `every installed Kit ...` failing with "is at revision N, expected M": another
  enabled addon embeds a different copy of that Kit. Say which addons are
  enabled; the test is then reporting the session truthfully.
- `the framework publishes only the globals ...` failing: its logs name every
  unexpected global.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (the client's own error
   messages with their paths, the measured memory delta, ApiKit's `wow` status,
   the private key's name) and the client facts. Lua shortens a long file path
   from the left, so a logged message may start with `...`; the tests compare
   only the `RegistrySuite.lua:<line>` suffix.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
