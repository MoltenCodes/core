# Changelog

## 0.1.8 — 2026-11-15

- Fixed: `Gate` named an unknown option field by passing the caller's key to `tostring`. `tostring` on a table or userdata runs its `__tostring`, foreign code that could raise (or answer a secret on Retail) inside ReadinessKit, so the caller saw that error instead of the real refusal. A string key is still shown as written and a number or boolean through `tostring`, which runs no foreign code, so `unknown field "aaa"` is unchanged; any other key is named by its type: `ReadinessKit:Gate options contains unknown field "<table>"`. Documented in `docs/API.md`.
- Implementation revision 5. No state or gate layout changed: an upgrade over revision 4 replaces the methods and keeps every gate, waiter, poll timer and subscription.
- Specs: a table option field whose `__tostring` raises is named by its type at the caller's line and its `__tostring` never runs (`ErrorLevels_spec.lua`); the previous-revision upgrade spec checks the new message on the upgraded facade. 100 → 101 specs.

## 0.1.7 — 2026-11-15

- `docs/API.md` now gives the message of every refusal it described only in words: the `Gate` option values (`intervalSeconds`, `timeoutSeconds`, `maxWaiters`), an `options` that is not a table and an unknown option field (`options contains unknown field "<name>"`), a bad `name` or `probe`, a callback that is not a function, a waiter method called on something that is not a waiter, `Await`, `Probe`, `Invalidate` and `ReprobeOn` on a closed gate, the two `WhenAll` refusals, and the load-time errors for a Registry without `Bootstrap` and a corrupted package state.
- The README said SignalKit and EventKit must load before ReadinessKit for `ReprobeOn`. ReadinessKit looks EventKit up when `ReprobeOn` is called, so they only have to load before that call; the README now says so, as `docs/API.md` already did.
- Documentation only: implementation revision 4 is unchanged.

## 0.1.6 — 2026-11-15

- Documentation: `docs/API.md` states implementation revision 4 in its header (it still read 3), and its "Performance" row for a poll tick on a gate that is not ready counts two clock reads, one to timestamp the negative answer and one to measure the timeout, or one when `timeoutSeconds` is `false` (it said one). The source comments on `GetProbeErrorCount` and the round reset count a probe that answered a secret value as a failure, as the code has since revision 4. Comments and documentation only: the implementation revision is unchanged.

## 0.1.5 — 2026-09-24

- A probe that answers a secret value is a probe failure. The client raises on any boolean test of a secret (measured on Retail 12.1.0 b69933: `if result then` with `result = secretwrap(true)` raised "attempt to perform boolean test on local 'result' (a secret boolean value ...)"), and before this release that test ran outside the probe's protected call, so a secret answer made `Gate` raise and left the gate registered. The answer is now checked with `issecretvalue` (read once at load) before it is tested for truth; a secret answer counts as "not ready", the gate stays pending, nothing raises out of `Gate`, `Probe`, a poll or a re-probe event, `GetProbeErrorCount` counts it, and the first of each polling round is reported through the host error handler as `ReadinessKit gate "<name>" probe answered a secret value; a probe must answer a plain true or false`. `docs/API.md` gains "Probes that answer a secret value".
- `gate:ReprobeOn` re-raises a refused host registration whose reason is a secret value with the fixed text `(secret value)` in place of the reason, instead of testing the secret while stripping its position.
- Implementation revision 4, because the executed implementation changed. A new spec upgrades a revision-3 gate in place and has the upgraded gate treat a secret answer as a failure; `SecretValues_spec.lua` covers a secret answer at definition, from a poll, from `Probe` and from a re-probe event.

## 0.1.4 — 2026-09-24

- Nil rule (decision of 2026-09-24): absence of a value that comes from outside the Kit (an option, the Registry lookups, the EventKit facade `Registry:Find` returns) is tested with `type(value) == "nil"`, never by comparing it with `nil`, because comparing a secret value raises inside the Kit instead of at the caller.
- A secret `name` (`Gate`, `Get`), `eventName` (`ReprobeOn`) or option value (`intervalSeconds`, `timeoutSeconds`, `maxWaiters`) is refused at the caller's line with `... must not be a secret value` before any comparison, instead of raising inside ReadinessKit. `issecretvalue` is read once at load; a host without it has no secret values. `docs/API.md` lists the messages under "Error behaviour".
- Implementation revision 3, because the executed implementation changed. A new bootstrap spec upgrades the previous revision in place; new `SecretValues_spec.lua`.

