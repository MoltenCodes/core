# InteropKit Tests

The InteropKit suite runs on the shared fixture with a LibStub stand-in that
`InteropKitTestEnv.InstallLibStub()` publishes and `Reset` removes. The stand-in
has LibStub's semantics, written independently: `libs`, `minors`,
`NewLibrary` with the digit extraction from string minors, `GetLibrary` with
the `silent` flag, `IterateLibraries` and the `__call` form.

Two environments are built in `support/InteropKitTestEnv.lua`:

- the default one loads Registry and InteropKit;
- `InteropKitTestEnv.Kits` also loads SignalKit and EventKit with `loadfile`
  from their repository paths, the way a `.toc` loads them, because neither is
  a dependency of InteropKit and the runner does not put them on `LUA_PATH`.

The suite covers:

- `IsLibStubPresent` with no LibStub, a LibStub without its methods, and a
  real one;
- `ExposeToLibStub`: the default major, `LibStub(major)` and `GetLibrary`
  returning the facade, the minor taken from the revision, LibStub's own
  iteration, an explicit major, idempotence, LibStub refusing an equal minor
  afterwards, re-exposure with a higher minor after an in-place upgrade, a
  foreign major refused without touching the foreign library or its minor,
  an unknown package or generation with Registry's reason, Registry itself,
  and a LibStub that lacks `libs` and `minors` or records inconsistently;
- `ExposeAll` against real Kits: counts, `LibStub("MoltenCodes-EventKit-1")`
  returning the EventKit facade, `options.except`, a foreign major counted as
  refused, idempotence, LibStub absent, and EventKit upgraded in place and
  exposed again with the higher minor, and Registry's message naming its
  Diagnostics part when that part is absent;
- adoption: absent LibStub, an unknown major, string minors, `Find` before and
  after adoption and after LibStub is gone, refreshing the recorded minor, no
  writes into LibStub or the library, the sorted and fresh `Adopted()` listing,
  and an allocation guard on `Find`;
- secret values: a secret `major`, `packageName` or `api`, and a secret package
  name in `options.except`, refused at the caller;
- `error` levels: every argument failure reports the caller's own line,
  including every `Find` refusal on its inlined checks;
- Registry publication, duplicate loads, a newer revision not being
  downgraded, an in-place upgrade that keeps adoptions (the source loaded with
  its revision raised by one), revision 1 and revision 2 copies upgraded with
  the current file, load-order failures, and corrupted-state refusal;
- the shared `isSecret` block: the probe kept from load when the global is
  replaced, a probe installed after load asked, and the in-place upgrade over
  the committed revision 3 file (`fixtures/InteropKit-revision3.lua`);
- the repository conformance suite (`tests/support/KitConformance.lua`):
  manifest, arguments and upgrade; limits and receivers are pending, with the
  reason in the spec;
- manifest/runtime API and revision consistency.

| Spec | Covers |
|---|---|
| `Expose_spec.lua` | `IsLibStubPresent` and `ExposeToLibStub` |
| `ExposeAll_spec.lua` | `ExposeAll` against real Kits |
| `Adopt_spec.lua` | `AdoptFromLibStub`, `Find` and `Adopted` |
| `SecretValues_spec.lua` | secret arguments refused at the caller |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, load order, corrupted state |
| `SharedHelpers_spec.lua` | the shared `isSecret` block, the upgrade from revision 3 |
| `Conformance_spec.lua` | the conformance suite on a mainline-profile environment |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement |
