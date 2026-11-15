# Cookbook

Short recipes for what addons do most, each with the Kit reference to read
next. Every recipe starts from the two lines of
[Getting started](GETTING_STARTED.md):

```lua
local MC = MoltenCodes:For(...)
local addon = MC:NewAddon()
```

Everything registered through `self.scope` belongs to the addon object (or the
module) and is released when it is disabled, so none of the recipes needs a
clean-up. `self.scope` is available from `OnEnable` on.

Where a recipe needs a Kit's optional part, it says so; give the part to the
generator (`python3 -m tooling.package.embeds ... eventKit/Coalescing`) and it
writes `embeds.xml` with everything the part needs, in load order.

## The addon object

```lua
function addon:OnInitialize() end -- the client has loaded the addon and its saved variables
function addon:OnEnable() end     -- the player is in the game
function addon:OnDisable() end    -- addon:Disable(), or logout
```

In another file of the same addon: `local addon = MoltenCodes:For(...):GetAddon()`.
Reference: [AddonKit](../packages/addonKit/docs/API.md#the-addon-object),
[ModuleKit](../packages/moduleKit/docs/API.md#module-lifecycle).

## Register and unregister an event

```lua
function addon:OnEnable()
  self.bagUpdates = self.scope.Events:Connect("BAG_UPDATE", function(event, bagID)
    self:Refresh(bagID)
  end)
end

function addon:StopWatchingBags()
  self.bagUpdates:Disconnect()
end
```

With an EventKit that takes method names, `self.scope.Events:Connect("BAG_UPDATE", self)`
calls `self:BAG_UPDATE(event, bagID)`, as AceEvent does, and
`Connect("BAG_UPDATE", self, "OnBags")` calls `self:OnBags(...)`; the method
must exist when you connect. Reference: [EventKit](../packages/eventKit/docs/API.md).

## Bucketed events

Many events in a burst, one callback at the end of the interval, with every
unit that fired:

```lua
self.scope.Events:Coalesce({ "UNIT_HEALTH", "UNIT_MAXHEALTH" }, 0.1, function(units)
  for unit in pairs(units) do
    self:UpdateHealth(unit)
  end
end, { units = { "player", "target" } })
```

Needs EventKit's Coalescing part (`eventKit\parts\EventKit-Coalescing.lua`) and
TimerKit embedded; SchedulerKit is not needed. This is AceBucket's interval: the
first event starts it. Reference: [EventKit, Coalescing events](../packages/eventKit/docs/API.md#coalescing-events).

## A repeating and a one-shot timer

```lua
self.ticker = self.scope.Timers:Every(60, function() self:Poll() end)
self.scope.Timers:After(5, function() print("Five seconds later.") end)

self.ticker:Cancel()
```

Reference: [TimerKit](../packages/timerKit/docs/API.md).

## A database with profiles

```lua
local defaults = {
  profile = {
    scale = MC.Range(0.5, 2, 1),
    anchor = MC.Enum({ "TOP", "CENTER", "BOTTOM" }, "CENTER"),
    auras = { ["*"] = { shown = true } },
  },
  global = { installs = 0 },
}

function addon:OnInitialize()
  self.db = MC:Database("MyAddonDB", defaults)
  self.db:OnProfileChanged(function() self:Refresh() end)
end
```

Writes are checked against the types the defaults imply, and against
`MC.Range` and `MC.Enum`. Iterate a view with `self.db:Pairs(self.db.profile)`;
plain `pairs` finds nothing. Reference: [AddonKit, Database part](../packages/addonKit/docs/API.md#database-part),
[SettingsKit](../packages/settingsKit/docs/API.md).

## Migrations

Restructure saved data when a new version of the addon changes its layout:

```lua
self.db = MC:Database("MyAddonDB", defaults, {
  version = 2,
  migrations = {
    [2] = function(raw)
      -- Version 1 called the scale `size`.
      for _, profile in pairs(raw.profiles or {}) do
        profile.scale, profile.size = profile.size, nil
      end
    end,
  },
})
```

Each step runs once, on a copy, and is committed only when it returns.
Reference: [SettingsKit, Migrations](../packages/settingsKit/docs/API.md#migrations).

## Profiles per specialization

```lua
self.db:SetSpecProfile(1, "Healing")
self.db:SetSpecProfile(2, "Damage")
```

The database switches profile when the player changes specialization (or
talent group on Classic Era); needs EventKit embedded. Reference:
[SettingsKit, Spec profiles](../packages/settingsKit/docs/API.md#spec-profiles).

## An options panel and a slash command

```lua
self.panel = MC:Options({
  type = "group",
  name = "My Addon",
  args = {
    scale = { type = "range", name = "Scale", min = 0.5, max = 2, step = 0.05, bind = "profile.scale" },
    profiles = MC.OptionsKit:ProfileOptions(self.db),
  },
}, { db = self.db, slash = "myaddon" })
```

Needs AddonKit's Composition part (`addonKit/Composition`), CommandKit, PanelKit
and OptionsKit's Profiles part (`optionsKit/Profiles`) for `ProfileOptions`.
PanelKit brings in WidgetKit's Renderer part and the widget types it draws with.
Reference: [AddonKit, Composition part](../packages/addonKit/docs/API.md#composition-part),
[OptionsKit](../packages/optionsKit/docs/API.md).

## A slash command of its own

```lua
self.scope.Commands:Register("myaddonreset", {
  handler = function(context)
    self.db:ResetProfile()
  end,
})
```

`Register` returns `nil, "taken"` when another addon owns the name; check it.
Reference: [CommandKit](../packages/commandKit/docs/API.md).

## Localisation

`Locales/enUS.lua`, loaded first:

```lua
local L = MoltenCodes:For(...).LocaleKit:NewLocale(..., "enUS", { isDefault = true })
L["Scale"] = true
```

`Locales/deDE.lua`:

```lua
local L = MoltenCodes:For(...).LocaleKit:NewLocale(..., "deDE")
if not L then return end
L["Scale"] = "Skalierung"
```

Reading: `local L = MC.LocaleKit:GetLocale(MC.addonName)`. Reference:
[LocaleKit](../packages/localeKit/docs/API.md).

## A module that can be disabled

```lua
local bags = MC:NewModule("Bags")

function bags:OnEnable()
  self.scope.Events:Connect("BAG_UPDATE_DELAYED", function() self:Rebuild() end)
end

bags:Disable() -- its events are disconnected
bags:Enable()
```

A module enables after the addon object and is disabled with it. Reference:
[AddonKit, NewModule](../packages/addonKit/docs/API.md#mcnewmodulename-definition).

## Send and receive an addon message

```lua
self.scope.Comm:Register("MyAddon", function(prefix, text, distribution, sender)
  self:Merge(sender, text)
end)

self.scope.Comm:Send({ prefix = "MyAddon", text = "hello", distribution = "PARTY" })
```

Reference: [CommKit](../packages/commKit/docs/API.md).

## A hook

```lua
self.scope.Hooks:SecureHook("ToggleGameMenu", function() self:OnGameMenu() end)
self.scope.Hooks:SecureHook(GameTooltip, "SetUnit", function(tooltip) self:Decorate(tooltip) end)
```

Disabling the addon undoes every hook. Reference: [HookKit](../packages/hookKit/docs/API.md).

## A minimap button

```lua
-- In the profile defaults: minimap = MC.LAUNCHER_DEFAULTS
MC:Launcher({
  icon = "Interface\\Icons\\INV_Misc_Gear_01",
  OnClick = function() addon.panel:Open() end,
}, self.db)
```

Needs AddonKit's Composition part and LauncherKit.
Reference: [AddonKit, Launcher](../packages/addonKit/docs/API.md#mclauncherdefinition-db-field),
[LauncherKit](../packages/launcherKit/docs/API.md).

## A window

```lua
local window = MC.WidgetKit:Create("Frame") --[[@as WidgetKit.Window]]
window:SetTitle("My Addon")
window:BindPosition(function() return addon.db.profile.window end)

local button = MC.WidgetKit:Create("Button") --[[@as WidgetKit.Button]]
button:SetText("Refresh")
button:SetCallback("OnClick", function() addon:Refresh() end)
window:AddChild(button)
```

Declare `window = {}` in the profile defaults for the position. `window:Release()`
gives the frames back. Needs WidgetKit's Containers, Button and Position parts
(`widgetKit/Containers widgetKit/Button widgetKit/Position`). Reference: [WidgetKit](../packages/widgetKit/docs/API.md).

## A confirmation dialog

```lua
MC.DialogKit:Show({
  text = "Reset every profile?",
  accept = "Reset",
  onAccept = function() addon.db:ResetDatabase() end,
  key = "MyAddonReset",
})
```

`key` keeps a second click from opening a second dialog. Reference:
[DialogKit](../packages/dialogKit/docs/API.md).

## A tooltip with columns

```lua
local tooltip = MC.TooltipKit:Acquire("MyAddon", 2, "LEFT", "RIGHT")
tooltip:AddHeader("Item", "Count")
tooltip:AddLine("Hearthstone", 1)
tooltip:SmartAnchorTo(anchorFrame)
tooltip:SetAutoHideDelay(0.25)
tooltip:Show()
```

The tooltip is released once the cursor has left it for a quarter second.
Reference: [TooltipKit](../packages/tooltipKit/docs/API.md).
