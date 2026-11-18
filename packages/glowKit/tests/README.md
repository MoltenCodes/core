# GlowKit Tests

The GlowKit suite covers:

- glows: the overlay over its frame, five levels above, with eight pixel lines by default in the default colour; the lines moving round each side with time; a resized frame followed and a frame without size drawing nothing; the pulse border's thickness, colour and breathing alpha; keys side by side and a restart under the same key; `Stop` by key, `StopAll`, and overlays given back cleared and reused; the update of an overlay given back, and a secret elapsed time, ignored; `maxGlows` with a restart not counted twice;
- arguments and secrets: every argument failure reported at the caller's line, secret frames, options, colours, limits and receivers refused, a secret size or level counted as 0, and a host without `CreateFrame`;
- Registry publication, a duplicate embedded load keeping glows, yielding to a newer revision, an in-place upgrade keeping glows, the pool and the limit while an overlay's update runs the new code, a refusal of state holding an invalid limit, missing Registry or PoolKit, and an incomplete facade;
- the shared helper blocks: the secret probe kept from load and a probe installed after load asked, the facade message, and the in-place upgrade over the committed revision 1 file (`fixtures/GlowKit-revision1.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`): manifest, receivers and upgrade; its limits and arguments groups are pending, with the reason in the spec;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/GlowKitTestEnv.lua` provides `UIParent`, `FrameAt` (a frame on the screen), `Run` (a frame's script), the secret probe and `LoadRevision`. Specs reach a glow's overlay through its record.

| Spec | Covers |
|---|---|
| `Glow_spec.lua` | both effects, time, size, keys, stopping, reuse, the limit |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, a missing host |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `SharedHelpers_spec.lua` | the shared `isSecret` and `validateFacade` blocks, the upgrade from revision 1 |
| `Conformance_spec.lua` | the conformance suite on a mainline-profile environment |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
