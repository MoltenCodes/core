# apiKit metadata schema

The metadata of one client flavour is a directory of JSON files written by
`python3 -m tooling.api.normalize` from the client's own API documentation
tables and read by every generator (`docs/API_KIT_DESIGN.md`, sections 7.1
and 13). This document describes the files field by field. The Python model
that reads and writes them is `tooling/api/model.py`; the two are kept in
step by `tooling/tests/test_api_model.py`.

## Conventions

- Keys are camelCase. Objects are written with sorted keys and two-space
  indentation; lists are sorted as stated per file; text is written as UTF-8
  without escaping, so the same capture always produces the same bytes.
- A key whose value would be `null`, an empty list or an empty object is
  omitted. `false` and `0` are values and are written.
- Every file carries `"schema": 1` and `"flavour": "<id>"`. The schema
  number changes when a field changes meaning or is removed; a new optional
  field does not change it.
- Names: `name` is always the Blizzard name exactly as the tables spell it;
  `wrapper` is the MoltenCodes name produced by the rules in
  `tooling/api/naming.py`; `binding` is the raw expression the wrapper aliases.
- Documentation prose from the tables is kept as `documentation`, a list of
  paragraphs, with provenance in `provenance.json`.
- Attributes the model does not name are never dropped: a boolean attribute
  that is `true` appears in `flags` (a sorted list of attribute names), any
  other value under `attributes` (an object keyed by attribute name). A
  reference to another table (`Enum.SecretAspect.Cooldown`) is carried as its
  dotted path, an arithmetic expression as its text.

## Files

| File | List key | Sorted by | Holds |
|---|---|---|---|
| `provenance.json` | | | where the capture came from |
| `namespaces.json` | `namespaces` | `wrapper` | function groups and their functions |
| `events.json` | `events` | `name` | frame events and payloads |
| `enums.json` | `enums` | `name` | enumerations (`Enum.<name>`) |
| `structures.json` | `structures` | `name` | record types |
| `callbacks.json` | `callbacks` | `name` | callback signatures |
| `constants.json` | `constants` | `name` | constants tables (`Constants.<name>`) |
| `restrictions.json` | `restrictions` | `system`, `name` | restriction predicates |

## `provenance.json`

| Key | Type | Meaning |
|---|---|---|
| `schema` | integer | `1` |
| `flavour` | string | the flavour id from `tooling/api/flavours.json` |
| `repository` | string | the mirror repository (`Gethe/wow-ui-source`) |
| `branch` | string | the mirror branch the capture was taken from |
| `commit` | string | the full commit sha, lowercase |
| `committedAt` | string | the commit date as the mirror reports it (ISO 8601) |
| `subject` | string | the commit subject (`12.1.0 (69933)`) |
| `version` | string, optional | the client version parsed from the subject |
| `build` | integer, optional | the client build parsed from the subject |
| `documentationPath` | string | the directory read inside the mirror |
| `capturedOn` | string | the fetch date, `YYYY-MM-DD` |
| `fileCount` | integer | how many documentation tables were read |

## Namespace

An entry of `namespaces.json`.

| Key | Type | Meaning |
|---|---|---|
| `wrapper` | string | the wrapper name: `api.<wrapper>` |
| `kind` | string | `namespace` (a `C_*`, `string` or `table` namespace), `global` (functions that are globals, grouped by their documentation system) or `object` (methods of a script object type; typed, never bound) |
| `system` | string | the documentation system name (`AddOns`, `Unit`); when several files document one namespace under different names, the one equal to the namespace without its prefix, else the alphabetically first |
| `blizzardNamespace` | string, kind `namespace` only | `C_AddOns` |
| `alias` | string, optional | the short alias from `naming.json`; `api.<alias>` is the same table |
| `objectType` | string, kind `object` only | the tables' `ObjectType` |
| `environment` | string, optional | the tables' `Environment` (`All`, `SecureOnly`) |
| `documentation` | list of strings, optional | |
| `functions` | list of Function, sorted by `name` | |
| `sources` | list of strings | the documentation files this namespace was read from |

## Function

| Key | Type | Meaning |
|---|---|---|
| `name` | string | Blizzard name (`DisableAddOn`) |
| `wrapper` | string | `api.<namespace>.<wrapper>` |
| `binding` | string, absent for kind `object` | the raw expression aliased: `C_AddOns.DisableAddOn` or `UnitName` |
| `arguments` | list of Parameter, optional | in call order |
| `returns` | list of Parameter, optional | in return order |
| `documentation` | list of strings, optional | |
| `secretArguments` | string, optional | the tables' `SecretArguments` (`AllowedWhenUntainted`, `AllowedWhenTainted`, `NotAllowed`) |
| `mayReturnNothing` | `true`, optional | the function may return nothing at all |
| `hasRestrictions` | `true`, optional | the function is subject to its system's restriction predicates |
| `isProtected` | `true`, optional | the tables' `IsProtectedFunction` |
| `flags` | list of strings, optional | other markers that are `true` (`RequiresClubsInitialized`, `SecretWhenUnitStatsRestricted`, ...) |
| `attributes` | object, optional | other non-boolean markers (`FailureMode`, `SecretReturnsForAspect`, ...) |
| `source` | string | the documentation file |

