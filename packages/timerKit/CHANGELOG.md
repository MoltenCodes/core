# Changelog

## 0.1.0

- Added TimerKit API generation 1.
- Added cancelable one-shot and repeating timers.
- Added idle/start/cancel/restart/completion state management.
- Added generation guards that suppress stale native callbacks after cancel/restart.
- Added manual timer scopes with deterministic bulk cancellation and terminal close.
- Added addon-owned scopes that close automatically through LifecycleKit shutdown.
- Added native creation rollback and best-effort cleanup after cancellation errors.
- Added strict input validation and runtime/manifest consistency tests.
