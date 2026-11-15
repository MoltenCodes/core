-- MoltenCodes AddonKit part Composition
--
-- The two pairs of Kits nearly every addon wires together, each one call:
--
--   MC:Options(tree, { db, slash, title })  OptionsKit defines the tree,
--       PanelKit shows it in Blizzard's settings, and CommandKit registers a
--       slash command that opens it.
--   MC:Launcher(definition, db, field?)    BrokerKit creates the launcher
--       object, LauncherKit places its minimap button with its position kept
--       in `db.profile[field]`, and a profile switch moves the button.
--   MC.LAUNCHER_DEFAULTS                   LibDBIcon-1.0's three saved
--       fields, for the profile defaults: `minimap = MC.LAUNCHER_DEFAULTS`.
--
-- Each helper is a sequence of documented calls. Refusals the Kits return as
-- values (CommandKit's "taken") are raised at the author's line with the fix,
-- never dropped.
--
-- Contents
-- --------
--   Constants ........ identity, settings fields, refusal messages
--   Dependencies ..... AddonKit's core and its state
--   Methods .......... Options, Launcher
--   Fields ........... LAUNCHER_DEFAULTS
--   Commit ........... members and the part's revision

-- Constants ------------------------------------------------------------------

local PART_NAME = "Composition"
local PART_REVISION = 1
local REQUIRED_REGISTRY_API = 2
local CORE_PACKAGE, CORE_API = "addonKit", 1

-- The fields `MC:Options` accepts in its second argument.
local OPTIONS_FIELDS = { db = true, slash = true, title = true }

-- The profile field `MC:Launcher` keeps the button in when none is named.
local DEFAULT_LAUNCHER_FIELD = "minimap"

-- What each CommandKit `Register` refusal means for the author, and the fix.
local SLASH_REFUSALS = {
  taken = "/%s is already used by another addon or a chat command; pass another slash name to MC:Options",
  emote = "/%s is an emote's command; pass another slash name to MC:Options",
  full = "/%s cannot be added: the addon's CommandKit scope holds its most commands;"
    .. " unregister one or raise maxCommands",
}

-- Dependencies ---------------------------------------------------------------

-- The shared MoltenCodes namespace is the one documented global handoff point between independently embedded copies.
-- selene: allow(global_usage)
local namespace = rawget(_G, "MoltenCodes")
local generations = type(namespace) == "table" and rawget(namespace, "Registries") or nil
local Registry = type(generations) == "table" and rawget(generations, REQUIRED_REGISTRY_API) or nil
local AddonKit = nil
if type(Registry) == "table" and type(rawget(Registry, "Get")) == "function" then
  AddonKit = Registry:Get(CORE_PACKAGE, CORE_API)
end
local state = type(AddonKit) == "table" and rawget(AddonKit, "_state") or nil
if
  type(state) ~= "table"
  or type(rawget(state, "methods")) ~= "table"
  or type(rawget(state, "fields")) ~= "table"
  or type(rawget(state, "helpers")) ~= "table"
  or type(rawget(state, "parts")) ~= "table"
then
  error("MoltenCodes AddonKit part Composition requires AddonKit API 1 to be loaded first", 2)
end

local parts = rawget(state, "parts")
local installed = rawget(parts, PART_NAME)
if
  type(installed) == "table"
  and type(installed.revision) == "number"
  and installed.revision >= PART_REVISION
then
  -- An equal or newer revision of this part already serves every facade.
  return AddonKit
end

local methods = rawget(state, "methods")
local fields = rawget(state, "fields")
-- Read at call time, never copied: an upgraded core's helpers serve this part.
local helpers = rawget(state, "helpers")

---A fresh table of LibDBIcon-1.0's saved fields with their defaults.
---@return AddonKit.LauncherDefaults
local function launcherDefaults()
  return { hide = false, lock = false, minimapPos = 225 }
end

-- Methods --------------------------------------------------------------------

---Check the second argument of `MC:Options`.
---@param settings any
local function checkOptionsSettings(settings)
  if helpers.isSecret(settings) or (type(settings) ~= "nil" and type(settings) ~= "table") then
    error("MC:Options settings must be a table { db, slash, title } or nil", 3)
  end
  if settings == nil then
    return
  end
  for key in pairs(settings) do
    if helpers.isSecret(key) or not OPTIONS_FIELDS[key] then
      error("MC:Options settings holds an unknown field; it accepts db, slash and title", 3)
    end
  end
  if settings.slash ~= nil then
    helpers.requireName(settings.slash, "MC:Options settings.slash", 4)
  end
  if settings.title ~= nil then
    helpers.requireName(settings.title, "MC:Options settings.title", 4)
  end
end

---Define the addon's options tree, show it in Blizzard's settings and, with
---`settings.slash`, open it from a slash command. The command is registered
---first, so a refused name leaves no tree and no panel behind.
---@param self MoltenCodesFacade
---@param tree table an OptionsKit tree
---@param settings AddonKit.OptionsSettings?
---@return table panel a PanelKit panel
local function facadeOptions(self, tree, settings)
  local record = helpers.requireRecord(self, "MC:Options", 3)
  if helpers.isSecret(tree) or type(tree) ~= "table" then
    error(
      'MC:Options tree must be an OptionsKit tree: { type = "group", name = ..., args = { ... } }',
      2
    )
  end
  checkOptionsSettings(settings)
  settings = settings or {}
  local OptionsKit = helpers.requireKit(record, "OptionsKit", 3)
  local PanelKit = helpers.requireKit(record, "PanelKit", 3)
  local addonName = record.addonName
  local title = settings.title
  if title == nil then
    local treeName = tree.name
    title = (not helpers.isSecret(treeName) and type(treeName) == "string" and treeName ~= "")
        and treeName
      or addonName
  end

  local panel = nil
  local commands, slash = nil, settings.slash
  if slash ~= nil then
    local CommandKit = helpers.requireKit(record, "CommandKit", 3)
    commands = helpers.callAtCaller(3, CommandKit.ForAddon, CommandKit, addonName)
    local registered, reason = helpers.callAtCaller(3, commands.Register, commands, slash, {
      handler = function()
        if panel ~= nil then
          panel:Open()
        end
      end,
    })
    if not registered then
      local template = SLASH_REFUSALS[reason] or ("/%s was refused (" .. tostring(reason) .. ")")
      error("MC:Options " .. string.format(template, slash), 2)
    end
  end

  local ok, failure = pcall(function()
    OptionsKit:Define(addonName, tree, settings.db ~= nil and { db = settings.db } or nil)
    panel = PanelKit:Register(addonName, { name = title })
  end)
  if not ok then
    if commands ~= nil then
      pcall(commands.Unregister, commands, slash)
    end
    -- The Kits raised at the closure's lines; their messages lose that
    -- position and take the author's line instead.
    error(helpers.withoutPosition(failure), 2)
  end
  -- `Register` returned a panel or raised above.
  return panel --[[@as table]]
end

---A minimap button for the addon, its position kept in `db.profile[field]`
---and moved on a profile switch. The launcher object is named after the addon.
---@param self MoltenCodesFacade
---@param definition table BrokerKit attributes; `type` defaults to `"launcher"`
---@param db table a SettingsKit database whose profile declares `field`
---@param field string? the profile field holding LibDBIcon's fields; default `"minimap"`
---@return table launcher a LauncherKit launcher
local function facadeLauncher(self, definition, db, field)
  local record = helpers.requireRecord(self, "MC:Launcher", 3)
  if helpers.isSecret(definition) or type(definition) ~= "table" then
    error(
      "MC:Launcher definition must be a table of BrokerKit attributes: { icon = ..., OnClick = ... }",
      2
    )
  end
  if helpers.isSecret(db) or type(db) ~= "table" or type(db.Validate) ~= "function" then
    error("MC:Launcher db must be a database from MC:Database (or SettingsKit:Open)", 2)
  end
  if field == nil then
    field = DEFAULT_LAUNCHER_FIELD
  else
    helpers.requireName(field, "MC:Launcher field", 3)
  end
  local BrokerKit = helpers.requireKit(record, "BrokerKit", 3)
  local LauncherKit = helpers.requireKit(record, "LauncherKit", 3)
  local declared, reason =
    helpers.callAtCaller(3, db.Validate, db, "profile", { field }, launcherDefaults())
  if not declared then
    error(
      string.format(
        "MC:Launcher the database does not take profile.%s (%s); declare %s = MC.LAUNCHER_DEFAULTS"
          .. " in the profile defaults",
        field,
        tostring(reason),
        field
      ),
      2
    )
  end
  local attributes = {}
  for key, value in pairs(definition) do
    attributes[key] = value
  end
  if attributes.type == nil then
    attributes.type = "launcher"
  end
  local addonName = record.addonName
  helpers.callAtCaller(3, BrokerKit.New, BrokerKit, addonName, attributes)
  local launcher = helpers.callAtCaller(3, LauncherKit.Register, LauncherKit, addonName, function()
    return db.profile[field]
  end)
  helpers.callAtCaller(3, db.OnProfileChanged, db, function()
    launcher:Refresh()
  end)
  return launcher
end

-- Commit ---------------------------------------------------------------------

rawset(methods, "Options", facadeOptions)
rawset(methods, "Launcher", facadeLauncher)
rawset(fields, "LAUNCHER_DEFAULTS", launcherDefaults)
rawset(parts, PART_NAME, { revision = PART_REVISION })

return AddonKit
