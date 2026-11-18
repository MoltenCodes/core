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

## Loading

Load `Registry.lua`, then `ApiKit.lua`, then the generated flavour files
(`flavours/*.lua`); a flavour file loaded before ApiKit raises (see [Error
behaviour](#error-behaviour)). ApiKit reads the client identity
(`WOW_PROJECT_ID`, `IsTestBuild`, `IsBetaBuild`) once at load and
`issecretvalue` once at load; a host that had no `issecretvalue` then reads
the global again on each check.

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

Both probes are documented functions of the Retail client (`IsTestBuild` and
`IsBetaBuild` in its `Build` tables at build 69933), which is the only client
whose project id needs them: the build facts are consulted for Retail's
project id alone, because only Retail's test realm and beta builds are
flavours of their own. A Classic Era or Mists test realm client runs its
Classic flavour's surface. A probe the client does not have counts as
`false`; a beta client counts as a test build whatever `IsTestBuild()` says; a probe that raises stops the
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
end, { version = "12.1.5", build = 70783 })
```

`flavor` is a supported flavour id, `install` a function receiving the
flavour's `api` table and the host global table, `info` an optional table with
the metadata's `version` (string) and `build` (integer). The installer runs at
once, and only, when `flavor` is the running flavour and nothing has installed
it yet; the method returns whether it ran. A registration for another flavour
costs nothing beyond the call. A second registration of the running flavour
(two addons embedding the same file) is dropped; the first file to load wins,
and its `info` is what `GetMetadataBuild` reports. `info` is recorded for every
flavour whose file loaded, installed or not, first registration winning. The
standalone `MoltenCodes` addon's `.toc` loads each flavour file only on its own
client game type (`[AllowLoadGameType ...]`), so there `GetMetadataBuild`
answers nothing for a flavour other than the running client's.

An error raised by the installer propagates to the generated file's load, so a
broken generated file is loud rather than half-installed and silent. Before it
propagates, the flavour's `api` table is emptied and the registration and its
`info` are forgotten, so the next copy to load (another addon's working file)
installs from a clean table. Unknown `info` fields are ignored, so a file from
a newer generator still registers.

Generated files call this method; an addon may call it to install a surface of
its own for a flavour whose generated file it chose not to embed.

## `MoltenCodes.wow`

The namespace root is written into the framework's `MoltenCodes` table when
the facade first loads, before any flavour file registers. A value already there that is not ApiKit's root is
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

## Secret values

On Retail 12.x a secret compared with a value of its own type, used in
arithmetic or used as a table key raises at that line (measured on Retail
12.1.0 b69933; see [`EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x)).
ApiKit asks the host's `issecretvalue` about the two
arguments that meet one of those operations, and refuses a secret one at the
caller's line before it is used:

- `flavor` of `RegisterFlavor` and `GetMetadataBuild`, which is used as a key
  of the flavour table;
- `info.build` of `RegisterFlavor`, whose integer test is arithmetic.

The message names the argument and never formats the value in. A refused
registration records nothing and runs no installer. `info.version` is only
stored and handed back by `GetMetadataBuild`, which the client allows, so a
secret version is accepted. A client without `issecretvalue` has no secret
values and refuses nothing. The probe is the `issecretvalue` found at load
(revision 7); a host that had none at load is asked again on each check, so
a probe installed later is honoured.

## Limits

ApiKit has no limits to open, so it has no `SetLimits` and no `UNBOUNDED`
(design constitution, principle 4a). What it retains is fixed at load: the
five namespace tables, the installed flavour's bindings (one table per
Blizzard namespace, one entry per function) and the `info` of each registered
flavour. Nothing grows with use.

## Error behaviour

Argument and receiver failures are raised at the caller's line:

