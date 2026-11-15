# ClientKit Tests

The ClientKit suite runs against the shared fixture's client profiles
(`tests/support/framework/ClientStub.lua`): one per supported flavour —
`mainline`, `mists`, `tbc`, `classic` — plus `noProjectId`, a host that
publishes no `WOW_PROJECT_ID` and no `GetBuildInfo`. `ClientKitTestEnv.NewPackageFor(profile)`
selects one and loads Registry and ClientKit against it.

The suite covers:

- flavour and build per profile, with each interface number checked against
  `tooling/validation/supported_clients.json`;
- the absent-project-id trap: an absent id yields `"classic"`, interface `0`,
  and never every capability at once; an unknown, non-number or
  constant-less id is handled by value;
- `IsAtLeast` boundaries, including the cross-flavour ordering it does not
  promise;
- the capability table flag by flag for every profile, a host that exposes
  nothing, flags probed from the host rather than the flavour, unknown and
  secret names, and zero allocation after bootstrap;
- `IsSecret` with the `issecretvalue` stub and without it; `CanAccessFrame`
  for forbidden, context-restricted, unrestricted and method-less frames;
  `IsEventValid` for a known, an invalid and an unknowable name;
- every shim on modern and legacy hosts and on a host with neither;
- `GetManifest`: every snapshot field on all four profiles (the `C_AddOns`
  form and the legacy globals), locale-suffixed `Title`/`Notes` before the
  plain ones and no suffixed read without a locale, list fields split into
  arrays with the raw strings behind `Get`, `RequiredDeps` as the second
  spelling of `Dependencies`, the host's dependency calls as the fallback
  list source, `X-` fields through `Get` with the host asked once per field,
  absent fields not remembered, a field the client refuses reading as absent,
  the same snapshot on every call, an unknown addon (`GetAddOnInfo` reason
  `"MISSING"`) answering `nil, "unknown"` without any `Title` read and never
  being cached even after fifty unknown names, names matched case-insensitively with one record and
  the host's spelling in `name`, a host without `GetAddOnInfo` recognising an
  addon by its `Title` and keeping the caller's spelling, a host with neither
  metadata call answering `nil, "unavailable"`, secret names and fields
  refused, writes refused at the writer's line, a cache holding one record per
  listed addon, and zero allocation for a cached manifest;
- `error` levels: every argument failure, secret refusal (`IsAtLeast`, `Has`,
  `GetManifest`, `Get`), receiver with a secret `name` refused by `Get`, and
  manifest write reports the caller's own line;
- Registry publication, duplicate loads, a newer revision not being
  downgraded, an in-place upgrade that re-reads the host into the same state
  tables (a copy of the source loaded with a higher revision), an upgrade
  over a revision 1 layout that adds the locale and the manifest tables, an
  upgrade over a revision 2 layout that keeps the manifest cache, an upgrade
  from a revision 3 package and from the previous revision (6) to the working file
  that keeps state, capabilities and cached manifests (whose `Get` then refuses
  a receiver with a secret `name`), the deprecation mode, reporter and
  reports and an `IsAtLeast` that then refuses a secret, a cached
  manifest keeping its identity and its rewritten `Get` across an upgrade,
  load-order failures, and corrupted-state refusal on a reload and on an
  upgrade, including a `manifests` or `manifestPrototype` that is not a table;
  an upgrade over a revision 5 layout that adds the deprecation state and
  keeps cached manifests, reporters, once-keys, reports, the mode and the
  limits kept across an upgrade with `Warn` rewritten in place, and
  deprecation state of the wrong shape refused on a reload and on an upgrade;
- deprecation warnings: one report per call site through the host error
  handler and none for a repeated call from the same site, two sites
  reported twice, one report per addon named by the Kit with `debugstack`
  read once per addon, a report without a replacement, an explicit level
  from a helper, fresh report rows, a name declared again returning the
  same reporter with the newer text, nothing held until a Kit deprecates
  something, and no allocation for a repeated warning of a known addon;
  the addon and location named from each frame form (bracketed, `[string
  "@..."]`, bare path with backslashes, with the client's `...` line), a
  frame outside `Interface/AddOns/`, an empty or blank answer, a host
  without `debugstack`, and a secret frame line; `print` on a host without
  `geterrorhandler`, a failing handler that never raises, and a handler that
  warns again from inside a report; the three
  modes, `"raise"` at the consumer's line on every call with and without a
  site; limits (defaults, subsets, ceilings, refusals that change nothing,
  a secret limit name, the inert reporter and its one notice, silent mode,
  `maxReports` stopping call-site reads); malformed and secret spec fields,
  levels, addon names and receivers; the optional-Kit pattern with
  ClientKit loaded, absent, and at revision 5 without the methods;
- manifest/runtime API and revision consistency.

| Spec | Covers |
|---|---|
| `Flavor_spec.lua` | flavour, build, interface number, `IsAtLeast` |
| `Capabilities_spec.lua` | `Has`, the capability table, allocation guard |
| `Taint_spec.lua` | `IsSecret`, `CanAccessFrame`, `IsEventValid` |
| `Shims_spec.lua` | `GetSpellInfo`, `GetItemInfo`, `GetAddOnMetadata`, `IsAddOnLoaded` |
| `GetManifest_spec.lua` | `GetManifest`, the snapshot fields, locale fallback, `Get`, caching |
| `Deprecation_spec.lua` | `Deprecate`, `Warn`, call sites, modes, reports, limits, the optional-Kit pattern |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, upgrades, load order, corrupted state |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement |

`support/ClientKitTestEnv.lua` selects a client profile, builds frame doubles
for `CanAccessFrame` and loads the source at a patched revision for the
upgrade specs; `NewHostFor(profile, options)` prepares the same host as
`NewPackageFor` without loading ClientKit, so an upgrade spec can load an
older revision first. It also installs the host functions only ClientKit reads and
the shared fixture does not stub: `GetLocale` (`NewPackageFor(profile, {
locale = "deDE" })`, `false` for a host without it) and `GetAddOnInfo` with
the two dependency-list calls (`RegisterAddOn(name, { dependencies,
optionalDependencies })`; `{ addOnInfo = false }` for a host without them),
placed in `C_AddOns` when the profile has that table and as legacy globals
otherwise. `GetAddOnInfo` models the real call: an unknown name is echoed
back with the reason `"MISSING"`, never raised for, and names are matched
case-insensitively. The profile's metadata call is wrapped so
`MetadataReads(addon, field)` counts what the host was asked,
`RefuseMetadataField(field)` models a client that raises for a field it does
not export, and a registered addon is found under any spelling of its name.
`{ secretStrings = { ... } }` makes the profile's `issecretvalue` report
those strings (or numbers) secret. `{ debugStack = { addon, form, more, answer } }` installs a
`debugstack` stand-in that answers the frame at the level asked, numbered as
the client numbers it, from Busted's `debug.getinfo`, so a report names the
spec's real line; `form` picks the bracketed form the Retail client writes,
the `[string "@..."]` form or a bare path, `more` adds the client's `...`
line, `answer` replaces the frame (a chunk outside `Interface/AddOns/`, a
secret), and `DebugStackCalls()` counts the calls. Without the option the
host has no `debugstack`.
