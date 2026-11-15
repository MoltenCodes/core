# Changelog

## 0.1.0 — 2026-11-15

- Added BindingKit API generation 1, implementation revision 1: override key bindings in named scopes, as recorded in `docs/ROADMAP.md` (package M).
- `BindingKit:CreateScope(name, options?)` with `priority`, `BindingKit:GetScope`; `SetLimits` and `GetLimits` for `maxScopes` (32, up to 256) and `maxFunctionKeys` (64, up to 512).
- A scope: `BindCommand`, `BindClick`, `BindFunction` (through a hidden named button, reused from a free list, calling the function protected), `Unbind`, `ClearAll`, `GetBinding`, `IsPending`, `GetName`. A change made in combat waits and is applied at `PLAYER_REGEN_ENABLED`.
- 21 specs, and a client suite, `tests/client/MoltenCodesTest_BindingKit`, not yet run in a client.
