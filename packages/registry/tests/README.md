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
- the stack level of load-time versus argument errors.

Test helpers belong under `support/` and are not public package API.

All executable specs use the `*_spec.lua` suffix so Busted discovers them with its default pattern.

From the repository root, run only this package with:

```bash
python3 -m tooling.test.run registry
```
