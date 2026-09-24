# Expected result: `/mct run hookKit`

Installed with
`python3 -m tooling.client.install --wow-dir "/Applications/World of Warcraft" --package hookKit`
and nothing else from the MoltenCodes framework enabled in the client.

Run it standing idle, **out of combat**, solo, outside any instance (a capital
city is ideal). No test needs combat, a group or an instance, and nothing a
test does is visible.

## What is hooked, and why it is harmless

HookKit is the most taint-sensitive Kit, so this addon keeps to three rules:

- **One Blizzard function, post-hooked securely.** The only Blizzard function
  the suite hooks is the global `IsLinuxClient`: a C function of the client's
  Build system that takes no argument, answers one boolean, has no side effect
  or restriction flag, returns no secret, and has nothing to do with combat,
  units, actions or protected frames (see
  `packages/apiKit/metadata/retail/namespaces.json`, `BuildDocumentation.lua`).
  It is hooked only with `SecureHook`, which goes through the client's
  `hooksecurefunc` and leaves the global secure; the test checks exactly that
  with the client's `issecurevariable`.
- **Non-secure hooks of it are only ever refused.** The tests that ask HookKit
  for `Hook` or `RawHook` of `IsLinuxClient` expect a refusal, and run only
  while `issecurevariable("IsLinuxClient")` answers `true`, which is exactly
  when HookKit refuses. If another addon already tainted the global, they are
  reported as `SKIP` instead.
- **Nothing protected is hooked.** The protected-frame refusals are asked of a
  secure action button (`SecureActionButtonTemplate`) the suite creates itself,
  out of combat: it has no action, no size and is never shown. Every other
  hook targets a table or a plain 1x1, alpha-0 test frame without a parent that the
  suite owns.

## At login

One line from the harness:

```text
MoltenCodes Test: test suites loaded for hookKit. Type /mct run hookKit to run them; /mct help lists every command.
```

## After `/mct run hookKit`

Within a second or two, exactly these lines, in this order (`PASS` is green
and `SKIP` yellow in the client):

