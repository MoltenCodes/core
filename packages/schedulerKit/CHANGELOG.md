# Changelog

## 0.1.2

- Rejected non-finite `maxResumesPerFrame` values so the hard per-frame safety ceiling cannot be disabled accidentally with `math.huge`.
- Made each SchedulerKit scope allocate its TimerKit delay scope lazily, so immediate-only scheduling avoids an unnecessary scope allocation and TimerKit failure surface.
- Removed unused internal job IDs and runtime-revision bookkeeping that had no observable or diagnostic purpose.
- Hardened precise-clock validation against non-finite host values.

## 0.1.1

- Fixed cooperative self-cancellation so `Context:Yield()` preserves the `cancelled` state instead of converting the job to `failed`.
- Made the package-level TimerKit scope lazy, eliminating an unnecessary bootstrap allocation and a host-failure point after Registry revision acceptance.
- Released callback/context execution references when jobs become terminal to reduce closure retention for long-lived job handles.
- Hardened duplicate-load validation to accept the intentionally uninitialized lazy default scope.

## 0.1.0

- Added SchedulerKit API generation 1.
- Added weighted `HIGH` / `NORMAL` / `LOW` / `IDLE` priority scheduling.
- Added cooperative coroutine jobs with frame-budget-aware contexts.
- Added delayed and fixed-delay repeating work through TimerKit.
- Added manual and LifecycleKit-owned cancellation scopes.
- Added callback error isolation and job diagnostics.
- Added runaway-slice and per-frame resume safety limits.
- Added compatible embedded-copy runtime dispatch and identity preservation.
