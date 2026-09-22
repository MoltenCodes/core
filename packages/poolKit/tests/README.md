# PoolKit Tests

PoolKit tests cover reuse/reset semantics, ownership and duplicate-release protection, bounded/unbounded retention, prewarming, cleanup/error behavior, embedded bootstrap identity, manifest drift, and randomized state invariants.

They also cover the contracts a caller is most likely to get wrong:

- a pool without `reset` hands back objects carrying their previous state, and `strictReset` refuses to build one;
- borrowed objects are caller-owned and unbounded, with `maxActiveWarning` reported once through the host error handler;
- nested lifecycle callbacks, and callbacks that raise, leave the re-entrancy guard exactly as they found it;
- every argument error reports the caller's own line.

PoolKit is pure Lua, so the host error handler used by the leak-warning specs is installed explicitly by the spec rather than by default.

The property spec executes 5,000 deterministic acquire/release operations and continuously verifies the accounting invariant:

```text
created = active + available + discarded
```

for the no-external-destroy-error model used by that test.
