# logKit records

Moved from `docs/ROADMAP.md` (Package K — logKit).

## logKit

**logKit** — facade `LogKit`

1. Package `logKit`, facade `LogKit`, API generation 1.
2. Purpose: levelled, structured logging for addons and Kits with lazy
   formatting (arguments are formatted only when a sink is listening at that
   level), per-addon loggers with a tri-state override (addon, global,
   default), a bounded in-memory journal readable after the fact (built on
   SignalKit's journal), and sinks: chat frame, the journal, a callback; the
   sink contract ProfileKit reports can share. Non-goals: log files (the
   client has none), remote shipping, a viewer window (UI phase).
3. Dependencies: registry API 2, signalKit API 1; commandKit API 1 optional
   (`/log <addon> <level>`), settingsKit API 1 optional (persisting the
   per-addon level).
4. Surface: `LogKit:ForAddon(addonName)` → logger with `Trace`, `Debug`,
   `Info`, `Warn`, `Error`, each `(message, ...)` formatted lazily, and
   `logger:SetLevel(level)`, `logger:GetLevel()`, `logger:IsEnabled(level)`;
   `LogKit:SetGlobalLevel(level|nil)`; `LogKit:AddSink(sink)` /
   `RemoveSink`; `LogKit:History(addonName?)` → iterator over the journal;
   `SetLimits{ journalCapacity, maxSinks, maxMessageLength }`.
5. Ownership: loggers are per addon and live for the session; sinks are
   removed by their handle; the journal is a ring.
6. Performance: a disabled level costs one comparison; formatting happens
   once per enabled message; secret values are never formatted.
7. Tests: level gating, lazy formatting (the formatter is not called when
   disabled), override precedence, journal ring order, sinks and their
   removal, secret-safe formatting, limits, upgrade, manifest, error levels.
8. Docs: README, API.md, CHANGELOG; EMBEDDING rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 144 specs; deviations
   recorded in `packages/logKit/docs/API.md`.

