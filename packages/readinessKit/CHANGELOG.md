# Changelog

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
