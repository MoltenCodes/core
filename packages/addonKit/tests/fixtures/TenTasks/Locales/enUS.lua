--# selene: allow(undefined_variable, unused_variable)
--@T06 the default locale: `true` means the key is its own text
local L = MoltenCodes:For(...).LocaleKit:NewLocale(..., "enUS", { isDefault = true })
L["My Addon"] = true
L["Scale"] = true
L["Five seconds later."] = true
