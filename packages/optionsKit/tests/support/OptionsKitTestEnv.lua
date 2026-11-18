--- Package-specific test environment for the OptionsKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the helpers
--- only its specs describe: a SettingsKit stand-in for `bind` specs,
--- allocation measurement and an in-place upgrade.
---
--- SettingsKit is an optional dependency, declared under
--- `optionalDependencies`. For the specs that do not need the real package,
--- `InstallSettingsKitStub` registers a stand-in under `settingsKit` API 1 so
--- `Registry:Find` answers, and `NewDatabase` builds a database with the
--- documented shape: six scope tables whose reads fall back to defaults
--- through a metatable, and `OnChange` and `Validate` methods.
local FrameworkTestEnv = require("FrameworkTestEnv")

local OptionsKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "SchemaKit",
    "SchemaKit-Rules",
    "OptionsKit",
    "OptionsKit-Presentation",
    "OptionsKit-Handlers",
    "OptionsKit-Bind",
    "OptionsKit-Profiles",
    "OptionsKit-Dynamic",
  },
})

--- OptionsKit's parts, in the order `NewPackage` loads them after the core.
OptionsKitTestEnv.PART_MODULES = {
  "OptionsKit-Presentation",
  "OptionsKit-Handlers",
  "OptionsKit-Bind",
  "OptionsKit-Profiles",
  "OptionsKit-Dynamic",
}

---Load SettingsKit and its SpecProfiles part, which the Profiles part's spec
---selects need (SettingsKit 0.7.0 moved spec profiles into that part), as an
---addon embedding both does.
---@return table SettingsKit
function OptionsKitTestEnv.RequireSettingsKit()
  -- Run both files again: `Reset` does not unload SettingsKit, which is not
  -- in the module chain, so a cached module would be a facade an earlier
  -- spec's Registry held. A second run in one spec yields to the copy it
  -- loaded first.
  package.loaded["SettingsKit"] = nil
  package.loaded["SettingsKit-SpecProfiles"] = nil
  local SettingsKit = require("SettingsKit")
  require("SettingsKit-SpecProfiles")
  return SettingsKit
end

---Load one OptionsKit part after the core, as an addon that embeds it does.
---@param partName string `"Presentation"`, `"Handlers"`, `"Bind"`, `"Profiles"` or `"Dynamic"`
---@return table OptionsKit
function OptionsKitTestEnv.LoadPart(partName)
  local moduleName = "OptionsKit-" .. partName
  package.loaded[moduleName] = nil
  return require(moduleName)
end

--- The scopes a SettingsKit database exposes.
local SCOPES = { "global", "char", "realm", "class", "faction", "profile" }

---Register a SettingsKit API 1 stand-in with Registry, so that
---`Registry:Find("settingsKit", 1)` finds it.
---@param Registry table
---@return table SettingsKit the stand-in facade
function OptionsKitTestEnv.InstallSettingsKitStub(Registry)
  local SettingsKit = Registry:Register("settingsKit", 1, 1)
  rawset(SettingsKit, "API", 1)
  rawset(SettingsKit, "REVISION", 1)
  return SettingsKit
end

---Build a live table over `defaults`: reads of absent keys fall back to the
---default, writes land in the table itself, and nested default tables become
---nested live tables, as SettingsKit's scope tables behave.
---@param defaults table
---@return table live
local function newLiveTable(defaults)
  local live = {}
  for key, value in pairs(defaults) do
    if type(value) == "table" then
      live[key] = newLiveTable(value)
    end
  end
  return setmetatable(live, { __index = defaults })
end

---Build a SettingsKit-shaped database.
---@param defaults table? defaults per scope, such as `{ profile = { scale = 1 } }`
---@return table db
function OptionsKitTestEnv.NewDatabase(defaults)
  defaults = defaults or {}
  local db = {}
  for index = 1, #SCOPES do
    local scope = SCOPES[index]
    db[scope] = newLiveTable(defaults[scope] or {})
  end
  function db:OnChange(_, _)
    return nil
  end
  -- The stand-in's scopes declare no schema, so every write is accepted.
  function db:Validate(_, _, _)
    return true
  end
  return db
end

---Reset and load OptionsKit's core without its parts, the way an addon that
---embeds the core alone loads it.
---@return table OptionsKit
---@return table Registry
function OptionsKitTestEnv.NewCorePackage()
  OptionsKitTestEnv.Reset()
  OptionsKitTestEnv.InstallWowApi()
  local Registry = require("Registry")
  require("SignalKit")
  require("SchemaKit")
  require("SchemaKit-Rules")
  return require("OptionsKit"), Registry
end

---Build a SettingsKit-shaped database with namespaces, as SettingsKit
---revision 15 offers them: `GetNamespace(name, { missingOk = true })` answers
---the child database registered under `name`, or `nil`.
---@param defaults table? defaults per scope of the parent
---@param namespaces table<string, table> name to that namespace's defaults per scope
---@return table db
---@return table<string, table> children
function OptionsKitTestEnv.NewDatabaseWithNamespaces(defaults, namespaces)
  local db = OptionsKitTestEnv.NewDatabase(defaults)
  local children = {}
  for name, childDefaults in pairs(namespaces) do
    children[name] = OptionsKitTestEnv.NewDatabase(childDefaults)
  end
  function db:GetNamespace(name, options)
    local child = children[name]
    if child == nil and not (type(options) == "table" and options.missingOk == true) then
      error("SettingsKit.Database:GetNamespace name names no registered namespace", 2)
    end
    return child
  end
  return db, children
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function OptionsKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

-- The last single-file core revision, kept verbatim as a fixture, so an
-- "older copy" in the upgrade specs is the whole file an addon of that time
-- embedded (presentation fields, method names and binds inside).
local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local REVISION_15_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/OptionsKit-revision15.lua"

---Find the core file on `package.path`, as `require` would.
---@return string path
local function findCoreSource()
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "OptionsKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      return candidate
    end
  end
  error("OptionsKitTestEnv.LoadRevision could not find OptionsKit.lua on package.path", 3)
end

---Load the OptionsKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. A revision up to
---15 is loaded from the revision 15 fixture, the last single-file core; a
---later one from the core in `src/`. A revision older than 15 stands in for
---a copy that also held `ProfileOptions`, so the Profiles part loads with it.
---SchemaKit's Rules part, which OptionsKit's manifest names, is loaded first
---when it is not.
---@param revision integer
---@return table OptionsKit
function OptionsKitTestEnv.LoadRevision(revision)
  if package.loaded["SchemaKit"] ~= nil and package.loaded["SchemaKit-Rules"] == nil then
    require("SchemaKit-Rules")
  end
  local path = revision <= 15 and REVISION_15_FIXTURE or findCoreSource()

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("OptionsKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  local loaded = chunk()
  -- Revisions 14 and older were one file holding `ProfileOptions`; a copy
  -- standing in for one loads the Profiles part with it.
  if revision < 15 and package.loaded["OptionsKit-Profiles"] == nil then
    require("OptionsKit-Profiles")
  end
  return loaded
end

return OptionsKitTestEnv
