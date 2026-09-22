# MoltenCodes WoW Framework Roadmap

> Canonical development roadmap for the MoltenCodes WoW framework.
>
> This document is intentionally kept inside the repository so that project
> planning does not depend on chat history or external notes.

## Status

The framework is developed incrementally as small, reusable packages. Public
framework packages follow the Apple-like `Kit` convention:

- package IDs use **lowerCamelCase** (for example, `signalKit`)
- Lua/runtime facades use **PascalCase** (for example, `SignalKit`)
- `registry` / `Registry` is the infrastructure exception

Performance is a first-class requirement. New packages must minimize CPU time,
allocations, garbage-collector pressure, and retained memory. Caches and pools
must be bounded by default. Explicit developer opt-in escape hatches may relax
those defaults when they are documented and observable.

## Completed foundation

- [x] `registry`
- [x] `signalKit`
- [x] `eventKit`
- [x] `lifecycleKit`
- [x] `moduleKit`
- [x] `schedulerKit`
- [x] `timerKit`
- [x] `poolKit`

These entries describe packages present in this repository snapshot. A checked
item means its implementation is part of the repository; it does not mean the
package can never receive further optimization, fixes, or API refinement.

## Ongoing framework work

- [ ] Continue expanding the framework one focused Kit at a time.
- [ ] Keep public APIs documented and version-aware.
- [ ] Add regression tests for every fixed defect.
- [ ] Preserve deterministic lifecycle and ownership semantics.
- [ ] Preserve bounded-by-default retention, caching, scheduling, and pooling.
- [ ] Keep hot paths allocation-conscious and avoid unnecessary table/function creation.
- [ ] Maintain explicit cleanup and teardown paths for long-lived runtime objects.
- [ ] Keep package dependencies minimal, explicit, and acyclic.
- [ ] Maintain manifest, Registry key, package ID, and runtime facade naming consistency.
- [ ] Keep LuaLS/LuaCATS-facing documentation useful for autocomplete and editor tooling.
- [ ] Validate behavior against supported World of Warcraft environments as packages evolve.
- [ ] Keep CI, linting, formatting, repository validation, and test tooling current.

## Planned package policy

Future Kits should be added to this section **when their scope and name are
accepted**, before or together with implementation. Each planned Kit should
record:

1. package ID and runtime facade name;
2. purpose and non-goals;
3. dependencies;
4. public API surface;
5. lifecycle/ownership model;
6. performance and memory constraints;
7. test plan;
8. documentation requirements;
9. implementation status.

This prevents speculative package names from becoming accidental architecture.

## Definition of done for a Kit

A Kit is considered complete for its initial release when:

- [ ] its responsibility and boundaries are documented;
- [ ] its manifest and Registry integration are correct;
- [ ] its public API follows framework naming and documentation conventions;
- [ ] normal, error, edge-case, re-entrant, and teardown paths are reviewed;
- [ ] ownership and lifecycle behavior are explicit;
- [ ] retained state is bounded by default where applicable;
- [ ] performance-sensitive paths avoid unnecessary allocation and work;
- [ ] escape hatches are explicit, documented, and observable where applicable;
- [ ] automated tests cover core behavior and regressions;
- [ ] repository validation passes;
- [ ] package documentation and changelog are current.

## Roadmap maintenance

`docs/ROADMAP.md` is the canonical roadmap in repository artifacts. Whenever a
Kit is added, completed, renamed, split, or removed, this file should be updated
in the same change. Architecture decisions belong in the architecture/design
documents; this roadmap tracks sequencing and delivery status rather than
duplicating those specifications.

---

Last roadmap baseline update: 2026-09-22.
