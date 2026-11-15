# DialogKit Tests

The DialogKit suite covers:

- dialogs: the text and two buttons on the named frame at the `DIALOG` strata with the client's templates, the frame's name added to `UISpecialFrames`; one button with `cancel = false` and a number as text; accept with the button and Enter and cancel with the button, each once; the input line's starting text, letter limit and text handed to `onAccept`; Escape from the input line and through `UISpecialFrames`; the timeout; the queue in order, a waiting dialog hidden, the shown one hidden; keys; a callback showing the next dialog at once; `HideAll`, the waiting ones first; a callback that raises reported with the next dialog still shown; `maxQueued` and `UNBOUNDED`;
- arguments and secrets: every argument failure reported at the caller's line, a secret text refused without `allowSecret` and drawn with it, secret options and limits refused, a host without `UIParent`, and a host without `UISpecialFrames`;
- Registry publication, a duplicate embedded load keeping dialogs, yielding to a newer revision, an in-place upgrade keeping the frame, the queue, the limit and the sentinel while the frame's scripts run the new code and the frame's name stays listed once, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependency.

`support/DialogKitTestEnv.lua` provides `UIParent`, `UISpecialFrames` and `PressEscape` (which hides every shown frame the list names, as the client's Escape does), a `GetTime` clock (`SetTime`, `Advance`), `Run`, `TakeReportedValues`, the secret probe and `LoadRevision`.

| Spec | Covers |
|---|---|
| `Dialog_spec.lua` | showing, ending, the queue, keys, callbacks, the limit |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, missing host facilities |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependency |
