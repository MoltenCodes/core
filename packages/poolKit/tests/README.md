# PoolKit Tests

PoolKit tests cover reuse/reset semantics, ownership and duplicate-release protection, bounded/unbounded retention, prewarming, cleanup/error behavior, embedded bootstrap identity, manifest drift, and randomized state invariants.

The property spec executes 5,000 deterministic acquire/release operations and continuously verifies the accounting invariant:

```text
created = active + available + discarded
```

for the no-external-destroy-error model used by that test.
