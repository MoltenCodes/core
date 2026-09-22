# Registry API

Registry API generation: **2**  
Implementation revision: **4**

Registry is a zero-dependency runtime resolver for independently embedded framework packages.

## Public runtime access

The portable World of Warcraft access path is:

```lua
local Registry = MoltenCodes.Registry
```

`Registry.lua` publishes this namespace whenever it is loaded directly by an addon TOC.

The file also returns the exact same Registry facade, which is useful in pure-Lua tests and in WoW environments where the module `require` API is available.

## Package identity

A registration is identified by:

```text
(package name, API generation)
```

The revision is the implementation ordering value within that API generation.

Package names use the same naming rule as package manifests:

```text
^[a-z][A-Za-z0-9]*$
```

API generations and revisions are positive integers. Repository package manifests additionally require public framework packages to end in `Kit`; Registry itself validates identifier syntax rather than repository naming policy.

## `Registry:Register(packageName, api, revision)`

Requests initialization rights for a package revision.

When the revision is accepted, Registry returns:

```lua
sharedPackageTable, previousRevision
```

`previousRevision` is `nil` for the first accepted revision.

When an equal or newer revision is already active, Registry returns `nil`. The caller must stop initialization and must not modify an independently created package table.

### Selection rules

1. The first revision for a `(package, API)` pair is accepted.
2. A higher revision is accepted.
3. A lower revision is rejected.
4. An equal revision is rejected.
5. The shared package table is never replaced.

### Stable-reference guarantee

A higher revision receives the same package table used by earlier revisions. It upgrades that table in place.

This means a consumer that previously cached:

```lua
local EventKit = Registry:Get("eventKit", 1)
```

continues to reference the active package instance after a later revision is accepted.

This behavior is essential for embedded libraries because different addons can load their bundled copies at different times.

### Upgrade example

```lua
local EventKit, previousRevision = Registry:Register("eventKit", 1, 9)
if EventKit == nil then
    return
end

if previousRevision ~= nil and previousRevision < 8 then
    -- Migrate shared package state if revision 9 requires it.
end

function EventKit:Dispatch(eventName)
    -- revision 9 implementation
end
```

Registry API generation 2 does not accept the API-1 development contract that supplied an `implementation` argument. Package code initializes the returned shared table instead. Incompatible Registry API generations must not share one Registry facade.

## `Registry:Get(packageName, api)`

Returns:

```lua
sharedPackageTable, selectedRevision
```

Both values are `nil` when no implementation has been registered.

The call performs no allocation.

```lua
local EventKit, revision = Registry:Get("eventKit", 1)
```

## `Registry:GetInfo(packageName, api)`

Returns a metadata snapshot:

```lua
{
    package = "eventKit",
    api = 1,
    revision = 9,
    implementation = EventKit,
}
```

Returns `nil` when no implementation has been registered.

Every call returns a new metadata table. Mutating metadata fields cannot modify Registry-owned metadata.

`implementation` intentionally points at the live shared package table. Changes made by an accepted package upgrade are therefore visible through that reference.

## Registry constants

```lua
Registry.API
Registry.REVISION
```

`API` identifies the Registry API generation. `REVISION` identifies the Registry implementation revision.

## Embedded Registry copies

Registry stores one private bootstrap object in the WoW global environment and one public facade at:

```lua
MoltenCodes.Registry
```

Compatible embedded copies reuse both the bootstrap state and facade. Loading another compatible copy therefore does not create an isolated registry.

A newer Registry implementation revision replaces methods on the existing facade rather than replacing the facade itself.

The private bootstrap key is implementation detail and must not be read or written by consumers.

Registry validates package buckets and entries lazily when they are accessed. If private package state is malformed, `Register()`, `Get()`, and `GetInfo()` fail consistently with a Registry corruption error rather than returning partial or invalid data.

Bootstrap-state and facade integrity checks use raw table access. Metatable hooks on corrupted or foreign tables cannot synthesize Registry-owned fields or intercept an in-place facade upgrade.

## Load-order semantics

For different package revisions, the highest revision wins regardless of registration order.

Equal revisions deliberately use first-initializer-wins semantics: the first copy initializes the shared table and later equal copies are rejected.

Packages must never publish behaviorally different code under the same package/API/revision identity.

## Package-author rule

The shared package table returned by `Register()` is the package identity. Package authors must update it in place and must not replace it with another table.

Registry does not clear that table before an accepted upgrade. A newer package revision is responsible for overwriting changed members and explicitly removing members that no longer belong to the implementation. This allows package-owned runtime state to be migrated deliberately instead of being destroyed by Registry.

Private state that must survive upgrades should also be designed for in-place migration, using `previousRevision` when necessary. Package initialization should complete synchronously after an accepted registration; Registry records the accepted revision before package initialization code runs.

Registry cannot roll back arbitrary mutations made by package initialization. If initialization raises an error after registration is accepted, the shared table can remain partially updated at the accepted revision. Package authors should therefore keep initialization deterministic, validate failure-prone inputs before mutating the shared table, and perform explicit migration carefully when upgrading existing state.


## Registry API-generation compatibility

Registry is the bootstrap layer itself, so all embedded Registry copies participating in one public `MoltenCodes.Registry` facade must use the same Registry API generation. Compatible implementation revisions within that generation may upgrade the shared facade in place.

An incompatible Registry API generation is rejected explicitly rather than being silently treated as an implementation revision. This prevents callers compiled for one `Register()` contract from being routed to a different contract.
