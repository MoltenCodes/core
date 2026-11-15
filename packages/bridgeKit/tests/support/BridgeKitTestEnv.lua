--- Package-specific test environment for the BridgeKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's module load order and the loader of the
--- AceSerializer fixtures recorded from Ace3 (`tests/fixtures/`).
local FrameworkTestEnv = require("FrameworkTestEnv")

local BridgeKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "BridgeKit" },
})

--- Where the recorded fixtures live, relative to the repository root, which is
--- the directory the test runner starts Busted in.
local FIXTURE_PATH = "packages/bridgeKit/tests/fixtures/AceSerializerFixtures.lua"

---The AceSerializer-3.0 fixtures recorded from Ace3 by
---`python3 -m tooling.fixtures.ace_serializer`.
---@return table fixtures `{ provenance, encode, decode }`
function BridgeKitTestEnv.AceSerializerFixtures()
  return dofile(FIXTURE_PATH)
end

---Load Registry, OptionsKit with what it requires, and BridgeKit, for the
---specs that define a converted tree. The test runner puts OptionsKit, an
---optional dependency, on the path.
---@return table BridgeKit
---@return table OptionsKit
function BridgeKitTestEnv.NewPackageWithOptionsKit()
  BridgeKitTestEnv.Reset()
  -- `Reset` unloads this package's own module chain; OptionsKit's goes too,
  -- so every spec gets fresh copies registered with a fresh Registry.
  for _, name in ipairs({ "SignalKit", "SchemaKit", "OptionsKit" }) do
    package.loaded[name] = nil
  end
  BridgeKitTestEnv.InstallWowApi()
  require("Registry")
  require("SignalKit")
  require("SchemaKit")
  local OptionsKit = require("OptionsKit")
  local BridgeKit = require("BridgeKit")
  return BridgeKit, OptionsKit
end

--- The player identity the SettingsKit-backed environment reports, and the
--- globals it installs; `Reset` removes them and every saved variable a spec
--- named through `SavedVariable`.
local PLAYER = { name = "Tester", realm = "Silvermoon", class = "MAGE", faction = "Alliance" }
local IDENTITY_GLOBALS =
  { "UnitName", "GetRealmName", "UnitClass", "UnitFactionGroup", "UnitNameUnmodified" }
local savedVariables = {}

---Write a host global: the fixture stands in for the client, whose API and
---saved variables only exist in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Set a saved-variable global, as the client does before `ADDON_LOADED`.
---@param name string
---@param value any
function BridgeKitTestEnv.SavedVariable(name, value)
  savedVariables[name] = true
  setGlobal(name, value)
end

---Read a global.
---@param name string
---@return any
function BridgeKitTestEnv.Global(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Report the player as `PLAYER`, and `unmodified` (when given) from
---`UnitNameUnmodified`.
---@param unmodified string?
function BridgeKitTestEnv.SetPlayer(unmodified)
  setGlobal("UnitName", function(unit)
    return unit == "player" and PLAYER.name or nil
  end)
  setGlobal("UnitNameUnmodified", function(unit)
    return unit == "player" and (unmodified or PLAYER.name) or nil
  end)
  setGlobal("GetRealmName", function()
    return PLAYER.realm
  end)
  setGlobal("UnitClass", function(unit)
    if unit == "player" then
      return "Mage", PLAYER.class, 8
    end
  end)
  setGlobal("UnitFactionGroup", function(unit)
    if unit == "player" then
      return PLAYER.faction, PLAYER.faction
    end
  end)
end

local baseReset = BridgeKitTestEnv.Reset

---Clear the fixture, then the globals only this environment installs.
function BridgeKitTestEnv.Reset()
  baseReset()
  for _, name in ipairs(IDENTITY_GLOBALS) do
    setGlobal(name, nil)
  end
  for name in pairs(savedVariables) do
    setGlobal(name, nil)
  end
  savedVariables = {}
end

---Load Registry, SchemaKit, SettingsKit with what it requires, and BridgeKit,
---with the player identity installed, for the importer specs.
---@return table BridgeKit
---@return table SettingsKit
---@return table SchemaKit
function BridgeKitTestEnv.NewPackageWithSettingsKit()
  BridgeKitTestEnv.Reset()
  for _, name in ipairs({ "SignalKit", "SchemaKit", "SettingsKit", "OptionsKit" }) do
    package.loaded[name] = nil
  end
  BridgeKitTestEnv.InstallWowApi()
  BridgeKitTestEnv.SetPlayer()
  require("Registry")
  require("SignalKit")
  local SchemaKit = require("SchemaKit")
  local SettingsKit = require("SettingsKit")
  local BridgeKit = require("BridgeKit")
  return BridgeKit, SettingsKit, SchemaKit
end

---A deep copy, for comparing a table before and after a call.
---@param value any
---@return any
function BridgeKitTestEnv.Snapshot(value)
  if type(value) ~= "table" then
    return value
  end
  local copy = {}
  for key, entry in pairs(value) do
    copy[key] = BridgeKitTestEnv.Snapshot(entry)
  end
  return copy
end

---Make `issecretvalue` report exactly the given values as secret.
---@param ... any
function BridgeKitTestEnv.MarkSecret(...)
  local secrets = {}
  for index = 1, select("#", ...) do
    secrets[select(index, ...)] = true
  end
  -- selene: allow(global_usage)
  rawset(_G, "issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---Load the BridgeKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. `edits` maps
---plain source fragments to their replacements, for a copy that differs in
---more than its revision.
---@param revision integer
---@param edits table<string, string>?
---@return table BridgeKit
function BridgeKitTestEnv.LoadRevision(revision, edits)
  local path = "packages/bridgeKit/src/BridgeKit.lua"
  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()
  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  assert(replacements == 1, "BridgeKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION")
  for fragment, replacement in pairs(edits or {}) do
    local first, last = patched:find(fragment, 1, true)
    assert(first ~= nil, "BridgeKitTestEnv.LoadRevision could not find " .. fragment)
    patched = patched:sub(1, first - 1) .. replacement .. patched:sub(last + 1)
  end
  return assert(loadstring(patched, "@" .. path))()
end

return BridgeKitTestEnv
