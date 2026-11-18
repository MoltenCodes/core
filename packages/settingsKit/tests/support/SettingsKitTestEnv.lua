--- Package-specific test environment for the SettingsKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order and the host
--- surface only SettingsKit touches, which the shared fixture does not model:
---
---   `UnitName`, `GetRealmName`, `UnitClass`, `UnitFactionGroup`, `UnitRace`,
---   `GetLocale`, `GetCurrentRegion`, `GetCurrentRegionName`
---                        the player identity `Open` resolves its scope keys
---                        from, set by `SetPlayer`;
---   `issecretvalue`      installed by `InstallSecretProbe`, reporting the
---                        tables `NewSecret` returns;
---   `C_SpecializationInfo`, `GetNumTalentGroups`
---                        the specialization and talent-group answers spec
---                        profiles read, installed by `SetSpecialization`
---                        from a table a spec keeps changing;
---   saved variables      globals a spec names, removed by `Reset`.
---
--- These globals are not among the ones the shared fixture owns, so `Reset`
--- removes them itself. `issecretvalue` is owned by the fixture and cleared by
--- its own `Reset`.
---
--- EventKit is an optional dependency of SettingsKit, declared under
--- `optionalDependencies`, so the test runner puts it on `LUA_PATH` for this
--- suite; `NewPackageWithoutEventKit` models an addon that embeds none.
---
--- `NewPackage` loads the core with the SpecProfiles part, and SchemaKit with
--- its Rules and Apply parts (the specs build patterns and `custom` nodes),
--- the surface most specs describe. `NewCore` loads the core without any
--- SettingsKit part; `LoadNamespaces` and `LoadSpecProfiles` add one.
--- `LoadRevision(n)` takes revision 15 and older from the byte copy
--- `fixtures/SettingsKit-revision15.lua`, the last single-file revision.
local FrameworkTestEnv = require("FrameworkTestEnv")

local SettingsKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "EventKit", "SchemaKit", "SettingsKit" },
})

--- The player identity host functions this environment installs and removes.
local IDENTITY_GLOBALS = {
  "UnitName",
  "UnitNameUnmodified",
  "GetRealmName",
  "UnitClass",
  "UnitFactionGroup",
  "UnitRace",
  "GetLocale",
  "GetCurrentRegion",
  "GetCurrentRegionName",
}

--- The specialization host surface `SetSpecialization` installs and `Reset`
--- removes. `WOW_PROJECT_ID` is owned, and cleared, by the shared fixture.
local SPECIALIZATION_GLOBALS = { "C_SpecializationInfo", "GetNumTalentGroups" }

--- The identity a fresh environment reports.
local DEFAULT_PLAYER = {
  name = "Tester",
  realm = "Silvermoon",
  class = "MAGE",
  faction = "Alliance",
  race = "Scourge",
  locale = "enUS",
  region = 3,
  regionName = "EU",
}

--- Saved-variable globals specs created through `SavedVariable`.
local savedVariables = {}

--- Tables the `issecretvalue` stub reports as secret. Weak-keyed so a spec's
--- secrets never outlive it.
local secrets = setmetatable({}, { __mode = "k" })

---Write a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Write a host global from a spec, for a host function a case replaces.
---@param name string
---@param value any
function SettingsKitTestEnv.SetGlobal(name, value)
  setGlobal(name, value)
end

---Read a host global the same way.
---@param name string
---@return any
function SettingsKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Install the identity functions for `player`. A field set to `false` leaves
---that function out, so the scope it feeds is unavailable. `race`, `locale`,
---`region` (the number `GetCurrentRegion` answers) and `regionName` feed the
---scopes revision 15 added; each may be any value, for the fallback cases.
---`unmodified`, when given, installs `UnitNameUnmodified` answering it (any
---value, for the fallback cases); without it the function is left out, as on
---a client without one.
---@param player table? `{ name, realm, class, faction, unmodified, race, locale, region, regionName }`; omitted fields take the defaults
function SettingsKitTestEnv.SetPlayer(player)
  player = player or {}
  local function pick(field)
    local value = player[field]
    if value == nil then
      return DEFAULT_PLAYER[field]
    end
    return value
  end

  local name, realm, class, faction = pick("name"), pick("realm"), pick("class"), pick("faction")
  setGlobal("UnitName", name ~= false and function(unit)
    if unit == "player" then
      return name, nil
    end
    return nil
  end or nil)
  local unmodified = player.unmodified
  setGlobal("UnitNameUnmodified", unmodified ~= nil and function(unit)
    if unit == "player" then
      return unmodified, nil
    end
    return nil
  end or nil)
  setGlobal("GetRealmName", realm ~= false and function()
    return realm
  end or nil)
  setGlobal("UnitClass", class ~= false and function(unit)
    if unit == "player" then
      return "Localized " .. class, class, 8
    end
    return nil
  end or nil)
  setGlobal("UnitFactionGroup", faction ~= false and function(unit)
    if unit == "player" then
      return faction, "Localized " .. faction
    end
    return nil
  end or nil)
  local race, locale = pick("race"), pick("locale")
  local region, regionName = pick("region"), pick("regionName")
  setGlobal("UnitRace", race ~= false and function(unit)
    if unit == "player" then
      return "Localized race", race, 5
    end
    return nil
  end or nil)
  setGlobal("GetLocale", locale ~= false and function()
    return locale
  end or nil)
  setGlobal("GetCurrentRegion", region ~= false and function()
    return region
  end or nil)
  setGlobal("GetCurrentRegionName", regionName ~= false and function()
    return regionName
  end or nil)
end

---Install the specialization surface of a client and return the table it
---answers from, so a spec changes the player's specialization by writing a
---field and then emitting the event the client would send.
---
---Fields: `projectId` (`WOW_PROJECT_ID`; `nil` leaves it unset),
---`initialized` (`C_SpecializationInfo.IsInitialized`, default `true`),
---`specialization` (`GetSpecialization`), `classCount`
---(`GetNumSpecializationsForClassID`, answered only for class ID 8, the one
---`SetPlayer` reports), `talentGroup` (`GetActiveSpecGroup`) and
---`talentGroups` (`GetNumTalentGroups`; `false` leaves the function out).
---@param client table
---@return table client the same table, read on every call
function SettingsKitTestEnv.SetSpecialization(client)
  if client.initialized == nil then
    client.initialized = true
  end
  setGlobal("WOW_PROJECT_ID", client.projectId)
  setGlobal("C_SpecializationInfo", {
    IsInitialized = function()
      return client.initialized
    end,
    GetSpecialization = function()
      return client.specialization
    end,
    GetNumSpecializationsForClassID = function(classID)
      if classID == 8 then
        return client.classCount
      end
      return 0
    end,
    GetActiveSpecGroup = function()
      return client.talentGroup
    end,
  })
  setGlobal("GetNumTalentGroups", client.talentGroups ~= false and function()
    return client.talentGroups
  end or nil)
  return client
end

---Set a saved-variable global, as the client does before `ADDON_LOADED`.
---`Reset` removes it.
---@param name string
---@param value any
function SettingsKitTestEnv.SavedVariable(name, value)
  savedVariables[name] = true
  setGlobal(name, value)
end

---Install an `issecretvalue` that reports the tables `NewSecret` returns.
function SettingsKitTestEnv.InstallSecretProbe()
  setGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---Return a new value the `issecretvalue` stub reports as secret.
---@return table secret
function SettingsKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

local baseReset = SettingsKitTestEnv.Reset
local baseNewPackage = SettingsKitTestEnv.NewPackage

--- Every part module a spec may load, cleared by `Reset`.
local PART_MODULES = {
  "SettingsKit-Namespaces",
  "SettingsKit-SpecProfiles",
  "SettingsKit-Defaults",
  "SchemaKit-Rules",
  "SchemaKit-Apply",
}

local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"

-- The last single-file revision, kept verbatim so an "older copy" in the
-- upgrade specs is the whole file an addon of that time embedded.
local REVISION_15_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/SettingsKit-revision15.lua"

---Load SchemaKit's Rules and Apply parts, for the specs that build patterns,
---`custom` and `oneOf` nodes or apply defaults.
local function loadSchemaKitParts()
  require("SchemaKit-Rules")
  require("SchemaKit-Apply")
end