| Message | Cause |
|---|---|
| `ApiKit:<Method> must be called on the ApiKit facade` | Called with another receiver. |
| `ApiKit:<Method> flavor must be one of retail, classic-era, classic-mop, ptr, beta` | Unknown flavour id. |
| `ApiKit:RegisterFlavor install must be a function` | |
| `ApiKit:RegisterFlavor info must be a table when given` | |
| `ApiKit:RegisterFlavor info.version must be a string when given` | |
| `ApiKit:RegisterFlavor info.build must be an integer when given` | |
| `ApiKit:<Method> flavor must not be a secret value` | A flavour id `issecretvalue` reports secret; see [Secret values](#secret-values). |
| `ApiKit:RegisterFlavor info.build must not be a secret value` | See [Secret values](#secret-values). |
| `ApiKit.SUPPORTED_FLAVORS is read-only; index "<key>" cannot be written` | `<key>` is a string as written and a number or boolean as its text (`index "6"`); any other key is named by its type (`index "<table>"`), and a key `issecretvalue` reports secret by `<secret>`, so a key's `__tostring` never runs (revision 6). |

Load-time failures: `MoltenCodes ApiKit requires Registry API 2 to be loaded
first`, `MoltenCodes ApiKit requires a valid Registry API 2 facade`,
`MoltenCodes ApiKit package state is corrupted or incomplete`, `MoltenCodes
ApiKit found MoltenCodes.wow owned by something else`. A generated flavour
file raises `MoltenCodes ApiKit (<Flavour> bindings) requires Registry API 2
to be loaded first`, `... requires a valid Registry API 2 facade` or `...
requires ApiKit API 1 to be loaded first` when it loads out of order.

## Performance

The installer was measured on the Retail file generated for client 12.1.0,
build 69933 (about 9,800 lines, 560 KB, 312 namespaces and 4,900 bindings),
with Lua 5.1.5 on a 2026 desktop, so the numbers are an order of magnitude,
not a promise. The parse was measured again on the file committed now (client
12.1.5, build 70783: 9,895 lines, 514 KB, 316 namespaces and 4,970 bindings)
and still takes about 3 ms. The other documents quote this table.

| Step | Cost |
|---|---|
| Parsing the flavour file | about 3 ms |
| Running the installer (about 300 namespaces, about 5,000 bindings) | under 0.5 ms |
| Retained by the installed surface | one table per bound namespace (316 on Retail 12.1.5; an alias such as `api.profiler` reuses its namespace's table) holding one function reference per binding (4,970), plus the event, enumeration and constants tables |
| A flavour file on a client of another flavour | its parse and one registration call; the installer is dropped |

The Retail tables at build 70783 document 6,440 functions; 4,970 of them are
bound. The other 1,470 are methods of 81 script object types (frames,
textures, animation groups), which are called on host objects and are
described in the types only. The README gives the counts of every flavour.

A call through the wrapper is one table index more than the raw call and
allocates nothing. Nothing in the package grows with use.

## Embedded copies and upgrades

ApiKit registers with Registry as package `apiKit`, API generation 1. When two
addons embed different revisions, Registry keeps the newest copy and hands it
the older one's state: the namespace tables, the installed flavours and their
`info` survive an in-place upgrade, and a flavour file that registered before
the upgrade is not run again. Revision 2 keeps the revision 1 state as it is
and replaces the methods only; the flavour is probed again on the upgrade.
Revision 3 keeps the revision 2 state the same way; the replaced methods refuse
secret arguments as described under [Secret values](#secret-values).
Revision 4 keeps the revision 3 state and methods as they are: what changed
is the generated flavour files it ships, which bind the functions the tables
place outside their system's namespace from where they live (see the
changelog, 0.1.4). A flavour an older copy's file already installed keeps
that surface for the session, because a flavour is installed once and the
first file to register it wins (above); only a session in which a revision 4
flavour file registers first gets the corrected bindings.
Revision 5 keeps the revision 4 state and methods the same way: it ships the
flavour files generated from the 2026-11-14 captures (changelog, 0.2.0), and
the same first-registration rule decides which build's surface a session
gets.
Revision 6 keeps the revision 5 state; it names a written key without
`tostring` (see [Errors](#error-behaviour)). The view's metatable is protected, so an
upgrade cannot change the refusal an older view carries: it publishes a fresh
view over the same `supportedFlavors` list as `SUPPORTED_FLAVORS`. A reference
to the older view taken before the upgrade reads the same ids and keeps the
older message.
Revision 7 keeps the revision 6 state and replaces the methods only: its
secret check is the shared helper block, which asks the `issecretvalue` found
at load (see [Secret values](#secret-values)).