```text
MoltenCodes Test: running hookKit: 9 suites. Results follow when every test has finished.
MoltenCodes Test: PASS hookKit.facade: Registry:Get('hookKit', 1) is the HookKit facade with API 1, every documented method, MAX_HOOKS 256 and UNBOUNDED
MoltenCodes Test: PASS hookKit.facade: the installed HookKit carries the revision of the committed manifest
MoltenCodes Test: PASS hookKit.secureGlobal: SecureHook of the Blizzard global IsLinuxClient runs the handler once per call with no argument, the caller gets the original answer, and issecurevariable still reports the global secure
MoltenCodes Test: PASS hookKit.secureGlobal: Unhook of that secure post-hook silences the handler but leaves the client's hooksecurefunc wrapper installed and the global secure (a secure hook cannot be removed)
MoltenCodes Test: PASS hookKit.secureGlobal: Hook and RawHook of the secure Blizzard global IsLinuxClient are refused at the calling line, write nothing and leave the global secure
MoltenCodes Test: PASS hookKit.secureMethod: SecureHook of a method of a test-owned table passes the receiver and every argument, explicit nils included, and the caller gets the original's results unchanged
MoltenCodes Test: PASS hookKit.secureMethod: a raising secure post-hook handler is reported once to the client's error handler, naming HookKitSuite.lua at the raising line, and the caller still gets the original's results
MoltenCodes Test: PASS hookKit.scripts: SecureHookScript runs OnShow and OnHide handlers with the frame when a hidden 1x1 test frame is shown and hidden, and Unhook silences them
MoltenCodes Test: PASS hookKit.scripts: the client's own Frame:HookScript answers true for OnShow on a test-owned frame (HookKit discards this answer; it is logged)
MoltenCodes Test: PASS hookKit.scripts: SecureHookScript of a script a plain Frame lacks records no hook when the client declines it (the client's own HookScript answer is logged)
MoltenCodes Test: PASS hookKit.scripts: HookScript runs its handler before the frame's own OnShow with the frame, and Unhook puts that same script back
MoltenCodes Test: PASS hookKit.scripts: RawHookScript of OnHide on a frame without one receives nil as the previous script, and Unhook leaves OnHide empty again
MoltenCodes Test: PASS hookKit.scripts: a script pre-hook is refused at the calling line while a SecureHookScript post-hook holds that script; the safe order (pre-hook first) runs both, and unhooking the pre-hook then leaves it inert
MoltenCodes Test: PASS hookKit.scripts: Frame:SetScript over a client HookScript post-hook runs the new script; whether the post-hook survives is logged (why HookKit refuses a pre-hook after a post-hook)
MoltenCodes Test: PASS hookKit.access: a test-owned frame answers IsForbidden false and CanBeAccessedInContext true, and SecureHookScript accepts it
MoltenCodes Test: SKIP hookKit.access: a script hook of a genuinely forbidden frame is refused at the calling line -- no forbidden frame is reachable from addon code without side effects; hookKit.errors checks the refusal on a stand-in, packages/hookKit/tests on the fixture
MoltenCodes Test: PASS hookKit.access: Hook of Show on a test-owned frame is refused at the calling line: the method the frame inherits from the client's widget table is secure there, and the frame gets no field
MoltenCodes Test: PASS hookKit.access: on a test-owned secure action button (IsProtected true), HookScript of OnClick is refused outright and RawHookScript of OnEnter without forceSecure too, both at the calling line, and the scripts stay as they were
MoltenCodes Test: SKIP hookKit.access: during combat lockdown a forced script hook of the test's secure button is refused at the calling line (passive: skipped out of combat) -- the player is not in combat; this passive test never starts combat
MoltenCodes Test: PASS hookKit.release: Unhook of a pre-hook and of a replacement on a test-owned table writes each original back exactly, and a second Unhook answers false
MoltenCodes Test: PASS hookKit.release: UnhookAll undoes every hook newest first and keeps the scope usable; Close is terminal and a later hook is refused at the calling line
MoltenCodes Test: PASS hookKit.release: a scope opened with maxHooks 1 answers nil and full to a second hook and leaves that target untouched
MoltenCodes Test: PASS hookKit.release: ForAddon with this test addon's name returns one open scope that names the addon, with the default limit of 256
MoltenCodes Test: PASS hookKit.allocation: a secure post-hooked table method called 10000 times allocates nothing, active and after Unhook, through the client's hooksecurefunc wrapper (allocation guard)
MoltenCodes Test: PASS hookKit.allocation: a pre-hooked and a raw-hooked table method called 10000 times each allocate nothing (allocation guard)
MoltenCodes Test: PASS hookKit.allocation: IsHooked, Original and GetActiveCount of hooked and never-hooked targets allocate nothing over 5000 rounds (allocation guard)
MoltenCodes Test: PASS hookKit.errors: SecureHook with a handler that is not a function names HookKitSuite.lua at the calling line
MoltenCodes Test: PASS hookKit.errors: Hook of a field that holds no function names HookKitSuite.lua at the calling line
MoltenCodes Test: PASS hookKit.errors: a second hook of one target in one scope is refused at the calling line
MoltenCodes Test: PASS hookKit.errors: Hook with an unknown option field is refused at the calling line and installs nothing
MoltenCodes Test: PASS hookKit.errors: a scope method called with a dot instead of a colon names HookKitSuite.lua at the calling line
MoltenCodes Test: PASS hookKit.errors: SecureHookScript on a stand-in whose IsForbidden answers true is refused at the calling line before any frame method runs
MoltenCodes Test: PASS hookKit.errors: CreateScope with maxHooks 0 is refused at the calling line
MoltenCodes Test: PASS hookKit.secrets: a secret method name is refused by SecureHook and Hook at the calling line before HookKit compares it
MoltenCodes Test: PASS hookKit.secrets: a secret global name is refused by SecureHook and by Unhook at the calling line
MoltenCodes Test: PASS hookKit.secrets: a secret script name is refused by SecureHookScript and HookScript at the calling line
MoltenCodes Test: PASS hookKit.secrets: a secret addon name is refused by ForAddon and a secret maxHooks by CreateScope at the calling line
MoltenCodes Test: PASS hookKit.secrets: a secret argument reaches a pre-hook handler, the original and a secure post-hook handler still secret, and the original's secret result reaches the caller
MoltenCodes Test: hookKit: 36 passed, 0 failed, 2 skipped, 0 timed out (38 tests)
MoltenCodes Test: results saved in MoltenCodesTestResults; /reload or log out to write them to disk.
```

