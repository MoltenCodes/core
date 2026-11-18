# DialogKit Tests

The DialogKit suite covers:

- dialogs: the text and two buttons on the named frame at the `DIALOG` strata with the client's templates, the frame's name added to `UISpecialFrames`; one button with `cancel = false` and a number as text; accept with the button and Enter and cancel with the button, each once; the input line's starting text, letter limit and text handed to `onAccept`; Escape from the input line and through `UISpecialFrames`; a parent hiding (the interface hidden) leaving the dialog shown; the timeout; the queue in order, a waiting dialog hidden, the shown one hidden; keys; a callback showing the next dialog at once; `HideAll`, the waiting ones first; a callback that raises reported with the next dialog still shown; `maxQueued` and `UNBOUNDED`;
- arguments and secrets: every argument failure reported at the caller's line, a secret text refused without `allowSecret` and drawn with it, a secret button text refused without naming `allowSecret`, a secret `cancel` refused at the caller's line before it is compared, a secret number `text` drawn unconverted, a secret that raises when converted drawn, secret options and limits refused, a host without `UIParent`, and a host without `UISpecialFrames`;
- Registry publication, a duplicate embedded load keeping dialogs, yielding to a newer revision, an in-place upgrade keeping the frame, the queue, the limit and the sentinel while the frame's scripts run the new code and the frame's name stays listed once, an upgrade from revision 1 whose frame then ignores a parent's hide, a refusal of state holding an invalid limit, missing Registry, and an incomplete facade;
- the shared helper blocks: the secret probe kept from load and a probe installed after load asked, the facade message, a dialog's callback printed when the host error handler raises, and the in-place upgrade over the committed revision 2 file (`fixtures/DialogKit-revision2.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`): manifest, receivers, arguments and upgrade; its limits group is pending, with the reason in the spec;
- manifest/runtime API and revision consistency, and the declared dependency.

`support/DialogKitTestEnv.lua` provides `UIParent`, `UISpecialFrames` and `PressEscape` (which hides every shown frame the list names, as the client's Escape does), a `GetTime` clock (`SetTime`, `Advance`), `Run`, `TakeReportedValues`, the secret probe, `NewSecret` (a secret that raises when compared, concatenated or converted), `MarkSecret` and `LoadRevision`.

| Spec | Covers |
|---|---|
| `Dialog_spec.lua` | showing, ending, the queue, keys, callbacks, the limit |
| `Arguments_spec.lua` | argument errors at the caller's line, secrets, missing host facilities |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `SharedHelpers_spec.lua` | the shared `isSecret`, `reportError` and `validateFacade` blocks, the upgrade from revision 2 |
| `Conformance_spec.lua` | the conformance suite on a mainline-profile environment |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependency |
