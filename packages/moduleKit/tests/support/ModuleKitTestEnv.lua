--- Package-specific test environment for the ModuleKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order.
---
--- HookKit, CommandKit and SchemaKit are optional dependencies: `module.scope.Hooks`
--- and `module.scope.Commands` find the first two through `Registry:Find` at
--- first read, and the schema form of `implements` finds SchemaKit at
--- registration. The manifest declares them under `optionalDependencies`, so
--- the test runner puts them on `LUA_PATH`, and the module chain loads them as
--- an addon that embeds them would. `NewPackageWithoutOptionalKits` loads the
--- chain without them.
---
--- ModuleKit's parts (Injection, Implements, RequiredAddons) load on top of
--- the chain: `NewPackage` loads them all, as most specs exercise them, and
--- `NewCore` loads the chain without them, as an addon that embeds the core
--- alone does. When LifecycleKit ships its Halt part as a file of its own, both
--- load it after LifecycleKit, since the RequiredAddons part needs it.
local FrameworkTestEnv = require("FrameworkTestEnv")
local assert = require("luassert")

local ModuleKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "SignalKit",
    "EventKit",
    "LifecycleKit",
    -- Halting is a LifecycleKit part from its revision 19 on.
    "LifecycleKit-Halt",
    "HookKit",
    "SchemaKit",
    "CommandKit",
    -- Buses, which `scope.Messages` and `OnModuleCreated` use, are SignalKit's
    -- Bus part from its revision 13 on. It is listed last so the positions
    -- `NewPackage` returns the other modules at stay as they were.
    "SignalKit-Bus",
    "ModuleKit",
  },
})

local installFixtureWowApi = ModuleKitTestEnv.InstallWowApi
local resetFixture = ModuleKitTestEnv.Reset

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

ModuleKitTestEnv.RunSlash = runSlash

-- CommKit ------------------------------------------------------------------
--
-- CommKit is an optional dependency, and it requires LifecycleKit, TimerKit,
-- SchedulerKit and PoolKit. It cannot sit in the module chain above: it must
-- load after LifecycleKit, and TimerKit and SchedulerKit in the chain would
-- replace the stand-ins other specs register. `LoadCommKit` loads the four on
-- top of a chain `NewPackage` already loaded; the runner puts them on
-- `LUA_PATH` as CommKit's required closure, and `Reset` clears them.

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
function ModuleKitTestEnv.LoadCommKit()
  local loaded
  for index = 1, #COMM_KIT_MODULES do
    loaded = require(COMM_KIT_MODULES[index])
  end
  return loaded
end

-- ModuleKit's parts ----------------------------------------------------------

--- ModuleKit's part modules, in the order `LoadParts` loads them.
local PART_MODULES = { "ModuleKit-Injection", "ModuleKit-Implements", "ModuleKit-RequiredAddons" }

--- LifecycleKit's Halt part, which the RequiredAddons part needs. A
--- LifecycleKit whose Halt part is still built into its core has no such file.
local LIFECYCLE_HALT_PART = "LifecycleKit-Halt"

--- Other Kits' parts a spec loads on top of the chain: SchemaKit's Rules part,
--- whose `custom` the schema form of `implements` is tested with.
local EXTRA_PART_MODULES = { "SchemaKit-Rules" }

---Clear the part modules from `package.loaded`, so the next load runs each
---part file again.
local function unloadParts()
  for index = 1, #PART_MODULES do
    package.loaded[PART_MODULES[index]] = nil
  end
  for index = 1, #EXTRA_PART_MODULES do
    package.loaded[EXTRA_PART_MODULES[index]] = nil
  end
  package.loaded[LIFECYCLE_HALT_PART] = nil
end

---Load LifecycleKit's Halt part when this tree has it as a file of its own.
local function loadLifecycleHaltPart()
  if FrameworkTestEnv.findModuleFile(LIFECYCLE_HALT_PART) ~= nil then
    require(LIFECYCLE_HALT_PART)
  end
end

---Load ModuleKit's parts, or the named ones, on top of a loaded core.
---@param names string[]? part names (`"Injection"`); every part when omitted
---@return table ModuleKit
function ModuleKitTestEnv.LoadParts(names)
  loadLifecycleHaltPart()
  local loaded
  if names == nil then
    for index = 1, #PART_MODULES do
      loaded = require(PART_MODULES[index])
    end
  else
    for index = 1, #names do
      loaded = require("ModuleKit-" .. names[index])
    end
  end
  return loaded
end

local loadChain = ModuleKitTestEnv.NewPackage

---Load the module chain and ModuleKit's core alone, without its parts.
---@return ... loaded modules, ModuleKit first, as `NewPackage` returns them
function ModuleKitTestEnv.NewCore()
  local results = { loadChain() }
  loadLifecycleHaltPart()
  return unpack(results, 1, table.maxn(results))
end

---Load the module chain, then every ModuleKit part.
---@return ... loaded modules, ModuleKit first
function ModuleKitTestEnv.NewPackage()
  local results = { loadChain() }
  ModuleKitTestEnv.LoadParts()
  return unpack(results, 1, table.maxn(results))
end

---Install the shared fixture's WoW API plus an empty `SlashCmdList`.
function ModuleKitTestEnv.InstallWowApi()
  installFixtureWowApi()
  setGlobal("SlashCmdList", {})
end

---Reset the shared fixture and remove the slash-command globals.
function ModuleKitTestEnv.Reset()
  resetFixture()
  unloadParts()
  unloadCommKit()
  removeSlashApi()
end

---Load the module chain without HookKit, SchemaKit and CommandKit, as an
---addon that embeds none of them does.
---@return table ModuleKit
function ModuleKitTestEnv.NewPackageWithoutOptionalKits()
  ModuleKitTestEnv.Reset()
  ModuleKitTestEnv.InstallWowApi()
  require("Registry")
  require("SignalKit")
  require("SignalKit-Bus")
  require("EventKit")
  require("LifecycleKit")
  require("ModuleKit")
  return ModuleKitTestEnv.LoadParts()
end

---Load every module of the chain except ModuleKit, as `NewPackage` does, so a
---spec can then load a ModuleKit copy of its choosing (and `LoadParts` after
---it).
function ModuleKitTestEnv.LoadDependencies()
  ModuleKitTestEnv.Reset()
  ModuleKitTestEnv.InstallWowApi()
  require("Registry")
  require("SignalKit")
  require("SignalKit-Bus")
  require("EventKit")
  local LifecycleKit = require("LifecycleKit")
  loadLifecycleHaltPart()
  require("HookKit")
  require("SchemaKit")
  require("CommandKit")
  return LifecycleKit
end

---Run ModuleKit's source as if it declared implementation revision `revision`.
---
---This is how an upgrade spec models an embedded copy older or newer than the
---one under test without keeping a second copy of the source. It bypasses
---`require`, so `package.loaded.ModuleKit` is left alone.
---@param revision integer
---@return table ModuleKit the facade that copy returned
function ModuleKitTestEnv.LoadRevision(revision)
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "ModuleKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("ModuleKitTestEnv.LoadRevision could not find ModuleKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("ModuleKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk, failure = loadstring(patched, "@" .. path)
  if chunk == nil then
    error(
      "ModuleKitTestEnv.LoadRevision could not compile " .. path .. ": " .. tostring(failure),
      2
    )
  end
  return chunk()
end

-- The verbatim file of revision 23, the last revision before the parts and
-- the oldest one this revision takes over in place (the upgrade floor).
local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local REVISION_23_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/ModuleKit-revision23.lua"

---Run the verbatim revision 23 file, as an addon of that time embedded it.
---Like `LoadRevision`, it bypasses `require`; `LoadDependencies` first.
---@return table ModuleKit the facade revision 23 returned
function ModuleKitTestEnv.LoadRevision23()
  local chunk, failure = loadfile(REVISION_23_FIXTURE)
  if chunk == nil then
    error("ModuleKitTestEnv.LoadRevision23 could not compile the fixture: " .. tostring(failure), 2)
  end
  return chunk()
end

---Assert that `callback` raises `expected` at the line that calls into
---ModuleKit, which is the first line of `callback`'s body, the line after its
---`function()`. The source compared is the spec file that called this helper.
---@param expected string substring the message must contain
---@param callback fun()
function ModuleKitTestEnv.expectCallerError(expected, callback)
  local source = debug.getinfo(2, "S").short_src
  local line = debug.getinfo(callback, "S").linedefined + 1
  local ok, message = pcall(callback)

  assert.is_false(ok)
  assert.is_not_nil(string.find(tostring(message), expected, 1, true), tostring(message))
  assert.is_not_nil(
    string.find(tostring(message), source .. ":" .. line .. ":", 1, true),
    tostring(message)
  )
end

return ModuleKitTestEnv
