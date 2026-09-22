# Changelog

## 0.1.0

- Added PoolKit API generation 1.
- Added bounded generic object pools with explicit `PoolKit.UNBOUNDED` escape hatch.
- Added shallow-clearing table pools.
- Added strict ownership, duplicate/re-entrant release protection, and reset rollback.
- Added prewarm, trim, clear, close, runtime retention resizing, and scalar diagnostics.
- Added best-effort bulk destroy semantics and weak discarded-object history.
