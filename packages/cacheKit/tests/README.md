# CacheKit Tests

The CacheKit suite covers:

- LRU eviction order, overwrite-as-use, `Set(key, nil)` as delete, `Peek` leaving recency and statistics untouched, `Clear`, `Close`, and the statistics table;
- TTL expiry at the exact boundary with the fixture's clock stub, age restarted by `Set` and not by `Get`, and the documented behaviour on a host without `GetTimePreciseSec`;
- negative entries: `nil, "negative"` from `Get` and `Peek`, counted as hits, the entry's own age limit shorter and longer than the cache's, replacement by `Set`, removal by `Delete` and `Clear`, eviction by recency, a memoised function answering `nil` without calling `fn`, refusal on an LRU cache and on a `Memoize` cache without `ttlSeconds`, argument and closed-cache errors, the clock-less host, and a 5,000-step deterministic comparison against a naive TTL model (`Set`, `PutNegative` with 1 to 3 second limits, `Get`, `Delete`, `Clear`, clock advances) checking `GetCount` and the `Peek` value and outcome of every key after every step;
- memoisation: hits and misses, clearing through the returned cache, the default bound, `ttlSeconds`, `false` remembered and `nil` not, errors from `fn`, recursion, a closed cache, and `cacheable`: an incomplete result returned without being remembered, the predicate's arguments (first result and key, not consulted for `nil`), a `nil` answer treated as not cacheable, an error from the predicate, the predicate closing the cache, and the type check;
- lazy trees: once-per-path resolution with parts passed unchanged, `nil` results not kept, `Peek` without resolving, invalidation of a node with its descendants and the values of its ancestors, invalidation of a path never expanded, the zero return, `Clear`, the default bound and eviction order, an evicted node kept as structure for its descendant, `UNBOUNDED` and the 1024-node free list, a resolver that reads other paths and one that closes the tree, an error from the resolver, `Close`, constructor and path validation, a structural node expanded while eviction takes its only expanded descendant, and a 3,000-step randomized workload of `Get`, `Peek`, `Invalidate` and `Clear`, run with six and with two expanded nodes, with resolvers that invalidate their own path, clear the tree or read another path mid-resolve, walking the whole tree after every step to assert that every node without a value has an expanded descendant, that `parent`, `key` and `childCount` agree with the `children` tables, that the recency list holds exactly the expanded nodes and each of them is attached under the root, and that the free list stays within the bound;
- queues: first-in, first-out order, `false` as a value, wrap-around, the three overflow policies and what `Push` returns under each, iteration across the wrap point, `Clear` and popped slots blanked, capacity one, constructor validation (including `UNBOUNDED`), the `nil` value and receiver errors, and a 1,000-step comparison against a naive array model per policy;
- snapshots: added, removed and changed keys, reused result arrays, identity comparison, a reader that raises (added keys rolled back, changed values restored and reported by the next success, the count held within `maxEntries` over 100 failing reads), duplicate keys, `maxEntries`, re-entrancy, secret keys and values refused through an `issecretvalue` stub, and `Close`;
- clear-on-event through the real EventKit, connections released by `Close`, a cache closed during the dispatch in flight, EventKit loaded after CacheKit, a host registration refusal re-raised at the caller, and the errors when EventKit is absent, when the embedded Registry has no `Find`, and when the EventKit facade has no `CreateScope`;
- allocation guards (`collectgarbage("count")` with the collector stopped) on `Get` hits and misses, `Peek`, `Set` overwrites, eviction, free-list reuse, memoised hits, negative hits and renewals, results `cacheable` lets through, lazy tree hits and peeks, re-expansion of an invalidated path, queue pushes, pops and iteration, and unchanged snapshot keys;
- duplicate embedded loading, Registry publication, yielding to a newer revision, an in-place upgrade to a newer revision that keeps every cache, entry, memoised function, subscription, snapshot, lazy tree, queue and negative entry, the upgrade of revision 1 state (schema 1, no `LazyTree`, `Queue` or `PutNegative`, three-argument memoised closures) to schema 2, the upgrade of revision 2 state with its limits, lazy trees, queues and negative entries kept, and a same-revision state without the negative marker refused;
- `error` levels: every argument failure reports the caller's own line, including `PutNegative`, `cacheable`, `Lazy`, `NewQueue`, `SetLimits`, `GetLimits`, lazy tree paths and queue values;
- a 5,000-step deterministic property test against a naive LRU model, checking after every step that live plus free entries stay within `maxEntries`;
- limits: the default `Memoize` and snapshot bounds, `UNBOUNDED` on every constructor, the 1024-entry free list of an unbounded cache, another table refused at the caller's line, the sentinel identity and unbounded caches kept across an in-place upgrade, and `maxQueueCapacity`: the 1024 default bounding `NewQueue`, the 65536 ceiling, lowering without shrinking an existing queue, `UNBOUNDED` refused with its reason on `SetLimits` and `NewQueue`, invalid values, unknown names and a non-table, atomic updates, a fresh table from `GetLimits`, the facade receiver, and the value shared by embedded copies and kept across an upgrade;
- manifest/runtime API and revision consistency.

The randomized and model-based specs draw from a fixed linear congruential generator, so every run replays the same workload. The draw uses the generator's high bits: with a power-of-two modulus the low bits repeat with periods as short as two, which would make a "random" workload cycle through a handful of steps.

EventKit is an optional dependency, declared under `optionalDependencies` in the manifest, so the test runner puts EventKit and SignalKit on `LUA_PATH` for this suite and the clear-on-event specs exercise the real EventKit rather than a stub. The release load order ignores optional dependencies; `cache:ClearOn` finds EventKit through `Registry:Find` at call time.

| Spec | Covers |
|---|---|
| `Lru_spec.lua` | LRU order, `Peek`, `Delete`, `Clear`, `Close`, statistics |
| `Ttl_spec.lua` | age limits and the clock-less host |
| `Negative_spec.lua` | negative entries on caches with an age limit |
| `NegativeProperty_spec.lua` | the model-based TTL and negative-entry property test |
| `Memoize_spec.lua` | memoised functions, `cacheable` |
| `Lazy_spec.lua` | lazy trees: expansion, invalidation, eviction, the structure invariant |
| `Queue_spec.lua` | ring queues, overflow policies, the model comparison |
| `Snapshot_spec.lua` | snapshots, rollback of failed reads |
| `SecretValues_spec.lua` | secret keys and values refused by `fill` |
| `ClearOn_spec.lua` | clear-on-event through EventKit |
| `Allocation_spec.lua` | allocation guards |
| `Property_spec.lua` | the model-based LRU property test |
| `Limits_spec.lua` | `maxEntries` defaults, `UNBOUNDED`, `maxQueueCapacity`, the sentinel across upgrades |
| `Errors_spec.lua` | argument and state errors |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement |
