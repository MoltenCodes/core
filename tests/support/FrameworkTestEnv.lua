--- Shared World of Warcraft test fixture for every MoltenCodes package suite.
---
--- Every package suite needs the same stubs: a fake `CreateFrame`, a fake
--- `C_Timer`, controllable clocks, a capture for the host error handler, and
--- the `package.loaded` bookkeeping a bootstrap spec needs. They live here once,
--- so a fix to one of them (the two-slot `RegisterUnitEvent` limit, say)
--- reaches every suite.
---
--- `FrameworkTestEnv.New` builds one environment per package. Each environment
--- owns its own stub state, so nothing leaks between environments even when a
--- process builds more than one.
---
--- This file is the facade. The stubs themselves live one per file under
--- `framework/`, and each of them is a module-level factory over the shared
--- state table this file creates:
---
---     framework/Constants.lua           keys, host limits, owned globals
---     framework/FrameStub.lua           CreateFrame, Emit, Tick, registrations
---     framework/TimerStub.lua           C_Timer and the native timer handles
---     framework/ClockStub.lua           the wall clock and the CPU clock
---     framework/AddonStub.lua           addon load state, login, combat log
---     framework/ClientStub.lua          client identity and per-flavour profiles
---     framework/ErrorHandlerStub.lua    geterrorhandler and securecallfunction
---
--- What stays here is what is not any one stub's: option handling, the load
--- order of a package's module chain, the `Reset`/`NewPackage`/`ReloadPackage`
--- lifecycle that drives every stub together, and the helpers the shared
--- conformance suite (`KitConformance.lua`) builds on: `Modules`,
--- `NewPackageWithout` and `LoadSourceWithRevision`.
---
--- A package keeps `tests/support/<Kit>TestEnv.lua` for what is genuinely its
--- own: the load order of its module chain, and any helper that only its specs
--- can describe.
---
--- Busted injects `describe`, `it` and luassert's `assert` into spec chunks
--- only. This module is loaded through plain `require`, so it names luassert
--- explicitly for the handful of helpers that assert a genuine expectation, and
--- raises ordinary `error(..., 2)` for stub preconditions.

local assert = require("luassert")

local Constants = require("framework.Constants")
local FrameStub = require("framework.FrameStub")
local TimerStub = require("framework.TimerStub")
local ClockStub = require("framework.ClockStub")
local AddonStub = require("framework.AddonStub")
local ClientStub = require("framework.ClientStub")
local ErrorHandlerStub = require("framework.ErrorHandlerStub")

--- Every stub factory, in the order `Reset` and `InstallWowApi` drive them.
---
--- `ErrorHandlerStub` is absent from this list on purpose: it installs nothing
--- by default, because a pure-Lua package's specs opt into a host error sink
--- rather than having one installed for them. It is reset with the rest.
---
--- `ClientStub` comes after `AddonStub` because a legacy client profile
--- replaces the `C_AddOns` table `AddonStub` installs.
local STUBS = { FrameStub, TimerStub, ClockStub, AddonStub, ClientStub, ErrorHandlerStub }

local FrameworkTestEnv = {}

--- Private bootstrap-state key the Registry API 2 implementation publishes.
FrameworkTestEnv.REGISTRY_STATE_KEY = Constants.REGISTRY_STATE_KEY

--- The retired API 1 bootstrap-state key. Specs that prove it is *not* adopted
--- still have to clear it between attempts.
FrameworkTestEnv.LEGACY_REGISTRY_STATE_KEY = Constants.LEGACY_REGISTRY_STATE_KEY

--- The documented public namespace every package hands off through.
FrameworkTestEnv.NAMESPACE_KEY = Constants.NAMESPACE_KEY

--- The host's `Frame:RegisterUnitEvent(event, unit1, unit2)` slot count.
FrameworkTestEnv.MAXIMUM_UNIT_TOKENS = Constants.MAXIMUM_UNIT_TOKENS

---Clear `package.loaded` for `moduleName` and require it again.
---
---Lua 5.1 marks a module as in-progress in `package.loaded` before running its
---chunk and does not clear that marker when the chunk raises. A second
---`require` of the same module would otherwise report `loop or previous error
---loading module` instead of re-running the bootstrap guard under test.
---@param moduleName string
---@return any
function FrameworkTestEnv.requireAfterFailedLoad(moduleName)
  package.loaded[moduleName] = nil
  return require(moduleName)
