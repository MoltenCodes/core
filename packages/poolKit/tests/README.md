# PoolKit Tests

PoolKit tests cover reuse/reset semantics, ownership and duplicate-release protection, bounded/unbounded retention, prewarming, cleanup/error behavior, embedded bootstrap identity, manifest drift, and randomized state invariants.

They also cover the contracts a caller is most likely to get wrong:

- a pool without `reset` hands back objects carrying their previous state, and `strictReset` refuses to build one;
- borrowed objects are caller-owned and unbounded, with `maxActiveWarning` reported once through the host error handler;
- nested lifecycle callbacks, and callbacks that raise, leave the re-entrancy guard exactly as they found it;
- every argument error reports the caller's own line.

## Spec files

| File | Covers |
|---|---|
| `PoolKit_spec.lua` | Reuse, reset before retention, table pools, option and factory-result rejection, default retention. |
| `Ownership_spec.lua` | Foreign, duplicate and re-entrant release; reset rollback; ownership without strict history. |
| `Capacity_spec.lua` | Retention overflow, `UNBOUNDED`, idempotent prewarm, trimming when `maxRetained` is lowered. |
| `Cleanup_spec.lua` | `Clear`, `Close`, best-effort bulk destroy, the detached trim snapshot. |
| `Errors_spec.lua` | Arbitrary error objects, destroy errors after commit, the lifecycle-callback guard. |
| `ErrorLevels_spec.lua` | Every argument, receiver, closed-pool, guard and factory error reported at the caller's line. |
| `Retention_spec.lua` | `strictReset`, leftover state without `reset`, `maxActiveWarning`. |
| `Property_spec.lua` | The randomized accounting invariant below. |
| `Generation_spec.lua` | Generation defaults, `SetGeneration`, stale retained and borrowed objects, side-table stamps. |
| `Unfreeable_spec.lua` | `maxCreated`, `maxActive`, `SetMaxCreated`, the waiting ring (FIFO, wrap-around, cancellation, refusal, close, failures, zero allocation). |
| `Children_spec.lua` | `AttachChild`/`DetachChild`, cascade order, cycles, child and parent reset failures. |
| `Deferred_spec.lua` | `ReleaseAfter`: parking, one hook per group, early completion, close, live limit, reported failures. |
| `Bootstrap_spec.lua` | Duplicate loads, newer-revision refusal, in-place upgrades from revisions 1, 3 and 5, sentinel drift. |
| `Manifest_spec.lua` | Manifest API and revision agree with the runtime. |

`support/PoolKitTestEnv.lua` builds the environment on the shared fixture and adds an animation-group stand-in (`NewAnimationGroup`) and `LoadRevision`, which loads this source as an earlier revision of the same state schema.

PoolKit is pure Lua, so the host error handler used by the leak-warning specs is installed explicitly by the spec rather than by default.

The property spec executes 5,000 deterministic acquire/release operations and continuously verifies the accounting invariant:

```text
created = active + available + discarded
```

for the no-external-destroy-error model used by that test.
