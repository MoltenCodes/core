# Changelog

## 0.1.1 — 2026-11-15

- Documentation: `docs/API.md` lists every error message, and says that a toast counts no time while the interface is hidden. Documentation only; the implementation revision stays 1.

## 0.1.0 — 2026-11-15

- Added ToastKit API generation 1, implementation revision 1: short notifications, as recorded in `docs/ROADMAP.md` (package M).
- `ToastKit:Show(options)` with `title`, `text`, `icon`, `duration`, `onClick`, `data`, `key` and `allowSecret`; `ToastKit:DismissAll()`; `ToastKit:SetAnchor(point, x, y, direction)`; `SetLimits` and `GetLimits` for `maxVisible` (5, up to 20) and `maxQueued` (32, opens to `UNBOUNDED`).
- A toast: `Dismiss`, `IsShown`, `IsQueued`. Toasts stack at the anchor, hold while the cursor rests on them, fade over their last half second, and run a protected `onClick` before ending; a key updates and restarts the toast under it.
- 23 specs, and a client suite, `tests/client/MoltenCodesTest_ToastKit`, not yet run in a client.
