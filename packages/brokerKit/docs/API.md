# BrokerKit API

BrokerKit API generation **1** provides data objects for display addons in the LibDataBroker-1.1 idiom: named objects whose attributes are plain fields, typed at the caller's line; change signals per object and per attribute; sorted enumeration; and a two-way bridge to LibDataBroker-1.1.

Implementation revision: **2**.

## Loading

Runtime files must be loaded in dependency order:

```text
Registry.lua
SignalKit.lua
BrokerKit.lua
```

Portable WoW code resolves the package through Registry:

```lua
local BrokerKit = MoltenCodes.Registries[2]:Get("brokerKit", 1)
```

BrokerKit does not rely on `require()` at runtime.

### Host facilities

BrokerKit reads two host globals, each at call time rather than at load, and works without both:

| Facility | Used by | Without it |
|---|---|---|
| `issecretvalue` | every argument check and every attribute write | Nothing is treated as secret. |
| `LibStub` | `ExposeToLibDataBroker`, `AdoptFromLibDataBroker` | Both return `false, "absent"`. |

`LibStub` is read with `rawget(_G, "LibStub")`, and LibDataBroker with `LibStub:GetLibrary("LibDataBroker-1.1", true)`. BrokerKit does not use the `interopKit` bridge: it needs the library's methods and callbacks, which the bridge's Registry entry does not add, and depending on `interopKit` would make every addon embedding BrokerKit embed it too.

## Public surface

| Member | Purpose |
|---|---|
| `New(name, definition?)` | Create an object. Raises for a taken name. |
| `Get(name)` | The object, MoltenCodes or foreign, or `nil`. |
| `Objects()` | A fresh array of every name, sorted. |
| `Iterate()` | An allocation-free iterator over `name, object`, sorted. |
| `OnObjectAdded(callback)` | A SignalKit connection fired with each new object. |
| `IsForeign(object)` | Whether the object was adopted from LibDataBroker. |
| `ExposeToLibDataBroker()` | Register our objects into LibDataBroker and keep doing so. |
| `AdoptFromLibDataBroker()` | Wrap LibDataBroker's objects read-only and follow new ones. |
| `SetLimits(limits)` | Change the shared limits (`maxObjects`, `maxAttributes`). Returns nothing. |
| `GetLimits()` | A fresh table of both limits; allocates. |
| `MAX_OBJECTS`, `MAX_ATTRIBUTES` | `256` and `32`, the defaults of the two limits. |
| `UNBOUNDED` | Sentinel that lifts either limit; the same table for every revision. |
| `API`, `REVISION` | `1`, `1`. |

An object has three methods, `Set`, `Get` and `OnChange`, and the read-only field `name`; everything else on it is an attribute.

## Attributes

An object carries the attributes LibDataBroker-1.1's data specification names, with the Lua type each accepts, plus any custom attribute the owning addon adds. The known set is fixed and checked at every write; a custom attribute holds any value.

| Attribute | Type | Meaning for a display |
|---|---|---|
| `type` | `"data source"` or `"launcher"` | A data source shows `text`; a launcher shows `icon` and reacts to clicks. Defaults to `"data source"`; cannot be cleared. |
| `text` | string | The text a data source shows. |
| `label` | string | A short label shown before `text`. |
| `icon` | string or number | A texture path or a FileDataID. |
| `value` | string or number | A value shown with `suffix`. |
| `suffix` | string | The unit of `value`. |
| `tocname` | string | The addon the object belongs to. |
| `iconCoords` | table | Texture coordinates of `icon`. |
| `iconR`, `iconG`, `iconB` | number | The icon's vertex colour. |
| `OnClick` | function `(frame, button)` | Called by a display when its entry is clicked. |
| `OnEnter`, `OnLeave` | function `(frame)` | Called by a display when the cursor enters or leaves its entry. |
| `OnTooltipShow` | function `(tooltip)` | Called by a display to fill a tooltip. |

`icon` and `value` accept a number where LibDataBroker's specification says string, because the client now names textures by FileDataID and displays show `value` through `tostring`; the roadmap's "strings" is kept for `text`, `label`, `suffix` and `tocname`. Any attribute except `type` is cleared by writing `nil`.

