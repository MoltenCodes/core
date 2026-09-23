# Registry API

Registry API generation: **2**  
Implementation revision: **9**

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
## Interface: 120100, 50504, 20506, 11509
## Title: My Addon
## Notes: Example of embedding MoltenCodes packages

Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\signalKit\SignalKit.lua
Libs\MoltenCodes\eventKit\EventKit.lua

MyAddon.lua
```

Those Interface numbers are current as of 2026-09; see
[`../../../docs/EMBEDDING.md`](../../../docs/EMBEDDING.md) for the supported
flavours, the full load-order rules, and a complete example addon.

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

## `Registry:Find(packageName, api)`

Silent lookup for an optional dependency. Available from revision **7**.

```lua
local SchedulerKit, revisionOrReason = Registry:Find("schedulerKit", 1)
if SchedulerKit == nil then
    -- revisionOrReason explains the miss; carry on without the optional Kit.
end
```

On success it returns the same shared table `Get` returns, and its selected
revision. On a miss it returns `nil` and one reason from a fixed vocabulary:

| Reason | Meaning |
|---|---|
| `absent` | Nothing is registered under that package name. |
| `generation_mismatch` | The package is registered, but not under this API generation. |
| `retired` | The selected copy handed its state over during an upgrade whose migrations did not finish; the table is in no state to be used. |

`Find` never raises because a package is missing. It raises at the caller only
for malformed arguments, exactly as `Get` does, and it performs no allocation.

## `Registry:Packages()`

Diagnostic enumeration of every registration:

```lua
for _, row in ipairs(Registry:Packages()) do
    print(row.package, row.api, row.revision, row.status)
end
```

Returns a fresh array of fresh rows `{ package, api, revision, status }`, sorted
by package name and then API generation. `status` is `active`, or `retired` for
an entry `Find` would refuse. Mutating the result cannot touch Registry state.

`Packages` allocates on every call by design. It is for consoles, options pages
and debugging, never for a hot path. Available from revision **7**.

## `Registry:OnRetire(packageName, api, retire)`

Registers the hand-over hook of the revision currently selected for
`(packageName, api)`. It is the alternative to passing `request.retire` to
`Bootstrap`, for a package that only knows what to hand over once its file has
finished. It raises at the caller when the package is not registered or `retire`
is not a function. See [Retirement and migration](#retirement-and-migration).

## `Registry:Bootstrap(request)`

Performs the reconciliation every embedded package used to repeat by hand, and
returns what the package needs in order to finish.

```lua
local SignalKit, previousRevision, selected = Registry:Bootstrap({
    package = "signalKit",
    api = 1,
    revision = 3,
    label = "MoltenCodes SignalKit",
    validatePublicSurface = validatePublicSurface,
})

if SignalKit == nil then
    -- An equal or newer compatible revision already owns the package.
    return selected
