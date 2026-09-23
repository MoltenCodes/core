# Changelog

## 0.1.2 — 2026-09-23

- Limits (design constitution, principle 4a). Added `TestKit:SetLimits`, `TestKit:GetLimits()` and the `TestKit.UNBOUNDED` sentinel, modelled on SignalKit. The seven former constants become package-wide limits with unchanged defaults: `maxSuites` 64, `maxTests` 256, `maxHooks` 16, `maxLogLines` 64, `maxFinishedCallbacks` 16 and `maxReplacements` 256 accept `UNBOUNDED` (development-only; the consumer's own tests), and `maxEqualDepth` 16 accepts up to 64 and refuses `UNBOUNDED` because `ToEqual` recurses per level. `SetLimits` validates the whole table at the caller's line first; `GetLimits` returns a fresh table; `Reset` keeps the limits.
- Implementation revision 2, because the executed implementation changed. Revision-1 state is seeded with the former constants in place; `UNBOUNDED`, `SetLimits` and `GetLimits` join the public-surface check.
- New `Limits_spec.lua` and a bootstrap spec for the revision-1 upgrade. `docs/API.md` gains a "Limits" section.

## 0.1.1 — 2026-09-23

- Documentation only: no runtime change, implementation revision 1 is unchanged. The README states the seven-file minimum footprint. TimerKit 0.5.0 and SchedulerKit 0.6.0 no longer require LifecycleKit, so TestKit's required closure is the same seven packages reached by a shorter path (LifecycleKit brings SignalKit and EventKit; SchedulerKit brings TimerKit).

## 0.1.0 — 2026-09-23

- Added TestKit API generation 1, implementation revision 1: in-client test suites for development addons. TestKit is development-only: the manifest declares `"distribution": "development"`, so the bundle builder skips it, and `.pkgmeta` ignores `packages/testKit`.
- **Suites.** `TestKit:Suite(name, options)` with `phase` (`"loaded"` or `"ready"`, default `"ready"`), `addonName` (default: the suite name) and `timeoutSeconds` (default 10); a duplicate name is refused with `nil, "taken"`, a 65th suite with `nil, "full"`. Suite methods `Test`, `Skip`, `Before`, `After` and `GetName`: at most 256 tests and 16 hooks of each kind per suite, `nil, "full"` beyond.
- **Test context.** `Replace` (raw, restored newest first after the After hooks, also after a failure, a timeout or a `Reset`, also for `nil`; secret values and keys refused; at most 256 per test), `Yield`, `WaitFor(eventName, timeoutSeconds)` (EventKit through `Registry:Find`; the first of the event and the timeout decides), `WaitUntil(predicate, timeoutSeconds)`, `Expect`, `Fail` and `Log` (64 lines per test).
- **Matchers** `ToBe`, `ToEqual` (deep, 16 levels, raw access, first differing path reported), `ToBeTruthy`, `ToBeNil`, `ToRaise(pattern)` and `ToBeSecure(table, key)` over `issecurevariable`, each with `Not`. Failure messages describe values by type and at most 64 quoted bytes, describe a secret as `<secret value>`, and point at the test's own line; a comparison a secret makes impossible fails even under `Not`.
- **Runner.** `TestKit:Run(filter)` (every suite, `"suite"` or `"suite/test"`): suites wait for their LifecycleKit phase; tests run one at a time inside one SchedulerKit job, each step in its own coroutine; a test that outlives its limit is abandoned as `"timeout"` and its After hooks run in a window of their own. A suite whose phase can no longer be reached, because the addon halted or shut down before `Run` or while the suite waited, is reported as skipped with the cause, and the run finishes.
- **Results.** `TestKit:Report()`, `TestKit:OnFinished(callback)` (16 callbacks) and `TestKit:Reset()`, which also abandons a run in progress. Facade methods refuse a dot call (`TestKit.Run("MyAddon")`) at the caller instead of shifting their arguments.
- **Upgrades.** The runner job, phase subscriptions, wait callbacks and the deadline timer call through a shared dispatch table, and suites, contexts and matchers keep their metatables, so an in-place upgrade keeps suites, results, a waiting test and a queued suite.
- **Fixture fidelity.** `fidelity/FixtureFidelity.lua` registers the `FixtureFidelity` suite of nine host facts (among them `OnShow` / `OnHide` firing on a change only and the edit focus moving between edit boxes), finding Registry by generation (`MoltenCodes.Registries[2]`) with the alias as fallback; a Busted spec runs the same file against the shared fixture and names the facts the fixture does not model yet (`InCombatLockdown`, `C_Timer.After`).
- 97 specs, including an in-place upgrade spec and a cost spec: loading and registering create no frame, timer or event registration, and a finished run leaves none behind.