Four names are **reserved** and refused as attributes: `name` (the object's identity), `Set`, `Get` and `OnChange` (its methods). An attribute name must be a non-empty, non-secret string.

BrokerKit never calls `OnClick` and the other handlers: a display does, with its own frame. They are stored and mirrored like any other attribute.

## `BrokerKit:New(name, definition?)`

```lua
local status = BrokerKit:New("MyAddon", {
    type = "data source",
    text = "0 ms",
    icon = 134400,
    OnClick = function(frame, button) end,
})
local launcher = BrokerKit:New("MyAddonLauncher", { type = "launcher", icon = [[Interface\Icons\X]] })
local bare = BrokerKit:New("Bare") -- a data source with no other attribute
```

Creates the object `name` with the attributes of `definition` and returns it. `definition` is optional, is copied (the caller keeps its table), and every field is validated before anything is created: a bad attribute leaves no object behind. `type` defaults to `"data source"` when the definition does not give one.

Raised at the caller: a name that is not a non-empty string or is secret; a name already held (`BrokerKit:New name "X" is already taken`, or `... is already taken by a foreign LibDataBroker object`); a definition that is not a table; an attribute name that is not a non-empty string, is secret or is reserved (`BrokerKit:New attribute "name" is reserved`); a known attribute of the wrong type (`BrokerKit:New attribute "text" must be a string`) or holding a secret; more attributes than `maxAttributes`, the default `type` counted (`BrokerKit:New refuses more than 32 attributes on an object`); and the object past `maxObjects` (`BrokerKit:New refuses more than 256 objects`).

A successful `New` stores the object, exposes it into LibDataBroker when exposing is on, and then fires `OnObjectAdded`, in that order.

Objects live for the session. There is no removal: a display addon keeps references to them, and LibDataBroker has no unregistration either.

## Reading and writing attributes

```lua
status.text = "12 ms"            -- the LibDataBroker idiom
status:Set("value", 12)          -- the explicit form; same checks, same signals
local text = status.text         -- a table read
local value = status:Get("value")
print(status.name)               -- "MyAddon"
```

An object is a proxy in the sense LibDataBroker uses: the table a consumer holds is empty, reads go through `__index` to the attribute storage, and writes go through `__newindex` into the one write path `Set` also uses. That is what makes a plain field write fire the change signals, and it is why `rawset(object, ...)` and `pairs(object)` are not part of the contract: the first bypasses the object, the second sees nothing.

### `object:Set(attribute, value)` and `object.attribute = value`

Both run the same steps, in this order:

1. refuse a foreign object (`BrokerKit.Object:Set object "X" is foreign (adopted from LibDataBroker) and read-only`);
2. refuse a bad attribute name (secret, not a non-empty string, reserved);
3. refuse a bad value for a known attribute (`BrokerKit.Object:Set attribute "text" must be a string`), or a secret one (`... must not be a secret value`); a custom attribute accepts anything;
4. compare with the current value and **return without firing when they are equal** (`nil` over nothing included); a secret on either side is never compared and always counts as a change;
5. refuse a new attribute past `maxAttributes` (`BrokerKit.Object:Set refuses more than 32 attributes on object "X"`); replacing or clearing an attribute is always allowed and clearing frees a slot;
6. store the value;
7. when exposed, write the value into the LibDataBroker data object (one write; LibDataBroker fires its own callbacks); a secret value is not mirrored;
8. fire the attribute's `OnChange` list, then the any-attribute list, with `(object, attribute, value, previous)`.

Every failure names `BrokerKit.Object:Set`, whichever form was used, and reports the line that wrote. A listener error propagates to the writer after the value was stored and mirrored.

### `object:Get(attribute)` and `object.attribute`

`object.attribute` is a table read: no function runs. `object:Get(attribute)` validates the name exactly as `Set` does and returns the stored value; `object:Get("name")` is refused because `name` is not an attribute; read `object.name`.

### `object.name`

The name the object was created or adopted under. Read-only: writing it raises `attribute "name" is reserved`.

## `object:OnChange(attribute?, callback)`

```lua
local connection = status:OnChange("text", function(object, attribute, value, previous)
    button:SetText(value)
end)
status:OnChange(function(object, attribute, value, previous)
    -- any attribute
end)
```

Connects `callback` to changes of one attribute, or of every attribute when `attribute` is omitted or `nil`, and returns a SignalKit connection (`connection:Disconnect()`, `connection:IsConnected()`; see [`signalKit/docs/API.md`](../../signalKit/docs/API.md)). The connection belongs to the caller. Listeners receive `(object, attribute, value, previous)`; `previous` is `nil` for a new attribute and `value` is `nil` for a cleared one. Per-attribute listeners run before any-attribute listeners; within a list, in connection order. Listeners run after the value is stored, so `object.attribute` already reads the new value. A listener error propagates to the writer, as SignalKit's `Fire` does. Foreign objects fire the same signals when LibDataBroker reports a change.

Raised at the caller: a callback that is not a function; an attribute name that is secret, not a non-empty string or reserved.

## `BrokerKit:Get(name)`

Returns the object named `name`, whether MoltenCodes or foreign, or `nil`. The name must be a non-empty, non-secret string.

## `BrokerKit:Objects()` and `BrokerKit:Iterate()`

```lua
for _, name in ipairs(BrokerKit:Objects()) do
    dropdown:AddItem(name)
end
for name, object in BrokerKit:Iterate() do
    panel:AddEntry(name, object)
end
```

Both enumerate every object, MoltenCodes and foreign, in the order of their names sorted with `<` (byte order: upper case before lower case, `"Bar 10"` before `"Bar 2"`). The order depends only on the names, never on creation order.

`Objects` returns a **fresh array** on every call; the caller may keep or modify it. `Iterate` returns a stateless iterator over a **cached** enumeration (the sorted names and their positions, built together) that is rebuilt only after an object was added; while nothing was added it allocates nothing. A walk is bound to the enumeration it started with, which is never modified: an object created during a walk (by the loop body, or by an `OnObjectAdded` listener that enumerates) goes into a new enumeration, so the walk still visits every name present when it started, in order, and does not visit the new object.

## `BrokerKit:OnObjectAdded(callback)`

Connects `callback` to every object created or adopted from now on and returns a SignalKit connection. The callback receives the object, after it is stored (so `Get` and `Iterate` see it) and, for a MoltenCodes object, after it was exposed into LibDataBroker.

## `BrokerKit:IsForeign(object)`

Whether `object` was adopted from LibDataBroker and is therefore read-only. Raises at the caller for anything that is not a broker object.

## LibDataBroker-1.1

LibDataBroker-1.1 is the registry every display addon reads. BrokerKit bridges it in both directions; nothing happens until one of the two methods is called, each is called once per library, and each returns `false, "absent"` when LibStub or LibDataBroker-1.1 is not loaded.

### Field-by-field mapping

A BrokerKit object and a LibDataBroker data object share the idiom, so the mapping is one to one:

| BrokerKit | LibDataBroker-1.1 |
|---|---|
| `BrokerKit:New(name, definition)` | `ldb:NewDataObject(name, dataobj)`; LibDataBroker returns `nil` for a taken name, BrokerKit raises at the caller |
| `object.attr` (read) | `dataobj.attr` through `__index` |
| `object.attr = value` (write) | `dataobj.attr = value` through `__newindex`; both compare with the old value and fire nothing when equal |
| `object:Set` / `object:Get` | no equivalent; the explicit form |
| `object.name` | `ldb:GetNameByDataObject(dataobj)` |
| `object:OnChange(callback)` | `ldb.RegisterCallback(self, "LibDataBroker_AttributeChanged", handler)` filtered by name |
| `object:OnChange(attr, callback)` | `ldb.RegisterCallback(self, "LibDataBroker_AttributeChanged_<name>_<attr>", handler)` |
| `BrokerKit:OnObjectAdded(callback)` | `ldb.RegisterCallback(self, "LibDataBroker_DataObjectCreated", handler)` |
| `BrokerKit:Get(name)` | `ldb:GetDataObjectByName(name)` |
| `BrokerKit:Iterate()` | `ldb:DataObjectIterator()`; sorted here, hash order there |
| `BrokerKit:Objects()` | no equivalent |
| the attribute table above | the data specification's attributes, unchecked there |
| a callback `(object, attribute, value, previous)` | a callback `(event, name, attr, value, dataobj)`; LibDataBroker has no `previous` |

### `BrokerKit:ExposeToLibDataBroker()`

```lua
local exposed, reason = BrokerKit:ExposeToLibDataBroker()
```

- Calls `ldb:NewDataObject(name, attributes)` for every MoltenCodes object, in sorted name order, with a copy of its non-secret attributes, and remembers the data object LibDataBroker hands back as the object's mirror. From then on every `New` does the same and every changed attribute is one write into the mirror, so LibDataBroker fires its `LibDataBroker_AttributeChanged*` events for the displays that listen.
- A name a foreign data object already holds in LibDataBroker cannot be taken: `NewDataObject` returns `nil`, the object stays local, and later changes are not mirrored. Displays keep showing the foreign object; BrokerKit consumers see ours.
- Returns `true`, or `false, "absent"`, or `false, "already"` when this library is already exposed into.

### `BrokerKit:AdoptFromLibDataBroker()`

```lua
local adopted, reason = BrokerKit:AdoptFromLibDataBroker()
```

- Registers one callback each for `LibDataBroker_DataObjectCreated` and `LibDataBroker_AttributeChanged` through LibDataBroker's CallbackHandler (`RegisterCallback`), then walks `ldb:DataObjectIterator()` in sorted name order and wraps each data object as a **foreign** object holding a copy of its attributes (read through `ldb:pairs(dataobj)`; a data object nobody has written to yet has none until its first change arrives). `OnObjectAdded` fires for each.
- A foreign object is read-only: `Set` and a field write raise at the caller naming it foreign. Its changes arrive through the callback and fire `OnChange` like any other. Its attributes are taken as they are, unchecked, because they are another addon's data; the attribute names must still be non-empty, non-secret strings and not reserved. Attributes past `maxAttributes` are left out quietly, custom ones first: at adoption they are written as `type`, then the known attributes, then custom ones, each group sorted, so what a display needs survives a low limit.
- **Listener errors on the foreign path do not reach the writer.** LibDataBroker delivers its callbacks through CallbackHandler, which runs each one under `xpcall` and hands an error to the client's error handler; the addon that wrote the attribute never sees it, and BrokerKit's remaining `OnChange` listeners for that change do not run (the error aborted that dispatch), while the value is already stored. A BrokerKit write, by contrast, propagates a listener error to the writer.
- A name BrokerKit already holds is not adopted: the MoltenCodes object wins, and LibDataBroker's changes for that name are ignored. In the other order, a foreign object adopted first keeps its name, and `New` for it raises `... is already taken by a foreign LibDataBroker object`.
- Adoption stops quietly at `maxObjects`. Secret and non-string names are skipped.
- Returns `true`, or `false, "absent"`, or `false, "already"` when this library is already adopted from. A LibDataBroker without `RegisterCallback` (none exists: CallbackHandler is its dependency) is read once.

### No echo

With both directions on, nothing bounces:

- an adopted object is never exposed: exposure skips foreign objects;
- a MoltenCodes object exposed into LibDataBroker comes back through `LibDataBroker_DataObjectCreated` while `New` is still running, finds its name already held and is not adopted;
- a mirrored attribute write comes back through `LibDataBroker_AttributeChanged`, finds a MoltenCodes object under that name and is ignored, as is any write another addon makes into our mirror.

## Secret values

On Retail 12.x the client hands tainted code secret values that raise when compared or used as table keys. BrokerKit asks `issecretvalue` before any comparison:

- a secret **name** or **attribute name** is refused at the caller in every method, and skipped when it comes from LibDataBroker;
- a secret value for a **known attribute** is refused at the caller (`BrokerKit.Object:Set attribute "text" must not be a secret value`), because displays format those and LibDataBroker compares them;
- a secret value for a **custom attribute** is stored without being compared, so every write of it counts as a change and fires, and it is never mirrored into LibDataBroker; a secret foreign value is kept the same way;
- a secret **receiver** is reported as a call without the facade (`BrokerKit:Get must be called on the BrokerKit facade; use BrokerKit:Get(...)`), and a `LibDataBroker_AttributeChanged` whose data object is secret is ignored, both without comparing it.

Absence of a value BrokerKit did not create (an argument, a definition or limits field, anything LibDataBroker hands over) is tested with `type`, never with `== nil`: that is the repository rule, which never compares anything. A secret compared with `nil` happens not to raise; one compared with a value of its own type, or used as a table key, does (measured on Retail 12.1.0 b69933).

`issecretvalue` is looked up at every call; without it nothing is secret. See [`docs/EMBEDDING.md`](../../../docs/EMBEDDING.md#secret-values-retail-12x).

## Limits

| Limit | Default | How to open | UNBOUNDED allowed? |
|---|---|---|---|
| `maxObjects` | 256 (`MAX_OBJECTS`) | `BrokerKit:SetLimits({ maxObjects = n })` | Yes |
| `maxAttributes` | 32 (`MAX_ATTRIBUTES`) | `BrokerKit:SetLimits({ maxAttributes = n })` | Yes |

```lua
BrokerKit:SetLimits({ maxObjects = 1024 })
BrokerKit:SetLimits({ maxAttributes = BrokerKit.UNBOUNDED })
local limits = BrokerKit:GetLimits() -- a fresh table; allocates
```

`SetLimits` accepts any subset of the limits and returns nothing. It raises at the caller's line, **before changing anything**, when `limits` is not a table, names an unknown limit (`BrokerKit:SetLimits limits.<name> is not a recognised limit`), or gives a secret or invalid value: each limit must be a positive integer or `BrokerKit.UNBOUNDED`. `GetLimits` returns a new table on every call, with `BrokerKit.UNBOUNDED` itself for a lifted limit.

Both limits accept `UNBOUNDED` and have no ceiling: objects and their attributes are the consumers' own data, one object per panel entry an addon publishes, held by the displays that show them; nothing is sorted or scanned per frame. `maxObjects` counts every object, adopted ones included, so a large LibDataBroker population is raised for by the display addon that adopts it. `maxAttributes` counts the attributes an object holds now, the default `type` included; clearing one frees a slot.

**The limits are shared by every consumer in the session**: every embedded copy and every addon uses one set, like the objects themselves. Lowering a limit removes nothing: objects and attributes that exist stay, a further object or attribute raises, until the count is under the limit again.

## Error behaviour

Argument failures report the line that called the public method (or wrote the field), never a line inside BrokerKit. Messages name the method (`BrokerKit:New`, `BrokerKit.Object:Set`) and the argument. Calling an object method with `.` instead of `:` raises `BrokerKit.Object:Set must be called on a broker object; use object:Set(...)`; calling a facade method without the facade raises `BrokerKit:New must be called on the BrokerKit facade; use BrokerKit:New(...)`.

A duplicate name and a limit reached are errors, not results, because both are the writing addon's mistake: names are the addon's own, and a limit is opened in its code. The bridge methods return `false, reason` instead, because a missing library is not a mistake.

## Performance

| Operation | Cost |
|---|---|
| `object.attr` (read) | Two table lookups: the empty proxy, then the attributes (`name` three, the methods four). No function call, no allocation. |
| `object.attr = v`, `object:Set` to the same value | The checks, one secret probe per side, one comparison. No fire, no allocation. |
| `object.attr = v`, `object:Set` to a new value | The above, one store, one LibDataBroker write when exposed, one signal fire per list that has a listener (the attribute's, the any list). No allocation. |
| `object:Get` | The name checks and one table read. No allocation. |
| `BrokerKit:Get` | The name checks and one table read. No allocation. |
| `Iterate` unchanged | One version comparison per call, one position lookup and one array read per step. No allocation. |
| `Iterate` / `Objects` after an object was added | O(n log n) for n objects; one new array (and one copy for `Objects`). |
| `New` | Seven small tables (proxy, two metatables, identity, attributes, record, its attribute-signal map) and the definition copy; one `NewDataObject` when exposed; the signal's dispatch. |
| `OnChange` first subscription on an object or attribute | One signal. |
| `ExposeToLibDataBroker` | One `NewDataObject` and one attribute copy per object. |
| `AdoptFromLibDataBroker` | O(n log n) for n data objects; one temporary name array, and one per data object for its attribute names. |
| `GetLimits` | One table. |

## Embedded copies and upgrades

Several addons may embed BrokerKit; Registry selects the newest compatible revision and every copy shares one facade. An upgrade happens in place: objects and their identity, connections, the sorted name cache, the limits a consumer set, the `UNBOUNDED` sentinel, and the LibDataBroker exposure, adoption and subscription all survive. Each proxy's `__newindex` and the callbacks LibDataBroker holds dispatch through package state, so a newer revision replaces their behaviour without touching existing objects or subscribing again; the object methods are rewritten on the shared prototype every object reads through.

Nothing survives `/reload`: addons create their objects again.

## Deviations from the planned contract

The nine-point plan in `docs/ROADMAP.md` is followed except where recorded here:

- **LibStub directly, not through the LibStub bridge.** Point 3 lists `interopKit` as optional "through `Registry:Find`". BrokerKit reads `rawget(_G, "LibStub")` itself, as MediaKit does: it needs LibDataBroker's methods and callbacks, which the bridge's Registry entry does not add. `interopKit` is therefore not declared as an optional dependency either.
- **Field writes notify too.** Point 5 says attributes "change through `Set` for notification". A plain field write runs the same path, so an addon ported from LibDataBroker keeps its `obj.text = ...` lines and still notifies; `Set` is the explicit form.
- **`icon` and `value` accept a number** as well as a string; see [Attributes](#attributes).
- **Additions:** `Iterate`, `IsForeign`, `object:Get`, the `"already"` result of the bridge methods, `MAX_OBJECTS`, `MAX_ATTRIBUTES`, `GetLimits` and `UNBOUNDED`.
- **Name collisions** are resolved by whoever held the name first, with the MoltenCodes object never displaced and never adopted over; see [`AdoptFromLibDataBroker`](#brokerkitadoptfromlibdatabroker).
- **Listener errors propagate** to the writer of a MoltenCodes object, as SignalKit's `Fire` does, after the value was stored; they are not isolated. On the foreign path the client's CallbackHandler isolates them instead; see [`AdoptFromLibDataBroker`](#brokerkitadoptfromlibdatabroker).