end
```

Available from Registry API 2 **revision 6**. A package that calls it therefore
requires a Registry at least that new. That is not a contract change — `api` is
still 2 — but a package embedding Registry alongside its own files must keep the
documented load order, which already puts Registry first.

### Request fields

| Field | Required | Meaning |
|---|---|---|
| `package` | yes | Package identifier, as in `Register`. |
| `api` | yes | API generation this copy implements. |
| `revision` | yes | Implementation revision this copy carries. |
| `label` | yes | Prefix for the failures Registry raises on the package's behalf, for example `"MoltenCodes SignalKit"`. |
| `validatePublicSurface` | yes | `fun(implementation): boolean` — whether a table exposes the complete public API of this generation. |
| `validateState` | no | `fun(implementation): boolean` — whether a copy carrying this exact revision already committed its private state. Without it, a same-revision copy that passes `validatePublicSurface` counts as complete. |
| `resume` | no | `fun(implementation, complete): integer\|nil` — the same-revision repair hook described below. |
| `retire` | no | `fun(implementation, incomingRevision): any` — this copy's hand-over hook, called once when a newer revision replaces it. Revision 7. |
| `migrations` | no | `{ [revision] = fun(state, implementation): any }` — per-revision migration steps. Revision 7. |
| `sealFacade` | no | `boolean` — refuse new facade fields written from outside the package. Revision 7. |

### Return values

| Value | Meaning |
|---|---|
| `implementation` | The shared package table to initialize, or `nil` when there is nothing to do. |
| `previousRevision` | `nil` for a first registration, otherwise the revision whose state this copy inherits, exactly as `Register` reports it. |
| `selected` | The copy Registry has selected. This is what the package returns when `implementation` is `nil`. |
| `state` | What the outgoing copy handed over, after every migration step has transformed it. `nil` when nothing was handed over. |

### What it decides

In order:

1. **Nothing registered yet** — registers this revision and hands back a fresh
   shared table with `previousRevision = nil`.
2. **A newer compatible revision is registered** — validates only its public
   surface and yields to it. A newer revision owns its own private state schema,
   so an older copy must never reinterpret it.
3. **This exact revision is registered** — validates the public surface, then
   asks `validateState` whether that copy finished. A complete copy is returned
   unchanged; an incomplete one is a corruption error unless `resume` says
   otherwise.
4. **An older revision is registered** — asks the older copy to retire, then
   registers this one over it, runs the migration steps between the two
   revisions and reports the inherited revision. The older copy is deliberately
   *not* held to this revision's public surface: it is about to be replaced, and
   the package validates whatever it inherits itself.

| Situation | Retire hook | Migrations | Returns |
|---|---|---|---|
| Nothing registered | — | none | fresh table, `nil`, `nil`, `nil` |
| Newer revision registered | — | none | `nil`, `nil`, newer copy |
| Same revision, complete | — | none | `nil`, `nil`, that copy |
| Same revision, `resume` returns `n` | — | steps after `max(n, last step run)`, or after the last completed step of an unfinished run | that copy, `n`, that copy, migrated state |
| Older revision `p` registered | outgoing hook, once (not again while a run is unfinished) | steps in `(max(p, last step run), revision]`, or after the last completed step of an unfinished run | shared table, `p`, older copy, migrated state |

### The `resume` hook

Some packages install shared runtime state that a failed earlier bootstrap can
leave half-built — host event watchers, a dispatch table other objects call
through. For those, "Registry already accepted this revision" does not imply
"this revision finished".

`resume` runs only in case 3, receives the selected copy and whether it looks
complete, and returns either `nil` to accept the copy as it is, or the revision
to inherit so the package re-runs its own setup against the existing shared
table. It may also raise on state it judges unrepairable.

### Reading Registry forward-compatibly

A package resolves Registry by generation before it can call `Bootstrap`:

```lua
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, 2) or nil
if Registry == nil and type(namespace) == "table" then
    Registry = rawget(namespace, "Registry")
