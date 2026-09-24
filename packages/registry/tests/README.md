# Registry Tests

The Registry suite covers:

- bootstrap and duplicate embedding;
- direct TOC-style file loading;
- public `MoltenCodes.Registry` exposure;
- package and API isolation;
- revision selection and load-order behavior;
- stable package-table identity across upgrades;
- metadata snapshots;
- runtime API/revision consistency with `package.manifest.json`;
- input validation;
- test-environment isolation;
- bootstrap/facade corruption and metatable hardening;
- API-generation coexistence, alias ownership in both load orders, and
  generation-private bootstrap state;
- the stack level of load-time versus argument errors;
- silent lookup (`Find`) and the diagnostic listing (`Packages`);
- retirement hand-over, per-revision migrations and their exactly-once record;
- sealed facades.

Spec files:

| File | Covers |
|---|---|
| `Registry_spec.lua` | API generation and revision, the `MoltenCodes` namespace and alias owners, direct loading, reload identity, the explicit bootstrap state |
| `Registration_spec.lua` | first registration, in-place upgrade, lower and equal revisions, package and API isolation, unknown lookups |
| `LoadOrder_spec.lua` | highest revision wins whatever the order, one stable implementation table, equal-revision races |
| `Metadata_spec.lua` | `GetInfo` snapshots: fresh tables, no shared mutable state, stability across upgrades |
| `Validation_spec.lua` | package-name, API and revision validation, argument errors at the calling line, no entry on failure |
| `Corruption_spec.lua` | corrupted buckets and entries rejected consistently and at the caller's line, `Packages` refusing malformed state |
| `Generations_spec.lua` | API-generation coexistence, alias ownership in both load orders, generation-private bootstrap state |
| `Bootstrap_spec.lua` | `Registry:Bootstrap`: fresh tables, inherited revisions, yielding to newer copies, resume hooks and their return values, argument and refusal errors at the package's `Bootstrap` call |
| `Find_spec.lua` | `Find` (absent, different generation, retired-unfinished, argument errors, no allocation, `Get` included) and `Packages` snapshots |
| `Retirement_spec.lua` | retire hooks and `OnRetire`, per-revision migrations run exactly once, failed steps, the in-place upgrade from the previous Registry revision |
| `Seal_spec.lua` | sealed facades: refused writes at the writer's line, `rawset` upgrades, removal, foreign metatables |
| `RegistryTestEnv_spec.lua` | the test environment's own reset and isolation |
| `Manifest_spec.lua` | runtime API and revision against `package.manifest.json` |

Test helpers belong under `support/` and are not public package API.

All executable specs use the `*_spec.lua` suffix so Busted discovers them with its default pattern.

From the repository root, run only this package with:

```bash
python3 -m tooling.test.run registry
```
