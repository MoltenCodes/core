# Changelog

## 0.1.2 — 2026-11-18

- Fixed: a host error handler that raises (an error-display addon with a bug) turned the report of a timer's `onFinished` that failed into a second error, raised into the client's script call. `reportError` is now the shared helper block (`tooling/shared/lua/reportError.lua`): it calls the handler under `pcall` and prints the failure when the handler is missing or raises. Spec: `SharedHelpers_spec.lua` ("prints ... when the host error handler raises").
- `isSecret` and `validateFacade` are now the shared helper blocks too, kept in step by `python3 -m tooling.shared.sync`. The secret check takes the probe rule: `issecretvalue` is read once at load and asked directly, about 50 ns less per check on the host; only a host that had no probe at load reads the global again on each check. A probe that replaces the one present at load is no longer asked. Refusal messages are unchanged.
- Implementation revision 3; an embedded revision 2 is upgraded in place, keeping what it made.
- New specs: `SharedHelpers_spec.lua` (the probe rule, the facade message, the raising handler, the upgrade over the committed revision 2 file in `tests/fixtures/BarKit-revision2.lua`) and `Conformance_spec.lua` (the repository's conformance suite; its limits group is pending, see the spec).

## 0.1.1 — 2026-11-15

Implementation revision 2. Bars acquired by revision 1 are taken over in place.

- Fixed: `releaseOnFinish` released a bar that its `onFinished` had started again, so a repeating timer lost its bar and its handle at the first run-out. The bar is now released only when no timer runs after `onFinished`. Spec: `Timer_spec.lua`, "keeps a bar that onFinished started again, releaseOnFinish or not".
- Fixed: a label or value text that had shown a secret (`allowSecret`) kept the client's secret text aspect through a plain `SetText` and through a release, so the next plain text on that font string, in the same use or a later borrower's, read back as a secret (the client's behaviour as measured for WidgetKit on Retail 12.1.0). BarKit now empties such a font string with `ClearText` before it draws a plain text there, the timer's time text included, and on every release. Spec: `Bar_spec.lua`, "makes a text plain again after a secret, in the same use and the next".
- Documentation: `docs/API.md` lists every error message, says that a timer on a hidden bar finishes only once shown (the client runs `OnUpdate` only for shown frames), what `onFinished` may do, which secret aspects the client keeps, and the `ClearText` host facility; the README says the same in short.
- Specs: an `onFinished` that releases its bar and acquires another, the upgrade of a revision 1 record, and more argument cases (`Start` options, `SetMinMax` maximum, `height`, secret option keys, flags, parent and `Release` argument). The test environment gained `ModelSecretTextAspect`. 33 specs.
- Client suite: the plain status test runs before the secret one, which now also checks that a reused bar's label reads plainly and logs whether a reused frame's value stays secret; the released bar's value text may read `nil` or `""`.

## 0.1.0 — 2026-11-15

- Added BarKit API generation 1, implementation revision 1: status and timer bars, as recorded in `docs/ROADMAP.md` (package M).
- `BarKit:Acquire(options?)` with `width`, `height`, `texture` and `parent`; `BarKit:Release`; `SetLimits` and `GetLimits` for `maxBars` (64, up to 512).
- A bar: `SetLabel` and `SetValueText` (with `allowSecret`), `SetIcon`, `SetColor`, `SetBackgroundColor`, `SetMinMax` and `SetValue` passing secret values to the client's `StatusBar` untouched, `Start` with `onFinished`, `fill` and `releaseOnFinish`, `Pause`, `Resume`, `Stop`, `IsRunning`, `IsPaused`, `GetRemaining`, `GetFrame`.
- Bars come from a PoolKit pool that keeps every released frame; a release clears every text, icon, colour, value, timer and callback.
- 29 specs, and a client suite, `tests/client/MoltenCodesTest_BarKit`, not yet run in a client.
