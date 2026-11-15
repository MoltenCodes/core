# AddonKit

AddonKit is the one way in for addon authors. `local MC = MoltenCodes:For(...)`
at the top of every file gives the addon its facade: every Kit by name
(`MC.TimerKit`, `MC.EventKit`, ...), an addon object with `OnInitialize`,
`OnEnable` and `OnDisable`, a database from a plain defaults table, and one-call
helpers for an options panel with its slash command and for a minimap button.

```lua
local MC = MoltenCodes:For(...)
local addon = MC:NewAddon()

function addon:OnEnable()
  self.scope.Events:Connect("PLAYER_ENTERING_WORLD", function(event, isInitialLogin)
    if isInitialLogin then
      print("Hello from " .. MC.addonName)
    end
  end)
end
```

What each piece promises:

- **Nothing new underneath.** Every call AddonKit makes is a documented API 1
  call of another Kit. Validation, bounds, secret-value checks, ownership and
  error levels stay those Kits'. AddonKit adds lookups, defaults and errors
  that say the fix.
- **Free after the first read.** `MC.TimerKit` is found through
  `Registry:Find` on the first read and stored on the facade, so every later
  read is a plain field read. A facade costs about 450 bytes per addon.
- **Explicit generations.** Each Kit is handed out at the API generation
  AddonKit API 1 records for it, which never changes inside AddonKit API 1.
  `MC:Use("TimerKit", 2)` asks for another one, before the first read.
- **Errors at your line, with the fix.** A Kit missing from `embeds.xml`, a
  misspelt name (`did you mean MC.TimerKit?`), a database opened before the
  client restored its saved variable, a slash command another addon owns, a
  minimap button whose storage the profile does not declare: each raises at
  the line that caused it and names what to change.
- **Optional.** No Kit depends on AddonKit. An addon that does not embed it
  pays nothing. The database and the composition helpers are separate part
  files, embedded only when used.

