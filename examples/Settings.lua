-- ExampleAddon: Settings.lua
--
-- Shows: a SettingsKit database over the `.toc`'s saved variable, described by
-- a SchemaKit schema, with a `global` scope and a `profile`, and a versioned
-- migration from the layout an earlier release of this addon saved.
--
-- The database is a ModuleKit singleton rather than a file-scope value because
-- it must be opened in the `loaded` phase: before the addon's `ADDON_LOADED`
-- the client has not restored the saved variable yet. A singleton's factory
-- runs when the first module that injects it initializes, which is exactly
-- then.

local _, ADDON_TABLE = ...
---@cast ADDON_TABLE ExampleAddon.Private

local SchemaKit = ADDON_TABLE.Kits.SchemaKit
local SettingsKit = ADDON_TABLE.Kits.SettingsKit

--- The global name from the `.toc`'s `## SavedVariables` line.
local SAVED_VARIABLE = "ExampleAddonDB"

--- The version of the saved table this release writes.
local DATABASE_VERSION = 1

-- Every field is optional with a default: a saved variable starts empty and
-- fills in one write at a time, and only values that differ from their default
-- are kept after the logout compaction.
local SCHEMA = {
  global = SchemaKit.table({
    fields = {
      greetings = SchemaKit.optional(SchemaKit.number({ integer = true, min = 0 }), 0),
    },
  }),
  profile = SchemaKit.table({
    fields = {
      greet = SchemaKit.optional(SchemaKit.boolean(), true),
      announceHealth = SchemaKit.optional(SchemaKit.boolean(), false),
      windowScale = SchemaKit.optional(SchemaKit.number({ min = 0.5, max = 2 }), 1),
    },
  }),
}

local MIGRATIONS = {
  -- The release before SettingsKit saved `{ greetings = n }` at the top of the
  -- table. A migration receives a copy of the saved table and runs before the
  -- layout exists, so a step can restructure anything an older release wrote;
  -- the copy replaces the saved table only when the step returns.
  [1] = function(raw)
    if type(raw.greetings) ~= "nil" then
      raw.global = raw.global or {}
      raw.global.greetings = raw.greetings
      raw.greetings = nil
    end
  end,
}

---Open the addon's database. Called once, by ModuleKit, in the `loaded` phase.
---@return SettingsKit.Database
local function openDatabase()
  return SettingsKit:Open(SAVED_VARIABLE, SCHEMA, {
    defaultProfile = SettingsKit.DEFAULT_PROFILE,
    version = DATABASE_VERSION,
    migrations = MIGRATIONS,
  })
end

ADDON_TABLE.Modules:ProvideSingleton("Database", openDatabase)