end

---Assert that `callback` fails with a message containing `expected`.
---@param expected string substring the failure must contain
---@param callback fun()
function FrameworkTestEnv.expectErrorContaining(expected, callback)
  local ok, message = pcall(callback)

  assert.is_false(ok)
  assert.is_not_nil(string.find(tostring(message), expected, 1, true))
end

---Options accepted by `FrameworkTestEnv.New`.
---@class FrameworkTestEnv.Options
---@field modules string[]? Module names in load order; the last one is the package under test. Omit it for a suite that loads its subject some other way, such as the example addon.
---@field wowApi boolean? Whether `NewPackage` installs the WoW stubs. Defaults to `true`.
---@field legacyRegistryState boolean? Whether `Reset` also clears the retired API 1 state key.
---@field wowProfile string? Client profile `InstallWowApi` installs: `"mainline"`, `"mists"`, `"tbc"`, `"classic"` or `"noProjectId"`. Defaults to none, which installs no client identity at all. See `framework/ClientStub.lua`.

---Validate `options` and return what `New` needs from it.
---@param options any
---@return string[] modules, boolean installsWowApi, boolean clearsLegacyState, string? wowProfile
local function readOptions(options)
  if type(options) ~= "table" then
    error("FrameworkTestEnv.New requires an options table", 3)
  end

  local modules = options.modules
  if modules == nil then
    modules = {}
  elseif type(modules) ~= "table" then
    error("FrameworkTestEnv.New options.modules must be an array of module names", 3)
  end

  ClientStub.ValidateProfileName(options.wowProfile, 4)

  return modules, options.wowApi ~= false, options.legacyRegistryState == true, options.wowProfile
end

---Clear every global an environment owns, whether or not it installed it.
---@param clearsLegacyState boolean
local function clearOwnedGlobals(clearsLegacyState)
  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, Constants.REGISTRY_STATE_KEY, nil)
  -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
  -- selene: allow(global_usage)
  rawset(_G, Constants.NAMESPACE_KEY, nil)
  if clearsLegacyState then
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, Constants.LEGACY_REGISTRY_STATE_KEY, nil)
  end
  for index = 1, #Constants.OWNED_GLOBALS do
    -- The fixture stands in for the World of Warcraft client, whose API and shared namespace only exist in the global table.
    -- selene: allow(global_usage)
    rawset(_G, Constants.OWNED_GLOBALS[index], nil)
  end
end

