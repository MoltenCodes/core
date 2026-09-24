-- ExampleAddon: Options.lua
--
-- Shows: an OptionsKit tree bound to the SettingsKit database. The tree says
-- what is configurable and how it is presented; `bind` points each option at a
-- database field, so reads fall back to the schema defaults and writes are
-- validated twice, by the option and by the stored field. `ProfileOptions`
-- adds the ready-made group that switches, creates, copies, resets and deletes
-- the database's profiles. The same tree drives both the `/exampleaddon`
-- command line (Commands.lua) and the settings window (Window.lua); neither
-- knows the options by name.

local ADDON_NAME, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local OptionsKit = ADDON_TABLE.Kits.OptionsKit
local L = ADDON_TABLE.Kits.LocaleKit:GetLocale(ADDON_NAME)

--- The root group. Keys are the dotted paths a command line types:
--- `/exampleaddon set windowScale 1.25`.
local TREE = {
  type = "group",
  name = L["Example Addon"],
  args = {
    intro = {
      type = "description",
      name = L["Settings for the example addon."],
      order = 0,
    },
    greet = {
      type = "toggle",
      name = L["Greet on login"],
      order = 1,
      bind = "profile.greet",
    },
    announceHealth = {
      type = "toggle",
      name = L["Announce health changes"],
      order = 2,
      bind = "profile.announceHealth",
    },
    windowScale = {
      type = "range",
      name = L["Window scale"],
      order = 3,
      min = 0.5,
      max = 2,
      step = 0.05,
      isPercent = true,
      bind = "profile.windowScale",
    },
  },
}

---Define the options tree over the database. Called once, by ModuleKit, when
---the main module initializes.
---@param modules ModuleKit.Addon
---@return OptionsKit.Tree
local function defineOptions(modules)
  local database = modules:Resolve("Database")
  -- The profile group needs the open database, so it joins the tree here.
  -- It is placed as it is: `Define` recognises the table and connects it to
  -- the database's profile signals, so the window redraws after a switch.
  TREE.args.profiles = OptionsKit:ProfileOptions(database, { order = 10 })
  return OptionsKit:Define(ADDON_NAME, TREE, { db = database })
end

ADDON_TABLE.Modules:ProvideSingleton("Options", defineOptions)
