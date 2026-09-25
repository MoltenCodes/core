# Migrating from Ace3

This guide moves an addon from Ace3 to the MoltenCodes Kits, one Ace3
library at a time. Each section shows the Ace3 code first, then the same
thing with the Kits, then the differences that change behaviour. Every
MoltenCodes sample uses the API as documented in the Kit's `docs/API.md`
today; the samples that use **BridgeKit** are marked *planned*, because that
package is designed but not implemented yet (see
[`BRIDGE_KIT_DESIGN.md`](BRIDGE_KIT_DESIGN.md)).

The Ace3 behaviour described here was read from Ace3 at commit
`5e2e0d3b3fd125ef1518744c6a9dd21f68f6e773`. References such as
`AceBucket-3.0.lua:108` point at a file and line of that commit.

## Contents

- [Before you start](#before-you-start)
- [The map](#the-map)
- [LibStub](#libstub)
- [CallbackHandler-1.0](#callbackhandler-10)
- [AceAddon-3.0](#aceaddon-30)
- [AceEvent-3.0](#aceevent-30)
- [AceTimer-3.0](#acetimer-30)
- [AceBucket-3.0](#acebucket-30)
- [AceHook-3.0](#acehook-30)
- [AceConsole-3.0](#aceconsole-30)
- [AceTab-3.0](#acetab-30)
- [AceLocale-3.0](#acelocale-30)
- [AceDB-3.0](#acedb-30)
- [AceDBOptions-3.0](#acedboptions-30)
- [AceConfig-3.0, AceConfigRegistry, AceConfigDialog, AceConfigCmd](#aceconfig-30-aceconfigregistry-aceconfigdialog-aceconfigcmd)
- [AceGUI-3.0](#acegui-30)
- [AceSerializer-3.0](#aceserializer-30)
- [AceComm-3.0](#acecomm-30)
- [Moving data and peers with BridgeKit (planned)](#moving-data-and-peers-with-bridgekit-planned)
- [What has no equivalent yet](#what-has-no-equivalent-yet)

## Before you start

**Embedding.** Ace3 libraries come in through `embeds.xml` and `LibStub`.
The Kits come in the same way: list their files in dependency order in
`embeds.xml` (each Kit's `docs/API.md` has a "Loading" section, and
[`EMBEDDING.md`](EMBEDDING.md) has the full rules and a complete example
addon). Both can be loaded side by side during a migration: the Kits never
touch Ace3's tables, and Ace3 never touches theirs.

**Resolving a Kit.** Every sample below starts from these lines, at the top of
each file of the addon:

```lua
local ADDON_NAME = ...
local Registry = MoltenCodes.Registries[2]
```

and then asks Registry for each Kit it uses, by package id and API generation:

```lua
local EventKit = Registry:Get("eventKit", 1)
```

**Ownership instead of mixins.** Ace3 embeds methods into your addon object
(`self:RegisterEvent`) and remembers what you registered on it. The Kits give
you a **scope** instead: `EventKit:ForAddon(ADDON_NAME)`,
`TimerKit:ForAddon(ADDON_NAME)` and so on, closed for you at logout, or a
module's `self.scope`, closed whenever the module is disabled. The
[ModuleKit section](#aceaddon-30) shows the module form; the other sections
show the addon form, which works without ModuleKit.

## The map

| Ace3 | Kits | Notes |
|---|---|---|
| LibStub | Registry; InteropKit for LibStub interop | [LibStub](#libstub) |
| CallbackHandler-1.0 | SignalKit signals and buses | [CallbackHandler](#callbackhandler-10) |
| AceAddon-3.0 | ModuleKit on LifecycleKit | [AceAddon](#aceaddon-30) |
| AceEvent-3.0 | EventKit (events), SignalKit buses (messages) | [AceEvent](#aceevent-30) |
| AceTimer-3.0 | TimerKit | [AceTimer](#acetimer-30) |
| AceBucket-3.0 | EventKit `Coalesce`, SchedulerKit `Coalesce` | [AceBucket](#acebucket-30) |
| AceHook-3.0 | HookKit | [AceHook](#acehook-30) |
| AceConsole-3.0 | CommandKit | [AceConsole](#aceconsole-30) |
| AceTab-3.0 | CommandKit completion, for your own commands | [AceTab](#acetab-30) |
| AceLocale-3.0 | LocaleKit | [AceLocale](#acelocale-30) |
| AceDB-3.0 | SettingsKit (schema: SchemaKit); data import: BridgeKit (planned) | [AceDB](#acedb-30) |
| AceDBOptions-3.0 | `OptionsKit:ProfileOptions` | [AceDBOptions](#acedboptions-30) |
| AceConfig-3.0, AceConfigRegistry-3.0 | OptionsKit; table conversion: BridgeKit (planned) | [AceConfig](#aceconfig-30-aceconfigregistry-aceconfigdialog-aceconfigcmd) |
| AceConfigDialog-3.0 | WidgetKit `RenderOptions` | [AceConfig](#aceconfig-30-aceconfigregistry-aceconfigdialog-aceconfigcmd) |
| AceConfigCmd-3.0 | CommandKit `BindOptions` | [AceConfig](#aceconfig-30-aceconfigregistry-aceconfigdialog-aceconfigcmd) |
| AceGUI-3.0 | WidgetKit | [AceGUI](#acegui-30) |
| AceSerializer-3.0 | CodecKit; Ace-format compatibility: BridgeKit (planned) | [AceSerializer](#aceserializer-30) |
| AceComm-3.0 (with ChatThrottleLib) | CommKit; Ace-format compatibility: BridgeKit (planned) | [AceComm](#acecomm-30) |

## LibStub

```lua
-- Ace3
local AceDB = LibStub("AceDB-3.0")
local LDB = LibStub:GetLibrary("LibDataBroker-1.1", true)
```

```lua
-- MoltenCodes
local SettingsKit = Registry:Get("settingsKit", 1)
local SchedulerKit, reason = Registry:Find("schedulerKit", 1) -- optional: nil and a reason when absent

local InteropKit = Registry:Get("interopKit", 1)
local LDB, minor = InteropKit:AdoptFromLibStub("LibDataBroker-1.1") -- nil, reason when absent
```

- `Registry:Get` returns `nil` when a Kit is not loaded; `Registry:Find` is
  the silent lookup for an optional Kit and says why it missed (`"absent"`,
  `"generation_mismatch"`, `"retired"`). A Kit is asked for by **API
  generation**, not by a major string with a version in it.
- Code that still expects LibStub can be handed a Kit:
  `InteropKit:ExposeToLibStub("eventKit", 1)` makes it
  `LibStub("MoltenCodes-EventKit-1")`. `InteropKit:ExposeAll()` exposes every
  loaded Kit. See [`interopKit/docs/API.md`](../packages/interopKit/docs/API.md).
- Writing your own versioned library: a Kit registers through
  `Registry:Bootstrap`, which also upgrades embedded copies in place; see
  [`registry/docs/API.md`](../packages/registry/docs/API.md#registrybootstraprequest).

## CallbackHandler-1.0

```lua
-- Ace3: a library that lets others register callbacks
MyLib.callbacks = MyLib.callbacks or LibStub("CallbackHandler-1.0"):New(MyLib)

function MyLib.callbacks:OnUsed(target, eventName)
  startWatching()
end

function MyLib.callbacks:OnUnused(target, eventName)
  stopWatching()
end

MyLib.callbacks:Fire("Changed", value)

-- a consumer
MyLib.RegisterCallback(MyAddon, "Changed", function(eventName, value) end)
MyLib.UnregisterCallback(MyAddon, "Changed")
```

```lua
-- MoltenCodes: one signal per event
local SignalKit = Registry:Get("signalKit", 1)

MyLib.changed = SignalKit:New({
  onFirst = function(signal)
    startWatching()
  end,
  onLast = function(signal)
    stopWatching()
  end,
})

MyLib.changed:Fire(value)

-- a consumer
local connection = MyLib.changed:Connect(function(value) end)
connection:Disconnect()
```

- A signal is one event: listeners receive the fired arguments without an
  event name in front (CallbackHandler passes the event name first,
  `CallbackHandler-1.0.lua:54`).
- Unregistering goes through the connection handle, not through a
  `(target, eventName)` pair, so one consumer may connect several times.
- `onFirst`/`onLast` are `OnUsed`/`OnUnused` per signal.
- **Errors.** A raw signal is owned by whoever fires it, so a listener's
  error reaches the caller of `Fire`. CallbackHandler isolates each callback.
  When other addons register the callbacks, publish on a **bus** instead: a
  bus delivers each subscriber through `securecallfunction` and reports an
  error without stopping the others (see [AceEvent messages](#messages)).

## AceAddon-3.0

```lua
-- Ace3
local MyAddon = LibStub("AceAddon-3.0"):NewAddon("MyAddon", "AceEvent-3.0")

function MyAddon:OnInitialize() end -- ADDON_LOADED
function MyAddon:OnEnable() end     -- PLAYER_LOGIN
function MyAddon:OnDisable() end

local Bags = MyAddon:NewModule("Bags")
function Bags:OnEnable() end
```

```lua
-- MoltenCodes
local ModuleKit = Registry:Get("moduleKit", 1)
local addon = ModuleKit:ForAddon(ADDON_NAME)

local main = addon:CreateModule("Main")
function main:OnInitialize(deps) end -- LifecycleKit "loaded" (ADDON_LOADED)
function main:OnEnable(deps) end     -- LifecycleKit "ready" (loaded and logged in)
function main:OnDisable(deps) end    -- Disable(), and at logout

local bags = addon:CreateModule("Bags")
bags:DependsOn("Main")
function bags:OnEnable() end
```

- **The addon object** is a container of modules. What an Ace3 addon does in
  its own `OnInitialize`/`OnEnable`, a "Main" module does; other modules
  declare what they need with `DependsOn`, and ModuleKit initializes and
  enables them in dependency order rather than creation order.
- **Mixins** (`"AceEvent-3.0"` in `NewAddon`) become the module's scope:
  `self.scope.Events`, `self.scope.Timers`, `self.scope.Hooks`,
  `self.scope.Commands`, `self.scope.Comm`, `self.scope.Messages`,
  `self.scope.Jobs`, available from `OnEnable` until the module is disabled
  and released automatically then. A field reads `nil` when its Kit is not
  embedded.
- **Logout.** Ace3 calls `OnDisable` only when you disable something;
  ModuleKit disables every module at logout, so `OnDisable` runs then too.
- `NewModule` with a prototype and `SetDefaultModuleState(false)`: a module
  that calls `self:Disable()` in `OnInitialize` stays disabled when the addon
  becomes ready.
- `MyAddon:GetModule("Bags")` is `addon:GetModule("Bags")` (`nil` when
  absent); `IterateModules` is `addon:GetModules()`, an array in creation
  order.
- `LibStub("AceAddon-3.0"):GetAddon("Other")` raises for an unknown addon;
  `ModuleKit:ForAddon("Other")` creates the container on first use.
- The lifecycle alone, without modules, is LifecycleKit:
  `LifecycleKit:ForAddon(ADDON_NAME):OnLoaded(function(instance) end)`,
  `OnReady`, `OnShutdown`.

## AceEvent-3.0

### Events

```lua
-- Ace3
function MyAddon:OnEnable()
  self:RegisterEvent("PLAYER_ENTERING_WORLD")
  self:RegisterEvent("BAG_UPDATE", "OnBagUpdate")
end

function MyAddon:PLAYER_ENTERING_WORLD(event, isInitialLogin, isReloadingUi) end
function MyAddon:OnBagUpdate(event, bagId) end

self:UnregisterEvent("BAG_UPDATE")
self:UnregisterAllEvents()
```

```lua
-- MoltenCodes
local EventKit = Registry:Get("eventKit", 1)
local events = EventKit:ForAddon(ADDON_NAME) -- in a module: self.scope.Events

events:Connect("PLAYER_ENTERING_WORLD", function(event, isInitialLogin, isReloadingUi) end)
local bagUpdates = events:Connect("BAG_UPDATE", function(event, bagId)
  MyAddon:OnBagUpdate(bagId)
end)

bagUpdates:Disconnect()
events:DisconnectAll()
```

- The callback receives the event name first, as Ace3's does; there is no
  method-name form, a closure calls your method.
- Several listeners per event per addon are allowed; each `Connect` returns
  its own connection.
- On clients with `C_EventUtils.IsEventValid`, an unknown event name raises at
  your line instead of failing silently.
- `RegisterUnitEvent` is `events:ConnectUnit(event, callback, "player")`
  (at most two unit tokens, the client's limit).
- A listener's error is reported through the error handler; the other
  listeners still run.
- The combat log: `events:ConnectCombatLog("SPELL_DAMAGE", callback)` reads
  `CombatLogGetCurrentEventInfo()` once per event for every listener; see
  [`eventKit/docs/API.md`](../packages/eventKit/docs/API.md#eventkitconnectcombatlogsubevent-callback).

### Messages

```lua
-- Ace3
self:RegisterMessage("MyAddon_ProfileChanged", function(message, name) end)
self:SendMessage("MyAddon_ProfileChanged", "Raid")
```

```lua
-- MoltenCodes
local SignalKit = Registry:Get("signalKit", 1)
local bus = SignalKit:ForAddon(ADDON_NAME) -- the bus named after the addon; nil, "full" at the session bound

bus:DeclareTopic("ProfileChanged", { arguments = 1, description = "The profile's name." })
bus:Publish("ProfileChanged", "Raid")

-- anywhere, from any addon
local subscription = SignalKit:Bus("MyAddon"):Subscribe("ProfileChanged", function(name) end)
```

- Ace3 messages share one namespace, so names carry the addon's name by
  convention; the Kits use **named buses** and short topics.
- Publishing a topic nobody declared raises at the publisher's line, unless
  the bus was created with `SignalKit:Bus(name, { openTopics = true })`, so a
  misspelt topic fails loudly. Subscribing needs no declaration.
- Subscribers receive the published arguments without the topic name.
- In a module, `self.scope.Messages:Subscribe("ProfileChanged", callback)`
  subscribes on the addon's bus and is released on disable.

## AceTimer-3.0

```lua
-- Ace3
local handle = self:ScheduleTimer("Refresh", 5, "login")
local ticker = self:ScheduleRepeatingTimer(function() self:Poll() end, 1)
local seconds = self:TimeLeft(handle)
self:CancelTimer(ticker)
self:CancelAllTimers()
```

```lua
-- MoltenCodes
local TimerKit = Registry:Get("timerKit", 1)
local timers = TimerKit:ForAddon(ADDON_NAME) -- in a module: self.scope.Timers

local timer = timers:After(5, function(timer)
  MyAddon:Refresh("login")
end)
local ticker = timers:Every(1, function(timer)
  MyAddon:Poll()
end)
local seconds = timer:GetRemaining() -- nil once it is no longer running
ticker:Cancel()
timers:CancelAll()
```

- The callback receives the timer handle, not your arguments: capture them
  in the closure, or attach one value with `timer:SetUserData(value)`.
- A handle is an object: `Cancel`, `Restart`, `IsPending`, `GetRemaining`.
  `TimerKit:New({ delay, callback, repeating })` makes one that starts later.
- An error in a repeating callback is reported and the ticker keeps ticking.

## AceBucket-3.0

```lua
-- Ace3
self:RegisterBucketEvent({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.2, function(units)
  for unit, count in pairs(units) do end
end)
self:RegisterBucketMessage("MyAddon_Changed", 1, "OnChanged")
```

```lua
-- MoltenCodes
local EventKit = Registry:Get("eventKit", 1)
local SchedulerKit = Registry:Get("schedulerKit", 1)
local SignalKit = Registry:Get("signalKit", 1)

local health = EventKit:ForAddon(ADDON_NAME):Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.2, function(units)
  for unit in pairs(units) do end
end)

local changed = SchedulerKit:ForAddon(ADDON_NAME):Coalesce(function(keys)
  for key in pairs(keys) do end
end, 1)
SignalKit:Bus("MyAddon"):Subscribe("Changed", function(key)
  changed(key)
end)
```

- The same interval rule: the first event starts the interval and the
  callback runs once at its end with everything collected.
- The set's values are `true`, where Ace3 counts how often each key arrived
  (`AceBucket-3.0.lua:108`). An event whose first argument is `nil` is keyed
  by the event name, where Ace3 uses the string `"nil"` (`104-106`).
- **The set is reused**: read it in the callback, never keep it.
- One interval holds at most 256 distinct keys by default (`maxKeys`); past
  that, new keys are refused and counted.
- `EventKit:Coalesce` needs SchedulerKit embedded. `health:Close()` is
  `UnregisterBucket`.
- `options.units` registers unit events with a filter:
  `Coalesce(events, 0.2, callback, { units = { "player", "target" } })`.

## AceHook-3.0

```lua
-- Ace3
self:SecureHook(GameTooltip, "SetUnit", "OnTooltipSetUnit")
self:Hook(OtherAddon, "Refresh", function(obj, reason) end)
self:RawHook(OtherAddon, "Format", function(obj, value)
  return self.hooks[OtherAddon].Format(obj, value)
end)
self:SecureHookScript(PlayerFrame, "OnShow", function(frame) end)
self:HookScript(myFrame, "OnUpdate", function(frame, elapsed) end)
self:Unhook(GameTooltip, "SetUnit")
self:UnhookAll()
```

```lua
-- MoltenCodes
local HookKit = Registry:Get("hookKit", 1)
local hooks = HookKit:ForAddon(ADDON_NAME) -- in a module: self.scope.Hooks

hooks:SecureHook(GameTooltip, "SetUnit", function(tooltip, unit)
  MyAddon:OnTooltipSetUnit(tooltip, unit)
end)
hooks:Hook(OtherAddon, "Refresh", function(obj, reason) end)
hooks:RawHook(OtherAddon, "Format", function(original, obj, value)
  return original(obj, value)
end)
hooks:SecureHookScript(PlayerFrame, "OnShow", function(frame) end)
hooks:HookScript(myFrame, "OnUpdate", function(frame, elapsed) end)
hooks:Unhook(GameTooltip, "SetUnit")
hooks:UnhookAll()
```

- A raw hook's handler receives the **original as its first argument**
  instead of reading `self.hooks[object][method]`; `hooks:Original(object,
  method)` returns it too.
- A pre-hook or raw hook of a **secure** target is refused unless you pass
  `{ forceSecure = true }` (Ace3's `hookSecure` argument), because it taints
  every caller. Prefer `SecureHook` whenever you only need to react.
- `SecureHook` becomes reversible: `Unhook` turns the installed handler inert.
- Every hook method returns `true`, or `nil, "full"` past the scope's 256
  hooks (`HookKit:ForAddon(ADDON_NAME, { maxHooks = n })` opens it).
- See [`hookKit/docs/API.md`](../packages/hookKit/docs/API.md#the-taint-model-read-this-first)
  for what each semantic taints.

## AceConsole-3.0

```lua
-- Ace3
self:RegisterChatCommand("myaddon", "SlashCommand")

function MyAddon:SlashCommand(input)
  local command, value = self:GetArgs(input, 2)
end

self:Print("Hello")
self:Printf("%d items", count)
```

```lua
-- MoltenCodes
local SchemaKit = Registry:Get("schemaKit", 1)
local CommandKit = Registry:Get("commandKit", 1)
local S = SchemaKit
local commands = CommandKit:ForAddon(ADDON_NAME) -- in a module: self.scope.Commands

local registered, reason = commands:Register("myaddon", {
  description = "My Addon.",
  subcommands = {
    scale = {
      description = "Set the frame scale.",
      arguments = { S.number({ min = 0.5, max = 2 }) },
      handler = function(context, scale)
        MyAddon:SetScale(scale)
        context:Printf("Scale %.2f.", scale)
      end,
    },
  },
})

-- Keeping an old handler that parses the text itself, for now:
commands:Register("myaddonold", {
  handler = function(context)
    MyAddon:SlashCommand(context:GetRawText())
  end,
})
```

- Arguments are declared with SchemaKit schemas and converted and checked
  before your handler runs; a refusal prints the reason and the generated
  usage. Without `arguments`, the handler receives every token as a string.
- `Register` returns `nil, "taken"` when another addon or a chat type owns
  the name, `nil, "emote"` for an emote, `nil, "full"` past the scope's
  bound.
- `GetArgs` is `CommandKit:Parse(text)`: a new array of tokens, with quotes
  and item links kept whole, or `nil, reason`.
- Output inside a command goes through `context:Print` and `context:Printf`.
  Elsewhere use `print`; AceConsole's `Print` also prefixes the addon's name
  in colour (`AceConsole-3.0.lua:37`). For levelled output, see
  [`logKit/docs/API.md`](../packages/logKit/docs/API.md).

## AceTab-3.0

```lua
-- Ace3
AceTab:RegisterTabCompletion("MyAddon", "/myaddon", { "show", "hide", "reset" })
```

```lua
-- MoltenCodes: completion for your own CommandKit commands
commands:Register("myaddon", {
  subcommands = {
    show = {
      arguments = { S.string() },
      handler = function(context, name) end,
      complete = function(context, text, position)
        return MyAddon:FrameNames()
      end,
    },
  },
})
commands:EnableCompletion()
```

- Sub-command names complete without a `complete` function; `complete`
  answers for argument `position`.
- AceTab completes any pattern in any chat edit box; CommandKit completes its
  own commands only.

## AceLocale-3.0

```lua
-- Ace3
local L = LibStub("AceLocale-3.0"):NewLocale("MyAddon", "enUS", true)
L["Hello"] = true

local L = LibStub("AceLocale-3.0"):NewLocale("MyAddon", "deDE")
if not L then return end
L["Hello"] = "Hallo"

local L = LibStub("AceLocale-3.0"):GetLocale("MyAddon")
print(L["Hello"])
```

```lua
-- MoltenCodes
local LocaleKit = Registry:Get("localeKit", 1)

local L = LocaleKit:NewLocale("MyAddon", "enUS", { isDefault = true })
L["Hello"] = true

local L = LocaleKit:NewLocale("MyAddon", "deDE")
if not L then return end
L["Hello"] = "Hallo"

local L = LocaleKit:GetLocale("MyAddon")
print(L["Hello"])
```

- Ace3's `silent` argument becomes the read mode of the first `GetLocale`:
  `LocaleKit:GetLocale("MyAddon", { missing = "silent" })`, or `"raw"` for a
  plain table that answers `nil`. The default, `"report"`, reports each
  missing key once and records it for `LocaleKit:MissingKeys("MyAddon")`.
- `GAME_LOCALE` testing is `LocaleKit:SetLocaleOverride("deDE")`, called
  before the translation files load.
- `LocaleKit:Format(L["%1$s has %2$d items"], name, count)` lets a
  translation reorder its arguments.
- Missing-key recording is bounded (1024 keys per addon by default).

## AceDB-3.0

The data model is the same idea — scopes, profiles, defaults — with two
changes: defaults come from a **SchemaKit schema** instead of a defaults
table, and every write is **validated** at the writer's line.

```lua
-- Ace3
local defaults = {
  profile = {
    scale = 1,
    anchor = "CENTER",
    auras = { ["*"] = { shown = true } },
  },
  global = { installs = 0 },
}

function MyAddon:OnInitialize()
  self.db = LibStub("AceDB-3.0"):New("MyAddonDB", defaults, true)
  self.db.RegisterCallback(self, "OnProfileChanged", "Refresh")
  self.db.global.installs = self.db.global.installs + 1
end
```

```lua
-- MoltenCodes
local SchemaKit = Registry:Get("schemaKit", 1)
local SettingsKit = Registry:Get("settingsKit", 1)
local LifecycleKit = Registry:Get("lifecycleKit", 1)
local S = SchemaKit

local schema = {
  profile = S.table({
    fields = {
      scale = S.optional(S.number({ min = 0.5, max = 2 }), 1),
      anchor = S.optional(S.enum({ "TOP", "CENTER", "BOTTOM" }), "CENTER"),
      auras = S.optional(S.map({
        keys = S.number({ integer = true, min = 1 }),
        values = S.optional(S.table({ fields = { shown = S.optional(S.boolean(), true) } }), {}),
        max = 256,
      }), {}),
    },
  }),
  global = S.table({ fields = { installs = S.optional(S.number({ integer = true, min = 0 }), 0) } }),
}

LifecycleKit:ForAddon(ADDON_NAME):OnLoaded(function()
  local db = SettingsKit:Open("MyAddonDB", schema, { defaultProfile = "Default" })
  db:OnProfileChanged(function(db, name, previous)
    MyAddon:Refresh()
  end)
  db.global.installs = db.global.installs + 1
  MyAddon.db = db
end)
```

| AceDB-3.0 | SettingsKit |
|---|---|
| `AceDB:New(name, defaults, true)` | `SettingsKit:Open(name, schema, { defaultProfile = "Default" })` |
| `AceDB:New(name, defaults)` (per-character profile) | `SettingsKit:Open(name, schema, { defaultProfile = "char" })` |
| `db.profile`, `db.global`, `db.char`, `db.realm`, `db.class`, `db.faction` | the same names, as validated views |
| `db.race`, `db.factionrealm`, `db.factionrealmregion`, `db.locale` | no scope: declare a keyed `map` in `global` and index it by the key yourself |
| `["*"]` and `["**"]` defaults | a `map` whose `values` is `S.optional(record, {})`: every key reads the record's field defaults until written |
| `db:SetProfile(name)`, `db:GetCurrentProfile()` | `db:SetProfile(name)`, `db:GetProfile()` |
| `db:GetProfiles()` → table, count | `db:GetProfiles()` → a new sorted array |
| `db:CopyProfile(name)`, `db:ResetProfile()`, `db:DeleteProfile(name)` | the same names; deleting a missing profile is refused (Ace3's `silent` has no equivalent) |
| `db:ResetDB()` | `db:ResetDatabase()` |
| `db:RegisterNamespace(name, defaults)` | no namespaces yet: open a second database or declare a field |
| `db:RegisterDefaults(defaults)` | the schema passed to `Open` |
| callbacks `OnProfileChanged(event, db, name)`, `OnProfileCopied`, `OnProfileReset`, `OnProfileDeleted` | `db:OnProfileChanged(function(db, name, previous))`, `OnProfileCopied(db, from, name)`, `OnProfileReset(db, name)`, `OnProfileDeleted(db, name)` |
| `OnDatabaseShutdown` | `LifecycleKit:ForAddon(ADDON_NAME):OnShutdown(callback)` |
| stripping values equal to defaults at logout | `db:Compact()`, run at logout when EventKit is loaded |

- **Open in the loaded phase.** Before `ADDON_LOADED` the client has not
  loaded the saved variable yet.
- **Every field of a record is `optional`.** A saved variable starts empty;
  `Open` refuses a required field with its path.
- **Writes are checked.** `db.profile.anchor = "LEFT"` raises at that line
  with the schema's message; `db:Validate("profile", "anchor", "LEFT")` asks
  first without raising.
- **Views are not plain tables.** `pairs(db.profile)` sees nothing; use
  `db:Pairs(db.profile)`.
- **Views hold their saved tables.** SettingsKit views keep a reference to
  the saved tables they read; if you edit the saved variable directly after
  `Open`, call `db:Resync()`. For hot loops, `db:Getter("profile", key)`
  replaces repeated `db.profile.key` reads: it returns a function that answers
  what the view would, defaults included, and follows `SetProfile`.
- **Versioned data.** `Open(name, schema, { version = 2, migrations = { [2] =
  function(raw) end } })` runs each migration once, transactionally, and a
  saved table written by a newer version of the addon opens read-only.
- Profile names are at most 64 bytes by default (Ace3 allows 50 characters,
  which can be more bytes).
- **Existing AceDB data** is carried over by BridgeKit's importer (planned):
  see [below](#importing-an-acedb-saved-variable).

## AceDBOptions-3.0

```lua
-- Ace3
options.args.profiles = LibStub("AceDBOptions-3.0"):GetOptionsTable(self.db)
```

```lua
-- MoltenCodes
local OptionsKit = Registry:Get("optionsKit", 1)

local tree = OptionsKit:Define(ADDON_NAME, {
  type = "group",
  args = {
    general = {
      type = "group",
      name = "General",
      args = { scale = { type = "range", name = "Scale", min = 0.5, max = 2, bind = "profile.scale" } },
    },
    profiles = OptionsKit:ProfileOptions(db, { order = 90 }),
  },
}, { db = db })
```

- Place the returned group in `args` **as it is**: `Define` recognises the
  table and connects it to the database's profile signals.
- `ProfileOptions` returns one cached group per database and options, like
  AceDBOptions' one group per database: later calls with the same database
  and options return the same table. One group can sit in one defined tree
  at a time; two trees that each show profile options at once need two
  option sets (for example another `order`) or two databases.
- Current profile, new, copy, reset and delete, with confirmations, and a
  `localize` option for every string.

## AceConfig-3.0, AceConfigRegistry, AceConfigDialog, AceConfigCmd

```lua
-- Ace3
local options = {
  type = "group",
  name = "My Addon",
  handler = MyAddon,
  get = "GetOption",
  set = "SetOption",
  args = {
    scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, order = 1 },
    anchor = {
      type = "select",
      name = "Anchor",
      values = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" },
      order = 2,
    },
  },
}

LibStub("AceConfig-3.0"):RegisterOptionsTable("MyAddon", options, { "myaddon" })
LibStub("AceConfigDialog-3.0"):AddToBlizOptions("MyAddon")
LibStub("AceConfigDialog-3.0"):Open("MyAddon")
LibStub("AceConfigRegistry-3.0"):NotifyChange("MyAddon")
```

```lua
-- MoltenCodes
local OptionsKit = Registry:Get("optionsKit", 1)
local CommandKit = Registry:Get("commandKit", 1)
local WidgetKit = Registry:Get("widgetKit", 1)

local tree = OptionsKit:Define(ADDON_NAME, {
  type = "group",
  name = "My Addon",
  args = {
    scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, order = 1, bind = "profile.scale" },
    anchor = {
      type = "select",
      name = "Anchor",
      values = { TOP = "Top", CENTER = "Centre", BOTTOM = "Bottom" },
      sorting = { "TOP", "CENTER", "BOTTOM" },
      order = 2,
      bind = "profile.anchor",
    },
  },
}, { db = db })

-- /myaddon get|set|reset|list|exec
CommandKit:ForAddon(ADDON_NAME):BindOptions(tree, "myaddon", { description = "My Addon options." })

-- a window
local frame = assert(WidgetKit:Create("Frame"))
frame:SetTitle("My Addon")
local rendering = WidgetKit:RenderOptions(tree, frame)
frame:Show()

-- after the addon changed the database outside the tree
rendering:Refresh()
```

- **`bind` replaces `get`/`set`** for a value stored in SettingsKit: the
  value is read with SettingsKit's defaults, written through its validated
  write, and `tree:Reset(path)` restores the default. An option that is not
  stored keeps its own `get(info)` and `set(info, value)`.
- **No inheritance.** Ace3 lets a group's `handler`, `get`, `set`,
  `validate`, `disabled` and `hidden` apply to everything below it. In
  OptionsKit every value option names its own `get`/`set` or `bind`;
  `disabled` and `hidden` on a group still apply to its children.
- **Functions** are callbacks only (`get`, `set`, `validate`, `disabled`,
  `hidden`, `values`, `func`, and `desc`). `name` and `order` are plain
  values, and method-name strings do not exist: pass a function.
- **Value shapes.** A `color` value is a table `{ r, g, b[, a] }` (Ace3 passes
  four values); a `multiselect` value is a map of key to boolean (Ace3 calls
  `get(info, key)` and `set(info, key, state)` per key).
- **`validate`** returns `true`, or `false` and a message (Ace3: `true` or the
  message string). A schema refusal raises at the caller of `Set`; a
  `validate` refusal is returned for the user.
- **`confirm`** exists on `execute` only.
- **Keys** in `args` are identifiers (`[%a_][%w_]*`).
- Presentation fields (`width`, `icon`, `image`, `descStyle`,
  `childGroups`, the `dialogControl` family, per-interface `guiHidden` and
  `cmdHidden`) have no equivalent; OptionsKit refuses unknown fields at
  `Define`.
- **`NotifyChange`**: the rendering follows `tree:OnChange` by itself;
  changes made outside the tree call `rendering:Refresh()`, typically from
  `db:OnChange` and `db:OnProfileChanged`.
- **Command line**: CommandKit's syntax is `/myaddon set scale 1.25`, where
  AceConfigCmd's is `/myaddon scale 1.25`.
- **`AddToBlizOptions`** has no equivalent yet (the user-interface phase).
- **Converting an existing table** instead of rewriting it is BridgeKit's
  AceConfig adapter (planned): see
  [below](#converting-an-aceconfig-table).

## AceGUI-3.0

```lua
-- Ace3
local AceGUI = LibStub("AceGUI-3.0")
local frame = AceGUI:Create("Frame")
frame:SetTitle("My Addon")
frame:SetLayout("Flow")
frame:SetCallback("OnClose", function(widget)
  AceGUI:Release(widget)
end)

local button = AceGUI:Create("Button")
button:SetText("Refresh")
button:SetCallback("OnClick", function()
  MyAddon:Refresh()
end)
frame:AddChild(button)
```

```lua
-- MoltenCodes
local WidgetKit = Registry:Get("widgetKit", 1)

local frame = assert(WidgetKit:Create("Frame"))
frame:SetTitle("My Addon")
frame:SetLayout("Flow")
frame:SetCallback("OnClose", function(widget)
  widget:Release()
end)

local button = assert(WidgetKit:Create("Button"))
button:SetText("Refresh")
button:SetCallback("OnClick", function()
  MyAddon:Refresh()
end)
frame:AddChild(button)
frame:Show()
```

| AceGUI-3.0 | WidgetKit |
|---|---|
| `Frame`, `SimpleGroup`/`InlineGroup`, `ScrollFrame`, `Label`, `Heading`, `Button`, `CheckBox`, `Slider`, `EditBox`, `MultiLineEditBox`, `Dropdown`, `ColorPicker` | `Frame`, `Group`, `ScrollFrame`, `Label`, `Heading`, `Button`, `CheckBox`, `Slider`, `EditBox`, `EditBox` with `SetMultiLine(true)`, `Dropdown`, `ColorPicker` |
| `Keybinding` | `Button` with `SetKeyCapture(true)` |
| layouts `List`, `Flow`, `Fill` | the same names |
| `AceGUI:RegisterWidgetType(name, constructor, version)` | `WidgetKit:RegisterType(name, constructor, version, options?)` |
| `AceGUI:RegisterLayout(name, func)` | `WidgetKit:RegisterLayout(name, layout)` |
| `AceGUI:Release(widget)` | `WidgetKit:Release(widget)` or `widget:Release()` |

- `Create` returns `nil` and a reason (`"unknownType"`, `"exhausted"`)
  instead of raising; every type is pooled and bounded.
- Callbacks receive `(widget, name, ...)` as Ace3's do; setters never fire
  them.
- `Frame:SetStatusText`, `TreeGroup`, `TabGroup`, `DropdownGroup`, `Icon`,
  `InteractiveLabel` and the LibSharedMedia widgets have no equivalent yet;
  MediaKit's `WidgetKit:CreateMediaPicker(mediaType)` covers the media
  dropdown.
- Window positions persist with `frame:BindPosition(storage)`.

## AceSerializer-3.0

```lua
-- Ace3
local AceSerializer = LibStub("AceSerializer-3.0")
local text = AceSerializer:Serialize("sync", 3, { a = 1 })
local ok, kind, version, payload = AceSerializer:Deserialize(text)
```

```lua
-- MoltenCodes
local CodecKit = Registry:Get("codecKit", 1)
local encoded, text = CodecKit:EncodeMany({ channel = "addon" }, "sync", 3, { a = 1 })
local ok, kind, version, payload = CodecKit:DecodeMany(text, { channel = "addon" })
```

- **A different format.** CodecKit writes a binary frame escaped for the
  addon channel (or printable, `channel = "print"`, for export strings), with
  optional DEFLATE compression (`compress = "deflate"`). An Ace3 peer cannot
  read it, and CodecKit does not read AceSerializer text; for that, see
  [talking to Ace3 peers](#talking-to-ace3-peers-during-the-move).
- **Nothing raises on bad input**: decoding returns `false` and a reason for
  any string; a secret value raises at the caller when encoding.
- **Validate what you decode** with a SchemaKit schema before using it; see
  [`codecKit/docs/API.md`](../packages/codecKit/docs/API.md#security-decoded-data-is-untrusted).
- `Encode`/`Decode` handle one value; `EncodeMany`/`DecodeMany` an argument
  list, `nil`s included.

## AceComm-3.0

```lua
-- Ace3
self:RegisterComm("MyAddon", "OnCommReceived")

function MyAddon:OnCommReceived(prefix, message, distribution, sender) end

self:SendCommMessage("MyAddon", text, "RAID", nil, "BULK")
```

```lua
-- MoltenCodes
local CommKit = Registry:Get("commKit", 1)
local comm = CommKit:ForAddon(ADDON_NAME) -- in a module: self.scope.Comm

local connection, reason = comm:Register("MyAddon", function(prefix, text, distribution, sender) end)

local handle, refused = comm:Send({
  prefix = "MyAddon",
  text = text,
  distribution = "RAID",
  priority = CommKit.Priority.BULK,
  onComplete = function(handle, state, reason) end,
})
```

- **A different wire format.** CommKit frames every message with its own
  control byte and chunk header, so Ace3 peers cannot read it and it cannot
  read theirs; keep the two on different prefixes (see
  [below](#talking-to-ace3-peers-during-the-move)).
- **Text must not contain NUL, LF, CR or `|`.** CommKit refuses them
  (`"forbiddenByte"`) rather than change your text; `CodecKit:Encode(value,
  { channel = "addon" })` never produces them.
- **Everything is bounded**: reassembly per sender, the send queue, the
  number of registrations; a send that does not fit is refused with a reason
  instead of queued forever.
- **One budget for the session**, shared with every addon, replaces
  ChatThrottleLib; priorities are weighted 4 : 2 : 1 per chunk.
- `sender` is the name exactly as the client reports it; AceComm passes it
  through `Ambiguate(sender, "none")` first (`AceComm-3.0.lua:244`).
- `callbackFn` progress becomes `onProgress(handle, bytesSent, bytesTotal)`;
  `handle:Cancel()` stops a message.
- `scope:SyncSet(prefix, { fields = { ... } })` synchronises named fields by
  content hash, which many AceComm protocols implement by hand.

## Moving data and peers with BridgeKit (planned)

Three things cannot be rewritten by hand without risk: the saved variable
your players' settings live in, a large options table, and a wire format
peers still speak. BridgeKit is designed for exactly these three
([`BRIDGE_KIT_DESIGN.md`](BRIDGE_KIT_DESIGN.md)). **None of the code in this
section runs yet**; it shows the planned API so an addon can plan its
migration, and it will be made current when BridgeKit ships.

### Importing an AceDB saved variable

*Planned API.* Keep the old global listed in the TOC during the transition
and add a backup global:

```toc
## SavedVariables: MyAddonDB, MyAddonSettings, MyAddonDB_Backup
```

```lua
-- Planned API: BridgeKit does not exist yet.
LifecycleKit:ForAddon(ADDON_NAME):OnLoaded(function()
  if type(MyAddonSettings) == "nil" then
    local report, reason = BridgeKit:ImportAceDB("MyAddonDB", "MyAddonSettings", {
      schema = schema,
      aceDefaults = defaults, -- the table you passed to AceDB:New
      version = 1,
      backup = "MyAddonDB_Backup",
    })
    if report then
      for _, line in ipairs(BridgeKit:FormatReport(report)) do
        print(line)
      end
    end
  end
  MyAddon.db = SettingsKit:Open("MyAddonSettings", schema, { version = 1 })
end)
```

- The old table is never modified; the backup is a copy.
- Profiles, every character's profile choice, `char`, `realm`, `class`,
  `faction` and `global` land where SettingsKit reads them. `race`,
  `factionrealm`, `factionrealmregion` and `locale` land in map fields you
  name (`scopes`), namespaces under fields you name (`namespaces`); anything
  else is reported and left in the backup.
- Every value is checked against your schema; a refused value is reported,
  never written.
- An AceDB default that differs from your SettingsKit default is written as a
  value, so every setting reads what it read under Ace3.
- `BridgeKit:PreviewAceDB(source, plan)` returns the same report without
  writing anything. `BridgeKit:AceDBMigration(plan)` does the import inside a
  SettingsKit migration when the addon keeps its saved-variable name.

### Converting an AceConfig table

*Planned API.*

```lua
-- Planned API: BridgeKit does not exist yet.
local tree, report = BridgeKit:DefineAceConfig(ADDON_NAME, options, {
  db = db,
  bind = { scale = "profile.scale" },                          -- store this one in SettingsKit
  replace = { profiles = OptionsKit:ProfileOptions(db) },      -- instead of AceDBOptions
})
```

- Your Ace3 `get`, `set`, `func` and `validate` handlers keep working: they
  are called with an Ace3-shaped `info`, inheritance resolved.
- Every field that is dropped, renamed or changes meaning (presentation
  fields, `step` not being enforced, a `name` function evaluated once, ...)
  is in the report; `strict = true` turns any of them into an error.

### Talking to Ace3 peers during the move

*Planned API.* Use two prefixes: the old one in Ace3's format through
BridgeKit, a new one through CommKit and CodecKit. Release v2 sends and
listens on both; release v3 drops the old prefix once telemetry says the Ace3
peers are gone.

```lua
-- Planned API: BridgeKit does not exist yet.
local CommKit = Registry:Get("commKit", 1)
local CodecKit = Registry:Get("codecKit", 1)
local BridgeKit = Registry:Get("bridgeKit", 1)

local LEGACY_PREFIX, PREFIX = "MyAddon", "MyAddonMC"
local MAX_KNOWN_PEERS = 256
local knownPeers, knownPeerCount = {}, 0
local comm = CommKit:ForAddon(ADDON_NAME)

local function rememberPeer(sender)
  if knownPeers[sender] or knownPeerCount >= MAX_KNOWN_PEERS then
    return
  end
  knownPeers[sender] = true
  knownPeerCount = knownPeerCount + 1
end

comm:Register(PREFIX, function(prefix, text, distribution, sender)
  rememberPeer(sender)
  local ok, kind, payload = CodecKit:DecodeMany(text, { channel = "addon" })
  if ok then
    MyAddon:Handle(sender, kind, payload)
  end
end)

local legacy = BridgeKit:OpenAceComm(comm, LEGACY_PREFIX, function(prefix, message, distribution, sender)
  if knownPeers[sender] then
    return -- this peer also sent it on PREFIX
  end
  local ok, kind, payload = BridgeKit:AceDeserialize(message)
  if ok then
    MyAddon:Handle(sender, kind, payload)
  end
end, { ambiguate = false }) -- compare the same sender name CommKit delivers

local function broadcast(kind, payload)
  local encoded, text = CodecKit:EncodeMany({ channel = "addon" }, kind, payload)
  if encoded then
    comm:Send({ prefix = PREFIX, text = text, distribution = "GUILD" })
  end
  local serialized, legacyText = BridgeKit:AceSerialize(kind, payload)
  if serialized then
    legacy:Send({ text = legacyText, distribution = "GUILD" })
  end
end
```

- BridgeKit writes the same bytes AceComm and AceSerializer write, and reads
  theirs, with the bounds CommKit applies to its own traffic.
- The set of known peers is bounded, as every retained table in the
  framework is.
- Validate `payload` with a SchemaKit schema in both paths: a peer can send
  anything.

## What has no equivalent yet

| Ace3 | Status |
|---|---|
| `AceConfigDialog:AddToBlizOptions` (the Blizzard settings panel) | The user-interface phase. |
| AceGUI `TreeGroup`, `TabGroup`, `DropdownGroup`, `Icon`, `InteractiveLabel`, `Frame:SetStatusText` | The user-interface phase. |
| AceConfigDialog `childGroups` (tabs, trees, drop-down groups) | The user-interface phase; `RenderOptions` nests groups. |
| AceTab completion in arbitrary edit boxes | Not planned; CommandKit completes its own commands. |
| AceDB namespaces, and the `race`, `factionrealm`, `factionrealmregion` and `locale` scopes | Not in SettingsKit API 1; use a second database or map fields. BridgeKit's importer maps existing data. |
| Reading or writing AceComm and AceSerializer traffic | BridgeKit (planned). |
| Converting AceConfig tables and importing AceDB data | BridgeKit (planned). |
