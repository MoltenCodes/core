--# selene: allow(undefined_variable, unused_variable)
-- MyAddon: ten common addon tasks with AddonKit. Each `--@Txx` tag marks the
-- task the lines below it belong to.

--@P
local MC = MoltenCodes:For(...)
local L = MC.LocaleKit:GetLocale(MC.addonName)

--@T01 addon with OnInitialize / OnEnable
local addon = MC:NewAddon()

--@T04 database with defaults and profiles: plain defaults, one field refined
local defaults = {
  profile = { scale = MC.Range(0.5, 2, 1), greet = true, minimap = MC.LAUNCHER_DEFAULTS },
  global = { installs = 0 },
}

--@T01
function addon:OnInitialize()
  --@T04
  self.db = MC:Database("MyAddonDB", defaults)
  self.db:OnProfileChanged(function()
    addon:Refresh()
  end)
  self.db.global.installs = self.db.global.installs + 1
  --@T05 options panel in Blizzard's settings, with a slash command
  self.panel = MC:Options({
    type = "group",
    name = L["My Addon"],
    args = {
      scale = {
        type = "range",
        name = L["Scale"],
        min = 0.5,
        max = 2,
        step = 0.05,
        bind = "profile.scale",
      },
      profiles = MC.OptionsKit:ProfileOptions(self.db),
    },
  }, { db = self.db, slash = "myaddon" })
  --@T10 minimap button from a data broker object
  MC:Launcher({
    icon = "Interface\\Icons\\INV_Misc_Gear_01",
    OnClick = function()
      addon.panel:Open()
    end,
  }, self.db)
  --@T01
end

function addon:OnEnable()
  --@T02 register and unregister events
  self.scope.Events:Connect(
    "PLAYER_ENTERING_WORLD",
    function(event, isInitialLogin, isReloadingUi) end
  )
  self.bagUpdates = self.scope.Events:Connect("BAG_UPDATE", function(event, bagID)
    self.bagUpdates:Disconnect()
  end)
  --@T03 a repeating and a one-shot timer
  self.ticker = self.scope.Timers:Every(60, function()
    self:Poll()
  end)
  self.scope.Timers:After(5, function()
    print(L["Five seconds later."])
  end)
  --@T08 send and receive an addon message
  self.scope.Comm:Register("MyAddon", function(prefix, text, distribution, sender) end)
  --@T09 a hook
  self.scope.Hooks:SecureHook("ToggleGameMenu", function()
    self:OnGameMenu()
  end)
  --@T01
end

--@T03
function addon:Poll() end
function addon:StopPolling()
  self.ticker:Cancel()
end

--@T04
function addon:Refresh() end

--@T08
function addon:SendHello()
  self.scope.Comm:Send({ prefix = "MyAddon", text = "hello", distribution = "PARTY" })
end

--@T09
function addon:OnGameMenu() end

--@T07 a module that can be disabled
local bags = MC:NewModule("Bags")
function bags:OnEnable()
  self.scope.Events:Connect("BAG_UPDATE_DELAYED", function()
    self:Rebuild()
  end)
end
function bags:Rebuild() end
function addon:ToggleBags(on)
  if on then
    bags:Enable()
  else
    bags:Disable()
  end
end
