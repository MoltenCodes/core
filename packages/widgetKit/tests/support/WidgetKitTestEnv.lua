--- Package-specific test environment for the WidgetKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`;
--- its `FrameStub` models the sizes, anchors, regions and frame types widgets
--- use. What stays here is this package's own module load order and the
--- helpers only its specs describe:
---
---   the screen      `UIParent`, a named 1920 x 1080 frame at the origin,
---                   created after the module chain loads;
---   secret values   `InstallSecretProbe` installs `issecretvalue`, which
---                   reports the tables `NewSecret` returns;
---   allocation      `AllocatedKilobytes` measures a workload with the
---                   collector stopped;
---   upgrades        `LoadRevision` loads the source again as another revision;
---   client rules    `InstallClientRules` applies what the client does and the
---                   shared stub does not (`WidgetKitClientRules`): secret
---                   arguments refused by frame setters, `nil` for an empty
---                   text, the secret aspect of a font string and strata that
---                   follow the parent. Every `NewPackage` loader installs them.
---
--- OptionsKit is an optional dependency of WidgetKit, declared under
--- `optionalDependencies`, so the test runner puts it and its closure on
--- `LUA_PATH`. `NewPackageWithoutOptionsKit` models an addon that embeds none.
--- The SchedulerKit, SettingsKit and MediaKit chain lives in
--- `WidgetKitHostTestEnv`.
local FrameworkTestEnv = require("FrameworkTestEnv")
local WidgetKitClientRules = require("WidgetKitClientRules")

local WidgetKitTestEnv = FrameworkTestEnv.New({
  modules = { "Registry", "SignalKit", "PoolKit", "SchemaKit", "OptionsKit", "WidgetKit" },
})

--- The screen size `UIParent` has.
WidgetKitTestEnv.SCREEN_WIDTH = 1920
WidgetKitTestEnv.SCREEN_HEIGHT = 1080

--- Tables the `issecretvalue` stub reports as secret. Weak-keyed so a spec's
--- secrets never outlive it.
local secrets = setmetatable({}, { __mode = "k" })

---Read a host global. The fixture stands in for the World of Warcraft client,
---whose API only exists in the global table.
---@param name string
---@return any
function WidgetKitTestEnv.GetGlobal(name)
  -- selene: allow(global_usage)
  return rawget(_G, name)
end

---Write a host global the same way. `issecretvalue`, `UIParent` and named
---frames are cleared by the shared `Reset`; any other global a spec writes it
---must clear itself.
---@param name string
---@param value any
function WidgetKitTestEnv.SetGlobal(name, value)
  -- selene: allow(global_usage)
  rawset(_G, name, value)
end

---Create `UIParent`: a named, parentless frame at the origin, the size of the
---screen.
---@return table uiParent
function WidgetKitTestEnv.InstallScreen()
  local createFrame = WidgetKitTestEnv.GetGlobal("CreateFrame")
  local uiParent = createFrame("Frame", "UIParent")
  uiParent:SetSize(WidgetKitTestEnv.SCREEN_WIDTH, WidgetKitTestEnv.SCREEN_HEIGHT)
  return uiParent
end

---Apply the client rules of `WidgetKitClientRules` to every frame created
---from now on, until the next `Reset`.
function WidgetKitTestEnv.InstallClientRules()
  WidgetKitClientRules.Install(WidgetKitTestEnv.SetGlobal)
end

local sharedNewPackage = WidgetKitTestEnv.NewPackage

---Reset, install the host stubs and the client rules, load the module chain
---and create the screen.
---@return table WidgetKit
---@return table Registry
---@return table SignalKit
---@return table PoolKit
---@return table SchemaKit
---@return table OptionsKit
function WidgetKitTestEnv.NewPackage()
  local WidgetKit, Registry, SignalKit, PoolKit, SchemaKit, OptionsKit = sharedNewPackage()
  WidgetKitTestEnv.InstallClientRules()
  WidgetKitTestEnv.InstallScreen()
  return WidgetKit, Registry, SignalKit, PoolKit, SchemaKit, OptionsKit
end

---Load the chain without creating `UIParent`, as on a host without one.
---@return table WidgetKit
function WidgetKitTestEnv.NewPackageWithoutScreen()
  local WidgetKit = sharedNewPackage()
  WidgetKitTestEnv.InstallClientRules()
  return WidgetKit
end

---Load Registry, SignalKit, PoolKit and WidgetKit only, as an addon that
---embeds no OptionsKit does.
---@return table WidgetKit
---@return table Registry
function WidgetKitTestEnv.NewPackageWithoutOptionsKit()
  WidgetKitTestEnv.Reset()
  WidgetKitTestEnv.InstallWowApi()
  local Registry = require("Registry")
  require("SignalKit")
  require("PoolKit")
  local WidgetKit = require("WidgetKit")
  WidgetKitTestEnv.InstallClientRules()
  WidgetKitTestEnv.InstallScreen()
  return WidgetKit, Registry
end

---Install `issecretvalue`, reporting the tables `NewSecret` returns.
function WidgetKitTestEnv.InstallSecretProbe()
  WidgetKitTestEnv.SetGlobal("issecretvalue", function(value)
    return secrets[value] == true
  end)
end

---A value `issecretvalue` reports as secret once the probe is installed.
---@return table secret
function WidgetKitTestEnv.NewSecret()
  local secret = {}
  secrets[secret] = true
  return secret
end

---Measure the allocation a workload causes, in kilobytes, with the collector
---stopped so that a collection cycle cannot hide or invent growth.
---@param workload fun()
---@return number kilobytes
function WidgetKitTestEnv.AllocatedKilobytes(workload)
  collectgarbage()
  collectgarbage("stop")
  local before = collectgarbage("count")
  workload()
  local after = collectgarbage("count")
  collectgarbage("restart")
  return after - before
end

---Load the WidgetKit source again as a copy carrying `revision`, the way a
---newer embedded copy loads over an older one in the client. `replacements`
---maps further source text to what it becomes in that copy.
---@param revision integer
---@param replacements table<string, string>?
---@return table WidgetKit
function WidgetKitTestEnv.LoadRevision(revision, replacements)
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "WidgetKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("WidgetKitTestEnv.LoadRevision could not find WidgetKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, count =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if count ~= 1 then
    error("WidgetKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end
  for original, replacement in pairs(replacements or {}) do
    local start, finish = patched:find(original, 1, true)
    if start == nil then
      error("WidgetKitTestEnv.LoadRevision could not find " .. original, 2)
    end
    patched = patched:sub(1, start - 1) .. replacement .. patched:sub(finish + 1)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return WidgetKitTestEnv
