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
| `Children_spec.lua` | `AttachChild`/`DetachChild`, cascade order, cycles, child and parent reset failures, a child's reset releasing its parent mid-release. |
| `Deferred_spec.lua` | `ReleaseAfter`: parking, one hook per group, early completion, close, live limit, reported failures; a Frame (`HookScript` without `IsPlaying`, `Play` and `Stop`), a group missing any of the four methods and an unreadable userdata refused at the caller's line; a userdata group accepted. |
| `FastPath_spec.lua` | The `Acquire` and `Release` fast paths: LIFO reuse, counters, double release of retained and discarded objects, foreign objects and receivers, closed pools, full retention, superseded generations, the waiting queue, the leak warning, a release from inside `reset`, a failing `reset`'s rollback, children, and a table-pool clear that bypasses `__newindex`. |
| `Allocation_spec.lua` | Zero allocation for steady-state acquire/release through generic, table and capped pools, and for attach-and-cascade. |
| `Bootstrap_spec.lua` | Duplicate loads, newer-revision refusal, in-place upgrades from revisions 1, 3, 5, 7 and 8 and from the previous revision (which then names a table option field by its type), sentinel drift. |
| `SecretValues_spec.lua` | Secret options and pool-method arguments refused at the caller's line on the `mainline` host; ordinary and absent ones still accepted. |
| `Manifest_spec.lua` | Manifest API and revision agree with the runtime. |
| `Parts_spec.lua` | The four parts: stubs and constructor-option refusals at the caller without them, neutral getters, `Acquire(onAvailable)` answering `queueFull` without a queue, sparse pools of at most 16 fields, `HasPart`, either load order, a part without its core, part revisions, a later core over installed parts, and the upgrade from revision 11 with a queue, a parked object, a child and a raised generation, with the parts (everything adopted) and without them (each reported once, the safe exact path), a full and a sparse pool side by side. |
| `Conformance_spec.lua` | The shared conformance suite's `manifest`, `receivers`, `arguments` and `upgrade` groups (`limits` does not apply). |

`support/PoolKitTestEnv.lua` builds the environment on the shared fixture, loading the core and its four parts (`PoolKitTestEnv.Core` loads the core alone), and adds an animation-group stand-in (`NewAnimationGroup`), `LoadParts`, a `ReloadPackage` that reloads the core and then its parts, and `LoadRevision`, which loads an earlier revision: the whole-file fixture `fixtures/PoolKit-revision11.lua` up to revision 11, the core in `src/` after it.

PoolKit is pure Lua, so the host error handler used by the leak-warning specs is installed explicitly by the spec rather than by default.

The property spec executes 5,000 deterministic acquire/release operations and continuously verifies the accounting invariant:

```text
created = active + available + discarded
```

for the no-external-destroy-error model used by that test.
