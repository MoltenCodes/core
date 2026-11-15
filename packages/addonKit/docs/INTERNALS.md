# AddonKit Internals

This document describes implementation invariants for maintainers. It is not an
additional public API; the contract is [`API.md`](API.md).

## Package state

`AddonKit._state` is shared by every embedded copy (schema 1):

| Field | Meaning |
|---|---|
| `schema` | The state layout version, `1`. |
| `runtimeRevision` | The core revision that last committed its functions. |
| `limits` | `{ maxFacades }`. |
| `facades` | Addon name to its facade. |
| `records` | Facade to its private record (below). |
| `facadeCount` | How many facades exist; held to `maxFacades`. |
| `methods` | Facade member name to function: the core's eight methods (revision 2 adds `SetDefaultModuleState`, `SetDefaultModulePrototype` and `OnModuleCreated`, thin forwarders to the addon's ModuleKit container) and each part's. Each loader writes only its own keys. |
| `fields` | Facade field name to a factory `function(record)` whose value is stored on the facade at its first read (`LAUNCHER_DEFAULTS`). |
| `helpers` | Core functions the parts call at call time (below). |
| `parts` | Part name to `{ revision = n }`, written by each part file. |
| `dispatch` | `index`, `newindex` and `forEntry`, rewritten by every core revision. |
| `metatable` | The metatable every facade carries. `__index` and `__newindex` are closures created once that call `dispatch`; `__metatable` is `"AddonKit.Facade"`. |
| `entry` | The function installed at `MoltenCodes.For` and `AddonKit.For`, created once; it calls `dispatch.forEntry`. |
| `reportedForeignEntry` | Whether a foreign `MoltenCodes.For` was already reported. |

A facade record is `{ addonName, facade, pins, databases }`: `pins` maps a
facade name to a pinned generation, `databases` maps a saved-variable name to
`{ defaults, db }`.

## Why the closures are created once

A facade's metatable and the namespace entry are held by addon code for the
session: every addon keeps its `MC`, and `MoltenCodes.For` may have been read
into a local. They are therefore created by the first revision and never
replaced. Their behaviour lives in `dispatch`, which each revision rewrites,
so a newer copy embedded by another addon serves every facade and every
`MoltenCodes:For` call at once.

Methods are deliberately not cached on the facade: `__index` finds them in
`state.methods` on each call, so an upgrade reaches them too. Kits are cached
(`rawset`), because the shared Kit tables are stable across their own
upgrades (Registry, "Stable-reference guarantee").

## Stack levels

No call that reaches `error` from a metamethod or the entry is a tail call:
`__index` writes `local value = dispatch.index(facade, key); return value`,
which keeps its frame, so level 3 inside `dispatch.index` is the line that read
the field. Inside a method, `requireRecord`, `requireName` and `requireKit` take
the level `error` needs inside themselves, and each further hop adds one.

`callAtCaller(level, func, ...)` runs another Kit's call under `pcall`. A Kit
raises at its caller's level, and its caller there is `pcall`, a C function, so
the message arrives without a position; `error(message, level)` adds the
author's. `withoutAddonKitPosition` removes a leading
`...AddonKit*.lua:<line>: ` in case a message was raised at a line of
AddonKit itself (`MC:Options` runs `Define` and `Register` in one closure, so
their messages carry that closure's line).

## Parts

A part file resolves the core with `Registry:Get("addonKit", 1)` and checks that
the state has `methods`, `helpers` and `parts` (and `fields` for Composition),
raising the documented load error otherwise. When `state.parts[name].revision`
is at least the file's `PART_REVISION`, the file returns at once. Otherwise it
writes its members into `state.methods` (and `state.fields`) and its revision
into `state.parts`.

Part functions keep no copy of a core helper: they read `helpers.<name>` at each
call, so a core upgraded after the part was loaded serves it. The helpers are
`isSecret`, `reportError`, `callAtCaller`, `withoutPosition`, `requireRecord`,
`requireKit`, `requireSchemaKit`, `requireName` and `isFacade`. A new core
revision must keep each of them with the same arguments and meaning, or bump
the parts' minimum.

The core knows which members belong to which part (`PART_OF`) only to write the
"part not loaded" message and to suggest those names.

## The catalogue

`CATALOGUE` maps a facade name to its generation; the package ID is derived by
lower-casing the first letter, and the file path is built only for an error
message, so the table is one string key and one number per Kit. The Manifest
spec compares it with every `package.manifest.json` and with the
`PUBLISHED_GENERATIONS` baseline, which may gain rows but never change one.
Adding a Kit to the repository means adding a row to both, a new revision, and
a `---@field` line on `MoltenCodesFacade`.

## Suggestions

`suggestionFor` runs only on the error path. It lists every Kit, alias,
method and part member, compares lower-cased names with a bounded edit
distance (stopping at 3), treats `name .. "kit"` as distance 0, and picks the
nearest, ties broken by sorted order.
