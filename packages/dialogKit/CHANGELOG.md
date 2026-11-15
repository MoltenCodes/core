# Changelog

## 0.1.1 — 2026-11-15

- Fixed: hiding the interface cancelled the shown dialog. The client runs a frame's `OnHide` when a parent hides (warcraft.wiki.gg, the `OnHide` script handler page), so Alt+Z, which hides `UIParent`, ended the dialog with `onCancel(data, "escape")`. The frame's `OnHide` now ends the dialog only when the frame itself was hidden (its `IsShown()` answers `false`), as Escape through `UISpecialFrames` does; otherwise the dialog stays and shows again with its parent. Specs: `Dialog_spec.lua` ("keeps the dialog when only a parent hides, as when the player hides the interface"), `Bootstrap_spec.lua` ("upgrades revision 1 in place: its frame then ignores a parent's hide").
- Fixed: a secret `accept` or `cancel` text was refused with `... must not be a secret value; pass allowSecret = true to draw one`, although `allowSecret` covers only `text`. The message is now `DialogKit:Show options.<accept or cancel> must not be a secret value`. Spec: `Arguments_spec.lua` ("refuses a secret button text without offering allowSecret, which never applies to it").
- Fixed: a secret `cancel` was compared with `false` before the secret check, and on Retail comparing a secret raises, so the error came from inside DialogKit instead of the caller's line. `cancel` is now checked with `issecretvalue` first and refused with `DialogKit:Show options.cancel must not be a secret value` at the caller's line. The facade receiver is also asked about first, before it is compared. Spec: `Arguments_spec.lua` ("refuses a secret cancel at the caller's line, before comparing it").
- Fixed: a secret number `text` shown with `allowSecret` went through `tostring`, which raises on a secret. A secret `text` now reaches the font string unconverted, as the client accepts it there; only a plain number is converted. Without `allowSecret` a secret `text` is refused before any conversion, as before. Specs: `Arguments_spec.lua` ("hands a secret number text to the font string unconverted, and refuses it without allowSecret", "draws a secret text that raises when converted or concatenated").
- Test stand-in: `NewSecret` returns a value that raises when compared with another table, ordered, concatenated or converted with `tostring`, as the client's secrets do. `MarkSecret` makes a number secret for the paths that read a secret's type. Lua 5.1 runs `__eq` only between two tables, so `secret ~= false` cannot raise in a spec. That check is pinned by its message and the caller's line.
- `docs/API.md` lists every error message.
- Implementation revision 2. No state changed; the frame, the shown and waiting dialogs and the limit of revision 1 are kept, and the frame's scripts run the new code through the shared dispatch table. 32 specs.

## 0.1.0 — 2026-11-15

- Added DialogKit API generation 1, implementation revision 1: confirmation and input dialogs without `StaticPopupDialogs`, as recorded in `docs/ROADMAP.md` (package M).
- `DialogKit:Show(options)` with `text`, `accept`, `cancel`, `onAccept`, `onCancel`, `data`, `input`, `inputText`, `maxLetters`, `timeout`, `key` and `allowSecret`; `DialogKit:HideAll()`; `SetLimits` and `GetLimits` for `maxQueued` (16, opens to `UNBOUNDED`).
- A dialog: `Hide`, `IsShown`, `IsQueued`, `GetInput`. Each dialog ends once, by `onAccept` or by `onCancel` with `"cancel"`, `"escape"`, `"timeout"` or `"hidden"`, run protected; Escape works through `UISpecialFrames`.
- 26 specs, and a client suite, `tests/client/MoltenCodesTest_DialogKit`, not yet run in a client.
