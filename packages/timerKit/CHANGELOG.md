# Changelog

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Pointed the test-support helpers at luassert explicitly and made the `CreateFrame` stub raise a plain error when asked for a frame type it does not model. Busted injects luassert into spec chunks only, so the support module previously failed on Lua's own `assert` global.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Added TimerKit API generation 1.
- Added cancelable one-shot and repeating timers.
- Added idle/start/cancel/restart/completion state management.
- Added generation guards that suppress stale native callbacks after cancel/restart.
- Added manual timer scopes with deterministic bulk cancellation and terminal close.
- Added addon-owned scopes that close automatically through LifecycleKit shutdown.
- Added native creation rollback and best-effort cleanup after cancellation errors.
- Added strict input validation and runtime/manifest consistency tests.
