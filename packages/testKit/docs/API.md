# TestKit API

TestKit API generation **1** runs test suites inside the World of Warcraft client: suites registered against LifecycleKit phases, tests run one at a time inside a SchedulerKit job, save-and-restore mocking, asynchronous waits, secret-safe expectations and structured results.

Implementation revision: **4**.

TestKit is **development-only**. It belongs in a development addon and never in a release bundle; see the README's "Embedding" section.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
EventKit.lua
LifecycleKit.lua
TimerKit.lua
SchedulerKit.lua
TestKit.lua
FixtureFidelity.lua   (optional: the fixture-fidelity suite)
```

TestKit depends directly on Registry API 2, LifecycleKit API 1 and SchedulerKit API 1. Portable code resolves it through Registry:

```lua
local TestKit = MoltenCodes.Registries[2]:Get("testKit", 1)
```

Loading it without Registry raises `MoltenCodes TestKit requires Registry API 2 to be loaded first`; without LifecycleKit or SchedulerKit, `MoltenCodes TestKit requires LifecycleKit API 1 to be loaded first` or `... SchedulerKit API 1 ...`.

### Packages and host facilities found at call time

| Facility | Used by | Without it |
|---|---|---|
| TimerKit API 1, through `Registry:Find` | `Run` (the per-test time limit), `WaitFor` and `WaitUntil` timeouts | `Run` raises at the caller: `TestKit:Run requires TimerKit API 1, which is not loaded (absent)`. SchedulerKit requires TimerKit, so this happens only with a retired or foreign copy. |
| EventKit API 1, through `Registry:Find` | `ctx:WaitFor` | `WaitFor` raises inside the test, which fails it. LifecycleKit requires EventKit, so this, too, is theoretical. |
| `issecretvalue` | every description of a value, `Replace`, name arguments | Nothing is treated as secret. |
| `issecurevariable` | `ToBeSecure` | `ToBeSecure` fails, even under `Not`: `issecurevariable is not available on this host`. |
| `GetTimePreciseSec` | `durationMs` | `durationMs` is `0`. |
| `geterrorhandler` | an `OnFinished` callback that raises | The error is printed. |

The host functions are read when they are used, not once at load, so a test can replace one with `ctx:Replace`.

## Public surface

Package facade:

| Method | Purpose |
|---|---|
| `Suite(name, options?)` | Register a suite; returns it, or `nil, "taken"` / `nil, "full"`. |
| `Run(filter?)` | Queue every suite, one suite, or one test; returns how many suites were queued, or `nil, "unknown"`. |
| `Report()` | The structured results of every test that ran since the last `Reset`. Allocates. |
| `OnFinished(callback)` | Call `callback(report)` when a run has nothing left to do; `true` or `nil, "full"`. |
| `Reset()` | Abandon a run in progress and clear every result; returns `true`. |
| `SetLimits(limits)` / `GetLimits()` | Change or read the package-wide limits. See [Limits](#limits). |
| `UNBOUNDED` | Sentinel a limit takes to be lifted. |

Suites:

| Method | Purpose |
|---|---|
| `Test(name, fn)` | Register a test; `true` or `nil, "full"`. |
| `Skip(name, reason?)` | Register a test that is always reported as skipped; `true` or `nil, "full"`. |
| `Before(fn)` | Run `fn(ctx)` before every test of the suite; `true` or `nil, "full"`. |
| `After(fn)` | Run `fn(ctx)` after every test of the suite, whatever its outcome; `true` or `nil, "full"`. |
| `GetName()` | The suite name. |

Test context, passed to every test body and hook:

| Method | Purpose |
|---|---|
| `Replace(table, key, value)` | Replace `table[key]` until the test ends; returns the previous value, or `nil, "full"` past `maxReplacements` (256) in one test. |
| `Yield()` | Suspend the test until the runner job's next resume. |
| `WaitFor(eventName, timeoutSeconds)` | `true, ...payload` when the event fires, or `false, "timeout"`. |
| `WaitUntil(predicate, timeoutSeconds)` | `true` once `predicate()` is truthy (polled once per frame), or `false, "timeout"`. |
| `Expect(actual)` | A matcher about `actual`. |
| `Fail(message?)` | Fail the test now. |
| `Log(message)` | Keep one line with the test's result; `false` once `maxLogLines` (64) lines are kept. |

Matchers, each also on `matcher.Not`:

| Method | Passes when |
|---|---|
| `ToBe(expected)` | `actual` is `expected` itself: raw equality, no `__eq` metamethod. |
| `ToEqual(expected)` | the values are structurally equal, tables compared key by key with raw access, at most `maxEqualDepth` (16) levels deep. |
| `ToBeTruthy()` | `actual` is neither `nil` nor `false`. |
| `ToBeNil()` | `actual` is `nil`. |
| `ToRaise(pattern?)` | `actual`, a function, raises when called with no arguments; with `pattern`, raises a string that matches the Lua pattern. |
| `ToBeSecure(table, key)` | `issecurevariable(table, key)` (or `issecurevariable(key)` when `table` is `nil`) answers secure. The value given to `Expect` is not used: write `ctx:Expect(nil):ToBeSecure(...)`. |

## `TestKit:Suite(name, options?)`

```lua
local suite = TestKit:Suite("MyAddon.Combat", {
    phase = "ready",
    addonName = "MyAddon",
    timeoutSeconds = 20,
})
```

`name` is a non-empty string without `/` (the filter separator). Options:

| Option | Default | Meaning |
|---|---|---|
| `phase` | `"ready"` | The LifecycleKit phase the suite waits for: `"loaded"` (the addon's `ADDON_LOADED` was seen) or `"ready"` (loaded and logged in). |
| `addonName` | the suite name | The addon whose `LifecycleKit:ForAddon(addonName)` instance the suite waits on. Matched exactly, like LifecycleKit. |
| `timeoutSeconds` | `10` | How long one test's Before hooks and body may take before it is abandoned as `"timeout"`, and separately how long its After hooks may take. A finite number greater than zero. |

Unknown option fields are refused; with several, the message names the alphabetically first. A secret `phase` is refused before it is compared (`TestKit:Suite phase must not be a secret value`).

Suites live in TestKit's shared state for the session. A name already registered is refused with `nil, "taken"`, and a suite past `maxSuites` (64) with `nil, "full"`; prefix suite names with your addon's name. Nothing is ever unregistered: `/reload` starts over.

A suite whose `addonName` never loads waits for ever, and so does the run; `Reset` abandons it. A suite whose addon halts or shuts down while it waits does not: it is recorded as skipped and the run goes on (see `Run`).

## Tests and hooks

`suite:Test(name, fn)` registers `fn(ctx)`. Test names are non-empty strings, unique within the suite (a duplicate raises at the caller), and may contain `/`. `suite:Skip(name, reason)` registers a test that is reported as `"skipped"` with `reason` (default `"skipped"`) whenever the suite runs. Together they are bounded at `maxTests` (256) per suite.

`Before(fn)` and `After(fn)` add hooks, at most `maxHooks` (16) of each per suite. For every test the runner executes, in order:

1. every Before hook, in registration order;
2. the test body;
3. every After hook, in registration order.

Each step runs in its own coroutine and receives the same `ctx`. A failing Before hook skips the remaining Before hooks and the body; a failing body skips nothing but itself. After hooks always run, each one even when an earlier one failed, as long as their time window lasts (see below). The **first** failure decides the result: a failing After hook does not hide why the body failed, and fails a test that had passed.

### Outcomes

| Status | When |
|---|---|
| `"passed"` | Every step returned. |
| `"failed"` | A step raised: a failed expectation, `ctx:Fail`, or any other error. The message is the error, cut to 256 bytes; a secret is `<secret value>`, anything but a string `error object: <description>`. |
| `"timeout"` | The Before hooks and body did not finish within `timeoutSeconds`. |
| `"skipped"` | Registered with `Skip`, or its suite's phase can no longer be reached. |

A test that outlives its limit is abandoned: its coroutine is dropped where it is suspended, and its After hooks run next with a fresh window of `timeoutSeconds`. After hooks share that second window: the hook that outlives it is abandoned and fails the test (`an After hook did not finish within N seconds`), and the After hooks registered after it are not started. Only a suspended test can time out: Lua cannot interrupt a step that never yields.

## The test context

A context is valid only while its test runs; using one afterwards raises `TestKit.Context:<Method> was called after its test finished`.

### `ctx:Replace(table, key, value)`

Writes `value` to `table[key]` and records what was there. The read and the write are raw (`rawget`, `rawset`), so a method that was reachable only through `__index` comes back to being reachable only through `__index`. Returns the previous raw value.

Every replacement is undone when the test ends — after the After hooks, whatever the outcome, also after a timeout and when `Reset` abandons the test — **newest first**, so replacing the same key twice restores the original. `nil` is a value like any other: replacing a missing key with something removes it again, and replacing a present key with `nil` puts it back.

`table` must be a table and `key` must not be `nil` or NaN. A secret `value` or `key` is refused. Replacing a global is `ctx:Replace(_G, "Name", value)`.

A test holds at most `maxReplacements` (**256** by default) replacements. Past that nothing is written and `Replace` returns `nil, "full"`; since a previous value may itself be `nil`, check the second value.

### `ctx:Yield()`

Suspends the test. The runner job yields to SchedulerKit, which resumes it on a later pass under its frame budget, possibly in the same rendered frame. Must be called from the test's (or hook's) own function, not from a coroutine of its own; and like every SchedulerKit yield it cannot cross `pcall`, a metamethod or an iterator function — Lua 5.1 raises `attempt to yield across metamethod/C-call boundary`.

Calling `coroutine.yield` directly fails the test (`the test called coroutine.yield; use ctx:Yield()`).

### `ctx:WaitFor(eventName, timeoutSeconds)`

```lua
local fired, unit = ctx:WaitFor("UNIT_AURA", 2)
if not fired then
    ctx:Fail("no UNIT_AURA within two seconds")
