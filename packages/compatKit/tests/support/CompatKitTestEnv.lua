--- Package-specific test environment for the CompatKit suite.
---
--- The World of Warcraft stubs, the per-flavour client profiles, the
--- `package.loaded` bookkeeping and the error capture live in the shared
--- `FrameworkTestEnv` fixture at `tests/support/`. What stays here is
--- CompatKit's own:
---
---   the module chain            Registry, then CompatKit;
---   a profile-first loader      `NewPackageFor(profile)` selects a client
---                               profile before the host stubs are installed,
---                               so ClientKit reads a flavour at its load;
---   the optional Kits           `LoadClientKit` and `LoadApiKit` load the two
---                               optional dependencies with `require`, which
---                               the runner puts on `LUA_PATH` because the
---                               manifest names them under
---                               `optionalDependencies`; `LoadApiKit` can also
---                               load one committed flavour file;
---   the upgrade loader          `LoadSourceAtRevision` loads the source again
---                               with its revision patched, as a newer embedded
---                               copy would load over an older one;
---   the allocation meter        `AllocatedKilobytes`.
---
--- `Reset` also forgets the optional Kits' modules and the `wow` global ApiKit
--- publishes, which are not among the modules and globals the shared fixture
--- owns.
local FrameworkTestEnv = require("FrameworkTestEnv")

local CompatKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "CompatKit" },
})

--- Path of the runtime source, relative to the repository root the runner
--- starts Busted from.
local SOURCE_PATH = "packages/compatKit/src/CompatKit.lua"

--- Modules this environment loads beside the chain and forgets on `Reset`.
local OPTIONAL_MODULES = { "ClientKit", "ApiKit", "flavours.Retail", "flavours.ClassicEra" }

--- The global ApiKit publishes, which the fixture does not own.
local OWNED_GLOBALS = { "wow" }

local sharedReset = CompatKitTestEnv.Reset

---Write a host global. The stubs stand in for World of Warcraft client APIs
---that only exist in the global table.
---@param name string
---@param value any
local function setGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Clear everything the shared fixture clears, plus the optional Kits'
---modules and globals.
function CompatKitTestEnv.Reset()
  sharedReset()
  for index = 1, #OPTIONAL_MODULES do
    package.loaded[OPTIONAL_MODULES[index]] = nil
  end
  for index = 1, #OWNED_GLOBALS do
    setGlobal(OWNED_GLOBALS[index], nil)
  end
end

---Reset, select the client profile `profile` (see `framework/ClientStub.lua`;
---`nil` installs no client identity), install the host stubs, then load
---Registry and CompatKit.
---@param profile string?
---@return table CompatKit
---@return table Registry
function CompatKitTestEnv.NewPackageFor(profile)
  CompatKitTestEnv.Reset()
  CompatKitTestEnv.SetWowProfile(profile)
  CompatKitTestEnv.InstallWowApi()
  local Registry = require("Registry")
  local CompatKit = require("CompatKit")
  return CompatKit, Registry
end

---Load ClientKit over the chain already loaded, as a `.toc` listing it after
---CompatKit would.
---@return table ClientKit
function CompatKitTestEnv.LoadClientKit()
  return require("ClientKit")
end

---Load ApiKit over the chain already loaded and, when asked, one committed
---flavour file by module name (`"flavours.Retail"`, `"flavours.ClassicEra"`),
---which installs its bindings only on a client of its flavour (the `mainline`
---and `classic` profiles respectively).
---@param flavourModule string?
---@return table ApiKit
function CompatKitTestEnv.LoadApiKit(flavourModule)
  local ApiKit = require("ApiKit")
  if flavourModule ~= nil then
    require(flavourModule)
  end
  return ApiKit
end

---Make the host's `issecretvalue` report `secret` (compared with `rawequal`)
---as a secret value. The shared fixture owns and clears this global.
---@param secret any
function CompatKitTestEnv.InstallSecretProbe(secret)
  setGlobal("issecretvalue", function(value)
    return rawequal(value, secret)
  end)
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function CompatKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Read a file relative to the repository root.
---@param path string
---@return string
function CompatKitTestEnv.ReadFile(path)
  local file = io.open(path, "r")
  if file == nil then
    error("CompatKitTestEnv cannot read " .. path, 2)
  end
  local text = file:read("*a")
  file:close()
  return text
end

---Load the CompatKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client.
---@param revision integer
---@return table CompatKit
function CompatKitTestEnv.LoadSourceAtRevision(revision)
  local patched, replacements = CompatKitTestEnv.ReadFile(SOURCE_PATH):gsub(
    "local IMPLEMENTATION_REVISION = %d+",
    "local IMPLEMENTATION_REVISION = " .. revision,
    1
  )
  if replacements ~= 1 then
    error("CompatKitTestEnv found no IMPLEMENTATION_REVISION in the source", 2)
  end
  local chunk, message = loadstring(patched, "@" .. SOURCE_PATH)
  if chunk == nil then
    error(message, 2)
  end
  return chunk()
end

return CompatKitTestEnv
