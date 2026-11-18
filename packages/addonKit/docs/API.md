# AddonKit API

AddonKit API generation 1, implementation revision 1. Parts: Database revision
1, Composition revision 1.

## Loading

Runtime files load in this order:

```text
Registry.lua
AddonKit.lua
parts/AddonKit-Composition.lua   (optional)
parts/AddonKit-Database.lua      (optional)
```

The core needs only Registry API 2. A part needs the core loaded first and
raises at load otherwise:

```text
MoltenCodes AddonKit part Database requires AddonKit API 1 to be loaded first
```

Every other Kit is found through `Registry:Find` when it is first used, so it
may load before or after AddonKit. AddonKit does not rely on `require()` at
runtime.

### Host facilities

| Facility | Used by | Without it |
|---|---|---|
| `issecretvalue` | every argument check; read once at load, and again on each check only when it was absent at load | Nothing is treated as secret. |
| `geterrorhandler` | the report of a foreign `MoltenCodes.For` | The report is printed, also when the handler itself raises. |

AddonKit calls no other client function, creates no frame, registers no event
and runs nothing per frame. The Kits it calls read their own host facilities.

## Public surface

The package facade, `MoltenCodes.Registries[2]:Get("addonKit", 1)`:

| Field | Purpose |
|---|---|
| `For(addonName, ...)` | The addon's facade; the same function as `MoltenCodes.For`. |
| `GetCatalogue()` | A fresh `{ [facadeName] = { packageId, api } }` of every Kit a facade hands out. |
| `SetLimits(limits)` / `GetLimits()` | `maxFacades` (see [Limits](#limits)). |
| `API` | `1`. |
| `REVISION` | The implementation revision active in the session (`2`). |
| `MAX_FACADES` | `256`, the default of `maxFacades`. |
| `FACADES_CEILING` | `4096`, the highest `maxFacades` accepts. |

The addon's facade, `local MC = MoltenCodes:For(...)`:

| Member | Purpose | Part |
|---|---|---|
| `addonName` | The addon's folder name. | core |
| `<Kit>` | Every Kit in the catalogue, by facade name. | core |
| `S` | SchemaKit. | core |
| `Registry` | Registry API 2. | core |
| `Use(facadeName, generation)` | Pin a Kit's API generation for this addon. | core |
| `NewAddon(definition?)` | The addon object. | core |
| `NewModule(name, definition?)` | A module of the addon. | core |
| `GetAddon()` | The addon object. | core |
| `GetModule(name)` | A module. | core |
| `SetDefaultModuleState(enabled)` | The starting intent of modules created from now on; never the addon object's. Revision 2. | core |
| `SetDefaultModulePrototype(prototype)` | The prototype of modules created from now on, or `nil`. Revision 2. | core |
| `OnModuleCreated(callback)` / `OnModuleCreated(receiver[, methodName])` | Hear of every module created from now on. Revision 2. | core |
| `Database(savedVariable, defaults, options?)` | A SettingsKit database from plain defaults. | Database |
| `Range(min, max, default)` | An optional bounded number node. | Database |
| `Enum(values, default)` | An optional choice node. | Database |
| `Options(tree, settings?)` | An options panel, with a slash command that opens it. | Composition |
| `Launcher(definition, db, field?)` | A minimap button kept in the profile. | Composition |
| `LAUNCHER_DEFAULTS` | LibDBIcon-1.0's three saved fields. | Composition |

Methods are called with a colon (`MC:NewAddon()`); `Range` and `Enum` build
schema nodes and are called with a dot (`MC.Range(0.5, 2, 1)`), as SchemaKit's
builders are.

## `MoltenCodes:For(addonName, ...)`

```lua
local MC = MoltenCodes:For(...)
```

Returns the facade of `addonName`, created on the first call; every later call
for that name, from any file, returns the same table. Pass the file's `...`
as it is: the first value is the addon's folder name, and the second (the
addon's private table) is ignored.

`For` is the stable entry function AddonKit installs at `MoltenCodes.For`. It
is installed when the key is empty or already holds that function; any other
value is left alone and reported once through `geterrorhandler()`:

```text
MoltenCodes AddonKit: MoltenCodes.For is owned by another value, so it was left alone; use MoltenCodes.Registries[2]:Get("addonKit", 1):For(...)
```

`AddonKit:For(...)` is the same function and always works.

Raised at the caller:

```text
MoltenCodes:For is called with a colon: local MC = MoltenCodes:For(...)
MoltenCodes:For addonName must not be a secret value
MoltenCodes:For addonName must be the addon's folder name, a non-empty string: local MC = MoltenCodes:For(...)
MoltenCodes:For holds at most 256 addon facades; raise maxFacades with AddonKit:SetLimits
```

## Reading a Kit: `MC.<Kit>`

The first read of `MC.TimerKit` calls `Registry:Find("timerKit", generation)`
and stores the answer on the facade with `rawset`; every later read is a plain
field read and allocates nothing. The stored value is the shared Kit table,
which Registry keeps the same across in-place upgrades, so it never goes
stale.

The catalogue (`AddonKit:GetCatalogue()`) holds every Kit of the repository
except Registry: ApiKit, BarKit, BindingKit, BridgeKit, BrokerKit, CacheKit,
ClientKit, CodecKit, CommandKit, CommKit, CompatKit, DialogKit, EditModeKit,
EventKit, GlowKit, HookKit, InteropKit, LauncherKit, LifecycleKit, LocaleKit,
LogKit, MediaKit, MenuKit, ModuleKit, OptionsKit, PanelKit, PoolKit,
ProfileKit, RangeKit, ReadinessKit, SchedulerKit, SchemaKit, SettingsKit,
SignalKit, TestKit, TimerKit, ToastKit, TooltipKit, UnitFrameKit and
WidgetKit, each at API 1. The package ID is the facade name with its first
letter lower-cased.

**Generations.** An entry's generation never changes inside AddonKit API 1.
New Kits only add entries. An addon that wants another generation pins it
before the first read; the pin is shared by every file of the addon:

```lua
MC:Use("TimerKit", 2)
local TimerKit = MC.TimerKit -- API 2, or the error below
```

Raised at the reading line, and nothing is stored:

```text
MyAddon uses MoltenCodes TimerKit (API 1), which is not loaded. Add timerKit\TimerKit.lua to embeds.xml after the files it needs, or rebuild embeds.xml with the build tool (docs/EMBEDDING.md, "Load order")
MyAddon uses MoltenCodes TimerKit API 2, but only another API generation of it is loaded. Embed a copy of timerKit\TimerKit.lua that provides API 2, or pin the loaded one with MC:Use
MyAddon uses MoltenCodes TimerKit API 1, which was retired by an unfinished upgrade this session; /reload
```

A name that is neither a Kit nor a member raises, with the closest name when
one is near: a different case, a missing `Kit` suffix, or at most two edits
away, over Kits, methods and fields.

```text
MoltenCodes has no Kit or helper named Timerkit; did you mean MC.TimerKit?
MC has no member of type number; read a Kit by name, such as MC.TimerKit
```

A member of a part that is not loaded raises with the file:

```text
MC:Database is in AddonKit's Database part, which is not loaded: add addonKit\parts\AddonKit-Database.lua to embeds.xml after addonKit\AddonKit.lua
```

The facade refuses writes, at the writing line:

```text
MC (the MoltenCodes facade of MyAddon) holds Kits and helpers only; keep db on your addon object
```

`getmetatable(MC)` answers `"AddonKit.Facade"`.

## `MC:Use(facadeName, generation)`

Pins the generation `facadeName` resolves at for this addon. Calling it again
with the same generation, or after a read at that same generation, does
nothing. Raised at the caller:

```text
MC:Use facadeName must be a non-empty string
MC:Use facadeName: MoltenCodes has no Kit or helper named Timerkit; did you mean MC.TimerKit?
MC:Use generation must not be a secret value
MC:Use generation must be a positive integer
MC:Use SignalKit was already read at API 1; call MC:Use before the first read of MC.SignalKit
```

## The addon object

### `MC:NewAddon(definition?)`

Returns the module `"Main"` of the addon's ModuleKit container,
`ModuleKit:ForAddon(addonName):CreateModule("Main", definition)`. It is
ModuleKit's module, not a wrapper:

- `OnInitialize` runs at the addon's loaded phase (its `ADDON_LOADED`),
  `OnEnable` at the ready phase (login), `OnDisable` on `Disable()` and at
  logout;
- `self.scope.Events`, `.Timers`, `.Hooks`, `.Commands`, `.Comm`, `.Jobs` and
  `.Messages` own what the addon registers while it is enabled, and are
  released when it is disabled (ModuleKit, "Module scopes");
- every other field is yours: `self.db`, your methods.

`definition` is passed to `CreateModule` as it is (ModuleKit, "Creating
modules"). Method-name callbacks work through the scope exactly as the runtime
Kits support them: the addon object is a plain receiver, and AddonKit adds no
mixin methods to it.

Raised at the caller:

```text
MC:NewAddon is called with a colon on a facade: MC:NewAddon(...)
MC:NewAddon definition must be a ModuleKit definition table or nil
MC:NewAddon MyAddon already has its addon object; read it with MC:GetAddon(), or create a module with MC:NewModule(name)
MyAddon uses MoltenCodes ModuleKit (API 1), which is not loaded. ...
```

and every refusal of `CreateModule`, with ModuleKit's message.

### `MC:NewModule(name, definition?)`

Creates a module that depends on the addon object (`DependsOn("Main")`): the
addon initializes and enables before it, and disabling the addon disables it,
as AceAddon-3.0 does with its modules. The module may be created before the
addon object, in an earlier file; the dependency is resolved when the
container first initializes. A definition table is copied, with `"Main"` put
first in its `dependsOn` (once).

A module created after the addon has loaded follows ModuleKit's rules for late
modules: configure it and call `module:Activate()`, or pass a definition table.

Raised at the caller:

```text
MC:NewModule name must not be a secret value
MC:NewModule name must be a non-empty string
MC:NewModule the name Main belongs to the addon object; create it with MC:NewAddon()
MC:NewModule definition must be a ModuleKit definition table or nil
```

### `MC:GetAddon()` and `MC:GetModule(name)`

Return the addon object or a module, for the addon's other files. Raised at the
caller:

```text
MC:GetAddon MyAddon has no addon object yet; create it with MC:NewAddon() in the file the .toc loads first
MC:GetModule MyAddon has no module named Bags; create it with MC:NewModule("Bags")
```

### Module defaults and the created notice

`MC:SetDefaultModuleState(enabled)`, `MC:SetDefaultModulePrototype(prototype)`
and `MC:OnModuleCreated(callback | receiver[, methodName])` call the addon
container's ModuleKit methods of the same names (ModuleKit revision 23 and
later, docs/API.md of ModuleKit, "Intent versus fact", "Module prototypes" and
"The module-created notice") and return what they return; ModuleKit's refusals
are raised at the author's line. They are AceAddon-3.0's
`MyAddon:SetDefaultModuleState(false)`, `SetDefaultModulePrototype` and
`OnModuleCreated`, on `MC` because the addon object is itself a module.
`MC:NewModule(name, { enabledState = false, prototype = Shared })` passes the
two definition fields through as it passes every other.

```lua
local addon = MC:NewAddon()
MC:SetDefaultModuleState(false)        -- modules start off; the addon does not
MC:SetDefaultModulePrototype(BagModule)
function addon:OnModuleCreated(module) end
MC:OnModuleCreated(addon)              -- after the method exists
```

The module default never applies to the addon object, as in AceAddon: when it
is `false` and `MC:NewAddon()` is called after it, the new addon object's
intent is set back to `true` (unless its definition says `enabledState =
false`), so the addon still enables at login. A default prototype set before
`MC:NewAddon()` does apply to the addon object; set the defaults after
`MC:NewAddon()`, as AceAddon requires. With a ModuleKit older than revision 23
each method raises `MC:SetDefaultModuleState needs ModuleKit revision 23 or
later; update the copy of moduleKit your addon embeds` (and the same for the
other two).

## Database part

### `MC:Database(savedVariable, defaults, options?)`

```lua
local defaults = {
  profile = {
    scale = MC.Range(0.5, 2, 1),
    anchor = MC.Enum({ "TOP", "CENTER" }, "TOP"),
    greet = true,
    auras = { ["*"] = { shown = true } },
    notes = {},
    minimap = MC.LAUNCHER_DEFAULTS,
  },
  global = { installs = 0 },
}

function addon:OnInitialize()
  self.db = MC:Database("MyAddonDB", defaults)
end
```

Opens `SettingsKit:Open(savedVariable, schema, options)` with the schema
inferred from `defaults`. The keys of `defaults` are SettingsKit's scopes:
`profile`, `global`, `char`, `realm`, `class` and `faction`. `options` are
`SettingsKit:Open`'s (`defaultProfile`, `version`, `migrations`, ...).

The inference:

| Default | Schema |
|---|---|
| `true`, `1`, `"text"` | `optional(boolean / number / string, value)`. Strings are bounded at 4096 bytes (or the default's length when longer). Numbers are not made integers: `scale = 1` accepts 1.5. |
| `{ a = ..., b = ... }` | An optional record of the inferred fields. |
| `{}` | A free-form bag: a `map` of strings (at most 256 bytes) or numbers to `any`, at most 1024 entries. |
| `{ ["*"] = default }` | A `map` of the same keys, at most 1024 entries, whose every key reads `default` until written, as AceDB's wildcard does. |
| `{ 1, 2, 3 }`, `{ "a", "b" }` | An optional `array` of that one type, with the list as its default. |
| A SchemaKit node or sealed schema | Itself, made optional when it is not. A scope given as a node is used as it is. |

The inference gives every field a type and every map a bound, which is what
SettingsKit's guarantees need. It adds no ranges or choices: write those
inline with `MC.Range`, `MC.Enum` or a SchemaKit node. A field whose default
would be `nil` cannot be inferred; declare it with a node
(`label = MC.S.string({ max = 32 })`).

The database refuses to open before the addon's `ADDON_LOADED`, which it asks
LifecycleKit: the client restores the saved variable only then and would
replace what an earlier open created. Open it in `OnInitialize`.

A second call for the same saved variable returns the same database when it is
given the same defaults table, and raises otherwise (SettingsKit refuses a
second schema for an open name, and an inferred schema is always new).

Raised at the caller:

```text
MC:Database is called with a colon on a facade: MC:Database(...)
MC:Database savedVariable must not be a secret value
MC:Database savedVariable must be a non-empty string
MC:Database defaults must be a table: { profile = { ... }, global = { ... } }
MC:Database options must be a table of SettingsKit:Open options or nil
MC:Database MyAddonDB is already open with another defaults table; open it once and keep the database (self.db)
MyAddon opened MyAddonDB before ADDON_LOADED; open it in OnInitialize, after the client restored it
MC:Database defaults has the scope factionrealm, which SettingsKit does not have; its scopes are profile, global, char, realm, class, faction
MC:Database defaults must hold at least one scope, such as profile = { ... }
MC:Database defaults.profile must be a table of defaults
MC:Database defaults profile.list uses ["**"], which has no SettingsKit form; give each key its defaults, or use ["*"] alone
MC:Database defaults profile.list puts ["*"] beside named keys, which has no SettingsKit form; move the named keys into a record of their own, or keep ["*"] alone
MC:Database defaults profile.callback is a function; a default is a boolean, number, string, table or schema node
MC:Database defaults profile has a number key; record keys are non-empty strings (use ["*"] for a keyed bag)
MC:Database defaults profile.mixed is a list of mixed or table values; write its schema node inline (MC.S.array{ of = ... })
MC:Database defaults profile.deep nest deeper than 16 tables
```

The "not loaded" message for LifecycleKit, SchemaKit or SettingsKit, and every
refusal of `SettingsKit:Open`, with SettingsKit's message.

### `MC.Range(min, max, default)` and `MC.Enum(values, default)`

```lua
scale = MC.Range(0.5, 2, 1)                     -- optional(number{ min = 0.5, max = 2 }, 1)
anchor = MC.Enum({ "TOP", "CENTER" }, "TOP")    -- optional(enum{ "TOP", "CENTER" }, "TOP")
```

Raised at the caller: a secret argument; a colon call
(`MC.Range is called with a dot: MC.Range(min, max, default)`); `MC.Range takes
three numbers`; `MC.Enum values must be a list of strings, numbers or booleans`;
`MC.Enum needs a default, one of the values`; SchemaKit's own refusals (a
`min` above `max`, a default outside the range or the list); and, when
SchemaKit is not loaded,
`This needs MoltenCodes SchemaKit (API 1), which is not loaded. ...`.

## Composition part

### `MC:Options(tree, settings?)`

```lua
self.panel = MC:Options(tree, { db = self.db, slash = "myaddon", title = "My Addon" })
```

In order: registers the slash command `/<slash>` on the addon's CommandKit
scope (`CommandKit:ForAddon(addonName)`), whose handler opens the panel;
defines `tree` with `OptionsKit:Define(addonName, tree, { db = settings.db })`;
registers it with `PanelKit:Register(addonName, { name = title })`. Returns the
panel. `title` defaults to the tree's `name`, then to the addon's name.

The command is registered first so that a refused name leaves no tree and no
panel. When `Define` or `Register` raises after it, the command is
unregistered before the error is raised again. CommandKit's refusals, which
`Register` returns as values, are raised:

```text
MC:Options /myaddon is already used by another addon or a chat command; pass another slash name to MC:Options
MC:Options /dance is an emote's command; pass another slash name to MC:Options
MC:Options /myaddon cannot be added: the addon's CommandKit scope holds its most commands; unregister one or raise maxCommands
```

Also raised at the caller:

```text
MC:Options tree must be an OptionsKit tree: { type = "group", name = ..., args = { ... } }
MC:Options settings must be a table { db, slash, title } or nil
MC:Options settings holds an unknown field; it accepts db, slash and title
MC:Options settings.slash must be a non-empty string
MC:Options settings.title must be a non-empty string
```

and OptionsKit's, PanelKit's and CommandKit's own refusals with their messages.

### `MC:Launcher(definition, db, field?)`

```lua
MC:Launcher({ icon = 134400, OnClick = function() addon.panel:Open() end }, self.db)
```

Creates the BrokerKit object named after the addon from a copy of
`definition` (`type = "launcher"` unless given), registers a LauncherKit button
whose storage is `db.profile[field]` (`field` defaults to `"minimap"`), and
connects `db:OnProfileChanged` to `launcher:Refresh()`, so a profile switch
moves the button. Returns the launcher.

Before creating anything it asks `db:Validate("profile", { field }, ...)`
whether the profile takes LibDBIcon's three fields there:

```text
MC:Launcher the database does not take profile.minimap (<SettingsKit's reason>); declare minimap = MC.LAUNCHER_DEFAULTS in the profile defaults
```

Also raised at the caller: `MC:Launcher definition must be a table of BrokerKit
attributes`, `MC:Launcher db must be a database from MC:Database (or
SettingsKit:Open)`, `MC:Launcher field must be a non-empty string`, and
BrokerKit's and LauncherKit's own refusals. A BrokerKit object lives for the
session: when LauncherKit refuses after BrokerKit created it, the object stays.

### `MC.LAUNCHER_DEFAULTS`

`{ hide = false, lock = false, minimapPos = 225 }`: a fresh table for each
addon, made on its first read, so one addon editing it never changes another's.

## Secret values

Every argument, key, limit and receiver is checked with `issecretvalue` before
it is compared or used as a table key, and a secret is refused at the caller
with a message that says so (`MoltenCodes:For addonName must not be a secret
value`). The probe is read once at load; a host that had none at load is
asked again on each check, so a probe installed later is honoured, while one
that replaces the probe present at load is not (revision 3).

## Limits

| Limit | Default | Range | Meaning |
|---|---|---|---|
| `maxFacades` | `256` | 1 to 4096 | Addons holding a facade in the session. |

`AddonKit:SetLimits({ maxFacades = n })` changes it for the session; lowering
it keeps every facade. A facade is kept for the session, so there is no
unbounded setting. `GetLimits` returns a fresh table. Raised at the caller:

```text
AddonKit:SetLimits must be called on the AddonKit facade; use AddonKit:SetLimits(...)
AddonKit:SetLimits limits must be a table
AddonKit:SetLimits limits holds an unknown field; it accepts maxFacades
AddonKit:SetLimits limits.maxFacades must not be a secret value
AddonKit:SetLimits limits.maxFacades must be an integer from 1 to 4096
```

## Error behaviour

Every error is raised at the line that called AddonKit: the line that read or
wrote the facade field, or the line that called the method. A refusal of
another Kit that AddonKit calls is raised again at that line with the Kit's
own message, AddonKit's position removed. An error object that is not a string
is raised again as it is.

What AddonKit reports instead of raising (a foreign `MoltenCodes.For` left
alone) goes to the host error handler (`geterrorhandler()`), called under
`pcall`. When the host has no handler, or the handler itself raises (an
error-display addon with a bug), the report is printed instead, so it never
raises into the loading file (revision 3; earlier revisions let a raising
handler's error through).

## Performance

| Operation | Cost |
|---|---|
| `MC.<Kit>`, after the first read | One field read; no allocation. |
| `MC.<Kit>`, first read | One `Registry:Find` and one field stored (about 33 bytes). |
| `MoltenCodes:For`, first call per addon | One facade (about 450 bytes with its record). |
| A method call on `MC` | One `__index` function call; meant for setup, not hot paths. |
| `MC:Database` | The inference allocates the schema nodes SettingsKit needs anyway, once. |

Resident after loading, host Lua 5.1.5 with debug info kept: core 40.6 KB,
Database part 17.7 KB, Composition part 9.8 KB (measured 2026-11-15).

## Embedded copies and upgrades

Every embedded copy shares `AddonKit._state`. The highest revision wins and
takes over in place: the facades, their cached Kits and pins, the facade
metatable (its `__index` and `__newindex` are stable closures that dispatch
through the state), the namespace entry (one function for the session) and
the parts. A part keeps its own revision in the state; a part file of an equal
or lower revision than the one installed loads as a no-op. Revision 2 adds the
three module-default methods to `_state.methods`, so facades made by revision
1 gain them through the shared metatable. Revision 3 changes no state field:
it replaces the secret check, the error report and the facade check with the
shared helper blocks, and its upgrade over revision 2 keeps every facade and
limit. See
[`INTERNALS.md`](INTERNALS.md).

## Dependencies

| Package | API | Kind | For |
|---|---|---|---|
| Registry | 2 | required | everything |
| ModuleKit, LifecycleKit | 1 | optional | the addon object |
| LifecycleKit, SchemaKit, SettingsKit | 1 | optional (Database part) | `MC:Database`, `MC.Range`, `MC.Enum` |
| OptionsKit, PanelKit, CommandKit | 1 | optional (Composition part) | `MC:Options` |
| BrokerKit, LauncherKit | 1 | optional (Composition part) | `MC:Launcher` |
| every catalogue Kit | 1 | optional | `MC.<Kit>` |
