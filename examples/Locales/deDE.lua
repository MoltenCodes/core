-- ExampleAddon: Locales/deDE.lua
--
-- Shows: a translation file. `NewLocale` returns `nil` on every client that is
-- not German, so the file costs nothing there. A key this file leaves out
-- falls back to the default locale, and an indexed specifier (`%4$d`) lets the
-- translation put the arguments in its own order.

local ADDON_NAME, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local L = ADDON_TABLE.Kits.LocaleKit:NewLocale(ADDON_NAME, "deDE")
if not L then
    return
end

L["yes"] = "ja"
L["no"] = "nein"
L["%1$s is ready on the %2$s client (secret values: %3$s); greeting #%4$d."] =
    "Begrüßung Nr. %4$d: %1$s ist bereit (Client %2$s, geheime Werte: %3$s)."
L["Example Addon"] = "Beispiel-Addon"
L["Greet on login"] = "Beim Einloggen begrüßen"
L["Window scale"] = "Fenstergröße"
