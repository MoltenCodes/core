# CacheKit Tests

The CacheKit suite covers:

- LRU eviction order, overwrite-as-use, `Set(key, nil)` as delete, `Peek` leaving recency and statistics untouched, `Clear`, `Close`, and the statistics table;
- TTL expiry at the exact boundary with the fixture's clock stub, age restarted by `Set` and not by `Get`, and the documented behaviour on a host without `GetTimePreciseSec`;
- memoisation: hits and misses, clearing through the returned cache, the default bound, `ttlSeconds`, `false` remembered and `nil` not, errors from `fn`, recursion, and a closed cache;
- snapshots: added, removed and changed keys, reused result arrays, identity comparison, a reader that raises, duplicate keys, `maxEntries`, re-entrancy, and `Close`;
- clear-on-event through the real EventKit, connections released by `Close`, a cache closed during the dispatch in flight, EventKit loaded after CacheKit, and the error when EventKit is absent;
- allocation guards (`collectgarbage("count")` with the collector stopped) on `Get` hits and misses, `Peek`, `Set` overwrites, eviction, free-list reuse, memoised hits and unchanged snapshot keys;
- duplicate embedded loading, Registry publication, yielding to a newer revision, and an in-place upgrade that keeps every cache, entry, memoised function, subscription and snapshot;
- `error` levels: every argument failure reports the caller's own line;
- a 5,000-step deterministic property test against a naive LRU model;
- manifest/runtime API and revision consistency.

EventKit is an optional dependency, so the manifest does not name it and the test runner does not put it on `LUA_PATH`. `support/CacheKitTestEnv.lua` adds the SignalKit and EventKit source directories itself, so the clear-on-event specs exercise the real EventKit rather than a stub.
