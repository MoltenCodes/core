# ToastKit Tests

The ToastKit suite covers:

- toasts: the title, text and icon at the anchor at the `HIGH` strata, a title alone and a number as text, stacking down and up with the gap closed when one ends, the life and the fade, holding under the cursor, `onClick` with its data before ending and one that raises reported, the queue past `maxVisible` filled as places free, `Dismiss` once and `DismissAll`, a key updating and restarting the toast and clearing what the new options leave out, frames reused, and `maxQueued` with `UNBOUNDED`;
- arguments and secrets: every argument failure reported at the caller's line, a secret title refused without `allowSecret` and drawn with it, secret options, anchors and limits refused, a secret `elapsed` and mouse-over answer ignored, and a host without `UIParent`;
- Registry publication, a duplicate embedded load keeping toasts, yielding to a newer revision, an in-place upgrade keeping toasts, the anchor, the limits and the sentinel while a toast shown before it ends with the new code and the waiting one takes its place, a refusal of state holding an invalid limit, missing Registry or PoolKit, and an incomplete facade;
- the shared helper blocks: the secret probe kept from load and a probe installed after load asked, the facade message, a toast's `onClick` printed when the host error handler raises, and the in-place upgrade over the committed revision 1 file (`fixtures/ToastKit-revision1.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`): manifest, receivers, arguments and upgrade; its limits group is pending, with the reason in the spec;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/ToastKitTestEnv.lua` provides `UIParent`, `SetMouseOver` (an `IsMouseOver` answer), `Run` (a frame's script), `TakeReportedValues`, the secret probe and `LoadRevision`. Specs reach a toast's frame through its record.

| Spec | Covers |
|---|---|
| `Toast_spec.lua` | showing, stacking, life, fade, clicks, the queue, keys, limits |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, a missing host |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `SharedHelpers_spec.lua` | the shared `isSecret`, `reportError` and `validateFacade` blocks, the upgrade from revision 1 |
| `Conformance_spec.lua` | the conformance suite on a mainline-profile environment |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
