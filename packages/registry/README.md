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

`Get()` performs table lookups only and allocates nothing. `GetInfo()` intentionally allocates a metadata snapshot so callers cannot mutate Registry-owned metadata.

## Documentation

- [`docs/API.md`](docs/API.md) — complete public contract and upgrade semantics.
- [`CHANGELOG.md`](CHANGELOG.md) — package evolution.
- [`tests/README.md`](tests/README.md) — behavior covered by the test suite.
