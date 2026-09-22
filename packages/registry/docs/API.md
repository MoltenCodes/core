# Registry API

Registry API generation: **2**  
Implementation revision: **5**

Registry is a zero-dependency runtime resolver for independently embedded framework packages.

## Public runtime access

The portable World of Warcraft access path is:

```lua
local Registry = MoltenCodes.Registry
```

`Registry.lua` publishes this namespace whenever it is loaded directly by an addon TOC.

The file also returns the exact same Registry facade, which is useful in pure-Lua tests and in WoW environments where the module `require` API is available.

Code that must keep working when a future Registry API generation loads in the
same session asks for its generation by number instead:

```lua
local Registry = MoltenCodes.Registries and MoltenCodes.Registries[2] or MoltenCodes.Registry
```

See [API-generation coexistence](#registry-api-generation-coexistence) for why.

### Embedding Registry from a `.toc`

Registry has no dependencies and must be listed before every framework package
that uses it:

```toc
## Interface: 110000
## Title: My Addon
## Notes: Example of embedding MoltenCodes packages

Libs\MoltenCodes\Registry.lua
Libs\MoltenCodes\SignalKit.lua
Libs\MoltenCodes\EventKit.lua

MyAddon.lua
```

`MyAddon.lua` then resolves the packages it needs without `require`:

```lua
local Registry = MoltenCodes.Registry
local EventKit = Registry:Get("eventKit", 1)
```

Every addon lists its own bundled copies. Registry reconciles them: whichever
copy of a package carries the highest revision wins, and all addons end up
sharing that one instance.

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

API generations and revisions are positive integers no greater than `2^53`.

That upper bound is not cosmetic. Lua 5.1 numbers are doubles, which represent
consecutive integers exactly only up to `2^53`; past that boundary distinct
values start comparing equal. Without the bound, `Register("someKit", 1, 1e300)`
passed the "positive integer" test and became a revision no future embedded copy
could ever beat. Values above the bound, non-integers, `nan` and both infinities
are rejected.

Repository package manifests additionally require public framework packages to end in `Kit`; Registry itself validates identifier syntax rather than repository naming policy.

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

Registry stores one private bootstrap object in the WoW global environment, per
API generation, and publishes two public entries:

```lua
MoltenCodes.Registry        -- alias for the newest generation loaded
MoltenCodes.Registries[2]   -- this generation, always
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


## Registry API-generation coexistence

Registry is the bootstrap layer itself, so all embedded Registry copies that
share one facade must use the same Registry API generation. Compatible
implementation revisions inside that generation upgrade the shared facade in
place; an incompatible generation is never treated as an implementation
revision, because that would route callers compiled for one `Register()`
contract into a different one.

Generations are kept apart rather than rejected. Each generation owns:

- a private bootstrap-state global keyed by its own generation number, so
  registrations made through one generation are invisible to the other;
- a public entry at `MoltenCodes.Registries[<generation>]`, which is the
  documented, generation-exact access path;
- a share in `MoltenCodes.Registry`, which is an **alias for the newest
  generation currently loaded**.

### Publication rules

When `Registry.lua` for generation *G* loads:

1. It publishes itself at `MoltenCodes.Registries[G]`. If that key already holds
   a different table, the state is corrupt and loading fails.
2. If `MoltenCodes.Registry` is empty or already this facade, it claims the alias.
3. If the alias holds a generation **older** than *G*, it claims the alias and
   parks the displaced facade at `MoltenCodes.Registries[<older>]` when that key
   is free. Older generations predate this convention and would otherwise become
   unreachable.
4. If the alias holds a generation **newer** than *G*, it leaves the alias alone
   and returns normally. The copy stays fully usable through
   `MoltenCodes.Registries[G]`.
5. If the alias holds a table that claims generation *G* but is not this facade,
   loading fails: two different tables cannot both be the shared facade.

Rules 3 and 4 make the result independent of load order: whichever order the two
files load in, the newest generation owns the alias and both generations remain
reachable by number.

Loading a second generation therefore never aborts the load of the addon that
embedded the other one. That was the previous behaviour — a fatal
`MoltenCodes.Registry API generation conflict` at file scope — and it took down
an unrelated addon for no reason the user could act on.

### Migration story

A consumer written against one generation must not be handed another one. The
migration is:

1. **Today (generation 2 only).** `MoltenCodes.Registry` is generation 2.
   Existing package bootstraps read it and assert `Registry.API == 2`. Nothing
   changes.
2. **When a generation 3 ships.** Generation 3 takes the alias. Bootstraps that
   still read `MoltenCodes.Registry` and require API 2 then fail their own
   dependency check with their own error, instead of Registry aborting the load
   for them.
3. **Forward-compatible bootstrap.** Packages should resolve their generation by
   number and fall back to the alias only for copies of Registry older than
   revision 5:

   ```lua
   local generations = rawget(namespace, "Registries")
   local Registry = generations and rawget(generations, 2) or rawget(namespace, "Registry")
   ```

   This is the shape the shared `Registry:Bootstrap` helper will adopt. The
   framework packages in this repository still use the plain alias; migrating
   them is a single coordinated change rather than a per-package one.

Registry does not translate between generations. A generation-3 facade is not
routed generation-2 calls and vice versa; a package that needs both asks for
both by number.

## Error reporting

Registry raises two kinds of error, and the stack level differs on purpose.

**Argument errors** from `Register()`, `Get()` and `GetInfo()`, and corrupted
package state discovered while serving one of those calls, point at the calling
line. A package author sees their own `Registry:Register(...)` call, not a line
inside `Registry.lua`.

**Load-time failures** — incompatible or corrupted bootstrap state, a corrupted
facade, a hostile owner of `MoltenCodes` or `MoltenCodes.Registries` — raise with
level `0`, which attaches no source position, and carry an explicit `Registry:`
prefix instead:

```text
Registry: bootstrap state is incompatible
Registry: API generation is incompatible
Registry: facade is corrupted or incompatible
Registry: MoltenCodes global namespace is owned by an incompatible value
```

These run at file scope, where the only "caller" is whichever addon TOC happened
to load the file. A stack level there names an arbitrary consumer line that has
nothing to do with the failure, so the prefix carries the attribution instead.
