# Changelog

## 0.2.0 — 2026-09-22

- Documented that `Acquire()` never cleans: a pool constructed without a `reset` callback hands back objects still carrying the previous borrower's state. Added the opt-in `strictReset` option, which refuses to construct such a pool at all. It is validated at construction and never stored, so it costs the acquire/release hot paths nothing.
- Documented `_active` as unbounded, caller-owned retention — the one structure in a pool PoolKit cannot bound, because it cannot reclaim an object the caller never releases. Added the optional `maxActiveWarning` threshold, reported once per pool through `geterrorhandler`. With no threshold configured the acquire path pays one comparison.
- Made the lifecycle-callback guard a depth counter that restores the previous phase instead of a flag that clears it, so a nested lifecycle callback cannot release a guard it did not take, and a callback that returns by raising cannot leave its pool permanently locked.
- Normalised every `error` level so argument failures report the line that called the public method. `Release` object checks, `Prewarm`/`Trim` counts, `SetMaxRetained`, factory-result rejections reached through `Prewarm`, and the constructor's own option checks previously reported one stack level too deep, which stripped the `file:line` prefix or pointed it at the wrong frame.
- Added LuaCATS annotations for the package facade, `Pool`, and both option tables.

## 0.1.1 — 2026-09-22

- No runtime behaviour change. Revision 1 still describes the shipped implementation.
- Annotated every deliberate `_G` access with the reason it crosses into the global table, so Selene reports the package clean without the `global_usage` lint being disabled repository-wide.
- Reformatted the package with StyLua 2.5.2. Whitespace, wrapping and quote style only; the compiled Lua is unchanged.

## 0.1.0

- Added PoolKit API generation 1.
- Added bounded generic object pools with explicit `PoolKit.UNBOUNDED` escape hatch.
- Added shallow-clearing table pools.
- Added strict ownership, duplicate/re-entrant release protection, and reset rollback.
- Added prewarm, trim, clear, close, runtime retention resizing, and scalar diagnostics.
- Added best-effort bulk destroy semantics and weak discarded-object history.