The two `SKIP` lines are expected on every run out of combat:

- **A genuinely forbidden frame.** No forbidden frame can be reached from
  addon code without side effects. The refusal itself is checked on a stand-in
  whose `IsForbidden` answers `true` (`hookKit.errors`), and on the fixture by
  `packages/hookKit/tests`.
- **The combat-lockdown refusal** is a passive test: it runs only when the
  player already is in combat at `/mct run` (and after one earlier run out of
  combat has created the secure button). Out of combat it is skipped with
  "the player is not in combat". It never starts combat.

Running it again in the same session prints the same lines.

### If the run happens in combat

Every test that touches `IsLinuxClient` or the secure button is then reported
as `SKIP` with "the player is in combat; ...", and the passive combat test runs
instead (or skips with "the secure button is created out of combat by the test
before ..." when no earlier run made the button). Leave combat and run again.

## Visible side effects

None. No frame is shown on screen: the test frames are 1x1, at alpha 0, have
no texture and no parent, and the secure button is never shown. Nothing is
printed besides the harness lines. No sound plays, no CVar changes, no error
window opens.

## What a run leaves behind

Every scope a test creates is closed by its suite's After hook, pass or fail,
which silences every hook and writes back every original HookKit is documented
to restore. Then the `OnShow` and `OnHide` scripts of the plain test frames are
cleared and the frames hidden. The client's error handler is replaced only for
the one hooked call whose handler fails on purpose, and put back at once.

What stays for the rest of the session, by design (a secure hook cannot be
removed; `docs/API.md` of hookKit, "Secure post-hook"):

- **`IsLinuxClient`'s `hooksecurefunc` chain** grows by two inert closures per
  run (one per `secureGlobal` test that installs a post-hook). Each reads one
  flag and does nothing. The global stays secure. `/reload` removes them.
- **The test frames' `HookScript` chains** keep inert HookKit closures and a few
  no-op closures the `scripts` tests add directly with `Frame:HookScript`, one
  set per run.
- **The frames themselves:** eleven plain 1x1 test frames and one secure
  action button, created on the first run and reused by later ones, because
  the client never frees a frame.
- **This addon's HookKit scope**, `HookKit:ForAddon("MoltenCodesTest_HookKit")`,
  open and empty; LifecycleKit closes it at logout.
- HookKit's memo that `IsLinuxClient` and the widget method `Show` were secure
  (weak-keyed, `docs/INTERNALS.md` of hookKit, `secureStatus`).

Nothing is written to a global, a saved variable (other than the harness's own
results) or a CVar.

## What each test proves

| Test | Proves in the real client |
|---|---|
| `Registry:Get('hookKit', 1) is the HookKit facade ...` | The facade the client loaded is API 1, has `CreateScope`, `ForAddon`, `CloseAddonScopes`, `MAX_HOOKS` 256, `UNBOUNDED` and a `Scope` prototype with every method `docs/API.md` lists. |
| `the installed HookKit carries the revision ...` | Registry's selected revision and the facade's `REVISION` are both the committed manifest's. |
| `SecureHook of the Blizzard global IsLinuxClient ...` | The client's `hooksecurefunc` runs HookKit's closure once per call with no argument, the caller gets the answer the unhooked function gave, `IsHooked` reports `"secure"`, and the client's `issecurevariable("IsLinuxClient")` still answers `true` after the hook: the post-hook did not taint the global. The log says whether `hooksecurefunc` replaced the global with a new function and what `issecure()` answers inside the handler. |
| `Unhook of that secure post-hook ...` | After `Unhook` the handler no longer runs, the global still holds the client's wrapper (HookKit wrote nothing back, which would have tainted it), and `issecurevariable` still answers `true`. This is the documented limit: a secure hook can be silenced, not removed. |
| `Hook and RawHook of the secure Blizzard global ...` | HookKit's secure-target refusal, asked through the client's real `issecurevariable`, names this file at the calling line, the global is the same function afterwards and still secure, and the scope holds nothing. |
| `SecureHook of a method of a test-owned table ...` | Through the client's `hooksecurefunc` on a table method, the handler receives the receiver and all four arguments with their nils and count, and the caller gets the original's five results unchanged. |
| `a raising secure post-hook handler is reported once ...` | HookKit's `pcall` around the handler: the failure reaches the handler `seterrorhandler` installed exactly once, naming this file at the raising line, and the call still returns the original's results. No error window opens. |
| `SecureHookScript runs OnShow and OnHide handlers ...` | The client's `Frame:HookScript` post-hooks run when a real frame is shown and hidden, with the frame as argument, and are silent after `Unhook`. |
| `the client's own Frame:HookScript answers true ...` | What the Retail `HookScript` returns (documented as a `success` boolean) for a script the frame has: one value, `true`. HookKit discards this value; the log records it. |
| `SecureHookScript of a script a plain Frame lacks ...` | What the client does with `HookScript` of `OnValueChanged` on a plain Frame (raise, or answer `false`; logged), and that HookKit then records no hook. See "What counts as unexpected" for the `false` case. |
| `HookScript runs its handler before the frame's own OnShow ...` | A script pre-hook installed with the client's `SetScript` runs first with the frame, the frame's own script still runs, `Original` returns that script, and `Unhook` puts that same function back (`GetScript` returns it). |
| `RawHookScript of OnHide on a frame without one ...` | A replacement receives `nil` as the previous script and the frame, and `Unhook` leaves `OnHide` empty. |
| `a script pre-hook is refused at the calling line while ...` | The install-order refusal names this file at the calling line across scopes; pre-hook then post-hook run in that order; unhooking the pre-hook leaves its closure in place, inert, and the post-hook keeps running. The log says whether `GetScript` changes when the client adds a `HookScript` post-hook. |
| `Frame:SetScript over a client HookScript post-hook ...` | The fact behind HookKit's install-order rule: after `SetScript`, the new script runs, and the log says whether the earlier `HookScript` post-hook survived (`true`) or was dropped (`false`). Send it back either way. |
| `a test-owned frame answers IsForbidden false ...` | The two access probes HookKit asks answer `false` and `true` for an addon's own frame, and `SecureHookScript` accepts it. |
| `Hook of Show on a test-owned frame is refused ...` | On a real frame, `Show` is inherited through the metatable's `__index` table, the client reports it secure there, and HookKit refuses the non-secure hook at the calling line without writing a `Show` field on the frame. The log holds what `getmetatable` and `issecurevariable` answered. |
| `on a test-owned secure action button ...` | The client reports a `SecureActionButtonTemplate` button protected, HookKit refuses `OnClick` outright and `OnEnter` without `forceSecure`, both at the calling line, and neither script changes. |
| `Unhook of a pre-hook and of a replacement ...` | Both originals are written back as the exact functions, a second `Unhook` answers `false`, and the replacement received the original first. |
| `UnhookAll undoes every hook newest first ...` | `Hooks()` lists the kinds in creation order, `UnhookAll` answers 3 and restores the frame's empty `OnShow`, the scope stays usable, `Close` answers `true` then `false`, and a later hook raises at the calling line. |
| `a scope opened with maxHooks 1 ...` | The limit answers `nil, "full"` and leaves the target untouched. |
| `ForAddon with this test addon's name ...` | `ForAddon` returns the same open scope every time, naming this addon, with the default limit 256. |
| `a secure post-hooked table method called 10000 times ...` | The whole hooked path, the client's `hooksecurefunc` wrapper included, allocates nothing on the client's collector, active and inert. |
| `a pre-hooked and a raw-hooked table method ...` | HookKit's pre-hook and replacement closures allocate nothing per call. |
| `IsHooked, Original and GetActiveCount ...` | Lookups, of a hooked table and of one never hooked, create nothing. |
| The seven `hookKit.errors` tests | Each documented argument error names this file at the calling line, with the documented message. The forbidden stand-in's `HookScript` is never reached. |
| The four secret-name tests | Genuine secrets made by `secretwrap` as a method, global, script or addon name, or as `maxHooks`, are refused at the calling line with the documented message before HookKit compares them or uses them as keys; nothing is installed. |
| `a secret argument reaches a pre-hook handler ...` | A secret passes through a pre-hook, the original and a `hooksecurefunc` post-hook untouched: every handler sees it secret, and the caller gets a secret of type `number`. |

## What counts as unexpected

- Any `FAIL` or `TIMEOUT` line, any `SKIP` other than the two above, or a
  totals line other than `36 passed, 0 failed, 2 skipped, 0 timed out (38 tests)`.
- **`SecureHookScript of a script a plain Frame lacks ...` failing with "the
  client declined HookScript, yet HookKit recorded the hook ...":** the client
  answered `false` instead of raising, and HookKit ignores that answer. That is
  a HookKit defect to report, not a fault of the run; the log holds the
  client's exact answer.
- A `secureGlobal` test reported as `SKIP` with "IsLinuxClient is already
  tainted in this session": another addon wrote over that global. `/reload`
  with other addons disabled and run again.
- A `secureGlobal` test failing at `ToBeSecure`: the post-hook tainted the
  global. That is a serious finding; send the saved file back at once and
  `/reload` before playing.
- `Hook of Show on a test-owned frame ...` reported as `SKIP`: the client hides
  the frame's method table or does not report `Show` secure there; the log says
  which.
- The secure-button test reported as `SKIP` with "the client does not report a
  SecureActionButtonTemplate button as protected".
- The error-handler test failing with "the client's error handler could not be
  replaced": an error-capturing addon (BugGrabber, usually with BugSack) keeps
  the handler. Disable it and run again.
- A Lua error window, a BugSack entry, or a blocked-action warning naming
  `MoltenCodes`, `MoltenCodesTest` or `MoltenCodesTest_HookKit`. The
  `secureMethod` test raises `mctHookKit deliberate handler failure` on
  purpose, but it must reach only the test's own collector.
- `the installed HookKit carries the revision ...` failing: another enabled
  addon embeds a different HookKit copy.

## What to send back

1. The chat lines above as they appeared (a screenshot, or a copy of the chat
   log), including any line that differs and any blocked-action warning.
2. After `/reload` or a logout, the file
   `/Applications/World of Warcraft/_retail_/WTF/Account/<ACCOUNT>/SavedVariables/MoltenCodesTest.lua`.
   Its logs answer the open questions: what `Frame:HookScript` returns, what
   the client does with `HookScript` of a script a frame lacks, whether
   `SetScript` drops `HookScript` post-hooks, whether `GetScript` changes when a
   post-hook is added, whether `hooksecurefunc` replaces the global, what
   `issecure()` answers inside a post-hook, the frame's metatable shape, and
   every memory delta. Lua shortens a long file path from the left, so a logged
   message may start with `...`; the tests compare only the
   `HookKitSuite.lua:<line>` part.
3. The text of any Lua error, with `/console scriptErrors 1` turned on.
4. The list of other enabled addons, when a test failed.
