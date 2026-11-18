# Registry

Registry is the zero-dependency runtime package resolver at the bottom of the MoltenCodes WoW framework.

Its purpose is to let independently distributed addons embed framework packages while preserving one shared package instance for each `(package, API generation)` pair.

## Guarantees

For each `(package, API generation)` pair:

- the highest registered revision is selected;
- lower and equal revisions are rejected;
- the selected package table is created once and never replaced;
- a newer revision upgrades that same table in place;
- consumers holding an older reference therefore continue to observe the active package instance;
- separate packages are independent;
- separate API generations are independent;
- malformed private package state is rejected consistently instead of being exposed as valid data.

Registry itself also survives duplicate embedding. Every compatible Registry copy in API generation 2 shares one internal bootstrap state and one facade table. A newer compatible Registry revision upgrades that facade in place.

Different Registry API generations never share a facade, but they do coexist. Each generation keeps its own bootstrap state and publishes itself at `MoltenCodes.Registries[<generation>]`; `MoltenCodes.Registry` is an alias for the newest generation loaded. Loading a second generation therefore cannot abort the load of the addon that embedded the other one. See [`docs/API.md`](docs/API.md) for the publication rules and the migration story.

## World of Warcraft access

Registry publishes its facade as:

```lua
MoltenCodes.Registry        -- newest Registry API generation loaded
MoltenCodes.Registries[2]   -- this API generation, always
```

This is the portable runtime access path for addons loaded through TOC files and does not require WoW's module `require` API.

For pure-Lua tests and environments where module loading is available, `Registry.lua` also returns the same facade table.

## Package initialization

A package asks Registry for permission to initialize a revision:

```lua
local Registry = MoltenCodes.Registry

local EventKit, previousRevision = Registry:Register("eventKit", 1, 7)
if EventKit == nil then
  return
end

EventKit.Dispatch = function(self, eventName)
  -- revision 7 implementation
end
```

The first accepted revision receives a new shared table and `previousRevision == nil`.

A higher revision receives the exact same table plus the previously active revision. Equal and lower revisions receive `nil` and must stop initialization.

## Runtime cost

Registry has no runtime package dependencies.

`Get()` and `Find()` perform table lookups only and allocate nothing. `GetInfo()` intentionally allocates a metadata snapshot so callers cannot mutate Registry-owned metadata, and `Packages()` allocates a sorted listing for diagnostics. Retirement, migration and sealing run at load time only.

Registry is a core and two optional parts (revision 17 and later): `Handover`
holds retire hooks, migration steps, sealed facades and `OnRetire`;
`Diagnostics` holds `GetInfo` and `Packages`. No Kit needs either, so the core
is what every addon loads: 26.5 KB resident with debug information kept
(revision 16, one file: 32.3 KB; LibStub: 2.6 KB), measured as `docs/API.md`
*Performance* describes. The core's budget is at most 600 code lines,
counted by `tests/Budget_spec.lua`.

## Moving from LibStub

| LibStub | Registry |
|---|---|
| `LibStub:NewLibrary(major, minor)`: the library table and the previous minor, or `nil` when an equal or newer minor is loaded | `Registry:Register(packageName, api, revision)`: the same contract, keyed by a package name and an API generation instead of a major string; `Registry:Bootstrap(request)` adds state validation, retirement and migrations |
| `LibStub("Name")`, `LibStub:GetLibrary("Name")`: raises when the library is missing | `Registry:Get(packageName, api)`: `nil` when nothing is registered, never raises for a missing package |
| `LibStub:GetLibrary("Name", true)`: the silent lookup | `Registry:Find(packageName, api)`: `nil` and a reason (`absent`, `generation_mismatch`, `retired`) |
| `LibStub.minors[major]` | the second return of `Get` or `Find`, or `Registry:GetInfo(packageName, api).revision` (`Diagnostics` part) |
| `LibStub:IterateLibraries()` | `Registry:Packages()`, a sorted diagnostic listing (`Diagnostics` part) |
| a new major string (`"MyLib-2.0"`) for a breaking change | a new API generation: `Registry:Register("myKit", 2, revision)` |

Code that must still reach a Kit through LibStub, or adopt a LibStub library,
uses InteropKit (`ExposeToLibStub`, `AdoptFromLibStub`); see
[`docs/MIGRATING_FROM_ACE3.md`](../../docs/MIGRATING_FROM_ACE3.md#libstub).

## Documentation

- [`docs/API.md`](docs/API.md) — complete public contract and upgrade semantics.
- [`CHANGELOG.md`](CHANGELOG.md) — package evolution.
- [`tests/README.md`](tests/README.md) — behavior covered by the test suite.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\registry\parts\Registry-Handover.lua      # only for retire, migrations, sealFacade, OnRetire
Libs\MoltenCodes\registry\parts\Registry-Diagnostics.lua   # only for GetInfo, Packages
```

Minimum footprint: embed 1 file: `registry/Registry.lua`. A part loads after
the core; without it, each of its members raises at the caller's line naming
the file to add, and `Registry:HasPart(name)` answers `false`.

No runtime dependencies. Registry is the bootstrap layer, so it is the
first MoltenCodes file every addon loads.
