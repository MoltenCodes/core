# InteropKit API

InteropKit API generation **1** is the bridge between the MoltenCodes Registry
and LibStub: it exposes Kits to LibStub consumers and adopts LibStub libraries
as read-only foreign entries.

```lua
local InteropKit = MoltenCodes.Registries[2]:Get("interopKit", 1)
```

## Public surface

| Method | Returns | Purpose |
|---|---|---|
| `IsLibStubPresent()` | `boolean` | Whether a global `LibStub` table with `NewLibrary` and `GetLibrary` is loaded. |
| `ExposeToLibStub(packageName, api, major?)` | `true, major` or `false, reason[, registryReason]` | Make a Kit's facade the LibStub library under `major`. |
| `ExposeAll(options?)` | `exposed, skipped, refused` | Expose every active package `Registry:Packages()` lists. |
| `AdoptFromLibStub(major)` | `library, minor` or `nil, reason` | Read a LibStub library and record it. |
| `Find(major)` | `library, minor` or `nil, "unknown"` | Read a recorded adoption. Allocation-free. |
| `Adopted()` | `{ { major, minor }, ... }` | Every adoption, sorted by major. Fresh array per call. |

`API` and `REVISION` are published on the facade as integers.

LibStub is read through `rawget(_G, "LibStub")` on every call, so it may load
before or after InteropKit. Everything here is load-time work; no method is
meant for a per-frame path, and none needs tearing down.

## Results and reasons

