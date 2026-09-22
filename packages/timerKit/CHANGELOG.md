# Changelog

## 0.2.0 — 2026-09-22

- Added `Timer:SetUserData(value)` and `Timer:GetUserData()`, a documented public seam for attaching one opaque owner-defined value to a timer. Consumers that need to associate their own state with a timer no longer have to write private fields onto a TimerKit handle. Attaching a value allocates nothing and survives cancel/restart; TimerKit never reads or clears it.
- Normalised every `error` level so argument failures report the line that called the public method. Previously `scope:After(1, "nope")`, `TimerKit:After(...)`, timer/scope receiver checks, option-table fields, and closed-scope rejections reported one stack level too deep, which stripped the `file:line` prefix from the message or pointed it at the wrong frame.
- Made `New()` option validation allocation-free. The allowed-field set is now a file-local constant instead of a table built per call, and the first unknown field is found by tracking the smallest key rather than collecting and sorting every offender.
- Removed a dead counter update in bulk cancellation: a failed native cancel incremented the cancelled total on a path that always re-raises before returning it.
- Documented same-instant timer ordering as host-defined, and documented that argument errors point at the caller.
- Added LuaCATS annotations for the package facade, `Timer`, `Scope`, and the option table.

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
