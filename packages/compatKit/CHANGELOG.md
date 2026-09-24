# Changelog

## 0.1.2 — 2026-09-24

- Implementation revision 2, applying the repository rule for values CompatKit did not create: their absence is tested with `type`, never with `== nil`, and a secret is never compared. A provider probe's answer is checked with `issecretvalue` before it is compared with `true`: only `true` still counts as alive, and a secret answer counts as dead instead of raising inside `Resolve` or `List`. `hasGlobal` tests the host value with `type`, so a global holding a secret is reported present. The facade check tests the receiver's type before comparing it with the facade, so a secret receiver raises `CompatKit:<Method> must be called on the CompatKit facade; use CompatKit:<Method>(...)` at the caller's line. `Shim` options, `Register`'s `implementation`, `probe` and `priority`, `Resolve`'s `preferred` and `SetLimits` test absence with `type`. Behaviour for every non-secret value is unchanged.
- The state layout is unchanged; a new bootstrap spec loads revision 1, fills its state (an applied shim, a skip, providers with a probe, a raised limit) and checks that revision 2 takes it over in place. The upgrade specs load the next revision as `REVISION + 1`.
- New specs: a probe answering a secret, `hasGlobal` over a secret global, a secret receiver, and the upgrade from the previous revision; a ClientKit flavour that is not a string, ApiKit without its namespace root, a failure escaping the per-shim isolation (the guard still released), the `MoltenCodes.Registry` alias, a shared table missing a method or the catalogue, limits that are not a table and an upgrade over an unknown schema. 126 specs.

## 0.1.1 — 2026-09-24

- Documentation and tests only; implementation revision 1 is unchanged. `docs/API.md`: the limits table is whole again (a paragraph had been inserted between its rows) and says what each limit bounds. The README's first example names the resolved provider `output` rather than `print_`.
- The test environment no longer claims to own `IsTestBuild` and `IsBetaBuild`, which nothing in the suite installs, and keeps the source path private; `tests/README.md` is rewrapped.

## 0.1.0 — 2026-09-24

- Added CompatKit API generation 1, implementation revision 1: shims, provider registries and the catalogue of taint-hostile subsystems.
- `Shim(name, version, implementation, options?)` records a named, integer-versioned shim; before `Apply` the highest version registered wins across embedded copies, after `Apply` a higher version is recorded but not run. Returns `true` with `"pending"`, `"replaced"` or `"recorded"`, or `false` with `"ignored"` (equal or lower version) or `"full"` (the `maxShims` limit). Options: `description`, `flavours` (ClientKit flavour ids the shim applies to), `covers` (documented API names checked against ApiKit's installed surface at apply time).
- `SkipShim(name)` marks a shim never to run, before or after its registration, dropping a pending implementation; a skipped shim still lists. Returns `true`, or `false, "full"` for a name without a shim when the shims plus the skips waiting for theirs reach `maxShims`.
- `Apply()` runs every pending shim that is not skipped and that applies to the client, in name order, each under `pcall`; a failing shim is reported through the host error handler (itself called under `pcall`, with `print` as the fallback), recorded as `failed`, and does not stop the others. Returns the applied, skipped and failed counts of that call; a second call runs only shims registered since. Every shim receives a read-only context `{ flavour, hasApi, hasGlobal }`.
- `GetShims()` returns fresh, name-sorted records `{ name, version, applied, skipped, failed, status, description, flavours, covers, missing }`.
- `Providers(kind)` returns one registry per kind with `Register(name, implementation, probe?, priority?)` (`true`, or `false` with `"exists"` or `"full"`), `Unregister(name)`, `Resolve(preferred?)` (`implementation, name` or `nil, "none"`: a live preferred provider, else the memoised answer re-validated by its probe, else the highest-priority live provider with ties broken by name; allocation-free) and `List()`.
- `SetLimits{ maxShims, maxProviders, maxProviderKinds }` (defaults 64, 32, 32; each accepts `CompatKit.UNBOUNDED`; `maxShims` counts skips waiting for their shim) and `GetLimits()`.
- `CATALOGUE` and `CATALOGUE_COUNT`: the read-only catalogue of taint-hostile subsystems, mirrored from `docs/EMBEDDING.md`, each row with `subsystem`, `reason`, `replacement`, `replacementApi`, `flavours` and `flavourCount`.
- Argument errors name the method and parameter and point at the caller's line; a secret name, version, priority, implementation, option or limit is refused before it is compared or formatted.
