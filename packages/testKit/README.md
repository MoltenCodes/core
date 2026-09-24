# TestKit

TestKit runs test suites **inside the World of Warcraft client**. It is a development-only package: it belongs in a development addon you load while working on the framework or on your own addon, never in a release.

The framework's Busted specs prove logic against a fake client. Some facts only the real client can prove:

- real event order and payload shapes;
- combat lockdown;
- taint: whether a Blizzard variable is still secure after our code ran (`issecurevariable`);
- whether the fake client used by the Busted specs tells the truth.

TestKit is the small harness for those. It does not replace Busted: logic that can be tested outside the client belongs in a spec.

```lua
local TestKit = MoltenCodes.Registries[2]:Get("testKit", 1)

-- Waits for MyAddon's "ready" phase (loaded and logged in) by default.
local suite = TestKit:Suite("MyAddon")

suite:Test("the bag index rebuilds on BAG_UPDATE_DELAYED", function(ctx)
    local rebuilt = false
    ctx:Replace(MyAddon, "Rebuild", function()
        rebuilt = true
    end)
    local fired = ctx:WaitFor("BAG_UPDATE_DELAYED", 5)
    ctx:Expect(fired):ToBe(true)
    ctx:Expect(rebuilt):ToBe(true)
end)

suite:Test("our tooltip hook leaves GameTooltip secure", function(ctx)
    ctx:Expect(nil):ToBeSecure(nil, "GameTooltip")
end)

TestKit:OnFinished(function(report)
    print(("%d passed, %d failed"):format(report.totals.passed, report.totals.failed))
end)
```

```text
/run MoltenCodes.Registries[2]:Get("testKit", 1):Run()
/run MoltenCodes.Registries[2]:Get("testKit", 1):Run("MyAddon/our tooltip hook leaves GameTooltip secure")
```

What each piece promises:

- **Suites wait for a LifecycleKit phase.** `options.phase` is `"loaded"` or `"ready"` (the default) of the addon `options.addonName` (default: the suite's own name). `Run` queues a suite whose phase has not been reached and runs it when it is.
- **Tests run one at a time inside a SchedulerKit job**, each step in its own coroutine, so `ctx:Yield()`, `ctx:WaitFor(event, seconds)` and `ctx:WaitUntil(predicate, seconds)` suspend the test without holding the frame, and the frame budget is honoured between tests.
- **Save-and-restore mocking.** `ctx:Replace(table, key, value)` is undone after the test, in reverse order, also after a failure or a timeout, also for `nil` values. A secret value is refused.
- **Expectations that never print a secret.** `ctx:Expect(value)` offers `ToBe`, `ToEqual` (deep, 16 levels), `ToBeTruthy`, `ToBeNil`, `ToRaise(pattern)`, `ToBeSecure(table, key)` and `Not`. Failures describe values by type and at most 64 quoted bytes, and point at the test's own line.
- **Structured results.** `TestKit:Report()` returns `{ suites = { { name, tests = { { name, status, message, durationMs, logs } } } }, totals }`, ready for a slash command to dump and compare with a Busted run.
- **Bounded by default, opened on purpose.** 64 suites, 256 tests per suite, 16 Before and 16 After hooks per suite, 256 replacements and 64 log lines per test, 16 `OnFinished` callbacks, `ToEqual` 16 levels deep; beyond each, `nil, "full"` (or `false` from `Log`). `TestKit:SetLimits` raises any of them, and every one but the `ToEqual` depth accepts `TestKit.UNBOUNDED`; see [Limits](docs/API.md#limits).
- **No run hangs on a dead addon.** A suite whose addon halts or shuts down before its phase is reported as skipped and the run finishes.

See [`docs/API.md`](docs/API.md) for the complete contract and [`docs/INTERNALS.md`](docs/INTERNALS.md) for the runner's state machine.

## When to write an in-client test

Write one when the thing under test is the host itself, or our assumptions about it:

- an event's payload or its order relative to another event;
- behaviour in combat lockdown (`InCombatLockdown()`, `LifecycleKit:IsInCombat()`, protected frames);
- taint: `issecurevariable` on a Blizzard global or field after a hook or a write;
- a fact the shared test fixture models: add it to the fixture-fidelity suite (below) instead of to your own.

Everything else — branching, bounds, error paths, state machines — belongs in a Busted spec, where it runs on every change and in CI.

## The fixture-fidelity suite

[`fidelity/FixtureFidelity.lua`](fidelity/FixtureFidelity.lua) registers the suite `FixtureFidelity`: a handful of host facts the shared Busted fixture (`tests/support/FrameworkTestEnv.lua`) models, such as the `ADDON_LOADED` payload, `InCombatLockdown()` answering a boolean, `C_Timer.After` existing, `OnShow` / `OnHide` firing on a change only, and the edit focus moving between edit boxes with its scripts. The same file runs in both environments:

- in the client, listed in a development addon's `.toc` after `TestKit.lua` (see the load order below), with `/run MoltenCodes.Registries[2]:Get("testKit", 1):Run("FixtureFidelity")`;
- under Busted, through [`tests/FixtureFidelity_spec.lua`](tests/FixtureFidelity_spec.lua), which loads the file into the fixture and runs the same suite.

**The two must agree.** A fidelity test that passes in the client and fails against the fixture is a fixture defect; the spec names the facts the fixture does not model yet, and fails as soon as one of them starts passing so the list stays true. A fidelity test that fails in the client means the framework assumes something about the host that is wrong.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a **development** addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua
Libs\MoltenCodes\lifecycleKit\LifecycleKit.lua
Libs\MoltenCodes\timerKit\TimerKit.lua
Libs\MoltenCodes\schedulerKit\SchedulerKit.lua
Libs\MoltenCodes\testKit\TestKit.lua
Libs\MoltenCodes\testKit\FixtureFidelity.lua
```

Minimum footprint: Embed 7 files: Registry, SignalKit, EventKit, LifecycleKit,
TimerKit, SchedulerKit, TestKit (plus the optional `FixtureFidelity.lua`).
TimerKit and SchedulerKit do not require LifecycleKit, so the two may load
before or after it; the list above is one valid order.

Direct runtime dependencies: Registry API 2, LifecycleKit API 1, SchedulerKit
API 1. EventKit and TimerKit are already in their closures; TestKit finds them
through `Registry:Find` when it first needs them. Every file above except the
last is required; omitting one makes TestKit raise at load. The last line is
optional: copy `fidelity/FixtureFidelity.lua` next to `TestKit.lua` only when
you want the fixture-fidelity suite.

**Development only.** Keep TestKit out of anything you ship:

- list it in a separate development addon (for example `MyAddon_Tests`, with
  `## Dependencies: MyAddon`), never in your release addon's `.toc`;
- if you pull the framework in with the packager, add `testKit` to your own
  `.pkgmeta` `ignore:` list, as the framework's own `.pkgmeta` does (its
  manifest declares `"distribution": "development"`, so the framework's
  bundle builder never includes it);
- nothing in a release addon may call `Registry:Get("testKit", 1)`: in a
  release it answers `nil`.

TestKit costs nothing until it is used: loading it and registering suites
creates no frame, timer or event registration, and a finished run leaves none
behind.
