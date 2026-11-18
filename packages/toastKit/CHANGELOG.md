# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that raises (an error-display addon with a bug) turned the report of a toast's `onClick` that failed into a second error, raised into the client's script call. `reportError` is now the shared helper block (`tooling/shared/lua/reportError.lua`): it calls the handler under `pcall` and prints the failure when the handler is missing or raises. Spec: `SharedHelpers_spec.lua` ("prints ... when the host error handler raises").
- `isSecret` and `validateFacade` are now the shared helper blocks too, kept in step by `python3 -m tooling.shared.sync`. The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 2; an embedded revision 1 is upgraded in place, keeping what it made.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the facade message, the raising handler, the upgrade over the committed revision 1 file in `tests/fixtures/ToastKit-revision1.lua`) and `Conformance_spec.lua` (the repository's conformance suite; its limits group is pending, see the spec).

## 0.1.1 — 2026-11-15

- Documentation: `docs/API.md` lists every error message, and says that a toast counts no time while the interface is hidden. Documentation only; the implementation revision stays 1.

## 0.1.0 — 2026-11-15

- Added ToastKit API generation 1, implementation revision 1: short notifications, as recorded in `docs/ROADMAP.md` (package M).
- `ToastKit:Show(options)` with `title`, `text`, `icon`, `duration`, `onClick`, `data`, `key` and `allowSecret`; `ToastKit:DismissAll()`; `ToastKit:SetAnchor(point, x, y, direction)`; `SetLimits` and `GetLimits` for `maxVisible` (5, up to 20) and `maxQueued` (32, opens to `UNBOUNDED`).
- A toast: `Dismiss`, `IsShown`, `IsQueued`. Toasts stack at the anchor, hold while the cursor rests on them, fade over their last half second, and run a protected `onClick` before ending; a key updates and restarts the toast under it.
- 23 specs, and a client suite, `tests/client/MoltenCodesTest_ToastKit`, not yet run in a client.
