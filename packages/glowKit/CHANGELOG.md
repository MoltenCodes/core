# Changelog

## 0.1.0 — 2026-11-15

- Added GlowKit API generation 1, implementation revision 1: glows, as recorded in `docs/ROADMAP.md` (package M).
- `GlowKit:Start(frame, options?)` with `kind` (`"pixel"` or `"pulse"`), `key`, `color`, `lines`, `thickness` and `frequency`; `GlowKit:Stop`, `GlowKit:StopAll`, `GlowKit:IsGlowing`; `SetLimits` and `GetLimits` for `maxGlows` (64, up to 512).
- A glow: `Stop`, `IsActive`. Each glow is a pooled overlay laid over its frame, a child of it, so it runs nothing while the frame is hidden; a key restarts the glow under it.
- 22 specs, and a client suite, `tests/client/MoltenCodesTest_GlowKit`, not yet run in a client.