end
```

Connects once to `eventName` through a Kit-owned EventKit scope and starts a one-shot timer of `timeoutSeconds` in a Kit-owned TimerKit scope. Returns `true` and the event's payload (without the event name, `nil`s and secrets included, untouched) when the event fires first, or `false, "timeout"`. Whichever comes second is disconnected or cancelled.

While the test waits, the runner job **ends**: no job is queued and no `OnUpdate` runs on TestKit's behalf. The event or the timer schedules a new job.

`eventName` is a non-empty string and `timeoutSeconds` a finite number greater than zero. A timeout is not a failure; assert on the result.

### `ctx:WaitUntil(predicate, timeoutSeconds)`

Calls `predicate()` at once; when it is truthy, returns `true` without suspending. Otherwise the test is resumed once per rendered frame (through `SchedulerKit` `NextFrame`) and `predicate()` asked again, until it is truthy (`true`) or `timeoutSeconds` pass on TimerKit (`false, "timeout"`). A predicate that raises fails the test.

### `ctx:Expect(actual)`, `ctx:Fail(message?)`, `ctx:Log(message)`

`Expect` returns a matcher; see below. `Fail` raises `message` at the test's line (default `"failed"`); a string is cut to 256 bytes and anything else is described safely. `Log` keeps `message` the same way, up to `maxLogLines` (64) lines per test, and returns `false` without keeping it after that.

## Matchers

A matcher that holds returns `true`. One that does not raises at the line of the test that called it:

```text
MyAddon_Tests/Combat.lua:42: expected number 1 to be number 2
MyAddon_Tests/Combat.lua:43: expected table to equal table (at .items[2].name: string "b" where string "c" was expected)
MyAddon_Tests/Combat.lua:44: expected function to raise an error matching "code" (it returned normally)
MyAddon_Tests/Combat.lua:45: expected field "Show" to be secure (tainted by string "MyAddon")
```

`matcher.Not` negates: `ctx:Expect(value).Not:ToBeNil()`. Its failures read `expected ... not to ...`.

### Safe descriptions

A failure message never prints a secret and never quotes a long string:

| Value | Described as |
|---|---|
| a secret (`issecretvalue`) | `<secret value>` |
| `nil`, a boolean, a number | `nil`, `boolean true`, `number 42` |
| a string | `string "..."`, at most 64 bytes, then `... (N bytes)`; control characters escaped |
| a table, function, userdata, thread | its type alone; `tostring` is never called, so no `__tostring` runs |

A comparison that a secret makes impossible — `ToBe` or `ToEqual` with a secret anywhere, `ToBeTruthy` on a secret boolean, `ToRaise` with a pattern when the function raised a secret — **fails even under `Not`**, with `expected <secret value>: a secret value cannot be compared`: negation must not turn "could not look" into a pass. A secret of another type is truthy and not `nil`, because its type is not secret.

`ToEqual` stops at `maxEqualDepth` levels, 16 by default (`tables nested deeper than 16 levels`), which also ends a cyclic structure. `ToRaise` calls the function with no arguments under `pcall`; without a pattern any error passes, including `nil` and `false`. `ToRaise` on something that is not a function fails even under `Not`.

## `TestKit:Run(filter?)`

| `filter` | Runs |
|---|---|
| `nil` | every suite, in registration order |
| `"MyAddon"` | every test of that suite |
| `"MyAddon/the bag index rebuilds"` | that test (and its suite's hooks); the name is split at the first `/` |

Returns the number of suites it queued. A suite that is already waiting, queued or running is left as it is (with the filter it was queued with) and not counted, so `Run()` during a run adds only what is not already in it. A filter naming a suite or test that does not exist returns `nil, "unknown"` and starts nothing. `"/x"`, `"x/"` and non-strings raise at the caller.

For each selected suite, `Run` subscribes to its phase with `LifecycleKit:ForAddon(addonName):OnLoaded` or `:OnReady`. A phase already reached queues the suite at once (LifecycleKit replays); otherwise it is queued when the phase arrives. A phase that can no longer be reached records the selected tests as `"skipped"` with `the ready phase of "MyAddon" can no longer be reached (halted)` or `(shutdown)`. That is decided when `Run` subscribes (the addon already halted or shut down) and again while the suite waits: LifecycleKit disconnects a pending phase subscription without calling it when the addon halts or shuts down, so a waiting suite also watches the instance's `OnHalted` and `OnShutdown`, and the run goes on. The watches are released once the phase arrives.

Tests never run inside `Run`. One SchedulerKit job at a time (`name = "TestKit runner"`, in a Kit-owned scope) takes suites off the queue in the order their phases arrived and runs their tests one at a time. Between tests it yields when `ShouldYield()` says the frame budget is spent.

A run **finishes** when nothing is running, queued or waiting for a phase; then every `OnFinished` callback is called once with a fresh report. A suite waiting for a phase that never comes keeps the run open.

## `TestKit:Report()`

```lua
local report = {
    suites = {
        {
            name = "MyAddon",
            phase = "ready",
            addonName = "MyAddon",
            tests = {
                { name = "rebuilds", status = "passed", message = nil, durationMs = 3.2, logs = {} },
                { name = "secure",   status = "failed", message = "Tests.lua:31: expected ...", durationMs = 0.4, logs = { "..." } },
            },
        },
    },
    totals = { suites = 1, tests = 2, passed = 1, failed = 1, skipped = 0, timeout = 0 },
}
```

Every suite with at least one result appears, in registration order. Within a suite, tests appear in the order they first produced a result since the last `Reset`, which is registration order when the suite ran whole; running a test again replaces its result in place. `durationMs` is wall-clock time on `GetTimePreciseSec` from the first Before hook to the end of the last After hook, suspensions included.

`Report` **allocates**: every call builds new tables, so the caller may keep, change or serialise the result. Call it from a slash command or an `OnFinished` callback, not every frame.

## `TestKit:OnFinished(callback)` and `TestKit:Reset()`

`OnFinished` registers `callback(report)` for every run that finishes, at most `maxFinishedCallbacks` (16) callbacks for the session (`nil, "full"` beyond). Each callback runs protected: one that raises is reported through `geterrorhandler()` (or printed) and the others still run.

`Reset` clears every result. When a run is in progress it is **abandoned** first: suites waiting for a phase are unsubscribed, queued suites dropped, the active test's replacements restored and its waits released, the runner job cancelled, and no `OnFinished` callback is called. Suites and `OnFinished` callbacks stay registered. `Reset` raises when called from inside a test or hook (`TestKit:Reset cannot be called from inside a running test`).

## The fixture-fidelity suite

`fidelity/FixtureFidelity.lua` is an addon file, loaded with the addon's name as its first vararg before that addon's `ADDON_LOADED`. It registers the suite `FixtureFidelity` with `phase = "loaded"` for that addon, and returns it. Its tests assert host facts the shared Busted fixture models:

| Test | Fact |
|---|---|
| `ADDON_LOADED carries the addon folder name first` | The event's first payload value is the addon's folder name. |
| `InCombatLockdown returns a boolean` | `InCombatLockdown()` exists and answers a boolean. |
| `IsLoggedIn returns a boolean` | `IsLoggedIn()` exists and answers a boolean. |
| `C_Timer.After exists` | `C_Timer.After` is a function. |
| `C_Timer.NewTimer and C_Timer.NewTicker exist` | Both constructors are functions. |
| `GetTimePreciseSec returns a number` | The wall clock exists and answers a number. |
| `Show and Hide fire OnShow and OnHide on a change only` | Hiding or showing a frame without a parent runs its `OnHide` or `OnShow` once; hiding a hidden frame or showing a shown one runs nothing. |
| `SetFocus moves the edit focus from one edit box to another` | Focusing a second edit box runs the first box's `OnEditFocusLost`, then the second's `OnEditFocusGained`; `ClearFocus` on a box without the focus runs nothing. |
| `issecurevariable reports a Blizzard global as secure` | `issecurevariable("CreateFrame")` answers secure; on a host without `issecurevariable` the test logs that and passes. |

`tests/FixtureFidelity_spec.lua` loads the same file into the fixture and runs the same suite. **The two environments must agree.** The spec lists by name the facts the fixture does not model yet (today `InCombatLockdown` and `C_Timer.After`) and requires them to fail there; every other test must pass. When the fixture learns one of them the spec fails until the entry is removed.

## Limits

Every bound TestKit keeps is a default the consumer can open (design
constitution, principle 4a). TestKit is development-only and what it retains is
the consumer's own tests, so every limit but one accepts `TestKit.UNBOUNDED`:

| Limit | Default | `UNBOUNDED` | Guards |
|---|---|---|---|
| `maxSuites` | 64 | accepted | suites for the session |
| `maxTests` | 256 | accepted | tests (`Test` and `Skip`) per suite |
| `maxHooks` | 16 | accepted | Before hooks, and separately After hooks, per suite |
| `maxLogLines` | 64 | accepted | `ctx:Log` lines per test |
| `maxFinishedCallbacks` | 16 | accepted | `OnFinished` callbacks |
| `maxReplacements` | 256 | accepted | `ctx:Replace` calls per test |
| `maxEqualDepth` | 16, at most 64 | refused: `ToEqual` recurses once per level | table nesting `ToEqual` compares |

```lua
TestKit:SetLimits({ maxTests = TestKit.UNBOUNDED, maxEqualDepth = 32 })
local limits = TestKit:GetLimits()
```

`SetLimits` changes any subset, validates the whole table at the caller's line
before applying any of it, and must be called on the facade. A secret value is
refused before it is compared (`TestKit:SetLimits limits.<name> must not be a
secret value`), and an unknown key that is not a string, number or boolean is
named by its type (`limits.<table>`), so no `__tostring` runs. `GetLimits`
returns a fresh table. Lowering a limit removes nothing already registered;
further registrations answer `nil, "full"` (or `false` from `Log`). `Reset`
keeps the limits. The limits and the sentinel live in shared state, so every
embedded copy sees the same values; revision-1 state is seeded with the
defaults above, and revisions 3 and 4 keep the revision 2 state as it is.

## Error behaviour

Argument failures report the line that called the public method, never a line inside TestKit; inside a test that line is the test's own, and the error fails the test. Messages name the method (`TestKit:Suite`, `TestKit.Suite:Test`, `TestKit.Context:WaitFor`, `TestKit.Matcher:ToBe`). A method called on the wrong receiver raises `TestKit.Suite:Test must be called on a TestKit suite`; a facade method called with a dot, such as `TestKit.Run("MyAddon")`, raises `TestKit:Run must be called on the TestKit facade` instead of shifting its arguments.

## Performance

TestKit is a development tool and its budget is "nothing unless it is used". Loading it and registering suites creates no frame, timer, event registration or job. A run costs one SchedulerKit job at a time, one coroutine per test step, a few tables per test and one TimerKit timer per test; a finished run leaves no timer, connection or `OnUpdate` handler behind. A test in `WaitFor` keeps no job queued; one in `WaitUntil` queues one job per rendered frame. `Report` allocates the whole report.

## Embedded copies and upgrades

Several development addons may embed TestKit; Registry selects the newest compatible revision and every copy shares one facade, one set of suites and one run. An upgrade happens in place: suites, results, `OnFinished` callbacks, a queued or waiting suite and a suspended test survive, and the runner job, phase subscriptions, wait callbacks and the deadline timer an older copy created run the newer implementation. Nothing survives `/reload`.

## Deviations

Against the package plan in `docs/ROADMAP.md` ("Package D planned Kits — the nine points", testKit):

1. **Excluded from release bundles by the manifest and by `.pkgmeta`.** Point 1 says "excluded from release bundles by `.pkgmeta`". A `.pkgmeta` line alone would keep TestKit out of what the packager uploads while `python3 -m tooling.package.build --all` still bundled it, so the two artifacts would disagree. The manifest therefore declares `"distribution": "development"` (see `docs/PACKAGE_MANIFEST.md`, "Distribution"): the builder skips the package in `--all` builds and lists it under `skipped`, refuses it with `--package`, the validator refuses a release package that depends on it, and repository validation requires the `- packages/testKit` line under `.pkgmeta` `ignore:`, which is present. TestKit is still tested and linted like any package.
2. **The fixture-fidelity suite lives in `fidelity/`, not `tests/`.** Point 4 says the suite is "shipped in `tests/`". `tests/` is Busted's directory: every file there is loaded as a spec or a spec helper, is linted with Busted's globals, and is never copied into a bundle. The fidelity suite is an addon file that runs in the client, so it has its own directory beside `src/`; its Busted counterpart is `tests/FixtureFidelity_spec.lua`.
3. **Suite options `addonName` and `timeoutSeconds`.** Point 4 names `{ phase }` only. A phase belongs to one addon, so the suite has to name it (defaulting to the suite name keeps the plan's one-option form working), and the `"timeout"` status needs a limit to measure against.
4. **`ToBeSecure(table, key)` ignores the value given to `Expect`.** `issecurevariable` asks about a variable, not a value; `ctx:Expect(nil):ToBeSecure(nil, "CreateFrame")` keeps the one matcher vocabulary.
5. **Bounds the plan does not name**: 16 Before and 16 After hooks per suite, 256 replacements and 64 log lines per test, 16 `OnFinished` callbacks, `nil, "taken"` for a duplicate suite name. Every retention structure is bounded by default and can be opened through `SetLimits` (see [Limits](#limits)).
6. **EventKit and TimerKit are found, not declared.** Point 3 lists Registry, LifecycleKit and SchedulerKit. `WaitFor` and the timeouts need EventKit and TimerKit, which are in those packages' closures; they are found with `Registry:Find` when first needed rather than added as edges.
7. **`Reset` abandons a run in progress** instead of refusing, so a suite waiting for a phase that never comes can always be cleared.
