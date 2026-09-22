# Changelog

## 0.1.1

- Made existing addon lifecycle subscriptions upgrade-safe through shared runtime dispatch and migrated revision-1 subscriptions without replacing addon/container identity.
- Added same-revision bootstrap recovery for incomplete runtime dispatch state.
- Preserved hard-dependency invariants when non-terminal `DisableAll()` encounters a dependent disable failure.
- Made terminal shutdown perform best-effort cleanup even when an inactive late module leaves the full graph invalid.
- Rejected late module definitions that would retroactively place a new module before an already-initialized module.
- Restricted targeted initialize/enable validation to the relevant hard-dependency closure so unrelated invalid modules do not block independent targeted operations.
- Tightened definition-table validation: unknown fields and sparse/mixed dependency arrays are rejected deterministically.
- Improved module-scoped provider cycle tracking so the same provider can legitimately resolve for different requesting modules during nested resolution.
- Strengthened public-surface, lifecycle-subscription, and requesting-module validation.

## 0.1.0

- Added addon-scoped module containers integrated with LifecycleKit.
- Added `automatic` and `strict` dependency policies.
- Added hard, optional, and ordering-only dependency graph constraints.
- Added deterministic topological initialization, enable, and reverse disable ordering.
- Added value, singleton, module-scoped, and transient dependency injection providers.
- Added provider-cycle and module-cycle detection with human-readable diagnostics.
- Added late-module activation and definition-table catch-up support.
- Added module failure/blocking diagnostics without permanent failed states.
