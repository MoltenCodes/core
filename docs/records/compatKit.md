# compatKit records

Moved from `docs/ROADMAP.md` (Package L — compatKit).

## compatKit

**compatKit** — facade `CompatKit`

1. Package `compatKit`, facade `CompatKit`, API generation 1.
2. Purpose (W17): named, independently versioned shims with a host opt-out
   table (TaintLess's model: the newest version of a shim wins across
   embedded copies, a shim can be skipped by name); a provider registry with
   liveness probes and a deterministic fallback cascade that output-routing
   consumers share (LibSink's model); and a documented catalogue of
   taint-hostile Blizzard subsystems with their sanctioned replacements. The
   apiKit metadata is used to state, per flavour, which documented function
   a shim covers and where it moved, so the catalogue is data, not memory.
   Non-goals: flavour detection (clientKit), rewriting Blizzard behaviour,
   the wrapper itself (apiKit).
3. Dependencies: registry API 2; clientKit API 1 optional (flavour facts),
   apiKit API 1 optional (presence checks).
4. Surface: `CompatKit:Shim(name, version, implementation)`,
   `CompatKit:SkipShim(name)`, `CompatKit:GetShims()`, `CompatKit:Apply()`;
   `CompatKit:Providers(kind)` → registry with `Register(name, implementation,
   probe, priority)`, `Resolve(preferred?)`, `List()`; `SetLimits{ maxShims,
   maxProviders }`.
5. Ownership: shims are process-wide and applied once; providers are
   memoised per kind and re-validated by their probe.
6. Performance: load-time apart from `Resolve`.
7. Tests: shim version convergence across two embedded copies, skip honoured,
   apply idempotent, cascade order, a dead preferred provider falls through,
   limits, upgrade, manifest, error levels.
8. Docs: README, API.md, CHANGELOG; the catalogue in EMBEDDING's taint
   section; EMBEDDING rows.
9. Status: implemented 2026-09-24, 0.1.0, revision 1, 114 specs; deviations
   recorded in `packages/compatKit/docs/API.md`.

