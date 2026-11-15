# Changelog

## 0.1.0 — 2026-11-15

- Added BarKit API generation 1, implementation revision 1: status and timer bars, as recorded in `docs/ROADMAP.md` (package M).
- `BarKit:Acquire(options?)` with `width`, `height`, `texture` and `parent`; `BarKit:Release`; `SetLimits` and `GetLimits` for `maxBars` (64, up to 512).
- A bar: `SetLabel` and `SetValueText` (with `allowSecret`), `SetIcon`, `SetColor`, `SetBackgroundColor`, `SetMinMax` and `SetValue` passing secret values to the client's `StatusBar` untouched, `Start` with `onFinished`, `fill` and `releaseOnFinish`, `Pause`, `Resume`, `Stop`, `IsRunning`, `IsPaused`, `GetRemaining`, `GetFrame`.
- Bars come from a PoolKit pool that keeps every released frame; a release clears every text, icon, colour, value, timer and callback.
- 29 specs, and a client suite, `tests/client/MoltenCodesTest_BarKit`, not yet run in a client.
