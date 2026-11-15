# lifecycleKit records

Moved from `docs/ROADMAP.md` (Package O — memory, performance and ease of use (decisions 18 and 19)).

## lifecycleKit (package O): the probe rule and the halted field as a record field

**lifecycleKit (package O): the probe rule and the halted field as a record field** — a change to facade `LifecycleKit`

1. Package `lifecycleKit`, facade `LifecycleKit`, API generation 1,
   version 0.6.9 (from 0.6.8, internal fix and documentation), implementation
   revision 18 (from 17).
2. Purpose: the LifecycleKit side of the moduleKit fix F3 in
   the decision 18 diagnosis (section lifecycleKit
   and moduleKit) and package O's probe rule.
   - **`_halted` becomes a documented, stable generation-1 field of an
     instance.** ModuleKit reads it on every enable instead of calling
     `IsHalted` twice. It is exact because LifecycleKit writes
     `_halted = true` before it notifies anyone (`LifecycleKit.lua:1973`),
     and every instance gets `_halted = false` at creation (`:674`). An
     instance of a revision older than the halted state has no field and
     reads as not halted, which is what it is. INTERNALS-level promise in
     API.md: the field is written only by LifecycleKit, is `true` from the
     moment the halt begins, and keeps its name and meaning for API 1.
   - **Probe rule.** `isSecret` (`:344`) reads `rawget(_G,
     "issecretvalue")` on every call today. It resolves it once at load and
     falls back to the per-call read, accepted only as a function, when it
     was absent at load.
   - **Decision 19b candidate.** `describeKey` (`:358`) checks a caller
     table's key for a secret before naming it; a table cannot be indexed
     with a secret key on Retail 12.1.0 (`docs/EMBEDDING.md`). The check
     stays until the client suite proves a secret key cannot be written
     either (see the schedulerKit record, point 7), then goes.
   Non-goals: any change to phases, halts, the combat gate or their costs.
3. Dependencies: unchanged, registry API 2, signalKit API 1, eventKit API 1.
4. Surface: no new methods. API.md documents the `_halted` field as above.
5. Ownership: unchanged.
6. Performance and memory: one global read and one `type` fewer per secret
   check in the client; nothing on the bench host, which has no probe. The
   ModuleKit gain the field enables is in the moduleKit record (about 22
   instructions per halt check, twice per enable). No bytes change.
7. Tests: a probe installed after load is honoured; `_halted` is `true`
   inside the first halt listener and before `OnHalted` subscribers run;
   in-place upgrade from revision 17 keeps instances, phases and halts.
8. Docs: API.md (the field, under "Halted state"), CHANGELOG, tests/README.
9. Status: implemented 2026-11-15 under core decisions 18 and 19, 0.6.9,
   revision 18, 202 specs.

