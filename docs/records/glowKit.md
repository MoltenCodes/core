# glowKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## glowKit

**glowKit** — facade `GlowKit`

1. Package `glowKit`, facade `GlowKit`, API generation 1.
2. Purpose: glows that draw the eye to a frame (an action button, an aura
   icon, a unit frame), what LibCustomGlow-1.0 gives WeakAuras and
   action-bar addons. Two effects drawn with plain textures on an overlay
   frame of the package's own: `pixel`, short lines running round the
   frame's edge, and `pulse`, a border whose opacity breathes. Several glows
   can sit on one frame under different keys. Overlays come from a PoolKit
   pool. Non-goals: Blizzard's spell-activation overlay
   (`ActionButton_ShowOverlayGlow`, Blizzard code on Blizzard buttons),
   particle or model effects.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`.
4. Surface: `GlowKit:Start(frame, options?)` → glow, with `kind`
   (`"pixel"` by default, or `"pulse"`), `key` (default `"default"`; a glow
   already under that key on that frame is restarted with the new options),
   `color`, `lines`, `thickness`, `frequency`; `glow:Stop()`,
   `glow:IsActive()`; `GlowKit:Stop(frame, key?)`,
   `GlowKit:IsGlowing(frame, key?)`, `GlowKit:StopAll(frame)`;
   `SetLimits{ maxGlows }` / `GetLimits()`.
5. Ownership: a glow lives from `Start` until it is stopped; its overlay is
   then released to the pool cleared. A glow on a frame that is hidden stays
   and resumes when the frame shows.
6. Performance and memory: one `OnUpdate` per active glow, only while its
   frame is visible, setting a few texture points or one alpha; lines are
   textures on the overlay, made the first time a count needs them.
   `maxGlows` (active at once) defaults to 64 with a ceiling of 512 and no
   `UNBOUNDED`.
7. Tests: both effects drawn and moved with time, colours, line counts,
   thickness, keys side by side and restarting, stop paths, pooling and
   reuse cleared, a frame resized while glowing, limits, secret values,
   upgrade, manifest, error levels. A client suite on Retail: a glow on a
   frame on screen, animated by the client's frames, and stopped.
8. Docs: README (with the migration from LibCustomGlow-1.0), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 22 specs; the client suite (`tests/client/MoltenCodesTest_GlowKit`) is
   written and has not been run in a client.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, documentation only.

