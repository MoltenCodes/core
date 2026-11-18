# Changelog

## 0.1.2 — 2026-11-18

- `isSecret` and `validateFacade` are now the shared helper blocks (`tooling/shared/lua/`, kept in step by `python3 -m tooling.shared.sync`). The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 2; an embedded revision 1 is upgraded in place, glows and limits kept.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the facade message, the upgrade over the committed revision 1 file in `tests/fixtures/GlowKit-revision1.lua`) and `Conformance_spec.lua` (the repository's conformance suite; its limits and arguments groups are pending, see the spec).

## 0.1.1 — 2026-11-15

- Documentation: `docs/API.md` lists every error message, and the README's migration row for `ButtonGlow_Start` names LibCustomGlow-1.0's own frame-level argument as unsupported. Documentation only; the implementation revision stays 1.

## 0.1.0 — 2026-11-15

- Added GlowKit API generation 1, implementation revision 1: glows, as recorded in `docs/ROADMAP.md` (package M).
- `GlowKit:Start(frame, options?)` with `kind` (`"pixel"` or `"pulse"`), `key`, `color`, `lines`, `thickness` and `frequency`; `GlowKit:Stop`, `GlowKit:StopAll`, `GlowKit:IsGlowing`; `SetLimits` and `GetLimits` for `maxGlows` (64, up to 512).
- A glow: `Stop`, `IsActive`. Each glow is a pooled overlay laid over its frame, a child of it, so it runs nothing while the frame is hidden; a key restarts the glow under it.
- 22 specs, and a client suite, `tests/client/MoltenCodesTest_GlowKit`, not yet run in a client.
