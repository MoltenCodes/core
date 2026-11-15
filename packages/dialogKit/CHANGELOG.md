# Changelog

## 0.1.0 — 2026-11-15

- Added DialogKit API generation 1, implementation revision 1: confirmation and input dialogs without `StaticPopupDialogs`, as recorded in `docs/ROADMAP.md` (package M).
- `DialogKit:Show(options)` with `text`, `accept`, `cancel`, `onAccept`, `onCancel`, `data`, `input`, `inputText`, `maxLetters`, `timeout`, `key` and `allowSecret`; `DialogKit:HideAll()`; `SetLimits` and `GetLimits` for `maxQueued` (16, opens to `UNBOUNDED`).
- A dialog: `Hide`, `IsShown`, `IsQueued`, `GetInput`. Each dialog ends once, by `onAccept` or by `onCancel` with `"cancel"`, `"escape"`, `"timeout"` or `"hidden"`, run protected; Escape works through `UISpecialFrames`.
- 26 specs, and a client suite, `tests/client/MoltenCodesTest_DialogKit`, not yet run in a client.
