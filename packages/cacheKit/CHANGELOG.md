# Changelog

## 0.1.0 — 2026-09-23

- Added CacheKit API generation 1, implementation revision 1.
- Added `CacheKit:NewLru({ maxEntries })` and `CacheKit:NewTtl({ maxEntries, ttlSeconds })`: bounded least-recently-used caches, the second with an age limit, with `Get`, `Set`, `Peek`, `Delete`, `Clear`, `GetCount`, `GetStats`, `ClearOn`, `Close` and `IsClosed`. `maxEntries` is required. The recency order is an intrusive doubly linked list over the key hash, so `Get` and `Set` are O(1); entry tables freed by `Delete`, expiry and `Clear` go to a free list bounded by `maxEntries`, and eviction reuses the evicted entry directly.
- Age limits read `GetTimePreciseSec`, which is optional: without it every age limit is disabled.
- Added `CacheKit:Memoize(fn, options)` for one string or number key, bounded by 128 entries by default, with an optional `ttlSeconds`. It returns the memoised function and the cache behind it.
- Added `CacheKit:NewSnapshot(read, options)` with `Refresh`, `Get`, `GetCount`, `Pairs`, `Close` and `IsClosed`. `Refresh` reports added, removed and changed keys in three reused arrays, and allocates nothing for a key whose value did not change. A snapshot accepts at most `maxEntries` keys per refresh, 1024 by default.
- Added `cache:ClearOn(eventName)` through EventKit API 1, an optional dependency found with `Registry:Find` when it is called. `Close` releases the subscriptions.
- Memoised functions, snapshot fill functions and clear-on-event callbacks call through a shared dispatch table, and caches and snapshots keep their metatables across upgrades, so an in-place upgrade keeps every entry and replaces the behaviour behind every closure.
- 77 specs, including allocation guards, a 5,000-step property test against a naive LRU model, and an in-place upgrade spec.
