# ApiKit API

ApiKit API generation **1** publishes the flavour namespaces of the generated
World of Warcraft API wrapper, detects the running client's flavour and installs
the matching generated bindings. The wrapper surface itself
(`api.<namespace>.<function>`) is data: the generated reference under
`reference/<flavour>/` describes it per flavour once a flavour's capture is
committed, and the rules that name it are in [`NAMING.md`](NAMING.md).

```lua
local ApiKit = MoltenCodes.Registries[2]:Get("apiKit", 1)
```

## Public surface

| Member | Returns | Purpose |
|---|---|---|
| `GetFlavor()` | `"retail" \| "classic-era" \| "classic-mop" \| "ptr" \| "beta" \| "unsupported"` | The running client's flavour, read once at load. |
| `GetGlobalStatus()` | `"published" \| "taken"` | Whether the short `wow` global names `MoltenCodes.wow`. |
| `RegisterFlavor(flavor, install, info?)` | `boolean` | The entry point every generated flavour file calls; see below. |
| `GetMetadataBuild(flavor)` | `string?, integer?` | The client version and build the registered metadata of `flavor` was captured from; nothing when no file registered. |
| `SUPPORTED_FLAVORS` | `string[]` | Read-only list of the flavour ids, in table order. |

`API` and `REVISION` are published on the facade as integers. The namespace
root is `MoltenCodes.wow`, with one `api` table per flavour at
`retail`, `classic.era`, `classic.mop`, `ptr` and `beta`; the same table is
the `wow` global when that name was free at load.

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
test build whatever `IsTestBuild()` says. A client matching no row (a Burning
Crusade Classic client, a client without `WOW_PROJECT_ID`) is `"unsupported"`:
its namespaces stay empty and every registration is dropped. The table is the
one in `tooling/api/flavours.json`; a spec holds the two together.

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
broken generated file is loud rather than half-installed and silent; the
flavour is then marked installed and not retried.

Generated files call this method; an addon may call it to install a surface of
its own for a flavour ApiKit ships no file for.

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
`MoltenCodes ApiKit package state is corrupted or incomplete`. A generated
flavour file raises `MoltenCodes ApiKit (<Flavour> bindings) requires ApiKit
API 1 to be loaded first` when it loads before the facade.

## Limits

ApiKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`
(design constitution, principle 4a). What it retains is fixed at load: the
five namespace tables, the installed flavour's bindings (one table per
Blizzard namespace, one entry per function) and the `info` of each registered
flavour. Nothing grows with use.

## Embedded identity and upgrades

ApiKit registers with Registry as package `apiKit`, API generation 1. When two
addons embed different revisions, Registry keeps the newest copy and hands it
the older one's state: the namespace tables, the installed flavours and their
`info` survive an in-place upgrade, and a flavour file that registered before
the upgrade is not run again.
