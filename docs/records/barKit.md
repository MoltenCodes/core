# barKit records

Moved from `docs/ROADMAP.md` (Package M — the user-interface phase (last, by the owner's decision)).

## barKit

**barKit** — facade `BarKit`

1. Package `barKit`, facade `BarKit`, API generation 1.
2. Purpose: status and timer bars, what LibCandyBar-3.0 gives boss-timer
   and cooldown addons and what unit-frame addons build by hand: a bar with
   a label, an icon, a value text and a colour, either showing a value
   between a minimum and a maximum (health, a resource, a cast) or counting
   a duration down with the remaining time drawn as `1:23` or `9.4`,
   pausable, with a callback when it runs out. Built on the client's
   `StatusBar`, which takes a Retail 12.x secret value (health, power) as it
   is, so a bar can show what an addon may not read. Bars come from a
   PoolKit pool, because the client never frees a frame. Non-goals: laying
   bars out in groups (an addon anchors them; WidgetKit's layouts exist),
   unit-frame logic, reading unit data.
3. Dependencies: registry API 2 and poolKit API 1, both required. Host
   requirement: `CreateFrame`, `UIParent`, `GetTime`.
4. Surface: `BarKit:Acquire(options?)` → bar (`width`, `height`,
   `texture`, `parent`); `BarKit:Release(bar)`; on a bar `SetLabel(text,
   options?)`, `SetValueText(text, options?)` (`allowSecret` for both),
   `SetIcon(texture|nil)`, `SetColor(r, g, b, a?)`, `SetBackgroundColor`,
   `SetMinMax(min, max)` and `SetValue(value)` (secrets passed through),
   `Start(duration, options?)` (`onFinished`, `fill` to fill instead of
   drain, `releaseOnFinish`), `Pause()`, `Resume()`, `Stop()`,
   `IsRunning()`, `IsPaused()`, `GetRemaining()`, `GetFrame()`;
   `SetLimits{ maxBars }` / `GetLimits()`.
5. Ownership: a bar is borrowed from `Acquire` until `Release` (or the end
   of a timer started with `releaseOnFinish`); a released bar is cleared of
   every text, icon, colour, value, timer and callback.
6. Performance and memory: a status bar runs nothing per frame; a running
   timer bar runs one `OnUpdate` that sets the fill every frame and the
   time text only when the shown text changes; a paused or stopped one runs
   nothing. `maxBars` (bars acquired at once) defaults to 64 with a ceiling
   of 512 and no `UNBOUNDED`.
7. Tests: a stand-in clock; status values and ranges, secret values passed
   to the bar untouched, labels and value texts with and without
   `allowSecret`, icon, colours; a timer draining and filling, its text
   formats, pause and resume keeping the remaining time, stop, the finished
   callback (one that raises reported), `releaseOnFinish`; pooling and
   reuse cleared; limits and the ceiling; upgrade; manifest; error levels.
   A client suite on Retail: a bar with a secret health value from the
   client, and a timer bar run to its end.
8. Docs: README (with the migration from LibCandyBar-3.0), API.md,
   CHANGELOG, tests/README; EMBEDDING rows; ARCHITECTURE's package list.
9. Status: implemented 2026-11-15 under core decision 15, 0.1.0, revision
   1, 29 specs; the client suite (`tests/client/MoltenCodesTest_BarKit`) is
   written and has not been run in a client.
   Reviewed 2026-11-15 under core decision 17: 0.1.1, revision 2, 33 specs
   (`releaseOnFinish` kept a bar restarted by `onFinished`; `ClearText`
   before plain text over a secret and on release).