---Clear the fixture, then the globals only this environment installs.
---
---`SettingsKit:Open` creates a missing saved variable, so the names of every
---database the package opened are read from its package state before the
---module chain is unloaded, and those globals are removed too.
function SettingsKitTestEnv.Reset()
  local SettingsKit = package.loaded["SettingsKit"]
  local packageState = type(SettingsKit) == "table" and rawget(SettingsKit, "_state") or nil
  local databases = type(packageState) == "table" and rawget(packageState, "databases") or nil
  if type(databases) == "table" then
    for name in pairs(databases) do
      savedVariables[name] = true
    end
  end

  baseReset()
  for index = 1, #PART_MODULES do
    package.loaded[PART_MODULES[index]] = nil
  end
  for index = 1, #IDENTITY_GLOBALS do
    setGlobal(IDENTITY_GLOBALS[index], nil)
  end
  for index = 1, #SPECIALIZATION_GLOBALS do
    setGlobal(SPECIALIZATION_GLOBALS[index], nil)
  end
  for name in pairs(savedVariables) do
    setGlobal(name, nil)
    savedVariables[name] = nil
  end
end

---Load the module chain with the SpecProfiles part and SchemaKit's parts,
---and install the default player identity.
---@return table SettingsKit, table Registry, table SignalKit, table EventKit, table SchemaKit
function SettingsKitTestEnv.NewPackage()
  local SettingsKit, Registry, SignalKit, EventKit, SchemaKit = baseNewPackage()
  loadSchemaKitParts()
  require("SettingsKit-SpecProfiles")
  SettingsKitTestEnv.SetPlayer()
  return SettingsKit, Registry, SignalKit, EventKit, SchemaKit
end

---Load the module chain without any SettingsKit part, as an addon that
---embeds the core alone does; SchemaKit's parts are loaded.
---@return table SettingsKit, table Registry, table SignalKit, table EventKit, table SchemaKit
function SettingsKitTestEnv.NewCore()
  local SettingsKit, Registry, SignalKit, EventKit, SchemaKit = baseNewPackage()
  loadSchemaKitParts()
  SettingsKitTestEnv.SetPlayer()
  return SettingsKit, Registry, SignalKit, EventKit, SchemaKit
end

---Load the Defaults part after the core, as an addon that embeds it does.
---@return table SettingsKit
function SettingsKitTestEnv.LoadDefaults()
  package.loaded["SettingsKit-Defaults"] = nil
  return require("SettingsKit-Defaults")
end

---Load the SpecProfiles part after the core, as an addon that embeds it does.
---@return table SettingsKit
function SettingsKitTestEnv.LoadSpecProfiles()
  package.loaded["SettingsKit-SpecProfiles"] = nil
  return require("SettingsKit-SpecProfiles")
end

---Load the Namespaces part after the core, as an addon that embeds it does.
---@return table SettingsKit
function SettingsKitTestEnv.LoadNamespaces()
  package.loaded["SettingsKit-Namespaces"] = nil
  return require("SettingsKit-Namespaces")
end

---Load the module chain without EventKit, as an addon that embeds none does.
---@return table SettingsKit, table Registry, table SchemaKit
function SettingsKitTestEnv.NewPackageWithoutEventKit()
  SettingsKitTestEnv.Reset()
  SettingsKitTestEnv.InstallWowApi()
  local Registry = require("Registry")
  require("SignalKit")
  local SchemaKit = require("SchemaKit")
  local SettingsKit = require("SettingsKit")
  loadSchemaKitParts()
  require("SettingsKit-SpecProfiles")
  SettingsKitTestEnv.SetPlayer()
  return SettingsKit, Registry, SchemaKit
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function SettingsKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Load the SettingsKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. A revision up to
---15 is loaded from the revision 15 fixture (spec profiles in the core, no
---SpecProfiles part); a later one from the core in `src/`.
---@param revision integer
---@return table SettingsKit
function SettingsKitTestEnv.LoadRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  if revision <= 15 then
    path = REVISION_15_FIXTURE
  else
    for template in package.path:gmatch("[^;]+") do
      local candidate = template:gsub("%?", "SettingsKit")
      local file = io.open(candidate, "r")
      if file ~= nil then
        file:close()
        path = candidate
        break
      end
    end
  end
  if path == nil then
    error("SettingsKitTestEnv.LoadRevision could not find SettingsKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("SettingsKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return SettingsKitTestEnv
