# Changelog

## 0.1.1 — 2026-11-15

- Fixed: a function key's button given up in combat was handed to the next function key at once, while the client still clicked it on the old key until combat ended. Unbinding `F5` in combat and binding `F6` to another function made `F5` run `F6`'s function until combat ended. A button given up in combat now waits with its scope and is freed when the scope's bindings are rebuilt; out of combat it is reused at once, as before. Specs: `Scope_spec.lua` ("keeps a button unbound in combat out of reuse until the client lets it go"), `Bootstrap_spec.lua` ("upgrades revision 1 in place: its scopes retire buttons unbound in combat").
- `docs/API.md` lists every error message.
- Implementation revision 2. A scope record gains `retiredButtons`; a record revision 1 made gets it at its first removal in combat, so no migration is needed. 23 specs.

## 0.1.0 — 2026-11-15

- Added BindingKit API generation 1, implementation revision 1: override key bindings in named scopes, as recorded in `docs/ROADMAP.md` (package M).
- `BindingKit:CreateScope(name, options?)` with `priority`, `BindingKit:GetScope`; `SetLimits` and `GetLimits` for `maxScopes` (32, up to 256) and `maxFunctionKeys` (64, up to 512).
- A scope: `BindCommand`, `BindClick`, `BindFunction` (through a hidden named button, reused from a free list, calling the function protected), `Unbind`, `ClearAll`, `GetBinding`, `IsPending`, `GetName`. A change made in combat waits and is applied at `PLAYER_REGEN_ENABLED`.
- 21 specs, and a client suite, `tests/client/MoltenCodesTest_BindingKit`, not yet run in a client.
