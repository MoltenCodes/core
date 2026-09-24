# ApiKit API

ApiKit API generation **1** publishes the flavour namespaces of the generated
World of Warcraft API wrapper, detects the running client's flavour and installs
the matching generated bindings. The wrapper surface itself
(`api.<namespace>.<function>`) is data: the generated reference, attached to
every release and built locally with `tooling.api.generate --reference-out`,
describes it per flavour, and the rules that name it are in
[`NAMING.md`](NAMING.md).

```lua
local ApiKit = MoltenCodes.Registries[2]:Get("apiKit", 1)
```

## Public surface

| Member | Returns | Purpose |
|---|---|---|
| `GetFlavor()` | `"retail" \| "classic-era" \| "classic-mop" \| "ptr" \| "beta" \| "unsupported"` | The running client's flavour, read once at load. |
| `GetGlobalStatus()` | `"published" \| "taken"` | Whether the short `wow` global names `MoltenCodes.wow`, read at the time of the call. |
| `RegisterFlavor(flavor, install, info?)` | `boolean` | The entry point every generated flavour file calls; see below. |
| `GetMetadataBuild(flavor)` | `string?, integer?` | The client version and build the registered metadata of `flavor` was captured from; nothing when no file registered. |
| `SUPPORTED_FLAVORS` | `string[]` | Read-only view of the flavour ids, in table order; index from 1 to `SUPPORTED_FLAVOR_COUNT`. |
| `SUPPORTED_FLAVOR_COUNT` | `integer` | How many ids the view holds. |

`API` and `REVISION` are published on the facade as integers. The namespace
root is `MoltenCodes.wow`, with one `api` table per flavour at
`retail`, `classic.era`, `classic.mop`, `ptr` and `beta`; the same table is
the `wow` global when that name was free at load. `SUPPORTED_FLAVORS` is a
read-only view: on Lua 5.1 `#` and `ipairs` do not see through it, so walk it
by index up to `SUPPORTED_FLAVOR_COUNT`.

## Flavour detection

The flavour is derived once, when the facade loads, from three host facts:

| Flavour | `WOW_PROJECT_ID` | `IsTestBuild()` | `IsBetaBuild()` |
|---|---|---|---|
| `retail` | `1` | false | false |
| `classic-era` | `2` | false | false |
| `classic-mop` | `19` | false | false |
| `ptr` | `1` | true | false |
| `beta` | `1` | true | true |

A probe the client does not have counts as `false`; a beta client counts as a
test build whatever `IsTestBuild()` says; a probe that raises stops the
facade's load with that error, as ClientKit's unprotected host calls do. A
client matching no row (a Burning Crusade Classic client, a client without
`WOW_PROJECT_ID`) is `"unsupported"`: its namespaces stay empty and every
registration is dropped. The probe runs on every bootstrap, an in-place
upgrade included, so a newer revision that knows a further flavour recognises
its client. The table is the one in `tooling/api/flavours.json`; a spec holds
the two together.

## `RegisterFlavor(flavor, install, info?)`

```lua
ApiKit:RegisterFlavor("retail", function(api, host)
    -- generated: api.addOnProfiler.measureCall = host.C_AddOnProfiler.MeasureCall ...
end, { version = "12.1.0", build = 69933 })
```

`flavor` is a supported flavour id, `install` a function receiving the
flavour's `api` table and the host global table, `info` an optional table with
the metadata's `version` (string) and `build` (integer). The installer runs at
once, and only, when `flavor` is the running flavour and nothing has installed
it yet; the method returns whether it ran. A registration for another flavour
costs nothing beyond the call. A second registration of the running flavour
(two addons embedding the same file) is dropped; the first file to load wins,
and its `info` is what `GetMetadataBuild` reports. `info` is recorded for every
flavour, installed or not, first registration winning.

An error raised by the installer propagates to the generated file's load, so a
broken generated file is loud rather than half-installed and silent. Before it
propagates, the flavour's `api` table is emptied and the registration and its
`info` are forgotten, so the next copy to load (another addon's working file)
installs from a clean table. Unknown `info` fields are ignored, so a file from
a newer generator still registers.

Generated files call this method; an addon may call it to install a surface of
its own for a flavour ApiKit ships no file for.

## `MoltenCodes.wow`

The namespace root is written into the framework's `MoltenCodes` table at the
first registration. A value already there that is not ApiKit's root is
corruption of the framework's own namespace, and the load stops with
`MoltenCodes ApiKit found MoltenCodes.wow owned by something else`; the short
`wow` global, which another addon may legitimately own, is never overwritten
and never raises.

## The raw API stays

Every wrapper entry is the Blizzard function itself, so a protected function
called through `api` behaves exactly as when called directly, including the
taint rules in [`EMBEDDING.md`](../../../docs/EMBEDDING.md#taint). Calling the
raw API remains valid at all times; the wrapper adds discoverability, naming
and types, never a layer.

## Errors

Argument and receiver failures are raised at the caller's line:

| Message | Cause |
|---|---|
| `ApiKit:<Method> must be called on the ApiKit facade` | Called with another receiver. |
| `ApiKit:<Method> flavor must be one of retail, classic-era, classic-mop, ptr, beta` | Unknown flavour id. |
| `ApiKit:RegisterFlavor install must be a function` | |
| `ApiKit:RegisterFlavor info must be a table when given` | |
| `ApiKit:RegisterFlavor info.version must be a string when given` | |
| `ApiKit:RegisterFlavor info.build must be an integer when given` | |
| `ApiKit.SUPPORTED_FLAVORS is read-only; index "<key>" cannot be written` | |

Load-time failures: `MoltenCodes ApiKit requires Registry API 2 to be loaded
first`, `MoltenCodes ApiKit requires a valid Registry API 2 facade`,
`MoltenCodes ApiKit package state is corrupted or incomplete`, `MoltenCodes
ApiKit found MoltenCodes.wow owned by something else`. A generated flavour
file raises `MoltenCodes ApiKit (<Flavour> bindings) requires Registry API 2
to be loaded first`, `... requires a valid Registry API 2 facade` or `...
requires ApiKit API 1 to be loaded first` when it loads out of order.

## Limits

ApiKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`
(design constitution, principle 4a). What it retains is fixed at load: the
five namespace tables, the installed flavour's bindings (one table per
Blizzard namespace, one entry per function) and the `info` of each registered
flavour. Nothing grows with use.

## Load cost

Measured on the committed Retail file (client 12.1.0, build 69933; 9,824
lines, 556 KB) with Lua 5.1.5 on a 2026 desktop, so the numbers are an order
of magnitude, not a promise:

| Step | Cost |
|---|---|
| Parsing the flavour file | about 3.5 ms |
| Running the installer (391 namespaces, 6,338 bindings) | under 0.5 ms |
| Retained by the installed surface | about 316 tables holding 6,000 function references |
| A flavour file on a client of another flavour | its parse and one registration call; the installer is dropped |

A call through the wrapper is one table index more than the raw call and
allocates nothing. Nothing in the package grows with use.

## Embedded identity and upgrades

ApiKit registers with Registry as package `apiKit`, API generation 1. When two
addons embed different revisions, Registry keeps the newest copy and hands it
the older one's state: the namespace tables, the installed flavours and their
`info` survive an in-place upgrade, and a flavour file that registered before
the upgrade is not run again.
