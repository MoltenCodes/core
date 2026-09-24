# Changelog

## 0.1.6 — 2026-09-24

- Secret values: INTERNALS.md (*Secret values*) and the source comments on `Suite` options and `SetLimits` no longer claim that comparing a secret with anything, `nil` included, raises, or that a raw identity test is safe whatever the other side. They state what was measured on Retail 12.1.0 b69933 (2026-09-24): a secret compared with a value of its own type raises (`==`, `~=`, `<`, `<=` and `rawequal` alike) and a secret used as a table key raises, while a comparison with `nil` or with a value of another type answers without raising. The `type(value) == "nil"` rule stays, as the repository's uniform rule that never compares anything. Comments and documentation only: `luac -s -l` gives the same instruction listing before and after, so the implementation revision is unchanged.

## 0.1.5 — 2026-09-24

- Annotation: the `TestKit.Context` field `WaitUntil` wrote its predicate as `fun(): any` inside the outer function type, where the language server reads the inner return list greedily and took `timeoutSeconds` for a second return of the predicate. The predicate type is now parenthesised, `(fun(): any)`. The other `fun(...)` fields of `TestKit.Context`, `TestKit.Suite` and `TestKit.Matcher` have no nested function type followed by a parameter and are unchanged. The compiled listing is identical, so implementation revision 4 is unchanged.

## 0.1.4 — 2026-09-24

- Fixed: the remaining tests for absence on values that did not originate in TestKit compared them with `nil`; they now use `type(value) == "nil"`, as the 0.1.3 fixes already did for `Suite`, `Run`, `Skip`, `ctx:Fail` and the optional `ToRaise` pattern check. This covers the `options` of `Suite`, the `pattern` branches inside `ToRaise`, the `target` of `ToBeSecure`, the key walk and the copied values of `SetLimits`, and the key lookup of `ToEqual` in the table under test. No argument is newly refused.
- Implementation revision 4. No state changed: an in-place upgrade from revision 2 or 3 keeps the suites, results, the limits and the sentinel, a waiting test and a queued suite, and replaces the methods only; the upgrade from revision 1 still seeds the limits.
- Specs: a new bootstrap spec upgrades a revision 3 copy with the current file. 109 specs.
- `TestKit` API generation 1 is unchanged.

## 0.1.3 — 2026-09-24

- Fixed: arguments that may be secret were compared before a secret check, which raises on the client. `Suite` compared `options.phase` with its two words, `SetLimits` compared each value with `TestKit.UNBOUNDED` and its bounds, and `Suite`, `Run`, `Skip`, `ctx:Fail`, `ToRaise` and `ToBeSecure` compared optional arguments with `nil`; `ctx:Fail(secret)` in particular raised a host error instead of failing the test with `<secret value>`. A secret `phase` or limit value is now refused at the caller (`TestKit:Suite phase must not be a secret value`, `TestKit:SetLimits limits.<name> must not be a secret value`), and absent arguments are told apart with `type`.
- Fixed: `SetLimits` named an unknown key with `tostring`, running a table key's `__tostring`; such a key is now named by its type (`limits.<table>`).
- Documentation: `docs/API.md` stated implementation revision 1 while the code was revision 2; it now states 3. The report is ordered by each test's first result since the last `Reset`, which API.md described as registration order; the text now says so. The README and API.md reach TestKit through `MoltenCodes.Registries[2]`, as the fidelity file does, and the README footprint no longer narrates an older release. The report example in API.md is an assignment, so it compiles. INTERNALS.md lists the `unbounded` and `limits` state fields and names the limits where it quoted the default numbers.
- Implementation revision 3. No state changed: an in-place upgrade from revision 2 keeps the suites, results, the limits and the sentinel, a waiting test and a queued suite, and replaces the methods only; the upgrade from revision 1 still seeds the limits.
- Specs: a new bootstrap spec upgrades a revision 2 copy with the current file; `SecretValues_spec.lua` covers the secret phase and limit values; `Limits_spec.lua` covers a table key with a `__tostring` metamethod. 108 specs.
- `TestKit` API generation 1 is unchanged.

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