## Parameter

An argument, a return value, an event payload field or a structure field.

| Key | Type | Meaning |
|---|---|---|
| `name` | string | |
| `type` | string | a type name: a host type from `tooling/api/types.json`, or an enumeration, structure, callback or object type of this flavour |
| `nilable` | boolean | whether the value may be `nil`; written even when `false` |
| `innerType` | string, optional | element type when `type` is `table` |
| `keyType` | string, optional | key type when `type` is `table` and the table is a map |
| `mixin` | string, optional | the mixin the client applies to the table |
| `default` | any, optional | the documented default; present only when the tables document one, even when it is `false` or `0` |
| `strideIndex` | integer, optional | the tables' `StrideIndex` for variadic groups |
| `documentation` | list of strings, optional | |
| `flags` | list of strings, optional | other markers that are `true` (`NeverSecret`, `NilableContents`, ...) |
| `attributes` | object, optional | other non-boolean markers |

## Event

| Key | Type | Meaning |
|---|---|---|
| `name` | string | the tables' PascalCase name (`AddonLoaded`) |
| `wrapper` | string | `api.events.<wrapper>`, whose value is `literalName` |
| `literalName` | string | the event string the client fires (`ADDON_LOADED`) |
| `system` | string | the documentation system |
| `payload` | list of Parameter, optional | in argument order |
| `documentation` | list of strings, optional | |
| `synchronous` | `true`, optional | the tables' `SynchronousEvent` |
| `unique` | `true`, optional | the tables' `UniqueEvent` |
| `callback` | `true`, optional | the tables' `CallbackEvent` |
| `flags`, `attributes` | optional | as for Function |
| `source` | string | |

## Enum

| Key | Type | Meaning |
|---|---|---|
| `name` | string | `Enum.<name>` |
| `wrapper` | string | `api.enums.<wrapper>` |
| `fields` | list of `{name, value, documentation?}` | in table order |
| `numValues`, `minValue`, `maxValue` | integer, optional | as the tables state them; the validator checks them against `fields` |
| `system` | string, optional | absent for constants-only files |
| `documentation` | list of strings, optional | |
| `source` | string | |

## Structure

| Key | Type | Meaning |
|---|---|---|
| `name` | string | |
| `fields` | list of Parameter | in table order |
| `system` | string, optional | |
| `documentation` | list of strings, optional | |
| `source` | string | |

## Callback

| Key | Type | Meaning |
|---|---|---|
| `name` | string | |
| `arguments` | list of Parameter, optional | |
| `returns` | list of Parameter, optional | |
| `system` | string, optional | |
| `documentation` | list of strings, optional | |
| `source` | string | |

## Constants table

| Key | Type | Meaning |
|---|---|---|
| `name` | string | `Constants.<name>` |
| `wrapper` | string | `api.constants.<wrapper>` |
| `values` | list of constant values | in table order |
| `system` | string, optional | |
| `documentation` | list of strings, optional | |
| `source` | string | |

A constant value is `{name, type, value, documentation?}` when the tables
give a literal, or `{name, type, expression, documentation?}` when they give
a reference or arithmetic (`Enum.CalendarGetEventType.Get`,
`Constants.X.LAST - Constants.X.FIRST + 1`), carried unevaluated exactly as
written.

## Restriction

| Key | Type | Meaning |
|---|---|---|
| `name` | string | the predicate a function's `flags` or `hasRestrictions` refers to |
| `kind` | string | `precondition` or `secret` |
| `failureMode` | string, optional | `Error`, `ReturnNothing`, `ReturnWithError` |
| `system` | string, optional | the system whose functions the predicate applies to; the same name may carry another failure mode in another system |
| `documentation` | list of strings, optional | |
| `source` | string | |

## Host types

`tooling/api/types.json` is the hand-maintained table of the types the
documentation tables reference but never define: Lua primitives (`number`,
`bool`, `cstring`), named aliases (`WOWGUID`, `luaIndex`, `UnitToken`),
client-provided classes (`ScriptRegion`, `ItemLocation`) and a few opaque
names. Each entry is `{kind, lua}`: the kind (`primitive`, `alias`, `class`,
`opaque`) and the LuaCATS type the generators write for it. The validator
refuses metadata that references a type neither the flavour nor this table
knows, so a new client type is a one-line addition here.