## 0.1.3 — 2026-09-24

- Documentation only: no runtime change, implementation revision 2 is unchanged. `docs/INTERNALS.md` lists the `unbounded` state field and describes the upgrade spec as it now runs (a revision-1 copy upgraded to the current revision). The comment on the option-key check no longer claims it refuses a non-table option table; its caller does.

## 0.1.2 — 2026-09-23

- Limits (design constitution, principle 4a). The `maxWaiters` gate option accepts `ReadinessKit.UNBOUNDED`, a new sentinel published on the facade and kept in package state (`_state.unbounded`), so a gate may queue any number of the consumer's own callbacks. `UNBOUNDED` joins the public-surface check. `docs/API.md` gains a "Limits" section, which also states that `intervalSeconds` and `timeoutSeconds` are timing, not caps.
- Implementation revision 2, because the executed implementation changed. Revision-1 state is given the sentinel during an in-place upgrade; the upgrade spec now loads a real revision-1 copy first.
- New `Limits_spec.lua`.

## 0.1.1 — 2026-09-23

- Documentation and tests only: no runtime change, implementation revision 1 is unchanged. TimerKit 0.5.0 no longer requires LifecycleKit, so ReadinessKit's required closure shrinks to Registry and TimerKit. The README and `docs/API.md` state the three-file minimum footprint (Registry, TimerKit, ReadinessKit) and that `ReprobeOn` needs SignalKit and EventKit embedded as well.
- The test module chain drops LifecycleKit. `NewPackageWithoutEventKit` now loads the minimum footprint instead of refusing EventKit through a replaced `Registry:Find`, and a bootstrap spec proves a gate polls to ready with those three files.

## 0.1.0 — 2026-09-23

- Added ReadinessKit API generation 1, implementation revision 1.
- Added `ReadinessKit:Gate(name, probe, options)`: one gate per name for the whole session. A repeated definition returns the existing gate and ignores the new probe and options. Options are `intervalSeconds` (default 0.5), `timeoutSeconds` (default 30, `false` for none) and `maxWaiters` (default 64); unknown fields are refused.
- Added `ReadinessKit:Get(name)` and `ReadinessKit:WhenAll(gates, callback)`.
- Added gate methods `IsReady`, `Await`, `Probe`, `Invalidate`, `ReprobeOn`, `Close` and `IsClosed`, and waiter handles with `Cancel` and `IsPending`.
- A gate probes once when it is defined and polls on one TimerKit repeating timer, in a TimerKit scope ReadinessKit owns, only while it is pending. A timeout calls every waiter with `false, "timeout"` once and stops polling until `Probe`, `Invalidate` or a re-probe event. `Probe` remembers a negative answer for one interval.
- A probe that raises, and a queued callback that raises, are reported to the host error handler; polling and the rest of the batch continue. Only the first probe failure of each polling round is reported; `gate:GetProbeErrorCount()` counts them all, so a probe that always raises cannot flood the handler, even with `timeoutSeconds = false`.
- A probe that closes its own gate leaves it closed: the gate never becomes ready, times out or polls again after that probe returns.
- The manifest lists EventKit API 1 under `optionalDependencies`.
- Waiters live in two arrays per gate that are reused across rounds, bounded by `maxWaiters`. A poll tick on a gate that is not ready allocates nothing.
- `gate:ReprobeOn(eventName)` through EventKit API 1, an optional dependency found with `Registry:Find` when it is called. `Close` releases the subscriptions.
- The poll callback, re-probe callbacks and `WhenAll` callbacks call through a shared dispatch table, and gates and waiters keep their metatables across upgrades, so an in-place upgrade keeps every gate, waiter, timer and subscription.
- `gate:ReprobeOn` raises a refused host registration at its caller's line as `ReadinessKit.Gate:ReprobeOn could not connect <event>: <reason>`, and the event can be connected again later.
- 85 specs, including an allocation guard on the poll tick and an in-place upgrade spec.
