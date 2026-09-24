# CompatKit Tests

The CompatKit suite runs on the shared fixture. `support/CompatKitTestEnv.lua`
adds what is CompatKit's own: a profile-first loader (`NewPackageFor(profile)`)
so ClientKit reads a client flavour at its load, `LoadClientKit` and
`LoadApiKit(flavourModule)` for the two optional dependencies (on `LUA_PATH`
because the manifest names them under `optionalDependencies`; the Retail and
Classic Era flavour files install only on the `mainline` and `classic`
profiles), an `issecretvalue` stub, the allocation meter, a file reader and the
source loader the upgrade specs use. `Reset` also forgets the optional Kits' modules and the
`wow` global ApiKit publishes.

The suite covers:

- shims: a new shim recorded as pending with every record field; the highest
  version kept before `Apply` and equal or lower versions ignored; convergence
  on the newest version when an older copy, a newer copy loaded with
  `LoadSourceAtRevision` and a third older copy register the same shim; a higher
  version after `Apply` recorded but not run; the newest version's options kept;
  `SkipShim` before and after the registration, counted on every `Apply`, only
  marking a shim that already ran, dropping a skipped shim's implementation
  whichever came first, and not listing a name nothing registered;
  `GetShims` fresh, sorted, with copied arrays;
- `Apply`: name order and the counts, idempotence, zero counts, a failing shim
  isolated, reported through `geterrorhandler` unchanged and recorded, the
  `print` fallback without a handler, a raising handler falling back to `print`
  with `Apply` still usable afterwards, the read-only context and `hasGlobal` on
  plain, dotted, absent, non-table and absent-then-global paths, re-entry
  refused and the guard released, a shim registering another shim that runs on
  the next `Apply`;
- flavours: everything applied and `flavour` `false` without ClientKit; filtering
  on Retail and Classic Era clients with ClientKit, a filtered shim never run
  later, the flavour read at `Apply` so a ClientKit loaded afterwards counts, and
  a skipped shim counted before its flavour is considered;
- `hasApi` and `covers`: `false` for everything without ApiKit, with ApiKit but
  no flavour file, and on a client the Retail file does not install on; the
  installed Retail surface with documented and present, documented but absent,
  undocumented and present-but-undocumented names; the installed Classic Era
  surface on a Classic client; a later path segment never read as a global;
  `missing` recorded (and empty) with ApiKit, reset when a newer version is
  recorded after the run, `false` without ApiKit and for a shim without covers,
  not verified for skipped or filtered shims, and a flavour file loaded between
  two `Apply` calls seen by the second;
- providers: one registry per kind with the hidden prototype; `Register`
  once, `"exists"`, any non-nil implementation, `Unregister`; `Resolve` with
  nothing alive, cascade by priority whatever the registration order, ties
  broken by name, a live preferred provider whatever its priority, a dead or
  unknown preferred provider falling through, the memo re-validated by the
  probe with the probe call counts, a memoised provider unregistered, a newer
  higher priority taking over once the memo dies, a probe that raises reported
  and treated as dead, a dead provider probed once when it is both preferred
  and memoised, a raising probe reported once per `Resolve`, and a probe
  answering anything but `true` treated as dead; `List` fresh rows in cascade
  order, a raising probe listed dead and reported once;
- the catalogue: at least the nine required rows with every field, flavours
  only for rows naming a documented replacement API, drawn from
  `tooling/api/flavours.json` and sorted, distinct subsystems, read-only down
  to the flavour lists, and a row-for-row mirror of
  the table in `docs/EMBEDDING.md` (the metadata check is
  `tooling/tests/test_compat_catalogue.py`);
- allocation guards (`collectgarbage("count")` with the collector stopped) on a
  memoised `Resolve`, `Resolve` with a live, dead or unknown preferred provider,
  the cascade after the memoised provider dies, a cascade that finds nothing,
  and a repeated `Providers` lookup;
- secret values: a secret shim name, version, options table, description,
  flavours, covers, flavour, cover or option key, a secret provider kind, name,
  implementation, probe, priority or preferred name, a secret name in the
  context helpers, and a secret limit value or key, all refused at the caller
  through an `issecretvalue` stub looked up at call time;
- the limits: defaults and fresh `GetLimits` tables, `"full"` for shims and
  providers (per kind), skips waiting for their shim counted against
  `maxShims` and their slot taken over by the shim, the kinds bound raising,
  `UNBOUNDED` for all three, lowering without removing, invalid, unknown,
  secret and non-facade calls refused without changing anything;
- `error` levels: every argument (including each malformed API name shape),
  receiver and read-only-view failure reports the caller's own line, re-entry
  the line inside the shim, and a context helper failure the shim's line;
- duplicate embedded loading, Registry publication, yielding to a newer
  revision, an in-place upgrade that keeps shims, skips, providers, limits and
  the `UNBOUNDED` sentinel and rewrites the registry methods, an older copy
  after an upgrade, missing Registry, an incomplete facade and corrupted state;
- manifest/runtime API and revision consistency, the declared dependency, the
  two optional dependencies and their position after `api`.

| Spec | Covers |
|---|---|
| `Shim_spec.lua` | `Shim`, `SkipShim`, `GetShims` and version convergence |
| `Apply_spec.lua` | `Apply`, isolation, the context and re-entry |
| `Flavours_spec.lua` | `options.flavours` with and without ClientKit |
| `HasApi_spec.lua` | `context.hasApi` and `options.covers` with and without ApiKit |
| `Providers_spec.lua` | provider registries: cascade, memo, probes, listing |
| `Catalogue_spec.lua` | `CATALOGUE` shape, read-only views and the EMBEDDING.md mirror |
| `Allocation_spec.lua` | allocation guards on `Resolve` and `Providers` |
| `SecretValues_spec.lua` | secret arguments refused at the caller |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, `"full"` and `UNBOUNDED` |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, load order, corrupted state |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
