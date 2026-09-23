# Changelog

## 0.1.0 — 2026-09-23

- Added TestKit API generation 1, implementation revision 1: in-client test suites for development addons. TestKit is development-only and must not be part of a release bundle.
- Added `TestKit:Suite(name, options)` with `phase` (`"loaded"` or `"ready"`, default `"ready"`), `addonName` (default: the suite name) and `timeoutSeconds` (default 10). A duplicate name is refused with `nil, "taken"`, a 65th suite with `nil, "full"`.
- Added suite methods `Test`, `Skip`, `Before`, `After` and `GetName`: at most 256 tests and 16 hooks of each kind per suite, `nil, "full"` beyond.
- Added the test context: `Replace` (raw, restored in reverse order after the After hooks, also after a failure or a timeout, also for `nil`; secret values refused), `Yield`, `WaitFor(eventName, timeoutSeconds)` (EventKit through `Registry:Find`), `WaitUntil(predicate, timeoutSeconds)`, `Expect`, `Fail` and `Log` (64 lines per test).
- Added matchers `ToBe`, `ToEqual` (deep, 16 levels, raw access, first differing path reported), `ToBeTruthy`, `ToBeNil`, `ToRaise(pattern)` and `ToBeSecure(table, key)` over `issecurevariable`, each with `Not`. Failure messages describe values by type and at most 64 quoted bytes, describe a secret as `<secret value>`, and point at the test's own line. A comparison a secret makes impossible fails even under `Not`.
- Added `TestKit:Run(filter)` (every suite, `"suite"` or `"suite/test"`): suites wait for their LifecycleKit phase; tests run one at a time inside one SchedulerKit job, each step in its own coroutine; a test that outlives its limit is abandoned as `"timeout"` and its After hooks still run. A suite whose phase can no longer be reached (halted or shut down) is reported as skipped.
- Added `TestKit:Report()`, `TestKit:OnFinished(callback)` (16 callbacks) and `TestKit:Reset()`, which also abandons a run in progress.
- Added `fidelity/FixtureFidelity.lua`, the fixture-fidelity suite, and a Busted spec that runs the same file against the shared fixture and names the facts the fixture does not model yet (`InCombatLockdown`, `C_Timer.After`).
- The runner job, phase subscriptions, wait callbacks and the deadline timer call through a shared dispatch table, and suites, contexts and matchers keep their metatables across upgrades, so an in-place upgrade keeps suites, results, a waiting test and a queued suite.
- 92 specs, including an in-place upgrade spec and a cost spec: loading and registering create no frame, timer or event registration, and a finished run leaves none behind.