---Build one package's test environment.
---@param options FrameworkTestEnv.Options
---@return table environment
function FrameworkTestEnv.New(options)
  local modules, installsWowApi, clearsLegacyState, wowProfile = readOptions(options)
  local packageModule = modules[#modules]

  local environment = {}

  environment.REGISTRY_STATE_KEY = FrameworkTestEnv.REGISTRY_STATE_KEY
  environment.LEGACY_REGISTRY_STATE_KEY = FrameworkTestEnv.LEGACY_REGISTRY_STATE_KEY
  environment.NAMESPACE_KEY = FrameworkTestEnv.NAMESPACE_KEY
  environment.MAXIMUM_UNIT_TOKENS = FrameworkTestEnv.MAXIMUM_UNIT_TOKENS
  environment.requireAfterFailedLoad = FrameworkTestEnv.requireAfterFailedLoad
  environment.expectErrorContaining = FrameworkTestEnv.expectErrorContaining

  -- One state table per environment, owned jointly by the stub factories and
  -- returned to its initial values by `Reset`. That reset is what keeps specs
  -- independent of each other's execution order.
  local state = { defaultWowProfile = wowProfile }
  for index = 1, #STUBS do
    STUBS[index].Reset(state)
    STUBS[index].Attach(environment, state)
  end

  ---Install every World of Warcraft API the framework packages touch.
  function environment.InstallWowApi()
    for index = 1, #STUBS do
      local installGlobals = STUBS[index].InstallGlobals
      if installGlobals ~= nil then
        installGlobals(state)
      end
    end

    environment.InstallHostErrorHandler()
  end

  ---Clear every module, global and stub this environment owns.
  function environment.Reset()
    for index = #modules, 1, -1 do
      package.loaded[modules[index]] = nil
    end

    clearOwnedGlobals(clearsLegacyState)

    for index = 1, #STUBS do
      STUBS[index].Reset(state)
    end
  end

  ---Reset, install the host stubs, then load the module chain in order.
  ---
  ---The package under test is returned first, then its dependencies in
  ---load order, so a spec can name only what it needs.
  ---@return ... loaded modules, package under test first
  function environment.NewPackage()
    if packageModule == nil then
      error("this environment was built without a module chain to load", 2)
    end

    environment.Reset()
    if installsWowApi then
      environment.InstallWowApi()
    end

    local loaded = {}
    for index = 1, #modules do
      loaded[index] = require(modules[index])
    end

    local ordered = { loaded[#loaded] }
    for index = 1, #loaded - 1 do
      ordered[index + 1] = loaded[index]
    end
    return unpack(ordered, 1, #ordered)
  end

  ---Re-run the package under test against the state it already published.
  ---@return any
  function environment.ReloadPackage()
    if packageModule == nil then
      error("this environment was built without a module chain to load", 2)
    end

    package.loaded[packageModule] = nil
    return require(packageModule)
  end

  ---The module chain in load order, the package under test last. A copy, so a
  ---caller cannot change the environment's own list.
  ---@return string[]
  function environment.Modules()
    local copy = {}
    for index = 1, #modules do
      copy[index] = modules[index]
    end
    return copy
  end

  ---Reset, install the host stubs, and load the module chain without
  ---`skippedModule`, then try to load the package under test.
  ---
  ---With a dependency skipped this proves the package refuses to load and
  ---names what is missing; with the package under test skipped it loads
  ---only the dependencies, ready for an older revision to load over them.
  ---@param skippedModule string a module of the chain
  ---@return boolean loaded whether the package under test loaded (`false` when it was skipped)
  ---@return any result the package, or the load error
  function environment.NewPackageWithout(skippedModule)
    if packageModule == nil then
      error("this environment was built without a module chain to load", 2)
    end
    local known = false
    for index = 1, #modules do
      known = known or modules[index] == skippedModule
    end
    if not known then
      error("NewPackageWithout: " .. tostring(skippedModule) .. " is not in the module chain", 2)
    end

    environment.Reset()
    if installsWowApi then
      environment.InstallWowApi()
    end
    for index = 1, #modules - 1 do
      if modules[index] ~= skippedModule then
        require(modules[index])
      end
    end
    if skippedModule == packageModule then
      return false, nil
    end
    return pcall(require, packageModule)
  end

  ---Load `moduleName`'s source from `package.path` with its
  ---`IMPLEMENTATION_REVISION` set to `revision`, and return what it returns.
  ---
  ---This is the shared form of the per-package `LoadRevision` helpers: the
  ---same code under a lower revision number proves the in-place takeover
  ---path, which an older embedded copy takes in a real session.
  ---@param moduleName string
  ---@param revision integer
  ---@return any
  function environment.LoadSourceWithRevision(moduleName, revision)
    local path = FrameworkTestEnv.findModuleFile(moduleName)
    if path == nil then
      error("LoadSourceWithRevision could not find " .. moduleName .. " on package.path", 2)
    end
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    local patched, replacements = text:gsub(
      "local IMPLEMENTATION_REVISION = %d+",
      "local IMPLEMENTATION_REVISION = " .. revision,
      1
    )
    if replacements ~= 1 then
      error("LoadSourceWithRevision found no IMPLEMENTATION_REVISION in " .. path, 2)
    end
    local chunk = assert(loadstring(patched, "@" .. path))
    return chunk()
  end

  return environment
end

---Return the file `require(moduleName)` would load from `package.path`, or `nil`.
---
---Lua 5.1 has no `package.searchpath`, so the templates are walked the way
---`require` walks them.
---@param moduleName string
---@return string?
function FrameworkTestEnv.findModuleFile(moduleName)
  local fileName = moduleName:gsub("%.", "/")
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", fileName)
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      return candidate
    end
  end
  return nil
end

return FrameworkTestEnv
