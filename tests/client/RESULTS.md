# Real-client results

<!-- Rendered by `python3 -m tooling.client.report` from `results.json`; do not edit. -->

What the real-client test addons ([`README.md`](README.md)) proved in the game, per
client flavour. Each row is a package's latest recorded run on that flavour: the
default run (`/mct run <package>`) or a combat run (`/mct run <package> combat`).
Rows keep their own client, date and commit, so a session that runs a few
packages updates only their rows. `not run` marks a flavour without any recorded
run and `-` a package without one. A skip is never a pass: every skipped test is
listed below with its reason, and every gap in coverage under [Gaps](#gaps).
Compare a new run with the package's `EXPECTED.md`, not with this table.

## Flavours

| Flavour | Folder | Status |
|---|---|---|
| Retail | `_retail_` | 27 packages recorded, latest 2026-09-25 17:40:57 |
| Classic Era | `_classic_era_` | not run (no client session available; the owner has no active game time) |
| Mists Classic | `_classic_` | not run (no client session available; the owner has no active game time) |
| TBC Anniversary | `_anniversary_` | optional (not promised); not run yet |

## Matrix

| Package | Retail tests | passed | failed | skipped | timeout | Classic Era tests | passed | failed | skipped | timeout | Mists Classic tests | passed | failed | skipped | timeout |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| `apiKit` | 23 | 23 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `brokerKit` | 32 | 32 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `cacheKit` | 38 | 38 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `clientKit` | 41 | 40 | 0 | 1 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `codecKit` | 32 | 32 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `commandKit` | 36 | 33 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `commKit` | 30 | 26 | 0 | 4 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `compatKit` | 24 | 24 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `eventKit` | 19 | 18 | 0 | 1 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `hookKit` | 38 | 36 | 0 | 2 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `hookKit` (combat) | 1 | 1 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `interopKit` | 22 | 19 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `lifecycleKit` | 28 | 25 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `lifecycleKit` (combat) | 1 | 1 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `localeKit` | 32 | 29 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `logKit` | 38 | 38 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `mediaKit` | 34 | 32 | 0 | 2 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `moduleKit` | 39 | 36 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `optionsKit` | 29 | 29 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `poolKit` | 36 | 36 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `profileKit` | 42 | 40 | 0 | 2 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `readinessKit` | 32 | 29 | 0 | 3 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `registry` | 17 | 17 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `schedulerKit` | 37 | 35 | 0 | 2 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `schemaKit` | 34 | 34 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `settingsKit` | 40 | 39 | 0 | 1 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `signalKit` | 35 | 35 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `timerKit` | 29 | 27 | 0 | 2 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| `widgetKit` | 41 | 41 | 0 | 0 | 0 | not run | - | - | - | - | not run | - | - | - | - |
| **total (default runs)** | **878** | **843** | **0** | **35** | **0** | not run | - | - | - | - | not run | - | - | - | - |

## Runs

### Retail

| Package | Build | Interface | Locale | OS | Date | Commit |
|---|---|---:|---|---|---|---|
| `apiKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `brokerKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `cacheKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `clientKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `codecKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `commandKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `commKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `compatKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `eventKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `hookKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-25 17:38:47 | `73d1ee79b71c` |
| `hookKit` (combat) | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-25 17:39:30 | `73d1ee79b71c` |
| `interopKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `lifecycleKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-25 17:38:57 | `73d1ee79b71c` |
| `lifecycleKit` (combat) | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-25 17:40:57 | `73d1ee79b71c` |
| `localeKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `logKit` | 12.1.0 (69933) | 120100 | enUS | unknown | 2026-09-25 16:14:14 | unknown |
| `mediaKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `moduleKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `optionsKit` | 12.1.0 (69933) | 120100 | enUS | unknown | 2026-09-25 16:13:58 | unknown |
| `poolKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `profileKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `readinessKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `registry` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `schedulerKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `schemaKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `settingsKit` | 12.1.0 (69933) | 120100 | enUS | unknown | 2026-09-25 16:13:41 | unknown |
| `signalKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `timerKit` | 12.1.0 (69933) | 120100 | enUS | macOS | 2026-09-24/2026-09-25 | unknown |
| `widgetKit` | 12.1.0 (69933) | 120100 | enUS | unknown | 2026-09-25 16:14:06 | unknown |

### Classic Era

Not run: no client session available; the owner has no active game time.

### Mists Classic

Not run: no client session available; the owner has no active game time.

## Skipped tests

### Retail

| Package | Test | Reason |
|---|---|---|
| `hookKit` | hookKit.access: a script hook of a genuinely forbidden frame is refused at the calling line | no forbidden frame is reachable from addon code without side effects; hookKit.errors checks the refusal on a stand-in, packages/hookKit/tests on the fixture |
| `hookKit` | hookKit.combat: during combat lockdown a forced script hook of the test's secure button is refused at the calling line (passive: skipped out of combat) | the player is not in combat; type /mct run hookKit combat and attack a training dummy to run it |
| `lifecycleKit` | lifecycleKit.dependencies: Halt of a throwaway instance tells a dependent through OnDependencyHalted | not exercised: API 1 keeps every ForAddon instance for the session and halted is terminal, so a probe addon would stay halted until /reload; Halt reads no client API, and packages/lifecycleKit/tests/Halt_spec.lua proves it |
| `lifecycleKit` | lifecycleKit.shutdown: at logout the Kit reaches shutdown and closes this addon's scopes after its OnShutdown callbacks | not observable in a run: PLAYER_LOGOUT ends the session before a result could be printed or saved; packages/lifecycleKit/tests/OwnedScopes_spec.lua proves it |
| `lifecycleKit` | lifecycleKit.combatDeferral: in combat, WhenOutOfCombat queues the call, refuses one past the limit, and runs it at PLAYER_REGEN_ENABLED before OnCombatEnd | not in combat; type /mct run lifecycleKit combat and attack a training dummy to run it (EXPECTED.md, Combat run) |
| `settingsKit` | settingsKit.persistence: persistence step one: profile.scale 1.25, profile.anchor at its default, char.note, the per-character global.note and a marker are written through the views and stored in both raw saved tables | a marker from an earlier session is present; step two reads it, so nothing is rewritten |

Recorded before this command existed, without the tests' names and reasons (each is a skip the package's `EXPECTED.md` announces):

- `clientKit`: 1 skipped
- `commandKit`: 3 skipped
- `commKit`: 4 skipped
- `eventKit`: 1 skipped
- `interopKit`: 3 skipped
- `localeKit`: 3 skipped
- `mediaKit`: 2 skipped
- `moduleKit`: 3 skipped
- `profileKit`: 2 skipped
- `readinessKit`: 3 skipped
- `schedulerKit`: 2 skipped
- `timerKit`: 2 skipped

## Failed and timed-out tests

No failed or timed-out test recorded.

## Gaps

- **Windows client**: no run on a Windows client is recorded (the owner's clients run on macOS), so behaviour only a Windows client shows is unproven.
- **Group communication with a second character**: no second character is available: addon messages between two clients over party, raid or whisper, and anything that needs a group, are not exercised; CommKit's round trips whisper to the player's own character instead.
- **Conditions a solo session cannot create**: the skipped tests listed above are not exercised on that flavour; besides a missing client capability, their reasons name what one session cannot set up: a logout or /reload in the middle of a run, a line typed or a key pressed by the player, another addon's LibStub, LibSharedMedia or copy of a Kit, a restricted encounter, or a forbidden frame.
- **Classic Era**: not run: no client session available; the owner has no active game time.
- **Mists Classic**: not run: no client session available; the owner has no active game time.
- **TBC Anniversary** (optional, not promised): no run recorded yet.
- **Skip reasons**: 12 rows were recorded without the names and reasons of their skipped tests; the next run of each package records them.
