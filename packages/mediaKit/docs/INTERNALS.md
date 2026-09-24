# MediaKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`MediaKit._state` holds everything that must survive an in-place upgrade:

| Field | Meaning |
|---|---|
| `types` | Media type to its type record; all seven exist from the first load. |
| `consumers`, `consumerCount` | Consumer name to defaults object, and how many (bounded by `limits.maxConsumers`). |
| `limits` | The shared limits `SetLimits` writes: `maxEntriesPerType` (an integer up to 16384) and `maxConsumers` (an integer or the sentinel). |
| `unbounded` | The `UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `defaultsPrototype`, `defaultsMetatable` | Shared by every defaults object. The metatable's `__metatable` is `"MediaKit.Defaults"`, which is also how a receiver is recognised. |
| `dispatch` | `mirrorEntry` and `onLibSharedMediaRegistered`, rewritten by every loading revision. |
| `libSharedMedia` | The bridge state below. |
| `runtimeRevision`, `schema` | Bookkeeping shared with every Kit. |

The prototype, the metatable and `dispatch` are created once and kept; every loading revision writes its functions into them, so objects and callbacks an older copy handed out run the newer behaviour.

## Type records

One per media type, every field present from construction:

| Field | Meaning |
|---|---|
| `entries` | Name to entry `{ data, scriptMask, origin }`. |
| `count` | Number of entries, compared with `limits.maxEntriesPerType` at every registration. |
| `version` | Incremented by every added entry. |
| `signal` | The SignalKit signal `OnRegistered` connects to. |
| `allList`, `allListVersion` | The sorted array of every name, and the `version` it was built at. |
| `clientList`, `clientListVersion`, `clientListScript` | The sorted array of the names this client can use, the `version` and the script it was built for. Only fonts use it. |
| `schema` | The record layout version, `1`. |

An entry's `origin` is `"builtin"`, `"registered"` or `"libSharedMedia"` (adopted). Only the last is excluded from mirroring.

## Defaults objects

One per consumer name, created by `Defaults` and kept in `consumers`:

| Field | Meaning |
|---|---|
| `_names` | Media type to the name the consumer chose; absent when it chose nothing. |
| `_schema` | The defaults layout version, `1`, so a later revision can upgrade old objects. |

`Get` never caches its answer: it re-checks the choice and the fallback at every call, so a pack that registers later, or a change of the client's script, is answered at once.

## Scripts as a bit mask

A font's scripts are stored as an integer: `latin` 1, `cyrillic` 2, `greek` 4, `cjkSimplified` 8, `cjkTraditional` 16, `korean` 32, `japanese` 64, so "every script" is 127. Two script sets are equal when their masks are, whatever order or repeats `options.scripts` had, and "covers script s" is `floor(mask / bit) % 2 == 1`. Lua 5.1 has no bit library outside the client, and this needs none. A font registered without `scripts` carries 1 (`latin`); non-font entries carry 127 and are never tested.

## One registration path

`registerEntry(type, name, data, scriptMask, origin)` is the only writer, used by `Register`, the built-ins and adoption. It returns `added`, `unchanged`, `taken` or `full`, and on `added` it:

1. stores the entry and bumps `count` and `version`;
2. calls `dispatch.mirrorEntry` unless the origin is `libSharedMedia`;
3. fires the type's signal with `(type, name, data)`.

Storing first is what makes both re-entrant paths safe: a listener that calls `Fetch` or `List` sees the entry, and LibSharedMedia's callback, fired synchronously from inside its own `Register` in step 2, finds the entry present and returns `unchanged`.

## Lists

`List` compares the record's `version` with the one its cached array was built at and rebuilds only when they differ (for the client's font list, also when `GetLocale` now maps to another script). A rebuild always makes a **new** array and never touches the old one, so an array a caller still iterates stays valid, and `MirrorToLibSharedMedia` can walk the cached array while LibSharedMedia's callback re-enters MediaKit. Names are unique keys, so `table.sort` with `<` gives one order for every insertion order.

## LibSharedMedia bridge

`libSharedMedia` holds:

| Field | Meaning |
|---|---|
| `adoptSource` | The library adopted from, or `false`. The callback does nothing while it is `false`. |
| `subscribed` | The library the callback was registered with, or `false`; `AdoptLibSharedMedia` registers only when this is not already that library. |
| `mirrorTarget` | The library mirrored into, or `false`; `mirrorEntry` does nothing while it is `false`. |
| `callbackOwner` | The table CallbackHandler files the registration under. CallbackHandler refuses the library itself as the owner. |
| `callback` | The function handed to `RegisterCallback`. It calls `dispatch.onLibSharedMediaRegistered` at every call, so an upgrade changes its behaviour without a second registration, which CallbackHandler would treat as a replacement. |

Adoption collects a type's LibSharedMedia names into a temporary array and sorts it before adopting, for two reasons: the signal order is then deterministic, and a listener that registers into LibSharedMedia during adoption cannot disturb a `next` traversal of the library's table.

Adopted fonts carry every script, because LibSharedMedia keeps no per-font locale mask after registration: it refuses, at `Register`, a font whose mask excludes the client's locale, so whatever `HashTable` holds is usable on this client.

## Built-ins

The first copy registers `BUILTIN_MEDIA` and `BUILTIN_FONTS` through `registerEntry` at the end of its file, after every function is committed. `GetLocale` is read once for them: on a Cyrillic client the fonts use the `_CYR` files and cover `latin` and `cyrillic`, elsewhere the Western files and `latin`. A later revision inherits them and registers nothing.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass 3 to a validator they call directly. `readRegisterOptions` and `readAnyScript` pass `level + 1` to the helpers they call. The error-level spec pins every message.

## Upgrades

The upgrade specs load the same source a second time with `IMPLEMENTATION_REVISION` raised by one and check that entries, cached lists, a connection, a defaults object, adoption, the single subscription, mirroring and the set limits survive, and that the built-ins are not registered twice. A further spec loads the source as revision 1 and upgrades it with the current file. Revision 2 changed no state: it keeps the revision 1 state and replaces the methods.
