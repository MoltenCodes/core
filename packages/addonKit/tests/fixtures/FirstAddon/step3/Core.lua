--# selene: allow(undefined_variable, unused_variable)
local MC = MoltenCodes:For(...)
local addon = MC:NewAddon()

local defaults = {
  profile = { greet = true, scale = MC.Range(0.5, 2, 1) },
  global = { logins = 0 },
}

function addon:OnInitialize()
  self.db = MC:Database("FirstAddonDB", defaults)
  self.panel = MC:Options({
    type = "group",
    name = "First Addon",
    args = {
      greet = { type = "toggle", name = "Greet me", bind = "profile.greet" },
      scale = {
        type = "range",
        name = "Scale",
        min = 0.5,
        max = 2,
        step = 0.05,
        bind = "profile.scale",
      },
      profiles = MC.OptionsKit:ProfileOptions(self.db),
    },
  }, { db = self.db, slash = "firstaddon" })
end

function addon:OnEnable()
  self.scope.Events:Connect("PLAYER_ENTERING_WORLD", function(event, isInitialLogin)
    if isInitialLogin then
      self.db.global.logins = self.db.global.logins + 1
      if self.db.profile.greet then
        print("Hello from " .. MC.addonName .. ", login " .. self.db.global.logins)
      end
    end
  end)
end
