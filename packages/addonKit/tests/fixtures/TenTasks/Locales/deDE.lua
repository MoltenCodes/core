--# selene: allow(undefined_variable, unused_variable)
--@T06 a translation, loaded only on a German client
local L = MoltenCodes:For(...).LocaleKit:NewLocale(..., "deDE")
if not L then
  return
end
L["Scale"] = "Skalierung"
