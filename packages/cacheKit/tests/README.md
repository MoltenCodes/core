# CacheKit Tests

The CacheKit suite covers:

- LRU eviction order, overwrite-as-use, `Set(key, nil)` as delete, `Peek` leaving recency and statistics untouched, `Clear`, `Close`, and the statistics table;
- TTL expiry at the exact boundary with the fixture's clock stub, age restarted by `Set` and not by `Get`, and the documented behaviour on a host without `GetTimePreciseSec`;
- memoisation: hits and misses, clearing through the returned cache, the default bound, `ttlSeconds`, `false` remembered and `nil` not, errors from `fn`, recursion, and a closed cache;
- snapshots: added, removed and changed keys, reused result arrays, identity comparison, a reader that raises (added keys rolled back, changed values restored and reported by the next success, the count held within `maxEntries` over 100 failing reads), duplicate keys, `maxEntries`, re-entrancy, secret keys and values refused through an `issecretvalue` stub, and `Close`;
- clear-on-event through the real EventKit, connections released by `Close`, a cache closed during the dispatch in flight, EventKit loaded after CacheKit, a host registration refusal re-raised at the caller, and the errors when EventKit is absent, when the embedded Registry has no `Find`, and when the EventKit facade has no `CreateScope`;
- allocation guards (`collectgarbage("count")` with the collector stopped) on `Get` hits and misses, `Peek`, `Set` overwrites, eviction, free-list reuse, memoised hits and unchanged snapshot keys;
- duplicate embedded loading, Registry publication, yielding to a newer revision, and an in-place upgrade that keeps every cache, entry, memoised function, subscription and snapshot;
- `error` levels: every argument failure reports the caller's own line;
- a 5,000-step deterministic property test against a naive LRU model, checking after every step that live plus free entries stay within `maxEntries`;
- manifest/runtime API and revision consistency.

EventKit is an optional dependency, declared under `optionalDependencies` in the manifest, so the test runner puts EventKit and SignalKit on `LUA_PATH` for this suite and the clear-on-event specs exercise the real EventKit rather than a stub. The release load order ignores optional dependencies; `cache:ClearOn` finds EventKit through `Registry:Find` at call time.

| Spec | Covers |
|---|---|
| `Lru_spec.lua` | LRU order, `Peek`, `Delete`, `Clear`, `Close`, statistics |
| `Ttl_spec.lua` | age limits and the clock-less host |
| `Memoize_spec.lua` | memoised functions |
| `Snapshot_spec.lua` | snapshots, rollback of failed reads |
| `SecretValues_spec.lua` | secret keys and values refused by `fill` |
| `ClearOn_spec.lua` | clear-on-event through EventKit |
| `Allocation_spec.lua` | allocation guards |
| `Property_spec.lua` | the model-based LRU property test |
| `Errors_spec.lua` | argument and state errors |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement |
