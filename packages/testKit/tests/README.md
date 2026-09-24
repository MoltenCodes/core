# TestKit Tests

The TestKit suite covers:

- `ctx:Replace`: the 256-replacement cap, restoration newest first after a passing test, after a raised error and after a failed expectation, keys that were `nil` and values replaced with `nil`, raw access past `__index`, globals, no leakage into the next test, After hooks seeing the replacement, refused arguments, and a context used after its test;
- hooks: Before, body, After order for every test, a failing Before hook skipping the body while every After hook runs, a failing After hook failing a passing test, the first failure winning, and hooks sharing the test's context;
- results: the `Report` shape and totals over every status, registration order, wall-clock durations, fresh copies on every call, re-runs replacing a result in place, 64 log lines, lines cut at 256 bytes, and suites that never ran left out;
- asynchronous tests: nothing runs inside `Run`, `ctx:Yield`, `WaitFor` success with its payload and timeout (with no `OnUpdate` alive while waiting), the event and the timeout both arriving before the test resumes, in either order, `WaitUntil` polling once per frame, at once and timing out, the per-test time limit (status `timeout`, After hooks and restoration still happening), After hooks with their own window, a raw `coroutine.yield`, `Yield` from a foreign coroutine, and the frame budget between tests;
- matchers: every matcher passing and failing, with and without `Not`, exact failure messages, the key path of a `ToEqual` difference, the 16-level bound on a cycle, metatables ignored, `ToRaise` patterns and non-string errors, `ToBeSecure` against a local `issecurevariable` stub and on a host without it, `ctx:Fail`, and error objects that are not strings;
- secret values, with a local `issecretvalue` stub: no secret in any matcher failure, negation never passing a comparison a secret prevents, secret booleans, secret error objects, `Fail` and `Log` messages, `ToRaise` on a raised secret, `Replace` refusing secret values and keys, secret event payloads passed through untouched, the 64-byte quote limit, secret suite names, and a secret suite phase or limit value refused before it is compared;
- phase gating: a `ready` suite queued until login, a `loaded` suite before login, the suite name as the default addon, suites that run while another waits and a run that finishes only after the last, no double queuing, a halted addon whose suite is skipped at `Run`, an addon that halts or shuts down while its suite waits (skipped, and the run finishes), and the halt watch released once the phase arrived;
- filters: every suite, one suite, one test split at the first `/`, unknown names, malformed filters, and no suites at all;
- bounds: 64 suites, 256 tests (`Skip` included), 16 hooks of each kind, 16 `OnFinished` callbacks, `"taken"` and duplicate test names;
- `Reset` and `OnFinished`: results cleared with suites and callbacks kept, a run in progress abandoned with its replacements restored and no callback called, `Reset` refused inside a test, and a raising callback reported while the others still run;
- the fixture-fidelity suite (`fidelity/FixtureFidelity.lua`) run against the shared fixture, with the known gaps as a ratchet (see below);
- cost: loading and registering create no frame, timer or `OnUpdate`, and a finished run leaves no armed timer, event registration or `OnUpdate` behind;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, LifecycleKit or SchedulerKit, an incomplete facade, and an in-place upgrade that keeps a waiting test and a queued suite, and the upgrades of a revision 1, a revision 2 and a revision 3 copy by the current file;
- `error` levels: facade and suite argument errors, and facade methods called with a dot, report the caller's line, and context errors, matcher errors and matcher failures report the test's own line;
- manifest/runtime API and revision consistency.

| Spec | Covers |
|---|---|
| `Replace_spec.lua` | `ctx:Replace` restoration, raw access, the cap, refusals |
| `Hooks_spec.lua` | Before and After hook order and failures |
| `Report_spec.lua` | the `Report` shape, totals, durations, re-runs, logs |
| `Async_spec.lua` | `Yield`, `WaitFor` (including the timeout race), `WaitUntil`, time limits, the frame budget |
| `Matchers_spec.lua` | every matcher, negation and failure messages |
| `SecretValues_spec.lua` | secret values in matchers, messages, `Replace` and payloads |
| `Phases_spec.lua` | phase gating, halted and shut-down addons |
| `Filter_spec.lua` | `Run` filters |
| `Caps_spec.lua` | the bounds on suites, tests, hooks and callbacks |
| `Reset_spec.lua` | `Reset` mid-run and `OnFinished` |
| `FixtureFidelity_spec.lua` | the fixture-fidelity suite against the shared fixture |
| `Cost_spec.lua` | no frame, timer or `OnUpdate` from loading, registering or a finished run |
| `ErrorLevels_spec.lua` | argument errors at the caller's line, dot calls on the facade |
| `Bootstrap_spec.lua` | publication, dependencies, duplicate loads, upgrades |
| `Limits_spec.lua` | `SetLimits` / `GetLimits`, `UNBOUNDED`, each limit opened, the `maxEqualDepth` ceiling, atomic validation, limits kept across `Reset` |
| `Manifest_spec.lua` | manifest and runtime consistency |

`support/TestKitTestEnv.lua` adds what only these specs need on top of the shared fixture. `Frame(ms)` renders one frame the way the runner experiences it: both clocks advance, every native timer that is due fires (the fixture records a timer's delay but not its creation time, so the helper notes the clock the first time it sees each timer), then every `OnUpdate` handler runs once. `RenderFrames`, `FramesUntil`, `RunToEnd` and `RunOne` drive whole runs; `RunToEnd` installs one `OnFinished` callback per facade so repeated runs do not spend the facade's sixteen slots. `SetGlobal` installs host globals the fixture does not own (`issecurevariable`) and `Reset` removes them.

## The fixture-fidelity spec

`FixtureFidelity_spec.lua` loads `fidelity/FixtureFidelity.lua` exactly as the client loads an addon file — with the addon name as the first vararg, before that addon's `ADDON_LOADED` — and runs the same suite a developer runs in the client. **The two environments must agree.** Two facts the client has are not modelled by the shared fixture yet, and the spec names them in `KNOWN_FIXTURE_GAPS`:

- `InCombatLockdown` — only `LifecycleKitTestEnv` stubs it, not `AddonStub`;
- `C_Timer.After` — `TimerStub` models `C_Timer.NewTimer` and `C_Timer.NewTicker` only.

The spec requires those tests to fail against the fixture and every other test to pass. When the fixture learns one of the facts, the spec fails until its entry is removed, so the list never goes stale.

EventKit and TimerKit are not TestKit dependencies but are in the closures of LifecycleKit and SchedulerKit, so the runner already puts them on `LUA_PATH`.
