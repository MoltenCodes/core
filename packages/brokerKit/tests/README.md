# BrokerKit Tests

The BrokerKit suite covers:

- `New`: the default type, a definition copied rather than kept, every known attribute accepted with its type and refused with another, custom attributes of every type, reserved and malformed attribute names, duplicate names (plain and held by a foreign object), invalid names and definitions, and the facade receiver;
- attributes: reads as plain fields and through `Get`, writes as plain fields and through `Set`, clearing with `nil`, `type` never cleared, the proxy kept empty, the hidden metatable, `name` read-only, the method names reserved, type checks on write keeping the old value, malformed names on write and read, receiver checks on every method, and methods shared between objects with identities apart;
- `OnChange`: the any list with `(object, attribute, value, previous)`, per-attribute lists, the attribute list before the any list, no fire for a same-value write or a `nil` over nothing, fires for clearing and for an equal-but-different table, the connection's lifetime, the new value visible to a listener, a listener error propagating after the value was stored, and argument refusals;
- enumeration: `Get`, `Objects` sorted whatever the creation order and fresh on every call, `Iterate` in the same order, over nothing, visiting every starting name when objects are added mid-walk (by the loop body and by an `OnObjectAdded` listener that enumerates), sharing one iteration state until an object is added, MoltenCodes and foreign objects ordered together, `OnObjectAdded` after the object is stored, `IsForeign`, and the facade receiver on every method;
- LibDataBroker: `"absent"` without LibStub and with a LibStub that holds no LibDataBroker; exposing existing objects (a fake display sees their creation and attributes), later changes as one write each, later objects, `"already"` with nothing created twice, and a name a foreign object holds staying local whether the object existed before exposing or was created after; adopting existing objects read-only in sorted order, writes refused naming the object foreign, foreign changes forwarded into both `OnChange` forms, later objects through the callback, an object nobody wrote to yet, reserved and non-string foreign attribute names skipped, `"already"` with one subscription, the MoltenCodes object kept on a name clash, `New` refused for a foreign name, a raising `OnChange` listener on the foreign path isolated by the library as CallbackHandler isolates it, and a LibDataBroker without CallbackHandler; and both directions at once without an adopted object mirrored back, an own object adopted, an own change echoed, or a foreign write to the mirror reaching the object;
- secret values: a secret name, attribute name (in every method), known-attribute value or limit refused at the caller through an `issecretvalue` stub looked up at call time; a secret custom value stored without comparison and firing every time, never mirrored into LibDataBroker; secret foreign names and attribute names skipped; a secret foreign value kept without comparison;
- the limits: `GetLimits` defaults, constants and fresh tables, `maxObjects` refusing at the caller, lowered without removing objects, lifted with `UNBOUNDED`, and stopping adoption quietly; `maxAttributes` refusing at the caller both ways while replacing and clearing stay possible, counting the default type, leaving foreign attributes out quietly with custom ones dropped before `type` and the known attributes, and lifted with `UNBOUNDED`; invalid, secret or unknown values and non-facade receivers refused at the caller's line without changing anything;
- allocation guards (`collectgarbage("count")` with the collector stopped) on same-value writes, changed writes with per-attribute and any listeners, changed writes while exposed to LibDataBroker, and reads, `Get` and `Iterate`;
- duplicate embedded loading, Registry publication, yielding to a newer revision, missing Registry, missing SignalKit, an incomplete facade, and an in-place upgrade that keeps objects, connections, the sorted cache, adoption, the single subscription and exposure, an upgrade that keeps the set limits and the `UNBOUNDED` sentinel, and a refusal of state holding an invalid limit;
- `error` levels: every argument failure reports the caller's own line, including field writes through `__newindex`;
- manifest/runtime API and revision consistency, and the declared dependencies.

The shared fixture does not stub LibStub, so `support/BrokerKitTestEnv.lua` provides a minimal LibStub (`InstallLibStub`) and a LibDataBroker-1.1 stub (`InstallLibDataBroker`) with the library's own semantics: `NewDataObject`, `DataObjectIterator`, `GetDataObjectByName`, `GetNameByDataObject`, `pairs`, proxies whose `__newindex` compares and fires the four `LibDataBroker_AttributeChanged*` events (raising a named error when a secret reaches the comparison), a CallbackHandler-shaped `RegisterCallback`, an `isolateErrors` option that runs callbacks under `pcall` and collects what they raised as CallbackHandler does through `xpcall`, and counters for idempotence checks; `WatchLibDataBroker` registers a fake display addon and returns what it saw; `Reset` removes `LibStub`.

| Spec | Covers |
|---|---|
| `New_spec.lua` | `New`, the definition, attribute types and names |
| `Attributes_spec.lua` | field reads and writes, `Set`, `Get`, the proxy |
| `OnChange_spec.lua` | change signals per attribute and for all |
| `Enumerate_spec.lua` | `Get`, `Objects`, `Iterate`, `OnObjectAdded`, `IsForeign` |
| `LibDataBroker_spec.lua` | exposing, adopting, both at once |
| `SecretValues_spec.lua` | secret arguments, values and foreign entries |
| `Limits_spec.lua` | `SetLimits`, `GetLimits`, both bounds and `UNBOUNDED` |
| `Allocation_spec.lua` | allocation guards |
| `ErrorLevels_spec.lua` | argument errors reported at the caller's line |
| `Bootstrap_spec.lua` | publication, duplicate loads, load order, upgrades |
| `Manifest_spec.lua` | manifest and runtime `API` / `REVISION` agreement, declared dependencies |