end
```

`MoltenCodes.Registry` is an alias for the newest generation loaded, so an
eventual API 3 takes it over. Asking for `Registries[2]` first is what keeps an
API-2 package working in that session; the alias remains the fallback for a
Registry old enough to predate the `Registries` table.

### Registry does not use it

Registry is the file that publishes the facade `Bootstrap` lives on, so its own
bootstrap has to run before any facade method exists. It stays hand-written.

## Retirement and migration

Revision 7 turns "the incoming copy guesses from `previousRevision`" into a
two-sided contract.

**The outgoing side.** A copy that registered a `retire` hook — through
`request.retire` or `Registry:OnRetire` — is asked to retire exactly once, when
a newer revision replaces it, and *before* the newer revision registers, so the
hook still sees the state it owns. It receives the shared table and the incoming
revision, drains what it must (disconnect host watchers, cancel work), and
returns whatever state it wants carried forward. A hook belongs to the revision
that registered it: an upgrade through the raw `Register` primitive discards it,
so it can never be handed a newer copy's table.

A retire hook that raises is reported through the host error handler
(`geterrorhandler()`, or `print` outside the client) and the upgrade continues
from no hand-over rather than from a half-drained one.

**The incoming side.** `request.migrations` maps a revision to the step that
converts state from the previous layout to that revision's. Registry runs the
steps in `(inherited revision, this revision]` in ascending order. Each step
receives the current state and the shared table and returns the state for the
next step; returning `nil` keeps the current state, which suits a step that
mutates in place. Steps outside the range are ignored, because an earlier copy
already ran them, and a skipped range is applied cumulatively.

**Exactly once.** Registry records the last step that ran for each entry. A copy
that resumes over state an earlier copy of the same revision already migrated
starts after that record, not after the revision it believes it inherits, so no
step runs twice. A step that raises stops the run, is raised at the package's
`Bootstrap` call as `<label> migration to revision <n> failed: <error>`, and
leaves the entry `retired` (see `Find`) until a copy completes the run.

**An unfinished run is resumed, not skipped.** While a run is unfinished,
Registry keeps the state the last completed step produced (the hand-over itself
when no step completed). The next copy to bootstrap — a newer revision or a
same-revision `resume` — starts after the last *completed* step rather than
after the revision it inherits, receives that kept state, and does not ask the
outgoing copy to retire a second time. So when revision 2 fails at step 2, a
revision-3 copy runs steps 2 and 3 once each, over the state revision 1 handed
over. A failing step must therefore leave the state it was given reusable: a
step that mutates in place and raises halfway hands a half-converted state to
the retry. The kept state is released when a run completes.

**The raw primitive does not finish a run.** `Registry:Register` knows nothing
about retirement: an upgrade through it over a `retired` entry changes the
revision but leaves the entry `retired` — and `Find` refusing it — until a copy
completes the run through `Bootstrap`. Kits upgrade through `Bootstrap`.

**Retired entry points.** The facade table is shared and never replaced, so once
the incoming copy has installed its methods, every reference the outgoing copy
handed out resolves to the new ones. The same holds for instances as long as the
package keeps its prototype tables stable and replaces methods on them in place,
which every Kit does; `docs/ARCHITECTURE.md` "How a Kit bootstraps" states that
rule. What the shared table cannot reach are closures the outgoing copy captured
privately — host frame scripts, timers, callbacks registered elsewhere. Those are
what the retire hook exists to release.

Registry does not migrate saved variables, and there is no downgrade path.

## Sealed facades

`request.sealFacade = true` installs a metatable on the shared table whose
`__newindex` raises at the writer's line:

```text
MyAddon.lua:12: MoltenCodes DemoKit facade is sealed; field "Extra" cannot be added from outside the package
```

The package itself writes through `rawset` during bootstrap and upgrade, which a
metatable does not see, so upgrades keep mutating the facade. Reads, `rawget`
and `pairs` are unchanged: the fields stay on the table itself.

Limits, stated plainly:

- Lua 5.1 has no metamethod for assignments to a field that already exists, so a
  seal refuses **new** fields — a misspelled method, a monkey-patched addition —
  but cannot stop an addon from overwriting `EventKit.Connect`. Doing that would
  need a proxy table, which would break `rawget` and `pairs` over the facade.
- It guards against mistakes, not malice: `rawset` and `setmetatable` still work.
- Each sealing revision installs a fresh seal, so a refusal names the label of
  the revision that sealed the facade most recently.
- Registry refuses to seal a facade that already carries a metatable it did not
  install, and a newer revision that does not ask for the seal removes the one
  Registry installed, because the newer revision owns the facade's policy.

The seal is opt-in in API 2. It is intended to become the default in a later
Registry API generation. No `Unseal` method exists, by design.

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

Registry validates package buckets and entries lazily when they are accessed. If private package state is malformed, `Register()`, `Get()`, `GetInfo()`, `Find()`, `OnRetire()` and `Packages()` fail consistently with a Registry corruption error at the calling line rather than returning partial or invalid data. `Packages()` validates every entry it lists, so a malformed one is never reported as a row.

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

   Every framework package in this repository resolves Registry this way
   before it calls `Registry:Bootstrap`; see
   [Reading Registry forward-compatibly](#reading-registry-forward-compatibly).

Registry does not translate between generations. A generation-3 facade is not
routed generation-2 calls and vice versa; a package that needs both asks for
both by number.

## Error reporting

Registry raises two kinds of error, and the stack level differs on purpose.

**Argument errors** from `Register()`, `Get()`, `GetInfo()`, `Find()` and
`OnRetire()`, and corrupted package state discovered while serving one of those
calls or `Packages()`, point at the calling line. A package author sees their own `Registry:Register(...)` call, not a line
inside `Registry.lua`. Failures `Bootstrap` raises on a package's behalf — a
refused state, a failed migration step, a seal that cannot be applied — carry
the package's `label` and point at the package's `Bootstrap` call.

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