Non-goals: Ace-style mixins (`self:RegisterEvent`) on the addon object, a
second options or database implementation, LibStub emulation (BridgeKit's), and
generating `embeds.xml` (the build tool does it).

## First addon in 10 minutes

### 1. Get the Kits

Download a MoltenCodes release, or build the bundle from a clone of the
repository, and copy it into your addon as `Libs\MoltenCodes`. Then generate
the `embeds.xml` that loads the Kits you use, in order, from your addon's
folder:

```sh
python3 -m tooling.package.embeds addonKit eventKit moduleKit \
  --root 'Libs\MoltenCodes' --out embeds.xml
```

That is the first step's set: Registry, AddonKit, SignalKit, EventKit,
LifecycleKit and ModuleKit, six files. Each later step adds Kits or parts to
the command (`addonKit/Database`, `settingsKit`, ...), and the generator puts
their dependencies in front of them.

### 2. The `.toc`

```toc
## Interface: 120105
## Title: First Addon
## SavedVariables: FirstAddonDB

embeds.xml
Core.lua
```

### 3. The addon

`Core.lua` is the snippet at the top of this page. `/reload`, and the greeting
prints once per login. `self.scope.Events` belongs to the addon object: when
the addon is disabled, everything it connected is disconnected.

### 4. A database

```lua
local defaults = {
  profile = { greet = true, scale = MC.Range(0.5, 2, 1) },
  global = { logins = 0 },
}

function addon:OnInitialize()
  self.db = MC:Database("FirstAddonDB", defaults)
end
```

The defaults are an AceDB-style table. AddonKit infers the schema from them:
`greet` accepts only booleans, `logins` only numbers, and `scale`, written with
`MC.Range`, only numbers from 0.5 to 2. A write of the wrong type raises at the
writing line. Defaults give you types; write `MC.Range`, `MC.Enum` or a
SchemaKit node where a field needs bounds. `OnInitialize` runs after the
client restored the saved variable; `MC:Database` refuses to open earlier.

### 5. Options and a slash command

```lua
self.panel = MC:Options({
  type = "group",
  name = "First Addon",
  args = {
    greet = { type = "toggle", name = "Greet me", bind = "profile.greet" },
    scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, bind = "profile.scale" },
    profiles = MC.OptionsKit:ProfileOptions(self.db),
  },
}, { db = self.db, slash = "firstaddon" })
```

The panel is in Blizzard's settings under AddOns, and the slash command opens
it. `bind` reads and writes the database field directly. If another addon
already owns the command's name, `MC:Options` raises with that fix instead of
losing the command.

### 6. A minimap button

```lua
-- In the profile defaults: minimap = MC.LAUNCHER_DEFAULTS
MC:Launcher({
  icon = "Interface\\Icons\\INV_Misc_Gear_01",
  OnClick = function()
    addon.panel:Open()
  end,
}, self.db)
```

The button's position, its hidden and locked state are kept in
`db.profile.minimap`, and a profile switch moves it.

The getting-started guide (`docs/GETTING_STARTED.md`) walks through the same
steps with every file shown, and ends in an addon that does ten common tasks.
Every one of its snippets is a fixture this package's specs run.

## The facade

| Member | What it is |
|---|---|
| `MC.addonName` | The addon's folder name. |
| `MC.<Kit>` | Every Kit by facade name: `MC.TimerKit`, `MC.EventKit`, `MC.SettingsKit`, ... |
| `MC.S` | SchemaKit, under the short name the documentation uses. |
| `MC.Registry` | Registry API 2. |
| `MC:Use(name, generation)` | Pin the API generation a Kit resolves at, before its first read. |
| `MC:NewAddon(definition?)` | The addon object: ModuleKit's module `"Main"`. |
| `MC:NewModule(name, definition?)` | A module that depends on the addon object. |
| `MC:GetAddon()`, `MC:GetModule(name)` | The objects, from any file of the addon. |
| `MC:Database(savedVariable, defaults, options?)` | Database part: a SettingsKit database from plain defaults. |
| `MC.Range(min, max, default)`, `MC.Enum(values, default)` | Database part: the two schema nodes defaults most often need. |
| `MC:Options(tree, { db, slash, title })` | Composition part: OptionsKit, PanelKit and CommandKit in one call. |
| `MC:Launcher(definition, db, field?)` | Composition part: BrokerKit and LauncherKit in one call. |
| `MC.LAUNCHER_DEFAULTS` | Composition part: LibDBIcon-1.0's three saved fields, for the profile defaults. |

`MoltenCodes:For` is installed on the shared namespace by AddonKit; the same
function is `AddonKit:For`, so
`MoltenCodes.Registries[2]:Get("addonKit", 1):For(...)` works too.

### Language server

AddonKit declares the facade with full LuaCATS types, so lua-language-server
completes `MC.` and every Kit read through it, and flags a misspelt member of
`MC`, of a Kit and of a database. Add the bundle's folders to your
workspace library. The addon object accepts any field you add (`self.db`), so
a call chained straight through it, `self.scope.Timers:After(...)`, is not
checked; the same call through a local (`local timers = self.scope.Timers`)
is.

### Moving from Ace3

| Ace3 | AddonKit |
|---|---|
| `LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceEvent-3.0", "AceTimer-3.0")` | `local MC = MoltenCodes:For(...)`, `local addon = MC:NewAddon()` |
| `addon:OnInitialize()`, `OnEnable()`, `OnDisable()` | the same three hooks on the addon object |
| `addon:NewModule("Bags")`, `addon:EnableModule("Bags")` | `MC:NewModule("Bags")`, `module:Enable()`; the module depends on the addon, as Ace's modules do |
| `LibStub("AceAddon-3.0"):GetAddon("MyAddon")` | `MC:GetAddon()` |
| `self:RegisterEvent("BAG_UPDATE")`, `UnregisterEvent` | `self.scope.Events:Connect("BAG_UPDATE", handler)`, `connection:Disconnect()`; released when the addon is disabled |
| `self:ScheduleTimer(func, 5)`, `ScheduleRepeatingTimer` | `self.scope.Timers:After(5, func)`, `Every(60, func)` |
| `self:SecureHook("ToggleGameMenu", func)` | `self.scope.Hooks:SecureHook("ToggleGameMenu", func)` |
| `LibStub("AceDB-3.0"):New("MyAddonDB", defaults, true)` | `MC:Database("MyAddonDB", defaults)`: the same defaults table, `["*"]` and `{}` included; writes are type-checked |
| AceConfig `get`/`set`, `AceConfigDialog:AddToBlizOptions`, `AceConsole:RegisterChatCommand` | `bind = "profile.field"` and `MC:Options(tree, { db, slash })` |
| `LibStub("LibDataBroker-1.1"):NewDataObject` plus `LibDBIcon:Register(name, object, db.profile.minimap)` | `MC:Launcher(definition, db)` with `minimap = MC.LAUNCHER_DEFAULTS` in the profile defaults |

What differs: a database refuses wrong types and undeclared fields, which AceDB
stores silently; `pairs(db.profile)` visits nothing, use `db:Pairs(db.profile)`;
`["**"]` and `["*"]` beside named keys have no SettingsKit form and raise with
the alternative; method-name callbacks (`"OnBagUpdate"`) follow the runtime
Kits' own support.

See [`docs/API.md`](docs/API.md) for the complete contract and
[`docs/INTERNALS.md`](docs/INTERNALS.md) for the implementation.

## Embedding

[`../../docs/EMBEDDING.md`](../../docs/EMBEDDING.md) is the addon author's guide:
directory layout, supported Interface numbers, taint, `/reload` semantics and
troubleshooting. This package's load order inside a consuming addon is:

```toc
Libs\MoltenCodes\registry\Registry.lua
Libs\MoltenCodes\addonKit\AddonKit.lua
Libs\MoltenCodes\addonKit\parts\AddonKit-Composition.lua
Libs\MoltenCodes\addonKit\parts\AddonKit-Database.lua
```

Minimum footprint: embed 2 files: `registry/Registry.lua`, `addonKit/AddonKit.lua`.
The parts are optional; each needs the core loaded before it.

Direct runtime dependencies: Registry API 2. Everything else is found when it
is used: ModuleKit and LifecycleKit for the addon object, SchemaKit, SettingsKit
and LifecycleKit for `MC:Database`, OptionsKit, PanelKit and CommandKit for
`MC:Options`, BrokerKit and LauncherKit for `MC:Launcher`. A helper whose Kit
is not loaded raises with the file to add.

AddonKit creates no frame, registers no event and runs nothing per frame.
