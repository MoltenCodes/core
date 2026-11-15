--# selene: allow(undefined_variable, unused_variable)
local MC = MoltenCodes:For(...)
local addon = MC:NewAddon()

function addon:OnEnable()
  self.scope.Events:Connect("PLAYER_ENTERING_WORLD", function(event, isInitialLogin)
    if isInitialLogin then
      print("Hello from " .. MC.addonName)
    end
  end)
end
