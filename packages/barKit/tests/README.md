# BarKit Tests

The BarKit suite covers:

- bars: a shown status bar at its default size, texture and colours, size, texture and parent from the options, a status value in its range with label, value text, icon at the bar's height and colours, the icon and label cleared, secret values and ranges passed to the status bar untouched, a secret text refused without `allowSecret` and drawn with it, and a released bar cleared, refused and its frame handed out again;
- timers: draining with the time text, hours, minutes and tenths, filling, `onFinished` once at zero with ticking stopped, an `onFinished` that raises reported, `releaseOnFinish` after `onFinished`, pause and resume keeping the time left, `Stop` and a second `Start` without the callback, `SetValue` and `SetMinMax` stopping a timer, and a text set by hand kept until the time text changes;
- arguments, limits and secrets: every argument failure reported at the caller's line, the limit refusing at the caller and freed by `Release`, secret options, numbers, colours, limits and receivers refused, and a host without `UIParent`;
- Registry publication, a duplicate embedded load keeping bars, yielding to a newer revision, an in-place upgrade keeping bars, the pool and the limit while a timer started before it finishes with the new code, a refusal of state holding an invalid limit, missing Registry or PoolKit, and an incomplete facade;
- manifest/runtime API and revision consistency, and the declared dependencies.

`support/BarKitTestEnv.lua` provides `UIParent`, a `GetTime` clock (`SetTime`, and `Advance`, which also runs a frame's `OnUpdate`), `TakeReportedValues`, the secret probe and `LoadRevision`. The shared frame stub models the `StatusBar` type.

| Spec | Covers |
|---|---|
| `Bar_spec.lua` | acquiring, status values, texts, icon, colours, release |
| `Timer_spec.lua` | `Start`, the time text, `Pause`, `Resume`, `Stop`, `onFinished` |
| `Arguments_spec.lua` | argument errors at the caller's line, the limit, secrets |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
