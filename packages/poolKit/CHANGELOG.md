# Changelog

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
