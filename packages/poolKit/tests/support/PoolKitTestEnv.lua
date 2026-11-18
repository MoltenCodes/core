--- Package-specific test environment for the PoolKit suite.
---
--- The World of Warcraft stubs, the `package.loaded` bookkeeping and the error
--- capture live in the shared `FrameworkTestEnv` fixture at `tests/support/`.
--- What stays here is this package's own module load order: the core and
--- its four parts by default, so every mechanism serves, and the core alone in
--- `PoolKitTestEnv.Core`, as an addon that embeds only `poolKit\PoolKit.lua`
--- loads it.
local FrameworkTestEnv = require("FrameworkTestEnv")

--- The parts, in manifest order.
local PARTS = { "PoolKit-Waiting", "PoolKit-Children", "PoolKit-Deferred", "PoolKit-Generations" }

local PoolKitTestEnv = FrameworkTestEnv.New({
  modules = {
    "Registry",
    "PoolKit",
    PARTS[1],
    PARTS[2],
    PARTS[3],
    PARTS[4],
  },
  -- PoolKit is pure Lua and stays silent without a host error sink, so its
  -- specs install `geterrorhandler` explicitly through
  -- `InstallHostErrorHandler` rather than having it installed for them.
  wowApi = false,
})

PoolKitTestEnv.PARTS = PARTS

--- The core without its parts.
PoolKitTestEnv.Core = FrameworkTestEnv.New({
  modules = { "Registry", "PoolKit" },
  wowApi = false,
})

--- Load every part after the core, as an addon that embeds them does.
---@return table PoolKit
function PoolKitTestEnv.LoadParts()
  local PoolKit = nil
  for index = 1, #PARTS do
    package.loaded[PARTS[index]] = nil
    PoolKit = require(PARTS[index])
  end
  return PoolKit
end

--- Load the core again over whatever state is already published, then its
--- parts, as a later addon embedding the core and every part does.
---@return table PoolKit
function PoolKitTestEnv.ReloadPackage()
  package.loaded["PoolKit"] = nil
  require("PoolKit")
  return PoolKitTestEnv.LoadParts()
end

--- Diagnostics PoolKit handed to the host error handler, in order.
---@return any[]
function PoolKitTestEnv.ReportedWarnings()
  return PoolKitTestEnv.ReportedErrors()
end

---A stand-in for a World of Warcraft AnimationGroup, reduced to what
---`Pool:ReleaseAfter` touches: `HookScript("OnFinished", handler)` and
---`IsPlaying()`, plus the `Play` and `Stop` methods its shape check requires.
---`Finish()` ends the animation the way the client does, calling every hooked
---`OnFinished` handler with the group and `requested = false`; `Stop()` ends it
---without firing `OnFinished`, as the client does.
---
---The shared fixture has no animation stubs because only PoolKit needs one.
---@return table group
function PoolKitTestEnv.NewAnimationGroup()
  local group = { playing = true, hooks = {} }

  function group:HookScript(scriptName, handler)
    if scriptName ~= "OnFinished" then
      error("the animation group stub only models OnFinished, got " .. tostring(scriptName), 2)
    end
    self.hooks[#self.hooks + 1] = handler
  end

  function group:IsPlaying()
    return self.playing
  end

  function group:Play()
    self.playing = true
  end

  function group:Stop()
    self.playing = false
  end

  function group:Finish()
    self.playing = false
    for index = 1, #self.hooks do
      self.hooks[index](self, false)
    end
  end

  return group
end

-- Revision 11 is the last whole file, every mechanism included; it is kept
-- verbatim as `fixtures/PoolKit-revision11.lua`.
local LAST_WHOLE_REVISION = 11
local SUPPORT_DIRECTORY = debug.getinfo(1, "S").source:match("^@(.*[/\\])") or "./"
local WHOLE_FIXTURE = SUPPORT_DIRECTORY .. "../fixtures/PoolKit-revision11.lua"

---Load PoolKit with its `IMPLEMENTATION_REVISION` patched to `revision`, and
---run it as that revision would load: up to revision 11 the whole-file
---fixture (every mechanism, no parts), after it the core from `package.path`.
---
---This stands in for an older embedded copy, which is what an in-place
---upgrade inherits.
---@param revision integer
---@return table PoolKit
function PoolKitTestEnv.LoadRevision(revision)
  if revision <= LAST_WHOLE_REVISION then
    local file = assert(io.open(WHOLE_FIXTURE, "r"))
    local text = file:read("*a")
    file:close()
    local patched, replacements = text:gsub(
      "local IMPLEMENTATION_REVISION = %d+",
      "local IMPLEMENTATION_REVISION = " .. revision
    )
    if replacements ~= 1 then
      error("PoolKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
    end
    return assert(loadstring(patched, "@" .. WHOLE_FIXTURE))()
  end
  -- Lua 5.1 has no `package.searchpath`, so walk the path templates the way
  -- `require` does.
  local path = nil
  for template in package.path:gmatch("[^;]+") do
    local candidate = template:gsub("%?", "PoolKit")
    local file = io.open(candidate, "r")
    if file ~= nil then
      file:close()
      path = candidate
      break
    end
  end
  if path == nil then
    error("PoolKitTestEnv.LoadRevision could not find PoolKit.lua on package.path", 2)
  end

  local file = assert(io.open(path, "r"))
  local text = file:read("*a")
  file:close()

  local patched, replacements =
    text:gsub("local IMPLEMENTATION_REVISION = %d+", "local IMPLEMENTATION_REVISION = " .. revision)
  if replacements ~= 1 then
    error("PoolKitTestEnv.LoadRevision could not find IMPLEMENTATION_REVISION", 2)
  end

  local chunk = assert(loadstring(patched, "@" .. path))
  return chunk()
end

return PoolKitTestEnv
