--- Package-specific test environment for the LifecycleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order, and the combat
--- lockdown host surface only the combat gate reads.
---
--- TimerKit, SchedulerKit, HookKit, CommandKit and CommKit are optional
--- dependencies: shutdown closes the addon's scope in each when it is loaded,
--- found through `Registry:Find`. The manifest declares all five under
--- `optionalDependencies`, so the test runner puts them and their required
--- closures on `LUA_PATH`. The module
--- chain loads HookKit and CommandKit (and SchemaKit, while CommandKit's
--- manifest requires it) before LifecycleKit, as an addon that embeds them would;
--- `NewPackageWithoutHookKit` loads the chain without either. CommKit is kept
--- out of the chain, so `LoadCommKit` adds it afterwards. The slash-command section
--- below models the host surface CommandKit writes to.
---
--- The shared fixture does not model `InCombatLockdown` yet, so this file adds
--- it on top of the fixture's own install and reset: `InstallWowApi` installs
--- the global and `Reset` removes it again, so no spec leaks combat state into
--- the next one.
local FrameworkTestEnv = require("FrameworkTestEnv")

---Whether CommandKit's manifest still lists SchemaKit as a required
---dependency. A CommandKit whose schema-checked arguments moved into a part
---needs SchemaKit only for that part, and then the chain leaves it out.
---@return boolean
local function commandKitRequiresSchemaKit()
  local file = io.open("packages/commandKit/package.manifest.json", "r")
  if file == nil then
    return true
  end
  local text = file:read("*a")
  file:close()
  local dependencies = text:match('"dependencies"%s*:%s*(%b{})') or ""
  return dependencies:find('"schemaKit"', 1, true) ~= nil
end

