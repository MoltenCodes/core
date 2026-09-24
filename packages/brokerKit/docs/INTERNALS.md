# BrokerKit Internals

This document describes implementation invariants for maintainers. It is not an additional public API.

## Package state

`BrokerKit._state` holds everything that must survive an in-place upgrade:

| Field | Meaning |
|---|---|
| `objects` | Object name to its record. |
| `records` | Proxy to its record; how a method finds the record behind `self`. Strong keys: objects live for the session. |
| `objectCount`, `version` | How many objects exist (compared with `limits.maxObjects`), and a counter bumped by every added object that the sorted name cache compares against. |
| `sortedCache`, `sortedVersion` | The cached enumeration `{ names, positions }` (every name sorted, and each name's index in that array) and the `version` it was built at. |
| `addedSignal` | The SignalKit signal `OnObjectAdded` connects to. |
| `limits` | The shared limits `SetLimits` writes: `maxObjects` and `maxAttributes`, each an integer or the sentinel. |
| `unbounded` | The `UNBOUNDED` sentinel, created once so every revision publishes the same table. |
| `objectPrototype`, `prototypeMetatable` | The methods every object reads through (`Set`, `Get`, `OnChange`), rewritten by every loading revision, and the metatable `{ __index = objectPrototype }` shared by every identity table. |
| `objectNewIndex` | The one `__newindex` function every proxy metatable holds. It calls `dispatch.assignFromProxy`, so an upgrade changes what a field write does without touching existing proxies. |
| `dispatch` | `assignFromProxy`, `onDataObjectCreated` and `onAttributeChanged`, rewritten by every loading revision. |
| `libDataBroker` | The bridge state below. |
| `runtimeRevision`, `schema` | Bookkeeping shared with every Kit. |

## The lookup chain of an object

An object is four tables:

```text
proxy       {}                                  what the consumer holds; always empty
  metatable { __index = attributes, __newindex = objectNewIndex, __metatable = "BrokerKit.Object" }
attributes  { type = ..., text = ..., ... }      the stored attributes
  metatable { __index = identity }
identity    { name = "MyAddon" }                 the read-only identity
  metatable prototypeMetatable                   { __index = objectPrototype }
```

A read of `object.text` misses the empty proxy and lands in `attributes` after one metatable hop; `object.name` after two; `object.Set` after three. No function runs on a read, which is what point 6 of the plan ("reads are field reads") asks for. Every write misses the empty proxy and calls `objectNewIndex`, so a plain field write and `Set` share one path. `__metatable` hides the metatable (so `setmetatable` on a proxy raises) and is the tag `recordOf` does not need: the record lookup is `records[proxy]`, which also answers for a proxy made by an older revision.

The `type` guard before `records[proxy]` matters: indexing a table with a secret value raises, and a method may be called with anything as `self`.

## Object records

One per object, created by `createRecord` and kept in `objects` and `records`:

| Field | Meaning |
|---|---|
| `name`, `proxy`, `attributes` | The identity and the two tables above. |
| `foreign` | `true` for an object adopted from LibDataBroker: read-only, never exposed. |
| `source` | The LibDataBroker data object a foreign record wraps, or `false`; `onAttributeChanged` accepts a change only from it. |
| `mirror` | The LibDataBroker data object an exposed record writes into, or `false`. |
| `attributeCount` | Attributes holding a value now, compared with `limits.maxAttributes` when a new one is written. |
| `anySignal`, `attributeSignals` | The change signals, created on the first `OnChange` of each kind so an object nobody listens to owns no signal. |
| `schema` | The record layout version, `1`. |

## One write path

`writeAttribute(record, key, value, valueIsSecret)` is the only writer of attribute storage, used by `Set`, a field write (`assignFromProxy` → `assignAttribute`), `New` (indirectly: `New` copies a validated definition with `rawset` and sets the count, because no listener can exist yet) and adoption. It returns `unchanged`, `changed` or `full`:

- `unchanged` when both sides are `nil`, or when neither side is secret and they are equal; `nil` is tested with `type`, the repository rule, which never compares (a secret compared with `nil` happens not to raise, but one compared with a string or number of its own type does);
- `full` when the write would add an attribute past `maxAttributes`; replacing and clearing never hit the limit, and clearing decrements the count;
- `changed` otherwise, after storing.

`assignAttribute` does what differs by origin for a MoltenCodes object: the foreign refusal, name and value validation, the limit error, the mirror write (skipped for a secret value, because LibDataBroker's own `__newindex` compares) and `fireChange`. Adoption and `onAttributeChanged` call `writeAttribute` and `fireChange` directly: a foreign value is unchecked and never mirrored.

`fireChange` fires the attribute's own signal, then the any-attribute signal, each only when it exists. SignalKit forwards the four arguments without allocating.

## Sorted names and `Iterate`

`currentSortedCache` compares `sortedVersion` with `version` and rebuilds only when they differ, always into a **new** `{ names, positions }` pair built together and never modified afterwards. `Iterate` returns `iterateNext, cache, nil`: a generic `for` hands `iterateNext` that cache and the previous name, and `cache.positions[previous] + 1` is the next index into `cache.names`. Because the positions belong to the same build as the names, an object added mid-walk (by the loop body or by an `OnObjectAdded` listener that enumerates) produces a new cache that the running walk never sees: it visits every name of its own build, in order, and terminates. Only a rebuild allocates, so `Iterate` itself is allocation-free. `Objects` copies `cache.names` so neither table of the cache is handed out as an array a caller could modify.

## LibDataBroker bridge

`libDataBroker` holds:

| Field | Meaning |
|---|---|
| `exposeTarget` | The library exposed into, or `false`. `exposeObject` does nothing while it is `false`. |
| `adoptSource` | The library adopted from, or `false`. Both callbacks do nothing while it is `false`. |
| `subscribed` | The library the callbacks were registered with, or `false`; `subscribe` registers only when this is not already that library. |
| `callbackOwner` | The table CallbackHandler files the registrations under. CallbackHandler refuses the library itself as the owner. |
| `onCreated`, `onAttributeChanged` | The functions handed to `RegisterCallback`. Each calls the matching `dispatch` entry, so an upgrade changes their behaviour without a second registration, which CallbackHandler would treat as a replacement. |

`exposeObject` builds a table of the record's non-secret attributes and hands it to `NewDataObject`, which (as the real library does) moves the fields into its storage, turns that table into the data object and fires `LibDataBroker_DataObjectCreated` synchronously. Because `createRecord` ran before `exposeObject`, `onDataObjectCreated` finds the name held and adopts nothing. A `nil` from `NewDataObject` means a foreign data object holds the name; the record's `mirror` stays `false`.

`adoptObject` collects the data object's attribute names through `ldb:pairs(dataobj)` under `pcall`, because the real library asserts on a data object that has no storage yet (one created with `NewDataObject(name)` and never written to), orders them with `foreignAttributeBefore` (`type`, then the known attributes, then custom ones, each group sorted) so a low `maxAttributes` drops custom attributes first, and writes each through `writeAttribute` so the attribute limit holds. The names are collected before any is written because they have to be ordered first; no listener runs until every attribute is stored, when `OnObjectAdded` fires.

`onAttributeChanged` accepts a change only for a record that is foreign **and** whose `source` is the data object reported. That one test is the no-echo rule for writes: a mirror write coming back names a MoltenCodes object, and a foreign addon writing into our mirror names our object with a different data object.

## Error levels

Every argument validator takes an explicit `level`, which is the value `error` needs *inside the function that receives it*; each further hop towards `error` adds one. Public methods pass 3 to a validator they call directly. `assignAttribute` receives 3 from `Set` and 4 from `assignFromProxy` (the closure in state and `assignFromProxy` are two frames between the metamethod's caller and it), and passes `level + 1` to the name and value validators. The error-level spec pins every message, field writes included.

## Upgrades

The upgrade spec loads the same source a second time with `IMPLEMENTATION_REVISION` raised to 2 and checks that objects keep their identity, a connection still fires from a field write, the mirror still receives writes, adoption still follows created objects and changed attributes through the single subscription, the bridge methods report `"already"`, and a foreign object is still read-only through the new code.