A refusal is a result, never an error. Errors are reserved for malformed
arguments (see [Errors](#errors)).

| Reason | Returned by | Meaning |
|---|---|---|
| `"absent"` | `ExposeToLibStub`, `AdoptFromLibStub` | LibStub is not loaded (`IsLibStubPresent()` is `false`). |
| `"unknown"` | `ExposeToLibStub` | Registry has no usable entry for `(packageName, api)`. The third result is Registry's own reason from `Registry:Find`: `"absent"`, `"retired"` or `"generation_mismatch"`. |
| `"unknown"` | `AdoptFromLibStub` | LibStub holds no library under `major`. |
| `"unknown"` | `Find` | `major` was never adopted. |
| `"taken"` | `ExposeToLibStub` | Another library already holds `major`. |
| `"unsupported"` | `ExposeToLibStub` | The loaded LibStub does not keep the `libs` and `minors` tables every released LibStub keeps, or records them inconsistently. |

## `ExposeToLibStub(packageName, api, major)`

- `packageName` is a Registry package identifier (`"eventKit"`), `api` its API
  generation.
- `major` defaults to `"MoltenCodes-" .. Facade .. "-" .. api`, where `Facade`
  is the package identifier with its first letter upper-cased: `eventKit`
  becomes `"MoltenCodes-EventKit-1"`, `registry` with `api` 2 becomes
  `"MoltenCodes-Registry-2"`.
- The minor is the Kit's implementation revision, as `Registry:Find` reports
  it.
- `registry` is resolved through `MoltenCodes.Registries[api]`, because
  Registry is not an entry of its own package table.

The call is idempotent: exposing a Kit that already holds `major` at its
current revision or a newer one returns `true, major` and changes nothing.
After a newer revision of the Kit upgrades it in place, exposing it again
raises the minor LibStub records to the new revision. The facade is the same
table, so LibStub consumers holding it already see the new methods; the higher
minor only keeps LibStub's bookkeeping truthful and makes LibStub refuse an
older copy of the same major.

### What the bridge does to LibStub

This is the complete list of what `ExposeToLibStub` and `ExposeAll` do to
LibStub's tables:

1. They read `LibStub.libs[major]` and `LibStub.minors[major]`. When
   `libs[major]` holds a table that is not the Kit's facade, the call returns
   `false, "taken"` **before LibStub is called**. Calling `NewLibrary` first
   would already raise the foreign library's recorded minor, so the foreign
   library, its table and its minor are never touched.
2. When `libs[major]` is empty, or holds the facade at a lower minor, they call
   `LibStub:NewLibrary(major, revision)`. LibStub records the minor itself, the
   usual way.
3. On a first exposure LibStub has just created an empty table for `major`.
   The bridge writes the Kit's facade into `LibStub.libs[major]` in its place,
   so `LibStub(major)`, `LibStub:GetLibrary(major)` and
   `LibStub:IterateLibraries()` all return the shared facade. **This single
   `rawset` into `LibStub.libs` is the only place InteropKit writes into
   LibStub's internals.** It is guarded: when `LibStub.libs` or
   `LibStub.minors` is not a table, or `NewLibrary` did not record the table it
   returned, the call returns `false, "unsupported"` and writes nothing.

InteropKit never lowers a minor, never removes an entry (LibStub entries are
permanent by LibStub's design), never writes into a library it adopts, and
never replaces the global `LibStub`.

A LibStub consumer that calls `LibStub:NewLibrary` on an exposed major with a
higher minor would be handed the Kit's facade to "upgrade". Nothing prevents
that inside LibStub; do not choose a `major` that another library's code also
creates.

## `ExposeAll(options)`

Exposes every row of `Registry:Packages()` whose status is `"active"`, under
its default major, and returns three counts:

- `exposed` — rows now exposed, including rows that already were;
- `skipped` — rows named in `options.except` or not active;
- `refused` — rows `ExposeToLibStub` would refuse for any reason, including
  LibStub being absent.

`options.except` is an array of package identifiers. Registry itself is not a
`Packages()` row; expose it explicitly with `ExposeToLibStub("registry", 2)`.
InteropKit's own row is exposed like any other; name `"interopKit"` in
`options.except` to leave it out.

## `AdoptFromLibStub(major)`, `Find(major)` and `Adopted()`

`AdoptFromLibStub` asks `LibStub:GetLibrary(major, true)` — the silent form, so
a missing library never raises — and returns the library table and its minor.
The pair is recorded in InteropKit's package state; adopting the same major
again refreshes the recorded minor after the library upgraded itself.

`Find(major)` returns the recorded library and minor, or `nil, "unknown"`. It
answers from the record, so it keeps working if the global `LibStub` is later
replaced, and it allocates nothing. The minor is the one recorded at the last
adoption. The library table is LibStub's own and upgrades in place, so the
table stays current even when the recorded minor does not.

`Adopted()` returns a fresh array of fresh `{ major = string, minor = number }`
rows sorted by major, for consoles and options pages.

Adopted libraries are read-only to InteropKit: it never writes into them,
never upgrades them and never registers them with LibStub again.

## Secret values

On a client with secret values, a `packageName`, `api` or `major` that
`issecretvalue` reports secret, including a package name inside
`ExposeAll`'s `options.except`, is refused at the caller before it is compared,
matched or formatted. Absence of an optional argument is tested with `type`, so
not even a comparison with `nil` runs first:

```text
MyAddon/Core.lua:12: InteropKit:AdoptFromLibStub major must not be a secret value
```

## Errors

Argument errors name the method and the parameter and point at the caller's
line:

| Message | Cause |
|---|---|
| `InteropKit:<Method> packageName must be a non-empty string` | `packageName` (or an `options.except` entry) is not a string, or is empty. |
| `InteropKit:<Method> packageName must match ^[a-z][A-Za-z0-9]*$` | Not a Registry package identifier. |
| `InteropKit:ExposeToLibStub api must be a positive integer` | `api` is not a positive integer up to 2^53. |
| `InteropKit:<Method> major must be a non-empty string` | `major` is not a string, or is empty. |
| `InteropKit:<Method> <parameter> must not be a secret value` | See [Secret values](#secret-values). |
| `InteropKit:ExposeAll options must be a table or nil` | `options` has another type. |
| `InteropKit:ExposeAll options.except must be an array of package names` | `options.except` is not a table. |

Bootstrap failures raise at the line that loaded the file:

| Message | Cause |
|---|---|
| `MoltenCodes InteropKit requires Registry API 2 to be loaded first` | `Registry.lua` is missing or loaded after this file. |
| `MoltenCodes InteropKit requires a valid Registry API 2 facade` | The published Registry lacks `Bootstrap`, `Find` or `Packages`. |
| `MoltenCodes InteropKit package state is corrupted or incomplete` | The shared package state was modified from outside. |

## Limits

InteropKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`. The one table it retains is the adoption record, one entry per LibStub major passed to `AdoptFromLibStub`, and a major is recorded only when LibStub already holds that library; adopting it again overwrites the same entry. The record therefore never outgrows the libraries loaded into the client. `ExposeToLibStub` and `ExposeAll` write into LibStub's own tables, bounded by the Kits Registry holds.

## Embedded identity and upgrades

InteropKit bootstraps through `Registry:Bootstrap` like every Kit (see
[`docs/ARCHITECTURE.md`](../../../docs/ARCHITECTURE.md#how-a-kit-bootstraps)).
The facade and its `_state`, including the adoption records, keep their
identity across compatible revisions: a newer copy rewrites the facade methods
in place and reuses the records, so adoptions made through an older copy stay
readable through `Find`. An older copy loading after a newer one yields to it.
Exposures live in LibStub, not in InteropKit's state, and are unaffected by an
InteropKit upgrade. Revision 2 keeps the revision 1 state as it is and
replaces the methods only.

`_state` is private; its layout is not part of the contract.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **Adopted libraries are not Registry entries.** The plan recorded an
  adoption in the Registry, readable through `Registry:Find("libstub:" ..
  major, 1)` and listed by `Registry:Packages()` with status `"foreign"`.
  Registry refuses any package name outside `^[a-z][A-Za-z0-9]*$`, so
  `"libstub:..."` would need a second naming rule in `Find`, `Packages`,
  `GetInfo` and the row type, and `Registry.lua` has almost none of its
  1000-line budget left. The header of `Registry.lua` says such a change moves into
  a package of its own, so the lookup lives here as `InteropKit:Find(major)`
  with the same silent contract (`library, minor` or `nil, reason`), and the
  listing as `InteropKit:Adopted()`. Registry is unchanged.
- **Every refusal of `ExposeToLibStub` returns `false`**, not `nil`, for
  `"taken"` and `"unsupported"` as well as `"absent"`: one boolean contract is
  easier to test than two falsy values.
- **`ExposeToLibStub` returns the major on success** (`true, major`), so a
  caller relying on the default knows the name to publish; and it returns
  `"unknown"` plus Registry's reason when the package is not found, because
  Registry's `"absent"` would collide with LibStub being `"absent"`.
- **Refusal happens before LibStub is called** when a foreign library holds
  the major, rather than after `NewLibrary` returned a foreign table: calling
  `NewLibrary` with a higher minor would already mutate LibStub's record of
  that library.
- **`ExposeAll` returns three counts** (exposed, skipped, refused) and counts
  every row as refused when LibStub is absent, rather than returning a reason.
- **Additions:** `Find(major)` and `Adopted()` (see the first item);
  `ExposeToLibStub("registry", api)`.
