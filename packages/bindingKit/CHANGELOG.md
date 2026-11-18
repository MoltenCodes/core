# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that raises (an error-display addon with a bug) turned the report of a function key's function that failed into a second error, raised into the client's script call. `reportError` is now the shared helper block (`tooling/shared/lua/reportError.lua`): it calls the handler under `pcall` and prints the failure when the handler is missing or raises. Spec: `SharedHelpers_spec.lua` ("prints ... when the host error handler raises").
- `isSecret` and `validateFacade` are now the shared helper blocks too, kept in step by `python3 -m tooling.shared.sync`. The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 3; an embedded revision 2 is upgraded in place, keeping what it made.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the facade message, the raising handler, the upgrade over the committed revision 2 file in `tests/fixtures/BindingKit-revision2.lua`) and `Conformance_spec.lua` (the repository's conformance suite; its limits group is pending, see the spec).

## 0.1.1 — 2026-11-15

- Fixed: a function key's button given up in combat was handed to the next function key at once, while the client still clicked it on the old key until combat ended. Unbinding `F5` in combat and binding `F6` to another function made `F5` run `F6`'s function until combat ended. A button given up in combat now waits with its scope and is freed when the scope's bindings are rebuilt; out of combat it is reused at once, as before. Specs: `Scope_spec.lua` ("keeps a button unbound in combat out of reuse until the client lets it go"), `Bootstrap_spec.lua` ("upgrades revision 1 in place: its scopes retire buttons unbound in combat").
- `docs/API.md` lists every error message.
- Implementation revision 2. A scope record gains `retiredButtons`; a record revision 1 made gets it at its first removal in combat, so no migration is needed. 23 specs.

## 0.1.0 — 2026-11-15

- Added BindingKit API generation 1, implementation revision 1: override key bindings in named scopes, as recorded in `docs/ROADMAP.md` (package M).
- `BindingKit:CreateScope(name, options?)` with `priority`, `BindingKit:GetScope`; `SetLimits` and `GetLimits` for `maxScopes` (32, up to 256) and `maxFunctionKeys` (64, up to 512).
- A scope: `BindCommand`, `BindClick`, `BindFunction` (through a hidden named button, reused from a free list, calling the function protected), `Unbind`, `ClearAll`, `GetBinding`, `IsPending`, `GetName`. A change made in combat waits and is applied at `PLAYER_REGEN_ENABLED`.
- 21 specs, and a client suite, `tests/client/MoltenCodesTest_BindingKit`, not yet run in a client.
