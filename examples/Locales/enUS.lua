-- ExampleAddon: Locales/enUS.lua
--
-- Shows: the default locale file. `isDefault` makes this the fallback every
-- client loads, and `L[key] = true` stores the key as its own text, so English
-- is written once, as the key. Every string the addon shows is a key here; a
-- key read but defined nowhere is reported once through the error handler.

local ADDON_NAME, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local L = ADDON_TABLE.Kits.LocaleKit:NewLocale(ADDON_NAME, "enUS", { isDefault = true })
if not L then
  return
end

-- Chat output (Core.lua).
L["yes"] = true
L["no"] = true
L["%1$s is ready on the %2$s client (secret values: %3$s); greeting #%4$d."] = true
L["Type /exampleaddon list for the settings, /exampleaddonwindow to edit them."] = true
L["Entered the world (login: %s, reload: %s)."] = true
L["Health changed: %s."] = true
L["%s is still running."] = true
L["Spell data is ready: %s."] = true
L["Spell data did not arrive (%s)."] = true

-- Options tree and window (Options.lua, Window.lua).
L["Example Addon"] = true
L["Settings for the example addon."] = true
L["Greet on login"] = true
L["Announce health changes"] = true
L["Window scale"] = true

-- Slash commands (Commands.lua).
L["Example Addon settings."] = true
L["Open or close the settings window."] = true
L["Could not register /%s: %s."] = true
