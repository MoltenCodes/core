# Expected result: `/mct run lifecycleKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package lifecycleKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it out of combat, solo, outside any instance (a capital city is ideal). No
test needs combat, a group or an instance, and none waits: a normal run
finishes within a second or two. One optional test uses combat, and only when
you are already in it; see [Optional: the training-dummy run](#optional-the-training-dummy-run).

Most of what these tests prove happened while the client loaded the addon, at
login or at `/reload`: the test addon records what it saw then, and the run
checks the record. Logging in and running, or `/reload` and running, are both
fine.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for lifecycleKit. Type /mct run lifecycleKit to run them; /mct help lists every command.
```

## After `/mct run lifecycleKit`

Within about two seconds, exactly these lines, in this order (`PASS` is green
and `SKIP` yellow in the client):

```text
MoltenCodes Test: running lifecycleKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS lifecycleKit.facade: Registry:Get('lifecycleKit', 1) is the LifecycleKit facade with API 1, every documented method, UNBOUNDED and CLOSES_ADDON_SCOPES
MoltenCodes Test: PASS lifecycleKit.facade: the installed LifecycleKit carries the revision of the committed manifest
MoltenCodes Test: PASS lifecycleKit.phases: while this file ran, the client reported the addon not finished loading and not logged in, and its instance was loading
MoltenCodes Test: PASS lifecycleKit.phases: the Kit reached loaded at this addon's ADDON_LOADED and ready at PLAYER_LOGIN, each before a listener connected after it
MoltenCodes Test: PASS lifecycleKit.phases: ForAddon with this addon's name returns the instance created at load, ready and neither halted nor shut down
MoltenCodes Test: PASS lifecycleKit.phases: OnLoaded and OnReady made after their phase run at once with the instance and return a disconnected subscription
MoltenCodes Test: PASS lifecycleKit.phases: OnShutdown and OnHalted made now stay pending without running, and Disconnect ends them
MoltenCodes Test: PASS lifecycleKit.dependencies: DependsOn the loaded harness addon records it once, and no halt notice is delivered
MoltenCodes Test: PASS lifecycleKit.dependencies: DependsOn an addon that is not installed records it once, and no halt notice is delivered
MoltenCodes Test: SKIP lifecycleKit.dependencies: Halt of a throwaway instance tells a dependent through OnDependencyHalted -- not exercised: API 1 keeps every ForAddon instance for the session and halted is terminal, so a probe addon would stay halted until /reload; Halt reads no client API, and packages/lifecycleKit/tests/Halt_spec.lua proves it
MoltenCodes Test: PASS lifecycleKit.combatGate: out of combat, WhenOutOfCombat runs the callback with the instance and true before it returns and hands back a spent call
MoltenCodes Test: PASS lifecycleKit.combatGate: SetCombatQueueLimit changes this addon's limit, including to UNBOUNDED, and GetCombatQueueLimit reads it back
MoltenCodes Test: PASS lifecycleKit.capabilities: CLOSES_ADDON_SCOPES names exactly the seven Kits shutdown closes, holds no keys of its own and refuses every write
MoltenCodes Test: PASS lifecycleKit.capabilities: every Kit CLOSES_ADDON_SCOPES names is loaded from the bundle at a version documented to read it
MoltenCodes Test: PASS lifecycleKit.errors: ForAddon with an empty name is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.errors: OnReady with a callback that is not a function is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.errors: Halt with an empty reason is refused at the calling line and halts nothing
MoltenCodes Test: PASS lifecycleKit.errors: DependsOn this addon's own name is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.errors: SetCombatQueueLimit(0) is refused at the calling line and leaves the limit unchanged
MoltenCodes Test: PASS lifecycleKit.errors: SetLimits with a limit LifecycleKit does not know is refused at the calling line and changes nothing
MoltenCodes Test: PASS lifecycleKit.errors: GetLimits called with a dot is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.secrets: ForAddon with a secret name is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.secrets: Halt with a secret reason is refused at the calling line and halts nothing
MoltenCodes Test: PASS lifecycleKit.secrets: DependsOn with a secret addon name is refused at the calling line
MoltenCodes Test: PASS lifecycleKit.secrets: SetCombatQueueLimit with a secret limit is refused at the calling line and leaves the limit unchanged
MoltenCodes Test: PASS lifecycleKit.secrets: SetLimits with a secret maxDependencies is refused at the calling line and changes nothing
MoltenCodes Test: SKIP lifecycleKit.shutdown: at logout the Kit reaches shutdown and closes this addon's scopes after its OnShutdown callbacks -- not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/lifecycleKit/tests/OwnedScopes_spec.lua proves it
MoltenCodes Test: SKIP lifecycleKit.combatDeferral: in combat, WhenOutOfCombat queues the call, refuses one past the limit, and runs it at PLAYER_REGEN_ENABLED before OnCombatEnd -- not in combat; to exercise it, attack a training dummy and type /mct run lifecycleKit (EXPECTED.md)
MoltenCodes Test: lifecycleKit: 25 passed, 0 failed, 3 skipped, 0 timed out (28 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The three `SKIP` lines are expected on every normal run:

- **Halt of a throwaway instance.** `Halt` needs an instance, and the only
  instance the test could halt without harm is one made for a probe name.
  LifecycleKit API 1 keeps every `ForAddon` instance for the session and
  halted is terminal, so the probe would stay in the session's state, halted,
  until `/reload`. The docs do not describe that as free of side effects, and
  `Halt` reads nothing from the client, so the Busted specs are the right
  place for it. The refusals of `Halt` (empty and secret reason) are tested
  here, on this addon's own instance, and leave it running.
- **Logout.** What shutdown does (the combat queue closed with `"shutdown"`,
  the `OnShutdown` callbacks, then the TimerKit, SchedulerKit, EventKit,
  HookKit, CommandKit and CommKit scopes and the SignalKit bus closed in that
  order) happens at `PLAYER_LOGOUT`, after which the client runs no more addon
  code that could print or save a result. Do not log out to test it.
- **The training-dummy test**, unless you ran it in combat (below).

Running it again in the same session prints the same lines.

### On a client without secret values

The five `lifecycleKit.secrets` tests need the client's `issecretvalue` and
`secretwrap`, which Retail 12.1 has. A client without them prints each of the
five with `SKIP` and ` -- the client has no issecretvalue and secretwrap; the
secret path was not exercised`, and the totals line reads
`20 passed, 0 failed, 8 skipped, 0 timed out (28 tests)`.

## Optional: the training-dummy run

This proves the one thing the combat gate does that needs real combat: work
handed to `WhenOutOfCombat` in combat waits, and runs when the client ends
combat. The test is passive: it attacks nothing, casts nothing and moves
nothing; it only reads the combat you are already in.

1. Stand at a training dummy (any capital city or your class hall), with
   nothing else pulled.
2. Start attacking it (auto-attack is enough).
3. While still in combat, type `/mct run lifecycleKit`.
4. Keep attacking for about three more seconds, then stop attacking and step
   back. The dummy drops combat a few seconds after the last hit.
5. The results appear once combat has ended; the test waits for it up to 30
   seconds.

Expected lines: the same list as above, except for two lines. The
out-of-combat test is skipped, because the run started in combat:

```text
MoltenCodes Test: SKIP lifecycleKit.combatGate: out of combat, WhenOutOfCombat runs the callback with the instance and true before it returns and hands back a spent call -- in combat, so the out-of-combat path was not exercised; run it again out of combat
```

and the training-dummy test passes:

```text
MoltenCodes Test: PASS lifecycleKit.combatDeferral: in combat, WhenOutOfCombat queues the call, refuses one past the limit, and runs it at PLAYER_REGEN_ENABLED before OnCombatEnd
```

The totals line is the same, `25 passed, 0 failed, 3 skipped, 0 timed out (28 tests)`.

The test sets this addon's combat-queue limit to 1, queues one call, checks
that a second call is refused with `nil, "full"`, then waits. When combat ends
it checks that the queued call ran once as `(instance, true)`, with
`InCombatLockdown()` already `false` and `LifecycleKit:IsInCombat()` `false`
inside it, and that it ran before the addon's `OnCombatEnd` notice, which ran
before a plain EventKit `PLAYER_REGEN_ENABLED` listener connected after
LifecycleKit's own. The queue limit is put back afterwards.

If combat does not end within 30 seconds (you kept attacking, or something
else attacked you), the test fails with
`combat did not end within 30 seconds; stop attacking right after typing the command`;
its After hook cancels the queued call and puts the limit back, so nothing is
left waiting. Run it again.

## Visible side effects

None. No test prints anything to chat besides the harness lines, changes a
setting, raises an error window or touches the world. The deliberate errors
the `errors` and `secrets` tests provoke are caught with `pcall` inside the
test.

## What a run leaves behind

Every subscription, connection and deferred call a test makes is released by
its suite's After hook, pass or fail; the combat-queue limit a test changes is
put back. `SetLimits` is only ever called with values it refuses, so the
package-wide limits never change. What stays for the session, because
LifecycleKit API 1 cannot release it:

- the lifecycle instance of `MoltenCodesTest_LifecycleKit`, created while the
  addon loaded, like every addon's;
- two dependencies recorded on it, on `MoltenCodesTest` and on
  `MoltenCodesTest_NoSuchAddon`. A later run records nothing new (its
  `DependsOn` answers `false`). No lifecycle instance is created for
  `MoltenCodesTest_NoSuchAddon`: `DependsOn` does not need one.

The two plain EventKit listeners the addon connects while it loads
(`ADDON_LOADED` and `PLAYER_LOGIN`) disconnect themselves when their event
arrives, during the login. Nothing is written to a global or a saved variable.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('lifecycleKit', 1) is the LifecycleKit facade ...` | The facade the client loaded is API 1 and carries `ForAddon`, `IsInCombat`, `SetLimits`, `GetLimits`, `UNBOUNDED` and `CLOSES_ADDON_SCOPES`; the instance carries every documented method. |
| `the installed LifecycleKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's, not an older or newer embedded copy. |
| `while this file ran, the client reported ...` | While the addon's own file ran, `C_AddOns.IsAddOnLoaded` answered "not finished" (the second value, the one LifecycleKit trusts), `IsLoggedIn()` answered `false`, and the instance `ForAddon` created then was `loading`. The log holds both values of `IsAddOnLoaded`, `InCombatLockdown()` and `IsInCombat()` at that moment. |
| `the Kit reached loaded at this addon's ADDON_LOADED ...` | The real order: the file ran (`loading`), `OnLoaded` ran (`loaded`, not logged in), then a plain `ADDON_LOADED` listener connected after LifecycleKit's (`loaded`), then `OnReady` (`ready`, logged in), then a plain `PLAYER_LOGIN` listener (`ready`). The log lists each step with the state and `IsLoggedIn()`. |
| `ForAddon with this addon's name returns the instance ...` | `ForAddon` is idempotent across the session and the instance is `ready`, not halted, not shut down, with no halt reason. |
| `OnLoaded and OnReady made after their phase ...` | Replay: a late subscription runs its callback before the method returns, with the instance, and comes back disconnected (`Disconnect` answers `false`). |
| `OnShutdown and OnHalted made now stay pending ...` | Subscriptions to phases not reached stay connected without running, and `Disconnect` ends them (`true`). |
| `DependsOn the loaded harness addon ...` | The harness's own instance is `ready`; `DependsOn("MoltenCodesTest")` answers `true` (or `false` when an earlier run recorded it), then `false`, with no reason; `OnDependencyHalted` replays nothing because nothing halted. |
| `DependsOn an addon that is not installed ...` | The same for a name the client reports as not loaded: the dependency is recorded and nothing is delivered. The log holds what `C_AddOns.IsAddOnLoaded` answered for the name. |
| `out of combat, WhenOutOfCombat runs the callback ...` | With `InCombatLockdown()` and `IsInCombat()` both `false`, the callback runs once, before `WhenOutOfCombat` returns, as `(instance, true)`, and the handle is spent (`IsPending` and `Cancel` answer `false`). |
| `SetCombatQueueLimit changes this addon's limit ...` | The limit (logged; 64 unless another addon changed it) reads back as 3, then as `UNBOUNDED`, and is put back. |
| `CLOSES_ADDON_SCOPES names exactly the seven Kits ...` | `timerKit`, `schedulerKit`, `eventKit`, `hookKit`, `commandKit`, `commKit` and `signalKit` answer `true`; `lifecycleKit` and `testKit` are absent; `next` sees no key and `getmetatable` answers `false`; adding a field and overwriting `eventKit` both raise the documented read-only message and change nothing. |
| `every Kit CLOSES_ADDON_SCOPES names is loaded ...` | Each of the seven is loaded at the revision Expected.lua lists, and its manifest version is at least the one its docs name as the first that reads the field (TimerKit 0.6.0, SchedulerKit 0.8.0, EventKit 0.7.0, HookKit, CommandKit and CommKit 0.2.0, SignalKit 0.6.0). The log lists each version and revision. |
| `errors` tests | Each documented argument error names `LifecycleKitSuite.lua` at the calling line, with the documented message; the refused `Halt`, `SetCombatQueueLimit` and `SetLimits` change nothing. |
| `secrets` tests | A genuine secret from `secretwrap` passed as the `ForAddon` name, the `Halt` reason, the `DependsOn` name, the `SetCombatQueueLimit` limit or a `SetLimits` value is refused at the calling line before LifecycleKit compares it, and changes nothing. |
| `in combat, WhenOutOfCombat queues the call ...` | See [Optional: the training-dummy run](#optional-the-training-dummy-run). |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, any `SKIP` other than the three listed (or,
  in the training-dummy run, the out-of-combat one instead of the dummy one),
  or a totals line other than
  `25 passed, 0 failed, 3 skipped, 0 timed out (28 tests)`.
- No login line, or `Expected.lua is missing`: the harness or the installer did
  not run as intended.
- A Lua error window or a BugSack entry naming `MoltenCodes`,
  `MoltenCodesTest` or `MoltenCodesTest_LifecycleKit`.
- `while this file ran ...` failing: the client reported the addon finished
  loading, or the player logged in, while the addon's own file ran. The log
  holds what it answered; LifecycleKit's `loading` catch-up relies on it.
- `the Kit reached loaded at this addon's ADDON_LOADED ...` failing: the log
  lists the order and the states the Kit and the listeners saw. A step missing
  from the list means that event was never observed.
- `every Kit CLOSES_ADDON_SCOPES names is loaded ...` or
  `the installed LifecycleKit carries the revision ...` failing: another
  enabled addon embeds a different copy of a Kit.
- The training-dummy test failing for any reason but the 30-second wait.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs, and say whether you ran the
   training-dummy run.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   It holds the full report, each test's logs (what `C_AddOns.IsAddOnLoaded`,
   `IsLoggedIn()` and `InCombatLockdown()` answered while the addon loaded, the
   load order the Kit and the listeners saw, the `DependsOn` answers, the
   combat-queue limit, the Kit versions, the client's messages with their
   paths, and in the dummy run the order of the deferred call, `OnCombatEnd`
   and the `PLAYER_REGEN_ENABLED` listener) and the client facts. Lua shortens
   a long file path from the left, so a logged message may start with `...`;
   the tests compare only the `LifecycleKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