--- The module chain, in load order; the package under test last.
local MODULES = { "Registry", "SignalKit", "EventKit", "HookKit" }
if commandKitRequiresSchemaKit() then
  MODULES[#MODULES + 1] = "SchemaKit"
end
MODULES[#MODULES + 1] = "CommandKit"
-- SignalKit's Bus part: the shutdown specs subscribe on an addon's bus
-- (`SignalKit:ForAddon`) to see LifecycleKit close it. LifecycleKit itself
-- calls only `CloseAddonBus`, which SignalKit's core keeps.
MODULES[#MODULES + 1] = "SignalKit-Bus"
MODULES[#MODULES + 1] = "LifecycleKit"

local LifecycleKitTestEnv = FrameworkTestEnv.New({ modules = MODULES })

---A module the chain loaded, by name, so a spec need not count its position
---in the chain (which changes with what CommandKit requires).
---@param name string such as `"CommandKit"`
---@return table
function LifecycleKitTestEnv.Module(name)
  local loaded = package.loaded[name]
  if type(loaded) ~= "table" then
    error("LifecycleKitTestEnv.Module: " .. tostring(name) .. " is not loaded", 2)
  end
  return loaded
end

--- The host's combat lockdown, as `InCombatLockdown()` reports it.
local combat = { lockdown = false }

local installFixtureWowApi = LifecycleKitTestEnv.InstallWowApi
local resetFixture = LifecycleKitTestEnv.Reset
local loadChain = LifecycleKitTestEnv.NewPackage

-- The parts -----------------------------------------------------------------
--
-- `NewPackage` loads both parts after the core, as an addon embedding them
-- does, so the suites of the combat gate and of halting run unchanged.
-- `NewCore` loads the core alone, and `LoadParts` adds the parts later, as an
-- addon loaded after it would. `Reset` unloads them.

--- The part modules, in load order.
local PART_MODULES = { "LifecycleKit-CombatGate", "LifecycleKit-Halt" }

---Clear the part modules from `package.loaded`.
local function unloadParts()
  for index = #PART_MODULES, 1, -1 do
    package.loaded[PART_MODULES[index]] = nil
  end
end

---Load both parts on top of a core already loaded.
---@return table LifecycleKit
function LifecycleKitTestEnv.LoadParts()
  local loaded
  for index = 1, #PART_MODULES do
    loaded = require(PART_MODULES[index])
  end
  return loaded
end

---Load the module chain without either part.
---@return ... LifecycleKit first, then the chain in load order
function LifecycleKitTestEnv.NewCore()
  return loadChain()
end

---Load the module chain and both parts.
---@return ... LifecycleKit first, then the chain in load order
function LifecycleKitTestEnv.NewPackage()
  local results = { loadChain() }
  LifecycleKitTestEnv.LoadParts()
  return unpack(results)
end

-- The slash-command host surface -------------------------------------------
--
-- CommandKit writes `SlashCmdList[key]` and the `SLASH_<key><n>` globals, which
-- the shared fixture does not own. `InstallWowApi` installs an empty
-- `SlashCmdList`, `RunSlash` does what the client does with a typed line, and
-- `Reset` removes the table and every `SLASH_*` global a spec's
-- registrations wrote, so none leaks into the next spec.

---Read a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@return any
local function getGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global, for the same reason.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Remove `SlashCmdList`, `SecureCmdList` and every `SLASH_*` global.
local function removeSlashApi()
  local names = {}
  -- selene: allow(global_usage)
  for name in pairs(_G) do
    if type(name) == "string" and name:sub(1, 6) == "SLASH_" then
      names[#names + 1] = name
    end
  end
  for index = 1, #names do
    setGlobal(names[index], nil)
  end
  setGlobal("SlashCmdList", nil)
  setGlobal("SecureCmdList", nil)
end

---Run a typed slash line the way the client does: find the key whose
---`SLASH_<key><n>` global matches the command, without case, and call its
---`SlashCmdList` function with the rest of the line.
---@param line string for example `"/myaddon status"`
---@return boolean found whether any registered key answered to the command
local function runSlash(line)
  local command, rest = line:match("^(/%S+)%s*(.*)$")
  local slashCommands = getGlobal("SlashCmdList")
  if command == nil or type(slashCommands) ~= "table" then
    return false
  end
  for key, handler in pairs(slashCommands) do
    local index = 1
    local alias = getGlobal("SLASH_" .. key .. index)
    while alias ~= nil do
      if alias:lower() == command:lower() then
        handler(rest, nil)
        return true
      end
      index = index + 1
      alias = getGlobal("SLASH_" .. key .. index)
    end
  end
  return false
end

LifecycleKitTestEnv.RunSlash = runSlash

-- CommKit ------------------------------------------------------------------
--
-- CommKit is an optional dependency; it requires SignalKit, EventKit, TimerKit,
-- SchedulerKit and PoolKit, not LifecycleKit. It is kept out of the module
-- chain above so the plain suites load without it. `LoadCommKit` loads the four on top of a chain
-- `NewPackage` already loaded, which is also how the shutdown specs reach
-- TimerKit and SchedulerKit; the runner puts them on `LUA_PATH` as optional
-- dependencies and as CommKit's required closure, and `Reset` clears them.

--- The modules `LoadCommKit` adds, in load order.
local COMM_KIT_MODULES = { "TimerKit", "SchedulerKit", "PoolKit", "CommKit" }

---Clear the modules `LoadCommKit` added from `package.loaded`.
local function unloadCommKit()
  for index = #COMM_KIT_MODULES, 1, -1 do
    package.loaded[COMM_KIT_MODULES[index]] = nil
  end
end

---Load CommKit and its remaining dependencies after `NewPackage`.
---@return table CommKit
function LifecycleKitTestEnv.LoadCommKit()
  local loaded
  for index = 1, #COMM_KIT_MODULES do
    loaded = require(COMM_KIT_MODULES[index])
  end
  return loaded
end

---Install the shared fixture's WoW API plus an empty `SlashCmdList` and
---`InCombatLockdown`.
function LifecycleKitTestEnv.InstallWowApi()
  installFixtureWowApi()
  setGlobal("SlashCmdList", {})
  -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "InCombatLockdown", function()
    return combat.lockdown
  end)
end

---Reset the shared fixture, unload what `LoadCommKit` added, and remove the
---slash-command globals and the combat lockdown stub.
function LifecycleKitTestEnv.Reset()
  unloadParts()
  resetFixture()
  unloadCommKit()
  removeSlashApi()
  combat.lockdown = false
  -- The fixture stands in for the World of Warcraft client, whose API only exists in the global table.
  -- selene: allow(global_usage)
  rawset(_G, "InCombatLockdown", nil)
end

---Load the module chain without HookKit and CommandKit, as an addon that
---embeds neither does.
---@return table LifecycleKit
---@return table Registry
---@return table SignalKit
---@return table EventKit
function LifecycleKitTestEnv.NewPackageWithoutHookKit()
  LifecycleKitTestEnv.Reset()
  LifecycleKitTestEnv.InstallWowApi()
  local Registry = require("Registry")
  local SignalKit = require("SignalKit")
  require("SignalKit-Bus")
  local EventKit = require("EventKit")
  local LifecycleKit = require("LifecycleKit")
  LifecycleKitTestEnv.LoadParts()
  return LifecycleKit, Registry, SignalKit, EventKit
end

---Set what `InCombatLockdown()` answers, without sending any event.
---@param value boolean
function LifecycleKitTestEnv.SetCombatLockdown(value)
  combat.lockdown = value == true
end

---Enter combat the way the client does.
---
---`PLAYER_REGEN_DISABLED` is sent just before lockdown begins, so handlers of
---the event still see `InCombatLockdown()` answer `false`.
function LifecycleKitTestEnv.EnterCombat()
  LifecycleKitTestEnv.Emit("PLAYER_REGEN_DISABLED")
  combat.lockdown = true
end

---Leave combat the way the client does: lockdown lifts, then
---`PLAYER_REGEN_ENABLED` is sent.
function LifecycleKitTestEnv.LeaveCombat()
  combat.lockdown = false
  LifecycleKitTestEnv.Emit("PLAYER_REGEN_ENABLED")
end

-- Revision 18, the last revision before the parts and the upgrade floor, kept
-- verbatim so a spec can stand in for an addon that embeds it.
local REVISION_18_FIXTURE = "packages/lifecycleKit/tests/fixtures/LifecycleKit-revision18.lua"

---Run revision 18 as an older embedded copy would.
---@return table LifecycleKit the facade Registry hands that copy
function LifecycleKitTestEnv.LoadRevision18()
  local chunk = assert(loadfile(REVISION_18_FIXTURE))
  return chunk()
end

---Run the LifecycleKit source once more as a copy carrying `revision`, the way
---a second addon embedding a different copy would. The copy is the current
---source with only `IMPLEMENTATION_REVISION` changed, so it stands in for an
---older or newer revision whose `_state` schema matches this one.
---@param revision integer
---@return table LifecycleKit the facade the copy returned
function LifecycleKitTestEnv.LoadSourceAtRevision(revision)
  -- Lua 5.1 has no `package.searchpath`, so walk the templates by hand.
  local path, file = nil, nil
  for template in string.gmatch(package.path, "[^;]+") do
    local candidate = string.gsub(template, "%?", "LifecycleKit")
    file = io.open(candidate, "rb")
    if file ~= nil then
      path = candidate
      break
    end
  end
  if file == nil then
    error("LifecycleKitTestEnv cannot find LifecycleKit.lua on package.path", 2)
  end
  local source = file:read("*a")
  file:close()

  local patched, count = source:gsub(
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision,
    1
  )
  if count ~= 1 then
    error("LifecycleKitTestEnv found no IMPLEMENTATION_REVISION in " .. path, 2)
  end
  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return LifecycleKitTestEnv
